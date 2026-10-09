import CoreGraphics
import Foundation
import MCACore
import MCASensing
import OSLog
#if canImport(AppKit)
import AppKit
#endif

// MARK: - System2Planning Protocol

/// Abstraction for the high-level System 2 Planning agent.
/// Allows injecting mocked planners returning canned SubgoalPlans or reactive re-plans.
public protocol System2Planning: Sendable {
    /// Decomposes a high-level goal into an ordered sequence of coarse subgoals.
    func plan(
        goal: String,
        initialSnapshot: UIStateSnapshot?
    ) async throws -> SubgoalPlan

    /// Re-evaluates or revises the plan upon escalation from System 1.
    func replan(
        goal: String,
        failedSubgoal: Subgoal,
        reason: EscalationReason,
        currentSnapshot: UIStateSnapshot?,
        history: [LoopStepRecord]
    ) async throws -> EscalationResolution

    /// Escalates control with current plan context (convenience overload).
    func escalate(
        reason: EscalationReason,
        currentSubgoal: Subgoal,
        plan: SubgoalPlan,
        snapshot: UIStateSnapshot
    ) async throws -> EscalationResolution
}

public extension System2Planning {
    func escalate(
        reason: EscalationReason,
        currentSubgoal: Subgoal,
        plan: SubgoalPlan,
        snapshot: UIStateSnapshot
    ) async throws -> EscalationResolution {
        try await replan(
            goal: plan.goal,
            failedSubgoal: currentSubgoal,
            reason: reason,
            currentSnapshot: snapshot,
            history: []
        )
    }

    func replan(
        goal: String,
        failedSubgoal: Subgoal,
        reason: EscalationReason,
        currentSnapshot: UIStateSnapshot?,
        history: [LoopStepRecord]
    ) async throws -> EscalationResolution {
        let plan = SubgoalPlan(goal: goal, subgoals: [failedSubgoal])
        let snap = currentSnapshot ?? UIStateSnapshot(visibleCandidates: [])
        return try await escalate(
            reason: reason,
            currentSubgoal: failedSubgoal,
            plan: plan,
            snapshot: snap
        )
    }
}

// MARK: - Escalation Types

/// Reason why System 1 is escalating control back to System 2 Planner.
public enum EscalationReason: Sendable, Codable, Equatable {
    /// No actionable UI element candidates observed on screen.
    case noCandidates
    case emptyCandidates

    /// System 1 decision confidence fell below configured threshold.
    case lowConfidence(confidence: Float, threshold: Float)

    /// State verification diffing failed after executing action.
    case verificationFailed(expectedOutcome: String, rationale: String, result: StateVerificationResult?)
    case outcomeUnverified(expected: String, stepsTaken: Int)

    /// Maximum steps allocated for the individual subgoal was exhausted without verification.
    case subgoalBudgetExceeded(subgoal: Subgoal, stepsTaken: Int)

    /// Repetitive loop detected across recent steps.
    case loopDetected(reason: String)

    /// Action execution stagnant or repetitive without progress.
    case actionStagnant(reason: String)

    /// Hardware event synthesis error.
    case executionError(error: String)
    case actionFailed(String)

    /// Convenience helper to check if escalation was caused by action stagnation or loop detection.
    public var isActionStagnant: Bool {
        if case .actionStagnant = self { return true }
        if case .loopDetected = self { return true }
        return false
    }
}

extension EscalationReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noCandidates, .emptyCandidates:
            return "No actionable UI element candidates observed on screen"
        case .lowConfidence(let confidence, let threshold):
            return "Action decision confidence (\(String(format: "%.2f", confidence))) fell below threshold (\(String(format: "%.2f", threshold)))"
        case .verificationFailed(let expectedOutcome, let rationale, _):
            return "State verification failed for expected outcome '\(expectedOutcome)': \(rationale)"
        case .outcomeUnverified(let expected, let stepsTaken):
            return "Outcome '\(expected)' unverified after \(stepsTaken) steps"
        case .subgoalBudgetExceeded(let subgoal, let stepsTaken):
            return "Subgoal '\(subgoal.id)' budget exceeded after \(stepsTaken) steps (max: \(subgoal.maxSteps))"
        case .loopDetected(let reason):
            return "Loop detected: \(reason)"
        case .actionStagnant(let reason):
            return "Action stagnant: \(reason)"
        case .executionError(let error):
            return "Execution error: \(error)"
        case .actionFailed(let error):
            return "Action failed: \(error)"
        }
    }
}

/// Decision made by System 2 Planner on how the autonomous loop should proceed after escalation.
public enum EscalationResolution: Sendable, Codable, Equatable {
    /// Retry the current subgoal with modified instructions.
    case retrySubgoal(Subgoal)

    /// Replace remaining plan with a revised sequence of subgoals.
    case replacePlan([Subgoal])
    case resumeWithRevisedSubgoals([Subgoal])

    /// Skip the problematic subgoal and proceed to the next one.
    case skipSubgoal(reason: String)
    case skipCurrentSubgoal

    /// Deem the entire goal completed successfully.
    case completeGoal(summary: String)

    /// Abort execution with a terminal error.
    case abort(reason: String)
}

// MARK: - Loop Configuration

/// Operational tuning parameters for TwoTierAutonomousLoopCoordinator.
public struct AutonomousLoopConfig: Sendable, Codable, Equatable {
    /// Maximum steps across the entire autonomous goal (hard ceiling). Default: 30.
    public var maxTotalSteps: Int

    /// Alias for maxTotalSteps matching test suites.
    public var maxSteps: Int {
        get { maxTotalSteps }
        set { maxTotalSteps = newValue }
    }

    /// Default max steps for a single subgoal if not specified. Default: 10.
    public var defaultSubgoalMaxSteps: Int

    /// Wall-clock ceiling for the whole goal, checked before every step. Default: 600s.
    public var maxDurationSeconds: Int

    /// Alias for defaultSubgoalMaxSteps matching test suites.
    public var maxSubgoalSteps: Int {
        get { defaultSubgoalMaxSteps }
        set { defaultSubgoalMaxSteps = newValue }
    }

    /// Confidence threshold below which System 1 escalates to System 2. Default: 0.80.
    public var confidenceThreshold: Float

    /// Delay in milliseconds after action execution to allow UI animation/rendering to settle. Default: 100ms.
    public var settlingDelayMs: Int

    /// Delay in seconds matching test suite convenience properties.
    public var settlingDelaySeconds: Double {
        get { Double(settlingDelayMs) / 1000.0 }
        set { settlingDelayMs = max(0, Int(newValue * 1000.0)) }
    }

    /// Maximum consecutive escalations allowed before aborting. Default: 3.
    public var maxConsecutiveEscalations: Int

    /// Two-Factor Loop Detection threshold for repeated identical actions. Default: 3.
    public var identicalActionThreshold: Int

    /// Two-Factor Loop Detection threshold for unchanged UI states. Default: 3.
    public var unchangedStateThreshold: Int

    /// When true, enables verbose diagnostic logging and step tracing. Default: false (or MCA_DEBUG=1 / MCA_AUTONOMOUS_DEBUG=1).
    public var isDebugMode: Bool

    /// Default debug mode inferred from environment variables.
    public static var defaultDebugMode: Bool {
        ProcessInfo.processInfo.environment["MCA_DEBUG"] == "1" ||
        ProcessInfo.processInfo.environment["MCA_AUTONOMOUS_DEBUG"] == "1"
    }

    public init(
        maxTotalSteps: Int = 30,
        defaultSubgoalMaxSteps: Int = 10,
        confidenceThreshold: Float = 0.80,
        settlingDelayMs: Int = 100,
        maxConsecutiveEscalations: Int = 3,
        identicalActionThreshold: Int = 3,
        unchangedStateThreshold: Int = 3,
        isDebugMode: Bool = AutonomousLoopConfig.defaultDebugMode,
        maxDurationSeconds: Int = 600
    ) {
        self.maxTotalSteps = maxTotalSteps
        self.maxDurationSeconds = maxDurationSeconds
        self.defaultSubgoalMaxSteps = defaultSubgoalMaxSteps
        self.confidenceThreshold = confidenceThreshold
        self.settlingDelayMs = settlingDelayMs
        self.maxConsecutiveEscalations = maxConsecutiveEscalations
        self.identicalActionThreshold = identicalActionThreshold
        self.unchangedStateThreshold = unchangedStateThreshold
        self.isDebugMode = isDebugMode
    }

    private enum CodingKeys: String, CodingKey {
        case maxTotalSteps, defaultSubgoalMaxSteps, maxDurationSeconds, confidenceThreshold, settlingDelayMs,
             maxConsecutiveEscalations, identicalActionThreshold, unchangedStateThreshold, isDebugMode
    }

    /// Configs encoded before `maxDurationSeconds` existed still decode, with the default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxTotalSteps: try c.decode(Int.self, forKey: .maxTotalSteps),
            defaultSubgoalMaxSteps: try c.decode(Int.self, forKey: .defaultSubgoalMaxSteps),
            confidenceThreshold: try c.decode(Float.self, forKey: .confidenceThreshold),
            settlingDelayMs: try c.decode(Int.self, forKey: .settlingDelayMs),
            maxConsecutiveEscalations: try c.decode(Int.self, forKey: .maxConsecutiveEscalations),
            identicalActionThreshold: try c.decode(Int.self, forKey: .identicalActionThreshold),
            unchangedStateThreshold: try c.decode(Int.self, forKey: .unchangedStateThreshold),
            isDebugMode: try c.decode(Bool.self, forKey: .isDebugMode),
            maxDurationSeconds: try c.decodeIfPresent(Int.self, forKey: .maxDurationSeconds) ?? 600)
    }

    public static let `default` = AutonomousLoopConfig()

    /// Configuration for zero-delay, deterministic test execution.
    public static var testing: AutonomousLoopConfig {
        AutonomousLoopConfig(
            maxTotalSteps: 30,
            defaultSubgoalMaxSteps: 10,
            confidenceThreshold: 0.80,
            settlingDelayMs: 0,
            maxConsecutiveEscalations: 3,
            identicalActionThreshold: 3,
            unchangedStateThreshold: 3,
            isDebugMode: false
        )
    }
}

// MARK: - Escalation Record

/// Record of an escalation attempt during autonomous execution.
public struct EscalationRecord: Sendable, Codable, Equatable {
    public let attempt: Int
    public let reason: EscalationReason
    public let timestamp: Date

    public init(attempt: Int, reason: EscalationReason, timestamp: Date = Date()) {
        self.attempt = attempt
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Execution Summary & Step Records

/// Record of an individual micro-action step executed within the autonomous loop.
public struct LoopStepRecord: Sendable, Codable, Equatable {
    public let stepNumber: Int
    public let subgoalId: String
    public let action: ComputerActionDecision
    public let verificationResult: StateVerificationResult?
    public let timestamp: Date

    public init(
        stepNumber: Int,
        subgoalId: String,
        action: ComputerActionDecision,
        verificationResult: StateVerificationResult? = nil,
        timestamp: Date = Date()
    ) {
        self.stepNumber = stepNumber
        self.subgoalId = subgoalId
        self.action = action
        self.verificationResult = verificationResult
        self.timestamp = timestamp
    }
}

/// Final summary produced upon termination of the autonomous execution loop.
public struct ExecutionSummary: Sendable, Codable, Equatable {
    public var goal: String
    public var isSuccess: Bool
    public var totalSteps: Int
    public var subgoalsCompleted: Int
    public var totalSubgoals: Int
    public var durationSeconds: Double
    public var stepRecords: [LoopStepRecord]
    public var terminationReason: String

    public var completedSubgoals: Int {
        get { subgoalsCompleted }
        set { subgoalsCompleted = newValue }
    }

    public var finalMessage: String {
        get { terminationReason }
        set { terminationReason = newValue }
    }

    public init(
        goal: String,
        isSuccess: Bool = true,
        totalSteps: Int = 0,
        subgoalsCompleted: Int = 0,
        totalSubgoals: Int = 0,
        durationSeconds: Double = 0.0,
        stepRecords: [LoopStepRecord] = [],
        terminationReason: String = ""
    ) {
        self.goal = goal
        self.isSuccess = isSuccess
        self.totalSteps = totalSteps
        self.subgoalsCompleted = subgoalsCompleted
        self.totalSubgoals = totalSubgoals
        self.durationSeconds = durationSeconds
        self.stepRecords = stepRecords
        self.terminationReason = terminationReason
    }

    public init(
        goal: String,
        totalSteps: Int,
        completedSubgoals: Int,
        totalSubgoals: Int,
        isSuccess: Bool,
        finalMessage: String
    ) {
        self.goal = goal
        self.isSuccess = isSuccess
        self.totalSteps = totalSteps
        self.subgoalsCompleted = completedSubgoals
        self.totalSubgoals = totalSubgoals
        self.durationSeconds = 0.0
        self.stepRecords = []
        self.terminationReason = finalMessage
    }
}

// MARK: - AutonomousLoopDelegate

/// Observability and interception delegate for autonomous loop lifecycle events.
public protocol AutonomousLoopDelegate: AnyObject, Sendable {
    func loopDidStart(goal: String, initialPlan: SubgoalPlan) async
    func loopDidStart(goal: String) async
    func loopDidBeginSubgoal(subgoal: Subgoal, index: Int, total: Int) async
    func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async
    func loopDidStep(step: Int, action: ComputerActionDecision, diff: UIStateDiff) async
    func loopDidVerifyOutcome(subgoal: Subgoal, result: StateVerificationResult) async
    func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) async throws -> EscalationResolution?
    func loopDidComplete(summary: ExecutionSummary) async
    func loopDidFail(error: LoopExecutionError) async
}

public extension AutonomousLoopDelegate {
    func loopDidStart(goal: String, initialPlan: SubgoalPlan) async {}
    func loopDidStart(goal: String) async {}
    func loopDidBeginSubgoal(subgoal: Subgoal, index: Int, total: Int) async {}
    func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async {}
    func loopDidStep(step: Int, action: ComputerActionDecision, diff: UIStateDiff) async {}
    func loopDidVerifyOutcome(subgoal: Subgoal, result: StateVerificationResult) async {}
    func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) async throws -> EscalationResolution? { nil }
    func loopDidComplete(summary: ExecutionSummary) async {}
    func loopDidFail(error: LoopExecutionError) async {}
}

// MARK: - DefaultSubgoalPlanner

/// Standard implementation of System2Planning using local decomposition rules and optional LanguageModelExecuting.
public struct DefaultSubgoalPlanner: System2Planning {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "DefaultSubgoalPlanner")
    public let modelExecutor: (any LanguageModelExecuting)?

    public init(modelExecutor: (any LanguageModelExecuting)? = nil) {
        self.modelExecutor = modelExecutor
    }

    public func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SubgoalPlan(goal: "", subgoals: [])
        }

        // If an LLM executor is configured and supported, query for structured subgoals
        if let executor = modelExecutor, executor.capabilities.contains(.guidedGeneration) {
            do {
                let prompt = """
                Decompose the following user computer automation goal into 1 to 4 sequential subgoals:
                Goal: "\(trimmed)"
                Frontmost App: "\(initialSnapshot?.appName ?? "Unknown")"
                Window Title: "\(initialSnapshot?.windowTitle ?? "Unknown")"

                Format as JSON array of objects:
                [{"id": "subgoal_1", "description": "...", "expectedOutcome": "...", "maxSteps": 10}]
                """
                let request = GenerationRequest(
                    transcript: [.instructions("You are a computer use task decomposition planner."), .prompt(Prompt(text: prompt))],
                    options: GenerationOptions(temperature: 0.1)
                )
                let response = try await executor.complete(request)
                if let data = response.text.data(using: .utf8),
                   let subgoals = try? JSONDecoder().decode([Subgoal].self, from: data), !subgoals.isEmpty {
                    return SubgoalPlan(goal: trimmed, subgoals: subgoals)
                }
            } catch {
                log.warning("System 2 LLM decomposition failed; falling back to deterministic heuristic decomposition: \(error.localizedDescription)")
            }
        }

        // Deterministic local decomposition fallback
        let subgoals = Self.heuristicDecompose(goal: trimmed)
        return SubgoalPlan(goal: trimmed, subgoals: subgoals)
    }

    public func replan(
        goal: String,
        failedSubgoal: Subgoal,
        reason: EscalationReason,
        currentSnapshot: UIStateSnapshot?,
        history: [LoopStepRecord]
    ) async throws -> EscalationResolution {
        log.info("System 2 replanning for failed subgoal '\(failedSubgoal.id)': \(String(describing: reason))")

        // 1. LLM Reflection Re-planning (when modelExecutor is configured and supported)
        if let executor = modelExecutor, executor.capabilities.contains(.guidedGeneration) {
            do {
                let candidateSummary: String = {
                    guard let snapshot = currentSnapshot, !snapshot.visibleCandidates.isEmpty else {
                        return "None"
                    }
                    return snapshot.visibleCandidates.prefix(12).map { c in
                        let labelStr = c.label.isEmpty ? "" : " '\(c.label)'"
                        return "[\(c.role)] id='\(c.id)'\(labelStr)"
                    }.joined(separator: ", ")
                }()

                let historySummary: String = {
                    guard !history.isEmpty else { return "None" }
                    return history.suffix(4).map { h in
                        let act = h.action.action.rawValue
                        let target = h.action.targetElementId ?? (h.action.coordinates != nil ? "coords" : "screen")
                        let outcome = h.verificationResult?.status.rawValue ?? "unverified"
                        return "Step \(h.stepNumber): \(act) on \(target) -> outcome: \(outcome)"
                    }.joined(separator: "\n")
                }()

                let reasonDescription: String = {
                    switch reason {
                    case .actionStagnant(let r): return "Action stagnant: \(r)"
                    case .lowConfidence(let c, let t): return "Low confidence (\(c) < threshold \(t))"
                    case .outcomeUnverified(let exp, let steps): return "Outcome '\(exp)' unverified after \(steps) steps"
                    case .verificationFailed(let exp, let r, _): return "Verification failed for '\(exp)': \(r)"
                    case .subgoalBudgetExceeded(let sg, let s): return "Subgoal budget exceeded for '\(sg.id)' after \(s) steps"
                    case .noCandidates, .emptyCandidates: return "No visible interactive UI elements"
                    case .loopDetected(let r): return "Loop detected: \(r)"
                    case .executionError(let e): return "Hardware execution error: \(e)"
                    case .actionFailed(let e): return "Action failed: \(e)"
                    }
                }()

                let prompt = """
                You are an autonomous computer use System 2 planner resolving an execution escalation.
                Overall User Goal: "\(goal)"
                Failed Subgoal: "\(failedSubgoal.description)" (Expected: "\(failedSubgoal.expectedOutcome)")
                Escalation Reason: \(reasonDescription)

                Recent Actions Taken:
                \(historySummary)

                Current Screen Observation:
                - Active App: "\(currentSnapshot?.appName ?? "Unknown")"
                - Window Title: "\(currentSnapshot?.windowTitle ?? "Unknown")"
                - Interactive Elements: \(candidateSummary)

                Reflect on why the previous attempt failed and determine the optimal recovery resolution.
                Respond strictly with a JSON object:
                {
                  "resolution": "replacePlan" | "retrySubgoal" | "completeGoal" | "abort",
                  "rationale": "short explanation of reflection and recovery direction",
                  "subgoals": [
                    {"id": "sg_recovery_1", "description": "concrete actionable directive", "expectedOutcome": "verifiable outcome", "maxSteps": 5}
                  ]
                }
                """

                let request = GenerationRequest(
                    transcript: [
                        .instructions("You are a computer use task decomposition planner and reflection engine. Always respond in valid JSON."),
                        .prompt(Prompt(text: prompt))
                    ],
                    options: GenerationOptions(temperature: 0.1)
                )

                let response = try await executor.complete(request)
                if let parsed = Self.parseReplanResponse(response.text, fallbackSubgoalId: failedSubgoal.id) {
                    log.info("System 2 LLM reflection generated resolution: \(String(describing: parsed))")
                    return parsed
                }
            } catch {
                log.warning("System 2 LLM replanning failed; falling back to deterministic heuristic recovery: \(error.localizedDescription)")
            }
        }

        // 2. Deterministic local heuristic recovery fallback
        return Self.heuristicReplan(failedSubgoal: failedSubgoal, reason: reason)
    }

    private struct ReplanPayload: Decodable {
        let resolution: String
        let rationale: String?
        let subgoals: [Subgoal]?
    }

    public static func parseReplanResponse(_ rawText: String, fallbackSubgoalId: String) -> EscalationResolution? {
        let cleaned: String
        if let start = rawText.firstIndex(of: "{"), let end = rawText.lastIndex(of: "}") {
            cleaned = String(rawText[start...end])
        } else {
            cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReplanPayload.self, from: data) else {
            return nil
        }

        switch payload.resolution.lowercased() {
        case "replaceplan":
            if let subgoals = payload.subgoals, !subgoals.isEmpty {
                return .replacePlan(subgoals)
            }
        case "retrysubgoal":
            if let first = payload.subgoals?.first {
                return .retrySubgoal(first)
            } else {
                return .retrySubgoal(Subgoal(
                    id: "\(fallbackSubgoalId)_retry",
                    description: payload.rationale ?? "Retry subgoal with adjusted interaction",
                    expectedOutcome: "",
                    maxSteps: 5
                ))
            }
        case "completegoal":
            return .completeGoal(summary: payload.rationale ?? "Goal marked as completed by System 2 reflection.")
        case "abort":
            return .abort(reason: payload.rationale ?? "System 2 determined task cannot proceed.")
        default:
            break
        }
        return nil
    }

    // MARK: - Replan Helper Methods

    /// Recursively strips existing replan prefixes and boilerplate to prevent runaway string nesting.
    public static func stripReplanBoilerplate(from description: String) -> String {
        let delimiters = CharacterSet(charactersIn: " :-,").union(.whitespacesAndNewlines)
        func trimLeadingDelimiters(_ s: String) -> String {
            var str = s
            while let first = str.unicodeScalars.first, delimiters.contains(first) {
                str.unicodeScalars.removeFirst()
            }
            return str
        }

        var text = trimLeadingDelimiters(description.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefixes = [
            "navigate using alternative elements or shortcuts for:",
            "navigate using alternative elements or shortcuts to:",
            "interact with alternative interactive element for:",
            "interact with alternative interactive element to:",
            "retry after low confidence:",
            "retry subgoal with adjusted interaction:",
            "conclude subgoal after reaching boundary:",
            "wait for ui to finish loading or rendering:",
            "wait for ui to finish loading or rendering",
            "retry:",
            "for:"
        ]

        var stripped = true
        while stripped {
            stripped = false
            let lower = text.lowercased()
            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    text = trimLeadingDelimiters(String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
                    stripped = true
                    break
                }
            }
        }
        return text.trimmingCharacters(in: delimiters)
    }

    /// Strips stagnant action keywords (scroll, feed, timeline, down, up, and Japanese equivalents)
    /// and dangling prepositions so fallbackLocalDecision does not re-classify the retry subgoal as .scroll.
    public static func stripStagnantKeywords(from description: String) -> String {
        var text = description

        // 1. English word-boundary removal for stagnant action words
        let englishPattern = "\\b(?:scroll(?:ing)?|feed|timeline|down(?:ward)?|up(?:ward)?)\\b"
        if let regex = try? NSRegularExpression(pattern: englishPattern, options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: " "
            )
        }

        // 2. Japanese stagnant terms removal
        let japaneseTerms = ["スクロール", "タイムライン", "フィード", "下を見て", "上を見て", "下へ", "上へ", "下に", "上に"]
        for term in japaneseTerms {
            text = text.replacingOccurrences(of: term, with: " ")
        }

        // 3. Clean up leading prepositions and conjunctions (e.g. "to find post" -> "find post")
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingPrepositionsPattern = "^(?:to|for|the|in|and|or|at|a|an|with|by|then)\\s+"
        if let prepRegex = try? NSRegularExpression(pattern: leadingPrepositionsPattern, options: .caseInsensitive) {
            var stripped = true
            while stripped {
                stripped = false
                let ns = cleaned as NSString
                if let match = prepRegex.firstMatch(in: cleaned, options: [], range: NSRange(location: 0, length: ns.length)) {
                    cleaned = ns.substring(from: match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    stripped = true
                }
            }
        }

        // 4. Clean Japanese leading grammatical particles left over (e.g. "をして最新の..." -> "最新の...")
        let japaneseLeadingParticles = ["をして", "して", "で", "を", "に", "から"]
        var strippedParticle = true
        while strippedParticle {
            strippedParticle = false
            for particle in japaneseLeadingParticles {
                if cleaned.hasPrefix(particle) {
                    cleaned = String(cleaned.dropFirst(particle.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    strippedParticle = true
                    break
                }
            }
        }

        // 5. Clean punctuation and collapse multiple whitespace
        let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+", options: [])
        cleaned = whitespaceRegex?.stringByReplacingMatches(
            in: cleaned,
            options: [],
            range: NSRange(location: 0, length: (cleaned as NSString).length),
            withTemplate: " "
        ) ?? cleaned

        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " :-,").union(.whitespacesAndNewlines))
    }

    /// Computes the next retry subgoal ID with bounded attempt counters (e.g., sg_alt -> sg_alt_2).
    public static func nextRetryId(from currentId: String, suffix: String) -> (id: String, attempt: Int) {
        var base = currentId
        var priorAttempt = 0

        let pattern = "_(" + ["retry_conf", "alt", "retry"].joined(separator: "|") + ")(?:_(\\d+))?$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = base as NSString
            if let match = regex.firstMatch(in: base, options: [], range: NSRange(location: 0, length: ns.length)) {
                if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    let numStr = ns.substring(with: match.range(at: 2))
                    priorAttempt = Int(numStr) ?? 1
                } else {
                    priorAttempt = 1
                }
                base = ns.substring(to: match.range.location)
            }
        }

        let nextAttempt = priorAttempt + 1
        let newId: String
        if nextAttempt <= 1 {
            newId = "\(base)_\(suffix)"
        } else {
            newId = "\(base)_\(suffix)_\(nextAttempt)"
        }
        return (newId, nextAttempt)
    }

    // MARK: - Hardened Heuristic Replan

    public static func heuristicReplan(failedSubgoal: Subgoal, reason: EscalationReason) -> EscalationResolution {
        switch reason {
        case .noCandidates, .emptyCandidates:
            let (retryId, attempt) = nextRetryId(from: failedSubgoal.id, suffix: "retry")
            if attempt >= 3 {
                return .abort(reason: "UI elements remain unavailable after \(attempt) attempts; outcome unverified.")
            }
            return .retrySubgoal(Subgoal(
                id: retryId,
                description: "wait for UI to finish loading or rendering",
                expectedOutcome: "element candidates appear on screen",
                maxSteps: 3
            ))

        case .lowConfidence:
            let (retryId, attempt) = nextRetryId(from: failedSubgoal.id, suffix: "retry_conf")
            let baseDesc = stripReplanBoilerplate(from: failedSubgoal.description)
            let coreTarget = baseDesc.isEmpty ? "interactive elements on screen" : baseDesc

            // Exhausted attempts establish inability to proceed, not success.
            if attempt >= 3 {
                return .abort(reason: "Outcome unverified after \(attempt) low-confidence attempts: \(coreTarget)")
            }

            return .retrySubgoal(Subgoal(
                id: retryId,
                description: "Interact with alternative interactive element for: \(coreTarget)",
                expectedOutcome: "screen state changes or control selected",
                maxSteps: max(failedSubgoal.maxSteps, 4)
            ))

        case .verificationFailed(let expected, let rationale, _):
            return .abort(reason: "State verification failed for outcome '\(expected)': \(rationale)")

        case .outcomeUnverified(let expected, let steps):
            return .abort(reason: "Subgoal outcome '\(expected)' unverified after \(steps) steps")

        case .subgoalBudgetExceeded(let subgoal, let steps):
            return .abort(reason: "Subgoal '\(subgoal.id)' step budget exceeded (\(steps) steps)")

        case .loopDetected(let reason):
            return .abort(reason: "Execution halted: \(reason)")

        case .actionStagnant(let reasonText):
            let (retryId, attempt) = nextRetryId(from: failedSubgoal.id, suffix: "alt")
            let unnested = stripReplanBoilerplate(from: failedSubgoal.description)
            let strippedCore = stripStagnantKeywords(from: unnested)
            let targetText = strippedCore.isEmpty ? "target elements or controls" : strippedCore

            // An inert boundary or retry limit cannot establish the requested outcome.
            let isBoundary = reasonText.lowercased().contains("boundary") || reasonText.lowercased().contains("inert")
            if attempt >= 3 || isBoundary {
                return .abort(reason: "Outcome unverified at page boundary or recovery limit for: \(targetText)")
            }

            return .retrySubgoal(Subgoal(
                id: retryId,
                description: "Navigate using alternative elements or shortcuts for: \(targetText)",
                expectedOutcome: "screen state changes or target appears",
                maxSteps: max(failedSubgoal.maxSteps, 5)
            ))

        case .executionError(let err), .actionFailed(let err):
            return .abort(reason: "Action execution failure: \(err)")
        }
    }

    public static func heuristicDecompose(goal: String) -> [Subgoal] {
        let lower = goal.lowercased()

        // Multi-clause search & enter heuristic: e.g. "search Tokyo and click first link"
        if (lower.contains("search") || lower.contains("検索")) && (lower.contains("click") || lower.contains("クリック")) {
            return [
                Subgoal(
                    id: "subgoal_1",
                    description: "Focus search field and enter search query",
                    expectedOutcome: "value updated with search term or search executed",
                    maxSteps: 5
                ),
                Subgoal(
                    id: "subgoal_2",
                    description: "Click the target link or result",
                    expectedOutcome: "window title changed or page navigated",
                    maxSteps: 5
                )
            ]
        }

        // Single-goal direct pass-through
        return [
            Subgoal(
                id: "subgoal_1",
                description: goal,
                expectedOutcome: "",
                maxSteps: 15
            )
        ]
    }
}

// MARK: - TwoTierAutonomousLoopCoordinator

/// Primary orchestrator of the 2-Tier Autonomous Execution Loop.
/// Coordinates System 2 (coarse subgoal planning) and System 1 (rapid TypeSafe Jev micro-actions <200ms),
/// enforcing strict safety guardrails, state diff verification, and escalation recovery.
public actor TwoTierAutonomousLoopCoordinator {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "TwoTierAutonomousLoopCoordinator")

    public let planner: any System2Planning
    public let decisionEngine: TypeSafeDecisionEngine
    public let synthesizer: any EventSynthesizing
    public let snapshotProvider: any UIStateProviding
    public let config: AutonomousLoopConfig
    public weak var delegate: (any AutonomousLoopDelegate)?
    /// Asked before each step that types or presses a key (see
    /// ``KeystrokeApproval``); a refusal ends the run. Refuses by default;
    /// ``AutoApproveToolApprover`` only where the caller already approved the
    /// whole run (MCP `autonomous_act`) or nothing is sent (dry run).
    public let keystrokeApprover: any ToolApproving

    public init(
        planner: any System2Planning = DefaultSubgoalPlanner(),
        decisionEngine: TypeSafeDecisionEngine = TypeSafeDecisionEngine(),
        synthesizer: any EventSynthesizing = EventSynthesizer(),
        snapshotProvider: (any UIStateProviding)? = nil,
        inspector: (any UIStateProviding)? = nil,
        config: AutonomousLoopConfig = .default,
        delegate: (any AutonomousLoopDelegate)? = nil,
        keystrokeApprover: any ToolApproving = DenyAllToolApprover()
    ) {
        self.planner = planner
        self.decisionEngine = decisionEngine
        self.synthesizer = synthesizer
        self.keystrokeApprover = keystrokeApprover
        self.snapshotProvider = inspector ?? snapshotProvider ?? InspectUIElementsTool.makeDefaultInspector(maxCandidates: 25)
        self.config = config
        self.delegate = delegate
    }

    // Tokens can outlive a run; clear the completed Task rather than retain its result.
    private final class ExecutionCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var execution: Task<ExecutionSummary, Error>?
        init(_ execution: Task<ExecutionSummary, Error>) { self.execution = execution }
        func cancel() { lock.withLock { execution }?.cancel() }
        func finish() { lock.withLock { execution = nil } }
    }

    /// Executes an autonomous goal to completion under cooperative cancellation.
    public func execute(
        goal: String,
        cancellationToken: CancellationToken = .none
    ) async throws -> ExecutionSummary {
        // A shared token must cancel suspended perception/planning/model work too.
        // The child inherits the caller's TaskLocal authorization and privacy scope.
        let execution = Task {
            try await executeLoop(goal: goal, cancellationToken: cancellationToken)
        }
        let cancellation = ExecutionCancellation(execution)
        defer { cancellation.finish() }
        cancellationToken.onCancel { cancellation.cancel() }
        return try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            cancellationToken.cancel()
            cancellation.cancel()
        }
    }

    private func executeLoop(
        goal: String,
        cancellationToken: CancellationToken
    ) async throws -> ExecutionSummary {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw LoopExecutionError.executionFailed(reason: "Goal cannot be empty.")
        }

        let startTime = Date()
        // Monotonic: a wall-clock jump (NTP, manual change) must not end or extend the run.
        let deadline = ContinuousClock.now + .seconds(config.maxDurationSeconds)
        var stepBudget = StepBudgetMonitor(
            maxSteps: config.maxTotalSteps,
            maxSubgoalSteps: config.defaultSubgoalMaxSteps
        )
        var loopDetector = TwoFactorLoopDetector(config: .init(
            identicalActionThreshold: config.identicalActionThreshold,
            unchangedStateThreshold: config.unchangedStateThreshold
        ))
        var stepRecords: [LoopStepRecord] = []
        var subgoalsCompletedCount = 0

        // Emergency halt registration: release hardware event state on cancellation
        EmergencyHaltManager.bindEmergencyRelease(
            token: cancellationToken,
            synthesizer: synthesizer
        )

        do {
            try cancellationToken.throwIfCancelled()

            // 1. Initial Screen State Perception
            var currentSnapshot = try await snapshotProvider.captureSnapshot()
            try cancellationToken.throwIfCancelled()

            // 2. System 2 Initial Plan Generation
            var plan = try await planner.plan(goal: trimmedGoal, initialSnapshot: currentSnapshot)
            if plan.subgoals.isEmpty {
                plan = SubgoalPlan(goal: trimmedGoal, subgoals: [
                    Subgoal(id: "subgoal_1", description: trimmedGoal, expectedOutcome: "", maxSteps: config.defaultSubgoalMaxSteps)
                ])
            }
            log.info("[AutonomousLoop] Started execution for goal (\(trimmedGoal.count) chars) (maxSteps: \(self.config.maxTotalSteps), debug: \(self.config.isDebugMode))")
            await delegate?.loopDidStart(goal: trimmedGoal, initialPlan: plan)
            await delegate?.loopDidStart(goal: trimmedGoal)

            // 3. Subgoal Execution Loop
            while !plan.isCompleted {
                try cancellationToken.throwIfCancelled()
                if currentSnapshot.visibleCandidates.isEmpty {
                    currentSnapshot = try await snapshotProvider.captureSnapshot()
                }
                guard var currentSubgoal = plan.currentSubgoal else { break }

                stepBudget.resetSubgoalBudget()
                loopDetector.reset()
                var consecutiveEscalations = 0
                var recentEscalations: [EscalationRecord] = []
                var lastDiff: UIStateDiff? = nil
                var subgoalResolved = false

                await delegate?.loopDidBeginSubgoal(
                    subgoal: currentSubgoal,
                    index: plan.currentSubgoalIndex,
                    total: plan.subgoals.count
                )

                // 4. System 1 Micro-Action Loop
                while !subgoalResolved {
                    try cancellationToken.throwIfCancelled()

                    // Checkpoint: Wall clock
                    if ContinuousClock.now >= deadline {
                        throw LoopExecutionError.timeLimitExceeded(seconds: config.maxDurationSeconds)
                    }

                    // Checkpoint: Step Budget
                    do {
                        try stepBudget.increment()
                    } catch let error as LoopExecutionError {
                        // Escalation on subgoal budget exhaustion
                        if case .stepBudgetExceeded = error,
                           stepBudget.totalStepsExecuted < stepBudget.maxSteps,
                           stepBudget.currentSubgoalSteps >= currentSubgoal.maxSteps {
                            let escReason = EscalationReason.subgoalBudgetExceeded(subgoal: currentSubgoal, stepsTaken: stepBudget.currentSubgoalSteps)
                            try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                            let resolution = try await handleEscalation(
                                reason: escReason,
                                subgoal: currentSubgoal,
                                plan: &plan,
                                history: stepRecords,
                                cachedSnapshot: currentSnapshot,
                                cancellationToken: cancellationToken
                            )
                            if resolution == .subgoalHandled {
                                subgoalResolved = true
                                break
                            }
                            guard let updated = plan.currentSubgoal else {
                                subgoalResolved = true
                                break
                            }
                            currentSubgoal = updated
                            stepBudget.resetSubgoalBudget()
                            loopDetector.reset()
                            try cancellationToken.throwIfCancelled()
                            await delegate?.loopDidBeginSubgoal(
                                subgoal: currentSubgoal,
                                index: plan.currentSubgoalIndex,
                                total: plan.subgoals.count
                            )
                            try cancellationToken.throwIfCancelled()
                            currentSnapshot = try await snapshotProvider.captureSnapshot()
                            continue
                        }
                        throw error
                    }

                    let beforeSnapshot = currentSnapshot
                    let candidates = beforeSnapshot.visibleCandidates

                    // Escalation Condition 1: Missing candidates
                    if candidates.isEmpty {
                        let escReason = EscalationReason.emptyCandidates
                        try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                        let resolution = try await handleEscalation(
                            reason: escReason,
                            subgoal: currentSubgoal,
                            plan: &plan,
                            history: stepRecords,
                            cachedSnapshot: beforeSnapshot,
                            cancellationToken: cancellationToken
                        )
                        if resolution == .subgoalHandled {
                            subgoalResolved = true
                            break
                        }
                        guard let updated = plan.currentSubgoal else {
                            subgoalResolved = true
                            break
                        }
                        currentSubgoal = updated
                        stepBudget.resetSubgoalBudget()
                        loopDetector.reset()
                        try cancellationToken.throwIfCancelled()
                        await delegate?.loopDidBeginSubgoal(
                            subgoal: currentSubgoal,
                            index: plan.currentSubgoalIndex,
                            total: plan.subgoals.count
                        )
                        try cancellationToken.throwIfCancelled()
                        currentSnapshot = try await snapshotProvider.captureSnapshot()
                        continue
                    }

                    if config.isDebugMode {
                        log.debug("[AutonomousLoop][Debug] Step \(stepBudget.totalStepsExecuted) candidates: \(candidates.count) found for activeApp: '\(beforeSnapshot.appName ?? "unknown", privacy: .public)'")
                        for (i, c) in candidates.prefix(5).enumerated() {
                            let label = c.label.isEmpty ? (c.value ?? "") : c.label
                            log.debug("[AutonomousLoop][Debug]   [\(i)] id=\(c.id, privacy: .public) role=\(c.role, privacy: .public) label='\(label)'")
                        }
                    }

                    // System 1 Micro-Grounding (<200ms)
                    let decision = try await decisionEngine.decideNextAction(
                        goal: currentSubgoal.description,
                        activeApp: beforeSnapshot.appName,
                        candidates: candidates,
                        history: stepRecords,
                        recentEscalations: recentEscalations,
                        lastDiff: lastDiff
                    )
                    try cancellationToken.throwIfCancelled()

                    if config.isDebugMode {
                        let targetDesc = decision.targetElementId ?? "none"
                        log.debug("[AutonomousLoop][Debug] Decision: action=\(decision.action.rawValue, privacy: .public) conf=\(decision.confidence) target=\(targetDesc, privacy: .public)")
                    }

                    // Completion check directly from Jev or offline fallback
                    if decision.isCompleted {
                        let hasExplicitExpectedOutcome = !currentSubgoal.expectedOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let isInertOrStagnant = decision.action == .none && (
                            decision.reasoning?.lowercased().contains("inert") == true ||
                            decision.reasoning?.lowercased().contains("boundary") == true
                        )

                        if hasExplicitExpectedOutcome && isInertOrStagnant {
                            // System 1 offline fallback concluded due to inert/boundary stagnation, but the subgoal has an unfulfilled explicit expected outcome.
                            // Escalate to System 2 planner to allow deliberative replan or abort.
                            let stagnantReason = decision.reasoning ?? "Subgoal target inert or page boundary reached without verifying expected outcome."
                            let escReason = EscalationReason.actionStagnant(reason: stagnantReason)
                            try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                            let resolution = try await handleEscalation(
                                reason: escReason,
                                subgoal: currentSubgoal,
                                plan: &plan,
                                history: stepRecords,
                                cachedSnapshot: beforeSnapshot,
                                cancellationToken: cancellationToken
                            )
                            if resolution == .subgoalHandled {
                                subgoalResolved = true
                                break
                            }
                            guard let updated = plan.currentSubgoal else {
                                subgoalResolved = true
                                break
                            }
                            currentSubgoal = updated
                            stepBudget.resetSubgoalBudget()
                            loopDetector.reset()
                            try cancellationToken.throwIfCancelled()
                            await delegate?.loopDidBeginSubgoal(
                                subgoal: currentSubgoal,
                                index: plan.currentSubgoalIndex,
                                total: plan.subgoals.count
                            )
                            try cancellationToken.throwIfCancelled()
                            if currentSnapshot.visibleCandidates.isEmpty {
                                currentSnapshot = try await snapshotProvider.captureSnapshot()
                            }
                            continue
                        }

                        log.info("System 1 signaled goal completion on screen state.")
                        if consecutiveEscalations > 0 {
                            log.info("[AutonomousLoop] Consecutive escalations reset from \(consecutiveEscalations) to 0 following progress.")
                        }
                        consecutiveEscalations = 0
                        recentEscalations.removeAll()
                        lastDiff = nil
                        subgoalsCompletedCount += 1
                        plan.advance()
                        subgoalResolved = true
                        break
                    }

                    // Escalation Condition 2: Low confidence or unresolvable action
                    if decision.confidence < config.confidenceThreshold || decisionEngine.shouldEscalate(decision: decision) {
                        let escReason = EscalationReason.lowConfidence(
                            confidence: decision.confidence,
                            threshold: config.confidenceThreshold
                        )
                        try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                        let resolution = try await handleEscalation(
                            reason: escReason,
                            subgoal: currentSubgoal,
                            plan: &plan,
                            history: stepRecords,
                            cachedSnapshot: beforeSnapshot,
                            cancellationToken: cancellationToken
                        )
                        if resolution == .subgoalHandled {
                            subgoalResolved = true
                            break
                        }
                        guard let updated = plan.currentSubgoal else {
                            subgoalResolved = true
                            break
                        }
                        currentSubgoal = updated
                        stepBudget.resetSubgoalBudget()
                        loopDetector.reset()
                        try cancellationToken.throwIfCancelled()
                        await delegate?.loopDidBeginSubgoal(
                            subgoal: currentSubgoal,
                            index: plan.currentSubgoalIndex,
                            total: plan.subgoals.count
                        )
                        try cancellationToken.throwIfCancelled()
                        currentSnapshot = try await snapshotProvider.captureSnapshot()
                        continue
                    }

                    // Guardrail Check: Factor 1 Loop Detection
                    do {
                        try loopDetector.recordAction(decision: decision)
                    } catch let error as LoopExecutionError {
                        if case .infiniteLoopDetected(let reason) = error {
                            let escReason = EscalationReason.actionStagnant(reason: reason)
                            try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                            let resolution = try await handleEscalation(
                                reason: escReason,
                                subgoal: currentSubgoal,
                                plan: &plan,
                                history: stepRecords,
                                cachedSnapshot: beforeSnapshot,
                                cancellationToken: cancellationToken
                            )
                            if resolution == .subgoalHandled {
                                subgoalResolved = true
                                break
                            }
                            guard let updated = plan.currentSubgoal else {
                                subgoalResolved = true
                                break
                            }
                            currentSubgoal = updated
                            stepBudget.resetSubgoalBudget()
                            loopDetector.reset()
                            try cancellationToken.throwIfCancelled()
                            await delegate?.loopDidBeginSubgoal(
                                subgoal: currentSubgoal,
                                index: plan.currentSubgoalIndex,
                                total: plan.subgoals.count
                            )
                            try cancellationToken.throwIfCancelled()
                            currentSnapshot = try await snapshotProvider.captureSnapshot()
                            continue
                        }
                        throw error
                    }
                    try cancellationToken.throwIfCancelled()

                    if let refusal = await keystrokeRefusal(for: decision, app: beforeSnapshot.appName) {
                        throw LoopExecutionError.executionFailed(reason: refusal)
                    }

                    // Synthetic GUI Event Execution with transactional rollback on hardware failure
                    do {
                        try await executeSyntheticAction(decision, candidates: candidates, snapshot: beforeSnapshot,
                            goal: currentSubgoal.description, cancellationToken: cancellationToken)
                    } catch {
                        loopDetector.rollbackLastAction()
                        synthesizer.releaseAllHeldEvents()
                        throw error
                    }

                    // Post-Action Settling
                    if config.settlingDelayMs > 0 {
                        try await cancellationToken.sleep(milliseconds: config.settlingDelayMs)
                    }

                    // Post-Action Perception
                    let afterSnapshot = try await snapshotProvider.captureSnapshot()
                    try cancellationToken.throwIfCancelled()

                    // State Diff Computation
                    let diff = UIStateDiff.compute(before: beforeSnapshot, after: afterSnapshot)
                    currentSnapshot = afterSnapshot
                    lastDiff = diff

                    if !diff.isStateUnchanged {
                        if consecutiveEscalations > 0 {
                            log.info("[AutonomousLoop] Consecutive escalations reset from \(consecutiveEscalations) to 0 following verified screen state progress (diff changed).")
                        }
                        consecutiveEscalations = 0
                        recentEscalations.removeAll()
                    }

                    if config.isDebugMode {
                        log.debug("[AutonomousLoop][Debug] UIStateDiff: focusChanged=\(diff.focusChanged) titleChanged=\(diff.titleChanged) layoutMutated=\(diff.layoutMutated)")
                    }

                    await delegate?.loopDidStep(
                        step: stepBudget.totalStepsExecuted,
                        subgoal: currentSubgoal,
                        action: decision,
                        diff: diff
                    )
                    await delegate?.loopDidStep(
                        step: stepBudget.totalStepsExecuted,
                        action: decision,
                        diff: diff
                    )

                    // Outcome Verification
                    let verification = diff.verifyOutcome(expected: currentSubgoal.expectedOutcome)
                    await delegate?.loopDidVerifyOutcome(subgoal: currentSubgoal, result: verification)

                    let stepRecord = LoopStepRecord(
                        stepNumber: stepBudget.totalStepsExecuted,
                        subgoalId: currentSubgoal.id,
                        action: decision,
                        verificationResult: verification
                    )
                    stepRecords.append(stepRecord)

                    // Verification Evaluation:
                    // Only advance on declarative verification if the subgoal specified an explicit expected outcome.
                    // For subgoals without an explicit expected outcome, completion must be signaled by
                    // System 1's goal-completion check (decision.isCompleted) or deliberative planner resolution.
                    let hasExplicitExpectedOutcome = !currentSubgoal.expectedOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasExplicitExpectedOutcome && verification.isVerified {
                        log.info("Subgoal '\(currentSubgoal.id)' verified successfully against expected outcome.")
                        if consecutiveEscalations > 0 {
                            log.info("[AutonomousLoop] Consecutive escalations reset from \(consecutiveEscalations) to 0 following progress.")
                        }
                        consecutiveEscalations = 0
                        recentEscalations.removeAll()
                        lastDiff = nil
                        subgoalsCompletedCount += 1
                        plan.advance()
                        subgoalResolved = true
                        break
                    }

                    // Guardrail Check: Factor 2 Loop Detection
                    do {
                        try loopDetector.recordStateDiff(diff: diff)
                    } catch let error as LoopExecutionError {
                        if case .infiniteLoopDetected(let reason) = error {
                            let escReason = EscalationReason.actionStagnant(reason: reason)
                            try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                            let resolution = try await handleEscalation(
                                reason: escReason,
                                subgoal: currentSubgoal,
                                plan: &plan,
                                history: stepRecords,
                                cachedSnapshot: afterSnapshot,
                                cancellationToken: cancellationToken
                            )
                            if resolution == .subgoalHandled {
                                subgoalResolved = true
                                break
                            }
                            guard let updated = plan.currentSubgoal else {
                                subgoalResolved = true
                                break
                            }
                            currentSubgoal = updated
                            stepBudget.resetSubgoalBudget()
                            loopDetector.reset()
                            try cancellationToken.throwIfCancelled()
                            await delegate?.loopDidBeginSubgoal(
                                subgoal: currentSubgoal,
                                index: plan.currentSubgoalIndex,
                                total: plan.subgoals.count
                            )
                            try cancellationToken.throwIfCancelled()
                            if currentSnapshot.visibleCandidates.isEmpty {
                                currentSnapshot = try await snapshotProvider.captureSnapshot()
                            }
                            continue
                        }
                        throw error
                    }

                    if stepBudget.currentSubgoalSteps >= currentSubgoal.maxSteps {
                        let escReason = EscalationReason.outcomeUnverified(
                            expected: currentSubgoal.expectedOutcome,
                            stepsTaken: stepBudget.currentSubgoalSteps
                        )
                        try recordAndCheckEscalation(reason: escReason, count: &consecutiveEscalations, history: &recentEscalations)
                        let resolution = try await handleEscalation(
                            reason: escReason,
                            subgoal: currentSubgoal,
                            plan: &plan,
                            history: stepRecords,
                            cachedSnapshot: afterSnapshot,
                            cancellationToken: cancellationToken
                        )
                        if resolution == .subgoalHandled {
                            subgoalResolved = true
                            break
                        }
                        guard let updated = plan.currentSubgoal else {
                            subgoalResolved = true
                            break
                        }
                        currentSubgoal = updated
                        stepBudget.resetSubgoalBudget()
                        loopDetector.reset()
                        try cancellationToken.throwIfCancelled()
                        await delegate?.loopDidBeginSubgoal(
                            subgoal: currentSubgoal,
                            index: plan.currentSubgoalIndex,
                            total: plan.subgoals.count
                        )
                        try cancellationToken.throwIfCancelled()
                        if currentSnapshot.visibleCandidates.isEmpty {
                            currentSnapshot = try await snapshotProvider.captureSnapshot()
                        }
                    }
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            let summary = ExecutionSummary(
                goal: trimmedGoal,
                isSuccess: true,
                totalSteps: stepBudget.totalStepsExecuted,
                subgoalsCompleted: subgoalsCompletedCount,
                totalSubgoals: plan.subgoals.count,
                durationSeconds: duration,
                stepRecords: stepRecords,
                terminationReason: "All subgoals completed successfully."
            )
            log.info("[AutonomousLoop] Goal completed successfully in \(stepBudget.totalStepsExecuted) steps (\(String(format: "%.2f", duration))s).")
            await delegate?.loopDidComplete(summary: summary)
            return summary

        } catch {
            if let loopErr = error as? LoopExecutionError {
                switch loopErr {
                case .cancelled, .stepBudgetExceeded:
                    // cancellation handled via token, stepBudget doesn't require release
                    break
                case .infiniteLoopDetected, .executionFailed, .escalationFailed:
                    synthesizer.releaseAllHeldEvents()
                }
            } else {
                synthesizer.releaseAllHeldEvents()
            }

            let loopError: LoopExecutionError
            if cancellationToken.isCancelled || Task.isCancelled {
                loopError = .cancelled
            } else if let le = error as? LoopExecutionError {
                loopError = le
            } else {
                loopError = .executionFailed(reason: error.localizedDescription)
            }
            log.error("[AutonomousLoop] Execution halted: \(loopError.localizedDescription)")
            await delegate?.loopDidFail(error: loopError)
            throw loopError
        }
    }

    // MARK: - Private Helpers

    private enum EscalationHandlingResult {
        case subgoalHandled
        case retryRequired
    }

    private func handleEscalation(
        reason: EscalationReason,
        subgoal: Subgoal,
        plan: inout SubgoalPlan,
        history: [LoopStepRecord],
        cachedSnapshot: UIStateSnapshot? = nil,
        cancellationToken: CancellationToken
    ) async throws -> EscalationHandlingResult {
        try cancellationToken.throwIfCancelled()

        // Delegate has first opportunity to resolve escalation
        if let delegateResolution = try await delegate?.loopDidEscalate(reason: reason, subgoal: subgoal) {
            try cancellationToken.throwIfCancelled()
            return try applyResolution(delegateResolution, plan: &plan)
        }

        let currentSnapshot: UIStateSnapshot?
        if let cachedSnapshot {
            currentSnapshot = cachedSnapshot
        } else {
            currentSnapshot = try? await snapshotProvider.captureSnapshot()
        }

        let resolution: EscalationResolution
        do {
            resolution = try await planner.replan(
                goal: plan.goal,
                failedSubgoal: subgoal,
                reason: reason,
                currentSnapshot: currentSnapshot,
                history: history
            )
        } catch let loopErr as LoopExecutionError {
            throw loopErr
        } catch is CancellationError {
            synthesizer.releaseAllHeldEvents()
            throw LoopExecutionError.cancelled
        } catch {
            synthesizer.releaseAllHeldEvents()
            if cancellationToken.isCancelled {
                throw LoopExecutionError.cancelled
            }
            throw LoopExecutionError.escalationFailed(reason: error.localizedDescription)
        }
        try cancellationToken.throwIfCancelled()
        return try applyResolution(resolution, plan: &plan)
    }

    private func applyResolution(
        _ resolution: EscalationResolution,
        plan: inout SubgoalPlan
    ) throws -> EscalationHandlingResult {
        switch resolution {
        case .retrySubgoal(let revised):
            if plan.currentSubgoalIndex < plan.subgoals.count {
                plan.subgoals[plan.currentSubgoalIndex] = revised
            }
            return .retryRequired

        case .replacePlan(let newSubgoals), .resumeWithRevisedSubgoals(let newSubgoals):
            plan.replaceRemaining(from: plan.currentSubgoalIndex, with: newSubgoals)
            return .retryRequired

        case .skipSubgoal, .skipCurrentSubgoal:
            plan.advance()
            return .subgoalHandled

        case .completeGoal:
            plan.currentSubgoalIndex = plan.subgoals.count
            return .subgoalHandled

        case .abort(let reason):
            throw LoopExecutionError.escalationFailed(reason: reason)
        }
    }

    private func recordAndCheckEscalation(
        reason: EscalationReason,
        count: inout Int,
        history: inout [EscalationRecord]
    ) throws {
        count += 1
        let currentCount = count
        let record = EscalationRecord(attempt: currentCount, reason: reason, timestamp: Date())
        history.append(record)
        log.warning("[AutonomousLoop] Escalation triggered (\(currentCount)/\(self.config.maxConsecutiveEscalations)): \(reason.description)")

        if currentCount >= config.maxConsecutiveEscalations {
            let reasonsSummary = history.map { "#\($0.attempt): \($0.reason.description)" }.joined(separator: "; ")
            log.error("[AutonomousLoop] Exceeded maximum consecutive escalations (\(currentCount)). Causes: [\(reasonsSummary)]")
            throw LoopExecutionError.escalationFailed(
                reason: "Exceeded maximum consecutive escalations (\(currentCount)). Causes: [\(reasonsSummary)]"
            )
        }
    }

    private func resolveTargetPID(from snapshot: UIStateSnapshot?) -> pid_t? {
        #if canImport(AppKit)
        if let bundleId = snapshot?.appBundleId, !bundleId.isEmpty {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                return app.processIdentifier
            }
        }
        if let appName = snapshot?.appName, !appName.isEmpty {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
                return app.processIdentifier
            }
        }
        #endif
        return nil
    }

    /// Nil when the step may run; otherwise why it may not.
    func keystrokeRefusal(for decision: ComputerActionDecision, app: String?) async -> String? {
        // A scoped task's ActionAuthorization card already presents the exact decision
        // and revalidates its target. Standalone CLI/MCP runs use this dedicated gate.
        guard ActionAuthorization.current == nil else { return nil }
        let approver = keystrokeApprover
        let request: ToolApprovalRequest
        switch decision.action {
        case .typeText:
            guard let text = decision.textInput else { return nil }
            request = KeystrokeApproval.request(tool: "autonomous_act", title: "Type text", keystrokes: text, app: app)
        case .keyPress:
            let keys = decision.keyCombination ?? []
            guard keys.contains(where: KeystrokeApproval.needsApproval(key:)) else { return nil }
            request = KeystrokeApproval.request(
                tool: "autonomous_act", title: "Press keys", keystrokes: "Keys: \(keys.joined(separator: ", "))", app: app)
        default:
            return nil
        }
        return await approver.gate(request)
    }

    private func executeSyntheticAction(
        _ decision: ComputerActionDecision,
        candidates: [UIElementCandidate] = [],
        snapshot: UIStateSnapshot? = nil,
        goal: String? = nil,
        cancellationToken: CancellationToken
    ) async throws {
        if !synthesizer.isSimulation, decision.action != .none && decision.action != .wait {
            try await DesktopActionAuthorization.requireApproval(operation: decision.action.rawValue, details: "Goal: \(goal ?? "")\nDecision: \(decision)", expected: snapshot)
        }
        try cancellationToken.throwIfCancelled()
        do {
            let targetPID = resolveTargetPID(from: snapshot)

            // Resolve target coordinates with robust fallback cascade
            let targetPoint: CGPoint? = {
                // 1. Explicit coordinates provided by decision
                if let direct = decision.targetCenter ?? decision.coordinates {
                    return direct
                }
                // 2. Candidate center matching targetElementId
                if let targetId = decision.targetElementId, targetId != "none",
                   let matched = candidates.first(where: { $0.id == targetId }) {
                    return matched.center
                }
                // 3. Fallback coordinate resolution for .scroll
                if decision.action == .scroll {
                    // 3a. Target scroll container candidate if available
                    if let container = TypeSafeDecisionEngine.resolveScrollContainer(candidates: candidates, goal: goal ?? "") {
                        return container.center
                    }
                    // 3b. Fall back to candidate bounding box centroid or screen center
                    return TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: candidates)
                }
                return nil
            }()

            try cancellationToken.throwIfCancelled()
            guard let coordinates = targetPoint else {
                switch decision.action {
                case .typeText:
                    if let text = decision.textInput {
                        try synthesizer.typeText(text)
                    }
                case .keyPress:
                    if let keys = decision.keyCombination {
                        for key in keys {
                            try cancellationToken.throwIfCancelled()
                            try synthesizer.pressKey(key)
                        }
                    }
                case .scroll:
                    // Defensive fallback: If targetPoint was somehow nil, resolve viewport centroid
                    let fallbackPoint = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: candidates)
                    let delta = decision.scrollDelta ?? CGVector(dx: 0, dy: -5)
                    try synthesizer.scroll(deltaX: Int32(delta.dx), deltaY: Int32(delta.dy), at: fallbackPoint, targetPID: targetPID)
                case .wait, .none:
                    break
                case .click, .doubleClick, .rightClick:
                    throw LoopExecutionError.executionFailed(reason: "Missing target coordinate for \(decision.action.rawValue).")
                }
                return
            }

            switch decision.action {
            case .click:
                try synthesizer.click(at: coordinates, button: .left, clickCount: 1)
            case .doubleClick:
                try synthesizer.click(at: coordinates, button: .left, clickCount: 2)
            case .rightClick:
                try synthesizer.click(at: coordinates, button: .right, clickCount: 1)
            case .typeText:
                try synthesizer.click(at: coordinates, button: .left, clickCount: 1)
                if let text = decision.textInput {
                    try cancellationToken.throwIfCancelled()
                    try synthesizer.typeText(text)
                }
            case .keyPress:
                try synthesizer.click(at: coordinates, button: .left, clickCount: 1)
                if let keys = decision.keyCombination {
                    for key in keys {
                        try cancellationToken.throwIfCancelled()
                        try synthesizer.pressKey(key)
                    }
                }
            case .scroll:
                let delta = decision.scrollDelta ?? CGVector(dx: 0, dy: -5)
                try synthesizer.scroll(deltaX: Int32(delta.dx), deltaY: Int32(delta.dy), at: coordinates, targetPID: targetPID)
            case .wait:
                break
            case .none:
                break
            }
        } catch let loopErr as LoopExecutionError {
            throw loopErr
        } catch {
            throw LoopExecutionError.executionFailed(reason: error.localizedDescription)
        }
    }
}
