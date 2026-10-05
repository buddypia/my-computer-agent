import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
@testable import mca
import Testing

@Suite("ActCommand Tests: CLI Parsing, Dry-Run & Signal Handling")
struct ActCommandTests {

    // MARK: - 1. Flag Parsing Tests

    @Test("ActOptions parses default single-step command from positional args")
    func testDefaultPositionalActParsing() {
        let result = ActOptions.parse(["click", "Submit", "Button"])
        switch result {
        case .success(let opts):
            #expect(opts.goal == "click Submit Button")
            #expect(!opts.isAutonomous)
            #expect(opts.maxSteps == 20)
            #expect(abs(opts.confidence - 0.80) < 0.001)
            #expect(!opts.isDryRun)
        case .failure(let err):
            Issue.record("Expected parse success, got error: \(err)")
        }
    }

    @Test("ActOptions parses --goal flag and automatically enables autonomous mode")
    func testExplicitGoalLongFlag() {
        let result = ActOptions.parse(["--goal", "Search Tokyo weather"])
        switch result {
        case .success(let opts):
            #expect(opts.goal == "Search Tokyo weather")
            #expect(opts.isAutonomous)
            #expect(opts.maxSteps == 20)
            #expect(abs(opts.confidence - 0.80) < 0.001)
            #expect(!opts.isDryRun)
        case .failure(let err):
            Issue.record("Expected parse success, got error: \(err)")
        }
    }

    @Test("ActOptions parses short -g flag")
    func testShortGoalFlag() {
        let result = ActOptions.parse(["-g", "Open Settings"])
        switch result {
        case .success(let opts):
            #expect(opts.goal == "Open Settings")
            #expect(opts.isAutonomous)
            #expect(opts.maxSteps == 20)
        case .failure(let err):
            Issue.record("Expected parse success, got error: \(err)")
        }
    }

    @Test("ActOptions parses custom max-steps via --max-steps, -m, and -s")
    func testCustomMaxStepsFlags() {
        let resLong = ActOptions.parse(["--goal", "Task", "--max-steps", "15"])
        if case .success(let opts) = resLong {
            #expect(opts.maxSteps == 15)
        } else {
            Issue.record("Failed parsing --max-steps")
        }

        let resM = ActOptions.parse(["--goal", "Task", "-m", "5"])
        if case .success(let opts) = resM {
            #expect(opts.maxSteps == 5)
        } else {
            Issue.record("Failed parsing -m")
        }

        let resS = ActOptions.parse(["--goal", "Task", "-s", "7"])
        if case .success(let opts) = resS {
            #expect(opts.maxSteps == 7)
        } else {
            Issue.record("Failed parsing -s")
        }
    }

    @Test("ActOptions parses custom confidence via --confidence and -c")
    func testCustomConfidenceFlags() {
        let resLong = ActOptions.parse(["--goal", "Task", "--confidence", "0.95"])
        if case .success(let opts) = resLong {
            #expect(abs(opts.confidence - 0.95) < 0.001)
        } else {
            Issue.record("Failed parsing --confidence")
        }

        let resC = ActOptions.parse(["--goal", "Task", "-c", "0.70"])
        if case .success(let opts) = resC {
            #expect(abs(opts.confidence - 0.70) < 0.001)
        } else {
            Issue.record("Failed parsing -c")
        }
    }

    @Test("ActOptions parses autonomous flag via --autonomous and -a")
    func testAutonomousFlags() {
        let resLong = ActOptions.parse(["click", "Next", "--autonomous"])
        if case .success(let opts) = resLong {
            #expect(opts.goal == "click Next")
            #expect(opts.isAutonomous)
        } else {
            Issue.record("Failed parsing --autonomous")
        }

        let resA = ActOptions.parse(["click", "Next", "-a"])
        if case .success(let opts) = resA {
            #expect(opts.goal == "click Next")
            #expect(opts.isAutonomous)
        } else {
            Issue.record("Failed parsing -a")
        }
    }

    @Test("ActOptions parses dry-run flag via --dry-run and -n")
    func testDryRunFlags() {
        let resLong = ActOptions.parse(["--goal", "Task", "--dry-run"])
        if case .success(let opts) = resLong {
            #expect(opts.isDryRun)
        } else {
            Issue.record("Failed parsing --dry-run")
        }

        let resN = ActOptions.parse(["--goal", "Task", "-n"])
        if case .success(let opts) = resN {
            #expect(opts.isDryRun)
        } else {
            Issue.record("Failed parsing -n")
        }
    }

    @Test("ActOptions parses combined short and long flags correctly")
    func testCombinedFlagsParsing() {
        let result = ActOptions.parse([
            "-g", "Fill Registration Form",
            "-m", "12",
            "-c", "0.92",
            "-a",
            "-n"
        ])
        switch result {
        case .success(let opts):
            #expect(opts.goal == "Fill Registration Form")
            #expect(opts.isAutonomous)
            #expect(opts.maxSteps == 12)
            #expect(abs(opts.confidence - 0.92) < 0.001)
            #expect(opts.isDryRun)
        case .failure(let err):
            Issue.record("Expected parse success, got error: \(err)")
        }
    }

    @Test("ActOptions rejects missing and invalid values")
    func testInvalidFlagValidation() {
        #expect(ActOptions.parse(["--goal"]).isFailure)
        #expect(ActOptions.parse(["--max-steps"]).isFailure)
        #expect(ActOptions.parse(["--max-steps", "0"]).isFailure)
        #expect(ActOptions.parse(["--max-steps", "-1"]).isFailure)
        #expect(ActOptions.parse(["--max-steps", "not_a_num"]).isFailure)
        #expect(ActOptions.parse(["--confidence"]).isFailure)
        #expect(ActOptions.parse(["--confidence", "1.05"]).isFailure)
        #expect(ActOptions.parse(["--confidence", "-0.01"]).isFailure)
        #expect(ActOptions.parse(["--unknown-flag"]).isFailure)
    }

    @Test("ActOptions handles help flags")
    func testHelpFlags() {
        let resLong = ActOptions.parse(["--help"])
        if case .failure(let err) = resLong {
            #expect(err == "HELP")
        } else {
            Issue.record("Expected HELP failure for --help")
        }

        let resShort = ActOptions.parse(["-h"])
        if case .failure(let err) = resShort {
            #expect(err == "HELP")
        } else {
            Issue.record("Expected HELP failure for -h")
        }
    }

    // MARK: - 2. ActCommand Execution Exit Code Tests

    @Test("ActCommand.execute handles help flags with code 0")
    func testExecuteHelpFlags() async {
        let codeLong = await ActCommand.execute(["--help"])
        #expect(codeLong == 0)

        let codeShort = await ActCommand.execute(["-h"])
        #expect(codeShort == 0)
    }

    @Test("ActCommand.execute rejects empty goal or invalid flags with code 2")
    func testExecuteValidationErrors() async {
        let emptyCode = await ActCommand.execute([])
        #expect(emptyCode == 2)

        let unknownCode = await ActCommand.execute(["--unknown-flag"])
        #expect(unknownCode == 2)

        let invalidStepsCode = await ActCommand.execute(["--goal", "Test", "--max-steps", "0"])
        #expect(invalidStepsCode == 2)

        let invalidConfCode = await ActCommand.execute(["--goal", "Test", "--confidence", "1.5"])
        #expect(invalidConfCode == 2)
    }

    // MARK: - 3. Emergency Halt Signal Trap Tests

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
        func mutate(_ transform: (inout T) -> Void) {
            lock.lock(); defer { lock.unlock() }
            transform(&_value)
        }
    }

    @Test("EmergencyHaltSignalTrap fires halt callback, cancels token, and releases held events")
    func testEmergencyHaltSignalTrapSimulation() {
        let token = CancellationToken()
        let synthesizer = DryRunEventSynthesizer()
        let callbackFired = SafeBox(false)

        let trap = EmergencyHaltSignalTrap(token: token, synthesizer: synthesizer) {
            callbackFired.set(true)
        }

        #expect(!token.isCancelled)
        #expect(!callbackFired.value)
        #expect(synthesizer.recordedActions.isEmpty)

        // Trigger simulated signal
        trap.simulateSignal()

        #expect(token.isCancelled)
        #expect(callbackFired.value)
        #expect(synthesizer.recordedActions.contains("releaseAllHeldEvents()"))

        // Multiple triggers are idempotent
        trap.simulateSignal()
        trap.tearDown()
    }

    @Test("EmergencyHaltManager binds cancellation token to synthesizer release")
    func testEmergencyHaltManagerBinding() {
        let token = CancellationToken()
        let synthesizer = DryRunEventSynthesizer()

        EmergencyHaltManager.bindEmergencyRelease(token: token, synthesizer: synthesizer)

        #expect(!token.isCancelled)
        #expect(synthesizer.recordedActions.isEmpty)

        token.cancel()

        #expect(token.isCancelled)
        #expect(synthesizer.recordedActions.contains("releaseAllHeldEvents()"))
    }

    // MARK: - 4. DryRunEventSynthesizer Verification

    @Test("DryRunEventSynthesizer records all GUI interactions without system calls")
    func testDryRunEventSynthesizerOperations() throws {
        let actionsCallback = SafeBox<[String]>([])
        let synth = DryRunEventSynthesizer { action in
            actionsCallback.mutate { $0.append(action) }
        }

        #expect(synth.isTrusted)
        let pos = try synth.cursorPosition()
        #expect(pos == CGPoint(x: 100, y: 100))

        try synth.mouseMove(to: CGPoint(x: 200, y: 300))
        try synth.click(at: CGPoint(x: 250, y: 350), button: .left, clickCount: 1)
        try synth.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        try synth.scroll(deltaX: 0, deltaY: -10, at: nil, targetPID: nil)
        try synth.typeText("Hello World")
        try synth.pressKey("Return")
        synth.releaseAllHeldEvents()

        let recorded = synth.recordedActions
        #expect(recorded.count == 7)
        #expect(recorded[0].contains("mouseMove(to: (200, 300))"))
        #expect(recorded[1].contains("click(at: (250, 350), button: left, clickCount: 1)"))
        #expect(recorded[2].contains("drag(from: (10, 10), to: (100, 100))"))
        #expect(recorded[3].contains("scroll(deltaX: 0, deltaY: -10, at: current)"))
        #expect(recorded[4].contains("typeText(\"Hello World\")"))
        #expect(recorded[5].contains("pressKey(\"Return\")"))
        #expect(recorded[6].contains("releaseAllHeldEvents()"))

        #expect(actionsCallback.value.count == 7)

        synth.reset()
        #expect(synth.recordedActions.isEmpty)
    }

    // MARK: - 5. CLIAutonomousLoopReporter Tests

    @Test("CLIAutonomousLoopReporter tracks steps and subgoals across lifecycle")
    func testCLIAutonomousLoopReporterTracking() async {
        let reporter = CLIAutonomousLoopReporter(isDryRun: true)
        #expect(reporter.totalSteps == 0)
        #expect(reporter.subgoalsCompleted == 0)

        let sg = Subgoal(id: "sg_1", description: "Search", expectedOutcome: "Search opened", maxSteps: 5)
        let plan = SubgoalPlan(goal: "Test Goal", subgoals: [sg])

        await reporter.loopDidStart(goal: "Test Goal", initialPlan: plan)
        await reporter.loopDidBeginSubgoal(subgoal: sg, index: 0, total: 1)

        let decision = ComputerActionDecision(action: .click, confidence: 0.95, coordinates: CGPoint(x: 100, y: 100))
        let diff = UIStateDiff(titleChanged: false, focusChanged: true)
        await reporter.loopDidStep(step: 1, subgoal: sg, action: decision, diff: diff)
        #expect(reporter.totalSteps == 1)

        let verified = StateVerificationResult(status: .verified, confidence: 1.0, rationale: "Outcome met")
        await reporter.loopDidVerifyOutcome(subgoal: sg, result: verified)
        #expect(reporter.subgoalsCompleted == 1)

        let summary = ExecutionSummary(
            goal: "Test Goal",
            isSuccess: true,
            totalSteps: 1,
            subgoalsCompleted: 1,
            totalSubgoals: 1,
            durationSeconds: 0.5,
            terminationReason: "Goal completed"
        )
        await reporter.loopDidComplete(summary: summary)
        #expect(reporter.totalSteps == 1)
        #expect(reporter.subgoalsCompleted == 1)

        // Test error report paths
        await reporter.loopDidFail(error: .cancelled)
        await reporter.loopDidFail(error: .stepBudgetExceeded(steps: 20))
        await reporter.loopDidFail(error: .infiniteLoopDetected(reason: "Stuck"))
        await reporter.loopDidFail(error: .escalationFailed(reason: "No resolution"))
        await reporter.loopDidFail(error: .executionFailed(reason: "Failed"))
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
