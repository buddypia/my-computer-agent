import MCACore
import MCAReasoning
@testable import mca
import Testing

@Suite("Copilot display collection scope")
@MainActor
struct CopilotScopedCollectionTests {
    @Test("Missing local action target rejects before screen permission or target resolution")
    func noLocalCollectionWindow() async throws {
        let copilot = Copilot(configuration: AgentConfiguration())
        let session = ActionAuthorization(goal: "Collect selected display", requestApproval: { _ in .rejected },
            targetWindow: nil, requiresWindowScope: true)
        await ActionAuthorization.withSession(session) {
            await #expect(throws: ActionAuthorizationError.staleTarget) {
                _ = try await copilot.collectWindowContent(steps: 1, deltaY: -10, delayMs: 100)
            }
        }
    }
}
