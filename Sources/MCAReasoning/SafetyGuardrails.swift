import CoreGraphics
import Foundation
import MCACore
import MCASensing
import OSLog

// MARK: - LoopExecutionError

/// Errors thrown by the autonomous execution loop during guardrail enforcement or cancellation.
public enum LoopExecutionError: LocalizedError, Sendable, Equatable {
    /// Step budget exceeded total allowable steps.
    case stepBudgetExceeded(steps: Int)

    /// Infinite loop detected via action repetition or invariant screen state.
    case infiniteLoopDetected(reason: String)

    /// Execution was cancelled by user, signal (SIGINT), or parent coordinator.
    case cancelled

    /// Escalation to System 2 planner failed or was rejected.
    case escalationFailed(reason: String)

    /// Low-level execution failure (e.g. accessibility permissions denied or hardware error).
    case executionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .stepBudgetExceeded(let steps):
            return "Autonomous loop terminated: maximum step budget exceeded (\(steps) steps executed)."
        case .infiniteLoopDetected(let reason):
            return "Autonomous loop aborted: infinite loop detected. \(reason)"
        case .cancelled:
            return "Autonomous loop execution was cancelled by user or emergency halt."
        case .escalationFailed(let reason):
            return "Autonomous loop escalation failed: \(reason)"
        case .executionFailed(let reason):
            return "Autonomous execution failed: \(reason)"
        }
    }
}

// MARK: - StepBudgetMonitor

/// Monitors and enforces the step budget for autonomous loop executions.
public struct StepBudgetMonitor: Sendable {
    /// Maximum allowable steps across the entire autonomous goal.
    public let maxSteps: Int

    /// Optional limit on steps per individual subgoal.
    public let maxSubgoalSteps: Int?

    /// Current count of total steps executed.
    public private(set) var totalStepsExecuted: Int = 0

    /// Current count of steps executed within the active subgoal.
    public private(set) var currentSubgoalSteps: Int = 0

    public init(maxSteps: Int = 30, maxSubgoalSteps: Int? = 10) {
        self.maxSteps = maxSteps
        self.maxSubgoalSteps = maxSubgoalSteps
    }

    /// Remaining steps before total budget exhaustion.
    public var remainingSteps: Int {
        max(0, maxSteps - totalStepsExecuted)
    }

    /// Advances the step count by 1. Throws `LoopExecutionError.stepBudgetExceeded`
    /// if the step budget limit is reached or exceeded.
    public mutating func increment() throws {
        if totalStepsExecuted >= maxSteps {
            throw LoopExecutionError.stepBudgetExceeded(steps: totalStepsExecuted)
        }

        if let maxSub = maxSubgoalSteps, currentSubgoalSteps >= maxSub {
            throw LoopExecutionError.stepBudgetExceeded(steps: currentSubgoalSteps)
        }

        totalStepsExecuted += 1
        currentSubgoalSteps += 1
    }

    /// Resets the per-subgoal step counter when transitioning to a new subgoal.
    public mutating func resetSubgoalBudget() {
        currentSubgoalSteps = 0
    }
}

// MARK: - TwoFactorLoopDetector

/// Detects repetitive action patterns and stagnant UI state loops across a sliding window of execution history.
public struct TwoFactorLoopDetector: Sendable {
    public struct Configuration: Sendable {
        /// Base threshold for consecutive identical actions (discrete actions: click, typeText). Default: 3.
        public var identicalActionThreshold: Int

        /// Absolute upper limit of continuous identical actions permitted, even with active screen diffs (DoS defense). Default: 10.
        public var maxExplorationRepetitionCeiling: Int

        /// Dedicated threshold for `.wait` actions before flagging stagnation. Default: 6.
        public var waitActionThreshold: Int

        /// Dedicated threshold for repeatable navigation keys (e.g. Backspace, ArrowDown). Default: 8.
        public var repeatableKeyPressThreshold: Int

        /// Number of consecutive unchanged UI states required to trigger Factor 2. Default: 3.
        public var unchangedStateThreshold: Int

        /// Capacity of recent history window. Default: 10.
        public var windowCapacity: Int

        /// Coordinate distance tolerance in Quartz points for matching click/drag targets. Default: 2.0.
        public var coordinateTolerance: CGFloat

        public init(
            identicalActionThreshold: Int = 3,
            maxExplorationRepetitionCeiling: Int = 10,
            waitActionThreshold: Int = 6,
            repeatableKeyPressThreshold: Int = 8,
            unchangedStateThreshold: Int = 3,
            windowCapacity: Int = 10,
            coordinateTolerance: CGFloat = 2.0
        ) {
            self.identicalActionThreshold = max(2, identicalActionThreshold)
            self.maxExplorationRepetitionCeiling = max(self.identicalActionThreshold, maxExplorationRepetitionCeiling)
            self.waitActionThreshold = max(self.identicalActionThreshold, waitActionThreshold)
            self.repeatableKeyPressThreshold = max(self.identicalActionThreshold, repeatableKeyPressThreshold)
            self.unchangedStateThreshold = max(2, unchangedStateThreshold)
            self.windowCapacity = max(5, windowCapacity)
            self.coordinateTolerance = coordinateTolerance
        }

        /// Fully backward-compatible initializer
        public init(
            identicalActionThreshold: Int = 3,
            unchangedStateThreshold: Int = 3,
            windowCapacity: Int = 10,
            coordinateTolerance: CGFloat = 2.0
        ) {
            self.init(
                identicalActionThreshold: identicalActionThreshold,
                maxExplorationRepetitionCeiling: 10,
                waitActionThreshold: 6,
                repeatableKeyPressThreshold: 8,
                unchangedStateThreshold: unchangedStateThreshold,
                windowCapacity: windowCapacity,
                coordinateTolerance: coordinateTolerance
            )
        }
    }

    public let config: Configuration

    /// Recent action decisions stored in FIFO order.
    private var actionHistory: [ComputerActionDecision] = []

    /// Consecutive count of identical actions evaluated.
    public private(set) var consecutiveIdenticalActionCount: Int = 0

    /// Consecutive count of unchanged UI states evaluated.
    public private(set) var consecutiveUnchangedStateCount: Int = 0

    /// Resilient structural fingerprint of desktop UI state snapshots.
    /// Uses semantic layout and candidate hierarchies, isolating pixel-level animation/caret noise.
    public struct StateFingerprint: Hashable, Equatable, Sendable {
        public let windowTitle: String?
        public let appBundleId: String?
        public let focusedElementId: String?
        public let frameHash: String?
        public let candidatesHash: Int
        public let structuralHash: Int

        public init(snapshot: UIStateSnapshot) {
            self.windowTitle = snapshot.windowTitle
            self.appBundleId = snapshot.appBundleId
            self.focusedElementId = snapshot.focusedElementId
            self.frameHash = snapshot.frameHash
            self.candidatesHash = snapshot.candidatesHash

            var hasher = Hasher()
            hasher.combine(snapshot.appName)
            hasher.combine(snapshot.visibleCandidates.count)
            for c in snapshot.visibleCandidates.prefix(15) {
                hasher.combine(c.id)
                hasher.combine(c.role)
                let trimmed = c.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    hasher.combine(trimmed.prefix(24))
                }
            }
            self.structuralHash = hasher.finalize()
        }

        public static func == (lhs: StateFingerprint, rhs: StateFingerprint) -> Bool {
            lhs.windowTitle == rhs.windowTitle &&
            lhs.appBundleId == rhs.appBundleId &&
            lhs.focusedElementId == rhs.focusedElementId &&
            lhs.structuralHash == rhs.structuralHash
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(windowTitle)
            hasher.combine(appBundleId)
            hasher.combine(focusedElementId)
            hasher.combine(structuralHash)
        }
    }

    /// History of recent state fingerprints in FIFO order.
    private var recentStateSignatures: [StateFingerprint] = []

    /// Immediately preceding UIStateDiff recorded post-action.
    private var lastRecordedDiff: UIStateDiff?

    /// Flag indicating whether recordStateDiff was called for the preceding action decision.
    private var diffRecordedSinceLastAction: Bool = false

    public init(config: Configuration = Configuration()) {
        self.config = config
    }

    // MARK: - Factor 1: Action Repetition Tracking

    /// Records a newly decided action before execution and verifies Factor 1 (Identical Action Repetition).
    /// If identical actions repeat while preceding UIStateDiff proves screen progress (mutation / viewport movement),
    /// the action is treated as legitimate forward exploration (e.g. continuous scrolling).
    /// Throws `LoopExecutionError.infiniteLoopDetected` if repetition meets or exceeds threshold without progress,
    /// or if the absolute exploration ceiling is breached (preventing ambient animation loop DoS).
    public mutating func recordAction(decision: ComputerActionDecision) throws {
        // Skip completion decisions from repetition locking
        if decision.isCompleted {
            return
        }

        if let lastAction = actionHistory.last {
            if Self.areActionsEquivalent(decision, lastAction, tolerance: config.coordinateTolerance) {
                consecutiveIdenticalActionCount += 1
            } else {
                consecutiveIdenticalActionCount = 1
            }
        } else {
            consecutiveIdenticalActionCount = 1
        }

        actionHistory.append(decision)
        if actionHistory.count > config.windowCapacity {
            actionHistory.removeFirst()
        }

        let previousDiffHadProgress = diffRecordedSinceLastAction && (lastRecordedDiff?.hasSignificantChange ?? false)
        diffRecordedSinceLastAction = false

        // Determine effective threshold based on action semantics
        let effectiveThreshold: Int = {
            switch decision.action {
            case .wait:
                return config.waitActionThreshold
            case .keyPress:
                if let key = decision.keyCombination?.first?.lowercased(),
                   ["backspace", "delete", "down", "up", "left", "right", "pagedown", "pageup"].contains(key) {
                    return config.repeatableKeyPressThreshold
                }
                return config.identicalActionThreshold
            case .scroll:
                return config.identicalActionThreshold
            default:
                return config.identicalActionThreshold
            }
        }()

        // Hard exploration ceiling: abort regardless of ambient diffs to prevent infinite loops from background animations
        if consecutiveIdenticalActionCount >= config.maxExplorationRepetitionCeiling {
            let actionName = decision.action.rawValue
            let reason = "Action repetition ceiling exceeded: action '\(actionName)' repeated \(consecutiveIdenticalActionCount) times (ceiling: \(config.maxExplorationRepetitionCeiling)). Suspected ambient screen animation loop or runaway exploration."
            throw LoopExecutionError.infiniteLoopDetected(reason: reason)
        }

        if consecutiveIdenticalActionCount >= effectiveThreshold {
            // Progress-Aware Guardrail: If previous step produced verifiable screen change
            // (e.g. exploratory scrolling, pagination click, progressive typing),
            // do not flag as stuck until hard exploration ceiling is reached.
            if previousDiffHadProgress {
                return
            }

            let targetDesc: String = {
                if let id = decision.targetElementId { return "element '\(id)'" }
                if let pt = decision.coordinates {
                    let xStr = pt.x.isFinite ? "\(Int(pt.x))" : "\(pt.x)"
                    let yStr = pt.y.isFinite ? "\(Int(pt.y))" : "\(pt.y)"
                    return "coords (\(xStr), \(yStr))"
                }
                if let txt = decision.textInput { return "text '\(txt)'" }
                if let keys = decision.keyCombination { return "keys \(keys)" }
                return "same target"
            }()
            let reason = "Identical action repetition: action '\(decision.action.rawValue)' repeated \(consecutiveIdenticalActionCount) consecutive times on \(targetDesc)."
            throw LoopExecutionError.infiniteLoopDetected(reason: reason)
        }
    }

    /// Transactional rollback helper: rolls back the last recorded action if synthetic dispatch fails.
    public mutating func rollbackLastAction() {
        guard !actionHistory.isEmpty else { return }
        actionHistory.removeLast()
        consecutiveIdenticalActionCount = max(0, consecutiveIdenticalActionCount - 1)
    }

    // MARK: - Factor 2: Unchanged UI State & Oscillation Tracking

    /// Records the post-action `UIStateDiff` and verifies Factor 2 (Unchanged UI State Repetition & State Oscillation).
    /// Throws `LoopExecutionError.infiniteLoopDetected` if the screen remained unchanged across >= threshold steps,
    /// if identical actions continued without screen changes, or if state oscillation was detected.
    public mutating func recordStateDiff(diff: UIStateDiff) throws {
        lastRecordedDiff = diff
        diffRecordedSinceLastAction = true

        if diff.isStateUnchanged {
            consecutiveUnchangedStateCount += 1
        } else {
            consecutiveUnchangedStateCount = 0
        }

        // Stagnation Check: if an identical action repetition (e.g. scroll) was performed at or above threshold,
        // but this diff yielded NO screen change (e.g. hit bottom/top of page or target became inert),
        // mark it as stagnant immediately.
        if diff.isStateUnchanged && consecutiveIdenticalActionCount >= config.identicalActionThreshold {
            let actionName = actionHistory.last?.action.rawValue ?? "action"
            let reason = "Action stagnation detected: repetitive action '\(actionName)' yielded no screen change (hit page boundary or target inert) across \(consecutiveIdenticalActionCount) steps."
            throw LoopExecutionError.infiniteLoopDetected(reason: reason)
        }

        if consecutiveUnchangedStateCount >= config.unchangedStateThreshold {
            let reason = "Unchanged UI state repetition: desktop UI state remained completely unchanged across \(consecutiveUnchangedStateCount) consecutive action steps."
            throw LoopExecutionError.infiniteLoopDetected(reason: reason)
        }

        // State Oscillation Tracking (同一状態の往復)
        if let after = diff.after {
            let sig = StateFingerprint(snapshot: after)
            if recentStateSignatures.last != sig {
                recentStateSignatures.append(sig)
                if recentStateSignatures.count > config.windowCapacity {
                    recentStateSignatures.removeFirst()
                }

                let count = recentStateSignatures.count
                // 2-Cycle Oscillation: A -> B -> A -> B
                if count >= 4 {
                    let sCurrent = recentStateSignatures[count - 1]
                    let sPrev1 = recentStateSignatures[count - 2]
                    let sPrev2 = recentStateSignatures[count - 3]
                    let sPrev3 = recentStateSignatures[count - 4]
                    if sCurrent == sPrev2 && sPrev1 == sPrev3 && sCurrent != sPrev1 {
                        let reason = "UI state oscillation: desktop state repeatedly oscillated back and forth between identical structural screens."
                        throw LoopExecutionError.infiniteLoopDetected(reason: reason)
                    }
                }

                // Cyclic State Revisit: same state revisited >= unchangedStateThreshold times
                let occurrences = recentStateSignatures.filter { $0 == sig }.count
                if occurrences >= config.unchangedStateThreshold && occurrences >= 3 {
                    let reason = "UI state cycle detected: identical desktop state visited \(occurrences) times in recent history."
                    throw LoopExecutionError.infiniteLoopDetected(reason: reason)
                }
            }
        }
    }

    /// Resets all counters and history (e.g. on subgoal advancement or replanning).
    public mutating func reset() {
        actionHistory.removeAll(keepingCapacity: true)
        consecutiveIdenticalActionCount = 0
        consecutiveUnchangedStateCount = 0
        recentStateSignatures.removeAll(keepingCapacity: true)
        lastRecordedDiff = nil
        diffRecordedSinceLastAction = false
    }

    // MARK: - Action Equivalence Logic

    /// Compares two decisions for behavioral equivalence.
    public static func areActionsEquivalent(
        _ a: ComputerActionDecision,
        _ b: ComputerActionDecision,
        tolerance: CGFloat = 2.0
    ) -> Bool {
        guard a.action == b.action else { return false }

        let targetsMatch: Bool = {
            if let idA = a.targetElementId, let idB = b.targetElementId {
                return idA == idB
            }
            if let ptA = a.coordinates ?? a.targetCenter, let ptB = b.coordinates ?? b.targetCenter {
                guard ptA.x.isFinite && ptA.y.isFinite && ptB.x.isFinite && ptB.y.isFinite else {
                    return false
                }
                let dx = abs(ptA.x - ptB.x)
                let dy = abs(ptA.y - ptB.y)
                return dx <= tolerance && dy <= tolerance
            }
            return a.targetElementId == nil && b.targetElementId == nil &&
                   (a.coordinates ?? a.targetCenter) == nil && (b.coordinates ?? b.targetCenter) == nil
        }()

        switch a.action {
        case .click, .doubleClick, .rightClick:
            return targetsMatch
        case .typeText:
            return targetsMatch && a.textInput == b.textInput
        case .keyPress:
            return a.keyCombination == b.keyCombination
        case .scroll:
            return targetsMatch && a.scrollDelta == b.scrollDelta
        case .wait, .none:
            return true
        }
    }
}

// MARK: - CancellationToken

/// Thread-safe cancellation token conforming to Sendable for cooperative task cancellation.
/// Protects state using an internal lock to allow synchronous, low-latency checking without async/await.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled: Bool = false
    private var callbacks: [@Sendable () -> Void] = []

    public init() {}

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    /// Requests cooperative cancellation, immediately executing any registered onCancel callbacks.
    public func cancel() {
        lock.lock()
        if _isCancelled {
            lock.unlock()
            return
        }
        _isCancelled = true
        let handlers = callbacks
        callbacks.removeAll()
        lock.unlock()

        for handler in handlers {
            handler()
        }
    }

    /// Checks if cancellation was requested on either this token or the ambient Swift Task.
    /// Throws `LoopExecutionError.cancelled` immediately if cancelled.
    public func throwIfCancelled() throws {
        if isCancelled || Task.isCancelled {
            throw LoopExecutionError.cancelled
        }
    }

    /// Registers a cleanup or emergency halt callback to be invoked immediately upon cancellation.
    /// If the token is already cancelled, the callback is invoked synchronously.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if _isCancelled {
            lock.unlock()
            handler()
            return
        }
        callbacks.append(handler)
        lock.unlock()
    }

    /// Suspends execution for the specified duration, returning early or throwing immediately if cancelled.
    public func sleep(milliseconds: Int) async throws {
        try throwIfCancelled()
        guard milliseconds > 0 else { return }
        let interval = 25 // 25ms polling slices for responsive abort
        var elapsed = 0
        while elapsed < milliseconds {
            let slice = min(interval, milliseconds - elapsed)
            do {
                try await Task.sleep(for: .milliseconds(slice))
            } catch is CancellationError {
                throw LoopExecutionError.cancelled
            }
            try throwIfCancelled()
            elapsed += slice
        }
    }

    /// Shared non-cancelled token instance for unconstrained runs.
    public static var none: CancellationToken {
        CancellationToken()
    }
}

// MARK: - EmergencyHaltManager

/// Coordinates emergency halt handling and synthetic event release.
public enum EmergencyHaltManager {
    private static let log = Logger(subsystem: "com.buddypia.mca", category: "EmergencyHaltManager")

    /// Binds an EventSynthesizing instance to a CancellationToken so any cancellation immediately triggers
    /// a clean hardware release of stuck mouse buttons and modifier keys.
    public static func bindEmergencyRelease(
        token: CancellationToken,
        synthesizer: any EventSynthesizing
    ) {
        token.onCancel {
            log.warning("Emergency halt / cancellation received: releasing all synthetic mouse & keyboard events.")
            synthesizer.releaseAllHeldEvents()
        }
    }
}
