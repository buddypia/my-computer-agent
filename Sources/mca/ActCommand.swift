import ApplicationServices
import CoreGraphics
import Foundation
import MCACore
import MCAMemory
import MCAReasoning
import MCASensing
import OSLog

// MARK: - ActParseError

public struct ActParseError: Error, CustomStringConvertible, Equatable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { self.message = value }
    public init(stringInterpolation: DefaultStringInterpolation) {
        self.message = String(stringInterpolation: stringInterpolation)
    }
    public var description: String { message }

    public static func == (lhs: ActParseError, rhs: String) -> Bool {
        lhs.message == rhs
    }
    public static func == (lhs: String, rhs: ActParseError) -> Bool {
        lhs == rhs.message
    }
}

// MARK: - ActOptions

public struct ActOptions: Sendable, Equatable {
    public var goal: String
    public var isAutonomous: Bool
    public var maxSteps: Int
    public var confidence: Float
    public var isDryRun: Bool
    public var isDebug: Bool

    public init(
        goal: String = "",
        isAutonomous: Bool = false,
        maxSteps: Int = 20,
        confidence: Float = 0.80,
        isDryRun: Bool = false,
        isDebug: Bool = (ProcessInfo.processInfo.environment["MCA_DEBUG"] == "1" || ProcessInfo.processInfo.environment["MCA_AUTONOMOUS_DEBUG"] == "1")
    ) {
        self.goal = goal
        self.isAutonomous = isAutonomous
        self.maxSteps = maxSteps
        self.confidence = confidence
        self.isDryRun = isDryRun
        self.isDebug = isDebug
    }

    public static func parse(_ arguments: [String]) -> Result<ActOptions, ActParseError> {
        var goal: String?
        var isAutonomous = false
        var maxSteps = 20
        var confidence: Float = 0.80
        var isDryRun = false
        var isDebug = (ProcessInfo.processInfo.environment["MCA_DEBUG"] == "1" || ProcessInfo.processInfo.environment["MCA_AUTONOMOUS_DEBUG"] == "1")
        var positional: [String] = []

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--goal", "-g":
                i += 1
                guard i < arguments.count else { return .failure("Missing value for \(arg)") }
                goal = arguments[i]
            case "--max-steps", "-m", "-s":
                i += 1
                guard i < arguments.count, let val = Int(arguments[i]), val > 0 else {
                    return .failure("Invalid value for \(arg): must be a positive integer")
                }
                maxSteps = val
            case "--confidence", "-c":
                i += 1
                guard i < arguments.count, let val = Float(arguments[i]), val >= 0.0 && val <= 1.0 else {
                    return .failure("Invalid value for \(arg): must be a float between 0.0 and 1.0")
                }
                confidence = val
            case "--autonomous", "-a":
                isAutonomous = true
            case "--dry-run", "-n":
                isDryRun = true
            case "--debug", "-d":
                isDebug = true
            case "-h", "--help":
                return .failure("HELP")
            default:
                if arg.hasPrefix("-") {
                    return .failure("Unknown flag: '\(arg)'")
                }
                positional.append(arg)
            }
            i += 1
        }

        let resolvedGoal = goal ?? positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // If --goal is explicitly passed, default to autonomous execution
        if goal != nil {
            isAutonomous = true
        }

        return .success(ActOptions(
            goal: resolvedGoal,
            isAutonomous: isAutonomous,
            maxSteps: maxSteps,
            confidence: confidence,
            isDryRun: isDryRun,
            isDebug: isDebug
        ))
    }
}

// MARK: - EmergencyHaltSignalTrap

public final class EmergencyHaltSignalTrap: @unchecked Sendable {
    private let source: DispatchSourceSignal?
    private let queue: DispatchQueue?
    private var isCancelled: Bool = false
    private let lock = NSLock()
    private let token: CancellationToken?
    private let synthesizer: (any EventSynthesizing)?
    private let onSignal: (@Sendable () -> Void)?

    public init(
        token: CancellationToken? = nil,
        synthesizer: (any EventSynthesizing)? = nil,
        onSignal: (@Sendable () -> Void)? = nil
    ) {
        self.token = token
        self.synthesizer = synthesizer
        self.onSignal = onSignal

        signal(SIGINT, SIG_IGN)
        let q = DispatchQueue(label: "com.buddypia.mca.emergency-halt", qos: .userInteractive)
        self.queue = q
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
        self.source = s

        s.setEventHandler { [weak self] in
            self?.fireHalt()
        }
        s.resume()
    }

    public convenience init(onSignal: @escaping @Sendable () -> Void) {
        self.init(token: nil, synthesizer: nil, onSignal: onSignal)
    }

    private func fireHalt() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()

        // Restore default handler so subsequent SIGINT forces termination
        signal(SIGINT, SIG_DFL)
        synthesizer?.releaseAllHeldEvents()
        token?.cancel()
        onSignal?()
        source?.cancel()
    }

    public func simulateSignal() {
        fireHalt()
    }

    public func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        isCancelled = true
        source?.cancel()
        signal(SIGINT, SIG_DFL)
    }

    deinit {
        tearDown()
    }
}

// MARK: - CLIAutonomousLoopReporter

public final class CLIAutonomousLoopReporter: AutonomousLoopDelegate, @unchecked Sendable {
    private let isDryRun: Bool
    private let startTime: Date
    private let lock = NSLock()
    public private(set) var totalSteps: Int = 0
    public private(set) var subgoalsCompleted: Int = 0

    public init(isDryRun: Bool = false) {
        self.isDryRun = isDryRun
        self.startTime = Date()
    }

    public func loopDidStart(goal: String, initialPlan: SubgoalPlan) async {
        print("=== MyComputerAgent Autonomous Action\(isDryRun ? " [DRY-RUN]" : "") ===")
        print("🎯 Goal: \"\(goal)\"")
        if !initialPlan.subgoals.isEmpty {
            print("📋 Decomposed into \(initialPlan.subgoals.count) subgoal\(initialPlan.subgoals.count == 1 ? "" : "s"):")
            for (idx, sg) in initialPlan.subgoals.enumerated() {
                let outcome = sg.expectedOutcome.isEmpty ? "" : " -> Expect: \(sg.expectedOutcome)"
                print("   \(idx + 1). [\(sg.id)] \(sg.description) (max: \(sg.maxSteps) steps)\(outcome)")
            }
        }
        print(String(repeating: "-", count: 60))
    }

    public func loopDidBeginSubgoal(subgoal: Subgoal, index: Int, total: Int) async {
        print("▶️  [Subgoal \(index + 1)/\(total)] \(subgoal.description)")
    }

    private func recordStep(_ step: Int) {
        lock.lock()
        totalSteps = step
        lock.unlock()
    }

    private func recordSubgoalVerified() {
        lock.lock()
        subgoalsCompleted += 1
        lock.unlock()
    }

    public func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async {
        recordStep(step)

        let tag = isDryRun ? "[DRY-RUN Step \(step)]" : "[Step \(step)]"
        let confPercent = Int(action.confidence * 100)
        let targetDesc = action.targetElementId ?? "none"
        let coordsDesc = (action.targetCenter ?? action.coordinates).map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "no coords"
        print("   \(tag) Selected: \(targetDesc) (\(confPercent)% conf) at \(coordsDesc)")

        var actionDetails = "Action: \(action.action.rawValue)"
        if let txt = action.textInput { actionDetails += " \"\(txt)\"" }
        if let keys = action.keyCombination { actionDetails += " keys=\(keys)" }
        if let delta = action.scrollDelta { actionDetails += " delta=(\(Int(delta.dx)), \(Int(delta.dy)))" }

        var diffDetails: [String] = []
        if diff.focusChanged { diffDetails.append("focusChanged=true") }
        if diff.titleChanged { diffDetails.append("titleChanged=true") }
        if diff.layoutMutated { diffDetails.append("layoutMutated=true") }
        let diffStr = diffDetails.isEmpty ? "screen state unchanged" : diffDetails.joined(separator: ", ")

        print("            \(actionDetails) -> \(diffStr)")
    }

    public func loopDidVerifyOutcome(subgoal: Subgoal, result: StateVerificationResult) async {
        if result.isVerified {
            recordSubgoalVerified()
            print("   ✓ Verified subgoal outcome: \(subgoal.expectedOutcome)")
        } else {
            print("   · Subgoal outcome not yet satisfied: \(result.rationale)")
        }
    }

    public func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) async throws -> EscalationResolution? {
        print("   ⚠️  Escalating to System 2: \(reason.description)")
        return nil
    }

    public func loopDidComplete(summary: ExecutionSummary) async {
        print(String(repeating: "-", count: 60))
        printExecutionSummary(
            goal: summary.goal,
            status: isDryRun ? "DRY-RUN SUCCESS" : "SUCCESS",
            message: summary.terminationReason,
            steps: summary.totalSteps,
            completedSubgoals: summary.subgoalsCompleted,
            totalSubgoals: summary.totalSubgoals,
            duration: summary.durationSeconds
        )
    }

    public func loopDidFail(error: LoopExecutionError) async {
        print(String(repeating: "-", count: 60))
        let status: String
        let message: String
        switch error {
        case .cancelled:
            status = "ABORTED"
            message = "Cancelled by user or emergency halt (SIGINT)."
        case .stepBudgetExceeded(let steps):
            status = "FAILED"
            message = "Step budget exceeded (\(steps) steps)."
        case .infiniteLoopDetected(let reason):
            status = "FAILED"
            message = "Infinite loop detected: \(reason)"
        case .escalationFailed(let reason):
            status = "FAILED"
            message = "Escalation failed: \(reason)"
        case .executionFailed(let reason):
            status = "FAILED"
            message = "Execution failed: \(reason)"
        }

        let duration = Date().timeIntervalSince(startTime)
        printExecutionSummary(
            goal: "",
            status: status,
            message: message,
            steps: totalSteps,
            completedSubgoals: subgoalsCompleted,
            totalSubgoals: 0,
            duration: duration
        )
    }

    private func printExecutionSummary(
        goal: String,
        status: String,
        message: String,
        steps: Int,
        completedSubgoals: Int,
        totalSubgoals: Int,
        duration: Double
    ) {
        print("============================================================")
        print("Execution Summary:")
        if !goal.isEmpty {
            print("  Goal:               \(goal)")
        }
        print("  Status:             \(status) (\(message))")
        print("  Total Steps:        \(steps)")
        if totalSubgoals > 0 {
            print("  Subgoals Completed: \(completedSubgoals) / \(totalSubgoals)")
        } else {
            print("  Subgoals Completed: \(completedSubgoals)")
        }
        print("  Duration:           \(String(format: "%.2f", duration))s")
        print("============================================================")
    }
}

// MARK: - ActCommand

public enum ActCommand {
    public static let usage = """
        Usage: mca act [options] [<goal>]

        Execute GUI actions using TypeSafe Jev Decision Engine and 2-Tier Autonomous Loop.

        Options:
          --goal, -g <string>       Natural language objective for autonomous execution
          --autonomous, -a          Enable 2-Tier Autonomous Execution Loop (System 2 + System 1)
          --max-steps, -s <int>     Maximum steps before termination (default: 20)
          --confidence, -c <float>  Minimum confidence threshold (0.0 - 1.0, default: 0.80)
          --dry-run, -n             Preview planning and decisions without synthesizing CGEvents
          --help, -h                Show this help message

        Examples:
          mca act --goal "Open Safari and search for Tokyo weather" --autonomous
          mca act --goal "Click Sign In button" --dry-run
          mca act --autonomous --max-steps 15 "Fill registration form"
          mca act "click Search button" (single-step mode)
        """

    public static func run(_ arguments: [String]) async {
        let code = await execute(arguments)
        exit(code)
    }

    public static func execute(_ arguments: [String]) async -> Int32 {
        let optionsResult = ActOptions.parse(arguments)
        switch optionsResult {
        case .failure(let err):
            if err == "HELP" {
                print(usage)
                return 0
            } else {
                FileHandle.standardError.write(Data("Error: \(err)\n\n".utf8))
                print(usage)
                return 2
            }
        case .success(let options):
            guard !options.goal.isEmpty else {
                FileHandle.standardError.write(Data("Error: Goal cannot be empty.\n\n".utf8))
                print(usage)
                return 2
            }

            if !options.isDryRun && !AXIsProcessTrusted() {
                print("Error: Accessibility permission is not granted.")
                print("Enable Accessibility for this terminal or MyComputerAgent in:")
                print("System Settings ▸ Privacy & Security ▸ Accessibility")
                return 1
            }

            if options.isAutonomous {
                return await runAutonomous(options)
            } else {
                return await runSingleStep(options)
            }
        }
    }

    private static func runAutonomous(_ options: ActOptions) async -> Int32 {
        let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
        let credentials = CredentialStore()
        let router = ModelRouter(policy: configuration.routing, credentials: credentials)
        let modelExecutor: (any LanguageModelExecuting)? = {
            if let ref = router.usableChain(for: .answer).first {
                return try? router.executor(for: ref)
            }
            return nil
        }()

        let planner = DefaultSubgoalPlanner(modelExecutor: modelExecutor)
        let decisionEngine = TypeSafeDecisionEngine.live(confidenceThreshold: options.confidence)
        let synthesizer: any EventSynthesizing = options.isDryRun ? DryRunEventSynthesizer() : EventSynthesizer()
        let inspector = InspectUIElementsTool.makeDefaultInspector(maxCandidates: SystemOneBackend.loopCandidateLimit)
        let reporter = CLIAutonomousLoopReporter(isDryRun: options.isDryRun)

        let config = AutonomousLoopConfig(
            maxTotalSteps: options.maxSteps,
            defaultSubgoalMaxSteps: min(options.maxSteps, 10),
            confidenceThreshold: options.confidence,
            settlingDelayMs: options.isDryRun ? 0 : 100,
            identicalActionThreshold: 3,
            unchangedStateThreshold: 3,
            isDebugMode: options.isDebug
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config,
            delegate: reporter,
            // Starting a goal does not approve text the loop derives from the screen.
            keystrokeApprover: options.isDryRun ? AutoApproveToolApprover() : TerminalToolApprover()
        )

        let cancellationToken = CancellationToken()
        let signalTrap = EmergencyHaltSignalTrap(token: cancellationToken, synthesizer: synthesizer) {
            FileHandle.standardError.write(Data("\n⚠️  [Emergency Halt] Interrupted by SIGINT (Ctrl+C). Aborting autonomous loop...\n".utf8))
        }
        defer { signalTrap.tearDown() }

        do {
            _ = try await coordinator.execute(
                goal: options.goal,
                cancellationToken: cancellationToken
            )
            return 0
        } catch let loopErr as LoopExecutionError {
            if loopErr == .cancelled {
                return 130
            } else {
                return 1
            }
        } catch {
            return 1
        }
    }

    private static func runSingleStep(_ options: ActOptions) async -> Int32 {
        let inspector = InspectUIElementsTool.makeDefaultInspector(maxCandidates: SystemOneBackend.loopCandidateLimit)
        let candidates = await inspector.inspectFocusedWindowAsync()
        print("Inspected frontmost application: found \(candidates.count) actionable UI elements.")

        let engine = TypeSafeDecisionEngine.live(confidenceThreshold: options.confidence)
        do {
            print("Evaluating goal with TypeSafe Jev Decision Engine...")
            let decision = try await engine.decideNextAction(goal: options.goal, candidates: candidates)
            print("Decision: action=\(decision.action.rawValue), target=\(decision.targetElementId ?? "none"), confidence=\(decision.confidence), center=\(String(describing: decision.targetCenter))")

            if options.isDryRun {
                print("Action executed successfully (dry-run: no CGEvents synthesized).")
                return 0
            }

            guard let targetCenter = decision.targetCenter, decision.action != .none else {
                print("No action executed (action is none or target center not found).")
                return 0
            }

            // Starting a goal does not approve text the engine derived from the screen.
            let request: ToolApprovalRequest? = {
                let app = KeystrokeApproval.frontmostAppName()
                switch decision.action {
                case .typeText:
                    return decision.textInput.map {
                        KeystrokeApproval.request(tool: "act", title: "Type text", keystrokes: $0, app: app)
                    }
                case .keyPress:
                    let keys = decision.keyCombination ?? []
                    guard keys.contains(where: KeystrokeApproval.needsApproval(key:)) else { return nil }
                    return KeystrokeApproval.request(
                        tool: "act", title: "Press keys", keystrokes: "Keys: \(keys.joined(separator: ", "))", app: app)
                default:
                    return nil
                }
            }()
            if let request, let refusal = await TerminalToolApprover().gate(request) {
                print(refusal)
                return 1
            }
            let synth = EventSynthesizer()
            switch decision.action {
            case .click:
                print("Executing click at \(targetCenter)...")
                try synth.click(at: targetCenter)
            case .doubleClick:
                print("Executing double-click at \(targetCenter)...")
                try synth.click(at: targetCenter, clickCount: 2)
            case .typeText:
                if let text = decision.textInput {
                    print("Executing typing: '\(text)'...")
                    try synth.typeText(text)
                }
            case .scroll:
                let delta = decision.scrollDelta ?? CGVector(dx: 0, dy: -5)
                print("Executing scroll delta=(\(delta.dx), \(delta.dy))...")
                try synth.scroll(deltaX: Int32(delta.dx), deltaY: Int32(delta.dy), at: targetCenter)
            case .keyPress:
                if let keys = decision.keyCombination {
                    for key in keys {
                        print("Executing keyPress '\(key)'...")
                        try synth.pressKey(key)
                    }
                }
            default:
                break
            }
            print("Action executed successfully.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Failed to execute action: \(error)\n".utf8))
            return 1
        }
    }
}
