import MCACore
import MCAReasoning
@testable import mca
import Testing

@Suite("Copilot display observation scope")
@MainActor
struct CopilotScopedReadTests {
    @Test("A selected display does not authorize reading any local foreground window")
    func noLocalWindow() async throws {
        let copilot = Copilot(configuration: AgentConfiguration())
        let session = ActionAuthorization(goal: "Read selected display", requestApproval: { _ in .rejected },
            targetWindow: nil, requiresWindowScope: true)
        let result = await ActionAuthorization.withSession(session) { await copilot.readCurrentScreenLive() }
        #expect(result?.contains("Error: selected window") == true)
        #expect(result?.contains("No local window was read") == true)
    }
}
