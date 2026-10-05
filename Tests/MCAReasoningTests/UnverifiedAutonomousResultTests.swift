import Foundation
import MCACore
import MCAMemory
import Testing
@testable import MCAReasoning

@Suite("Autonomous result evidence in each language")
struct UnverifiedAutonomousResultTests {
    @Test("Timeout output cannot become a completed autonomous task", arguments: [Language.english, .japanese, .korean])
    func timeout(_ language: Language) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteContextStore(url: path), counter = StepCounter()
        let executor = MockScriptedExecutor { _, channel in
            if counter.increment() == 1 {
                channel.send(.toolCall(ToolCall(id: "timeout", name: "typesafe_act", arguments: Data("{}".utf8))))
                channel.send(.finished(.toolCalls))
            } else { channel.send(.finished(.stop)) }
        }
        struct TimeoutTool: AgentTool {
            var definition: ToolDefinition { .init(name: "typesafe_act", description: "Owned timeout fixture", parameters: Data("{}".utf8)) }
            func invoke(arguments: Data) async throws -> String { "Timed out after 15 seconds" }
        }
        let router = ModelRouter(policy: RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")]),
            credentials: .empty, customResolver: { _ in executor })
        let agent = Agent(router: router, store: store, tools: ToolRegistry(tools: [TimeoutTool()]),
            health: HealthRegistry(), language: language)
        let answer = try await agent.answer("Perform the requested task", isAutonomousAction: true)
        #expect(answer.contains("Timed out after 15 seconds"))
        #expect(!answer.contains("자율 조작을 완료했습니다"))
        #expect(!answer.contains("Completed"))
        #expect(!answer.contains("完了しました"))
        #expect(counter.value >= 2)
    }
}
