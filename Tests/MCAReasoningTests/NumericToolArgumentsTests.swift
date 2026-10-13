import Foundation
import MCACore
import MCASensing
import Testing
@testable import MCAReasoning

@Suite("Numeric tool argument validation")
struct NumericToolArgumentsTests {
    @Test("Out-of-range JSON Double cannot crash a collector-free public tool")
    func hugeDouble() async throws {
        for key in ["steps", "delay_ms"] {
            let result = try await ScrollPageContentTool().invoke(arguments: Data("{\"\(key)\":1e100}".utf8))
            #expect(result == "Error: Background scrolling collector is not configured.")
        }
    }
    @Test("Candidate limits are bounded before an injected inspector runs", arguments: [-1, Int.max])
    func candidateLimits(_ input: Int) async throws {
        let tool = InspectUIElementsTool(inspectorProvider: { limit in
            #expect(limit == (input < 0 ? 1 : 25))
            return MockUIInspector(snapshots: [UIStateSnapshot(visibleCandidates: [])])
        })
        let result = try await tool.invoke(arguments: JSONSerialization.data(withJSONObject: ["max_candidates": input]))
        #expect(result == "[\n\n]")
        #expect(AccessibilityInspector(maxCandidates: input).maxCandidates == (input < 0 ? 0 : 100))
    }

    @Test("Out-of-range coordinates and scroll deltas in ComputerActionTool do not trap")
    func computerActionNumericBounds() async throws {
        let tool = ComputerActionTool()
        let badMove = try await tool.invoke(arguments: Data(#"{"action":"mouse_move","coordinate":[1e100,100]}"#.utf8))
        #expect(badMove.contains("Error: 'coordinate' [x, y] is required"))

        let badDrag = try await tool.invoke(arguments: Data(#"{"action":"left_click_drag","start_coordinate":[0,0],"coordinate":[1e100,0]}"#.utf8))
        #expect(badDrag.contains("Error: Both 'start_coordinate' and 'coordinate' are required"))

        let parsed: [String: Any] = ["delta_y": 1e100, "delta_x": -1e100, "bool": true]
        #expect(parsed.clampedInt32("delta_y") == Int32.max)
        #expect(parsed.clampedInt32("delta_x") == Int32.min)
        #expect(parsed.clampedInt32("bool") == nil)
    }
}
