import CoreGraphics
import Foundation
import MCACore
import MCAMemory
import MCASensing
@testable import MCAInterop
@testable import MCAReasoning
import MCP
import Testing

@Suite("MCP mutation authorization")
struct MCPMutationAuthorizationTests {
    @Test("Direct MCP dispatch requires approval for scripts and raw input")
    func directDispatch() async throws {
        let store = MockContextStore()
        // Preserve main's MCP error-result API; require an explicit refusal code.
        for (name, arguments) in [
            ("run_applescript", ["script": MCP.Value.string("return 142")]),
            ("computer", ["action": .string("type"), "text": .string("do not type")])
        ] {
            let result = try await ContextMCPServer.dispatch(name: name, arguments: arguments, store: store)
            #expect(result.contains("approval_required"))
            #expect(result.contains("'\(name)' was NOT run"))
        }
    }
}

// MARK: - Test Doubles for MCP Server Testing

actor MockContextStore: ContextStoring {
    private var observations: [DesktopObservation] = []

    func append(_ observation: DesktopObservation) async throws {
        observations.append(observation)
    }

    func search(_ query: ContextQuery) async throws -> [ScoredObservation] {
        []
    }

    func recent(seconds: TimeInterval, limit: Int) async throws -> [DesktopObservation] {
        Array(observations.suffix(limit))
    }

    func purge(olderThan days: Int) async throws -> Int {
        let count = observations.count
        observations.removeAll()
        return count
    }

    func count() async throws -> Int {
        observations.count
    }
}

final class MockSystem2Planner: System2Planning, @unchecked Sendable {
    let subgoals: [Subgoal]
    let shouldFail: Bool

    init(subgoals: [Subgoal] = [], shouldFail: Bool = false) {
        self.subgoals = subgoals
        self.shouldFail = shouldFail
    }

    func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
        if shouldFail {
            throw LoopExecutionError.executionFailed(reason: "Plan generation failed")
        }
        return SubgoalPlan(goal: goal, subgoals: subgoals)
    }

    func replan(
        goal: String,
        failedSubgoal: Subgoal,
        reason: EscalationReason,
        currentSnapshot: UIStateSnapshot?,
        history: [LoopStepRecord]
    ) async throws -> EscalationResolution {
        .abort(reason: "Replan not supported in mock")
    }
}

actor MockMCPTypeSafeEvaluator: TypeSafeEvaluating {
    private var responses: [TypeSafeClient.EvaluationResponse]
    private(set) var evaluationCount = 0

    init(responses: [TypeSafeClient.EvaluationResponse]) {
        self.responses = responses
    }

    init(answers: [String: TypeSafeClient.AnswerPayload] = [:]) {
        self.responses = [TypeSafeClient.EvaluationResponse(model: "jev-mock", answers: answers, usage: nil)]
    }

    static func sequence(_ steps: [(target: String?, action: String?, confidence: Float, isCompleted: Float)]) -> MockMCPTypeSafeEvaluator {
        let resps = steps.map { step in
            var answers: [String: TypeSafeClient.AnswerPayload] = [:]
            if let target = step.target {
                answers["target_element"] = TypeSafeClient.AnswerPayload(type: "choice", choice: target, confidence: step.confidence)
            }
            if let action = step.action {
                answers["action_type"] = TypeSafeClient.AnswerPayload(type: "choice", choice: action, confidence: step.confidence)
            }
            answers["is_completed"] = TypeSafeClient.AnswerPayload(type: "noul", noul: step.isCompleted)
            return TypeSafeClient.EvaluationResponse(model: "jev-mock", answers: answers, usage: nil)
        }
        return MockMCPTypeSafeEvaluator(responses: resps)
    }

    func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
        evaluationCount += 1
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return TypeSafeClient.EvaluationResponse(
            model: "jev-mock",
            answers: ["is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 1.0)],
            usage: nil
        )
    }
}

/// Exercises the live authorization branch while recording instead of posting input.
private final class MCPGuardedInputRecorder: EventSynthesizing, @unchecked Sendable {
    let isSimulation = false
    let isTrusted = true
    private let lock = NSLock()
    private var inputs = 0
    var inputCount: Int { lock.withLock { inputs } }
    private func record() { lock.withLock { inputs += 1 } }
    func cursorPosition() throws -> CGPoint { .zero }
    func mouseMove(to point: CGPoint) throws { record() }
    func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws { record() }
    func drag(from start: CGPoint, to end: CGPoint) throws { record() }
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws { record() }
    func typeText(_ text: String) throws { record() }
    func pressKey(_ key: String) throws { record() }
    func releaseAllHeldEvents() {}
}

/// Holds an in-flight observation until the test has cancelled the real MCP loop.
private actor MCPPausedSnapshotProvider: UIStateProviding {
    enum WaitError: Error { case finishedBeforeObservation, deadlineExceeded }
    private var started = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var output: Result<String, Error>?

    func captureSnapshot() async throws -> UIStateSnapshot {
        started = true
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return UIStateSnapshot(visibleCandidates: [])
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !started {
            if output != nil { throw WaitError.finishedBeforeObservation }
            guard ContinuousClock.now < deadline else { throw WaitError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func finish(_ result: Result<String, Error>) { output = result }

    func waitForOutput() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(5)
        while output == nil {
            guard ContinuousClock.now < deadline else { throw WaitError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try output!.get()
    }
}

final class MockMCPSnapshotProvider: UIStateProviding, @unchecked Sendable {
    let snapshot: UIStateSnapshot

    init(snapshot: UIStateSnapshot = UIStateSnapshot(visibleCandidates: [], timestamp: Date())) {
        self.snapshot = snapshot
    }

    func captureSnapshot() async throws -> UIStateSnapshot {
        snapshot
    }
}

// MARK: - Test Suite

@Suite("ContextMCPServer AutonomousAct Tests: Schema, Dispatch & Execution")
struct ContextMCPServerAutonomousActTests {

    // MARK: - 1. Schema Tests

    @Test("ContextMCPServer registers autonomous_act with valid MCP schema")
    func testAutonomousActToolSchema() {
        let tools = ContextMCPServer.toolDefinitions
        let tool = tools.first { $0.name == "autonomous_act" }
        #expect(tool != nil)

        guard let tool else { return }
        #expect(tool.description?.contains("2-Tier Planning") == true)
        #expect(tool.annotations.readOnlyHint == false)

        guard case .object(let dict) = tool.inputSchema else {
            Issue.record("Expected object inputSchema")
            return
        }
        #expect(dict["type"] == .string("object"))

        guard case .object(let properties)? = dict["properties"] else {
            Issue.record("Expected properties in schema")
            return
        }
        #expect(properties["goal"] != nil)
        #expect(properties["max_steps"] != nil)
        #expect(properties["confidence_threshold"] != nil)
        #expect(properties["dry_run"] != nil)

        guard case .array(let required)? = dict["required"] else {
            Issue.record("Expected required array in schema")
            return
        }
        #expect(required.contains(.string("goal")))
    }

    // MARK: - 2. Argument Validation Tests

    @Test("ContextMCPServer rejects missing or empty goal argument")
    func testAutonomousActMissingGoal() async throws {
        let mockStore = MockContextStore()

        // 1. Missing goal parameter entirely
        let noGoalResult = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["max_steps": .int(10)],
            store: mockStore
        )
        #expect(noGoalResult.contains("Error: 'goal' parameter is required."))

        // 2. Empty string goal parameter
        let emptyGoalResult = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("   ")],
            store: mockStore
        )
        #expect(emptyGoalResult.contains("Error: 'goal' parameter cannot be empty."))
    }

    @Test("ContextMCPServer validates max_steps bounds")
    func testAutonomousActInvalidMaxSteps() async throws {
        let mockStore = MockContextStore()

        let zeroSteps = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Valid Goal"), "max_steps": .int(0)],
            store: mockStore
        )
        #expect(zeroSteps.contains("Error: 'max_steps' must be a positive integer."))

        let negativeSteps = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Valid Goal"), "max_steps": .int(-5)],
            store: mockStore
        )
        #expect(negativeSteps.contains("Error: 'max_steps' must be a positive integer."))
    }

    @Test("ContextMCPServer validates confidence_threshold bounds")
    func testAutonomousActInvalidConfidence() async throws {
        let mockStore = MockContextStore()

        let highConf = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Valid Goal"), "confidence_threshold": .double(1.5)],
            store: mockStore
        )
        #expect(highConf.contains("Error: 'confidence_threshold' must be between 0.0 and 1.0."))

        let lowConf = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Valid Goal"), "confidence_threshold": .double(-0.1)],
            store: mockStore
        )
        #expect(lowConf.contains("Error: 'confidence_threshold' must be between 0.0 and 1.0."))
    }

    // MARK: - 3. Execution Tests

    @Test("ContextMCPServer dispatches autonomous_act with valid parameters returning JSON summary")
    func testAutonomousActSuccessfulExecution() async throws {
        let mockStore = MockContextStore()
        let subgoal = Subgoal(id: "sg_1", description: "Search", expectedOutcome: "Search opened", maxSteps: 3)
        let planner = MockSystem2Planner(subgoals: [subgoal])

        let candidate = UIElementCandidate(
            id: "search_btn",
            role: "AXButton",
            label: "Search",
            bounds: CGRect(x: 100, y: 100, width: 50, height: 30)
        )
        let snapshot = UIStateSnapshot(windowTitle: "App", visibleCandidates: [candidate], timestamp: Date())
        let inspector = MockMCPSnapshotProvider(snapshot: snapshot)

        let evaluator = MockMCPTypeSafeEvaluator.sequence([
            (target: "search_btn", action: "click", confidence: 0.95, isCompleted: 0.0),
            (target: nil, action: nil, confidence: 1.0, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let synthesizer = DryRunEventSynthesizer()

        let customFactory: AutonomousCoordinatorFactory = { config, _ in
            var cfg = config
            cfg.settlingDelayMs = 0
            return TwoTierAutonomousLoopCoordinator(
                planner: planner,
                decisionEngine: engine,
                synthesizer: synthesizer,
                snapshotProvider: inspector,
                config: cfg
            )
        }

        let arguments: [String: Value] = [
            "goal": .string("Click Search button"),
            "max_steps": .int(5),
            "confidence_threshold": .double(0.85),
            "dry_run": .bool(true)
        ]

        let result = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: arguments,
            store: mockStore,
            coordinatorFactory: customFactory
        )

        let data = try #require(result.data(using: .utf8))
        let output = try JSONDecoder().decode(AutonomousActOutput.self, from: data)

        #expect(output.isSuccess)
        #expect(output.totalSteps == 2)
        #expect(output.subgoalsCompleted == 1)
        #expect(output.totalSubgoals == 1)
        #expect(output.terminationReason?.contains("completed") == true)
        #expect(synthesizer.recordedActions.count == 1)
        #expect(synthesizer.recordedActions.first?.contains("click") == true)
    }

    @Test("Live MCP action without an approval presenter fails before input dispatch")
    func testAutonomousActRequiresPresenter() async throws {
        let mockStore = MockContextStore()
        let candidate = UIElementCandidate(id: "search_btn", role: "AXButton", label: "Search",
                                           bounds: CGRect(x: 100, y: 100, width: 50, height: 30))
        let inspector = MockMCPSnapshotProvider(snapshot: UIStateSnapshot(
            windowTitle: "Owned fixture", visibleCandidates: [candidate]))
        let evaluator = MockMCPTypeSafeEvaluator.sequence([
            (target: candidate.id, action: "click", confidence: 0.95, isCompleted: 0.0)
        ])
        let synthesizer = MCPGuardedInputRecorder()
        let customFactory: AutonomousCoordinatorFactory = { config, _ in
            return TwoTierAutonomousLoopCoordinator(
                planner: MockSystem2Planner(subgoals: [Subgoal(description: "Click Search", expectedOutcome: "Opened")]),
                decisionEngine: TypeSafeDecisionEngine(client: evaluator),
                synthesizer: synthesizer,
                snapshotProvider: inspector,
                config: config
            )
        }
        let result = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Click Search"), "dry_run": .bool(false)],
            store: mockStore,
            coordinatorFactory: customFactory
        )
        // main's outer MCP gate refuses before constructing/observing a coordinator.
        #expect(result.contains("approval_required"))
        #expect(result.contains("'autonomous_act' was NOT run"))
        #expect(await evaluator.evaluationCount == 0)
        #expect(synthesizer.inputCount == 0)

        // Explicit MCP opt-in still cannot dispatch raw input without a chat presenter.
        let optedIn = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("Click Search"), "dry_run": .bool(false)],
            store: mockStore, coordinatorFactory: customFactory,
            approver: AutoApproveToolApprover())
        let output = try JSONDecoder().decode(AutonomousActOutput.self, from: Data(optedIn.utf8))
        #expect(!output.isSuccess)
        #expect(output.summary.contains("approval_required"))
        #expect(output.subgoalsCompleted == 0)
        #expect(await evaluator.evaluationCount == 1)
        #expect(synthesizer.inputCount == 0)
    }

    @Test("Stopping the server or cancelling its caller cancels an in-flight MCP dispatch",
           arguments: [false, true])
    func testAutonomousActCancellationHandling(cancelCaller: Bool) async throws {
        let store = MockContextStore()
        let inspector = MCPPausedSnapshotProvider()
        let synthesizer = MCPGuardedInputRecorder()
        let evaluator = MockMCPTypeSafeEvaluator(answers: [:])
        let customFactory: AutonomousCoordinatorFactory = { config, _ in
            TwoTierAutonomousLoopCoordinator(
                planner: MockSystem2Planner(subgoals: [Subgoal(description: "Click Search", expectedOutcome: "Opened")]),
                decisionEngine: TypeSafeDecisionEngine(client: evaluator),
                synthesizer: synthesizer, snapshotProvider: inspector, config: config)
        }
        let server = ContextMCPServer(store: store, coordinatorFactory: customFactory)
        let task = Task {
            do {
                let result = try await ContextMCPServer.dispatch(
                    name: "autonomous_act",
                    arguments: ["goal": .string("Click Search"), "dry_run": .bool(false)],
                    store: store, coordinatorFactory: customFactory, serverInstance: server,
                    approver: AutoApproveToolApprover())
                await inspector.finish(.success(result))
            } catch { await inspector.finish(.failure(error)) }
        }
        defer { task.cancel() }
        let result: String
        do {
            try await inspector.waitUntilStarted()
            if cancelCaller { task.cancel() }
            else { await server.stop() }
            // A late observation must not restart the cancelled dispatch.
            await inspector.release()
            result = try await inspector.waitForOutput()
        } catch {
            task.cancel()
            await inspector.release()
            throw error
        }
        let output = try JSONDecoder().decode(AutonomousActOutput.self, from: Data(result.utf8))
        #expect(!output.isSuccess)
        #expect(output.terminationReason == "cancelled")
        #expect(output.totalSteps == 0)
        #expect(output.subgoalsCompleted == 0)
        #expect(await evaluator.evaluationCount == 0)
        #expect(synthesizer.inputCount == 0)
    }

    @Test("An MCP dispatch ending before observation fails the start wait instead of hanging")
    func earlyDispatchExitDoesNotHang() async throws {
        let inspector = MCPPausedSnapshotProvider()
        let result = try await ContextMCPServer.dispatch(
            name: "autonomous_act", arguments: ["goal": .string("   ")], store: MockContextStore())
        #expect(result.contains("cannot be empty"))
        await inspector.finish(.success(result))
        await #expect(throws: MCPPausedSnapshotProvider.WaitError.finishedBeforeObservation) {
            try await inspector.waitUntilStarted()
        }
        // Cleanup before observation is safe too: it must not leave a later waiter suspended.
        await inspector.release()
        _ = try await inspector.captureSnapshot()
    }

    @Test("ContextMCPServer stop cleans up active tokens")
    func testContextMCPServerStopCancellation() async throws {
        let mockStore = MockContextStore()
        let server = ContextMCPServer(store: mockStore)

        let token = CancellationToken()
        let id = ObjectIdentifier(token)
        server.registerActiveToken(token, id: id)

        #expect(!token.isCancelled)

        await server.stop()

        #expect(token.isCancelled)
    }
}
