import Foundation
import MCAMemory
import Testing
@testable import MCAReasoning

@Suite("Public search result limit refusal")
struct NegativeResultLimitTests {
    @Test("Nonpositive file limits reject before Spotlight or FileManager search")
    func fileSearch() async throws {
        for limit in [Int.min, -1, 0] {
            let result = try await FindFilesTool().invoke(arguments: JSONSerialization.data(withJSONObject:
                ["query": "owned-limit-fixture", "limit": limit, "search_path": "/nonexistent-owned-limit-fixture"]))
            #expect(result == "Error: 'limit' must be positive.")
        }
    }
    @Test("Nonpositive history limits reject before context search")
    func historySearch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mca-limit-\(UUID().uuidString).sqlite")
        let store = try SQLiteContextStore(url: url)
        for limit in [Int.min, -1, 0] {
            let result = try await SearchContextTool(store: store).invoke(arguments: JSONSerialization.data(withJSONObject:
                ["query": "owned-limit-fixture", "limit": limit]))
            #expect(result == "Error: 'limit' must be positive.")
        }
    }
}
