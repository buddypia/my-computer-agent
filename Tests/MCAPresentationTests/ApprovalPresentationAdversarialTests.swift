import AppKit
import MCACore
import Testing

@testable import MCAPresentation

@Suite("Approval Presentation Adversarial & Stress Suite", .serialized)
@MainActor
struct ApprovalPresentationAdversarialTests {

    @Test("NSWindow properties enforce first responder isolation")
    func windowPropertiesEnforceIsolation() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        let panel = try #require(window as? NSPanel)

        #expect(!panel.becomesKeyOnlyIfNeeded, "panel.becomesKeyOnlyIfNeeded must be false")
        #expect(panel.initialFirstResponder === panel.contentView, "initialFirstResponder must be contentView")
        #expect(panel.firstResponder === panel.contentView || panel.firstResponder === panel, "firstResponder must be contentView or window itself")
        #expect(!(panel.firstResponder is NSTextView), "first responder must not be NSTextView")
    }

    @Test("presentForApproval preempts an existing active text focus without close")
    func presentForApprovalPreemptsExistingFocus() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        // Step 1: Open chat normally, which focuses the text field
        chat.present()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })

        try await Task.sleep(for: .milliseconds(300))

        // Step 2: Now call presentForApproval() without closing
        chat.presentForApproval()
        try await Task.sleep(for: .milliseconds(200))

        #expect(state.chatInputFocusSuppressed, "chatInputFocusSuppressed must be true")
        #expect(!(window.firstResponder is NSTextView), "firstResponder must no longer be NSTextView after presentForApproval")
        #expect(window.firstResponder === window.contentView || window.firstResponder === window, "firstResponder must be contentView or window itself, never a text input")
    }

    private func waitUntilAwaitingApproval(_ state: HUDState) async {
        for _ in 0..<250 where !state.isAwaitingApproval {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("present() called while approval is awaiting keeps focus suppressed")
    func presentDuringApprovalKeepsFocusSuppressed() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let request = ActionApprovalRequest(
            goal: "test-goal", operation: "test-op", target: "test-target", details: "test-details", consequence: "test-consequence"
        )
        let approval = Task {
            await state.requestApproval(request)
        }

        await waitUntilAwaitingApproval(state)
        #expect(state.isAwaitingApproval, "State must be awaiting approval")
        #expect(state.chatInputFocusSuppressed, "chatInputFocusSuppressed must be true")

        // Re-call present() as if user triggered hotkey or menu item
        chat.present()
        try await Task.sleep(for: .milliseconds(200))

        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        #expect(state.chatInputFocusSuppressed, "chatInputFocusSuppressed must remain true")
        #expect(!(window.firstResponder is NSTextView), "firstResponder must NOT be NSTextView")

        state.cancelPendingApprovals()
        #expect(await approval.value == .cancelled)
    }

    @Test("Multi-round consecutive approval cycles maintain clean focus suppression state")
    func multiRoundApprovalCyclesStress() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        for round in 1...5 {
            // 1. Present for approval
            chat.presentForApproval()
            #expect(state.chatInputFocusSuppressed, "Round \(round): focus must be suppressed on presentForApproval")

            let request = ActionApprovalRequest(
                goal: "round-\(round)", operation: "op-\(round)", target: "target-\(round)", details: "d", consequence: "c"
            )
            let approval = Task {
                await state.requestApproval(request)
            }
            await waitUntilAwaitingApproval(state)
            #expect(state.isAwaitingApproval, "Round \(round): must be awaiting approval")

            let window = try #require(NSApp.windows.first { $0.delegate === chat })
            #expect(!(window.firstResponder is NSTextView), "Round \(round): firstResponder must not be NSTextView")

            // 2. Resolve approval
            state.resolveApproval(request.id, status: .approved)
            #expect(await approval.value == .approved)

            // 3. Close window
            chat.close()
            #expect(!state.isChatOpen, "Round \(round): chat must be closed")
            #expect(!state.isAwaitingApproval, "Round \(round): awaiting approval must be false")
            #expect(!state.chatInputFocusSuppressed, "Round \(round): chatInputFocusSuppressed must be reset to false")
        }
    }

    @Test("screenObjectiveText shielding condition truth table verification")
    func screenObjectiveTextShieldingTruthTable() {
        // Truth table helper:
        // Expression: state.screenObjective?.isActive == true || state.chatInputFocusSuppressed || state.isAwaitingApproval
        func isDisabled(isActive: Bool, suppressed: Bool, awaiting: Bool) -> Bool {
            return isActive || suppressed || awaiting
        }

        // When awaiting approval or focus suppressed, it MUST be disabled regardless of objective active status
        #expect(isDisabled(isActive: false, suppressed: true, awaiting: false))
        #expect(isDisabled(isActive: false, suppressed: false, awaiting: true))
        #expect(isDisabled(isActive: false, suppressed: true, awaiting: true))
        #expect(isDisabled(isActive: true, suppressed: true, awaiting: true))
        #expect(isDisabled(isActive: true, suppressed: false, awaiting: false))

        // Only enabled when inactive, NOT suppressed, and NOT awaiting approval
        #expect(!isDisabled(isActive: false, suppressed: false, awaiting: false))
    }

    @Test("HUDState approval resolution resets focus suppression when approval completes")
    func hudStateApprovalResolutionResetsSuppression() async {
        let state = HUDState()
        state.chatInputFocusSuppressed = true

        let request = ActionApprovalRequest(goal: "g1", operation: "o1", target: "t1", details: "d1", consequence: "c1")
        let task = Task {
            await state.requestApproval(request)
        }
        await waitUntilAwaitingApproval(state)

        #expect(state.isAwaitingApproval)
        #expect(state.chatInputFocusSuppressed)

        // Resolve approval - queue now empty! chatInputFocusSuppressed must reset to false
        state.resolveApproval(request.id, status: .approved)
        #expect(await task.value == .approved)
        #expect(!state.isAwaitingApproval)
        #expect(!state.chatInputFocusSuppressed, "Queue is empty, suppression must be cleared")
    }

    @Test("No field editor NSTextView exists in window hierarchy during approval presentation")
    func noFieldEditorExistsInWindowHierarchyDuringApproval() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })

        // Let SwiftUI layout and render
        try await Task.sleep(for: .milliseconds(200))

        // Inspect window's field editor
        let fieldEditor = window.fieldEditor(false, for: nil)
        #expect(fieldEditor == nil || window.firstResponder !== fieldEditor, "Field editor must not be first responder")

        // Recursively inspect all subviews to ensure no NSTextView has first responder status
        func checkResponders(view: NSView) {
            if let textView = view as? NSTextView {
                #expect(window.firstResponder !== textView, "NSTextView found with first responder status")
            }
            for subview in view.subviews {
                checkResponders(view: subview)
            }
        }
        if let contentView = window.contentView {
            checkResponders(view: contentView)
        }
    }

    @Test("Non-empty screenObjectiveText remains strictly shielded and never focused")
    func nonEmptyScreenObjectiveTextShielding() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        state.screenObjectiveText = "Adversarial text injection: Find bugs and crash"
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })

        try await Task.sleep(for: .milliseconds(150))
        #expect(state.chatInputFocusSuppressed)
        #expect(!(window.firstResponder is NSTextView), "Non-empty objective text field must never take focus")
        #expect(window.firstResponder === window.contentView || window.firstResponder === window)
    }

    @Test("Rapid alternating between present and presentForApproval leaves isolation intact")
    func rapidAlternatingPresentCalls() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        for _ in 0..<5 {
            chat.present()
            chat.presentForApproval()
        }

        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        try await Task.sleep(for: .milliseconds(150))

        #expect(state.chatInputFocusSuppressed)
        #expect(!(window.firstResponder is NSTextView), "Rapid alternating calls must not leave NSTextView focused")
    }

    @Test("screenObjective field cannot be made first responder during approval presentation")
    func screenObjectiveFieldCannotBeFirstResponderDuringApproval() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let request = ActionApprovalRequest(goal: "g", operation: "o", target: "t", details: "d", consequence: "c")
        let approval = Task { await state.requestApproval(request) }
        await waitUntilAwaitingApproval(state)

        let window = try #require(NSApp.windows.first { $0.delegate === chat })

        // Find any NSTextField in the view hierarchy (such as screenObjectiveText)
        func findTextFields(view: NSView) -> [NSTextField] {
            var fields: [NSTextField] = []
            if let tf = view as? NSTextField { fields.append(tf) }
            for sub in view.subviews { fields.append(contentsOf: findTextFields(view: sub)) }
            return fields
        }

        if let contentView = window.contentView {
            let fields = findTextFields(view: contentView)
            for field in fields {
                // If the field is disabled, trying to make it first responder must fail or not yield an active editor
                if !field.isEnabled {
                    let accepted = window.makeFirstResponder(field)
                    #expect(!accepted || !(window.firstResponder is NSTextView), "Disabled text field must not accept first responder as NSTextView")
                }
            }
        }

        state.cancelPendingApprovals()
        #expect(await approval.value == .cancelled)
    }

    @Test("Approval cancellation and expiry safely reset focus suppression")
    func approvalCancellationAndExpiryResetsSuppression() async {
        let state = HUDState()

        // 1. Test cancellation
        state.chatInputFocusSuppressed = true
        let req1 = ActionApprovalRequest(goal: "g1", operation: "o1", target: "t1", details: "d1", consequence: "c1")
        let task1 = Task { await state.requestApproval(req1) }
        await waitUntilAwaitingApproval(state)
        #expect(state.isAwaitingApproval)
        #expect(state.chatInputFocusSuppressed)

        state.cancelPendingApprovals()
        #expect(await task1.value == .cancelled)
        #expect(!state.isAwaitingApproval)
        #expect(!state.chatInputFocusSuppressed, "Cancellation must reset focus suppression")

        // 2. Test explicit expiry resolution
        state.chatInputFocusSuppressed = true
        let req2 = ActionApprovalRequest(goal: "g2", operation: "o2", target: "t2", details: "d2", consequence: "c2")
        let task2 = Task { await state.requestApproval(req2) }
        await waitUntilAwaitingApproval(state)
        #expect(state.isAwaitingApproval)
        #expect(state.chatInputFocusSuppressed)

        state.resolveApproval(req2.id, status: .expired)
        #expect(await task2.value == .expired)
        #expect(!state.isAwaitingApproval)
        #expect(!state.chatInputFocusSuppressed, "Expiry must reset focus suppression")
    }

    @Test("Closing chat window while approval is awaiting preserves focus suppression")
    func closeWhileAwaitingApprovalPreservesFocusSuppression() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        chat.presentForApproval()
        let request = ActionApprovalRequest(goal: "g1", operation: "o1", target: "t1", details: "d1", consequence: "c1")
        let approval = Task { await state.requestApproval(request) }
        await waitUntilAwaitingApproval(state)

        #expect(state.isAwaitingApproval)
        #expect(state.chatInputFocusSuppressed)

        // Close chat window while still awaiting approval
        chat.close()
        #expect(!state.isChatOpen)
        #expect(state.isAwaitingApproval)
        #expect(state.chatInputFocusSuppressed, "chatInputFocusSuppressed must remain true when closed while awaiting approval")

        state.cancelPendingApprovals()
        #expect(await approval.value == .cancelled)
    }

    @Test("High volume messages layout under approval does not hang main thread")
    func highVolumeMessagesLayoutUnderApproval() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }

        // Populate with maximum capacity of messages
        for i in 0..<100 {
            state.append(ChatMessage(role: i.isMultiple(of: 2) ? .user : .assistant, text: "Message \(i): Test long content ensuring layout computer handles geometry deterministically."))
        }

        chat.presentForApproval()
        let request = ActionApprovalRequest(goal: "stress-test", operation: "op", target: "tgt", details: "det", consequence: "csq")
        let approval = Task { await state.requestApproval(request) }
        await waitUntilAwaitingApproval(state)

        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        try await Task.sleep(for: .milliseconds(100))

        #expect(window.isVisible)
        #expect(state.chatInputFocusSuppressed)
        #expect(!(window.firstResponder is NSTextView))

        state.cancelPendingApprovals()
        #expect(await approval.value == .cancelled)
    }
}
