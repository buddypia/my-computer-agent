import Foundation
import MCACore
import MCAMemory
import MCASensing
import OSLog
import Synchronization

/// A capability the model can invoke mid-generation.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    func invoke(arguments: Data) async throws -> String
    /// Working-time limit for one call; nil uses the registry's. A tool whose
    /// own arguments allow a longer wait (`browser_wait`) declares it here.
    var timeout: Duration? { get }
}

extension AgentTool {
    public var timeout: Duration? { nil }
}

/// Registry plus the call/response loop.
///
/// Kept separate from the executors so a tool is written once and works with
/// every provider — Gemini function declarations, Anthropic tool_use blocks and
/// OpenAI function calls all reduce to this.
public actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]
    private let limits: ToolClock.Limits
    private let stuck: StuckToolCalls
    private let log = Logger(subsystem: "com.buddypia.mca", category: "ToolRegistry")

    /// How long one call may work, not counting time spent waiting on the user.
    public static let defaultTimeout: Duration = .seconds(90)
    /// Extra wall-clock room for approval prompts. Longer than the HUD's 300s
    /// approval expiry, so a pending approval is never cut short by this, and
    /// a prompt that never resolves still cannot hold the call forever.
    public static let defaultApprovalAllowance: Duration = .seconds(330)
    /// Abandoned calls still running. Each one may pin a thread, so past this
    /// many the registry refuses work rather than starve the cooperative pool.
    public static let defaultStuckCallLimit = 2

    public init(
        tools: [any AgentTool] = [],
        timeout: Duration = ToolRegistry.defaultTimeout,
        approvalAllowance: Duration = ToolRegistry.defaultApprovalAllowance,
        stuckCallLimit: Int = ToolRegistry.defaultStuckCallLimit
    ) {
        self.limits = ToolClock.Limits(working: timeout, approvalAllowance: approvalAllowance)
        self.stuck = StuckToolCalls(limit: stuckCallLimit)
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
        let started = ContinuousClock.now
        do {
            try Task.checkCancellation()
            if await ActionAuthorization.current?.terminalFailure != nil {
                throw ActionAuthorizationError.denied
            }
            if stuck.isSaturated { throw ToolUnavailableError(stuckCalls: stuck.count) }
            try Task.checkCancellation()
            let arguments = call.arguments
            var limits = self.limits
            if let own = tool.timeout { limits.working = max(own, limits.working) }
            let result = try await ToolClock.run(name: call.name, limits: limits, stuck: stuck) {
                try await tool.invoke(arguments: arguments)
            }
            log.info("Tool \(call.name, privacy: .public) finished in \(Self.milliseconds(since: started), privacy: .public) ms")
            return ToolOutput(callID: call.id, name: call.name, content: result)
        } catch {
            // The description can carry paths, typed text or page content, so
            // only the error's type is public in the unified log.
            log.error("Tool \(call.name, privacy: .public) failed after \(Self.milliseconds(since: started), privacy: .public) ms: \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .private)")
            // A timed-out action left the screen in an unknown state, and a
            // saturated registry cannot act at all: both end the action session
            // like a refusal, so the turn stops instead of spending model rounds.
            if error is ActionAuthorizationError || error is CancellationError
                || error is ToolTimeoutError || error is ToolUnavailableError {
                await ActionAuthorization.current?.abort(error)
            }
            // Errors are returned to the model rather than thrown: a failed
            // tool call is information the model can recover from, and killing
            // the turn instead would lose the whole response.
            return ToolOutput(
                callID: call.id, name: call.name,
                content: "Error: \(error.localizedDescription)")
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = ContinuousClock.now - start
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }
}

public struct ToolTimeoutError: LocalizedError, Sendable, Equatable {
    public let toolName: String
    public let timeout: Duration

    public var errorDescription: String? {
        "Tool '\(toolName)' did not finish within \(timeout.components.seconds)s and was abandoned; "
            + "it may or may not have taken effect. Do not call it again with the same arguments; "
            + "tell the user what got stuck."
    }
}

public struct ToolUnavailableError: LocalizedError, Sendable, Equatable {
    public let stuckCalls: Int

    public var errorDescription: String? {
        "\(stuckCalls) earlier tool calls are still stuck, so no tool was run. "
            + "Tell the user; restarting the app clears it."
    }
}

/// Abandoned tool calls whose work has not finished yet.
final class StuckToolCalls: Sendable {
    let limit: Int
    private let current = Mutex(0)

    init(limit: Int) { self.limit = max(1, limit) }

    var count: Int { current.withLock { $0 } }
    var isSaturated: Bool { count >= limit }
    func enter() { current.withLock { $0 += 1 } }
    func leave() { current.withLock { $0 = max(0, $0 - 1) } }
}

/// Working time of one tool call, with the time spent waiting on a human paused.
///
/// A tool that never returns used to hang the whole answer turn: nothing above
/// it had a deadline. Approval prompts legitimately wait minutes for the user,
/// so they bracket that wait with `notCounting` and only the machine's own time
/// is held against the limit.
public actor ToolClock {
    @TaskLocal public static var current: ToolClock?

    struct Limits: Sendable {
        var working: Duration
        var approvalAllowance: Duration
        var wall: Duration { working + approvalAllowance }
    }

    private let start = ContinuousClock.now
    private var pausedSince: ContinuousClock.Instant?
    private var pauseDepth = 0
    private var paused: Duration = .zero

    public init() {}

    public var workingTime: Duration {
        let now = ContinuousClock.now
        return (now - start) - paused - (pausedSince.map { now - $0 } ?? .zero)
    }

    var wallTime: Duration { ContinuousClock.now - start }

    private func pause() {
        if pauseDepth == 0 { pausedSince = .now }
        pauseDepth += 1
    }

    private func resume() {
        guard pauseDepth > 0 else { return }
        pauseDepth -= 1
        if pauseDepth == 0, let since = pausedSince {
            paused += .now - since
            pausedSince = nil
        }
    }

    /// Runs a wait on the user without charging it to the current tool call.
    public static func notCounting<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
        guard let clock = current else { return try await operation() }
        await clock.pause()
        do {
            let value = try await operation()
            await clock.resume()
            return value
        } catch {
            await clock.resume()
            throw error
        }
    }

    /// Runs `body`, throwing `ToolTimeoutError` once it has worked for
    /// `limits.working`, or once `limits.wall` has passed whatever it waited on.
    ///
    /// The body runs in its own task and is raced against a watchdog, so the
    /// caller gets control back even when the body is stuck in a call that
    /// ignores cancellation (a synchronous AX read on an unresponsive app). The
    /// body is cancelled and counted in `stuck` until it unwinds.
    static func run(
        name: String, limits: Limits, stuck: StuckToolCalls? = nil,
        _ body: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let clock = ToolClock()
        let race = ToolRace(stuck: stuck)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                race.track(Task {
                    let outcome: Result<String, any Error>
                    do { outcome = .success(try await ToolClock.$current.withValue(clock) { try await body() }) }
                    catch { outcome = .failure(error) }
                    race.settle(outcome, byWork: true)
                })
                race.track(Task {
                    while !Task.isCancelled {
                        let working = await clock.workingTime, wall = await clock.wallTime
                        if working >= limits.working || wall >= limits.wall {
                            race.settle(.failure(ToolTimeoutError(toolName: name, timeout: limits.working)), byWork: false)
                            return
                        }
                        // Sleep to the nearer deadline; a pause only pushes it out, so re-check on waking.
                        try? await Task.sleep(for: min(limits.working - working, limits.wall - wall))
                    }
                })
            }
        } onCancel: {
            race.settle(.failure(CancellationError()), byWork: false)
        }
    }
}

/// Settles a tool call exactly once, from whichever of the work, the watchdog
/// or the caller's cancellation gets there first, and cancels the rest.
private final class ToolRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, any Error>?
        var outcome: Result<String, any Error>?
        var tasks: [Task<Void, Never>] = []
        var workFinished = false
        var abandoned = false
    }

    private let state = Mutex(State())
    private let stuck: StuckToolCalls?

    init(stuck: StuckToolCalls?) { self.stuck = stuck }

    /// False when the call was already settled (cancelled before it started),
    /// in which case the continuation is resumed here and no work may start.
    func install(_ continuation: CheckedContinuation<String, any Error>) -> Bool {
        let settled = state.withLock { s -> Result<String, any Error>? in
            if let outcome = s.outcome { return outcome }
            s.continuation = continuation
            return nil
        }
        if let settled { continuation.resume(with: settled) }
        return settled == nil
    }

    func track(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { s -> Bool in
            if s.outcome != nil { return true }
            s.tasks.append(task)
            return false
        }
        if cancelNow { task.cancel() }
    }

    func settle(_ outcome: Result<String, any Error>, byWork: Bool) {
        enum Stuck { case none, enter, leave }
        let (continuation, tasks, change) = state.withLock { s -> (CheckedContinuation<String, any Error>?, [Task<Void, Never>], Stuck) in
            if byWork { s.workFinished = true }
            guard s.outcome == nil else {
                if byWork, s.abandoned { s.abandoned = false; return (nil, [], .leave) }
                return (nil, [], .none)
            }
            s.outcome = outcome
            var change = Stuck.none
            if !byWork, !s.workFinished, !s.tasks.isEmpty { s.abandoned = true; change = .enter }
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks, change)
        }
        switch change {
        case .enter: stuck?.enter()
        case .leave: stuck?.leave()
        case .none: break
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: outcome)
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
