import Foundation
import MCACore
import Testing
@testable import mca

@Suite("MCP configuration isolation")
struct MCPOptionsTests {
    @Test("An explicit missing config fails instead of opening the user's context DB")
    func missingConfigFailsClosed() throws {
        let options = try MCPOptions.parse(["--computer-use", "--config", "/nonexistent-\(UUID())/config.json"])
        #expect(options.computerUse)
        #expect(throws: MCPOptions.OptionsError.self) { try options.configuration() }
    }

    @Test("Missing paths, repeated config and unknown flags are rejected", arguments: [
        ["--config"], ["--config", "--computer-use"], ["--config", "a", "--config", "b"], ["--dangerous"]
    ])
    func invalidArguments(arguments: [String]) {
        #expect(throws: MCPOptions.OptionsError.self) { try MCPOptions.parse(arguments) }
    }

    @Test("A private config keeps its database, opt-in and capture exclusions")
    func privateConfig() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        let database = folder.appendingPathComponent("isolated.sqlite3")
        var config = AgentConfiguration(databaseURL: database)
        config.excludedWindowPatterns = ["acceptance exclusion"]
        try config.save(to: url)
        let options = try MCPOptions.parse(["--config", url.path])
        let loaded = try options.configuration()
        #expect(loaded.databaseURL == database)
        #expect(!options.computerUse)
        #expect(!loaded.mcpAllowDangerousTools)
        #expect(loaded.isExcluded(bundleID: nil, windowTitle: "acceptance exclusion"))
        try Data("not JSON".utf8).write(to: url)
        #expect(throws: MCPOptions.OptionsError.self) { try options.configuration() }
    }
}
