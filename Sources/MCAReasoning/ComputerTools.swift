import AppKit
import CoreGraphics
import Foundation
import MCACore
import MCAPerception
import MCASensing
import OSLog

/// Decides which synthesized keystrokes need the user's approval.
///
/// Typing into whatever app is in front is the one GUI action that turns
/// injected screen text into code execution: `curl … | sh` and Return in a
/// terminal. Which apps are terminals cannot be listed reliably (IDE panes,
/// SSH clients, unknown shells), so the rule is per keystroke instead: text and
/// every key are approved, except modifier-free navigation keys that move focus
/// or the caret without entering or confirming anything.
///
/// What the user judges is the literal text. The app named in the prompt is
/// the one in front when they are asked — a hint, not a guarantee, since focus
/// can still move before the keys are sent.
public enum KeystrokeApproval {
    /// Up and Down are not here: in a terminal they recall history, which a
    /// following (approved) Return would run without the user having seen it.
    static let navigationKeys: Set<String> = [
        "escape", "esc", "tab", "left", "right", "home", "end", "pageup", "pagedown",
    ]

    public static func needsApproval(key chord: String) -> Bool {
        !navigationKeys.contains(chord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The prompt names the receiving app, because the same text is harmless in
    /// a search field and an attack in Terminal.
    public static func request(tool: String, title: String, keystrokes: String, app: String?) -> ToolApprovalRequest {
        var warning = "Keystrokes go to the app in front. In a terminal they can run commands."
        let lineBreaks = keystrokes.filter(\.isNewline).count
        if lineBreaks > 0 {
            // A trailing one is invisible in the prompt and padding can push the
            // command out of view, so say it in words.
            warning += " The text has \(lineBreaks) line break(s); each one presses Return."
        }
        return ToolApprovalRequest(
            toolName: tool,
            title: title,
            detail: "App: \(app.map { ApprovalText.visible($0) } ?? "unknown")\n\n\(ApprovalText.visible(keystrokes, keepingLineBreaks: true))",
            warning: warning)
    }

    /// Name of the app in front, this one included.
    public static let frontmostAppName: @Sendable () -> String? = {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}

/// Synthesizes mouse movements, clicks, drags, typing, and key presses.
/// Conforms to the Anthropic Computer Use tool specification.
///
/// `type` and `key` go through `approver` (see ``KeystrokeApproval``); pointer
/// actions do not. The default refuses.
public struct ComputerActionTool: AgentTool {
    private let synthesizer: any EventSynthesizing
    private let approver: any ToolApproving
    private let frontmostApp: @Sendable () -> String?

    public init(
        synthesizer: any EventSynthesizing = EventSynthesizer(),
        approver: any ToolApproving = DenyAllToolApprover(),
        frontmostApp: @escaping @Sendable () -> String? = KeystrokeApproval.frontmostAppName
    ) {
        self.synthesizer = synthesizer
        self.approver = approver
        self.frontmostApp = frontmostApp
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "computer",
            description: """
                Interact with the macOS desktop interface. \
                Supports mouse movements, single/double/triple/right clicks, dragging, \
                scrolling the screen or active window, \
                typing text (including Japanese and Unicode), pressing keyboard shortcuts, \
                and querying the current cursor position.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "action": {
                      "type": "string",
                      "enum": [
                        "mouse_move",
                        "left_click",
                        "right_click",
                        "double_click",
                        "triple_click",
                        "middle_click",
                        "left_click_drag",
                        "scroll",
                        "type",
                        "key",
                        "cursor_position"
                      ],
                      "description": "The desktop action to perform."
                    },
                    "coordinate": {
                      "type": "array",
                      "items": { "type": "number" },
                      "description": "Target screen coordinate [x, y] in Quartz display pixels (origin at top-left of primary display)."
                    },
                    "start_coordinate": {
                      "type": "array",
                      "items": { "type": "number" },
                      "description": "Starting coordinate [x, y] when performing a drag action."
                    },
                    "delta_y": {
                      "type": "number",
                      "description": "Vertical scroll line amount when action is 'scroll' (negative to scroll down/downward, positive to scroll up/upward). Defaults to -5."
                    },
                    "delta_x": {
                      "type": "number",
                      "description": "Horizontal scroll line amount when action is 'scroll' (negative for left, positive for right)."
                    },
                    "target_pid": {
                      "type": "integer",
                      "description": "Optional process ID to scroll in the background without moving the physical cursor or bringing it frontmost."
                    },
                    "text": {
                      "type": "string",
                      "description": "Text to type when action is 'type'. Supports full Unicode and Japanese text."
                    },
                    "key": {
                      "type": "string",
                      "description": "Key or key chord to press when action is 'key' (e.g. 'Return', 'Escape', 'Tab', 'Space', 'cmd+c', 'ctrl+shift+a')."
                    }
                  },
                  "required": ["action"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let action = parsed.string("action") else {
            return "Error: 'action' parameter is required."
        }

        func extractPoint(_ key: String) -> CGPoint? {
            if let arr = parsed[key] as? [Double], arr.count >= 2 {
                return CGPoint(x: arr[0], y: arr[1])
            }
            if let arr = parsed[key] as? [Int], arr.count >= 2 {
                return CGPoint(x: Double(arr[0]), y: Double(arr[1]))
            }
            if let arr = parsed[key] as? [NSNumber], arr.count >= 2 {
                return CGPoint(x: arr[0].doubleValue, y: arr[1].doubleValue)
            }
            return nil
        }

        let supported = ["mouse_move", "left_click", "right_click", "double_click", "triple_click", "middle_click", "left_click_drag", "scroll", "type", "key", "cursor_position"]
        guard supported.contains(action) else { return "Error: Unsupported action '\(action)'." }
        if action == "type", parsed.string("text") == nil { return "Error: 'text' parameter is required for 'type' action." }
        if action == "key", parsed.string("key") == nil { return "Error: 'key' parameter is required for 'key' action." }
        if action == "left_click_drag", extractPoint("start_coordinate") == nil || extractPoint("coordinate") == nil {
            return "Error: Both 'start_coordinate' and 'coordinate' are required for 'left_click_drag'."
        }
        if action == "mouse_move", extractPoint("coordinate") == nil {
            return "Error: 'coordinate' [x, y] is required for 'mouse_move'."
        }
        // Validate both spellings without a trapping numeric conversion, before any gate/input.
        var targetPID: pid_t?
        for key in ["target_pid", "pid"] where parsed[key] != nil {
            guard let value = parsed[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  value.doubleValue.rounded(.towardZero) == value.doubleValue,
                  value.doubleValue >= 1, value.doubleValue <= Double(Int32.max),
                  targetPID == nil || targetPID == value.int32Value else {
                return "Error: 'target_pid'/'pid' must be a positive 32-bit integer and agree when both are provided."
            }
            targetPID = value.int32Value
        }
        // Resolve cursor-dependent actions before approval so its UI cannot change the operation.
        let coordinateActions = ["left_click", "right_click", "double_click", "triple_click", "middle_click", "scroll"]
        let actionPoint = coordinateActions.contains(action) ? (try extractPoint("coordinate") ?? synthesizer.cursorPosition()) : extractPoint("coordinate")
        let resolvedDetails = String(decoding: arguments, as: UTF8.self) + (actionPoint.map { "\nResolved coordinate: [\($0.x), \($0.y)]" } ?? "")
        let unscopedKeystroke = ActionAuthorization.current == nil && ["type", "key"].contains(action)
        if action != "cursor_position", !unscopedKeystroke {
            try await DesktopActionAuthorization.requireApproval(operation: action, details: resolvedDetails, requestedPID: targetPID)
        }
        try Task.checkCancellation()
        do {
            switch action {
            case "mouse_move":
                guard let point = extractPoint("coordinate") else {
                    return "Error: 'coordinate' [x, y] is required for 'mouse_move'."
                }
                try synthesizer.mouseMove(to: point)
                return "Moved cursor to (\(Int(point.x)), \(Int(point.y)))."

            case "left_click":
                let point = actionPoint
                try synthesizer.click(at: point, button: .left, clickCount: 1)
                if let point {
                    return "Left clicked at (\(Int(point.x)), \(Int(point.y)))."
                }
                return "Left clicked at current position."

            case "right_click":
                let point = actionPoint
                try synthesizer.click(at: point, button: .right, clickCount: 1)
                if let point {
                    return "Right clicked at (\(Int(point.x)), \(Int(point.y)))."
                }
                return "Right clicked at current position."

            case "double_click":
                let point = actionPoint
                try synthesizer.click(at: point, button: .left, clickCount: 2)
                if let point {
                    return "Double clicked at (\(Int(point.x)), \(Int(point.y)))."
                }
                return "Double clicked at current position."

            case "triple_click":
                let point = actionPoint
                try synthesizer.click(at: point, button: .left, clickCount: 3)
                if let point {
                    return "Triple clicked at (\(Int(point.x)), \(Int(point.y)))."
                }
                return "Triple clicked at current position."

            case "middle_click":
                let point = actionPoint
                try synthesizer.click(at: point, button: .middle, clickCount: 1)
                if let point {
                    return "Middle clicked at (\(Int(point.x)), \(Int(point.y)))."
                }
                return "Middle clicked at current position."

            case "left_click_drag":
                guard let start = extractPoint("start_coordinate"),
                      let end = extractPoint("coordinate") else {
                    return "Error: Both 'start_coordinate' and 'coordinate' are required for 'left_click_drag'."
                }
                try synthesizer.drag(from: start, to: end)
                return "Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))."

            case "scroll":
                let point = actionPoint
                let deltaY: Int32
                if let num = parsed["delta_y"] as? NSNumber {
                    deltaY = num.int32Value
                } else if let val = parsed["delta_y"] as? Int {
                    deltaY = Int32(val)
                } else if let val = parsed["delta_y"] as? Double {
                    deltaY = Int32(val)
                } else {
                    deltaY = -5 // Default to scrolling down
                }

                let deltaX: Int32
                if let num = parsed["delta_x"] as? NSNumber {
                    deltaX = num.int32Value
                } else if let val = parsed["delta_x"] as? Int {
                    deltaX = Int32(val)
                } else if let val = parsed["delta_x"] as? Double {
                    deltaX = Int32(val)
                } else {
                    deltaX = 0
                }

                try synthesizer.scroll(deltaX: deltaX, deltaY: deltaY, at: point, targetPID: targetPID)
                let direction = deltaY < 0 ? "down" : (deltaY > 0 ? "up" : "horizontally")
                if let targetPID {
                    return "Scrolled \(direction) on process \(targetPID) in background with deltaY=\(deltaY), deltaX=\(deltaX)."
                }
                if let point {
                    return "Scrolled \(direction) at (\(Int(point.x)), \(Int(point.y))) with deltaY=\(deltaY), deltaX=\(deltaX)."
                }
                return "Scrolled \(direction) with deltaY=\(deltaY), deltaX=\(deltaX)."

            case "type":
                guard let text = parsed.string("text") else {
                    return "Error: 'text' parameter is required for 'type' action."
                }
                if ActionAuthorization.current == nil,
                   let refusal = await approver.gate(KeystrokeApproval.request(
                    tool: definition.name, title: "Type text", keystrokes: text, app: frontmostApp())) {
                    return refusal
                }
                try synthesizer.typeText(text)
                return "Typed \(text.count) characters."

            case "key":
                guard let key = parsed.string("key") else {
                    return "Error: 'key' parameter is required for 'key' action."
                }
                if ActionAuthorization.current == nil, KeystrokeApproval.needsApproval(key: key),
                   let refusal = await approver.gate(KeystrokeApproval.request(
                    tool: definition.name, title: "Press a key", keystrokes: "Key: \(key)", app: frontmostApp())) {
                    return refusal
                }
                try synthesizer.pressKey(key)
                return "Pressed key '\(key)'."

            case "cursor_position":
                let pos = try synthesizer.cursorPosition()
                return "Current cursor position: [\(Int(pos.x)), \(Int(pos.y))]."

            default:
                return "Error: Unsupported action '\(action)'."
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

/// Clicks a semantic UI element (button, menu item, check box, etc.) identified by text/label in a target application.
public struct ClickElementTool: AgentTool {
    private let synthesizer = EventSynthesizer()
    public init() {}

    static func observedCandidate(_ snapshot: UIStateSnapshot, text: String, role: String?) throws -> UIElementCandidate {
        let matches = snapshot.visibleCandidates.filter {
            $0.isActionable && !$0.bounds.isEmpty && $0.label.caseInsensitiveCompare(text) == .orderedSame
                && (role == nil || $0.role.localizedCaseInsensitiveContains(role!))
        }
        guard matches.count == 1 else { throw ActionAuthorizationError.staleTarget }
        return matches[0]
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "click_element",
            description: """
                Clicks a UI element (e.g. a button, menu item, tab, or checkbox) identified by its \
                visible title, label, or description. Searches the Accessibility hierarchy \
                so you do not need to guess pixel coordinates.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "element_text": {
                      "type": "string",
                      "description": "Visible text, title, or accessible label of the UI element to click (e.g. 'Submit', 'OK', '送信')."
                    },
                    "app_name": {
                      "type": "string",
                      "description": "Name of the target application (e.g. 'Slack', 'Safari', 'Terminal'). If omitted, searches the frontmost window."
                    },
                    "role": {
                      "type": "string",
                      "description": "Optional UI element role filter (e.g. 'button', 'menuitem', 'checkbox')."
                    }
                  },
                  "required": ["element_text"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let text = parsed.string("element_text"), !text.isEmpty else {
            return "Error: 'element_text' parameter is required."
        }

        let appName = parsed.string("app_name")
        let role = parsed.string("role")

        guard let session = ActionAuthorization.current else { throw ActionAuthorizationError.approvalRequired }
        guard let snapshot = await session.nativeObservation else { throw ActionAuthorizationError.staleTarget }
        let candidate = try Self.observedCandidate(snapshot, text: text, role: role)
        try await DesktopActionAuthorization.requireApproval(operation: "Click element", details: String(decoding: arguments, as: UTF8.self) + "\nObserved element: \(candidate.id); coordinate: [\(candidate.center.x), \(candidate.center.y)]", requestedApp: appName, expected: snapshot)
        try Task.checkCancellation()
        do {
            try synthesizer.click(at: candidate.center)
            return "Clicked observed element '\(candidate.label)' (\(candidate.id))."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

/// Executes an AppleScript snippet via `osascript` to automate macOS applications and system state.
///
/// `do shell script` makes this arbitrary code execution, so every run goes
/// through `approver` with the literal script. The default refuses.
public struct RunAppleScriptTool: AgentTool {
    public let timeoutSeconds: TimeInterval
    private let approver: any ToolApproving

    public init(
        timeoutSeconds: TimeInterval = 15,
        approver: any ToolApproving = DenyAllToolApprover()
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.approver = approver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "run_applescript",
            description: """
                Executes an AppleScript command or script on macOS. \
                Useful for controlling native Mac apps (Finder, Safari, Notes, Calendar, Music, etc.), \
                activating applications, querying system settings, or triggering complex workflows.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "script": {
                      "type": "string",
                      "description": "The AppleScript code to execute."
                    }
                  },
                  "required": ["script"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let script = parsed.string("script"), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'script' parameter is required."
        }

        if ActionAuthorization.current == nil {
            if let refusal = await approver.gate(ToolApprovalRequest(
                toolName: definition.name,
                title: "Run AppleScript",
                detail: ApprovalText.visible(script, keepingLineBreaks: true),
                warning: "AppleScript can run shell commands and control any app.")) {
                return refusal
            }
        } else {
            try await DesktopActionAuthorization.requireApproval(operation: "Run AppleScript", details: script)
        }
        try Task.checkCancellation()
        return try await executeAppleScript(script)
    }

    private func executeAppleScript(_ script: String) async throws -> String {
        let output = try await CancellableToolProcess.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: timeoutSeconds)
        if output.timedOut { return "AppleScript execution timed out after \(Int(timeoutSeconds)) seconds." }
        if output.status == 0 { return output.stdout.isEmpty ? "AppleScript completed successfully with no output." : output.stdout }
        return "AppleScript error (\(output.status)): \(output.stderr.isEmpty ? output.stdout : output.stderr)"
    }
}

/// Inspects actionable UI elements of the active window with exact screen coordinates and privacy filtering.
public struct InspectUIElementsTool: AgentTool {
    /// `excluding` is added to `ScreenCapturer.processWideExclusion`, which the
    /// OCR fallback's capture always honours.
    public static func makeDefaultInspector(
        maxCandidates: Int = 25, excluding isExcluded: ScreenCapturer.WindowExclusion? = nil
    ) -> AccessibilityInspector {
        let capturer = ScreenCapturer()
        let recognizer = TextRecognizer()
        let selected = ActionAuthorization.current?.targetWindow
        return AccessibilityInspector(
            maxCandidates: maxCandidates,
            fallbackProvider: { pid, windowBounds in
                do {
                    let image: CGImage
                    if let selected {
                        let capture = try await capturer.captureWindow(selected, excluding: isExcluded ?? { _, _ in false })
                        guard capture.processID == pid, capture.bundleID == selected.bundleID,
                              capture.frame == windowBounds else { return [] }
                        image = capture.image
                    } else {
                        image = try await capturer.captureFocusedWindow(pid: pid, excluding: isExcluded)
                    }
                    return try await recognizer.recognizeCandidates(in: image, windowFrame: windowBounds)
                } catch {
                    return []
                }
            },
            targetWindow: selected,
            requiresWindowScope: ActionAuthorization.current?.requiresWindowScope == true
        )
    }

    private let candidateProvider: (@Sendable (Int) async -> [UIElementCandidate])?
    private let inspectorProvider: @Sendable (Int) -> any UIStateProviding

    public init(inspectorProvider: @escaping @Sendable (Int) -> any UIStateProviding = { InspectUIElementsTool.makeDefaultInspector(maxCandidates: $0) }, candidateProvider: (@Sendable (Int) async -> [UIElementCandidate])? = nil) {
        self.inspectorProvider = inspectorProvider
        self.candidateProvider = candidateProvider
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "inspect_ui_elements",
            description: """
                Inspect actionable UI elements (buttons, text fields, checkboxes, tabs, etc.) of the active window \
                with exact screen coordinates and labels, applying strict privacy filtering to redact passwords and secrets.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "max_candidates": {
                      "type": "integer",
                      "minimum": 1,
                      "maximum": 25,
                      "description": "Maximum number of UI elements to return (default: 25)."
                    }
                  }
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let maxCandidates = min(max(parsed.int("max_candidates") ?? 25, 1), 25)
        let inspector = inspectorProvider(maxCandidates)
        let candidates: [UIElementCandidate]
        if let candidateProvider { candidates = await candidateProvider(maxCandidates) }
        else {
            let snapshot = try await inspector.captureSnapshot()
            await ActionAuthorization.current?.recordNativeObservation(snapshot)
            candidates = snapshot.visibleCandidates
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(candidates)
        return String(decoding: encoded, as: UTF8.self)
    }
}

/// Autonomous desktop action tool using TypeSafe Jev System One model.
/// Inspects the active window, evaluates actionable candidates via Jev, and synthesizes the optimal action.
///
/// When the decision is to type, the text goes through `approver` like
/// ``ComputerActionTool``'s `type`. The default refuses.
public struct TypeSafeActTool: AgentTool {
    private let inspectorProvider: @Sendable (Int) -> any UIStateProviding
    private let engineProvider: @Sendable () -> TypeSafeDecisionEngine
    private let synthesizer: any EventSynthesizing
    private let approver: any ToolApproving
    private let frontmostApp: @Sendable () -> String?

    public init(
        inspectorProvider: @escaping @Sendable (Int) -> any UIStateProviding = { InspectUIElementsTool.makeDefaultInspector(maxCandidates: $0) },
        engineProvider: @escaping @Sendable () -> TypeSafeDecisionEngine = { TypeSafeDecisionEngine() },
        synthesizer: any EventSynthesizing = EventSynthesizer(),
        approver: any ToolApproving = DenyAllToolApprover(),
        frontmostApp: @escaping @Sendable () -> String? = KeystrokeApproval.frontmostAppName
    ) {
        self.inspectorProvider = inspectorProvider
        self.engineProvider = engineProvider
        self.synthesizer = synthesizer
        self.approver = approver
        self.frontmostApp = frontmostApp
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "typesafe_act",
            description: """
                Autonomous desktop GUI action powered by the TypeSafe Jev System One model (<200ms). \
                Inspects the currently active window, matches candidates against the user's goal, and automatically \
                performs the necessary click, double-click, or text typing action. Use this when the user asks \
                to click, type, press a button, or interact with what is currently on the screen.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "goal": {
                      "type": "string",
                      "description": "The specific objective or UI action to perform on screen (e.g. 'Click Search button and type Tokyo', 'Click OK', 'Select the text field and enter password')."
                    }
                  },
                  "required": ["goal"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let goal = parsed.string("goal"), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'goal' parameter is required."
        }

        let inspector = inspectorProvider(25)
        let observed = try await inspector.captureSnapshot()
        let candidates = observed.visibleCandidates

        let engine = engineProvider()
        let decision = try await engine.decideNextAction(goal: goal, candidates: candidates)

        if decision.action != .none && decision.action != .wait {
            try await DesktopActionAuthorization.requireApproval(operation: decision.action.rawValue, details: "Goal: \(goal)\nDecision: \(decision)", expected: observed)
        }
        try Task.checkCancellation()
        var executedSummary = "Action: \(decision.action.rawValue)"
        if let targetCenter = decision.targetCenter, decision.action != .none {
            do {
                switch decision.action {
                case .click:
                    try synthesizer.click(at: targetCenter)
                    executedSummary += " (clicked at \(Int(targetCenter.x)), \(Int(targetCenter.y)))"
                case .doubleClick:
                    try synthesizer.click(at: targetCenter, clickCount: 2)
                    executedSummary += " (double-clicked at \(Int(targetCenter.x)), \(Int(targetCenter.y)))"
                case .typeText:
                    if let text = decision.textInput {
                        if ActionAuthorization.current == nil,
                           let refusal = await approver.gate(KeystrokeApproval.request(
                            tool: definition.name, title: "Type text", keystrokes: text, app: frontmostApp())) {
                            return refusal
                        }
                        try synthesizer.typeText(text)
                        executedSummary += " (typed '\(text)')"
                    }
                default:
                    break
                }
            } catch {
                executedSummary += " (execution note: \(error.localizedDescription))"
            }
        }

        if let elementId = decision.targetElementId {
            executedSummary += " on target element '\(elementId)'"
        }
        executedSummary += ". Confidence: \(String(format: "%.2f", decision.confidence)). Completed: \(decision.isCompleted)."
        return executedSummary
    }
}

/// Searches files on macOS using Spotlight (`mdfind`) and FileManager.
public struct FindFilesTool: AgentTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "find_files",
            description: """
                Finds files on macOS matching a search query or filename pattern. \
                Searches user documents, desktop, downloads, code, and home directories. \
                Returns matching file paths, sizes, and locations.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "query": {
                      "type": "string",
                      "description": "Search query or filename pattern (e.g. 'notes.txt', 'budget', '*.swift', 'presentation')."
                    },
                    "search_path": {
                      "type": "string",
                      "description": "Optional directory to limit search to (e.g. '~/Documents', '~/Desktop', '~/Downloads'). Defaults to home directory."
                    },
                    "limit": {
                      "type": "integer",
                      "description": "Maximum number of results to return (default: 10, max: 30)."
                    }
                  },
                  "required": ["query"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let query = parsed.string("query"), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'query' parameter is required."
        }

        if let limit = parsed.int("limit"), limit <= 0 {
            return "Error: 'limit' must be positive."
        }
        let limit = min(parsed.int("limit") ?? 10, 30)
        let searchPath = parsed.string("search_path").map { NSString(string: $0).expandingTildeInPath }

        return await searchFiles(query: query, inDirectory: searchPath, limit: limit)
    }

    /// How long Spotlight gets before the search is abandoned. A wedged `mdfind`
    /// (index rebuilding, huge result set) must not hold the agent's turn open.
    static let searchTimeout: TimeInterval = 10

    /// `mdfind` has no `--`, and reads any argument that starts with `-` as one
    /// of its own options (`-live` never returns, `-attr` changes the output).
    /// The query comes from the model, so a leading dash is quoted into a
    /// Spotlight string literal, which is not an option.
    static func mdfindQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return trimmed }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func mdfindArguments(query: String, inDirectory: String?) -> [String] {
        let query = mdfindQuery(query)
        guard let dir = inDirectory else { return [query] }
        return ["-onlyin", dir, query]
    }

    /// Output collected from a pipe on another thread, so a chatty child cannot
    /// fill the pipe and stall while we wait for it to exit.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Runs `executable`, killing it after `timeout`. Returns what it printed
    /// and whether the timeout fired; throws when it could not be started.
    static func run(
        executable: URL, arguments: [String], timeout: TimeInterval
    ) throws -> (output: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // The child holds its own copy; ours must go or the read never sees EOF.
        try? outPipe.fileHandleForWriting.close()

        let box = OutputBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            reader.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = reader.wait(timeout: .now() + 2)
        return (String(decoding: box.value, as: UTF8.self), timedOut)
    }

    private func searchFiles(query: String, inDirectory: String?, limit: Int) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (output, timedOut) = try Self.run(
                        executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
                        arguments: Self.mdfindArguments(query: query, inDirectory: inDirectory),
                        timeout: Self.searchTimeout)
                    let rawLines = output.split(separator: "\n").map(String.init)

                    let filtered = rawLines.filter { path in
                        !path.contains("/Library/") && !path.contains("/.Trash/")
                    }

                    if filtered.isEmpty {
                        if timedOut {
                            continuation.resume(returning: "File search timed out after \(Int(Self.searchTimeout)) seconds without results; try a narrower query or search_path.")
                            return
                        }
                        let fmResults = self.fallbackFileManagerSearch(query: query, inDirectory: inDirectory, limit: limit)
                        if fmResults.isEmpty {
                            continuation.resume(returning: "No files found matching '\(query)'.")
                        } else {
                            continuation.resume(returning: "Found \(fmResults.count) file(s):\n" + fmResults.joined(separator: "\n"))
                        }
                        return
                    }

                    let results = filtered.prefix(limit).map { path -> String in
                        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                        let size = (attributes?[.size] as? Int64) ?? 0
                        return "- \(path) (\(size) bytes)"
                    }

                    continuation.resume(returning: "Found \(filtered.count) matching file(s) (showing top \(results.count)):\n" + results.joined(separator: "\n"))
                } catch {
                    let fmResults = self.fallbackFileManagerSearch(query: query, inDirectory: inDirectory, limit: limit)
                    if fmResults.isEmpty {
                        continuation.resume(returning: "Error executing file search: \(error.localizedDescription)")
                    } else {
                        continuation.resume(returning: "Found \(fmResults.count) file(s):\n" + fmResults.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    private func fallbackFileManagerSearch(query: String, inDirectory: String?, limit: Int) -> [String] {
        let base = inDirectory ?? NSHomeDirectory()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [String] = []
        let lowerQuery = query.lowercased()

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            if name.contains(lowerQuery) {
                matches.append("- \(fileURL.path)")
                if matches.count >= limit { break }
            }
        }
        return matches
    }
}

/// Opens a file, folder, or application on macOS via the system `open` command.
///
/// Opening can launch an application or a `.command` / `.app` file, so it is
/// approved like any other execution.
public struct OpenFileTool: AgentTool {
    private let approver: any ToolApproving

    public init(approver: any ToolApproving = DenyAllToolApprover()) {
        self.approver = approver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "open_file",
            description: """
                Opens a file, directory, or application on macOS. \
                Brings the opened file or application to the front. \
                Can optionally specify an application to open the file with (e.g. 'TextEdit', 'Notes', 'Visual Studio Code', 'Finder').
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "file_path": {
                      "type": "string",
                      "description": "Path to the file or directory to open (e.g. '~/Documents/notes.txt', '/Applications/Notes.app')."
                    },
                    "app_name": {
                      "type": "string",
                      "description": "Optional application name to open with (e.g. 'TextEdit', 'Safari', 'Finder'). If omitted, opens with default app."
                    }
                  },
                  "required": ["file_path"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let path = parsed.string("file_path"), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'file_path' parameter is required."
        }

        let appName = parsed.string("app_name")
        let expandedPath = Self.optionSafe(NSString(string: path).expandingTildeInPath)
        if ActionAuthorization.current == nil {
            if let refusal = await approver.gate(ToolApprovalRequest(
                toolName: definition.name, title: "Open a file or application",
                detail: "Path: \(ApprovalText.visible(expandedPath))"
                    + (appName.map { $0.isEmpty ? "" : "\nWith app: \(ApprovalText.visible($0))" } ?? ""),
                warning: "Opening an app or script file can run code.")) { return refusal }
        } else {
            try await DesktopActionAuthorization.requireApproval(operation: "Open file or handler", details: String(decoding: arguments, as: UTF8.self))
        }
        try Task.checkCancellation()
        let args = appName.flatMap { $0.isEmpty ? nil : $0 }.map { ["-a", $0, expandedPath] } ?? [expandedPath]
        let output = try await CancellableToolProcess.run(executable: "/usr/bin/open", arguments: args)
        if output.status == 0 { return "Successfully opened '\(expandedPath)'." }
        return "Failed to open '\(expandedPath)': \(output.stderr)"
    }

    static func optionSafe(_ path: String) -> String {
        path.hasPrefix("-") ? "./" + path : path
    }
}

/// Directly creates, overwrites, or appends text to a file on macOS.
///
/// Paths that persist code execution (shell rc files, dotfiles in `$HOME`,
/// LaunchAgents, system directories) are refused outright by
/// ``FileWritePolicy``; every other write needs approval, with the path and the
/// content shown.
public struct WriteFileTool: AgentTool {
    /// How much of the content the approval prompt shows.
    static let previewCharacterLimit = 2_000

    private let approver: any ToolApproving
    private let home: URL

    public init(
        approver: any ToolApproving = DenyAllToolApprover(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.approver = approver
        self.home = home
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: """
                Writes, creates, or appends text to a file on the local filesystem. \
                Use this when the user asks to save text, write notes, create a file, or edit file contents.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "file_path": {
                      "type": "string",
                      "description": "Target file path to write to (e.g. '~/Desktop/memo.txt', '~/Documents/notes.md')."
                    },
                    "content": {
                      "type": "string",
                      "description": "Text content to write into the file."
                    },
                    "mode": {
                      "type": "string",
                      "enum": ["overwrite", "append"],
                      "description": "Write mode: 'overwrite' to replace entire file, 'append' to add to end of file. Defaults to 'overwrite'."
                    }
                  },
                  "required": ["file_path", "content"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let path = parsed.string("file_path"), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'file_path' parameter is required."
        }
        guard let content = parsed.string("content") else {
            return "Error: 'content' parameter is required."
        }

        let mode = parsed.string("mode") ?? "overwrite"
        let expandedPath = NSString(string: path).expandingTildeInPath

        let outsideHome: Bool
        switch FileWritePolicy.evaluate(path: path, home: home) {
        case .denied(let reason):
            return "Error: writing '\(expandedPath)' is not allowed: \(reason). Tell the user instead of trying another path."
        case .needsApproval(let outside): outsideHome = outside
        }

        do {
            // Freeze both the destination and contents before either approval UI awaits.
            let parents: GuardedFileWriter.ParentCreation?
            let existingDestination: GuardedFileWriter.Destination?
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: expandedPath).deletingLastPathComponent().path) {
                parents = nil
                existingDestination = try GuardedFileWriter.Destination(expandedPath)
            } else {
                parents = try GuardedFileWriter.ParentCreation(expandedPath)
                existingDestination = nil
            }
            let original = try existingDestination.flatMap { try GuardedFileWriter.snapshot($0) }
            if ActionAuthorization.current != nil {
                try await ActionAuthorization.requireApproval(
                    operation: original == nil ? "Create file" : (mode == "append" ? "Append to existing file" : "Overwrite existing file"),
                    target: existingDestination?.path ?? expandedPath, details: content,
                    consequence: original == nil ? "Create a new file and any missing parent directories at this destination." : (mode == "append" ? "Add content to this file." : "Replace the existing file contents."),
                    revalidate: {
                        if let destination = existingDestination {
                            guard destination.isCurrent() else { return false }
                            return try GuardedFileWriter.snapshot(destination) == original
                        }
                        return parents?.isCurrent() == true
                    })
            } else {
                let preview = ApprovalText.visible(
                    ApprovalText.truncated(content, limit: Self.previewCharacterLimit), keepingLineBreaks: true)
                if let refusal = await approver.gate(ToolApprovalRequest(
                    toolName: definition.name,
                    title: mode == "append" ? "Append to a file" : "Write a file",
                    detail: "Path: \(ApprovalText.visible(expandedPath))\nMode: \(ApprovalText.visible(mode))\nLength: \(content.count) characters\n\n\(preview)",
                    warning: outsideHome ? "This path is outside your home folder." : nil)) { return refusal }
            }
            try Task.checkCancellation()
            guard case .needsApproval = FileWritePolicy.evaluate(path: path, home: home) else {
                throw ActionAuthorizationError.staleTarget
            }
            let destination: GuardedFileWriter.Destination
            if let existingDestination { destination = existingDestination }
            else if let parents { destination = try parents.create() }
            else { throw ActionAuthorizationError.staleTarget }
            try GuardedFileWriter.write(Data(content.utf8), to: destination,
                                        append: mode == "append", expected: original)
            return "Successfully \(mode == "append" ? "appended" : "wrote") \(content.count) characters to '\(expandedPath)'."
        } catch {
            if error is ActionAuthorizationError || error is CancellationError { await ActionAuthorization.current?.abort(error) }
            return "Error writing to file: \(error.localizedDescription)"
        }
    }
}

/// Scrolls a target application (e.g. Google Chrome, Safari, Firefox, or any pinned window) in the background
/// without stealing focus, without moving the physical cursor, and gathers newly visible text across multiple scroll steps.
public struct ScrollPageContentTool: AgentTool {
    public typealias BackgroundCollector = @Sendable (_ steps: Int, _ deltaY: Int32, _ delayMs: Int, _ appName: String?) async throws -> String

    private let collector: BackgroundCollector?
    public let toolName: String

    public init(name: String = "scroll_page_content", collector: BackgroundCollector? = nil) {
        self.toolName = name
        self.collector = collector
    }

    public init(collector: (@Sendable (_ steps: Int, _ deltaY: Int32, _ delayMs: Int) async throws -> String)? = nil) {
        self.toolName = "scroll_pinned_window"
        if let collector {
            self.collector = { steps, deltaY, delayMs, _ in
                try await collector(steps, deltaY, delayMs)
            }
        } else {
            self.collector = nil
        }
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: """
                Scrolls a web browser (Google Chrome, Safari, Firefox, Arc, Edge, etc.) or document window \
                in the background — without taking focus, raising the window, or moving the user's cursor — \
                and returns the text that becomes visible at each step. Targets the pinned window when there \
                is one, otherwise the active browser or most recent application window, on any display. \
                Use it to read or collect content from a page, feed, or document the user is viewing. \
                It does not click, type, or navigate: for interacting with a web page (searching a site, \
                forms, logins, structured extraction) use the browser_* tools instead.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "steps": {
                      "type": "integer",
                      "description": "Number of scroll steps to perform (default: 3, min: 1, max: 10)."
                    },
                    "delta_y": {
                      "type": "number",
                      "description": "Vertical scroll line amount per step (negative = down/downward, positive = up/upward). Defaults to -10."
                    },
                    "delay_ms": {
                      "type": "integer",
                      "description": "Delay in milliseconds between scroll steps to allow page rendering (default: 350)."
                    },
                    "app_name": {
                      "type": "string",
                      "description": "Optional application name hint (e.g. 'Google Chrome', 'Safari', 'Firefox'). If omitted, auto-detects the active browser or pinned target."
                    }
                  }
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        if let session = ActionAuthorization.current,
           session.requiresWindowScope, session.targetWindow == nil {
            throw ActionAuthorizationError.staleTarget
        }
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let steps = min(max(parsed.int("steps") ?? 3, 1), 10)
        let deltaY: Int32
        if let num = parsed["delta_y"] as? NSNumber {
            deltaY = num.int32Value
        } else if let val = parsed["delta_y"] as? Int {
            deltaY = Int32(val)
        } else if let val = parsed["delta_y"] as? Double {
            deltaY = Int32(val)
        } else {
            deltaY = -10
        }
        let delayMs = min(max(parsed.int("delay_ms") ?? 350, 100), 2000)
        let appName = parsed.string("app_name")

        guard let collector else {
            return "Error: Background scrolling collector is not configured."
        }

        return try await collector(steps, deltaY, delayMs, appName)
    }
}

/// Backwards compatibility alias for `ScrollPageContentTool`.
public typealias ScrollPinnedWindowTool = ScrollPageContentTool
