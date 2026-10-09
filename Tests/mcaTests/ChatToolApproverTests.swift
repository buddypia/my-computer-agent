import Foundation
import MCACore
import MCAPresentation
import MCAReasoning
@testable import mca
import Testing

@Suite("Tool approval in the chat")
@MainActor
struct ChatToolApproverTests {
    private let request = ToolApprovalRequest(
        toolName: "run_applescript", title: "Run AppleScript", detail: "tell application \"Firefox\" to activate")

    private func approver(_ state: HUDState) -> ChatToolApprover {
        ChatToolApprover { await state.requestApproval($0) }
    }

    /// Waits on the main actor, which is the point: the modal alert this
    /// replaced held the main thread, so nothing here could have run.
    private func pendingApproval(in state: HUDState) async throws -> ActionApprovalRequest {
        for _ in 0..<200 {
            if let pending = state.messages.last(where: { $0.approvalStatus == .pending })?.approval {
                return pending
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the approval request never appeared in the chat")
        throw CancellationError()
    }

    @Test("The request is shown in the chat with the exact detail, and approving it runs the tool")
    func approve() async throws {
        let state = HUDState()
        let decision = Task { await approver(state).decide(request) }
        let pending = try await pendingApproval(in: state)
        #expect(state.isAwaitingApproval)
        #expect(pending.details == request.detail)
        #expect(pending.operation == request.title)
        state.resolveApproval(pending.id, status: .approved)
        #expect(await decision.value == .approved)
    }

    @Test("Rejecting the request denies the tool")
    func reject() async throws {
        let state = HUDState()
        let decision = Task { await approver(state).decide(request) }
        let pending = try await pendingApproval(in: state)
        state.resolveApproval(pending.id, status: .rejected)
        #expect(await decision.value == .denied(reason: "the user declined"))
    }

    @Test("Stopping the task cancels a waiting approval instead of leaving it open")
    func stopCancels() async throws {
        let state = HUDState()
        let decision = Task { await approver(state).decide(request) }
        _ = try await pendingApproval(in: state)
        state.cancelPendingApprovals()
        guard case .denied = await decision.value else {
            Issue.record("a cancelled approval must not run the tool")
            return
        }
        #expect(!state.isAwaitingApproval)
    }
}
