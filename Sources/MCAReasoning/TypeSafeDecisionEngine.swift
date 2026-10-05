import CoreGraphics
import Foundation
import MCACore
import OSLog
#if canImport(AppKit)
import AppKit
#endif


/// High-speed System One decision engine for computer automation powered by TypeSafe Jev.
public struct TypeSafeDecisionEngine: Sendable {
    // Internal fixture viewport; task-local so concurrent tests and production
    // calls keep their own fallback context. Default remains the live screen.
    @TaskLocal static var fallbackScrollViewport: CGRect?
    private let log = Logger(subsystem: "com.buddypia.mca", category: "TypeSafeDecisionEngine")
    public let client: any TypeSafeEvaluating

    /// Custom evaluator closure for testing and offline mocking.
    public typealias Evaluator = @Sendable (TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse
    private let customEvaluator: Evaluator?

    /// Captures the screen as an image data URL, or `nil` when it cannot.
    public typealias Screenshot = @Sendable () async -> String?
    /// Consulted only when the text-only decision would escalate (see `decideNextAction`).
    private let screenshot: Screenshot?

    /// Confidence threshold below which an action is escalated to System Two or user review.
    public let confidenceThreshold: Float

    public init(
        client: any TypeSafeEvaluating = TypeSafeClient(),
        confidenceThreshold: Float = 0.80,
        customEvaluator: Evaluator? = nil,
        screenshot: Screenshot? = nil
    ) {
        self.client = client
        self.confidenceThreshold = confidenceThreshold
        self.customEvaluator = customEvaluator
        self.screenshot = screenshot
    }

    private func evaluate(_ request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
        if let customEvaluator { return try await customEvaluator(request) }
        return try await client.evaluate(request: request)
    }

    /// A screenshot is slow (6-14s on Clef against 1-3s for text), so it is taken only
    /// when the model can read it and the text-only answer was not good enough.
    private var canLook: Bool {
        screenshot != nil && (customEvaluator != nil || client.acceptsImages)
    }

    private func asking(_ request: TypeSafeClient.EvaluationRequest, withScreenshot image: String) -> TypeSafeClient.EvaluationRequest {
        var request = request
        request.images = [image]
        return request
    }

    /// Re-asks with the screenshot. Its answer replaces the text one only if it is decisive on
    /// its own (would not escalate); otherwise the loop escalates exactly as before.
    private func reconsiderWithScreenshot(
        _ textDecision: ComputerActionDecision,
        request: TypeSafeClient.EvaluationRequest,
        interpret: (TypeSafeClient.EvaluationResponse) -> ComputerActionDecision
    ) async -> ComputerActionDecision {
        guard canLook, shouldEscalate(decision: textDecision), let image = await screenshot?() else {
            return textDecision
        }
        guard let response = try? await evaluate(asking(request, withScreenshot: image)) else {
            log.warning("System One screenshot retry failed; keeping the text-only decision.")
            return textDecision
        }
        var seen = interpret(response)
        guard !shouldEscalate(decision: seen) else { return textDecision }
        seen.reasoning = (seen.reasoning ?? "") + " [screenshot]"
        return seen
    }

    /// Evaluates whether a given decision should be escalated to System 2 (reasoning LLM).
    public func shouldEscalate(decision: ComputerActionDecision) -> Bool {
        decision.confidence < confidenceThreshold || (decision.action == .none && !decision.isCompleted)
    }

    /// Evaluates the user's goal against screen UI candidates, returning a structured decision.
    public func decideNextAction(
        goal: String,
        activeApp: String? = nil,
        candidates: [UIElementCandidate],
        history: [LoopStepRecord] = [],
        recentEscalations: [EscalationRecord] = [],
        lastDiff: UIStateDiff? = nil
    ) async throws -> ComputerActionDecision {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        // Missing candidates are unresolved regardless of prior failed attempts.
        // The coordinator bounds escalation; failure history is not completion evidence.
        if candidates.isEmpty {
            let lowConfidenceEscalationCount = recentEscalations.filter {
                if case .lowConfidence = $0.reason { return true }
                return false
            }.count

            if lowConfidenceEscalationCount >= 2 {
                return ComputerActionDecision(
                    targetElementId: nil,
                    action: .none,
                    confidence: 0.0,
                    isCompleted: false,
                    targetCenter: nil,
                    textInput: nil,
                    keyCombination: nil,
                    scrollDelta: nil,
                    reasoning: "Target remains unresolved after \(lowConfidenceEscalationCount) low-confidence attempts; requires System 2 resolution (offline fallback)"
                )
            }

            let blind = ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: 0.0,
                isCompleted: false,
                targetCenter: nil,
                textInput: nil,
                keyCombination: nil,
                scrollDelta: nil,
                reasoning: "No actionable UI element candidates observed on screen. Escalating to System 2."
            )
            // Without candidates there is nothing to click, but the screenshot can still
            // show the goal is already done.
            var questions = Self.actionQuestions
            questions.removeValue(forKey: "target_element")
            let request = TypeSafeClient.EvaluationRequest(
                state: .dictionary(["user_goal": .string(trimmedGoal), "active_app": .string(activeApp ?? "Unknown"), "candidates": .array([])]),
                model: "jev-latest",
                questions: questions
            )
            let seen = await reconsiderWithScreenshot(blind, request: request) {
                interpret($0, goal: trimmedGoal, candidates: [], candidateTextSpans: [])
            }
            // Only a completion is taken from this path. A scroll, key or wait chosen without
            // any AX candidate could repeat forever without ever reaching System 2.
            return seen.isCompleted ? seen : blind
        }

        // Cap candidates to maintain sub-150ms latency while prioritizing candidates matching goal and actionable elements
        let cappedCandidates: [UIElementCandidate] = {
            if candidates.count <= 50 {
                return candidates
            }
            let lowerGoal = trimmedGoal.lowercased()
            let matched = candidates.filter { c in
                !c.label.isEmpty && !lowerGoal.isEmpty &&
                    Self.isDirectMatch(target: c.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), query: lowerGoal)
            }
            let matchedIds = Set(matched.map(\.id))
            let actionable = candidates.filter { $0.isActionable && !matchedIds.contains($0.id) }
            let otherIds = matchedIds.union(actionable.map(\.id))
            let nonActionable = candidates.filter { !otherIds.contains($0.id) }
            return Array((matched + actionable + nonActionable).prefix(50))
        }()

        // Build candidate map for Choice criteria
        var candidateCriteria: [String: String] = [:]
        for c in cappedCandidates {
            let label = c.label.isEmpty ? (c.value ?? "unnamed") : c.label
            let b = c.bounds
            let boundsDesc = (b.minX.isFinite && b.minY.isFinite && b.width.isFinite && b.height.isFinite)
                ? "[\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height))]"
                : "[\(b.minX),\(b.minY),\(b.width),\(b.height)]"
            let valueDesc = (c.value != nil && !c.value!.isEmpty) ? " (value: '\(c.value!)')" : ""
            candidateCriteria[c.id] = "\(c.role): '\(label)' at \(boundsDesc)\(valueDesc)"
        }
        candidateCriteria["none"] = "No matching or suitable UI element for this goal on screen"

        // Build state JSON
        let candidateItems: [AnyCodableValue] = cappedCandidates.map { c in
            .dictionary([
                "id": .string(c.id),
                "role": .string(c.role),
                "label": .string(c.label),
                "value": c.value.map { .string($0) } ?? .null,
                "bounds": .array([
                    .number(Double(c.bounds.origin.x)),
                    .number(Double(c.bounds.origin.y)),
                    .number(Double(c.bounds.size.width)),
                    .number(Double(c.bounds.size.height)),
                ]),
                "is_actionable": .bool(c.isActionable),
                "source": .string(c.source.rawValue)
            ])
        }

        let stateDict: [String: AnyCodableValue] = [
            "user_goal": .string(trimmedGoal),
            "active_app": .string(activeApp ?? "Unknown"),
            "candidates": .array(candidateItems),
        ]

        // Extract candidate text spans from goal for speculative text selection
        let candidateTextSpans = Self.extractCandidateTextSpans(from: trimmedGoal)

        // Build speculative parallel questions
        var questions = Self.actionQuestions
        questions["target_element"] = TypeSafeClient.QuestionPayload(
            type: "choice",
            instructions: "Which UI element candidate should be acted on next to advance the user's goal?",
            criteria: candidateCriteria
        )

        // If multiple text spans were extracted, ask Jev to pick the intended text
        if candidateTextSpans.count > 1 {
            var textCriteria: [String: String] = [:]
            for (idx, span) in candidateTextSpans.enumerated() {
                textCriteria["span_\(idx)"] = span
            }
            textCriteria["none"] = "Do not type any text"
            questions["text_selection"] = TypeSafeClient.QuestionPayload(
                type: "choice",
                instructions: "Which text span from the user goal is the intended text to type into the field?",
                criteria: textCriteria
            )
        }

        let request = TypeSafeClient.EvaluationRequest(
            state: .dictionary(stateDict),
            model: "jev-latest",
            questions: questions
        )

        let response: TypeSafeClient.EvaluationResponse
        do {
            response = try await evaluate(request)
        } catch {
            log.warning("System One model unavailable (\(error.localizedDescription)); using local deterministic grounding fallback.")
            return fallbackLocalDecision(
                goal: trimmedGoal,
                candidates: candidates,
                history: history,
                recentEscalations: recentEscalations,
                lastDiff: lastDiff
            )
        }

        let decision = interpret(response, goal: trimmedGoal, candidates: candidates, candidateTextSpans: candidateTextSpans)
        return await reconsiderWithScreenshot(decision, request: request) {
            interpret($0, goal: trimmedGoal, candidates: candidates, candidateTextSpans: candidateTextSpans)
        }
    }

    /// Questions that do not depend on the candidates; `target_element` is added per call.
    static let actionQuestions: [String: TypeSafeClient.QuestionPayload] = [
        "action_type": TypeSafeClient.QuestionPayload(
            type: "choice",
            instructions: "What action should be taken on the computer interface to advance the goal?",
            criteria: [
                "click": "Standard single left click on target element (e.g. buttons, links, tabs)",
                "double_click": "Double click on target element (e.g. open file, select word)",
                "right_click": "Right click for context menu on target element",
                "type": "Type text into target input field, search box, or focused element",
                "key": "Press a keyboard shortcut or control key (e.g. Return, Escape, Tab, Cmd+C)",
                "scroll": "Scroll the screen, window, feed, or document view (e.g. down, up, left, right)",
                "wait": "Wait for loading, animation, or rendering to complete",
                "none": "Do nothing, or goal is completed, or cannot determine action",
            ]
        ),
        "is_completed": TypeSafeClient.QuestionPayload(
            type: "noul",
            instructions: "Is the user's goal or current subgoal already fully accomplished on the current screen?"
        ),
        "scroll_direction": TypeSafeClient.QuestionPayload(
            type: "choice",
            instructions: "If scrolling is needed, in which direction should the screen or element be scrolled?",
            criteria: [
                "down": "Scroll downward to reveal lower/upcoming content (standard feed browsing)",
                "up": "Scroll upward to return towards the top",
                "right": "Scroll horizontally to the right",
                "left": "Scroll horizontally to the left",
                "none": "No scrolling needed",
            ]
        ),
        "key_target": TypeSafeClient.QuestionPayload(
            type: "choice",
            instructions: "If a key press or keyboard shortcut is needed, which key should be pressed?",
            criteria: [
                "return": "Return / Enter key (submit form, confirm search, activate default action)",
                "escape": "Escape key (dismiss dialog, cancel modal, exit fullscreen)",
                "tab": "Tab key (navigate to next focusable input field)",
                "space": "Spacebar (toggle checkbox, activate button)",
                "backspace": "Delete / Backspace key",
                "cmd_a": "Command+A (select all)",
                "cmd_c": "Command+C (copy selection)",
                "cmd_v": "Command+V (paste clipboard)",
                "cmd_f": "Command+F (find in page/app)",
                "cmd_w": "Command+W (close tab or window)",
                "cmd_s": "Command+S (save file/document)",
                "arrow_down": "Down Arrow key",
                "arrow_up": "Up Arrow key",
                "other_or_none": "Custom shortcut specified in goal text or no key needed",
            ]
        )
    ]

    /// Turns the model's answers into a decision. Pure: no I/O, so the screenshot retry can reuse it.
    private func interpret(
        _ response: TypeSafeClient.EvaluationResponse,
        goal trimmedGoal: String,
        candidates: [UIElementCandidate],
        candidateTextSpans: [String]
    ) -> ComputerActionDecision {
        // Parse answers
        let targetChoice = response.answers["target_element"]?.choice
        let targetConfidence = response.answers["target_element"]?.confidence ?? 0.0
        let actionRaw = response.answers["action_type"]?.choice ?? "none"
        let actionConfidence = response.answers["action_type"]?.confidence ?? 0.0
        let isCompletedProbability = response.answers["is_completed"]?.noul ?? 0.0

        // Check completion first
        let isCompleted = isCompletedProbability >= 0.70
        if isCompleted {
            return ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: isCompletedProbability,
                isCompleted: true,
                reasoning: "Goal is accomplished based on current screen state (p=\(String(format: "%.2f", isCompletedProbability)))"
            )
        }

        let actionType = ComputerActionDecision.ActionType(rawValue: actionRaw) ?? .none

        // Handle action-specific parameters
        switch actionType {
        case .scroll:
            let scrollDirChoice = response.answers["scroll_direction"]?.choice ?? response.answers["scroll_delta"]?.choice
            let delta = Self.extractScrollDelta(from: trimmedGoal, jevChoice: scrollDirChoice)
            let selectedCandidate = (targetChoice != nil && targetChoice != "none")
                ? candidates.first(where: { $0.id == targetChoice })
                : nil
            let effectiveConf = actionConfidence > 0 ? actionConfidence : targetConfidence
            return ComputerActionDecision(
                targetElementId: selectedCandidate?.id,
                action: .scroll,
                confidence: effectiveConf,
                isCompleted: false,
                targetCenter: selectedCandidate?.center,
                scrollDelta: delta,
                reasoning: "Scroll \(delta.dy < 0 ? "down" : (delta.dy > 0 ? "up" : "horizontally")) (confidence: \(String(format: "%.2f", effectiveConf)))"
            )

        case .keyPress:
            let keyChoice = response.answers["key_target"]?.choice ?? response.answers["key_combination"]?.choice
            let keys = Self.extractKeyCombination(from: trimmedGoal, jevChoice: keyChoice)
            let selectedCandidate = (targetChoice != nil && targetChoice != "none")
                ? candidates.first(where: { $0.id == targetChoice })
                : nil
            let baseConf = actionConfidence > 0 ? actionConfidence : targetConfidence
            let hasValidKeys = (keys != nil && keys?.isEmpty == false)
            let effectiveConf = hasValidKeys ? baseConf : min(baseConf, 0.50)
            let finalKeys = hasValidKeys ? keys : nil
            return ComputerActionDecision(
                targetElementId: selectedCandidate?.id,
                action: .keyPress,
                confidence: effectiveConf,
                isCompleted: false,
                targetCenter: selectedCandidate?.center,
                keyCombination: finalKeys,
                reasoning: "Press key combination '\(finalKeys?.joined(separator: "+") ?? "unknown")' (confidence: \(String(format: "%.2f", effectiveConf)))"
            )

        case .typeText:
            let textToType: String? = {
                if let direct = response.answers["text_input"]?.choice {
                    return direct
                }
                if let textChoice = response.answers["text_selection"]?.choice,
                   textChoice.hasPrefix("span_"),
                   let idx = Int(textChoice.dropFirst(5)),
                   idx >= 0 && idx < candidateTextSpans.count {
                    return candidateTextSpans[idx]
                }
                if candidateTextSpans.count == 1 {
                    return candidateTextSpans[0]
                }
                return Self.extractTextInput(from: trimmedGoal)
            }()

            guard let selectedId = targetChoice, selectedId != "none",
                  let selectedCandidate = candidates.first(where: { $0.id == selectedId }) else {
                return ComputerActionDecision(
                    targetElementId: nil,
                    action: .none,
                    confidence: 0.0,
                    isCompleted: false,
                    textInput: textToType,
                    reasoning: "Type target field not identified on screen (escalate to System 2)"
                )
            }

            let effectiveConf: Float
            let baseConf = actionConfidence > 0 ? min(targetConfidence, actionConfidence) : targetConfidence
            if textToType != nil {
                effectiveConf = baseConf
            } else {
                effectiveConf = min(baseConf, 0.50)
            }

            return ComputerActionDecision(
                targetElementId: selectedCandidate.id,
                action: .typeText,
                confidence: effectiveConf,
                isCompleted: false,
                targetCenter: selectedCandidate.center,
                textInput: textToType,
                reasoning: "Type '\(textToType ?? "")' into \(selectedCandidate.label) (confidence: \(String(format: "%.2f", effectiveConf)))"
            )

        case .click, .doubleClick, .rightClick:
            guard let selectedId = targetChoice, selectedId != "none",
                  let selectedCandidate = candidates.first(where: { $0.id == selectedId }) else {
                return ComputerActionDecision(
                    targetElementId: nil,
                    action: .none,
                    confidence: 0.0,
                    isCompleted: false,
                    reasoning: "No matching UI candidate found on screen for \(actionType.rawValue) (escalate to System 2)"
                )
            }

            let effectiveConf = actionConfidence > 0 ? min(targetConfidence, actionConfidence) : targetConfidence
            return ComputerActionDecision(
                targetElementId: selectedCandidate.id,
                action: actionType,
                confidence: effectiveConf,
                isCompleted: false,
                targetCenter: selectedCandidate.center,
                reasoning: "\(actionType.rawValue) on '\(selectedCandidate.label)' (confidence: \(String(format: "%.2f", effectiveConf)))"
            )

        case .wait:
            let effectiveConf = actionConfidence > 0 ? actionConfidence : targetConfidence
            return ComputerActionDecision(
                targetElementId: nil,
                action: .wait,
                confidence: effectiveConf,
                isCompleted: false,
                reasoning: "Wait for page/screen rendering to settle (confidence: \(String(format: "%.2f", effectiveConf)))"
            )

        case .none:
            return ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: targetConfidence,
                isCompleted: false,
                reasoning: "No action determined for current goal on screen"
            )
        }
    }

    /// Parameter extraction: candidate text spans from user goal.
    public static func extractCandidateTextSpans(from text: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        // 1. Quoted strings (double, single, Japanese quotes)
        let quotePatterns = [
            "\"([^\"]+)\"",
            "'([^']+)'",
            "「([^」]+)」",
            "『([^』]+)』",
            "“([^”]+)”",
            "‘([^’]+)’"
        ]

        for pat in quotePatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let nsString = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
                for m in matches where m.numberOfRanges >= 2 {
                    let span = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !span.isEmpty && !seen.contains(span) {
                        seen.insert(span)
                        results.append(span)
                    }
                }
            }
        }

        // 2. Keyword-directed patterns (e.g. type: foo, input: bar, text: baz)
        let colonPatterns = [
            "(?:type|input|text|query|search|enter|入力|テキスト|検索)[:：]\\s*([^\\s,;\n]+)",
        ]
        for pat in colonPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                let nsString = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
                for m in matches where m.numberOfRanges >= 2 {
                    let span = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !span.isEmpty && !seen.contains(span) {
                        seen.insert(span)
                        results.append(span)
                    }
                }
            }
        }

        return results
    }

    /// Parameter extraction: single text input to type into focused field.
    public static func extractTextInput(from text: String) -> String? {
        let spans = extractCandidateTextSpans(from: text)
        if let first = spans.first {
            return first
        }

        // Unquoted verb pattern: "type hello world into search" -> "hello world"
        let verbPatterns = [
            "(?:type|enter|input|write)\\s+([a-zA-Z0-9_.@\\-\\s]+?)(?:\\s+(?:in|into|on|to)|$)",
            "(?:search for|query)\\s+([a-zA-Z0-9_.@\\-\\s]+?)(?:\\s+(?:in|into|on|to)|$)",
            "([^\n\\s]+)\\s*と入力",
            "([^\n\\s]+)\\s*を入力"
        ]

        let nsString = text as NSString
        for pat in verbPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
                for m in matches where m.numberOfRanges >= 2 {
                    let val = nsString.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty {
                        return val
                    }
                }
            }
        }

        return nil
    }

    /// Parameter extraction: key combination chord from text or Jev choice.
    public static func extractKeyCombination(from text: String, jevChoice: String? = nil) -> [String]? {
        let lower = text.lowercased()

        // 1. Detect explicit keyboard shortcut chords (e.g. cmd+c, ctrl+alt+delete, cmd+shift+z, Command+Return)
        let chordPattern = "(?:cmd|command|ctrl|control|alt|opt|option|shift)(?:\\s*\\+\\s*(?:cmd|command|ctrl|control|alt|opt|option|shift|\\w+))+"
        if let regex = try? NSRegularExpression(pattern: chordPattern, options: .caseInsensitive) {
            let nsString = text as NSString
            if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsString.length)) {
                let chord = nsString.substring(with: match.range)
                let parts = chord.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                if !parts.isEmpty {
                    return parts
                }
            }
        }

        // 2. Detect standalone or verb-grounded key mentions in text
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        func hasRegexPattern(_ pattern: String) -> Bool {
            lower.range(of: pattern, options: .regularExpression) != nil
        }

        // Return / Enter
        if hasRegexPattern("\\b(?:press|hit|tap)\\s+(?:the\\s+)?(?:return|enter)\\b")
            || hasRegexPattern("\\b(?:return|enter)\\s+key\\b")
            || trimmed == "return" || trimmed == "enter"
            || lower.contains("エンターキー") || lower.contains("リターンキー")
            || lower.contains("エンターを押") || lower.contains("リターンを押")
            || lower.contains("enterキー") || lower.contains("returnキー") {
            return ["Return"]
        }

        // Escape
        if hasRegexPattern("\\b(?:press|hit|tap)\\s+(?:the\\s+)?(?:escape|esc)\\b")
            || hasRegexPattern("\\b(?:escape|esc)\\s+key\\b")
            || hasRegexPattern("\\bescape\\b")
            || trimmed == "esc"
            || lower.contains("エスケープキー") || lower.contains("エスケープを押") || lower.contains("escキー") {
            return ["Escape"]
        }

        // Tab (strictly requires explicit key verb, "tab key", or exact "tab" to avoid colliding with UI tabs / tables)
        if hasRegexPattern("\\b(?:press|hit|tap)\\s+(?:the\\s+)?tab\\b")
            || hasRegexPattern("\\btab\\s+key\\b")
            || trimmed == "tab"
            || lower.contains("タブキー") || lower.contains("tabキー")
            || lower.contains("タブを押") || lower.contains("tabを押") {
            return ["Tab"]
        }

        // Space
        if hasRegexPattern("\\b(?:press|hit|tap)\\s+(?:the\\s+)?(?:space|spacebar)\\b")
            || hasRegexPattern("\\b(?:space|spacebar)\\s+key\\b")
            || hasRegexPattern("\\bspacebar\\b")
            || trimmed == "space"
            || lower.contains("スペースキー") || lower.contains("スペースを押") {
            return ["Space"]
        }

        // Backspace / Delete
        if hasRegexPattern("\\b(?:press|hit|tap)\\s+(?:the\\s+)?(?:backspace|delete)\\b")
            || hasRegexPattern("\\b(?:backspace|delete)\\s+key\\b")
            || hasRegexPattern("\\bbackspace\\b")
            || trimmed == "backspace"
            || lower.contains("バックスペース") || lower.contains("deleteキー") {
            return ["Backspace"]
        }

        // Arrow keys
        if hasRegexPattern("\\b(?:arrow\\s+down|down\\s+arrow|press\\s+down)\\b")
            || lower.contains("下矢印") || lower.contains("下キー") {
            return ["Down"]
        }
        if hasRegexPattern("\\b(?:arrow\\s+up|up\\s+arrow|press\\s+up)\\b")
            || lower.contains("上矢印") || lower.contains("上キー") {
            return ["Up"]
        }

        // 3. Fallback to Jev key_target or key_combination choice
        guard let choice = jevChoice else { return nil }
        if choice.contains(",") {
            let parts = choice.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        if choice.contains("+") {
            let parts = choice.split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        switch choice.lowercased() {
        case "return", "enter": return ["Return"]
        case "escape", "esc": return ["Escape"]
        case "tab": return ["Tab"]
        case "space": return ["Space"]
        case "backspace", "delete": return ["Backspace"]
        case "cmd_a": return ["cmd", "a"]
        case "cmd_c": return ["cmd", "c"]
        case "cmd_v": return ["cmd", "v"]
        case "cmd_f": return ["cmd", "f"]
        case "cmd_w": return ["cmd", "w"]
        case "cmd_s": return ["cmd", "s"]
        case "arrow_down", "down": return ["Down"]
        case "arrow_up", "up": return ["Up"]
        default: return nil
        }
    }

    /// Parameter extraction: scroll delta vector from text or Jev choice.
    public static func extractScrollDelta(from text: String, jevChoice: String? = nil) -> CGVector {
        if let choice = jevChoice, choice.contains(",") {
            let parts = choice.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 2 {
                let dx = CGFloat(parts[0])
                let dy = CGFloat(parts[1])
                if dx.isFinite && dy.isFinite {
                    return CGVector(dx: dx, dy: dy)
                }
                return .zero
            }
        }

        let lower = text.lowercased()

        // Whole words only: "updates", "copyright" and "leftover" are not directions. Latin
        // lookarounds rather than \\b, which treats adjacent kana ("upにスクロール") as a word.
        func hasWord(_ word: String) -> Bool {
            lower.range(of: "(?<![a-z])\(word)(?![a-z])", options: .regularExpression) != nil
        }
        var isUp = !hasWord("down") && (hasWord("up") || lower.contains("上") || lower.contains("戻"))
        var isHorizontalRight = hasWord("right") || lower.contains("右")
        var isHorizontalLeft = hasWord("left") || lower.contains("左")

        if let choice = jevChoice?.lowercased() {
            switch choice {
            case "up": isUp = true
            case "down": isUp = false
            case "right": isHorizontalRight = true
            case "left": isHorizontalLeft = true
            default: break
            }
        }

        let isLarge = lower.contains("fast") || lower.contains("page") || lower.contains("大きく") || lower.contains("たくさん") || lower.contains("一気に")
        let isSmall = lower.contains("slow") || lower.contains("slightly") || lower.contains("little") || lower.contains("少し") || lower.contains("ちょっと")

        let magnitude: CGFloat = isLarge ? 15.0 : (isSmall ? 2.0 : 5.0)

        if isHorizontalRight {
            return CGVector(dx: magnitude, dy: 0)
        }
        if isHorizontalLeft {
            return CGVector(dx: -magnitude, dy: 0)
        }
        if isUp {
            return CGVector(dx: 0, dy: magnitude)
        }
        return CGVector(dx: 0, dy: -magnitude)
    }

    // MARK: - Script Boundary, Word Boundary & Tokenization Helpers

    private enum ScriptClass: Equatable {
        case katakana
        case hiragana
        case kanji
        case latin
        case digit
        case other

        static func of(_ scalar: Unicode.Scalar) -> ScriptClass {
            let val = scalar.value
            // Delimiters: Katakana middle dot U+30FB and half-width middle dot U+FF65 act as word separators
            if val == 0x30FB || val == 0xFF65 {
                return .other
            }
            // Katakana: \u{30A0}...\u{30FF} (including prolonged mark ー \u{30FC}), Phonetic \u{31F0}...\u{31FF}, Half-width \u{FF66}...\u{FF9F}
            if (val >= 0x30A0 && val <= 0x30FF) || (val >= 0x31F0 && val <= 0x31FF) || (val >= 0xFF66 && val <= 0xFF9F) {
                return .katakana
            }
            // Hiragana: \u{3040}...\u{309F}
            if val >= 0x3040 && val <= 0x309F {
                return .hiragana
            }
            // Kanji (CJK Unified Ideographs): \u{4E00}...\u{9FFF}, Ext A \u{3400}...\u{4DBF}, Compat \u{F900}...\u{FAFF}
            if (val >= 0x4E00 && val <= 0x9FFF) || (val >= 0x3400 && val <= 0x4DBF) || (val >= 0xF900 && val <= 0xFAFF) {
                return .kanji
            }
            // Digits: ASCII 0-9 and Full-width 0-9 (\u{FF10}...\u{FF19})
            if (val >= 0x0030 && val <= 0x0039) || (val >= 0xFF10 && val <= 0xFF19) {
                return .digit
            }
            // Latin letters: ASCII letters & Latin Extended
            if (val >= 0x0041 && val <= 0x005A) || (val >= 0x0061 && val <= 0x007A) || (val >= 0x00C0 && val <= 0x024F) {
                return .latin
            }
            return .other
        }

        static func normalizeScalar(_ scalar: Unicode.Scalar) -> Character {
            let val = scalar.value
            // Normalize full-width digits ０-９ (U+FF10...U+FF19) to ASCII 0-9
            if val >= 0xFF10 && val <= 0xFF19 {
                return Character(Unicode.Scalar(val - 0xFEE0)!)
            }
            return Character(scalar)
        }
    }

    /// Checks if a character is a Latin alphanumeric character or underscore (word constituent).
    private static func isLatinWordCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
            || (scalar.value >= 0x41 && scalar.value <= 0x5a) // A-Z
            || (scalar.value >= 0x61 && scalar.value <= 0x7a) // a-z
            || scalar.value == 0x5f                           // _
    }

    /// Checks whether `needle` appears in `haystack` as a distinct word, phrase, or token.
    /// For Latin text, enforces word boundary checks so short substrings like "ok"
    /// do not falsely match inside words like "lookup", "book", or "token".
    /// Conjoined Latin-to-CJK transitions (e.g. "OKボタン") are recognized as word boundaries.
    /// For CJK text (Japanese/Chinese), allows direct substring match for needles of length >= 2,
    /// or exact equality for 1-character needles.
    public static func containsWordOrPhrase(in haystack: String, needle: String) -> Bool {
        guard !haystack.isEmpty, !needle.isEmpty else { return false }
        guard haystack.count >= needle.count else { return false }

        // If needle contains CJK characters (Japanese/Chinese), words are not space-delimited.
        let hasCJK = needle.unicodeScalars.contains { scalar in
            (0x3040...0x30ff).contains(scalar.value) || // Hiragana & Katakana
            (0x4e00...0x9fff).contains(scalar.value) || // CJK Unified Ideographs
            (0x3400...0x4dbf).contains(scalar.value)    // CJK Extension A
        }
        if hasCJK {
            if needle.count == 1 {
                return haystack == needle
            }
            return haystack.contains(needle)
        }

        // For non-CJK (Latin/alphanumerics/symbols):
        // Scan all occurrences of needle in haystack to verify at least one is bounded by word boundaries
        var searchStartIndex = haystack.startIndex
        while searchStartIndex < haystack.endIndex,
              let matchRange = haystack.range(of: needle, range: searchStartIndex..<haystack.endIndex) {

            let hasLeftBoundary: Bool = {
                if matchRange.lowerBound == haystack.startIndex { return true }
                let prevChar = haystack[haystack.index(before: matchRange.lowerBound)]
                return !isLatinWordCharacter(prevChar)
            }()

            let hasRightBoundary: Bool = {
                if matchRange.upperBound == haystack.endIndex { return true }
                let nextChar = haystack[matchRange.upperBound]
                return !isLatinWordCharacter(nextChar)
            }()

            if hasLeftBoundary && hasRightBoundary {
                return true
            }

            searchStartIndex = matchRange.upperBound
        }

        return false
    }

    /// Determines whether target matches query as a discrete word or full phrase,
    /// preventing interior substring collisions (e.g. "ok" inside "lookup" or "book")
    /// and preventing empty-string false positives.
    public static func isDirectMatch(target: String, query: String) -> Bool {
        guard !target.isEmpty, !query.isEmpty else { return false }

        // Exact equality (case-normalized)
        if target == query { return true }

        // Check if query contains target as a word/phrase (e.g. target "OK", query "Click the OK button")
        if containsWordOrPhrase(in: query, needle: target) {
            return true
        }

        // Check if target contains query as a word/phrase (e.g. target "Submit Order", query "Submit")
        // Only valid if query has substance (at least 2 characters) to prevent single-character matches
        if query.count >= 2 && containsWordOrPhrase(in: target, needle: query) {
            return true
        }

        return false
    }

    /// Default stop words covering English articles, prepositions, conjunctions, UI verbs/nouns,
    /// and Japanese grammatical particles, inflection suffixes, and generic UI words.
    public static let defaultStopWords: Set<String> = [
        // English articles & prepositions
        "a", "an", "the", "in", "on", "at", "to", "for", "of", "from", "by", "with", "into", "onto",
        // English conjunctions & pronouns
        "and", "or", "but", "is", "are", "was", "were", "it", "its", "this", "that", "these", "those",
        // Generic UI verbs
        "click", "clicks", "clicked", "clicking",
        "press", "presses", "pressed", "pressing",
        "tap", "taps", "tapped", "tapping",
        "select", "selects", "selected", "selecting",
        "open", "opens", "opened", "opening",
        "find", "finds", "found", "finding",
        "go", "goes", "went", "going",
        "please", "want", "need",
        // Generic UI nouns
        "button", "buttons", "btn", "link", "links", "field", "input", "box", "menu", "item", "items",
        "window", "screen", "page", "tab", "control", "element", "elements", "icon",
        // Replan boilerplate tokens
        "interact", "alternative", "interactive", "shortcuts",
        // Japanese particles & generic words
        "を", "に", "の", "へ", "で", "と", "が", "は", "から", "まで", "より", "も", "など",
        "クリック", "押す", "押して", "開く", "開いて", "選択", "選択して", "入力", "入力して",
        "ボタン", "リンク", "フィールド", "項目", "画面", "タブ",
        "して", "する", "した", "してください"
    ]

    /// Extracts semantic tokens from text, segmenting Japanese script boundaries (Katakana, Hiragana, Kanji)
    /// and Latin/digits, while preserving numeric tokens and removing stop words.
    public static func extractTokens(from text: String, stopWords: Set<String> = defaultStopWords) -> [String] {
        var rawTokens: [String] = []
        var current = ""
        var currentClass: ScriptClass = .other

        for scalar in text.lowercased().unicodeScalars {
            let sc = ScriptClass.of(scalar)
            if sc == .other {
                if !current.isEmpty {
                    rawTokens.append(current)
                    current = ""
                }
                currentClass = .other
            } else if sc == currentClass {
                current.append(ScriptClass.normalizeScalar(scalar))
            } else {
                if !current.isEmpty {
                    rawTokens.append(current)
                    current = ""
                }
                current.append(ScriptClass.normalizeScalar(scalar))
                currentClass = sc
            }
        }
        if !current.isEmpty {
            rawTokens.append(current)
        }

        return rawTokens.filter { token in
            if stopWords.contains(token) { return false }
            if token.count == 1 && !token.first!.isNumber { return false }
            return true
        }
    }

    // MARK: - Scroll Container Grounding & Coordinate Resolution

    /// Primary scrollable container roles in accessibility hierarchy
    public static let scrollContainerRoles: Set<String> = [
        "AXScrollArea",
        "AXWebArea",
        "AXTable",
        "AXList",
        "AXOutline"
    ]

    /// Keywords indicating feed, timeline, or collection content containers
    public static let scrollContainerKeywords: [String] = [
        "feed", "timeline", "results", "content", "stream", "list", "chat", "messages", "posts", "tweets",
        "フィード", "タイムライン", "結果", "一覧", "コンテンツ", "チャット", "メッセージ", "投稿"
    ]

    /// Resolves the optimal scroll container candidate from observed screen elements.
    ///
    /// Prioritizes:
    /// 1. Explicit goal match with candidate label/title (+2000)
    /// 2. Role priority (AXScrollArea: 1000, AXWebArea: 900, AXTable/List/Outline: 800, Other: 400)
    /// 3. Container keyword match in label, value, or id (+500)
    /// 4. Bounding box area bonus (up to +500) to favor primary content over small widgets
    /// 5. Actionable element bonus (+50)
    public static func resolveScrollContainer(
        candidates: [UIElementCandidate],
        goal: String
    ) -> UIElementCandidate? {
        let normalizedGoal = goal.lowercased()

        var bestCandidate: UIElementCandidate?
        var highestScore: Double = -1.0

        for candidate in candidates {
            let bounds = candidate.bounds
            // Filter out degenerate or non-finite bounds
            guard bounds.width > 0, bounds.height > 0,
                  bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite else {
                continue
            }

            let role = candidate.role
            let lowerLabel = candidate.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerValue = (candidate.value ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerId = candidate.id.lowercased()

            let isScrollRole = scrollContainerRoles.contains(role)
            let hasContainerKeyword = scrollContainerKeywords.contains { kw in
                lowerLabel.contains(kw) || lowerValue.contains(kw) || lowerId.contains(kw)
            }
            let matchesGoal = !normalizedGoal.isEmpty && !lowerLabel.isEmpty && (
                Self.isDirectMatch(target: lowerLabel, query: normalizedGoal)
            )

            // Candidate must have a scroll role, container keyword, or direct goal match to qualify
            guard isScrollRole || hasContainerKeyword || matchesGoal else {
                continue
            }

            var score: Double = 0.0

            // 1. Role Priority
            switch role {
            case "AXScrollArea":
                score += 1000.0
            case "AXWebArea":
                score += 900.0
            case "AXTable", "AXList", "AXOutline":
                score += 800.0
            default:
                score += 400.0
            }

            // 2. Goal Matching Bonus (highest specificity)
            if matchesGoal {
                score += 2000.0
            }

            // 3. Container Keyword Bonus
            if hasContainerKeyword {
                score += 500.0
            }

            // 4. Bounding Box Area Bonus (normalized, caps at 500.0)
            let area = Double(bounds.width * bounds.height)
            score += min(area / 1000.0, 500.0)

            // 5. Actionable bonus
            if candidate.isActionable {
                score += 50.0
            }

            if score > highestScore {
                highestScore = score
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    /// Computes the fallback viewport center coordinate from candidates or screen bounds.
    public static func resolveFallbackScrollCoordinates(candidates: [UIElementCandidate]) -> CGPoint {
        // 1. Calculate bounding box union of all valid candidates
        let validBounds = candidates.compactMap { c -> CGRect? in
            let b = c.bounds
            guard b.width > 0, b.height > 0,
                  b.minX.isFinite, b.minY.isFinite,
                  b.width.isFinite, b.height.isFinite else {
                return nil
            }
            return b
        }

        if !validBounds.isEmpty {
            let minX = validBounds.map(\.minX).min() ?? 0
            let minY = validBounds.map(\.minY).min() ?? 0
            let maxX = validBounds.map(\.maxX).max() ?? 0
            let maxY = validBounds.map(\.maxY).max() ?? 0
            let width = maxX - minX
            let height = maxY - minY
            if width > 0 && height > 0 {
                return CGPoint(x: minX + width / 2.0, y: minY + height / 2.0)
            }
            if let first = validBounds.first {
                return CGPoint(x: first.midX, y: first.midY)
            }
        }

        // A fixture must retain its viewport across async actor boundaries;
        // otherwise NSScreen.main can change between compared observations.
        if let viewport = fallbackScrollViewport,
           viewport.width > 0, viewport.height > 0,
           viewport.origin.x.isFinite, viewport.origin.y.isFinite,
           viewport.midX.isFinite, viewport.midY.isFinite {
            return CGPoint(x: viewport.midX, y: viewport.midY)
        }

        // 2. Screen center fallback if available via AppKit
        #if canImport(AppKit)
        if let screen = NSScreen.main {
            return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        #endif

        // 3. Conservative default desktop viewport center
        return CGPoint(x: 600, y: 450)
    }

    /// Local deterministic fallback when TypeSafe Jev API is unavailable or unkeyed.
    public func fallbackLocalDecision(
        goal: String,
        candidates: [UIElementCandidate],
        history: [LoopStepRecord] = [],
        recentEscalations: [EscalationRecord] = [],
        lastDiff: UIStateDiff? = nil
    ) -> ComputerActionDecision {
        let normalizedGoal = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Early guard: Empty or whitespace goal produces immediate non-actionable decision
        guard !normalizedGoal.isEmpty else {
            return ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: 0.0,
                isCompleted: false,
                reasoning: "Goal is empty or whitespace (offline fallback)"
            )
        }

        // Keyword grounding cannot distinguish a requested action from a
        // prohibition. Leave constrained goals to System 2 instead of turning
        // "do not type" into input or "don't scroll" into scrolling.
        let constraintPatterns = [
            #"\b(?:do\s+not|don['’]t|never|must\s+not|avoid|refrain\s+from)\b"#,
            "しない|しません|するな|せず|禁止",
            "하지\\s*(?:마|않)|안\\s*(?:돼|되)|금지",
        ]
        if constraintPatterns.contains(where: {
            normalizedGoal.range(of: $0, options: .regularExpression) != nil
        }) {
            return ComputerActionDecision(
                action: .none, confidence: 0.0, isCompleted: false,
                reasoning: "Constrained goal requires model reasoning (offline fallback)"
            )
        }

        // Verification text can contain action words and numeric fragments
        // matching unrelated controls. Observation intent does not request
        // input; let System 2 assess the fresh snapshot instead.
        let observationPatterns = [
            #"^(?:verify|check|observe|inspect|read|confirm)\b"#,
            #"^(?!.*スクロール(?:して|する|してください|します)).*(?:確認|観察|検証|読み取り)(?:する|してください|して|します)?[。.!\s]*$"#,
            #"^(?!.*스크롤(?:해|하세요|한다|하십시오)).*(?:확인|관찰|검증|읽기)(?:하세요|해|한다|하십시오|해 주세요)?[.!\s]*$"#,
        ]
        let observationGoal = DefaultSubgoalPlanner.stripReplanBoilerplate(from: normalizedGoal)
        if observationPatterns.contains(where: {
            observationGoal.range(of: $0, options: .regularExpression) != nil
        }) {
            return ComputerActionDecision(
                action: .none, confidence: 0.0, isCompleted: false,
                reasoning: "Observation goal requires model verification (offline fallback)"
            )
        }

        // Words in the requested goal (including button labels such as Done)
        // describe intent, not an observed outcome. Only grounded model or
        // coordinator verification can establish completion.

        // Action classification by keywords: Scroll
        let scrollKeywords = ["スクロール", "scroll", "下を見て", "上を見て", "タイムライン", "feed", "フィード", "下へ", "上へ"]
        if scrollKeywords.contains(where: { normalizedGoal.contains($0) }) {
            let container = Self.resolveScrollContainer(candidates: candidates, goal: goal)
            let coordinates = container?.center ?? Self.resolveFallbackScrollCoordinates(candidates: candidates)
            let targetId = container?.id
            let delta = Self.extractScrollDelta(from: goal)

            // Stagnation Detection
            let isStateUnchanged = lastDiff?.isStateUnchanged == true
            let hasStagnantEscalation = recentEscalations.contains(where: { $0.reason.isActionStagnant })
            let lastAction = history.last?.action
            let lastActionWasScroll = lastAction?.action == .scroll
            let lastActionWasKeyPress = lastAction?.action == .keyPress
            let lastVerificationFailed = history.last?.verificationResult?.status == .unverified

            let isStagnant: Bool = {
                if hasStagnantEscalation { return true }
                if lastActionWasScroll && (isStateUnchanged || lastVerificationFailed) { return true }
                if isStateUnchanged && (lastActionWasScroll || lastActionWasKeyPress) { return true }
                let recentScrolls = history.suffix(2).filter { $0.action.action == .scroll }
                if recentScrolls.count >= 2 && isStateUnchanged { return true }
                return false
            }()

            if isStagnant {
                let triedKeyboardNav = history.contains(where: { step in
                    step.action.action == .keyPress && (
                        step.action.keyCombination == ["PageDown"] ||
                        step.action.keyCombination == ["PageUp"] ||
                        step.action.keyCombination == ["Down"] ||
                        step.action.keyCombination == ["Up"]
                    )
                }) || (lastActionWasKeyPress && isStateUnchanged)

                let highEscalationRisk = recentEscalations.count >= 2

                if triedKeyboardNav || highEscalationRisk {
                    // Tier 2: Both scroll and keyboard navigation yielded no change, or escalation limit approaching:
                    // Conclude the subgoal gracefully to prevent infinite loops and 3-strike escalation failure.
                    log.info("[TypeSafeDecisionEngine] Stagnant scroll & key navigation detected (isStateUnchanged=\(isStateUnchanged), escalations=\(recentEscalations.count)); concluding subgoal as boundary reached.")
                    return ComputerActionDecision(
                        targetElementId: targetId,
                        action: .none,
                        confidence: 0.85,
                        isCompleted: true,
                        targetCenter: coordinates,
                        reasoning: "Scroll and keyboard navigation produced no state change; page boundary reached or target inert. Concluding subgoal (offline fallback)"
                    )
                } else {
                    // Tier 1: Adapt to keyboard navigation (PageDown / PageUp) to attempt moving the viewport
                    let navKey = delta.dy > 0 ? "PageUp" : "PageDown"
                    log.info("[TypeSafeDecisionEngine] Stagnant scroll detected (isStateUnchanged=\(isStateUnchanged)); adapting to keyboard navigation [\(navKey)].")
                    return ComputerActionDecision(
                        targetElementId: targetId,
                        action: .keyPress,
                        confidence: 0.85,
                        isCompleted: false,
                        targetCenter: coordinates,
                        keyCombination: [navKey],
                        reasoning: "Prior scroll yielded no screen change (isStateUnchanged=true); adapting to keyboard navigation (\(navKey)) to advance view (offline fallback)"
                    )
                }
            }

            // Normal scroll action (grounded to container if available or fallback coordinates)
            let reasoning: String
            if let container = container {
                let name = container.label.isEmpty ? container.id : container.label
                reasoning = "Grounded scroll on container '\(name)' (\(container.role)) at (\(Int(coordinates.x)), \(Int(coordinates.y))) (offline fallback)"
            } else {
                reasoning = "Scroll directed at viewport center (\(Int(coordinates.x)), \(Int(coordinates.y))) fallback (offline fallback)"
            }

            return ComputerActionDecision(
                targetElementId: targetId,
                action: .scroll,
                confidence: 0.85,
                isCompleted: false,
                targetCenter: coordinates,
                scrollDelta: delta,
                reasoning: reasoning
            )
        }

        let explicitKeys = Self.extractKeyCombination(from: goal)
        let hasExplicitKey = (explicitKeys != nil)
        let keyKeywords = [
            "press key", "ショートカット", "キーを押",
            "press return", "return key", "press enter", "enter key",
            "press escape", "escape key", "press tab", "tab key",
            "タブキー", "エンターキー", "エスケープキー", "リターンキー"
        ]
        let hasKeyPhrase = keyKeywords.contains(where: { normalizedGoal.contains($0) })

        let hasTabCandidate = candidates.contains(where: {
            $0.role == "AXTab" || $0.label.lowercased().contains("tab")
        })
        let isTabSelectionGoal = normalizedGoal.contains("select")
            || normalizedGoal.contains("switch")
            || normalizedGoal.contains("choose")
            || normalizedGoal.contains("open")
            || normalizedGoal.contains("選択")
            || normalizedGoal.contains("切り替え")
            || normalizedGoal.range(of: "\\btab\\s+\\d+\\b", options: .regularExpression) != nil

        let shouldSkipKeyPressForTabElement = hasTabCandidate && isTabSelectionGoal

        if (hasKeyPhrase || hasExplicitKey)
            && !normalizedGoal.contains("click")
            && !normalizedGoal.contains("クリック")
            && !shouldSkipKeyPressForTabElement {
            let keys = explicitKeys ?? ["Return"]
            return ComputerActionDecision(
                targetElementId: nil,
                action: .keyPress,
                confidence: 0.85,
                isCompleted: false,
                keyCombination: keys,
                reasoning: "Detected keyPress action from keywords (offline fallback)"
            )
        }

        let isWait = normalizedGoal.contains("wait") || normalizedGoal.contains("待つ") || normalizedGoal.contains("待機")
        if isWait {
            return ComputerActionDecision(
                targetElementId: nil,
                action: .wait,
                confidence: 0.85,
                isCompleted: false,
                reasoning: "Detected wait action from keywords (offline fallback)"
            )
        }

        // Empty candidates check for remaining target-based actions
        if candidates.isEmpty {
            let lowConfidenceEscalationCount = recentEscalations.filter {
                if case .lowConfidence = $0.reason { return true }
                return false
            }.count

            if lowConfidenceEscalationCount >= 2 {
                return ComputerActionDecision(
                    targetElementId: nil,
                    action: .none,
                    confidence: 0.0,
                    isCompleted: false,
                    reasoning: "Target remains unresolved after \(lowConfidenceEscalationCount) low-confidence attempts; requires System 2 resolution (offline fallback)"
                )
            }

            return ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: 0.0,
                isCompleted: false,
                reasoning: "No actionable UI element candidates observed on screen (offline fallback)"
            )
        }

        let typeKeywords = ["type", "enter", "input", "入力", "テキスト入力", "文字入力", "タイプ"]
        let isTyping = typeKeywords.contains(where: { normalizedGoal.contains($0) })
        let extractedText = isTyping ? Self.extractTextInput(from: goal) : nil

        let isDoubleClick = normalizedGoal.contains("double click") || normalizedGoal.contains("ダブルクリック")
        let isRightClick = normalizedGoal.contains("right click") || normalizedGoal.contains("右クリック") || normalizedGoal.contains("コンテキストメニュー")

        // =========================================================================
        // Feature 3: Token-Based Candidate Matching & Multi-Attribute Scoring
        // =========================================================================

        // 1. Goal preprocessing: unwrap planner boilerplate retry goals
        var cleanGoal = normalizedGoal
        let replanPrefixes = [
            "interact with alternative interactive element for:",
            "navigate using alternative elements or shortcuts for:",
            "wait for ui to finish loading or rendering",
            "for:"
        ]
        for prefix in replanPrefixes {
            if let range = cleanGoal.range(of: prefix) {
                cleanGoal = String(cleanGoal[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 2. Tokenization & stop word removal
        let goalTokens = Self.extractTokens(from: cleanGoal.isEmpty ? normalizedGoal : cleanGoal)

        // 3. Multi-attribute candidate inspection (label, value, id, role)
        var bestCandidate: UIElementCandidate?
        var bestScore: Int = 0
        var bestOverlapRatio: Float = 0.0
        var bestMatchedCount: Int = 0

        for c in candidates where c.isActionable {
            let cLabel = c.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let cValue = c.value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cId = c.id.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let cRole = c.role.lowercased()

            var candidateScore: Int = 0
            var matchedGoalTokens = Set<String>()

            // Extract candidate tokens
            var candidateTokenSet = Set<String>()
            if !cLabel.isEmpty {
                candidateTokenSet.formUnion(Self.extractTokens(from: cLabel))
                if (cLabel.count > 1 || cLabel.first?.isNumber == true) && !Self.defaultStopWords.contains(cLabel) {
                    candidateTokenSet.insert(cLabel)
                }
            }
            if !cValue.isEmpty {
                candidateTokenSet.formUnion(Self.extractTokens(from: cValue))
                if (cValue.count > 1 || cValue.first?.isNumber == true) && !Self.defaultStopWords.contains(cValue) {
                    candidateTokenSet.insert(cValue)
                }
            }
            if !cId.isEmpty {
                let idParts = cId.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { ($0.count > 1 || $0.first?.isNumber == true) && !Self.defaultStopWords.contains($0) }
                candidateTokenSet.formUnion(idParts)
            }

            // Direct substring/phrase match check (high fidelity) across label, value, and id
            let hasDirectLabelMatch = !cLabel.isEmpty && (
                (!cleanGoal.isEmpty && Self.isDirectMatch(target: cLabel, query: cleanGoal)) ||
                (!normalizedGoal.isEmpty && Self.isDirectMatch(target: cLabel, query: normalizedGoal))
            )
            let hasDirectValueMatch = !cValue.isEmpty && (
                (!cleanGoal.isEmpty && Self.isDirectMatch(target: cValue, query: cleanGoal)) ||
                (!normalizedGoal.isEmpty && Self.isDirectMatch(target: cValue, query: normalizedGoal))
            )
            let hasDirectIdMatch = !cId.isEmpty && (
                (!cleanGoal.isEmpty && Self.isDirectMatch(target: cId, query: cleanGoal)) ||
                (!normalizedGoal.isEmpty && Self.isDirectMatch(target: cId, query: normalizedGoal))
            )

            if hasDirectLabelMatch || hasDirectValueMatch || hasDirectIdMatch {
                candidateScore += 100 + max(cLabel.count, max(cValue.count, cId.count))
                if !goalTokens.isEmpty {
                    for gt in goalTokens {
                        if candidateTokenSet.contains(gt) || Self.containsWordOrPhrase(in: cLabel, needle: gt) || Self.containsWordOrPhrase(in: cValue, needle: gt) || Self.containsWordOrPhrase(in: cId, needle: gt) {
                            matchedGoalTokens.insert(gt)
                        }
                    }
                    if matchedGoalTokens.isEmpty {
                        matchedGoalTokens.insert(goalTokens.first!)
                    }
                }
            }

            // Token overlap inspection across label, value, id, role
            for gt in goalTokens {
                var tokenHit = false
                if candidateTokenSet.contains(gt) {
                    candidateScore += 40
                    tokenHit = true
                }
                if !cLabel.isEmpty && (candidateTokenSet.contains(gt) || (gt.count > 3 && cLabel.contains(gt)) || cLabel.hasPrefix(gt) || Self.containsWordOrPhrase(in: cLabel, needle: gt)) {
                    candidateScore += 30
                    tokenHit = true
                }
                if !cValue.isEmpty && (candidateTokenSet.contains(gt) || (gt.count > 3 && cValue.contains(gt)) || cValue.hasPrefix(gt) || Self.containsWordOrPhrase(in: cValue, needle: gt)) {
                    candidateScore += 25
                    tokenHit = true
                }
                if !cId.isEmpty && (candidateTokenSet.contains(gt) || (gt.count > 3 && cId.contains(gt)) || cId.hasPrefix(gt) || Self.containsWordOrPhrase(in: cId, needle: gt)) {
                    candidateScore += 20
                    tokenHit = true
                }
                if cRole.contains(gt) {
                    candidateScore += 15
                    tokenHit = true
                }

                if tokenHit {
                    matchedGoalTokens.insert(gt)
                }
            }

            // Role and Actionability bonuses
            if isTyping || cRole.contains("field") || cRole.contains("text") {
                if c.role == "AXTextField" || c.role == "AXTextArea" || c.role == "AXSearchField" {
                    candidateScore += 50
                }
            }
            if ["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTab"].contains(c.role) {
                candidateScore += 25
            }

            if c.isActionable {
                candidateScore += 15
            }

            // Evaluate if this candidate is the best so far
            if candidateScore > bestScore && (hasDirectLabelMatch || hasDirectValueMatch || hasDirectIdMatch || !matchedGoalTokens.isEmpty || (isTyping && (c.role == "AXTextField" || c.role == "AXTextArea" || c.role == "AXSearchField"))) {
                bestScore = candidateScore
                bestCandidate = c
                bestMatchedCount = matchedGoalTokens.count
                bestOverlapRatio = goalTokens.isEmpty ? 1.0 : (Float(matchedGoalTokens.count) / Float(goalTokens.count))
            }
        }

        // If typing but no candidate matched by label/token, pick first text field
        if isTyping && bestCandidate == nil {
            if let firstField = candidates.first(where: {
                $0.isActionable && ["AXTextField", "AXTextArea", "AXSearchField"].contains($0.role)
            }) {
                bestCandidate = firstField
                bestScore = 50
                bestOverlapRatio = 0.5
                bestMatchedCount = 1
            }
        }

        // 4. If a candidate was matched, return targeted action with proportional confidence
        if let target = bestCandidate {
            let determinedAction: ComputerActionDecision.ActionType
            if isTyping {
                determinedAction = .typeText
            } else if isDoubleClick {
                determinedAction = .doubleClick
            } else if isRightClick {
                determinedAction = .rightClick
            } else {
                determinedAction = .click
            }

            // Proportional confidence scoring based on token overlap
            let confidence: Float
            if bestScore >= 100 || bestOverlapRatio >= 1.0 {
                confidence = 0.85
            } else if bestOverlapRatio >= 0.5 || bestScore >= 60 {
                confidence = 0.80 + (0.05 * bestOverlapRatio)
            } else if bestMatchedCount > 0 {
                confidence = 0.80
            } else {
                confidence = 0.75
            }

            let displayLabel = target.label.isEmpty ? (target.value ?? target.id) : target.label
            let totalTokens = max(goalTokens.count, 1)
            let matchTypeDesc = bestScore >= 100 ? "exact/label match" : "token overlap (\(bestMatchedCount)/\(totalTokens))"

            return ComputerActionDecision(
                targetElementId: target.id,
                action: determinedAction,
                confidence: confidence,
                isCompleted: false,
                targetCenter: target.center,
                textInput: extractedText,
                reasoning: "Matched '\(displayLabel)' (\(target.role)) via \(matchTypeDesc) [score=\(bestScore), conf=\(String(format: "%.2f", confidence))] (offline fallback)"
            )
        }

        // =========================================================================
        // Feature 4: Graceful Low-Confidence Fallthrough Recovery
        // =========================================================================

        let isAlternativeAttempt = normalizedGoal.contains("alternative")
            || recentEscalations.contains(where: { if case .lowConfidence = $0.reason { return true }; return false })

        let lowConfidenceEscalationCount = recentEscalations.filter {
            if case .lowConfidence = $0.reason { return true }
            return false
        }.count

        // After repeated unresolved grounding, preserve failure for the
        // coordinator's bounded escalation instead of trying an unrelated target.
        if lowConfidenceEscalationCount >= 2 {
            return ComputerActionDecision(
                targetElementId: nil,
                action: .none,
                confidence: 0.0,
                isCompleted: false,
                reasoning: "Target remains unresolved after \(lowConfidenceEscalationCount) low-confidence attempts; requires System 2 resolution (offline fallback)"
            )
        }

        // Recovery Strategy 2: Alternative Interactive Element Selection (Replan response)
        // If System 2 / heuristic replan asked to interact with an alternative interactive element,
        // pick the most prominent actionable interactive candidate rather than returning .none.
        if isAlternativeAttempt {
            let interactiveRoles = ["AXButton", "AXLink", "AXTextField", "AXSearchField", "AXCheckBox", "AXPopUpButton", "AXMenuItem"]
            let actionableCandidate = candidates.first(where: { $0.isActionable && interactiveRoles.contains($0.role) })
                ?? candidates.first(where: { $0.isActionable })

            if let altTarget = actionableCandidate {
                let altAction: ComputerActionDecision.ActionType = (altTarget.role == "AXTextField" || altTarget.role == "AXSearchField") ? .typeText : .click
                let displayLabel = altTarget.label.isEmpty ? altTarget.id : altTarget.label
                return ComputerActionDecision(
                    targetElementId: altTarget.id,
                    action: altAction,
                    confidence: 0.80,
                    isCompleted: false,
                    targetCenter: altTarget.center,
                    textInput: extractedText,
                    reasoning: "Selected alternative actionable element '\(displayLabel)' (\(altTarget.role)) following low-confidence replan (offline fallback)"
                )
            }
        }

        // Recovery Strategy 3: Exploratory Wait for Dynamic Render / Settling
        // If goal or context indicates waiting or dynamic UI loading/settling, issue .wait to allow UI to settle.
        let previousActionWasWait = (history.last?.action.action == .wait)
        let indicatesWaitOrRender = cleanGoal.contains("wait") || cleanGoal.contains("load") || cleanGoal.contains("render") || cleanGoal.contains("settl") || normalizedGoal.contains("待つ") || normalizedGoal.contains("待機")
        if !previousActionWasWait && indicatesWaitOrRender {
            return ComputerActionDecision(
                targetElementId: nil,
                action: .wait,
                confidence: 0.80,
                isCompleted: false,
                reasoning: "No candidate matched goal '\(cleanGoal)' on screen; waiting for dynamic UI render/settling before escalating (offline fallback)"
            )
        }

        // Recovery Strategy 4: Graduated Confidence & Diagnostic Reasoning
        // If we must return .none, graduate confidence (e.g. 0.35–0.40) and supply structured diagnostic details
        // so the coordinator / planner understands visible screen context without crashing immediately.
        let sampleRoles = Array(Set(candidates.prefix(8).map(\.role))).sorted().joined(separator: ", ")
        let sampleLabels = candidates.prefix(5).map { $0.label.isEmpty ? $0.id : "'\($0.label)'" }.joined(separator: ", ")
        let graduatedConfidence: Float = min(0.40, max(0.20, Float(candidates.count) * 0.02))

        return ComputerActionDecision(
            targetElementId: nil,
            action: .none,
            confidence: graduatedConfidence,
            isCompleted: false,
            reasoning: "No candidate matched keywords \(goalTokens) across \(candidates.count) visible elements [sample: \(sampleLabels); roles: \(sampleRoles)] (offline fallback)"
        )
    }

    /// Triages whether the user's input/goal requires computer, browser, or desktop action.
    /// Uses TypeSafe Jev System One model for sub-200ms evaluation, falling back to local heuristics if unavailable.
    public func triageGoal(
        goal: String,
        activeApp: String? = nil
    ) async -> ComputerActionTriage {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .conversational
        }

        let questions: [String: TypeSafeClient.QuestionPayload] = [
            "needs_action": TypeSafeClient.QuestionPayload(
                type: "choice",
                instructions: "Does this user request require interacting with the computer, browser, or desktop GUI (such as scrolling, clicking, searching, navigating, or typing into fields)?",
                criteria: [
                    "computer_action": "Yes, user wants to operate the browser or desktop (e.g. scroll, search, click, navigate, interact with screen).",
                    "conversational": "No, user wants conversational answer, explanation, or standard text response without GUI operations."
                ]
            ),
            "action_type": TypeSafeClient.QuestionPayload(
                type: "choice",
                instructions: "What kind of desktop action is primarily needed to fulfill this request?",
                criteria: [
                    "file_search_and_open": "Finding files on disk, opening files in applications, or creating/editing files.",
                    "file_text_entry": "Opening a file/app and typing text, writing notes, or modifying document contents.",
                    "browser_scroll_or_search": "Scrolling pages (e.g. Twitter/X feeds, web pages) or searching in a browser.",
                    "gui_interaction": "Clicking buttons, typing text, or interacting with macOS applications.",
                    "screen_inspection": "Inspecting or reading what is currently displayed on screen.",
                    "none": "No computer interaction."
                ]
            )
        ]

        let stateDict: [String: AnyCodableValue] = [
            "user_goal": .string(trimmed),
            "active_app": .string(activeApp ?? "Unknown")
        ]

        let request = TypeSafeClient.EvaluationRequest(
            state: .dictionary(stateDict),
            model: "jev-latest",
            questions: questions
        )

        do {
            let response: TypeSafeClient.EvaluationResponse
            if let evaluator = customEvaluator {
                response = try await evaluator(request)
            } else {
                response = try await client.evaluate(request: request)
            }

            let needsActionChoice = response.answers["needs_action"]?.choice
            let needsActionConfidence = response.answers["needs_action"]?.confidence ?? 0.0
            let actionType = response.answers["action_type"]?.choice ?? "none"

            let needsAction = (needsActionChoice == "computer_action")
            let plan: String?
            if actionType == "file_search_and_open" || actionType == "file_text_entry" {
                plan = "ファイルを検索してアプリケーションで開き、指定されたテキストの入力・編集を自律的に実行します"
            } else if actionType == "browser_scroll_or_search" {
                plan = "見守り固定中または対象のブラウザーを自律スクロールし、画面上のコンテンツを収集・探索します"
            } else if actionType == "gui_interaction" {
                plan = "対象UI要素をクリックまたは入力して画面を操作します"
            } else if actionType == "screen_inspection" {
                plan = "画面の現在の表示内容を確認・読み取ります"
            } else {
                plan = nil
            }

            return ComputerActionTriage(
                needsComputerAction: needsAction,
                confidence: needsActionConfidence,
                intentCategory: actionType,
                suggestedPlan: plan
            )
        } catch {
            log.debug("TypeSafe Jev triage API unavailable (\(error.localizedDescription)); using local heuristics fallback.")
            return fallbackLocalTriage(goal: trimmed, activeApp: activeApp)
        }
    }

    /// Fast local heuristic triage when Jev API is unavailable or unconfigured.
    public func fallbackLocalTriage(
        goal: String,
        activeApp: String? = nil
    ) -> ComputerActionTriage {
        let lower = goal.lowercased()

        if lower.hasPrefix("/goal") || lower.hasPrefix("/act") {
            return ComputerActionTriage(
                needsComputerAction: true,
                confidence: 1.0,
                intentCategory: "gui_interaction",
                suggestedPlan: "指定された自律ゴールを実行します"
            )
        }

        // File search, open, and text editing (e.g. "ファイルを探して", "ファイルを開いて文字を入力して")
        let fileSearchKeywords = ["ファイルを探", "ファイルを検索", "find file", "search file", "ファイル見つけて"]
        let fileOpenKeywords = ["ファイルを開", "open file", "開いて文字", "開いて入力", "開いて書", "ファイル編集"]
        let fileTextKeywords = ["文字を入力", "文字入力", "テキスト入力", "メモに入力", "ファイルに入力", "テキストを書", "メモを書", "type text", "write text"]

        let hasFileSearch = fileSearchKeywords.contains { lower.contains($0) }
        let hasFileOpen = fileOpenKeywords.contains { lower.contains($0) }
        let hasFileText = fileTextKeywords.contains { lower.contains($0) }

        if hasFileSearch || (hasFileOpen && hasFileText) {
            return ComputerActionTriage(
                needsComputerAction: true,
                confidence: 0.95,
                intentCategory: hasFileText ? "file_text_entry" : "file_search_and_open",
                suggestedPlan: "ファイルを検索してアプリケーションで開き、指定されたテキストの入力・編集を自律的に実行します"
            )
        } else if hasFileOpen {
            return ComputerActionTriage(
                needsComputerAction: true,
                confidence: 0.92,
                intentCategory: "file_search_and_open",
                suggestedPlan: "指定されたファイルを検索または開いてアプリケーションを前面化します"
            )
        }


        // General computer / GUI action keywords
        let actionKeywords = [
            "クリック", "click", "ダブルクリック", "タップ",
            "押して", "ボタン", "入力して", "文字入力", "タイプ",
            "開いて", "起動して", "閉じて", "切り替えて", "操作して",
            "探して", "もっと見て", "下を見て", "次へ", "検索して", "検索",
            "클릭", "눌러", "열어", "닫아", "입력해", "검색해", "실행해"
        ]
        // English requests are imperatives, so the verb leads the sentence. Matching only at
        // the start keeps "How do I open a .dmg?" a question.
        let englishImperatives = [
            "click ", "double click ", "right click ", "open ", "close ", "press ", "type ", "tap ",
            "select ", "switch to ", "go to ", "launch ", "quit ",
        ]
        let hasAction = actionKeywords.contains { lower.contains($0) }
            || englishImperatives.contains { lower.hasPrefix($0) }

        // High priority: browser scrolling / searching (Twitter, feeds, web, pinned background windows, Firefox, Chrome, etc.)
        let scrollKeywords = [
            "スクロール", "scroll", "3k", "タイムライン", "フィード", "収集", "情報収集",
            "스크롤", "타임라인", "피드", "수집"
        ]
        // A browser or app name is not a request to act on its own: "おすすめのChrome拡張機能ある？"
        // is a question. It routes to the browser only alongside an operation.
        let browserNames = [
            "twitter", "ツイッター", "ブラウザ", "ブラウザー",
            "chrome", "safari", "firefox", "ファイヤーフォックス", "ファイアフォックス", "火狐",
            "arc", "edge", "brave"
        ]
        let backgroundWatchKeywords = ["pin", "ピン", "見守り", "見張", "裏で", "バックグラウンド", "background"]
        let hasScroll = scrollKeywords.contains { lower.contains($0) }
            || (hasAction && browserNames.contains { lower.contains($0) })
        let hasBgWatch = backgroundWatchKeywords.contains { lower.contains($0) }

        if hasScroll {
            let isFirefox = lower.contains("firefox") || lower.contains("ファイヤーフォックス") || lower.contains("ファイアフォックス")
            let targetBrowser = isFirefox ? "Firefox" : "ブラウザー"
            let plan = (hasBgWatch || lower.contains("収集"))
                ? "見守り固定中または\(targetBrowser)をバックグラウンドで自律スクロールし、画面情報を自律収集します"
                : "\(targetBrowser)を自律操作・スクロールして画面上の対象コンテンツを探索・実行します"
            return ComputerActionTriage(
                needsComputerAction: true,
                confidence: 0.95,
                intentCategory: "browser_scroll_or_search",
                suggestedPlan: plan
            )
        } else if hasAction {
            return ComputerActionTriage(
                needsComputerAction: true,
                confidence: 0.88,
                intentCategory: "gui_interaction",
                suggestedPlan: "指定されたUI操作を自律的に実行します"
            )
        }

        return .conversational
    }
}
