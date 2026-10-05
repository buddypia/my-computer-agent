import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

// MARK: - Mock TypeSafe Evaluator

/// Thread-safe, scriptable in-memory mock for TypeSafe System One Jev evaluations.
public final class MockTypeSafeEvaluator: TypeSafeEvaluating, @unchecked Sendable {
    public typealias EvaluationHandler = @Sendable (TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse

    private var handler: EvaluationHandler
    private let lock = NSLock()
    private var _recordedRequests: [TypeSafeClient.EvaluationRequest] = []

    public var recordedRequests: [TypeSafeClient.EvaluationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedRequests
    }

    public init(handler: @escaping EvaluationHandler) {
        self.handler = handler
    }

    private func recordRequest(_ request: TypeSafeClient.EvaluationRequest) {
        lock.lock()
        defer { lock.unlock() }
        _recordedRequests.append(request)
    }

    public func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
        recordRequest(request)
        return try await handler(request)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _recordedRequests.removeAll()
    }

    /// Convenience builder for deterministic scripted responses.
    public static func scripted(
        targetChoice: String? = nil,
        targetConfidence: Float = 0.95,
        actionChoice: String? = "click",
        actionConfidence: Float? = nil,
        isCompletedProbability: Float = 0.0,
        textInput: String? = nil,
        keyCombination: String? = nil,
        scrollDelta: String? = nil,
        error: Error? = nil
    ) -> MockTypeSafeEvaluator {
        MockTypeSafeEvaluator { _ in
            if let error = error {
                throw error
            }

            var answers: [String: TypeSafeClient.AnswerPayload] = [:]

            if let targetChoice = targetChoice {
                answers["target_element"] = TypeSafeClient.AnswerPayload(
                    type: "choice",
                    choice: targetChoice,
                    confidence: targetConfidence
                )
            }

            if let actionChoice = actionChoice {
                answers["action_type"] = TypeSafeClient.AnswerPayload(
                    type: "choice",
                    choice: actionChoice,
                    confidence: actionConfidence ?? targetConfidence
                )
            }

            answers["is_completed"] = TypeSafeClient.AnswerPayload(
                type: "noul",
                noul: isCompletedProbability
            )

            if let text = textInput {
                answers["text_input"] = TypeSafeClient.AnswerPayload(
                    type: "choice",
                    choice: text,
                    confidence: 0.95
                )
            }

            if let keys = keyCombination {
                answers["key_combination"] = TypeSafeClient.AnswerPayload(
                    type: "choice",
                    choice: keys,
                    confidence: 0.95
                )
            }

            if let scroll = scrollDelta {
                answers["scroll_delta"] = TypeSafeClient.AnswerPayload(
                    type: "choice",
                    choice: scroll,
                    confidence: 0.95
                )
            }

            return TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: answers,
                usage: TypeSafeClient.UsagePayload(inputTokens: 12, outputTokens: 6)
            )
        }
    }
}

// MARK: - Test Suite

@Suite("TypeSafeDecisionEngine Tests: Jev Micro-Grounding & Action Extension")
struct TypeSafeDecisionEngineTests {

    // MARK: - Test Helpers

    private func makeCandidates() -> [UIElementCandidate] {
        [
            UIElementCandidate(
                id: "btn_search",
                role: "AXButton",
                label: "Search",
                bounds: CGRect(x: 100, y: 50, width: 80, height: 32)
            ),
            UIElementCandidate(
                id: "field_query",
                role: "AXTextField",
                label: "Query",
                value: "",
                bounds: CGRect(x: 200, y: 50, width: 250, height: 32)
            ),
            UIElementCandidate(
                id: "scroll_results",
                role: "AXScrollArea",
                label: "Results View",
                bounds: CGRect(x: 100, y: 120, width: 600, height: 400)
            ),
            UIElementCandidate(
                id: "btn_cancel",
                role: "AXButton",
                label: "Cancel",
                bounds: CGRect(x: 720, y: 50, width: 80, height: 32)
            ),
        ]
    }

    // MARK: - 1. Mock Judgment Pipeline & Request Verification

    @Test("decideNextAction dispatches structured state and questions to TypeSafe model")
    func testMockPipelineDispatchesCorrectPayload() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "btn_search",
            targetConfidence: 0.96,
            actionChoice: "click"
        )
        let engine = TypeSafeDecisionEngine(client: mock, confidenceThreshold: 0.80)
        let candidates = makeCandidates()

        let decision = try await engine.decideNextAction(
            goal: "Click search button",
            activeApp: "Safari",
            candidates: candidates
        )

        // Verify request was captured
        #expect(mock.recordedRequests.count == 1)
        let req = mock.recordedRequests[0]
        #expect(req.model == "jev-latest")

        // Verify questions
        #expect(req.questions["target_element"] != nil)
        #expect(req.questions["action_type"] != nil)
        #expect(req.questions["is_completed"] != nil)

        // Verify decision outcome
        #expect(decision.targetElementId == "btn_search")
        #expect(decision.action == .click)
        #expect(decision.confidence == 0.96)
        #expect(decision.targetCenter == CGPoint(x: 140, y: 66))
        #expect(!decision.isCompleted)
    }

    // MARK: - 2. Candidate Selection & Micro-Grounding

    @Test("Candidate center coordinate and ID correctly mapped from Jev selection")
    func testCandidateSelectionGrounding() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "field_query",
            targetConfidence: 0.92,
            actionChoice: "click"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let candidates = makeCandidates()

        let decision = try await engine.decideNextAction(
            goal: "Focus query input field",
            activeApp: "Google Chrome",
            candidates: candidates
        )

        #expect(decision.targetElementId == "field_query")
        #expect(decision.coordinates == CGPoint(x: 325, y: 66))
        #expect(decision.targetCenter == CGPoint(x: 325, y: 66))
        #expect(decision.confidence == 0.92)
    }

    // MARK: - 3. Action Type Classification & Parameter Extraction

    @Test("Classifies .click action accurately")
    func testActionClassificationClick() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", actionChoice: "click")
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Click Search", candidates: makeCandidates())

        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_search")
    }

    @Test("Classifies .doubleClick action accurately")
    func testActionClassificationDoubleClick() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", actionChoice: "double_click")
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Double click Search", candidates: makeCandidates())

        #expect(decision.action == .doubleClick)
    }

    @Test("Classifies .rightClick action accurately")
    func testActionClassificationRightClick() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "scroll_results", actionChoice: "right_click")
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Right click for context menu", candidates: makeCandidates())

        #expect(decision.action == .rightClick)
    }

    @Test("Classifies .typeText action with bound text input parameter")
    func testActionClassificationTypeText() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "field_query",
            targetConfidence: 0.94,
            actionChoice: "type",
            textInput: "Agentic Autonomous Loop"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(
            goal: "Type 'Agentic Autonomous Loop' into query",
            candidates: makeCandidates()
        )

        #expect(decision.action == .typeText)
        #expect(decision.targetElementId == "field_query")
        #expect(decision.textInput == "Agentic Autonomous Loop")
    }

    @Test("Classifies .keyPress action with key combination parameter")
    func testActionClassificationKeyPress() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "field_query",
            targetConfidence: 0.95,
            actionChoice: "key",
            keyCombination: "command,return"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(
            goal: "Press Command+Return to submit query",
            candidates: makeCandidates()
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination != nil)
        #expect(decision.keyCombination?.contains("command") == true || decision.keyCombination?.contains("return") == true)
    }

    @Test("Classifies .scroll action with directional scroll delta vector")
    func testActionClassificationScroll() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "scroll_results",
            targetConfidence: 0.91,
            actionChoice: "scroll",
            scrollDelta: "0,-300"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(
            goal: "Scroll down the results list",
            candidates: makeCandidates()
        )

        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == "scroll_results")
        #expect(decision.scrollDelta != nil)
        #expect((decision.scrollDelta?.dy ?? 0) < 0) // Negative delta indicates downward scroll
    }

    @Test("Classifies .wait action accurately")
    func testActionClassificationWait() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "scroll_results",
            actionChoice: "wait"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Wait for results to finish rendering", candidates: makeCandidates())

        #expect(decision.action == .wait)
    }

    // MARK: - 4. Confidence Thresholding & Low Confidence Triggers

    @Test("Low confidence judgment (<0.80) preserves confidence value for System 2 escalation")
    func testLowConfidenceTrigger() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "btn_search",
            targetConfidence: 0.65, // Below default 0.80 threshold
            actionChoice: "click"
        )
        let engine = TypeSafeDecisionEngine(client: mock, confidenceThreshold: 0.80)
        let decision = try await engine.decideNextAction(goal: "Maybe click search?", candidates: makeCandidates())

        #expect(decision.confidence == 0.65)
        #expect(decision.confidence < engine.confidenceThreshold, "Confidence below 0.80 must trigger escalation signal")
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Boundary testing for confidence threshold (0.79 vs 0.80 vs 0.81)")
    func testConfidenceThresholdBoundaries() async throws {
        // Case 1: 0.79 -> Below threshold (Escalation)
        let mock79 = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", targetConfidence: 0.79)
        let engine = TypeSafeDecisionEngine(client: mock79, confidenceThreshold: 0.80)
        let d79 = try await engine.decideNextAction(goal: "Test", candidates: makeCandidates())
        #expect(d79.confidence < engine.confidenceThreshold)
        #expect(engine.shouldEscalate(decision: d79))

        // Case 2: 0.80 -> At threshold (Accepted)
        let mock80 = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", targetConfidence: 0.80)
        let engine80 = TypeSafeDecisionEngine(client: mock80, confidenceThreshold: 0.80)
        let d80 = try await engine80.decideNextAction(goal: "Test", candidates: makeCandidates())
        #expect(d80.confidence >= engine80.confidenceThreshold)
        #expect(!engine80.shouldEscalate(decision: d80))

        // Case 3: 0.81 -> Above threshold (Accepted)
        let mock81 = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", targetConfidence: 0.81)
        let engine81 = TypeSafeDecisionEngine(client: mock81, confidenceThreshold: 0.80)
        let d81 = try await engine81.decideNextAction(goal: "Test", candidates: makeCandidates())
        #expect(d81.confidence >= engine81.confidenceThreshold)
        #expect(!engine81.shouldEscalate(decision: d81))
    }

    @Test("Custom configurable confidence threshold is strictly respected")
    func testCustomConfidenceThreshold() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", targetConfidence: 0.88)
        let strictEngine = TypeSafeDecisionEngine(client: mock, confidenceThreshold: 0.95)
        let decision = try await strictEngine.decideNextAction(goal: "Test strict", candidates: makeCandidates())

        #expect(decision.confidence == 0.88)
        #expect(decision.confidence < strictEngine.confidenceThreshold, "0.88 must be below strict 0.95 threshold")
        #expect(strictEngine.shouldEscalate(decision: decision))
    }

    // MARK: - 5. Empty Candidates Fallback

    @Test("Empty candidate list triggers immediate low-confidence fallback for escalation")
    func testEmptyCandidatesFallback() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "none", targetConfidence: 0.0)
        let engine = TypeSafeDecisionEngine(client: mock, confidenceThreshold: 0.80)

        let decision = try await engine.decideNextAction(
            goal: "Click Submit",
            activeApp: "Safari",
            candidates: []
        )

        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter == nil)
        #expect(!decision.isCompleted)
        #expect(decision.confidence < engine.confidenceThreshold, "Empty candidate list must not return high confidence")
        #expect(engine.shouldEscalate(decision: decision))
        #expect(mock.recordedRequests.isEmpty, "Should return immediately without invoking external API")
    }

    // MARK: - 6. Goal Completion Detection

    @Test("Jev is_completed >= 0.70 returns completed decision immediately")
    func testGoalCompletionDetected() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "none",
            isCompletedProbability: 0.88
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(
            goal: "Check if form submitted",
            candidates: makeCandidates()
        )

        #expect(decision.isCompleted)
        #expect(decision.action == .none)
        #expect(decision.confidence == 0.88)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    // MARK: - 7. Deterministic Fallback on Network / API Failure

    @Test("Engine falls back to local heuristic grounding when TypeSafe API fails")
    func testLocalDeterministicFallbackOnAPIFailure() async throws {
        let failingMock = MockTypeSafeEvaluator.scripted(
            error: TypeSafeClient.ClientError.httpError(status: 503, message: "Service Unavailable")
        )
        let engine = TypeSafeDecisionEngine(client: failingMock)
        let candidates = makeCandidates()

        let decision = try await engine.decideNextAction(
            goal: "Click Search button",
            activeApp: "Safari",
            candidates: candidates
        )

        // Must succeed without throwing and resolve btn_search via semantic fallback
        #expect(decision.targetElementId == "btn_search")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    // MARK: - 8. Adversarial Edge Cases

    @Test("Handles hallucinated candidate ID from model safely")
    func testHallucinatedCandidateIDHandledSafely() async throws {
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "ghost_element_999", // Does not exist in candidate list
            targetConfidence: 0.95,
            actionChoice: "click"
        )
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Click phantom", candidates: makeCandidates())

        // Must defensively fall back to none rather than crashing with index out of bounds
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter == nil)
    }

    @Test("Handles missing or corrupted answers gracefully")
    func testMissingAnswersHandledSafely() async throws {
        let mock = MockTypeSafeEvaluator { _ in
            TypeSafeClient.EvaluationResponse(
                model: "jev-mock",
                answers: [:], // Empty answers dictionary
                usage: nil
            )
        }
        let engine = TypeSafeDecisionEngine(client: mock)
        let decision = try await engine.decideNextAction(goal: "Test empty response", candidates: makeCandidates())

        #expect(decision.action == .none)
        #expect(decision.confidence == 0.0)
    }

    @Test("Handles Unicode, Japanese, and emoji goals safely")
    func testUnicodeAndEmojiGoalHandling() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "btn_search", actionChoice: "click")
        let engine = TypeSafeDecisionEngine(client: mock)

        let complexGoal = "🔎 「検索」ボタンをクリックして検索結果を表示する 🚀 — [Test]"
        let decision = try await engine.decideNextAction(goal: complexGoal, candidates: makeCandidates())

        #expect(decision.targetElementId == "btn_search")
        #expect(mock.recordedRequests.count == 1)
    }

    @Test("Stress test: handles large candidate list (1,000 candidates) within memory bounds")
    func testLargeCandidateListPerformance() async throws {
        var largeCandidates: [UIElementCandidate] = []
        for i in 0..<1000 {
            largeCandidates.append(
                UIElementCandidate(
                    id: "elem_\(i)",
                    role: "AXButton",
                    label: "Button \(i)",
                    bounds: CGRect(x: Double(i % 10) * 100, y: Double(i / 10) * 40, width: 90, height: 35)
                )
            )
        }

        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "elem_542", actionChoice: "click")
        let engine = TypeSafeDecisionEngine(client: mock)

        let decision = try await engine.decideNextAction(goal: "Click Button 542", candidates: largeCandidates)

        #expect(decision.targetElementId == "elem_542")
        #expect(decision.targetCenter != nil)
    }

    // MARK: - 9. Custom Evaluator Closure & Parameter Extraction Tests

    @Test("decideNextAction handles mock Jev response for click via closure")
    func testDecideNextActionMockClick() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_ok", confidence: 0.95),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "click", confidence: 0.98),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.05)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "btn_ok", role: "AXButton", label: "OK", bounds: CGRect(x: 100, y: 200, width: 80, height: 30))
        ]

        let decision = try await engine.decideNextAction(goal: "Click OK", candidates: candidates)
        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_ok")
        #expect(decision.targetCenter == CGPoint(x: 140, y: 215))
        #expect(decision.confidence == 0.95)
        #expect(!decision.isCompleted)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction handles mock Jev response for scroll with delta via closure")
    func testDecideNextActionMockScroll() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "none", confidence: 0.85),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "scroll", confidence: 0.92),
                    "scroll_direction": TypeSafeClient.AnswerPayload(type: "choice", choice: "down", confidence: 0.90),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.10)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "scroll_area", role: "AXScrollArea", label: "Timeline", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]

        let decision = try await engine.decideNextAction(goal: "Scroll down to see tweets", candidates: candidates)
        #expect(decision.action == .scroll)
        #expect(decision.scrollDelta != nil)
        #expect(decision.scrollDelta?.dy == -5.0)
        #expect(decision.confidence == 0.92)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction handles mock Jev response for key press with combination via closure")
    func testDecideNextActionMockKeyPress() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "none", confidence: 0.88),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "key", confidence: 0.95),
                    "key_target": TypeSafeClient.AnswerPayload(type: "choice", choice: "return", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.05)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "search_input", role: "AXTextField", label: "Search", bounds: CGRect(x: 10, y: 10, width: 200, height: 30))
        ]

        let decision = try await engine.decideNextAction(goal: "Press Enter to submit search", candidates: candidates)
        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["Return"])
        #expect(decision.confidence == 0.95)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction handles mock Jev response for typeText with text binding via closure")
    func testDecideNextActionMockTypeText() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "input_email", confidence: 0.93),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "type", confidence: 0.96),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.02)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "input_email", role: "AXTextField", label: "Email Address", bounds: CGRect(x: 50, y: 100, width: 200, height: 30))
        ]

        let decision = try await engine.decideNextAction(goal: "Type 'user@test.com' into the Email Address field", candidates: candidates)
        #expect(decision.action == .typeText)
        #expect(decision.targetElementId == "input_email")
        #expect(decision.textInput == "user@test.com")
        #expect(decision.confidence == 0.93)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction detects goal completion via Jev Noul probability via closure")
    func testDecideNextActionMockCompletion() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "none", confidence: 0.90),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "none", confidence: 0.95),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.88)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "msg_success", role: "AXStaticText", label: "Payment Successful", bounds: CGRect(x: 100, y: 100, width: 300, height: 40))
        ]

        let decision = try await engine.decideNextAction(goal: "Complete the payment", candidates: candidates)
        #expect(decision.isCompleted)
        #expect(decision.action == .none)
        #expect(decision.confidence == 0.88)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction triggers escalation when Jev confidence is below threshold via closure")
    func testDecideNextActionConfidenceBelowThreshold() async throws {
        let customEvaluator: TypeSafeDecisionEngine.Evaluator = { req in
            TypeSafeClient.EvaluationResponse(
                model: "jev-latest",
                answers: [
                    "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_maybe", confidence: 0.65),
                    "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "click", confidence: 0.70),
                    "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.10)
                ],
                usage: nil
            )
        }

        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80, customEvaluator: customEvaluator)
        let candidates = [
            UIElementCandidate(id: "btn_maybe", role: "AXButton", label: "Maybe", bounds: CGRect(x: 50, y: 50, width: 60, height: 25))
        ]

        let decision = try await engine.decideNextAction(goal: "Click the confirmation button", candidates: candidates)
        #expect(decision.action == .click)
        #expect(decision.confidence == 0.65)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("extractCandidateTextSpans extracts double, single, and Japanese quotes")
    func testExtractCandidateTextSpansQuotes() {
        let text1 = "Type \"admin123\" and 'backup_pass' or 「ひらがな」"
        let spans1 = TypeSafeDecisionEngine.extractCandidateTextSpans(from: text1)
        #expect(spans1.contains("admin123"))
        #expect(spans1.contains("backup_pass"))
        #expect(spans1.contains("ひらがな"))

        let text2 = "query: tokyo weather"
        let spans2 = TypeSafeDecisionEngine.extractCandidateTextSpans(from: text2)
        #expect(spans2.contains("tokyo"))
    }

    @Test("extractKeyCombination extracts chord shortcuts and named keys")
    func testExtractKeyCombination() {
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press cmd+c to copy") == ["cmd", "c"])
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press Return to submit") == ["Return"])
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press Escape") == ["Escape"])
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press Tab") == ["Tab"])
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press", jevChoice: "space") == ["Space"])
    }

    @Test("extractScrollDelta parses direction and magnitude accurately")
    func testExtractScrollDelta() {
        let deltaDown = TypeSafeDecisionEngine.extractScrollDelta(from: "Scroll down")
        #expect(deltaDown.dy == -5.0)
        #expect(deltaDown.dx == 0.0)

        let deltaUp = TypeSafeDecisionEngine.extractScrollDelta(from: "Scroll up to top")
        #expect(deltaUp.dy == 5.0)

        let deltaFastDown = TypeSafeDecisionEngine.extractScrollDelta(from: "Fast scroll page down")
        #expect(deltaFastDown.dy == -15.0)

        let deltaRight = TypeSafeDecisionEngine.extractScrollDelta(from: "Scroll right")
        #expect(deltaRight.dx == 5.0)
    }

    @Test("fallbackLocalDecision handles offline scroll, keypress, and type actions")
    func testFallbackLocalDecisionAllActions() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "txt_search", role: "AXTextField", label: "Search Field", bounds: CGRect(x: 10, y: 10, width: 200, height: 30)),
            UIElementCandidate(id: "btn_submit", role: "AXButton", label: "Submit", bounds: CGRect(x: 220, y: 10, width: 80, height: 30))
        ]

        // Scroll
        let scrollDecision = engine.fallbackLocalDecision(goal: "ブラウザをスクロールして下を見て", candidates: candidates)
        #expect(scrollDecision.action == .scroll)
        #expect(scrollDecision.scrollDelta?.dy == -5.0)
        #expect(scrollDecision.confidence >= 0.80)

        // Key
        let keyDecision = engine.fallbackLocalDecision(goal: "Press Return to submit", candidates: candidates)
        #expect(keyDecision.action == .keyPress)
        #expect(keyDecision.keyCombination == ["Return"])
        #expect(keyDecision.confidence >= 0.80)

        // Type
        let typeDecision = engine.fallbackLocalDecision(goal: "Type 'Swift 6' into Search Field", candidates: candidates)
        #expect(typeDecision.action == .typeText)
        #expect(typeDecision.targetElementId == "txt_search")
        #expect(typeDecision.textInput == "Swift 6")
        #expect(typeDecision.confidence >= 0.80)

        // A statement in the goal does not prove an observed outcome.
        let compDecision = engine.fallbackLocalDecision(goal: "作業が完了しました", candidates: candidates)
        #expect(!compDecision.isCompleted)
        #expect(compDecision.action == .none)
        #expect(engine.shouldEscalate(decision: compDecision))

        // Empty candidates
        let emptyDecision = engine.fallbackLocalDecision(goal: "Click Submit", candidates: [])
        #expect(emptyDecision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: emptyDecision))
    }

    // MARK: - 10. Existing Baseline Tests (Regression Safety)

    @Test("empty candidates return early with none action and no failure")
    func testEmptyCandidatesReturnsEarly() async throws {
        let engine = TypeSafeDecisionEngine()
        let decision = try await engine.decideNextAction(
            goal: "Click the Submit button",
            activeApp: "Safari",
            candidates: []
        )

        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter == nil)
        #expect(!decision.isCompleted)
    }

    @Test("UIElementCandidate calculates accurate center coordinate")
    func testCandidateCenterCalculation() {
        let candidate = UIElementCandidate(
            id: "btn_1",
            role: "AXButton",
            label: "OK",
            bounds: CGRect(x: 100, y: 200, width: 80, height: 40)
        )

        #expect(candidate.center == CGPoint(x: 140, y: 220))
    }

    @Test("ComputerActionDecision serializes and deserializes accurately")
    func testDecisionSerialization() throws {
        let original = ComputerActionDecision(
            targetElementId: "elem_42",
            action: .click,
            confidence: 0.95,
            isCompleted: false,
            targetCenter: CGPoint(x: 350, y: 500),
            textInput: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: data)

        #expect(decoded.targetElementId == original.targetElementId)
        #expect(decoded.action == original.action)
        #expect(decoded.confidence == original.confidence)
        #expect(decoded.targetCenter == original.targetCenter)
    }

    @Test("fallbackLocalDecision matches candidate by label when API is unconfigured")
    func testFallbackLocalDecision() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(
                id: "btn_search",
                role: "AXButton",
                label: "Search",
                bounds: CGRect(x: 200, y: 100, width: 60, height: 30)
            ),
            UIElementCandidate(
                id: "btn_cancel",
                role: "AXButton",
                label: "Cancel",
                bounds: CGRect(x: 300, y: 100, width: 60, height: 30)
            ),
        ]

        let decision = engine.fallbackLocalDecision(goal: "Please click the Search button", candidates: candidates)
        #expect(decision.targetElementId == "btn_search")
        #expect(decision.action == .click)
        #expect(decision.targetCenter == CGPoint(x: 230, y: 115))
        #expect(decision.confidence > 0.8)
    }

    @Test("CredentialStore supports typesafe provider")
    func testCredentialStoreTypesafeProvider() {
        #expect(CredentialStore.environmentVariables(for: "typesafe") == ["TYPESAFE_API_KEY"])
        let store = CredentialStore(overrides: ["typesafe": "test-key-123"])
        #expect(store.key(for: "typesafe") == "test-key-123")
        #expect(store.source(for: "typesafe") == .override)
        #expect(store.availableProviders().contains("typesafe"))
    }

    @Test("triageGoal classifies browser scroll and search request accurately")
    func testTriageGoalBrowserScroll() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(goal: "ブラウザーをスクロールしてTwitterの3K以上を探して", activeApp: "Google Chrome")
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "browser_scroll_or_search")
        #expect(triage.suggestedPlan != nil)
        #expect(triage.suggestedPlan?.contains("スクロール") == true)
    }

    @Test("triageGoal classifies GUI click and interaction accurately")
    func testTriageGoalGuiClick() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(goal: "送信ボタンをクリックして", activeApp: "Safari")
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "gui_interaction")
    }

    @Test("triageGoal returns conversational for general QA")
    func testTriageGoalConversational() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(goal: "今日の東京の天気は？", activeApp: "Finder")
        #expect(!triage.needsComputerAction)
        #expect(triage.intentCategory == "pure_qa")
    }

    @Test("triageGoal classifies file search and open accurately")
    func testTriageGoalFileSearchAndOpen() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(goal: "デスクトップのメモファイルを探して開いて", activeApp: "Finder")
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "file_search_and_open")
        #expect(triage.suggestedPlan != nil)
    }

    @Test("triageGoal classifies file open and text entry accurately")
    func testTriageGoalFileTextEntry() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(goal: "ファイルを開いて文字を入力して保存して", activeApp: "TextEdit")
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "file_text_entry")
        #expect(triage.suggestedPlan?.contains("テキストの入力") == true)
    }

    @Test("triageGoal classifies pinned background scroll collection request accurately")
    func testTriageGoalPinnedBackgroundScroll() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(
            goal: "FirefoxをPin留めして見守り中でスクロールして情報を収集しろ",
            activeApp: "Google Chrome"
        )
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "browser_scroll_or_search")
        #expect(triage.suggestedPlan?.contains("バックグラウンド") == true || triage.suggestedPlan?.contains("自律収集") == true)
    }

    @Test("triageGoal classifies Firefox browser action and search accurately")
    func testTriageGoalFirefoxAction() async {
        let engine = TypeSafeDecisionEngine()
        let triage = await engine.triageGoal(
            goal: "Firefoxを操作してAI最新動向を検索して調べて",
            activeApp: "Firefox"
        )
        #expect(triage.needsComputerAction)
        #expect(triage.intentCategory == "browser_scroll_or_search")
        #expect(triage.suggestedPlan?.contains("Firefox") == true)
    }

    // MARK: - Milestone 1: Fallback Grounding, Stagnation Adaptation, Token Matching & Recovery

    @Test("M1: fallbackLocalDecision grounds scroll action to AXScrollArea container")
    func testFallbackLocalDecisionScrollContainerGrounding() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "txt_search", role: "AXTextField", label: "Search", bounds: CGRect(x: 10, y: 10, width: 200, height: 30)),
            UIElementCandidate(id: "scroll_feed", role: "AXScrollArea", label: "Timeline Feed", bounds: CGRect(x: 100, y: 100, width: 600, height: 800)),
            UIElementCandidate(id: "btn_post", role: "AXButton", label: "Post", bounds: CGRect(x: 750, y: 10, width: 80, height: 30))
        ]

        let decision = engine.fallbackLocalDecision(goal: "タイムラインをスクロールして", candidates: candidates)
        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == "scroll_feed")
        #expect(decision.targetCenter == CGPoint(x: 400, y: 500))
        #expect(decision.coordinates == CGPoint(x: 400, y: 500))
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: resolveScrollContainer scoring prioritizes goal match and container area")
    func testFallbackLocalDecisionScrollContainerScoringWeights() {
        let sidebar = UIElementCandidate(id: "sidebar", role: "AXScrollArea", label: "Sidebar Nav", bounds: CGRect(x: 0, y: 0, width: 100, height: 200))
        let mainFeed = UIElementCandidate(id: "main_feed", role: "AXScrollArea", label: "Main Feed", bounds: CGRect(x: 100, y: 0, width: 800, height: 600))

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(candidates: [sidebar, mainFeed], goal: "Scroll down feed")
        #expect(selected?.id == "main_feed")
    }

    @Test("M1: fallbackLocalDecision uses viewport center fallback when no container exists")
    func testFallbackLocalDecisionScrollFallbackCenter() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_1", role: "AXButton", label: "One", bounds: CGRect(x: 100, y: 100, width: 100, height: 50)),
            UIElementCandidate(id: "btn_2", role: "AXButton", label: "Two", bounds: CGRect(x: 300, y: 500, width: 100, height: 50))
        ]

        let decision = engine.fallbackLocalDecision(goal: "Scroll down", candidates: candidates)
        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter != nil)
        #expect(decision.targetCenter?.x == 250)
        #expect(decision.targetCenter?.y == 325)
    }

    @Test("M1: fallbackLocalDecision adapts stagnant scroll to keyboard PageDown")
    func testFallbackLocalDecisionStagnantScrollAdaptsToKeyPress() throws {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "c_scroll", role: "AXScrollArea", label: "Timeline", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        let priorScrollDecision = ComputerActionDecision(
            targetElementId: "c_scroll",
            action: .scroll,
            confidence: 0.85,
            isCompleted: false
        )
        let priorStep = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: priorScrollDecision)
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down the feed",
            candidates: candidates,
            history: [priorStep],
            lastDiff: unchangedDiff
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["PageDown"])
        #expect(decision.confidence >= 0.80)
        #expect(decision.isCompleted == false)
    }

    @Test("M1: fallbackLocalDecision adapts stagnant scroll upwards to PageUp")
    func testFallbackLocalDecisionStagnantScrollAdaptsToPageUp() throws {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "c_scroll", role: "AXScrollArea", label: "Timeline", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        let priorScrollDecision = ComputerActionDecision(
            targetElementId: "c_scroll",
            action: .scroll,
            confidence: 0.85,
            isCompleted: false
        )
        let priorStep = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: priorScrollDecision)
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll up the feed",
            candidates: candidates,
            history: [priorStep],
            lastDiff: unchangedDiff
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["PageUp"])
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: fallbackLocalDecision concludes subgoal when both scroll and keyboard nav are stagnant")
    func testFallbackLocalDecisionConcludesWhenAllNavStagnant() throws {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "c_scroll", role: "AXScrollArea", label: "Timeline", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        let priorScroll = LoopStepRecord(
            stepNumber: 1,
            subgoalId: "sg1",
            action: ComputerActionDecision(targetElementId: "c_scroll", action: .scroll, confidence: 0.85, isCompleted: false)
        )
        let priorKey = LoopStepRecord(
            stepNumber: 2,
            subgoalId: "sg1",
            action: ComputerActionDecision(targetElementId: "c_scroll", action: .keyPress, confidence: 0.85, isCompleted: false, keyCombination: ["PageDown"])
        )
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down the feed",
            candidates: candidates,
            history: [priorScroll, priorKey],
            lastDiff: unchangedDiff
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true)
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: fallbackLocalDecision adapts when recentEscalations contains actionStagnant")
    func testFallbackLocalDecisionAdaptsOnRecentEscalation() throws {
        let engine = TypeSafeDecisionEngine()
        let escalation = EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "Unchanged UI state"))

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down feed",
            candidates: [],
            recentEscalations: [escalation]
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["PageDown"])
    }

    @Test("M1: fallbackLocalDecision concludes subgoal when stagnation reaches high escalation risk")
    func testFallbackLocalDecisionConcludesOnHighEscalationRisk() throws {
        let engine = TypeSafeDecisionEngine()
        let escalations = [
            EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "Stagnant")),
            EscalationRecord(attempt: 2, reason: .actionStagnant(reason: "Stagnant"))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down feed",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true)
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: Token matching matches candidate when label has partial overlap")
    func testFallbackTokenMatchingLabelOverlap() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_submit", role: "AXButton", label: "Submit Order", bounds: CGRect(x: 100, y: 100, width: 80, height: 30)),
            UIElementCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel", bounds: CGRect(x: 200, y: 100, width: 80, height: 30))
        ]
        let decision = engine.fallbackLocalDecision(goal: "Click the submit button", candidates: candidates)
        #expect(decision.targetElementId == "btn_submit")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: Token matching matches candidate by ID or Value when label is empty")
    func testFallbackTokenMatchingIdAndValue() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "search_input_box", role: "AXTextField", label: "", value: "Search query", bounds: CGRect(x: 50, y: 50, width: 200, height: 30))
        ]
        let decision = engine.fallbackLocalDecision(goal: "Search products in store", candidates: candidates)
        #expect(decision.targetElementId == "search_input_box")
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: Alternative interactive candidate selected on replan retry")
    func testFallbackAlternativeCandidateSelectedOnReplan() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_confirm", role: "AXButton", label: "Confirm", bounds: CGRect(x: 100, y: 100, width: 80, height: 30), isActionable: true)
        ]
        let escRecord = EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.60, threshold: 0.80))
        let decision = engine.fallbackLocalDecision(
            goal: "Interact with alternative interactive element for: click save",
            candidates: candidates,
            recentEscalations: [escRecord]
        )
        #expect(decision.targetElementId == "btn_confirm")
        #expect(decision.action == .click)
        #expect(decision.confidence == 0.80)
    }

    @Test("M1: Two low-confidence attempts keep an unmatched subgoal unresolved")
    func testFallbackCircuitBreakerPreventsThreeStrikeCrash() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_unrelated", role: "AXButton", label: "Unrelated", bounds: CGRect(x: 100, y: 100, width: 80, height: 30))
        ]
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.50, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.50, threshold: 0.80))
        ]
        let decision = engine.fallbackLocalDecision(
            goal: "Click non-existent phantom",
            candidates: candidates,
            recentEscalations: escalations
        )
        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("M1: Exploratory wait returned on render/wait goal")
    func testFallbackExploratoryWaitOnRenderGoal() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_unrelated", role: "AXButton", label: "Unrelated", bounds: CGRect(x: 100, y: 100, width: 80, height: 30))
        ]
        let decision = engine.fallbackLocalDecision(
            goal: "wait for ui to finish loading or rendering",
            candidates: candidates
        )
        #expect(decision.action == .wait)
        #expect(decision.confidence >= 0.80)
    }

    @Test("M1: Graduated diagnostic confidence returned on unmatched candidate")
    func testFallbackGraduatedDiagnosticConfidence() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_unrelated", role: "AXButton", label: "Unrelated", bounds: CGRect(x: 100, y: 100, width: 80, height: 30))
        ]
        let decision = engine.fallbackLocalDecision(
            goal: "Click rocket launch button",
            candidates: candidates
        )
        #expect(decision.action == .none)
        #expect(decision.confidence < 0.80)
        #expect(decision.confidence >= 0.20)
        #expect(decision.reasoning?.contains("visible elements") == true)
    }

    @Test("M1: fallbackLocalDecision backward compatibility without feedback parameters")
    func testFallbackLocalDecisionBackwardCompatibility() throws {
        let engine = TypeSafeDecisionEngine()
        let decision = engine.fallbackLocalDecision(goal: "scroll feed", candidates: [])

        #expect(decision.action == .scroll)
        #expect(decision.confidence >= 0.80)
        #expect(decision.isCompleted == false)
    }

    @Test("M1: decideNextAction catch block forwards feedback to fallbackLocalDecision")
    func testDecideNextActionForwardsFeedbackToFallback() async throws {
        struct FailingEvaluator: TypeSafeEvaluating {
            func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "API Offline"])
            }
        }

        let engine = TypeSafeDecisionEngine(client: FailingEvaluator())
        let candidates = [
            UIElementCandidate(id: "c_scroll", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        ]
        let escalation = EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "UI unchanged"))
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = try await engine.decideNextAction(
            goal: "Scroll feed down",
            activeApp: "Safari",
            candidates: candidates,
            history: [],
            recentEscalations: [escalation],
            lastDiff: unchangedDiff
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["PageDown"])
        #expect(decision.confidence >= 0.80)
    }

    // MARK: - M1 Remediation Verification Tests

    @Test("M1 Remediation: Repeated missing candidates cannot establish completion")
    func testRemediationEmptyCandidateCircuitBreaker() async throws {
        let engine = TypeSafeDecisionEngine()
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.20, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]

        let decision = try await engine.decideNextAction(
            goal: "Click anything",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("M1 Remediation: Short label 'OK' does not match interior substrings in words like 'Lookup'")
    func testRemediationShortLabelAnchoredMatching() {
        let engine = TypeSafeDecisionEngine()
        let candidate = UIElementCandidate(
            id: "btn_ok",
            role: "AXButton",
            label: "OK",
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            isActionable: true
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Lookup warehouse catalog",
            candidates: [candidate]
        )

        #expect(decision.targetElementId == nil)
        #expect(decision.confidence < 0.80)
    }

    @Test("M1 Remediation: Key keyword disambiguation prioritizes AXTab candidates over keyPress")
    func testRemediationKeyKeywordDisambiguation() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "tab_1", role: "AXTab", label: "Tab 1: Overview", bounds: CGRect(x: 0, y: 0, width: 100, height: 30), isActionable: true),
            UIElementCandidate(id: "tab_2", role: "AXTab", label: "Tab 2: Details", bounds: CGRect(x: 100, y: 0, width: 100, height: 30), isActionable: true)
        ]

        let dOverview = engine.fallbackLocalDecision(goal: "Select Tab 1", candidates: candidates)
        #expect(dOverview.targetElementId == "tab_1")
        #expect(dOverview.action == .click)

        // Verifies explicit key extraction still works
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Press Tab") == ["Tab"])
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Select Tab 1") == nil)
        #expect(TypeSafeDecisionEngine.extractKeyCombination(from: "Enter shipping address") == nil)
    }

    @Test("M1 Remediation: Japanese script boundary segmentation splits Katakana and Kanji roots cleanly")
    func testRemediationJapaneseScriptSegmentation() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_cart", role: "AXButton", label: "カートを見る", bounds: CGRect(x: 10, y: 10, width: 100, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_save", role: "AXButton", label: "保存", bounds: CGRect(x: 120, y: 10, width: 80, height: 40), isActionable: true)
        ]

        let tokens = TypeSafeDecisionEngine.extractTokens(from: "カートの中身を確認して")
        #expect(tokens.contains("カート"))
        #expect(tokens.contains("中身"))
        #expect(tokens.contains("確認"))
        #expect(!tokens.contains("の"))
        #expect(!tokens.contains("を"))
        #expect(!tokens.contains("して"))

        let decision = engine.fallbackLocalDecision(goal: "カートの中身を確認して", candidates: candidates)
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(engine.shouldEscalate(decision: decision))

        let numTokens = TypeSafeDecisionEngine.extractTokens(from: "タブ１")
        #expect(numTokens == ["1"])
    }

    @Test("goal wording never completes offline: neither completion reports nor UI labels saying Done")
    func testGoalWordingNeverCompletes() {
        let engine = TypeSafeDecisionEngine()
        let button = [UIElementCandidate(id: "btn-done", role: "AXButton", label: "Done", bounds: CGRect(x: 0, y: 0, width: 80, height: 30))]
        #expect(!engine.fallbackLocalDecision(goal: "入力が完了しました", candidates: button).isCompleted)
        #expect(!engine.fallbackLocalDecision(goal: "All fields typed, task completed", candidates: button).isCompleted)
        #expect(!engine.fallbackLocalDecision(goal: "Click the Done button", candidates: button).isCompleted)
    }

    @Test("scroll direction reads whole words, including next to kana")
    func testScrollDirectionWholeWords() {
        #expect(TypeSafeDecisionEngine.extractScrollDelta(from: "upにスクロール").dy > 0)
        #expect(TypeSafeDecisionEngine.extractScrollDelta(from: "下から上へスクロール").dy > 0)
        #expect(TypeSafeDecisionEngine.extractScrollDelta(from: "Scroll down to see the newest updates").dy < 0)
    }
}
