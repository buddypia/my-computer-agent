import Foundation
import MCACore
import Testing
@testable import MCAReasoning

@Suite("Display-scoped collection refusal")
struct ScopedCollectionTests {
    private actor Calls { var count = 0; func add() { count += 1 } }
    @Test("A remote/display context cannot resolve a different local collection window")
    func missingLocalTarget() async throws {
        let calls = Calls()
        let tool = ScrollPageContentTool(collector: { _, _, _, _ in
            await calls.add(); return "UNRELATED_LOCAL_VIEWPORT"
        })
        let session = ActionAuthorization(goal: "Collect selected display", requestApproval: { _ in .rejected },
            targetWindow: nil, requiresWindowScope: true)
        let registry = ToolRegistry(tools: [tool])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "display-collection", name: "scroll_page_content", arguments: Data("{}".utf8)))
        }
        #expect(result.content.hasPrefix("Error:"))
        #expect(!result.content.contains("UNRELATED_LOCAL_VIEWPORT"))
        #expect(await calls.count == 0)
        #expect(await session.terminalFailure != nil)
    }
}
