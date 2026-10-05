import Foundation
import MCACore
import MCAMemory
import MCASensing

/// A capability the model can invoke mid-generation.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    func invoke(arguments: Data) async throws -> String
}

/// Registry plus the call/response loop.
///
/// Kept separate from the executors so a tool is written once and works with
/// every provider — Gemini function declarations, Anthropic tool_use blocks and
/// OpenAI function calls all reduce to this.
public actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]

    public init(tools: [any AgentTool] = []) {
        for tool in tools { self.tools[tool.definition.name] = tool }
    }

    public func register(_ tool: any AgentTool) {
        tools[tool.definition.name] = tool
    }

    public func definitions() -> [ToolDefinition] {
        tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    public func invoke(_ call: ToolCall) async -> ToolOutput {
        guard let tool = tools[call.name] else {
            return ToolOutput(
                callID: call.id, name: call.name,
                content: "Error: no tool named '\(call.name)' is registered")
        }
        do {
            try Task.checkCancellation()
            if await ActionAuthorization.current?.terminalFailure != nil {
                throw ActionAuthorizationError.denied
            }
            try Task.checkCancellation()
            let result = try await tool.invoke(arguments: call.arguments)
            return ToolOutput(callID: call.id, name: call.name, content: result)
        } catch {
            if error is ActionAuthorizationError || error is CancellationError { await ActionAuthorization.current?.abort(error) }
            // Errors are returned to the model rather than thrown: a failed
            // tool call is information the model can recover from, and killing
            // the turn instead would lose the whole response.
            return ToolOutput(
                callID: call.id, name: call.name,
                content: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Built-in tools

/// Searches the user's own recorded history.
///
/// This is the tool that turns the agent from "a chatbot that can see one
/// screen" into something that remembers. It is also exposed over MCP so
/// external agents get the same capability.
public struct SearchContextTool: AgentTool {
    private let store: any ContextStoring
    /// When present, the query is expanded on-device before searching, so the
    /// user's phrasing does not have to match the recorded wording.
    private let expanded: ExpandedSearch?

    public init(store: any ContextStoring, expander: QueryExpander? = nil) {
        self.store = store
        self.expanded = expander.map { ExpandedSearch(store: store, expander: $0) }
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "search_context",
            description: """
                Search the user's recorded screen and audio history. Use this \
                whenever the user refers to something they saw, read, or \
                discussed earlier — "that error from before", "what did we \
                decide in the meeting", "the config I was looking at".
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "query": {
                      "type": "string",
                      "description": "Natural language search terms."
                    },
                    "minutes_ago": {
                      "type": "integer",
                      "description": "Only search the last N minutes. Omit to search everything."
                    },
                    "app_name": {
                      "type": "string",
                      "description": "Restrict to one application, e.g. 'Slack'."
                    },
                    "limit": {
                      "type": "integer",
                      "description": "Maximum results (default 15)."
                    }
                  },
                  "required": ["query"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let query = parsed.string("query") else {
            return "Error: 'query' is required"
        }

        if let limit = parsed.int("limit"), limit <= 0 {
            return "Error: 'limit' must be positive."
        }
        let since = parsed.int("minutes_ago").map {
            Date().addingTimeInterval(-Double($0) * 60)
        }
        let contextQuery = ContextQuery(
            text: query,
            since: since,
            appName: parsed.string("app_name"),
            limit: min(parsed.int("limit") ?? 15, 50))

        let results: [ScoredObservation]
        if let expanded {
            results = try await expanded.search(contextQuery)
        } else {
            results = try await store.search(contextQuery)
        }

        guard !results.isEmpty else {
            return "No matching history found for '\(query)'."
        }
        return results.map { ContextFormatter.line(for: $0.observation) }
            .joined(separator: "\n")
    }
}

/// Reads what is on screen right now.
public struct CurrentScreenTool: AgentTool {
    public typealias LiveReader = @Sendable () async throws -> String?

    private let store: any ContextStoring
    private let liveReader: LiveReader?

    public init(store: any ContextStoring, liveReader: LiveReader? = nil) {
        self.store = store
        self.liveReader = liveReader
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "read_current_screen",
            description: """
                Read the text currently visible in the user's focused window. \
                Use when the user says "this", "here", "what I'm looking at".
                """,
            parameters: Data(#"{"type":"object","properties":{}}"#.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        try Task.checkCancellation()
        let session = ActionAuthorization.current
        let scoped = session?.requiresWindowScope == true || session?.targetWindow != nil
        if session?.requiresWindowScope == true && session?.targetWindow == nil {
            return "Error: selected window is unavailable; use the selected display image already provided. No local window was read."
        }
        if let liveReader {
            do {
                if let liveText = try await liveReader(), !liveText.isEmpty {
                    try Task.checkCancellation()
                    return PrivacyFilter().redactSensitiveText(liveText)
                }
            } catch {
                try Task.checkCancellation()
                if scoped { return "Error: selected window could not be read: " + error.localizedDescription }
            }
        }
        try Task.checkCancellation()
        if scoped { return "Error: selected window could not be read; unrelated stored screen data was not used." }

        let recent = try await store.recent(seconds: 90, limit: 10)
        let screens = recent.compactMap { observation -> ScreenObservation? in
            if case .screen(let screen) = observation { return screen }
            return nil
        }
        guard let latest = screens.first else {
            return "No recent screen capture is available. Do not retry calling read_current_screen as no screen data is currently accessible. Please answer using the desktop context already provided or politely inform the user that screen capture is not available."
        }
        return PrivacyFilter().redactSensitiveText("""
            App: \(latest.appName)
            Window: \(latest.windowTitle)
            Captured: \(ContextFormatter.relativeTime(latest.timestamp))

            \(PrivacyFilter().redactSensitiveText(latest.text).prefix(4000))
            """)
    }
}

// MARK: - Formatting

public enum ContextFormatter {
    public static func line(for observation: DesktopObservation) -> String {
        let privacy = PrivacyFilter()
        switch observation {
        case .screen(let screen):
            let text = privacy.redactSensitiveText(screen.text)
                .split(separator: "\n")
                .prefix(12)
                .joined(separator: " / ")
            return privacy.redactSensitiveText("""
                [\(relativeTime(screen.timestamp))] \(screen.appName) — \
                \(screen.windowTitle): \(text.prefix(500))
                """)
        case .audio(let audio):
            let speaker = audio.channel == .microphone
                ? "You"
                : (audio.speakerID ?? "Other participant")
            return privacy.redactSensitiveText("[\(relativeTime(audio.timestamp))] \(speaker): \(audio.text)")
        }
    }

    /// Relative timestamps rather than absolute ones: the model reasons better
    /// about "3 minutes ago" than about a wall-clock time it has to subtract.
    public static func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(elapsed / 60))m ago"
        case ..<86400: return "\(Int(elapsed / 3600))h ago"
        default: return "\(Int(elapsed / 86400))d ago"
        }
    }

    /// Builds the rolling context block injected before a user question.
    public static func synthesize(_ observations: [DesktopObservation], maxCharacters: Int = 6000) -> String {
        var screenLines: [String] = []
        var dialogueLines: [String] = []
        var seenWindows = Set<String>()

        for observation in observations.sorted(by: { $0.timestamp > $1.timestamp }) {
            switch observation {
            case .screen(let screen):
                // One entry per window: consecutive captures of the same window
                // are near-duplicates and would crowd out the audio.
                let key = "\(screen.appName)|\(screen.windowTitle)"
                guard !seenWindows.contains(key) else { continue }
                seenWindows.insert(key)
                screenLines.append(line(for: observation))
            case .audio(let audio):
                guard audio.isFinal, !audio.text.isEmpty else { continue }
                dialogueLines.append(line(for: observation))
            }
        }

        var output = ""
        if !screenLines.isEmpty {
            output += "## Recent screen activity\n"
            output += screenLines.prefix(8).joined(separator: "\n")
            output += "\n\n"
        }
        if !dialogueLines.isEmpty {
            output += "## Recent conversation\n"
            output += dialogueLines.prefix(30).reversed().joined(separator: "\n")
            output += "\n"
        }
        return String(output.prefix(maxCharacters))
    }
}
