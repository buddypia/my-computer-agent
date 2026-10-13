import AppKit
import Foundation
import MCACore
import MCAPresentation
import MCAReasoning
@testable import mca
import os
import Testing

@Suite("Tool Approval & Watchdog Responsiveness Stress Tests", .serialized)
@MainActor
struct ToolApprovalWatchdogStressTests {

    @Test("5 consecutive approval cycles present and dismiss responsively without tripping MainThreadWatchdog")
    func consecutiveApprovalCyclesWithoutWatchdogHang() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        let hangCount = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = MainThreadWatchdog(
            targetQueue: .main,
            timeoutSeconds: 2,
            pollIntervalSeconds: 1,
            onHang: { _ in
                hangCount.withLock { $0 += 1 }
            }
        )
        watchdog.start()
        defer { watchdog.stop() }

        // Test 5 consecutive approval cycles
        for round in 1...5 {
            // 1. Present for approval
            chat.presentForApproval()
            #expect(state.chatInputFocusSuppressed, "Round \(round): focus must be suppressed on presentForApproval")
            #expect(state.isChatOpen, "Round \(round): chat must be open")

            let window = try #require(NSApp.windows.first { $0.delegate === chat })
            #expect(!(window.firstResponder is NSTextView), "Round \(round): firstResponder must not be NSTextView")

            // 2. Request approval
            let req = ActionApprovalRequest(
                goal: "stress-test round \(round)",
                operation: "Tool: test_action",
                target: "target-\(round)",
                details: "detail-\(round)",
                consequence: "consequence-\(round)"
            )
            let approvalTask = Task {
                await state.requestApproval(req)
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(state.isAwaitingApproval, "Round \(round): state must be awaiting approval")

            // 3. User approves
            state.resolveApproval(req.id, status: .approved)
            let resolvedStatus = await approvalTask.value
            #expect(resolvedStatus == .approved, "Round \(round): resolved status must be approved")

            // 4. Dismiss and wait for surface removal (as Copilot.toolApprover does)
            let removed = await chat.closeAndWaitForSurfaceRemoval()
            #expect(removed, "Round \(round): surface must be confirmed removed from Quartz")
            #expect(!chat.isOpen, "Round \(round): chatWindow must be closed")
            #expect(!state.isChatOpen, "Round \(round): state.isChatOpen must be false")
            #expect(!state.isAwaitingApproval, "Round \(round): isAwaitingApproval must be false")
            #expect(!state.chatInputFocusSuppressed, "Round \(round): chatInputFocusSuppressed must be reset to false")

            // Small cooperative pause between rounds
            try await Task.sleep(for: .milliseconds(30))
        }

        let hangs = hangCount.withLock { $0 }
        if IsolatedTiming.enabled {
            #expect(hangs == 0, "MainThreadWatchdog reported \(hangs) hangs during consecutive approval cycles!")
        }
    }

    @Test("Copilot-style ChatToolApprover executes 4 consecutive rounds without focus trap or lingering surface")
    func copilotStyleToolApproverConsecutiveRounds() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        let approver = ChatToolApprover { [weak chat, weak state] request in
            guard let chat, let state else { return .cancelled }
            chat.presentForApproval()
            let status = await state.requestApproval(request)
            _ = await chat.closeAndWaitForSurfaceRemoval()
            return status
        }

        for round in 1...4 {
            let toolRequest = ToolApprovalRequest(
                toolName: "computer",
                title: "Mouse Click (Round \(round))",
                detail: "click at coordinates (100, 20\(round))"
            )

            let decisionTask = Task {
                await approver.decide(toolRequest)
            }

            // Wait for approval to appear in state
            var pendingId: UUID?
            for _ in 0..<50 where pendingId == nil {
                try await Task.sleep(for: .milliseconds(20))
                pendingId = state.messages.last(where: { $0.approvalStatus == .pending })?.approval?.id
            }
            let reqId = try #require(pendingId, "Round \(round): approval request did not appear in chat")
            #expect(state.isAwaitingApproval, "Round \(round): must be awaiting approval")
            #expect(state.chatInputFocusSuppressed, "Round \(round): focus must be suppressed")

            let window = try #require(NSApp.windows.first { $0.delegate === chat })
            #expect(!(window.firstResponder is NSTextView), "Round \(round): field editor took focus")

            // Resolve
            state.resolveApproval(reqId, status: .approved)
            let decision = await decisionTask.value
            #expect(decision == .approved, "Round \(round): decision must be approved")

            // Verify window dismissed and no linger
            #expect(!chat.isOpen, "Round \(round): chat must not remain open")
            #expect(!state.isChatOpen, "Round \(round): state.isChatOpen must be false")
            #expect(!state.chatInputFocusSuppressed, "Round \(round): focus suppression must be cleared")
        }
    }

    @Test("ToolApprovalUI.restoreFocus cooperative polling yields to MainActor without freezing runloop")
    func restoreFocusCooperativeYielding() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        let hangCount = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = MainThreadWatchdog(
            targetQueue: .main,
            timeoutSeconds: 2,
            pollIntervalSeconds: 1,
            onHang: { _ in
                hangCount.withLock { $0 += 1 }
            }
        )
        watchdog.start()
        defer { watchdog.stop() }

        // Measure cooperative MainActor interleaving while ChatToolApprover runs
        let approver = ChatToolApprover { [weak chat, weak state] request in
            guard let chat, let state else { return .cancelled }
            chat.presentForApproval()
            let status = await state.requestApproval(request)
            _ = await chat.closeAndWaitForSurfaceRemoval()
            return status
        }

        let toolRequest = ToolApprovalRequest(
            toolName: "run_shell",
            title: "Run Script",
            detail: "echo test"
        )

        let approverTask = Task {
            await approver.decide(toolRequest)
        }

        // Concurrently on MainActor, perform multiple cooperative checks
        var interleavingPassed = 0
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            if state.isAwaitingApproval {
                interleavingPassed += 1
                let reqId = state.messages.last(where: { $0.approvalStatus == .pending })?.approval?.id
                if let reqId {
                    state.resolveApproval(reqId, status: .approved)
                }
            }
        }

        let decision = await approverTask.value
        #expect(decision == .approved)
        #expect(interleavingPassed > 0, "MainActor cooperative closures were able to interleave during approval lifecycle")

        let hangs = hangCount.withLock { $0 }
        if IsolatedTiming.enabled {
            #expect(hangs == 0, "restoreFocus triggered watchdog hang!")
        }
    }
}
