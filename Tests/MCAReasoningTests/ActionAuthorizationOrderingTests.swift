import Foundation
import MCACore
import MCAReasoning
import Testing

@Suite("Execution authorization ordering")
struct ActionAuthorizationOrderingTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("Approved but unverifiable is refused as stale, as before")
    func approvedWithoutValidator() async {
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in .approved })
        await ActionAuthorization.$current.withValue(session) {
            await #expect(throws: ActionAuthorizationError.staleTarget) {
                try await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d")
            }
        }
        #expect(await session.terminalFailure != nil)
    }

    @Test("An exhausted budget is reported after approval, as before")
    func budgetAfterApproval() async {
        let asked = Counter()
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in asked.increment(); return .approved },
                                          actionBudget: 0)
        await ActionAuthorization.$current.withValue(session) {
            await #expect(throws: ActionAuthorizationError.budgetExceeded) {
                try await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d", revalidate: { true })
            }
        }
        #expect(asked.count == 1)
    }

    @Test("A caller's validator cannot waive the session's validator")
    func bothValidatorsApply() async {
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in .approved }, validateTarget: { false })
        await ActionAuthorization.$current.withValue(session) {
            await #expect(throws: ActionAuthorizationError.staleTarget) {
                try await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d", revalidate: { true })
            }
        }
    }

    @Test("The first failure is kept as the reason")
    func firstFailureKept() async {
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in .rejected })
        await ActionAuthorization.$current.withValue(session) {
            _ = try? await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d", revalidate: { true })
            _ = try? await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d", revalidate: { true })
        }
        #expect(await session.terminalFailure == ActionAuthorizationError.denied.localizedDescription)
        await session.abort(ActionAuthorizationError.budgetExceeded)
        #expect(await session.terminalFailure == ActionAuthorizationError.denied.localizedDescription)
    }

    @Test("An approved action consumes exactly one unit of budget")
    func approvedConsumesOne() async throws {
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in .approved }, actionBudget: 1)
        try await ActionAuthorization.$current.withValue(session) {
            try await ActionAuthorization.requireApproval(operation: "o", target: "t", details: "d", revalidate: { true })
        }
        await #expect(throws: ActionAuthorizationError.budgetExceeded) { try await session.consumeAction() }
    }
}
