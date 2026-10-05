import MCAReasoning
import Testing

/// Existing pipeline tests now exercise explicit approval on the scripted driver.
/// The production browser validator still runs; denial and drift have separate tests.
struct ApprovedBrowserTestScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let session = ActionAuthorization(goal: "Scripted browser test", requestApproval: { _ in .approved })
        try await ActionAuthorization.$current.withValue(session) { try await function() }
    }
}
