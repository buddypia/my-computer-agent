import Foundation
import MCACore
import MCAReasoning
import Testing

@Suite("Execution authorization")
struct ActionAuthorizationTests {
    @Test("A task cannot dispatch more than its shared action budget")
    func budget() async throws {
        let session = ActionAuthorization(goal: "Bounded work", requestApproval: { _ in .approved })
        for _ in 0..<20 { try await session.consumeAction() }
        await #expect(throws: ActionAuthorizationError.budgetExceeded) { try await session.consumeAction() }
        #expect(await session.terminalFailure != nil)
    }

    @Test("Unsafe noninteractive calls fail closed")
    func noninteractive() async {
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await ActionAuthorization.requireApproval(operation: "Delete", target: "file", details: "Remove file")
        }
    }

    @Test("A denied operation never reaches the mutation")
    func rejected() async {
        let session = ActionAuthorization(goal: "Delete a file", requestApproval: { _ in .rejected })
        await ActionAuthorization.$current.withValue(session) {
            await #expect(throws: ActionAuthorizationError.denied) {
                try await ActionAuthorization.requireApproval(operation: "Delete", target: "file", details: "Remove file")
            }
        }
    }

    @Test("Approval is invalidated when preconditions change")
    func staleApproval() async {
        let session = ActionAuthorization(goal: "Update notes", requestApproval: { _ in .approved })
        await ActionAuthorization.$current.withValue(session) {
            await #expect(throws: ActionAuthorizationError.staleTarget) {
                try await ActionAuthorization.requireApproval(operation: "Overwrite", target: "notes", details: "New contents", revalidate: { false })
            }
        }
    }

    @Test("Approved exact operation passes after revalidation")
    func approved() async throws {
        let session = ActionAuthorization(goal: "Update notes", requestApproval: { proposal in
            #expect(proposal.goal == "Update notes")
            #expect(proposal.details == "New contents")
            return .approved
        })
        try await ActionAuthorization.$current.withValue(session) {
            try await ActionAuthorization.requireApproval(operation: "Overwrite", target: "notes", details: "New contents", revalidate: { true })
        }
    }
}
