import Foundation
import MCACore
import MCAMemory
import MCAReasoning
import MCASensing
import MCP
import OSLog

public typealias AutonomousCoordinatorFactory = @Sendable (AutonomousLoopConfig, Bool) -> TwoTierAutonomousLoopCoordinator

private final class ActiveTokenRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [ObjectIdentifier: CancellationToken] = [:]

    func register(_ token: CancellationToken, id: ObjectIdentifier) {
        lock.lock()
        tokens[id] = token
        lock.unlock()
    }

    func unregister(id: ObjectIdentifier) {
        lock.lock()
        tokens.removeValue(forKey: id)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(tokens.values)
        tokens.removeAll()
        lock.unlock()
        for token in all {
            token.cancel()
        }
    }
}

/// Exposes the user's recorded context to *other* agents over MCP.
///
/// This is the highest-leverage extensibility decision in the system. The HUD
/// and the built-in agent will both be superseded eventually; the captured
/// timeline will not. Publishing it as an MCP server means Claude Code, Codex
/// and anything else that speaks the protocol can answer "what was I looking at
/// an hour ago" without this project having to become their UI.
///
/// Runs over stdio, so a client launches it as a subprocess and no port is
/// opened.
public actor ContextMCPServer {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "MCP")
    private let store: any ContextStoring
    private let server: Server
    /// Extra agent tools published as-is (name, description, JSON schema),
    /// e.g. the browser toolkit. Keyed by tool name.
    private let extraTools: [String: any AgentTool]
    private let coordinatorFactory: AutonomousCoordinatorFactory
    private let activeTokens = ActiveTokenRegistry()
    /// Gate for tools that act on the machine. A stdio server has no UI, so the
    /// default refuses; see `AgentConfiguration.mcpAllowDangerousTools`.
    private let approver: any ToolApproving
    /// The `computer` tool this server drives; tests inject one over a recording
    /// synthesizer so no test moves the real mouse.
    private let computerTool: ComputerActionTool?

    public init(
        store: any ContextStoring,
        extraTools: [any AgentTool] = [],
        coordinatorFactory: AutonomousCoordinatorFactory? = nil,
        approver: any ToolApproving = ContextMCPServer.defaultApprover,
        computerTool: ComputerActionTool? = nil
    ) {
        self.store = store
        self.approver = approver
        self.computerTool = computerTool
        self.extraTools = Dictionary(uniqueKeysWithValues: extraTools.map { ($0.definition.name, $0) })
        self.coordinatorFactory = coordinatorFactory ?? { config, dryRun in
            TwoTierAutonomousLoopCoordinator(
                planner: DefaultSubgoalPlanner(),
                decisionEngine: .live(confidenceThreshold: config.confidenceThreshold),
                synthesizer: dryRun ? DryRunEventSynthesizer() : EventSynthesizer(),
                snapshotProvider: AccessibilityInspector(),
                config: config,
                // A live run is approved as a whole in `handleAutonomousAct` before it starts.
                keystrokeApprover: AutoApproveToolApprover()
            )
        }
        self.server = Server(
            name: "my-computer-agent",
            version: "1.0.0",
            title: "My Computer Agent — desktop context",
            instructions: """
                Provides searchable history of what the user has seen on screen \
                and heard around them, captured locally on their Mac. Use \
                search_context for anything the user refers to from earlier, and \
                recent_activity to establish what they are doing right now. \
                To operate the desktop, call computer with action "screenshot" \
                first, then act with coordinates read off that screenshot and \
                take another screenshot to check the result.
                """,
            capabilities: .init(tools: .init(listChanged: false)))
    }

    public func start(transport: any Transport = StdioTransport()) async throws {
        await registerHandlers()
        try await server.start(transport: transport)
        log.info("MCP server started on stdio")
    }

    public func waitUntilCompleted() async {
        await server.waitUntilCompleted()
    }

    public func stop() async {
        cancelAllActiveLoops()
        await server.stop()
    }

    public nonisolated func registerActiveToken(_ token: CancellationToken, id: ObjectIdentifier) {
        activeTokens.register(token, id: id)
    }

    public nonisolated func unregisterActiveToken(id: ObjectIdentifier) {
        activeTokens.unregister(id: id)
    }

    public nonisolated func cancelAllActiveLoops() {
        activeTokens.cancelAll()
    }

    private func registerHandlers() async {
        let tools = Self.toolDefinitions + extraTools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
            .map(Self.mcpTool(from:))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        let store = self.store
        let extraTools = self.extraTools
        let coordinatorFactory = self.coordinatorFactory
        let serverInstance = self
        let approver = self.approver
        let computerTool = self.computerTool
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                let content: [MCP.Tool.Content]
                if let tool = extraTools[parameters.name] {
                    let text = try await Self.invokeExtraTool(
                        tool, arguments: try Self.jsonFromMCPArguments(parameters.arguments ?? [:]),
                        approver: approver)
                    content = [.text(text: text, annotations: nil, _meta: nil)]
                } else {
                    content = try await Self.dispatchContent(
                        name: parameters.name,
                        arguments: parameters.arguments ?? [:],
                        store: store,
                        coordinatorFactory: coordinatorFactory,
                        serverInstance: serverInstance,
                        approver: approver,
                        computerTool: computerTool)
                }
                return CallTool.Result(content: content, isError: Self.reportsError(content))
            } catch {
                // Reported as a tool error rather than thrown, so the calling
                // model can read the message and adjust instead of the whole
                // request failing.
                return CallTool.Result(
                    content: [.text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                    isError: true)
            }
        }
    }

    /// MCP clients tell a failed call from a result by `isError`, not by the text. The tools
    /// report failures (a refusal, a bad argument, a failed input) as text beginning `Error:`.
    static func reportsError(_ content: [MCP.Tool.Content]) -> Bool {
        guard case .text(let text, _, _)? = content.first else { return false }
        return text.hasPrefix("Error:")
    }

    // MARK: - Tools

    static var toolDefinitions: [MCP.Tool] {
        [
            MCP.Tool(
                name: "search_context",
                description: """
                    Search the user's recorded screen and audio history using \
                    hybrid full-text and semantic matching.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Natural language search terms."),
                        ]),
                        "minutes_ago": .object([
                            "type": .string("integer"),
                            "description": .string("Restrict to the last N minutes."),
                        ]),
                        "app_name": .object([
                            "type": .string("string"),
                            "description": .string("Restrict to one application."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results, default 20."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)),

            MCP.Tool(
                name: "recent_activity",
                description: """
                    Return everything captured in the last N minutes, newest \
                    first. Use to establish what the user is doing right now.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "minutes": .object([
                            "type": .string("integer"),
                            "description": .string("Look-back window, default 10."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum entries, default 40."),
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)),

            MCP.Tool(
                name: "conversation_history",
                description: """
                    Return only spoken dialogue, separated into the user's own \
                    speech and other participants'. Use for meeting recall.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "minutes": .object([
                            "type": .string("integer"),
                            "description": .string("Look-back window, default 60."),
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("'me', 'others', or 'all' (default)."),
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)),

            MCP.Tool(
                name: "computer",
                description: """
                    Look at and operate the macOS desktop, with the same actions as \
                    Anthropic's computer use tool. Start with action "screenshot" (an \
                    image of the main display), then act with coordinates in the pixel \
                    space of the latest screenshot (origin top-left) and take another \
                    screenshot to verify. Use "zoom" to read small text. Main display only.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object([
                            "type": .string("string"),
                            "enum": .array(ContextMCPServer.computerActions.map { .string($0) }),
                            "description": .string("The action to perform: " + ContextMCPServer.computerActions.joined(separator: ", ") + "."),
                        ]),
                        "coordinate": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("number")]),
                            "description": .string("Target [x, y] in pixels of the latest screenshot, origin at its top-left. Omit to use the current cursor position."),
                        ]),
                        "start_coordinate": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("number")]),
                            "description": .string("Start [x, y] for left_click_drag, in pixels of the latest screenshot."),
                        ]),
                        "region": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("number")]),
                            "description": .string("[x0, y0, x1, y1] for zoom: top-left and bottom-right corners, in pixels of the latest screenshot."),
                        ]),
                        "duration": .object([
                            "type": .string("number"),
                            "description": .string("Seconds for wait (default 1) or hold_key; at most 300."),
                        ]),
                        "scroll_direction": .object([
                            "type": .string("string"),
                            "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")]),
                            "description": .string("Direction for scroll."),
                        ]),
                        "scroll_amount": .object([
                            "type": .string("integer"),
                            "description": .string("Number of scroll-wheel clicks for scroll (default 5)."),
                        ]),
                        "repeat": .object([
                            "type": .string("integer"),
                            "description": .string("For key: press it this many times (1 to 100, default 1)."),
                        ]),
                        "delta_y": .object([
                            "type": .string("integer"),
                            "description": .string("Older spelling of scroll: vertical wheel clicks (negative scrolls down, positive up). Prefer scroll_direction."),
                        ]),
                        "delta_x": .object([
                            "type": .string("integer"),
                            "description": .string("Older spelling of scroll: horizontal wheel clicks. Prefer scroll_direction."),
                        ]),
                        "target_pid": .object([
                            "type": .string("integer"),
                            "description": .string("Optional process ID (PID) to target background scrolling without stealing focus."),
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("For type: the text. For key and hold_key: the key or a '+'-joined combination (e.g. 'Return', 'cmd+c'). For clicks, drag and scroll: modifier keys to hold (shift, ctrl, alt, super), e.g. 'shift' or 'ctrl+shift'."),
                        ]),
                        "key": .object([
                            "type": .string("string"),
                            "description": .string("Older spelling of text for key and hold_key."),
                        ]),
                    ]),
                    "required": .array([.string("action")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)),

            MCP.Tool(
                name: "click_element",
                description: """
                    Click a UI element in an app by text or label without needing screen coordinates.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "element_text": .object([
                            "type": .string("string"),
                            "description": .string("Title, label, or text of the element to click."),
                        ]),
                        "app_name": .object([
                            "type": .string("string"),
                            "description": .string("Application name (optional, defaults to frontmost)."),
                        ]),
                        "role": .object([
                            "type": .string("string"),
                            "description": .string("Element role (optional)."),
                        ]),
                    ]),
                    "required": .array([.string("element_text")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)),

            MCP.Tool(
                name: "run_applescript",
                description: """
                    Execute an AppleScript command via osascript for macOS native app automation.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "script": .object([
                            "type": .string("string"),
                            "description": .string("AppleScript code to execute."),
                        ]),
                    ]),
                    "required": .array([.string("script")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)),

            MCP.Tool(
                name: "inspect_ui_elements",
                description: """
                    Inspect actionable UI elements of the active window with their bounds, in the \
                    same pixel space as computer coordinates (the latest screenshot's), \
                    applying strict privacy filtering to redact passwords and tokens.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_candidates": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum elements to return (default: 25)."),
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)),

            MCP.Tool(
                name: "typesafe_act",
                description: """
                    Autonomous computer action using TypeSafe Jev System One model. \
                    Inspects the active window, evaluates actionable candidates, and performs the optimal UI action.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "goal": .object([
                            "type": .string("string"),
                            "description": .string("The objective to achieve on screen (e.g. 'Click Search button and type Tokyo')."),
                        ]),
                    ]),
                    "required": .array([.string("goal")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)),

            MCP.Tool(
                name: "autonomous_act",
                description: """
                    Execute a multi-step desktop task autonomously using 2-Tier Planning (System 2) and micro-grounding (System 1).
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "goal": .object([
                            "type": .string("string"),
                            "description": .string("The user's intended objective."),
                        ]),
                        "max_steps": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum steps before termination (default: 20)."),
                        ]),
                        "confidence_threshold": .object([
                            "type": .string("number"),
                            "description": .string("Confidence threshold below which to escalate (default: 0.80)."),
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("Evaluate decisions without synthesizing OS events (default: false)."),
                        ]),
                    ]),
                    "required": .array([.string("goal")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)),
        ]
    }

    /// Refuses everything that needs approval, and says how to opt in.
    public static var defaultApprover: any ToolApproving {
        DenyAllToolApprover(
            reason: "MCP clients cannot be asked for confirmation; set \"mcpAllowDangerousTools\": true in config.json to allow this "
                + "(to allow only the screen, mouse and keyboard, start the server with `mca mcp --computer-use`)")
    }

    /// The published extra tools (the browser toolkit) that may run without
    /// approval under MCP default-deny: the ones that only read a page.
    ///
    /// This is an allowlist on purpose. Acting on a page in the user's logged-in
    /// browser (clicking, typing, navigating, running JavaScript, opening or
    /// closing tabs) or writing a file is as consequential as driving the mouse,
    /// so it needs the same opt-in, and a tool added later must be gated until
    /// someone has decided it is read-only. `browser_read` and `browser_tabs`
    /// are listed but only for their reading forms; see ``needsApproval(tool:arguments:)``.
    static let readOnlyExtraTools: Set<String> = [
        "browser_snapshot", "browser_observe", "browser_extract", "browser_wait",
        "browser_read", "browser_tabs",
    ]

    /// Whether a published extra tool has to pass the approver before it runs.
    /// Fails closed: anything not known to be read-only, and any call whose
    /// arguments cannot be read, needs approval.
    static func needsApproval(tool name: String, arguments: Data) -> Bool {
        guard readOnlyExtraTools.contains(name) else { return true }
        switch name {
        case "browser_read":
            // Without a path a screenshot goes to the temporary directory; with
            // one (whatever its type) the model chooses where a file is written.
            guard let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] else { return true }
            return parsed["path"] != nil
        case "browser_tabs":
            // Listing tabs reads; new / switch / close act.
            guard let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] else { return true }
            guard let action = parsed["action"] else { return false }
            return action as? String != "list"
        default:
            return false
        }
    }

    /// Invokes a published extra tool, asking `approver` first unless it is
    /// known to be read-only.
    static func invokeExtraTool(
        _ tool: any AgentTool, arguments: Data, approver: any ToolApproving
    ) async throws -> String {
        let name = tool.definition.name
        guard needsApproval(tool: name, arguments: arguments) else {
            return try await tool.invoke(arguments: arguments)
        }
        return try await approved(
            approver, tool: name, title: "Act in your browser or write a file",
            detail: ApprovalText.visible(String(decoding: arguments, as: UTF8.self))
        ) { try await tool.invoke(arguments: arguments) }
    }

    /// Runs `body` only if the user (or the opt-in configuration) approves.
    private static func approved(
        _ approver: any ToolApproving,
        tool: String,
        title: String,
        detail: String,
        run body: () async throws -> String
    ) async throws -> String {
        if let refusal = await approver.gate(ToolApprovalRequest(toolName: tool, title: title, detail: detail)) {
            return refusal
        }
        return try await body()
    }

    /// The actions of the `computer` tool, in the order and with the names of Anthropic's
    /// computer use toolset (`screenshot`, `zoom`, the clicks, `scroll`, `type`, `key`, …).
    public static let computerActions = [
        "screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
        "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position",
        "scroll", "type", "key", "hold_key", "wait",
    ]

    /// The tools an MCP client may use after `mca mcp --computer-use`: seeing the
    /// screen and driving the mouse and keyboard, nothing else. AppleScript, the
    /// browser tools that act on a page and the autonomous loops stay gated.
    public static let computerUseTools: Set<String> = ["computer"]

    /// The `computer` tool as the MCP server drives it. The call as a whole has
    /// already been approved by `approver` when this runs, so the tool takes
    /// that approval in place of the chat UI's per-action card.
    static func liveComputerTool() -> ComputerActionTool {
        ComputerActionTool(approver: AutoApproveToolApprover(), trustsCallerApproval: true)
    }

    /// Like ``dispatch(name:arguments:store:coordinatorFactory:serverInstance:approver:computerTool:)``
    /// but returns MCP content, so `computer` with `screenshot` can hand back an image.
    public static func dispatchContent(
        name: String,
        arguments: [String: Value],
        store: any ContextStoring,
        coordinatorFactory: AutonomousCoordinatorFactory? = nil,
        serverInstance: ContextMCPServer? = nil,
        approver: any ToolApproving = ContextMCPServer.defaultApprover,
        computerTool: ComputerActionTool? = nil
    ) async throws -> [MCP.Tool.Content] {
        if name == "computer", case .string(let action)? = arguments["action"], action == "screenshot" || action == "zoom" {
            // Capturing is read-only but puts the display in front of the client, so it needs
            // the same opt-in as driving the mouse.
            if let refusal = await approver.gate(ToolApprovalRequest(
                toolName: name, title: "Capture the screen", detail: "Take a screenshot of the main display")) {
                return [.text(text: refusal, annotations: nil, _meta: nil)]
            }
            let tool = computerTool ?? liveComputerTool()
            let screenshot: ComputerScreenshot
            do {
                screenshot = action == "zoom"
                    ? try await tool.captureZoom(arguments: try jsonFromMCPArguments(arguments))
                    : try await tool.captureScreenshot()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                throw ScreenshotError.unavailable("\(action == "zoom" ? "Zoom" : "Screenshot") failed: \(reason)")
            }
            return [
                .image(data: screenshot.jpeg.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil),
                .text(text: screenshot.summary, annotations: nil, _meta: nil),
            ]
        }
        let text = try await dispatch(
            name: name, arguments: arguments, store: store, coordinatorFactory: coordinatorFactory,
            serverInstance: serverInstance, approver: approver, computerTool: computerTool)
        return [.text(text: text, annotations: nil, _meta: nil)]
    }

    public static func dispatch(
        name: String,
        arguments: [String: Value],
        store: any ContextStoring,
        coordinatorFactory: AutonomousCoordinatorFactory? = nil,
        serverInstance: ContextMCPServer? = nil,
        approver: any ToolApproving = ContextMCPServer.defaultApprover,
        computerTool: ComputerActionTool? = nil
    ) async throws -> String {
        switch name {
        case "search_context":
            guard case .string(let query)? = arguments["query"], !query.isEmpty else {
                return "Error: 'query' is required."
            }
            let since = intValue(arguments["minutes_ago"]).map {
                Date().addingTimeInterval(-Double($0) * 60)
            }
            let results = try await store.search(ContextQuery(
                text: query,
                since: since,
                appName: stringValue(arguments["app_name"]),
                limit: min(intValue(arguments["limit"]) ?? 20, 100)))

            guard !results.isEmpty else { return "No matches for '\(query)'." }
            return results
                .map { ContextFormatter.line(for: $0.observation) }
                .joined(separator: "\n")

        case "recent_activity":
            let minutes = intValue(arguments["minutes"]) ?? 10
            let observations = try await store.recent(
                seconds: Double(minutes) * 60,
                limit: min(intValue(arguments["limit"]) ?? 40, 200))
            guard !observations.isEmpty else {
                return "Nothing captured in the last \(minutes) minutes."
            }
            return ContextFormatter.synthesize(observations)

        case "conversation_history":
            let minutes = intValue(arguments["minutes"]) ?? 60
            let speaker = stringValue(arguments["speaker"]) ?? "all"
            let channels: [AudioChannel]? = switch speaker {
            case "me": [.microphone]
            case "others": [.systemAudio]
            default: nil
            }
            let results = try await store.search(ContextQuery(
                since: Date().addingTimeInterval(-Double(minutes) * 60),
                channels: channels ?? AudioChannel.allCases,
                limit: 200))
            let lines = results
                .map(\.observation)
                .filter { if case .audio = $0 { return true } else { return false } }
                .sorted { $0.timestamp < $1.timestamp }
                .map { ContextFormatter.line(for: $0) }

            guard !lines.isEmpty else {
                return "No conversation recorded in the last \(minutes) minutes."
            }
            return lines.joined(separator: "\n")

        case "computer":
            // `approved` below asks about the whole call, so the tool's own
            // keystroke prompt would ask twice.
            let tool = computerTool ?? liveComputerTool()
            let data = try jsonFromMCPArguments(arguments)
            return try await approved(
                approver, tool: name, title: "Control the mouse and keyboard",
                detail: String(decoding: data, as: UTF8.self)
            ) { try await tool.invoke(arguments: data) }

        case "click_element":
            let tool = ClickElementTool(trustsCallerApproval: true)
            let data = try jsonFromMCPArguments(arguments)
            return try await approved(
                approver, tool: name, title: "Click a UI element",
                detail: String(decoding: data, as: UTF8.self)
            ) { try await tool.invoke(arguments: data) }

        case "run_applescript":
            // The tool gates itself, showing the script rather than the JSON
            // envelope around it.
            let tool = RunAppleScriptTool(approver: approver)
            let data = try jsonFromMCPArguments(arguments)
            return try await tool.invoke(arguments: data)

        case "inspect_ui_elements":
            // Bounds in the pixels `computer` reads, so a returned element can be clicked as is.
            let tool = InspectUIElementsTool(screenSpace: (computerTool ?? liveComputerTool()).coordinateSpace)
            let data = try jsonFromMCPArguments(arguments)
            return try await tool.invoke(arguments: data)

        case "typesafe_act":
            let tool = TypeSafeActTool(engineProvider: { .live() }, approver: AutoApproveToolApprover())
            let data = try jsonFromMCPArguments(arguments)
            return try await approved(
                approver, tool: name, title: "Act on the screen toward a goal",
                detail: String(decoding: data, as: UTF8.self)
            ) { try await tool.invoke(arguments: data) }

        case "autonomous_act":
            return try await handleAutonomousAct(
                approver: approver,
                arguments: arguments,
                coordinatorFactory: coordinatorFactory,
                serverInstance: serverInstance
            )

        default:
            return "Error: unknown tool '\(name)'."
        }
    }

    private static func handleAutonomousAct(
        approver: any ToolApproving,
        arguments: [String: Value],
        coordinatorFactory: AutonomousCoordinatorFactory?,
        serverInstance: ContextMCPServer?
    ) async throws -> String {
        guard let goalVal = arguments["goal"] else {
            return "Error: 'goal' parameter is required."
        }
        guard case .string(let goal) = goalVal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'goal' parameter cannot be empty."
        }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        if let stepsVal = arguments["max_steps"] {
            guard let maxSteps = intValue(stepsVal), maxSteps > 0 else {
                return "Error: 'max_steps' must be a positive integer."
            }
        }
        let maxSteps = intValue(arguments["max_steps"]) ?? 20

        if let confVal = arguments["confidence_threshold"] {
            guard let conf = doubleValue(confVal), conf >= 0.0 && conf <= 1.0 else {
                return "Error: 'confidence_threshold' must be between 0.0 and 1.0."
            }
        }
        let confidence = doubleValue(arguments["confidence_threshold"]) ?? 0.80

        let dryRun = boolValue(arguments["dry_run"]) ?? false

        // A dry run synthesizes no events, so it needs no approval. Asked after
        // argument validation so malformed calls still get their specific error.
        if !dryRun, let refusal = await approver.gate(ToolApprovalRequest(
            toolName: "autonomous_act",
            title: "Run a multi-step task on the screen",
            detail: trimmedGoal)) {
            return refusal
        }

        let config = AutonomousLoopConfig(
            maxTotalSteps: maxSteps,
            defaultSubgoalMaxSteps: min(maxSteps, 10),
            confidenceThreshold: Float(confidence),
            settlingDelayMs: dryRun ? 0 : 100,
            identicalActionThreshold: 3,
            unchangedStateThreshold: 3
        )

        let factory = coordinatorFactory ?? { cfg, isDry in
            TwoTierAutonomousLoopCoordinator(
                planner: DefaultSubgoalPlanner(),
                decisionEngine: .live(confidenceThreshold: cfg.confidenceThreshold),
                synthesizer: isDry ? DryRunEventSynthesizer() : EventSynthesizer(),
                snapshotProvider: AccessibilityInspector(),
                config: cfg,
                // A live run is approved as a whole in `handleAutonomousAct` before it starts.
                keystrokeApprover: AutoApproveToolApprover()
            )
        }

        let coordinator = factory(config, dryRun)
        let token = CancellationToken()
        let tokenID = ObjectIdentifier(token)
        serverInstance?.registerActiveToken(token, id: tokenID)
        defer { serverInstance?.unregisterActiveToken(id: tokenID) }

        return await AutonomousActOutput.run(coordinator, goal: trimmedGoal, cancellationToken: token).json
    }

    /// Publishes an `AgentTool` definition unchanged: the JSON Schema the
    /// built-in agent sees is the one MCP clients see.
    static func mcpTool(from definition: ToolDefinition) -> MCP.Tool {
        let schema = (try? JSONSerialization.jsonObject(with: definition.parameters)).map(mcpValue)
            ?? .object(["type": .string("object")])
        let readOnly = ["browser_snapshot", "browser_read", "browser_observe", "browser_extract", "browser_wait"].contains(definition.name)
        return MCP.Tool(
            name: definition.name,
            description: definition.description,
            inputSchema: schema,
            annotations: .init(readOnlyHint: readOnly, openWorldHint: definition.name.hasPrefix("browser_")))
    }

    static func mcpValue(_ any: Any) -> Value {
        switch any {
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let d = number.doubleValue
            if d.isFinite, let exact = Int(exactly: d) { return .int(exact) }
            return .double(d)
        case let array as [Any]: return .array(array.map(mcpValue))
        case let object as [String: Any]: return .object(object.mapValues(mcpValue))
        default: return .null
        }
    }

    private static func jsonFromMCPArguments(_ arguments: [String: Value]) throws -> Data {
        func convert(_ value: Value) -> Any {
            switch value {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .array(let a): return a.map(convert)
            case .object(let o): return o.mapValues(convert)
            case .null: return NSNull()
            case .data(mimeType: _, let data): return data
            @unknown default: return NSNull()
            }
        }
        let dict = arguments.mapValues(convert)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    static func intValue(_ value: Value?) -> Int? {
        switch value {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int(exactly: d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func stringValue(_ value: Value?) -> String? {
        if case .string(let s) = value, !s.isEmpty { return s }
        return nil
    }

    private static func doubleValue(_ value: Value?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    private static func boolValue(_ value: Value?) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .string(let s): return Bool(s)
        default: return nil
        }
    }
}
