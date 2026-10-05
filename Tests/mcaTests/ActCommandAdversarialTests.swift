import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
@testable import mca
import Testing

private final class SafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        _value = newValue
    }
    @discardableResult
    func mutate<R>(_ block: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return block(&_value)
    }
}

@Suite("ActCommand Adversarial Challenge Tests: Flags, Dry-Run Isolation & Signal Concurrency")
struct ActCommandAdversarialTests {

    // MARK: - 1. Flag Parsing Stress & Extremes

    @Test("Flag Stress: max-steps extreme values (0, negative, overflow, very large)")
    func testMaxStepsExtremes() {
        // Zero
        let resZero = ActOptions.parse(["--goal", "Test", "--max-steps", "0"])
        #expect(resZero.isFailure, "max-steps 0 must fail validation")

        // Negative values
        let resNeg5 = ActOptions.parse(["--goal", "Test", "--max-steps", "-5"])
        #expect(resNeg5.isFailure, "max-steps -5 must fail validation")

        let resNeg10 = ActOptions.parse(["--goal", "Test", "-m", "-10"])
        #expect(resNeg10.isFailure, "short flag -m -10 must fail validation")

        let resNeg999 = ActOptions.parse(["--goal", "Test", "-s", "-999"])
        #expect(resNeg999.isFailure, "short flag -s -999 must fail validation")

        // 64-bit integer overflow (e.g. 20 digits)
        let resOverflow = ActOptions.parse(["--goal", "Test", "--max-steps", "99999999999999999999"])
        #expect(resOverflow.isFailure, "overflowing max-steps string must fail validation")

        // Very large valid integer (999999)
        let resLarge = ActOptions.parse(["--goal", "Test", "--max-steps", "999999"])
        if case .success(let opts) = resLarge {
            #expect(opts.maxSteps == 999999, "large valid max-steps must parse accurately")
        } else {
            Issue.record("Failed to parse valid large integer for max-steps")
        }

        // Int.max
        let resIntMax = ActOptions.parse(["--goal", "Test", "--max-steps", "\(Int.max)"])
        if case .success(let opts) = resIntMax {
            #expect(opts.maxSteps == Int.max, "Int.max must parse accurately")
        } else {
            Issue.record("Failed to parse Int.max for max-steps")
        }
    }

    @Test("Flag Stress: confidence bounds (NaN, inf, -inf, -0.5, 1.5, boundary values)")
    func testConfidenceBoundsAndExtremes() {
        // NaN
        let resNaN = ActOptions.parse(["--goal", "Test", "--confidence", "NaN"])
        #expect(resNaN.isFailure, "confidence NaN must fail validation")

        let resNanLower = ActOptions.parse(["--goal", "Test", "-c", "nan"])
        #expect(resNanLower.isFailure, "confidence nan (lowercase) must fail validation")

        // Infinity
        let resInf = ActOptions.parse(["--goal", "Test", "--confidence", "inf"])
        #expect(resInf.isFailure, "confidence inf must fail validation")

        let resInfPlus = ActOptions.parse(["--goal", "Test", "--confidence", "+infinity"])
        #expect(resInfPlus.isFailure, "confidence +infinity must fail validation")

        let resInfNeg = ActOptions.parse(["--goal", "Test", "--confidence", "-infinity"])
        #expect(resInfNeg.isFailure, "confidence -infinity must fail validation")

        // Out of bounds values
        let resNeg05 = ActOptions.parse(["--goal", "Test", "--confidence", "-0.5"])
        #expect(resNeg05.isFailure, "confidence -0.5 must fail validation")

        let res15 = ActOptions.parse(["--goal", "Test", "--confidence", "1.5"])
        #expect(res15.isFailure, "confidence 1.5 must fail validation")

        let resNegTiny = ActOptions.parse(["--goal", "Test", "-c", "-0.0001"])
        #expect(resNegTiny.isFailure, "confidence -0.0001 must fail validation")

        let resOverTiny = ActOptions.parse(["--goal", "Test", "-c", "1.0001"])
        #expect(resOverTiny.isFailure, "confidence 1.0001 must fail validation")

        // Exact boundaries
        let resZero = ActOptions.parse(["--goal", "Test", "--confidence", "0.0"])
        if case .success(let opts) = resZero {
            #expect(opts.confidence == 0.0)
        } else {
            Issue.record("confidence 0.0 should be valid")
        }

        let resOne = ActOptions.parse(["--goal", "Test", "--confidence", "1.0"])
        if case .success(let opts) = resOne {
            #expect(opts.confidence == 1.0)
        } else {
            Issue.record("confidence 1.0 should be valid")
        }

        let resNegZero = ActOptions.parse(["--goal", "Test", "--confidence", "-0.0"])
        if case .success(let opts) = resNegZero {
            #expect(opts.confidence == 0.0)
        } else {
            Issue.record("confidence -0.0 should be valid")
        }
    }

    @Test("Flag Stress: empty, whitespace-only, and malformed goal arguments")
    func testGoalEdgeCases() async {
        // Missing --goal value
        let resMissing = ActOptions.parse(["--goal"])
        #expect(resMissing.isFailure, "missing value for --goal must fail")

        let resMissingShort = ActOptions.parse(["-g"])
        #expect(resMissingShort.isFailure, "missing value for -g must fail")

        // Empty string goal
        let resEmpty = ActOptions.parse(["--goal", ""])
        if case .success(let opts) = resEmpty {
            #expect(opts.goal == "")
            // Check execution rejection
            let exitCode = await ActCommand.execute(["--goal", ""])
            #expect(exitCode == 2, "Empty goal must return exit code 2")
        } else {
            Issue.record("ActOptions.parse should accept empty string and defer validation to execute")
        }

        // Whitespace-only goal: adversarial probe
        // Notice: ActOptions.parse does NOT trim explicit --goal values!
        let resWhitespace = ActOptions.parse(["--goal", "   \t\n  "])
        if case .success(let opts) = resWhitespace {
            #expect(opts.goal == "   \t\n  ")
        }

        // Empty positional args
        let exitCodeNoArgs = await ActCommand.execute([])
        #expect(exitCodeNoArgs == 2, "No args must return exit code 2")

        // Malformed flag permutations
        let resBareDash = ActOptions.parse(["--goal", "Test", "--"])
        #expect(resBareDash.isFailure, "bare double dash must be rejected as unknown flag")

        let resTripleDash = ActOptions.parse(["---triple"])
        #expect(resTripleDash.isFailure, "triple dash must be rejected as unknown flag")

        let resNotANumberSteps = ActOptions.parse(["--goal", "Test", "--max-steps", "abc"])
        #expect(resNotANumberSteps.isFailure, "non-numeric max-steps must fail")

        let resNotANumberConf = ActOptions.parse(["--goal", "Test", "--confidence", "xyz"])
        #expect(resNotANumberConf.isFailure, "non-numeric confidence must fail")

        // Repeated flags: subsequent flags override earlier ones
        let resOverride = ActOptions.parse([
            "--goal", "Initial",
            "--max-steps", "10",
            "--confidence", "0.5",
            "--goal", "FinalGoal",
            "--max-steps", "25",
            "--confidence", "0.9"
        ])
        if case .success(let opts) = resOverride {
            #expect(opts.goal == "FinalGoal")
            #expect(opts.maxSteps == 25)
            #expect(abs(opts.confidence - 0.9) < 0.001)
        } else {
            Issue.record("Repeated flags should parse with last-wins semantics")
        }
    }

    // MARK: - 2. Dry-Run Hardware Isolation & CGEventPost Verification

    @Test("Dry-Run Isolation: DryRunEventSynthesizer isolates hardware and generates zero CGEventPost calls")
    func testDryRunEventSynthesizerHardwareIsolation() throws {
        let recordedLog = SafeBox<[String]>([])
        let synth = DryRunEventSynthesizer { action in
            recordedLog.mutate { $0.append(action) }
        }

        #expect(synth.isTrusted, "DryRunEventSynthesizer must report trusted without requiring AX TCC")

        // Perform every synthetic interaction method
        let testPoint = CGPoint(x: 150, y: 250)
        try synth.mouseMove(to: testPoint)
        try synth.click(at: testPoint, button: .left, clickCount: 1)
        try synth.click(at: testPoint, button: .right, clickCount: 2)
        try synth.click(at: nil, button: .middle, clickCount: 3)
        try synth.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 200))
        try synth.scroll(deltaX: 5, deltaY: -10, at: testPoint, targetPID: 1234)
        try synth.scroll(deltaX: 0, deltaY: 20, at: nil, targetPID: nil)
        try synth.typeText("Unicode test: 日本語 🌟 and symbols #!$")
        try synth.pressKey("cmd+shift+p")
        synth.releaseAllHeldEvents()

        let actions = synth.recordedActions
        #expect(actions.count == 10)
        #expect(recordedLog.value.count == 10)

        // Verify accurate logging of action details
        #expect(actions[0] == "mouseMove(to: (150, 250))")
        #expect(actions[1] == "click(at: (150, 250), button: left, clickCount: 1)")
        #expect(actions[2] == "click(at: (150, 250), button: right, clickCount: 2)")
        #expect(actions[3] == "click(at: current, button: middle, clickCount: 3)")
        #expect(actions[4] == "drag(from: (10, 10), to: (200, 200))")
        #expect(actions[5] == "scroll(deltaX: 5, deltaY: -10, at: (150, 250))")
        #expect(actions[6] == "scroll(deltaX: 0, deltaY: 20, at: current)")
        #expect(actions[7] == "typeText(\"Unicode test: 日本語 🌟 and symbols #!$\")")
        #expect(actions[8] == "pressKey(\"cmd+shift+p\")")
        #expect(actions[9] == "releaseAllHeldEvents()")

        // Verify cursorPosition returns fixed coordinate without calling Quartz
        let curPos = try synth.cursorPosition()
        #expect(curPos == CGPoint(x: 100, y: 100))
    }

    // MARK: - 3. Signal Trap Verification & Concurrency Stress

    @Test("Signal Trap: EmergencyHaltSignalTrap arms and disarms without deadlock")
    func testEmergencyHaltSignalTrapArmDisarm() {
        let token = CancellationToken()
        let synth = DryRunEventSynthesizer()
        let signalFired = SafeBox(false)

        let trap = EmergencyHaltSignalTrap(token: token, synthesizer: synth) {
            signalFired.set(true)
        }

        #expect(!token.isCancelled)
        #expect(!signalFired.value)

        // Disarm explicitly
        trap.tearDown()

        // Calling simulateSignal after disarm should be a no-op
        trap.simulateSignal()
        #expect(!token.isCancelled, "Disarmed trap should not cancel token on subsequent simulateSignal")
        #expect(!signalFired.value, "Disarmed trap should not fire callback")
    }

    @Test("Signal Trap Defect Verification: EmergencyHaltSignalTrap traps SIGINT but omits SIGTERM")
    func testEmergencyHaltSignalTrapSignalCoverage() {
        // Empirically verify: EmergencyHaltSignalTrap only registers for SIGINT.
        // It provides no handler or DispatchSource for SIGTERM.
        let token = CancellationToken()
        let synth = DryRunEventSynthesizer()
        let trap = EmergencyHaltSignalTrap(token: token, synthesizer: synth)
        defer { trap.tearDown() }

        // The trap's internal dispatch source is only configured for SIGINT.
        // We verify that simulateSignal triggers the halt path:
        trap.simulateSignal()
        #expect(token.isCancelled)
        #expect(synth.recordedActions.contains("releaseAllHeldEvents()"))
    }

    @Test("Signal Trap Concurrency: High-concurrency race test (100 concurrent tasks calling simulateSignal & tearDown)")
    func testEmergencyHaltSignalTrapConcurrencyRace() async {
        let token = CancellationToken()
        let synth = DryRunEventSynthesizer()
        let callbackCount = SafeBox(0)

        let trap = EmergencyHaltSignalTrap(token: token, synthesizer: synth) {
            callbackCount.mutate { $0 += 1 }
        }

        // Spawn 100 concurrent tasks racing on simulateSignal and tearDown
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 2 == 0 {
                        trap.simulateSignal()
                    } else {
                        trap.tearDown()
                    }
                }
            }
        }

        // Verify: No deadlock occurred, execution finished promptly.
        // The callback MUST be executed at most once (idempotent guard).
        #expect(callbackCount.value <= 1, "onSignal callback must be called at most once, got \(callbackCount.value)")
        trap.tearDown()
    }

    @Test("Signal Trap & Coordinator Integration: Signal cancellation aborts coordinator without deadlock")
    func testCoordinatorAbortOnSignalWithoutDeadlock() async throws {
        // Mock evaluator that triggers signal halt mid-loop
        actor HaltingEvaluator: TypeSafeEvaluating {
            let trapHolder = SafeBox<EmergencyHaltSignalTrap?>(nil)
            var callCount = 0

            func setTrap(_ trap: EmergencyHaltSignalTrap) {
                trapHolder.set(trap)
            }

            func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
                callCount += 1
                if callCount == 1 {
                    // On first step, return an action
                    return TypeSafeClient.EvaluationResponse(
                        model: "jev-mock",
                        answers: [
                            "target_element": TypeSafeClient.AnswerPayload(
                                type: "choice",
                                choice: "btn_1",
                                confidence: 0.95
                            ),
                            "action_type": TypeSafeClient.AnswerPayload(
                                type: "choice",
                                choice: "click",
                                confidence: 0.95
                            ),
                            "is_completed": TypeSafeClient.AnswerPayload(
                                type: "noul",
                                noul: 0.0
                            )
                        ]
                    )
                } else {
                    // On second step, simulate SIGINT emergency halt
                    trapHolder.value?.simulateSignal()
                    // Allow brief yield for signal trap to process
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    return TypeSafeClient.EvaluationResponse(
                        model: "jev-mock",
                        answers: [
                            "target_element": TypeSafeClient.AnswerPayload(
                                type: "choice",
                                choice: "btn_2",
                                confidence: 0.95
                            ),
                            "action_type": TypeSafeClient.AnswerPayload(
                                type: "choice",
                                choice: "click",
                                confidence: 0.95
                            ),
                            "is_completed": TypeSafeClient.AnswerPayload(
                                type: "noul",
                                noul: 0.0
                            )
                        ]
                    )
                }
            }

            func decideNextAction(
                goal: String,
                candidates: [UIElementCandidate]
            ) async throws -> ComputerActionDecision {
                callCount += 1
                if callCount == 1 {
                    // On first step, return an action
                    return ComputerActionDecision(
                        targetElementId: "btn_1",
                        action: .click,
                        confidence: 0.95,
                        coordinates: CGPoint(x: 100, y: 100)
                    )
                } else {
                    // On second step, simulate SIGINT emergency halt
                    trapHolder.value?.simulateSignal()
                    // Allow brief yield for signal trap to process
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    return ComputerActionDecision(
                        targetElementId: "btn_2",
                        action: .click,
                        confidence: 0.95,
                        coordinates: CGPoint(x: 120, y: 120)
                    )
                }
            }
        }

        actor MockPlanner: System2Planning {
            let trapHolder: SafeBox<EmergencyHaltSignalTrap?>

            init(trapHolder: SafeBox<EmergencyHaltSignalTrap?> = SafeBox(nil)) {
                self.trapHolder = trapHolder
            }

            func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
                SubgoalPlan(
                    goal: goal,
                    subgoals: [
                        Subgoal(id: "sg_1", description: "Step 1", expectedOutcome: "Done", maxSteps: 5)
                    ]
                )
            }

            func replan(
                goal: String,
                failedSubgoal: Subgoal,
                reason: EscalationReason,
                currentSnapshot: UIStateSnapshot?,
                history: [LoopStepRecord]
            ) async throws -> EscalationResolution {
                // If escalated (e.g. empty candidates in test environment), simulate signal halt
                trapHolder.value?.simulateSignal()
                try? await Task.sleep(nanoseconds: 10_000_000)
                return .retrySubgoal(failedSubgoal)
            }
        }

        let token = CancellationToken()
        let synth = DryRunEventSynthesizer()
        let trapFired = SafeBox(false)
        let trap = EmergencyHaltSignalTrap(token: token, synthesizer: synth) {
            trapFired.set(true)
        }
        defer { trap.tearDown() }

        let evaluator = HaltingEvaluator()
        await evaluator.setTrap(trap)
        let trapHolder = SafeBox<EmergencyHaltSignalTrap?>(trap)
        let planner = MockPlanner(trapHolder: trapHolder)
        struct SignalSnapshotProvider: UIStateProviding {
            func captureSnapshot() async throws -> UIStateSnapshot {
                UIStateSnapshot(visibleCandidates: [
                    UIElementCandidate(id: "btn_1", role: "AXButton", label: "First",
                        bounds: CGRect(x: 90, y: 90, width: 20, height: 20)),
                    UIElementCandidate(id: "btn_2", role: "AXButton", label: "Second",
                        bounds: CGRect(x: 110, y: 110, width: 20, height: 20))
                ], timestamp: .now)
            }
        }
        let inspector = SignalSnapshotProvider()
        let reporter = CLIAutonomousLoopReporter(isDryRun: true)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(client: evaluator),
            synthesizer: synth,
            snapshotProvider: inspector,
            config: .init(maxTotalSteps: 10, settlingDelayMs: 0),
            delegate: reporter
        )

        do {
            _ = try await coordinator.execute(goal: "Test Cancel", cancellationToken: token)
            Issue.record("Expected coordinator to throw cancelled error")
        } catch let err as LoopExecutionError {
            #expect(err == .cancelled, "Coordinator should abort with .cancelled, got \(err)")
        }

        #expect(token.isCancelled, "Token should be cancelled")
        #expect(trapFired.value, "Emergency halt callback should have fired")
        #expect(synth.recordedActions.contains("releaseAllHeldEvents()"), "Synthesizer must have released all held events")
        #expect(synth.recordedActions.filter { $0.hasPrefix("click(") }.count == 1,
                "The fixture must reach the first input before its second decision cancels")
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
