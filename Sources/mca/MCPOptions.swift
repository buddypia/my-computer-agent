import Foundation
import MCACore

/// An explicit config lets MCP clients (including live acceptance) use their
/// own database without changing the user's saved settings or context store.
struct MCPOptions {
    var computerUse = false
    var configURL: URL?

    static func parse(_ arguments: [String]) throws -> MCPOptions {
        var options = MCPOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--computer-use": options.computerUse = true
            case "--config":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--"), options.configURL == nil else {
                    throw OptionsError("--config requires exactly one file path")
                }
                options.configURL = URL(fileURLWithPath: arguments[index])
            default: throw OptionsError("Unknown MCP option: \(arguments[index])")
            }
            index += 1
        }
        return options
    }

    func configuration() throws -> AgentConfiguration {
        if let configURL {
            // AgentConfiguration.load normally treats a missing file as a fresh
            // install. An explicit path must fail instead of opening the user DB.
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                throw OptionsError("Explicit MCP configuration does not exist")
            }
            return try AgentConfiguration.load(from: configURL)
        }
        return (try? AgentConfiguration.load()) ?? AgentConfiguration()
    }

    struct OptionsError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
