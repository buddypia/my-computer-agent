import CoreGraphics
import Foundation
import MCACore
import MCAPresentation
@testable import MCAReasoning
import MCASensing
@testable import mca
import Testing

// MARK: - Test Doubles

private final class CopilotMockSystem2Planner: System2Planning, @unchecked Sendable {
    let subgoals: [Subgoal]

    init(subgoals: [Subgoal] = []) {
        self.subgoals = subgoals
    }

    func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
        SubgoalPlan(goal: goal, subgoals: subgoals)
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

private actor CopilotMockTypeSafeEvaluator: TypeSafeEvaluating {
    private var responses: [TypeSafeClient.EvaluationResponse]

    init(responses: [TypeSafeClient.EvaluationResponse]) {
        self.responses = responses
    }

    init(answers: [String: TypeSafeClient.AnswerPayload] = [:]) {
        self.responses = [TypeSafeClient.EvaluationResponse(model: "jev-mock", answers: answers, usage: nil)]
    }

    static func sequence(_ steps: [(target: String?, action: String?, confidence: Float, isCompleted: Float)]) -> CopilotMockTypeSafeEvaluator {
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
        return CopilotMockTypeSafeEvaluator(responses: resps)
    }

    func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
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

private final class CopilotMockSnapshotProvider: UIStateProviding, @unchecked Sendable {
    let snapshot: UIStateSnapshot

    init(snapshot: UIStateSnapshot = UIStateSnapshot(visibleCandidates: [], timestamp: Date())) {
        self.snapshot = snapshot
    }

    func captureSnapshot() async throws -> UIStateSnapshot {
        snapshot
    }
}

@Suite("Copilot Autonomous Integration Tests: Intent Triage & Delegate Forwarding")
struct CopilotAutonomousIntegrationTests {

    // MARK: - 1. Autonomous Intent Triage

    @Test("Copilot decisionEngine triages GUI action intents vs informational questions")
    func testAutonomousIntentTriage() async throws {
        let engine = TypeSafeDecisionEngine()

        // 1. Action intent should require computer action
        let actionTriage = await engine.triageGoal(goal: "Click the Submit button and type Confirmation", activeApp: "Safari")
        #expect(actionTriage.needsComputerAction)

        // 2. Explicit /goal prefix
        let goalCommandTriage = await engine.triageGoal(goal: "/goal Download latest monthly sales report", activeApp: "Chrome")
        #expect(goalCommandTriage.needsComputerAction)

        // 3. Explicit /act prefix
        let actCommandTriage = await engine.triageGoal(goal: "/act click Next button", activeApp: "Finder")
        #expect(actCommandTriage.needsComputerAction)

        // 4. Conversational query should not trigger computer action
        let infoTriage = await engine.triageGoal(goal: "Explain the difference between synchronous and asynchronous code", activeApp: "Xcode")
        #expect(!infoTriage.needsComputerAction)

        // 5. Query asking to collect and summarize tweets while scrolling should be recognized as informational
        let tweetPrompt = "Xでビューが5K以上のTweetをまとめて教えて。スクロールしながら収集して"
        let tweetTriage = await engine.triageGoal(goal: tweetPrompt, activeApp: "Firefox")
        #expect(tweetTriage.needsComputerAction) // It does need computer action for scrolling/reading
        let isInformational = ScreenIntent.isInformationalRequest(tweetPrompt)
        #expect(isInformational) // BUT it is informational! So it should route to agent.answer, not pure autonomous GUI loop

        let shouldRunAutonomousLoop = !isInformational && tweetTriage.needsComputerAction && tweetTriage.confidence >= 0.80
        #expect(!shouldRunAutonomousLoop) // Must NOT bypass agent.answer
    }

    // MARK: - 2. Delegate Event Forwarding to HUDState

    @MainActor
    @Test("AutonomousLoopDelegate accurately forwards step progress and tokens to HUDState")
    func testDelegateEventForwardingToHUDState() async {
        let hudState = HUDState()
        hudState.tokenThrottleInterval = .zero
        let delegate = CopilotAutonomousLoopDelegate(hudState: hudState)

        hudState.beginStreaming(question: "Perform checkout")
        #expect(hudState.isStreaming)

        // 1. loopDidStart
        let subgoal1 = Subgoal(id: "sg_1", description: "Enter billing details", expectedOutcome: "Fields populated", maxSteps: 5)
        let plan = SubgoalPlan(goal: "Perform checkout", subgoals: [subgoal1])
        await delegate.loopDidStart(goal: "Perform checkout", initialPlan: plan)
        hudState.flushTokens()

        #expect(hudState.streamingText.contains("Perform checkout"))
        #expect(hudState.streamingText.contains("Enter billing details"))

        // 2. loopDidBeginSubgoal
        await delegate.loopDidBeginSubgoal(subgoal: subgoal1, index: 0, total: 1)
        hudState.flushTokens()
        #expect(hudState.streamingText.contains("Subgoal 1/1"))

        // 3. loopDidStep
        let action = ComputerActionDecision(action: .typeText, confidence: 0.95, textInput: "Visa Card")
        let diff = UIStateDiff(titleChanged: false, focusChanged: true)
        await delegate.loopDidStep(step: 1, subgoal: subgoal1, action: action, diff: diff)
        hudState.flushTokens()

        #expect(hudState.streamingText.contains("[Step 1]"))
        #expect(hudState.streamingText.contains("type"))
        #expect(hudState.streamingText.contains("Visa Card"))

        // 4. loopDidVerifyOutcome
        await delegate.loopDidVerifyOutcome(subgoal: subgoal1, result: StateVerificationResult(status: .verified, confidence: 1.0, rationale: "Success"))
        hudState.flushTokens()
        #expect(hudState.streamingText.contains("Verified outcome"))

        // 5. loopDidEscalate
        let resolution = try? await delegate.loopDidEscalate(reason: .lowConfidence(confidence: 0.5, threshold: 0.8), subgoal: subgoal1)
        #expect(resolution == nil)
        hudState.flushTokens()
        #expect(hudState.streamingText.contains("Escalation"))

        // 6. loopDidComplete
        let summary = ExecutionSummary(
            goal: "Perform checkout",
            isSuccess: true,
            totalSteps: 1,
            subgoalsCompleted: 1,
            totalSubgoals: 1,
            durationSeconds: 1.2,
            terminationReason: "Goal completed successfully."
        )
        await delegate.loopDidComplete(summary: summary)

        #expect(!hudState.isStreaming)
        // Verified final assistant message was created and preserves execution trace + completion summary
        let lastMsg = hudState.messages.last
        #expect(lastMsg?.text.contains("Goal Completed!") == true)
        #expect(lastMsg?.text.contains("Perform checkout") == true)
        #expect(lastMsg?.text.contains("[Step 1]") == true)
    }

    @MainActor
    @Test("AutonomousLoopDelegate presents HUDCard upon loopDidFail")
    func testDelegateFailurePresentsHUDCard() async {
        let hudState = HUDState()
        hudState.tokenThrottleInterval = .zero
        let delegate = CopilotAutonomousLoopDelegate(hudState: hudState)

        hudState.beginStreaming(question: "Failing Goal")

        let error = LoopExecutionError.stepBudgetExceeded(steps: 20)
        await delegate.loopDidFail(error: error)

        #expect(!hudState.isStreaming)
        // Verify failure notice card was added to messages
        let hasNotice = hudState.messages.contains { msg in
            msg.role == .notice && (msg.title?.contains("Halted") == true || msg.text.contains("step budget exceeded"))
        }
        #expect(hasNotice)
    }

    // MARK: - 3. End-to-End Autonomous Loop with HUDState

    @MainActor
    @Test("End-to-End TwoTierAutonomousLoopCoordinator streaming to HUDState")
    func testEndToEndAutonomousLoopWithHUD() async throws {
        let hudState = HUDState()
        hudState.tokenThrottleInterval = .zero
        let delegate = CopilotAutonomousLoopDelegate(hudState: hudState)

        hudState.beginStreaming(question: "Open settings")

        let subgoal = Subgoal(id: "sg_open", description: "Click gear icon", expectedOutcome: "Settings displayed", maxSteps: 3)
        let planner = CopilotMockSystem2Planner(subgoals: [subgoal])

        let candidate = UIElementCandidate(
            id: "gear_btn",
            role: "AXButton",
            label: "Settings",
            bounds: CGRect(x: 50, y: 50, width: 30, height: 30)
        )
        let snapshot = UIStateSnapshot(windowTitle: "Desktop", visibleCandidates: [candidate], timestamp: Date())
        let inspector = CopilotMockSnapshotProvider(snapshot: snapshot)

        let evaluator = CopilotMockTypeSafeEvaluator.sequence([
            (target: "gear_btn", action: "click", confidence: 0.95, isCompleted: 0.0),
            (target: nil, action: nil, confidence: 1.0, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let synthesizer = DryRunEventSynthesizer()

        var config = AutonomousLoopConfig.testing
        config.settlingDelayMs = 0

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config,
            delegate: delegate
        )

        let summary = try await coordinator.execute(goal: "Open settings")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 2)
        #expect(!hudState.isStreaming)
        #expect(synthesizer.recordedActions.count == 1)
    }
}
