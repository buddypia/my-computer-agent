import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

// MARK: - Zero-Network Mock Harness

public actor MockPlanningLLM: System2Planning {
    public typealias PlanProvider = @Sendable (String, UIStateSnapshot?) async throws -> SubgoalPlan
    public typealias EscalationHandler = @Sendable (EscalationReason, Subgoal, SubgoalPlan, UIStateSnapshot) async throws -> EscalationResolution

    private var planProvider: PlanProvider
    private var escalationHandler: EscalationHandler

    private var _recordedPlans: [(goal: String, snapshot: UIStateSnapshot?)] = []
    private var _recordedEscalations: [(reason: EscalationReason, subgoal: Subgoal, snapshot: UIStateSnapshot)] = []

    public var recordedPlans: [(goal: String, snapshot: UIStateSnapshot?)] {
        _recordedPlans
    }

    public var recordedEscalations: [(reason: EscalationReason, subgoal: Subgoal, snapshot: UIStateSnapshot)] {
        _recordedEscalations
    }

    public init(
        planProvider: @escaping PlanProvider = { goal, _ in
            SubgoalPlan(goal: goal, subgoals: [
                Subgoal(description: "Default Subgoal", expectedOutcome: "Default Outcome", maxSteps: 5)
            ])
        },
        escalationHandler: @escaping EscalationHandler = { _, _, _, _ in
            .abort(reason: "Default Mock Escalation Abort")
        }
    ) {
        self.planProvider = planProvider
        self.escalationHandler = escalationHandler
    }

    public func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
        _recordedPlans.append((goal: goal, snapshot: initialSnapshot))
        return try await planProvider(goal, initialSnapshot)
    }

    public func replan(
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

    public func escalate(
        reason: EscalationReason,
        currentSubgoal: Subgoal,
        plan: SubgoalPlan,
        snapshot: UIStateSnapshot
    ) async throws -> EscalationResolution {
        _recordedEscalations.append((reason: reason, subgoal: currentSubgoal, snapshot: snapshot))
        return try await escalationHandler(reason, currentSubgoal, plan, snapshot)
    }

    public static func staticPlan(
        subgoals: [Subgoal],
        escalationResolution: EscalationResolution = .abort(reason: "Static abort")
    ) -> MockPlanningLLM {
        MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: subgoals)
            },
            escalationHandler: { _, _, _, _ in
                escalationResolution
            }
        )
    }

    public func reset() {
        _recordedPlans.removeAll()
        _recordedEscalations.removeAll()
    }
}

private actor ResponseQueue {
    private var items: [TypeSafeClient.EvaluationResponse]
    private var lastItem: TypeSafeClient.EvaluationResponse?

    init(items: [TypeSafeClient.EvaluationResponse]) {
        self.items = items
    }

    func next() -> TypeSafeClient.EvaluationResponse {
        if !items.isEmpty {
            let item = items.removeFirst()
            lastItem = item
            return item
        }
        if let last = lastItem {
            return last
        }
        fatalError("Exhausted queued stepSequence responses")
    }
}

extension MockTypeSafeEvaluator {
    public static func stepSequence(
        _ steps: [(target: String?, action: String?, confidence: Float, text: String?, isCompleted: Float)]
    ) -> MockTypeSafeEvaluator {
        let responses: [TypeSafeClient.EvaluationResponse] = steps.map { step in
            var answers: [String: TypeSafeClient.AnswerPayload] = [:]
            if let target = step.target {
                answers["target_element"] = TypeSafeClient.AnswerPayload(type: "choice", choice: target, confidence: step.confidence)
            }
            if let action = step.action {
                answers["action_type"] = TypeSafeClient.AnswerPayload(type: "choice", choice: action, confidence: step.confidence)
            }
            answers["is_completed"] = TypeSafeClient.AnswerPayload(type: "noul", noul: step.isCompleted)
            if let text = step.text {
                answers["text_input"] = TypeSafeClient.AnswerPayload(type: "choice", choice: text, confidence: 0.95)
            }
            return TypeSafeClient.EvaluationResponse(model: "jev-mock", answers: answers, usage: nil)
        }

        let queue = ResponseQueue(items: responses)
        return MockTypeSafeEvaluator { _ in
            await queue.next()
        }
    }
}

public final class MockEventSynthesizer: EventSynthesizing, @unchecked Sendable {
    public let isSimulation: Bool
    public enum RecordedEvent: Sendable, Equatable {
        case click(point: CGPoint?, button: MouseButton, clickCount: Int)
        case typeText(String)
        case pressKey(String)
        case scroll(deltaX: Int32, deltaY: Int32, point: CGPoint?, targetPID: pid_t?)
        case mouseMove(CGPoint)
        case drag(start: CGPoint, end: CGPoint)
        case releaseAllHeldEvents
    }

    private let lock = NSLock()
    private var _events: [RecordedEvent] = []
    public var injectedError: Error?

    public var isTrusted: Bool { true }

    public var recordedEvents: [RecordedEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    public init(injectedError: Error? = nil, isSimulation: Bool = true) {
        self.injectedError = injectedError
        self.isSimulation = isSimulation
    }

    public func cursorPosition() throws -> CGPoint {
        CGPoint(x: 100, y: 100)
    }

    public func click(at point: CGPoint?, button: MouseButton = .left, clickCount: Int = 1) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.click(point: point, button: button, clickCount: clickCount))
    }

    public func typeText(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.typeText(text))
    }

    public func pressKey(_ chordString: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.pressKey(chordString))
    }

    public func scroll(deltaX: Int32 = 0, deltaY: Int32 = 0, at point: CGPoint? = nil, targetPID: pid_t? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.scroll(deltaX: deltaX, deltaY: deltaY, point: point, targetPID: targetPID))
    }

    public func mouseMove(to point: CGPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.mouseMove(point))
    }

    public func drag(from start: CGPoint, to end: CGPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if let err = injectedError { throw err }
        _events.append(.drag(start: start, end: end))
    }

    public func releaseAllHeldEvents() {
        lock.lock(); defer { lock.unlock() }
        _events.append(.releaseAllHeldEvents)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _events.removeAll()
    }
}

public actor MockUIInspector: UIStateProviding {
    private var snapshots: [UIStateSnapshot]
    private var currentIndex: Int = 0
    private var _capturedCount: Int = 0

    public var capturedCount: Int {
        _capturedCount
    }

    public init(snapshots: [UIStateSnapshot]) {
        self.snapshots = snapshots
    }

    public init(repeating snapshot: UIStateSnapshot) {
        self.snapshots = [snapshot]
    }

    public func captureSnapshot() async throws -> UIStateSnapshot {
        _capturedCount += 1
        guard !snapshots.isEmpty else {
            return UIStateSnapshot(windowTitle: "Empty Mock", visibleCandidates: [])
        }
        let snap = snapshots[min(currentIndex, snapshots.count - 1)]
        if currentIndex < snapshots.count - 1 {
            currentIndex += 1
        }
        return snap
    }

    public func reset() {
        currentIndex = 0
        _capturedCount = 0
    }
}

// MARK: - Test Suite

@Suite("TwoTierAutonomousLoopCoordinator Tests: 2-Tier Autonomous Execution Engine")
struct TwoTierAutonomousLoopCoordinatorTests {

    private func makeCandidate(id: String, role: String, label: String, x: Double, y: Double, w: Double = 80, h: Double = 30) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            bounds: CGRect(x: x, y: y, width: w, height: h)
        )
    }

    private func makeSnapshot(title: String, candidates: [UIElementCandidate], focusedId: String? = nil) -> UIStateSnapshot {
        UIStateSnapshot(
            windowTitle: title,
            appBundleId: "com.apple.Safari",
            appName: "Safari",
            focusedElementId: focusedId,
            visibleCandidates: candidates,
            timestamp: Date(),
            frameHash: "hash_\(title.hashValue)"
        )
    }

    // MARK: - Group 1: Happy Path Execution

    @Test("A nonsimulation coordinator without approval never dispatches the model's click")
    func noninteractiveDispatchIsRefused() async throws {
        let button = makeCandidate(id: "delete", role: "AXButton", label: "Delete", x: 100, y: 100)
        let inspector = MockUIInspector(snapshots: [makeSnapshot(title: "Document", candidates: [button])])
        let synthesizer = MockEventSynthesizer(isSimulation: false)
        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "delete", action: "click", confidence: 0.99, text: nil as String?, isCompleted: 0.0)
        ])
        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(description: "Click Delete", expectedOutcome: "Document removed", maxSteps: 2)
        ])
        let coordinator = TwoTierAutonomousLoopCoordinator(planner: planner,
            decisionEngine: TypeSafeDecisionEngine(client: evaluator), synthesizer: synthesizer,
            inspector: inspector, config: .testing)

        do {
            _ = try await coordinator.execute(goal: "Delete document")
            Issue.record("The noninteractive click was allowed")
        } catch {
            #expect(error.localizedDescription.contains("approval_required"))
        }
        #expect(!synthesizer.recordedEvents.contains { event in
            if case .releaseAllHeldEvents = event { return false }
            return true
        })
    }

    @Test("Happy Path: System 2 decomposes into 2 subgoals -> System 1 executes micro-actions -> post-diff verifies outcome -> loop completes")
    func testHappyPathTwoSubgoalsExecution() async throws {
        let subgoal1 = Subgoal(
            id: "sg_1",
            description: "Type 'Agentic User' into name field",
            expectedOutcome: "Full Name updated with Agentic User",
            maxSteps: 5
        )
        let subgoal2 = Subgoal(
            id: "sg_2",
            description: "Click Submit button to finalize",
            expectedOutcome: "element_added_dialog",
            maxSteps: 5
        )

        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal1, subgoal2])

        let fieldCandidateBefore = makeCandidate(id: "field_name", role: "AXTextField", label: "Full Name", x: 100, y: 100, w: 200, h: 32)
        let submitCandidate = makeCandidate(id: "btn_submit", role: "AXButton", label: "Submit", x: 100, y: 160)
        let s0 = makeSnapshot(title: "Form View", candidates: [fieldCandidateBefore, submitCandidate])

        var fieldCandidateAfter = fieldCandidateBefore
        fieldCandidateAfter.value = "Agentic User"
        let s1 = makeSnapshot(title: "Form View", candidates: [fieldCandidateAfter, submitCandidate], focusedId: "field_name")

        let dialogCandidate = makeCandidate(id: "dialog_confirm", role: "AXWindow", label: "Confirmation dialog", x: 50, y: 50, w: 400, h: 300)
        let s2 = makeSnapshot(title: "Confirmed View", candidates: [fieldCandidateAfter, submitCandidate, dialogCandidate])

        let mockInspector = MockUIInspector(snapshots: [s0, s1, s2])

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "field_name", action: "type", confidence: 0.95, text: "Agentic User", isCompleted: 0.0),
            (target: "btn_submit", action: "click", confidence: 0.96, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator, confidenceThreshold: 0.80)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Fill form and submit")

        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 2)
        #expect(summary.completedSubgoals == 2)
        #expect(summary.totalSubgoals == 2)

        let events = mockSynthesizer.recordedEvents
        #expect(events.contains(.typeText("Agentic User")))
        #expect(events.contains(.click(point: submitCandidate.center, button: .left, clickCount: 1)))
    }

    @Test("Single step completion: single subgoal executes 1 action and immediately satisfies expected outcome")
    func testSingleStepCompletion() async throws {
        let subgoal = Subgoal(id: "sg_single", description: "Click Next", expectedOutcome: "Page 2", maxSteps: 3)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let btn = makeCandidate(id: "btn_next", role: "AXButton", label: "Next", x: 200, y: 200)
        let s0 = makeSnapshot(title: "Page 1", candidates: [btn])
        let s1 = makeSnapshot(title: "Page 2 - Complete", candidates: [])
        let mockInspector = MockUIInspector(snapshots: [s0, s1])

        let mockEvaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_next", actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Go to page 2")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)
        #expect(summary.completedSubgoals == 1)
        #expect(mockSynthesizer.recordedEvents.count == 1)
    }

    @Test("Delegate lifecycle events are properly dispatched")
    func testDelegateLifecycleEventsDispatched() async throws {
        actor TestDelegate: AutonomousLoopDelegate {
            var started = false
            var steps: [Int] = []
            var completedSummary: ExecutionSummary?

            func loopDidStart(goal: String) async {
                started = true
            }

            func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async {
                steps.append(step)
            }

            func loopDidComplete(summary: ExecutionSummary) async {
                completedSummary = summary
            }
        }

        let delegate = TestDelegate()
        let subgoal = Subgoal(description: "One action", expectedOutcome: "Title Changed", maxSteps: 5)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let cand = makeCandidate(id: "btn_go", role: "AXButton", label: "Go", x: 50, y: 50)
        let s0 = makeSnapshot(title: "Init", candidates: [cand])
        let s1 = makeSnapshot(title: "Title Changed", candidates: [])
        let mockInspector = MockUIInspector(snapshots: [s0, s1])
        let mockEvaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_go", actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing,
            delegate: delegate
        )

        let summary = try await coordinator.execute(goal: "Test delegate")
        #expect(summary.isSuccess)
        let started = await delegate.started
        let steps = await delegate.steps
        let completed = await delegate.completedSummary
        #expect(started)
        #expect(steps == [1])
        #expect(completed != nil)
    }

    // MARK: - Group 2: Step Budget Enforcement

    @Test("Step budget enforcement: loop strictly halts with .stepBudgetExceeded when step count reaches maxSteps")
    func testGlobalStepBudgetExceededHaltsExecution() async throws {
        let subgoal = Subgoal(description: "Unachievable task", expectedOutcome: "Never matches", maxSteps: 10)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let candidate = makeCandidate(id: "btn_spin", role: "AXButton", label: "Spin", x: 100, y: 100)
        let s0 = makeSnapshot(title: "Stuck Screen", candidates: [candidate])
        let mockInspector = MockUIInspector(repeating: s0)

        let mockEvaluator = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_spin", confidence: 0.90),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "wait", confidence: 0.90),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ]
            )
        }
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.maxSteps = 3
        config.identicalActionThreshold = 10
        config.unchangedStateThreshold = 10

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Infinite spin")
            #expect(Bool(false), "Should have thrown step budget exceeded")
        } catch let error as LoopExecutionError {
            #expect(error == .stepBudgetExceeded(steps: 3))
        }
    }

    @Test("Boundary: maxSteps = 0 throws stepBudgetExceeded immediately before executing actions")
    func testZeroMaxStepsBoundary() async throws {
        let subgoal = Subgoal(description: "Any", expectedOutcome: "Any", maxSteps: 5)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])
        let mockInspector = MockUIInspector(repeating: makeSnapshot(title: "Title", candidates: []))
        let mockEvaluator = MockTypeSafeEvaluator.scripted(actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.maxSteps = 0

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Zero budget test")
            #expect(Bool(false), "Should have thrown step budget exceeded")
        } catch let error as LoopExecutionError {
            #expect(error == .stepBudgetExceeded(steps: 0))
        }
        #expect(mockSynthesizer.recordedEvents.isEmpty)
    }

    // MARK: - Group 3: Two-Factor Infinite Loop Detection

    @Test("Infinite loop detection Factor 1: repeated identical action >= 3 times triggers .infiniteLoopDetected")
    func testFactor1IdenticalActionRepetitionHalts() async throws {
        let subgoal = Subgoal(description: "Click unresponsive button", expectedOutcome: "Done", maxSteps: 10)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let candidate = makeCandidate(id: "btn_dead", role: "AXButton", label: "Dead Button", x: 200, y: 200)
        let s0 = makeSnapshot(title: "Dead Window", candidates: [candidate])
        let mockInspector = MockUIInspector(repeating: s0)

        let mockEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "btn_dead",
            targetConfidence: 0.95,
            actionChoice: "click"
        )
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3
        config.maxSteps = 20

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        await #expect(throws: LoopExecutionError.self) {
            try await coordinator.execute(goal: "Spam dead button")
        }

        #expect(mockSynthesizer.recordedEvents.contains(.releaseAllHeldEvents))
    }

    @Test("Infinite loop detection Factor 2: unchanged UI state across >= 3 steps triggers .infiniteLoopDetected")
    func testFactor2UnchangedUIStateRepetitionHalts() async throws {
        let subgoal = Subgoal(description: "Click various items", expectedOutcome: "Window title changed", maxSteps: 10)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let c1 = makeCandidate(id: "btn_1", role: "AXButton", label: "One", x: 100, y: 100)
        let c2 = makeCandidate(id: "btn_2", role: "AXButton", label: "Two", x: 200, y: 100)
        let c3 = makeCandidate(id: "btn_3", role: "AXButton", label: "Three", x: 300, y: 100)

        let s0 = makeSnapshot(title: "Frozen Window", candidates: [c1, c2, c3])
        let mockInspector = MockUIInspector(repeating: s0)

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn_1", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "btn_2", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "btn_3", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 10
        config.unchangedStateThreshold = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        await #expect(throws: LoopExecutionError.self) {
            try await coordinator.execute(goal: "Click frozen elements")
        }

        #expect(mockSynthesizer.recordedEvents.contains(.releaseAllHeldEvents))
    }

    // MARK: - Group 4: Emergency Cancellation Halt

    @Test("Emergency cancellation: calling token.cancel() halts execution immediately before next step")
    func testEmergencyCancellationHaltsExecution() async throws {
        let subgoal = Subgoal(description: "Long process", expectedOutcome: "Complete", maxSteps: 20)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let candidate = makeCandidate(id: "btn_step", role: "AXButton", label: "Step", x: 100, y: 100)
        let s0 = makeSnapshot(title: "Window", candidates: [candidate])
        let mockInspector = MockUIInspector(repeating: s0)

        let token = CancellationToken()
        let mockSynthesizer = MockEventSynthesizer()

        let mockEvaluator = MockTypeSafeEvaluator { _ in
            token.cancel()
            return TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_step", confidence: 0.90),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "click", confidence: 0.90),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                ]
            )
        }
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Cancel me", cancellationToken: token)
            #expect(Bool(false), "Should have thrown cancelled")
        } catch let error as LoopExecutionError {
            #expect(error == .cancelled)
        }

        #expect(mockSynthesizer.recordedEvents.contains(.releaseAllHeldEvents))
    }

    @Test("Cancellation before start aborts immediately with 0 synthetic actions")
    func testCancellationBeforeStartAbortsImmediately() async throws {
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [Subgoal(description: "A", expectedOutcome: "B")])
        let mockInspector = MockUIInspector(repeating: makeSnapshot(title: "T", candidates: []))
        let mockSynthesizer = MockEventSynthesizer()
        let decisionEngine = TypeSafeDecisionEngine(client: MockTypeSafeEvaluator.scripted(actionChoice: "click"))

        let token = CancellationToken()
        token.cancel()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Already cancelled", cancellationToken: token)
            #expect(Bool(false), "Should have thrown cancelled")
        } catch let error as LoopExecutionError {
            #expect(error == .cancelled)
        }

        #expect(mockSynthesizer.recordedEvents.isEmpty || mockSynthesizer.recordedEvents == [.releaseAllHeldEvents])
    }

    // MARK: - Group 5: Low-Confidence Re-Planning Escalation

    @Test("Escalation: low confidence (<0.80) triggers System 2 re-planning and successfully resumes with revised subgoals")
    func testLowConfidenceRePlanningEscalation() async throws {
        let originalSubgoal = Subgoal(id: "sg_orig", description: "Vague goal", expectedOutcome: "Outcome", maxSteps: 5)
        let revisedSubgoal = Subgoal(id: "sg_revised", description: "Clear goal", expectedOutcome: "Outcome verified", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [originalSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, plan, snapshot in
                if case .lowConfidence(let conf, let threshold) = reason {
                    #expect(conf == 0.65)
                    #expect(threshold == 0.80)
                    return .resumeWithRevisedSubgoals([revisedSubgoal])
                }
                return .abort(reason: "Unexpected escalation reason")
            }
        )

        let candidate = makeCandidate(id: "btn_ok", role: "AXButton", label: "OK", x: 100, y: 100)
        let s0 = makeSnapshot(title: "View", candidates: [candidate])
        let s1 = makeSnapshot(title: "View Updated", candidates: [candidate])
        let mockInspector = MockUIInspector(snapshots: [s0, s1])

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn_ok", action: "click", confidence: 0.65, text: nil as String?, isCompleted: 0.0),
            (target: "btn_ok", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator, confidenceThreshold: 0.80)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Escalation recovery")

        #expect(summary.isSuccess)
        let escalations = await mockPlanner.recordedEscalations
        #expect(escalations.count == 1)
        #expect(escalations[0].reason == .lowConfidence(confidence: 0.65, threshold: 0.80))
    }

    @Test("Escalation: empty candidate list triggers escalation, aborts if planner returns .abort")
    func testEmptyCandidatesEscalatesToSystem2() async throws {
        let subgoal = Subgoal(description: "Click hidden button", expectedOutcome: "Found", maxSteps: 5)
        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { reason, _, _, _ in
                #expect(reason == .emptyCandidates)
                return .abort(reason: "App window minimized or not visible")
            }
        )

        let mockInspector = MockUIInspector(repeating: makeSnapshot(title: "Empty Desktop", candidates: []))
        let mockEvaluator = MockTypeSafeEvaluator.scripted(actionChoice: "none")
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Find missing app")
            #expect(Bool(false), "Should have thrown escalation failed")
        } catch let error as LoopExecutionError {
            #expect(error == .escalationFailed(reason: "App window minimized or not visible"))
        }
    }

    @Test("Escalation: skipCurrentSubgoal skips problematic subgoal and advances to next")
    func testSubgoalSkipResolution() async throws {
        let sg1 = Subgoal(id: "sg_1", description: "Failing step", expectedOutcome: "Outcome 1", maxSteps: 3)
        let sg2 = Subgoal(id: "sg_2", description: "Succeeding step", expectedOutcome: "Outcome 2", maxSteps: 3)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [sg1, sg2]) },
            escalationHandler: { reason, _, _, _ in
                .skipCurrentSubgoal
            }
        )

        let cand = makeCandidate(id: "btn_step2", role: "AXButton", label: "Step 2 Button", x: 10, y: 10)
        let s0 = makeSnapshot(title: "S0", candidates: [cand])
        let mockInspector = MockUIInspector(repeating: s0)

        // Step 1: low confidence (0.60 < 0.80) -> escalates -> skipped -> advances to sg2
        // Step 2: high confidence & isCompleted -> completes
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn_step2", action: "click", confidence: 0.60, text: nil as String?, isCompleted: 0.0),
            (target: "btn_step2", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator, confidenceThreshold: 0.80)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Skip test")
        #expect(summary.isSuccess)
        let escalations = await mockPlanner.recordedEscalations
        #expect(escalations.count == 1)
    }

    // MARK: - Group 6: Edge Cases & Robustness

    @Test("Immediate goal completion: Jev is_completed >= 0.70 terminates loop on step 1 with 0 synthetic events")
    func testImmediateGoalCompletion() async throws {
        let subgoal = Subgoal(description: "Ensure page is open", expectedOutcome: "Page already open", maxSteps: 5)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let candidate = makeCandidate(id: "heading_title", role: "AXStaticText", label: "Welcome", x: 50, y: 50)
        let mockInspector = MockUIInspector(repeating: makeSnapshot(title: "Dashboard", candidates: [candidate]))

        let mockEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "none",
            actionChoice: "none",
            isCompletedProbability: 0.92
        )
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Check dashboard")

        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)
        #expect(mockSynthesizer.recordedEvents.isEmpty)
    }

    @Test("Confidence threshold boundary: 0.80 proceeds without escalation, 0.79 escalates")
    func testConfidenceThresholdExactBoundaries() async throws {
        // Case A: 0.80 -> exactly threshold -> proceeds
        let mockPlannerA = MockPlanningLLM.staticPlan(subgoals: [Subgoal(description: "A", expectedOutcome: "Title A")])
        let candA = makeCandidate(id: "btn_a", role: "AXButton", label: "A", x: 10, y: 10)
        let s0A = makeSnapshot(title: "V", candidates: [candA])
        let s1A = makeSnapshot(title: "Title A", candidates: [candA])
        let inspectorA = MockUIInspector(snapshots: [s0A, s1A])
        let evaluatorA = MockTypeSafeEvaluator.scripted(targetChoice: "btn_a", targetConfidence: 0.80, actionChoice: "click")
        let engineA = TypeSafeDecisionEngine(client: evaluatorA, confidenceThreshold: 0.80)
        let synthA = MockEventSynthesizer()

        let coordA = TwoTierAutonomousLoopCoordinator(planner: mockPlannerA, decisionEngine: engineA, synthesizer: synthA, inspector: inspectorA, config: .testing)
        let summaryA = try await coordA.execute(goal: "Test 0.80")
        #expect(summaryA.isSuccess)
        #expect(synthA.recordedEvents.count == 1)

        // Case B: 0.79 -> just below threshold -> escalates
        let mockPlannerB = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [Subgoal(description: "B", expectedOutcome: "B")]) },
            escalationHandler: { reason, _, _, _ in
                if case .lowConfidence(let c, _) = reason {
                    #expect(c == 0.79)
                }
                return .abort(reason: "Escalated on 0.79")
            }
        )
        let inspectorB = MockUIInspector(repeating: s0A)
        let evaluatorB = MockTypeSafeEvaluator.scripted(targetChoice: "btn_a", targetConfidence: 0.79, actionChoice: "click")
        let engineB = TypeSafeDecisionEngine(client: evaluatorB, confidenceThreshold: 0.80)
        let synthB = MockEventSynthesizer()

        let coordB = TwoTierAutonomousLoopCoordinator(planner: mockPlannerB, decisionEngine: engineB, synthesizer: synthB, inspector: inspectorB, config: .testing)
        do {
            _ = try await coordB.execute(goal: "Test 0.79")
            #expect(Bool(false), "Should have thrown escalation failed")
        } catch let error as LoopExecutionError {
            #expect(error == .escalationFailed(reason: "Escalated on 0.79"))
        }
    }

    @Test("Synthesizer failure is caught, triggers emergency release, and aborts with .executionFailed")
    func testSynthesizerFailureHaltsGracefully() async throws {
        let subgoal = Subgoal(description: "Click", expectedOutcome: "Done", maxSteps: 5)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])
        let cand = makeCandidate(id: "btn_err", role: "AXButton", label: "Err", x: 10, y: 10)
        let mockInspector = MockUIInspector(repeating: makeSnapshot(title: "Err Window", candidates: [cand]))
        let mockEvaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_err", actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)

        struct SimulatedSynthesizerError: Error, LocalizedError {
            var errorDescription: String? { "Simulated hardware error" }
        }
        let mockSynthesizer = MockEventSynthesizer(injectedError: SimulatedSynthesizerError())

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Trigger crash")
            #expect(Bool(false), "Should have thrown execution failed")
        } catch let error as LoopExecutionError {
            #expect(error == .executionFailed(reason: "Simulated hardware error"))
        }
    }

    // MARK: - Group 7: Progress-Aware Navigation & Stagnation Escalation (R1 & R2)

    @Test("Progress-Aware: continuous exploratory scroll with screen changes completes without loop detector halt")
    func testContinuousExploratoryScrollNavigationCompletes() async throws {
        let subgoal = Subgoal(description: "Scroll to find target", expectedOutcome: "Done Page", maxSteps: 6)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        // 6 snapshots: feed scrolling across 4 steps, then 5th step transitions to Done Page
        let s0 = makeSnapshot(title: "Feed Page", candidates: [makeCandidate(id: "post_1", role: "AXRow", label: "Post 1", x: 10, y: 10)])
        let s1 = makeSnapshot(title: "Feed Page", candidates: [makeCandidate(id: "post_2", role: "AXRow", label: "Post 2", x: 10, y: 20)])
        let s2 = makeSnapshot(title: "Feed Page", candidates: [makeCandidate(id: "post_3", role: "AXRow", label: "Post 3", x: 10, y: 30)])
        let s3 = makeSnapshot(title: "Feed Page", candidates: [makeCandidate(id: "post_4", role: "AXRow", label: "Post 4", x: 10, y: 40)])
        let s4 = makeSnapshot(title: "Feed Page", candidates: [makeCandidate(id: "post_5", role: "AXRow", label: "Post 5", x: 10, y: 50)])
        let s5 = makeSnapshot(title: "Done Page", candidates: [makeCandidate(id: "post_5", role: "AXRow", label: "Post 5", x: 10, y: 50)])

        let mockInspector = MockUIInspector(snapshots: [s0, s1, s2, s3, s4, s5])

        // 4 consecutive identical scroll actions, followed by completion action
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "post_5", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3 // Threshold is 3, but we execute 4 scrolls!

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Find target item by scrolling")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 5)
        #expect(mockSynthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }.count == 4)
    }

    @Test("Stagnation Escalation: repeated scroll at bottom escalates to System 2 Planner as .actionStagnant and recovers")
    func testScrollStagnationEscalatesToSystem2AndRecovers() async throws {
        let initialSubgoal = Subgoal(id: "sg_scroll", description: "Scroll to load items", expectedOutcome: "More items", maxSteps: 5)
        let recoverySubgoal = Subgoal(id: "sg_search", description: "Use search field instead", expectedOutcome: "Search Results Screen", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                return .replacePlan([recoverySubgoal])
            }
        )

        let footerCand = makeCandidate(id: "footer_end", role: "AXStaticText", label: "End of feed", x: 10, y: 100)
        let searchFieldCand = makeCandidate(id: "field_search", role: "AXTextField", label: "Search", x: 10, y: 10)
        let searchResultCand = makeCandidate(id: "res_1", role: "AXStaticText", label: "Search Results", x: 50, y: 50)
        let sBottom = makeSnapshot(title: "Dead End Feed", candidates: [footerCand, searchFieldCand])
        let sSearch = makeSnapshot(title: "Search Results Screen", candidates: [searchResultCand])

        let mockInspector = MockUIInspector(snapshots: [sBottom, sBottom, sBottom, sBottom, sSearch])

        // Initial subgoal: 3 consecutive scrolls on unchanging screen (hits stagnation)
        // Escalation: planner replaces plan with recoverySubgoal
        // Recovery subgoal: type and submit search, verifying outcome
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "field_search", action: "type", confidence: 0.95, text: "query", isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Find item with stagnation recovery")
        #expect(summary.isSuccess)

        // Verify that escalation happened with .actionStagnant
        let escalations = await mockPlanner.recordedEscalations
        #expect(!escalations.isEmpty)
        let reason = escalations.first?.reason
        #expect(reason?.isActionStagnant == true)
        if case .actionStagnant(let desc) = reason {
            #expect(!desc.isEmpty)
        }
    }

    @Test("Stagnation Escalation: post-action diff boundary stagnation (Factor 2) escalates to System 2 Planner and recovers")
    func testScrollPostActionDiffStagnationEscalatesToSystem2AndRecovers() async throws {
        let initialSubgoal = Subgoal(id: "sg_scroll", description: "Scroll feed", expectedOutcome: "Nonexistent Marker", maxSteps: 6)
        let recoverySubgoal = Subgoal(id: "sg_search", description: "Search feed", expectedOutcome: "Search Results", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                return .replacePlan([recoverySubgoal])
            }
        )

        // Snapshots: 3 steps with progress, 4th step unchanged (bottom boundary), 5th step search
        let s0 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_1", role: "AXRow", label: "Item 1", x: 10, y: 10)])
        let s1 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_2", role: "AXRow", label: "Item 2", x: 10, y: 20)])
        let s2 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_3", role: "AXRow", label: "Item 3", x: 10, y: 30)])
        let s3 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_4", role: "AXRow", label: "Item 4", x: 10, y: 40)])
        let s4 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_4", role: "AXRow", label: "Item 4", x: 10, y: 40)]) // unchanged!
        let sSearch = makeSnapshot(title: "Search Results", candidates: [makeCandidate(id: "res_done", role: "AXStaticText", label: "Result", x: 50, y: 50)])

        let mockInspector = MockUIInspector(snapshots: [s0, s1, s2, s3, s4, s4, sSearch])

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "res_done", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Find item through boundary stagnation recovery")
        #expect(summary.isSuccess)

        let escalations = await mockPlanner.recordedEscalations
        #expect(!escalations.isEmpty)
        let reason = escalations.first?.reason
        #expect(reason?.isActionStagnant == true)
        if case .actionStagnant(let desc) = reason {
            #expect(desc.contains("Action stagnation detected"))
        }
    }

    @Test("Stagnation Cascade: repeated stagnation across subgoals halts execution at maxConsecutiveEscalations")
    func testStagnationCascadeHaltsAtMaxConsecutiveEscalations() async throws {
        let initialSubgoal = Subgoal(id: "sg_1", description: "Initial subgoal", expectedOutcome: "Some outcome", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                // Keep retrying with a revised subgoal that will also stagnate
                let nextSubgoal = Subgoal(id: "\(currentSubgoal.id)_retry", description: "Retry subgoal", expectedOutcome: "Outcome", maxSteps: 5)
                return .retrySubgoal(nextSubgoal)
            }
        )

        let footerCand = makeCandidate(id: "footer_end", role: "AXStaticText", label: "End of feed", x: 10, y: 100)
        let sBottom = makeSnapshot(title: "Dead End Feed", candidates: [footerCand])

        // Feed snapshots that never change
        let snapshots = Array(repeating: sBottom, count: 20)
        let mockInspector = MockUIInspector(snapshots: snapshots)

        // Always decide to scroll
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2
        config.maxConsecutiveEscalations = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Cascade test")
            #expect(Bool(false), "Should have thrown escalationFailed")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Exceeded maximum consecutive escalations"))
            } else {
                #expect(Bool(false), "Expected .escalationFailed but got \(error)")
            }
        }

        let escalations = await mockPlanner.recordedEscalations
        #expect(escalations.count == 2, "Coordinator escalates twice and aborts on the 3rd escalation threshold")
    }

    @Test("State Oscillation: A-B-A-B state oscillation escalates to System 2 Planner and recovers")
    func testStateOscillationEscalatesToSystem2AndRecovers() async throws {
        let initialSubgoal = Subgoal(id: "sg_tabs", description: "Toggle tabs", expectedOutcome: "Nonexistent Goal", maxSteps: 6)
        let recoverySubgoal = Subgoal(id: "sg_recovery", description: "Direct navigation", expectedOutcome: "Target state", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                return .replacePlan([recoverySubgoal])
            }
        )

        let candA = makeCandidate(id: "tab_a", role: "AXButton", label: "Tab A", x: 10, y: 10)
        let candB = makeCandidate(id: "tab_b", role: "AXButton", label: "Tab B", x: 100, y: 10)
        let snapA = makeSnapshot(title: "Tab A Screen", candidates: [candA, candB])
        let snapB = makeSnapshot(title: "Tab B Screen", candidates: [candA, candB])
        let snapDone = makeSnapshot(title: "Target Screen", candidates: [makeCandidate(id: "done", role: "AXButton", label: "Done", x: 50, y: 50)])

        // Oscillate: A -> B -> A -> B, then on escalation recovery transition to snapDone
        let mockInspector = MockUIInspector(snapshots: [snapA, snapB, snapA, snapB, snapA, snapDone])

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "tab_b", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "tab_a", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "tab_b", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "tab_a", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "done", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.unchangedStateThreshold = 5

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Oscillation test")
        #expect(summary.isSuccess)

        let escalations = await mockPlanner.recordedEscalations
        #expect(!escalations.isEmpty)
        let reason = escalations.first?.reason
        #expect(reason?.isActionStagnant == true)
        if case .actionStagnant(let desc) = reason {
            #expect(desc.contains("UI state oscillation"))
        }
    }

    @Test("Factor 2 Stagnation: stagnant step is recorded in stepRecords and notified to delegate")
    func testFactor2StagnationRecordsStepAndNotifiesDelegate() async throws {
        actor StepTrackingDelegate: AutonomousLoopDelegate {
            var notifiedSteps: [Int] = []

            func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async {
                notifiedSteps.append(step)
            }
        }

        let initialSubgoal = Subgoal(id: "sg_stagnant", description: "Scroll feed", expectedOutcome: "Never matches", maxSteps: 5)
        let recoverySubgoal = Subgoal(id: "sg_recovery", description: "Search result navigation", expectedOutcome: "Search Results", maxSteps: 5)

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                return .replacePlan([recoverySubgoal])
            }
        )

        let snap0 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_1", role: "AXRow", label: "Item 1", x: 10, y: 10)])
        let snap1 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_2", role: "AXRow", label: "Item 2", x: 10, y: 20)])
        let snap2 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_3", role: "AXRow", label: "Item 3", x: 10, y: 30)])
        let snap3 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_4", role: "AXRow", label: "Item 4", x: 10, y: 40)])
        let snap4 = makeSnapshot(title: "Feed", candidates: [makeCandidate(id: "item_4", role: "AXRow", label: "Item 4", x: 10, y: 40)]) // unchanged!
        let snapSearch = makeSnapshot(title: "Search Results", candidates: [makeCandidate(id: "res_done", role: "AXStaticText", label: "Result", x: 50, y: 50)])

        let mockInspector = MockUIInspector(snapshots: [snap0, snap1, snap2, snap3, snap4, snap4, snapSearch])

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "res_done", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()
        let delegate = StepTrackingDelegate()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config,
            delegate: delegate
        )

        let summary = try await coordinator.execute(goal: "Stagnant step record verification")
        #expect(summary.isSuccess)

        // All 4 micro-actions (3 scroll steps including stagnant boundary + 1 recovery click) must be recorded and notified
        let notifiedSteps = await delegate.notifiedSteps
        #expect(notifiedSteps.count == 4, "Delegate must receive loopDidStep for all 4 executed steps")
        #expect(summary.stepRecords.count == 4, "stepRecords must contain all 4 executed steps")
        #expect(summary.totalSteps == 5)
    }

    @Test("Cancellation: token cancellation during stagnation escalation aborts with .cancelled")
    func testCancellationDuringStagnationEscalationAbortsWithCancelled() async throws {
        actor BegunSubgoalsTracker: AutonomousLoopDelegate {
            var begunSubgoalIds: [String] = []

            func loopDidBeginSubgoal(subgoal: Subgoal, index: Int, total: Int) async {
                begunSubgoalIds.append(subgoal.id)
            }
        }

        let initialSubgoal = Subgoal(id: "sg_stagnant", description: "Scroll dead end", expectedOutcome: "Never matches", maxSteps: 5)
        let token = CancellationToken()

        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                #expect(reason.isActionStagnant)
                // Cancel token during escalation replan
                token.cancel()
                let recoverySubgoal = Subgoal(id: "sg_recovery_unwanted", description: "Should never start", expectedOutcome: "Never", maxSteps: 5)
                return .retrySubgoal(recoverySubgoal)
            }
        )

        let footerCand = makeCandidate(id: "footer", role: "AXStaticText", label: "End", x: 10, y: 100)
        let sBottom = makeSnapshot(title: "Dead End", candidates: [footerCand])
        let mockInspector = MockUIInspector(repeating: sBottom)

        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()
        let tracker = BegunSubgoalsTracker()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config,
            delegate: tracker
        )

        do {
            _ = try await coordinator.execute(goal: "Stagnation cancellation test", cancellationToken: token)
            #expect(Bool(false), "Should have thrown .cancelled")
        } catch let error as LoopExecutionError {
            #expect(error == .cancelled, "Must throw .cancelled instead of .escalationFailed")
        }

        let begun = await tracker.begunSubgoalIds
        #expect(!begun.contains("sg_recovery_unwanted"), "Cancelled escalation must not dispatch loopDidBeginSubgoal for revised subgoal")
        #expect(mockSynthesizer.recordedEvents.contains(.releaseAllHeldEvents))
    }

    // MARK: - System 2 LLM Reflection & Guarded Verification Tests

    @Test("DefaultSubgoalPlanner: LLM reflection replanning parses replacePlan resolution")
    func testDefaultSubgoalPlannerLLMReflectionReplacePlan() async throws {
        let jsonResponse = """
        {
            "resolution": "replacePlan",
            "rationale": "Scrolling hit page boundary, searching via search bar instead",
            "subgoals": [
                {
                    "id": "sg_search_recovery",
                    "description": "Click search bar and type query",
                    "expectedOutcome": "Search field focused",
                    "maxSteps": 5
                }
            ]
        }
        """
        let mockExecutor = ScriptedExecutor(text: jsonResponse)
        let planner = DefaultSubgoalPlanner(modelExecutor: mockExecutor)

        let failedSubgoal = Subgoal(id: "sg_scroll", description: "Scroll feed", expectedOutcome: "New item", maxSteps: 5)
        let resolution = try await planner.replan(
            goal: "Find target item",
            failedSubgoal: failedSubgoal,
            reason: .actionStagnant(reason: "Boundary reached"),
            currentSnapshot: UIStateSnapshot(visibleCandidates: [
                UIElementCandidate(id: "search_bar", role: "AXTextField", label: "Search", bounds: .zero)
            ]),
            history: []
        )

        guard case .replacePlan(let subgoals) = resolution else {
            Issue.record("Expected .replacePlan but got \(resolution)")
            return
        }
        #expect(subgoals.count == 1)
        #expect(subgoals[0].id == "sg_search_recovery")
        #expect(subgoals[0].description == "Click search bar and type query")
    }

    @Test("DefaultSubgoalPlanner: LLM reflection replanning parses completeGoal resolution")
    func testDefaultSubgoalPlannerLLMReflectionCompleteGoal() async throws {
        let jsonResponse = """
        {
            "resolution": "completeGoal",
            "rationale": "Target item is already present and highlighted on screen"
        }
        """
        let mockExecutor = ScriptedExecutor(text: jsonResponse)
        let planner = DefaultSubgoalPlanner(modelExecutor: mockExecutor)

        let failedSubgoal = Subgoal(id: "sg_find", description: "Look for item", expectedOutcome: "Item found", maxSteps: 5)
        let resolution = try await planner.replan(
            goal: "Find item",
            failedSubgoal: failedSubgoal,
            reason: .outcomeUnverified(expected: "Item found", stepsTaken: 5),
            currentSnapshot: UIStateSnapshot(visibleCandidates: []),
            history: []
        )

        guard case .completeGoal(let summary) = resolution else {
            Issue.record("Expected .completeGoal but got \(resolution)")
            return
        }
        #expect(summary.contains("Target item is already present"))
    }

    @Test("DefaultSubgoalPlanner: heuristic fallback when modelExecutor is nil")
    func testDefaultSubgoalPlannerHeuristicFallback() async throws {
        let planner = DefaultSubgoalPlanner(modelExecutor: nil)
        let failedSubgoal = Subgoal(id: "sg_stuck", description: "Click submit", expectedOutcome: "Submitted", maxSteps: 5)

        let resolution = try await planner.replan(
            goal: "Submit form",
            failedSubgoal: failedSubgoal,
            reason: .actionStagnant(reason: "Button unresponsive"),
            currentSnapshot: nil,
            history: []
        )

        guard case .retrySubgoal(let retrySubgoal) = resolution else {
            Issue.record("Expected .retrySubgoal but got \(resolution)")
            return
        }
        #expect(retrySubgoal.id == "sg_stuck_alt")
        #expect(retrySubgoal.description.contains("Navigate using alternative elements"))
        #expect(!retrySubgoal.description.contains("stagnation: Button unresponsive"), "Must not leak raw diagnostic error strings into Jev description")
    }

    @Test("Guarded Verification: Subgoal with empty expectedOutcome does not complete prematurely on step 1 diff")
    func testGuardedVerificationDoesNotCompletePrematurelyOnEmptyOutcome() async throws {
        let subgoalWithEmptyOutcome = Subgoal(
            id: "sg_multi",
            description: "Type name and submit",
            expectedOutcome: "",
            maxSteps: 5
        )
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoalWithEmptyOutcome])

        let fieldCand = makeCandidate(id: "name_field", role: "AXTextField", label: "Name", x: 10, y: 10)
        let submitCand = makeCandidate(id: "submit_btn", role: "AXButton", label: "Submit", x: 10, y: 50)

        let snap1 = makeSnapshot(title: "Form", candidates: [fieldCand, submitCand])
        let snap2 = makeSnapshot(title: "Form (Typing)", candidates: [fieldCand, submitCand])
        let snap3 = makeSnapshot(title: "Form (Submitted)", candidates: [])

        let mockInspector = MockUIInspector(snapshots: [snap1, snap2, snap3])

        // Step 1: Types text, hasSignificantChange == true, but isCompleted == 0.0 (not completed!)
        // Step 2: Clicks submit, isCompleted == 1.0 (completed!)
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "name_field" as String?, action: "typeText", confidence: 0.95, text: "Alice" as String?, isCompleted: 0.0),
            (target: "submit_btn" as String?, action: "click", confidence: 0.95, text: nil as String?, isCompleted: 1.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Fill form")

        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 2, "Must execute both steps and not terminate prematurely on step 1 diff")
    }

    @Test("Debug & Logging: EscalationReason custom descriptions format as clear diagnostics")
    func testEscalationReasonDescriptions() {
        let emptyCand = EscalationReason.emptyCandidates
        #expect(emptyCand.description.contains("No actionable UI element candidates"))

        let lowConf = EscalationReason.lowConfidence(confidence: 0.65, threshold: 0.80)
        #expect(lowConf.description.contains("0.65"))
        #expect(lowConf.description.contains("0.80"))

        let stagnant = EscalationReason.actionStagnant(reason: "Repeated clicks")
        #expect(stagnant.description.contains("Repeated clicks"))

        let outcome = EscalationReason.outcomeUnverified(expected: "Logged in", stepsTaken: 10)
        #expect(outcome.description.contains("Logged in"))
        #expect(outcome.description.contains("10 steps"))
    }

    @Test("Debug & Logging: AutonomousLoopConfig supports debug mode flag")
    func testAutonomousLoopConfigDebugMode() {
        var config = AutonomousLoopConfig(isDebugMode: true)
        #expect(config.isDebugMode == true)

        config.isDebugMode = false
        #expect(config.isDebugMode == false)

        #expect(AutonomousLoopConfig.testing.isDebugMode == false)
    }

    @Test("Debug & Logging: Escalation limit failure includes detailed recent causes in error message")
    func testEscalationLimitErrorContainsDetailedCauses() async throws {
        let initialSubgoal = Subgoal(id: "sg_stuck", description: "Stuck subgoal", expectedOutcome: "Never", maxSteps: 5)
        let mockPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { _, currentSubgoal, _, _ in
                .retrySubgoal(currentSubgoal)
            }
        )

        let cand = makeCandidate(id: "btn", role: "AXButton", label: "Button", x: 100, y: 100)
        let snap = makeSnapshot(title: "App", candidates: [cand])
        let mockInspector = MockUIInspector(snapshots: [snap])

        // Action sequence repeats identical scroll to trigger stagnation escalation
        let mockEvaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.95, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: mockEvaluator)
        let mockSynthesizer = MockEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2
        config.maxConsecutiveEscalations = 3
        config.isDebugMode = true

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: decisionEngine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Test failure detail")
            #expect(Bool(false), "Should have thrown escalationFailed")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Exceeded maximum consecutive escalations (3)"))
                #expect(reason.contains("Causes: ["), "Error reason must include detailed causes summary: \(reason)")
                #expect(reason.contains("#1:"), "Must list escalation #1")
                #expect(reason.contains("#2:"), "Must list escalation #2")
                #expect(reason.contains("#3:"), "Must list escalation #3")
            } else {
                #expect(Bool(false), "Expected .escalationFailed but got \(error)")
            }
        }
    }

    // MARK: - Milestone 2: Features 5-8 Verification Tests

    @Test("Feature 5: Feedback loop passes history and lastDiff to decideNextAction allowing stagnation adaptation")
    func testFeedbackLoopPassesHistoryAndLastDiff() async throws {
        // Feed container candidate
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 500)
        let s0 = makeSnapshot(title: "Feed View", candidates: [scrollArea])
        let sDone = makeSnapshot(title: "Feed View - Done", candidates: [scrollArea])

        // Snapshot sequence: step 1 produces no diff (s0 -> s0); step 2 adapts to PageDown; step 3 completes
        let mockInspector = MockUIInspector(snapshots: [s0, s0, sDone])
        let mockSynthesizer = MockEventSynthesizer()

        // Unconfigured engine will use fallbackLocalDecision which responds to lastDiff and history
        let engine = TypeSafeDecisionEngine()

        let subgoal = Subgoal(id: "sg_feed", description: "Scroll feed down", expectedOutcome: "title changed to Feed View - Done", maxSteps: 4)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: engine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Browse feed")
        #expect(summary.isSuccess)

        // Step 1 should have issued .scroll
        let scrollEvents = mockSynthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }
        #expect(!scrollEvents.isEmpty, "Step 1 should execute initial scroll")

        // Step 2 should have adapted to keyboard PageDown due to lastDiff.isStateUnchanged == true
        let keyEvents = mockSynthesizer.recordedEvents.filter { if case .pressKey = $0 { return true }; return false }
        #expect(!keyEvents.isEmpty, "Step 2 should adapt to keyboard navigation when history and lastDiff are wired")
    }

    @Test("Feature 6: DefaultSubgoalPlanner strips replan boilerplate, stagnant keywords, and bounds retries")
    func testFeature6_NonRecursiveHeuristicReplanHardening() {
        // 1. Test stripReplanBoilerplate
        let nested = "Retry after low confidence: Navigate using alternative elements or shortcuts for: click submit button"
        let unnested = DefaultSubgoalPlanner.stripReplanBoilerplate(from: nested)
        #expect(unnested == "click submit button")

        let nested2 = "Retry: Interact with alternative interactive element for: search input field"
        let unnested2 = DefaultSubgoalPlanner.stripReplanBoilerplate(from: nested2)
        #expect(unnested2 == "search input field")

        // 2. Test stripStagnantKeywords
        let englishStagnant = "Scroll feed down to view comments"
        let strippedEnglish = DefaultSubgoalPlanner.stripStagnantKeywords(from: englishStagnant)
        #expect(strippedEnglish == "view comments")

        let japaneseStagnant = "タイムラインを下へスクロールして最新情報を確認"
        let strippedJapanese = DefaultSubgoalPlanner.stripStagnantKeywords(from: japaneseStagnant)
        #expect(strippedJapanese == "最新情報を確認")

        let allStripped = "scroll feed down"
        let strippedFallback = DefaultSubgoalPlanner.stripStagnantKeywords(from: allStripped)
        #expect(strippedFallback.isEmpty)

        // 3. Test nextRetryId
        let (id1, attempt1) = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_1", suffix: "alt")
        #expect(id1 == "subgoal_1_alt")
        #expect(attempt1 == 1)

        let (id2, attempt2) = DefaultSubgoalPlanner.nextRetryId(from: id1, suffix: "alt")
        #expect(id2 == "subgoal_1_alt_2")
        #expect(attempt2 == 2)

        let (id3, attempt3) = DefaultSubgoalPlanner.nextRetryId(from: id2, suffix: "alt")
        #expect(id3 == "subgoal_1_alt_3")
        #expect(attempt3 == 3)

        // 4. Test heuristicReplan behavior
        let failedSubgoal = Subgoal(id: "sg_stuck", description: "Scroll feed down to read article", expectedOutcome: "article read", maxSteps: 3)

        // Attempt 1: retries with stripped keywords
        let res1 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failedSubgoal, reason: .actionStagnant(reason: "No screen change"))
        if case .retrySubgoal(let retrySg) = res1 {
            #expect(retrySg.id == "sg_stuck_alt")
            #expect(retrySg.description.contains("read article"))
            #expect(!retrySg.description.contains("Scroll"))
            #expect(!retrySg.description.contains("feed"))
        } else {
            #expect(Bool(false), "Expected retrySubgoal on attempt 1")
        }

        // A boundary still does not prove that the article was read.
        let failedSubgoal2 = Subgoal(id: "sg_stuck_alt", description: "Navigate using alternative elements or shortcuts for: read article", expectedOutcome: "article read", maxSteps: 3)
        let res2 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failedSubgoal2, reason: .actionStagnant(reason: "Page boundary reached or target inert"))
        if case .abort(let reason) = res2 {
            #expect(reason.contains("Outcome unverified"))
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            #expect(Bool(false), "Expected abort for an unverified outcome at the boundary")
        }

        // Exhausting retries preserves the unverified outcome.
        let failedSubgoal3 = Subgoal(id: "sg_stuck_alt_2", description: "read article", expectedOutcome: "article read", maxSteps: 3)
        let res3 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failedSubgoal3, reason: .actionStagnant(reason: "Repeating unchanged state"))
        if case .abort(let reason) = res3 {
            #expect(reason.contains("Outcome unverified"))
            #expect(reason.contains("recovery limit"))
        } else {
            #expect(Bool(false), "Expected abort for an unverified outcome after retries")
        }
    }

    @Test("Feature 7: Coordinator coordinate fallback targets container or centroid, never nil")
    func testCoordinatorCoordinateFallbackInExecuteSyntheticAction() async throws {
        // Case A: With AXScrollArea container
        let scrollArea = makeCandidate(id: "main_scroll", role: "AXScrollArea", label: "Scroll Area", x: 200, y: 150, w: 400, h: 300)
        let s0 = makeSnapshot(title: "Container Page", candidates: [scrollArea])
        let sDone = makeSnapshot(title: "Container Page - Done", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        // Decision with action .scroll but nil targetCenter and nil coordinates
        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_scroll", description: "scroll content", expectedOutcome: "title changed to Container Page - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test scroll coordinate resolution")
        #expect(summary.isSuccess)

        // Verify that the synthesized scroll event had a non-nil point matching the scroll container center (x: 400, y: 300)
        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        let point = scrollEvents[0]
        #expect(point == scrollArea.center, "Scroll coordinate should resolve to scroll container center")
    }

    @Test("Feature 8: Consecutive escalations counter resets on verified screen state progress")
    func testConsecutiveEscalationsResetOnVerifiedScreenProgress() async throws {
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "Next Step 1", x: 10, y: 10)
        let btn2 = makeCandidate(id: "btn2", role: "AXButton", label: "Next Step 2", x: 10, y: 50)
        let doneLabel = makeCandidate(id: "done", role: "AXStaticText", label: "All Completed", x: 10, y: 90)

        let s0 = makeSnapshot(title: "Step 0", candidates: [btn1])
        let s1 = makeSnapshot(title: "Step 1", candidates: [btn2])
        let s2 = makeSnapshot(title: "Step 2 Done", candidates: [doneLabel])

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, s2])
        let synthesizer = MockEventSynthesizer()

        // Planner provides 2 subgoals. Each subgoal initially fails outcome, escalates, retries, and then makes verified progress.
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1_bad", description: "Bad Step 1", expectedOutcome: "title changed to Step 1", maxSteps: 2),
                    Subgoal(id: "sg_2_bad", description: "Bad Step 2", expectedOutcome: "title changed to Step 2 Done", maxSteps: 2)
                ])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                if failedSubgoal.id == "sg_1_bad" {
                    return .retrySubgoal(Subgoal(id: "sg_1_ok", description: "Click Next Step 1", expectedOutcome: "title changed to Step 1", maxSteps: 2))
                } else {
                    return .retrySubgoal(Subgoal(id: "sg_2_ok", description: "Click Next Step 2", expectedOutcome: "title changed to Step 2 Done", maxSteps: 2))
                }
            }
        )

        var config = AutonomousLoopConfig.testing
        // Strict limit: 2 consecutive escalations would trip if counter didn't reset on verified progress!
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Multi-escalation progress recovery")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
    }
}
