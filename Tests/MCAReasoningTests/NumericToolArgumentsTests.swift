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
}
