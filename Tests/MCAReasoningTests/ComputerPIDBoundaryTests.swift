import Foundation
import Testing
@testable import MCAReasoning

@Suite("Computer PID argument boundaries")
struct ComputerPIDBoundaryTests {
    @Test("Malformed or out-of-range PID fails before approval or input", arguments: ["target_pid", "pid"])
    func invalidPID(_ key: String) async throws {
        for value in [Int64(Int32.max) + 1, Int64(Int32.min) - 1, 0, -1] {
            let registry = ToolRegistry(tools: [ComputerActionTool()])
            let call = ToolCall(id: "invalid-pid", name: "computer", arguments:
                try JSONSerialization.data(withJSONObject: ["action": "scroll", "coordinate": [1, 1], key: value]))
            let result = await registry.invoke(call)
            #expect(result.content.contains("Error: 'target_pid'/'pid' must be a positive 32-bit integer"))
            #expect(!result.content.contains("Scrolled"))
        }
    }
}
