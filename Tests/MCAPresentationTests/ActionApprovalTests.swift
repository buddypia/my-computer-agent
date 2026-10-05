import Foundation
import MCACore
@testable import MCAPresentation
import Testing

@Suite("Action approval lifecycle")
@MainActor
struct ActionApprovalTests {
    private func request() -> ActionApprovalRequest {
        ActionApprovalRequest(goal: "Update meeting notes", operation: "Overwrite file",
                              target: "/tmp/notes.md", details: "New notes", consequence: "Replace existing contents")
    }

    private func waitForCard(_ state: HUDState) async throws -> ActionApprovalRequest {
        for _ in 0..<1_000 {
            if let card = state.messages.last?.approval { return card }
            await Task.yield()
        }
        throw TestFailure.missingCard
    }

    private enum TestFailure: Error { case missingCard }

    @Test("A second pending operation cannot replace the first approval")
    func singlePending() async throws {
        let state = HUDState(), proposal = request()
        let task = Task { await state.requestApproval(proposal) }
        _ = try await waitForCard(state)
        #expect(state.isAwaitingApproval)
        let second = await state.requestApproval(request())
        #expect(second == .cancelled)
        #expect(state.messages.count == 1)
        state.resolveApproval(proposal.id, status: .rejected)
        #expect(await task.value == .rejected)
        #expect(!state.isAwaitingApproval)
    }

    @Test("Approval resolves once and leaves a resolved card in history")
    func approveOnce() async throws {
        let state = HUDState(), proposal = request()
        let task = Task { await state.requestApproval(proposal) }
        let card = try await waitForCard(state)
        #expect(card == proposal)
        #expect(state.messages.last?.approvalStatus == .pending)
        state.resolveApproval(card.id, status: .approved)
        state.resolveApproval(card.id, status: .rejected)
        #expect(await task.value == .approved)
        #expect(state.messages.last?.approvalStatus == .approved)
    }

    @Test("Reject, task cancellation and card deletion release the waiter without approval")
    func rejectCancelDelete() async throws {
        for method in ["reject", "cancel", "delete", "clear", "deleteThrough", "deleteRole"] {
            let deferredExpiry = AsyncStream<Void>.makeStream()
            defer { deferredExpiry.continuation.finish() }
            let stream = deferredExpiry.stream
            let state = HUDState(approvalSleepUntil: { _ in
                for await _ in stream { break }
                try Task.checkCancellation()
            }), proposal = request()
            let task = Task { await state.requestApproval(proposal, timeout: .milliseconds(100)) }
            defer { task.cancel() }
            _ = try await waitForCard(state)
            if method == "cancel" {
                // A delayed setup must not allow expiry delivery to replace the
                // cancellation outcome this test specifically exercises.
                try await Task.sleep(for: .milliseconds(150))
            }
            switch method {
            case "reject": state.resolveApproval(proposal.id, status: .rejected)
            case "cancel": task.cancel()
            case "delete": state.removeMessage(proposal.id)
            case "deleteThrough": state.removeMessages(upThrough: proposal.id)
            case "deleteRole": state.removeMessages(ofRole: [.notice])
            default: state.clearChat()
            }
            let status = await task.value
            #expect(status == (method == "reject" ? .rejected : .cancelled))
        }
    }

    @Test("Unknown request IDs cannot resolve a different pending operation")
    func wrongID() async throws {
        let state = HUDState(), proposal = request()
        let task = Task { await state.requestApproval(proposal) }
        _ = try await waitForCard(state)
        state.resolveApproval(UUID(), status: .approved)
        #expect(state.messages.last?.approvalStatus == .pending)
        state.resolveApproval(proposal.id, status: .rejected)
        #expect(await task.value == .rejected)
    }

    @Test("An unanswered approval expires as denial")
    func expiration() async {
        let state = HUDState()
        let result = await state.requestApproval(request(), timeout: .milliseconds(5))
        #expect(result == .expired)
        #expect(state.messages.last?.approvalStatus == .expired)
    }

    @Test("Cancellation after delivered expiry cannot overwrite its denial")
    func expiryBeforeCancellation() async {
        let state = HUDState(), proposal = request()
        let task = Task { await state.requestApproval(proposal, timeout: .milliseconds(5)) }
        defer { task.cancel() }
        #expect(await task.value == .expired)
        task.cancel()
        state.resolveApproval(proposal.id, status: .approved)
        #expect(state.messages.last?.approvalStatus == .expired)
        #expect(!state.isAwaitingApproval)
    }
}
