import Foundation
import MCACore
@testable import MCAPresentation
import Testing

@Suite("Approval deadline enforcement")
@MainActor
struct ApprovalDeadlineTests {
    @Test("Approval after the deadline is denied even before the expiry task runs", arguments: [false, true])
    func lateApproval(delayedSetup: Bool) async throws {
        let deferredExpiry = AsyncStream<Void>.makeStream()
        defer { deferredExpiry.continuation.finish() }
        let stream = deferredExpiry.stream
        let state = HUDState(approvalSleepUntil: { _ in
            // Hold expiry delivery independently of setup scheduling. Cancelling
            // the approval timer releases AsyncStream's suspended iterator.
            for await _ in stream { break }
            try Task.checkCancellation()
        })
        let request = ActionApprovalRequest(goal: "Update notes", operation: "Overwrite",
            target: "/tmp/deadline-notes.md", details: "Replacement", consequence: "Overwrite file")
        let task = Task { await state.requestApproval(request, timeout: .milliseconds(10)) }
        defer { task.cancel() }
        let observationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.messages.last?.approval?.id != request.id {
            try #require(ContinuousClock.now < observationDeadline, "Approval card must appear")
            await Task.yield()
        }
        if delayedSetup {
            // Reproduce the setup delay that invalidated the original pending
            // precondition; controlled expiry must keep this card pending.
            try await Task.sleep(for: .milliseconds(30))
        }

        // Keep MainActor occupied past the deadline, so the expiry task cannot
        // resolve the card before the same actor receives this approval.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(30))
        while ContinuousClock.now < deadline {}
        #expect(state.messages.last?.approvalStatus == .pending)
        state.resolveApproval(request.id, status: .approved)

        #expect(await task.value == .expired)
        #expect(state.messages.last?.approvalStatus == .expired)
        #expect(!state.isAwaitingApproval)
        state.resolveApproval(request.id, status: .approved)
        #expect(state.messages.last?.approvalStatus == .expired)
    }
}
