import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Milestone 1 Challenger: Stagnation Adaptation, Circuit Breaker & Token Matching Stress Tests")
struct TypeSafeDecisionEngineMilestone1ChallengerTests {

    private func makeContainerCandidates() -> [UIElementCandidate] {
        [
            UIElementCandidate(
                id: "nav_bar",
                role: "AXGroup",
                label: "Navigation Bar",
                bounds: CGRect(x: 0, y: 0, width: 1000, height: 60)
            ),
            UIElementCandidate(
                id: "feed_scroll_view",
                role: "AXScrollArea",
                label: "Timeline Feed",
                bounds: CGRect(x: 100, y: 70, width: 800, height: 700)
            ),
            UIElementCandidate(
                id: "btn_post",
                role: "AXButton",
                label: "New Post",
                bounds: CGRect(x: 910, y: 15, width: 80, height: 30),
                isActionable: true
            )
        ]
    }

    // =========================================================================
    // SECTION 1: STAGNATION LADDER STRESS TESTING
    // =========================================================================

    @Test("Ladder: 3-step sequential transition from .scroll -> .keyPress(PageDown) -> .none(isCompleted: true)")
    func testStagnationLadderSequentialTransition() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let goal = "Scroll down the timeline feed"

        // Step 0: Initial action should be grounded .scroll
        let d0 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [],
            recentEscalations: [],
            lastDiff: nil
        )
        #expect(d0.action == .scroll)
        #expect(d0.targetElementId == "feed_scroll_view")
        #expect(d0.confidence >= 0.80)
        #expect(d0.isCompleted == false)

        let step0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: d0)

        // Step 1: First unchanged diff -> Adapts to .keyPress(PageDown)
        let d1 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [step0],
            recentEscalations: [],
            lastDiff: unchangedDiff
        )
        #expect(d1.action == .keyPress)
        #expect(d1.keyCombination == ["PageDown"])
        #expect(d1.confidence >= 0.80)
        #expect(d1.isCompleted == false)
        #expect(d1.targetCenter != nil, "KeyPress should preserve container target coordinates")

        let step1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

        // Step 2: Second unchanged diff after keyPress -> Concludes subgoal (.none, isCompleted: true)
        let d2 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [step0, step1],
            recentEscalations: [],
            lastDiff: unchangedDiff
        )
        #expect(d2.action == .none)
        #expect(d2.isCompleted == true)
        #expect(d2.confidence >= 0.80)
        #expect(engine.shouldEscalate(decision: d2) == false, "Completed conclusion must NOT escalate")
    }

    @Test("Ladder: Upward scroll stagnation adapts to PageUp then concludes")
    func testStagnationLadderUpwardScrollTransition() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let goal = "Scroll up to top of timeline feed"

        // Step 0: Initial scroll
        let d0 = engine.fallbackLocalDecision(goal: goal, candidates: candidates)
        #expect(d0.action == .scroll)
        #expect(d0.scrollDelta?.dy ?? 0 > 0, "Upward scroll must have positive dy")

        let step0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: d0)

        // Step 1: First unchanged -> PageUp
        let d1 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [step0],
            lastDiff: unchangedDiff
        )
        #expect(d1.action == .keyPress)
        #expect(d1.keyCombination == ["PageUp"])
        #expect(d1.isCompleted == false)

        let step1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

        // Step 2: Second unchanged -> Conclude
        let d2 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [step0, step1],
            lastDiff: unchangedDiff
        )
        #expect(d2.action == .none)
        #expect(d2.isCompleted == true)
    }

    @Test("Ladder: Japanese scroll goals adapt to PageDown/PageUp and conclude cleanly")
    func testStagnationLadderJapaneseGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

        // Downward: タイムラインを下にスクロール
        let downGoal = "タイムラインを下にスクロールして情報を確認する"
        let dDown0 = engine.fallbackLocalDecision(goal: downGoal, candidates: candidates)
        #expect(dDown0.action == .scroll)
        let sDown0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: dDown0)

        let dDown1 = engine.fallbackLocalDecision(goal: downGoal, candidates: candidates, history: [sDown0], lastDiff: unchangedDiff)
        #expect(dDown1.action == .keyPress)
        #expect(dDown1.keyCombination == ["PageDown"])

        let sDown1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: dDown1)
        let dDown2 = engine.fallbackLocalDecision(goal: downGoal, candidates: candidates, history: [sDown0, sDown1], lastDiff: unchangedDiff)
        #expect(dDown2.action == .none)
        #expect(dDown2.isCompleted == true)

        // Upward: 上へ戻るようにスクロール
        let upGoal = "上へ戻るようにスクロールして"
        let dUp0 = engine.fallbackLocalDecision(goal: upGoal, candidates: candidates)
        #expect(dUp0.action == .scroll)
        let sUp0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg2", action: dUp0)

        let dUp1 = engine.fallbackLocalDecision(goal: upGoal, candidates: candidates, history: [sUp0], lastDiff: unchangedDiff)
        #expect(dUp1.action == .keyPress)
        #expect(dUp1.keyCombination == ["PageUp"])
    }

    @Test("Ladder: Multi-step simulated stagnation loop terminates cleanly without infinite cycle")
    func testStagnationLadderExtendedSimulationLoopTerminates() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let goal = "Scroll down the feed"

        var history: [LoopStepRecord] = []
        var completedAtStep: Int? = nil

        for step in 0..<10 {
            let decision = engine.fallbackLocalDecision(
                goal: goal,
                candidates: candidates,
                history: history,
                recentEscalations: [],
                lastDiff: step == 0 ? nil : unchangedDiff
            )

            history.append(LoopStepRecord(stepNumber: step, subgoalId: "sg_sim", action: decision))

            if decision.isCompleted {
                completedAtStep = step
                break
            }
        }

        #expect(completedAtStep != nil, "Extended simulation loop MUST terminate with completion")
        #expect(completedAtStep == 2, "Completion must happen on Step 2 (after .scroll and .keyPress)")
    }

    @Test("Ladder: Resumes .scroll if keyboard navigation successfully breaks stagnation (UI changed)")
    func testStagnationRecoveryWhenScreenStateChanges() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let changedDiff = UIStateDiff(titleChanged: true, focusChanged: false)
        let goal = "Scroll down feed"

        // Step 0: Initial scroll
        let d0 = engine.fallbackLocalDecision(goal: goal, candidates: candidates)
        let s0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: d0)

        // Step 1: Stagnant -> keyPress
        let d1 = engine.fallbackLocalDecision(goal: goal, candidates: candidates, history: [s0], lastDiff: unchangedDiff)
        #expect(d1.action == .keyPress)
        let s1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

        // Step 2: PageDown successfully moved screen! (isStateUnchanged == false)
        let d2 = engine.fallbackLocalDecision(goal: goal, candidates: candidates, history: [s0, s1], lastDiff: changedDiff)
        #expect(d2.action == .scroll, "When UI state changes, engine should resume normal scrolling")
        #expect(d2.isCompleted == false)
    }

    // =========================================================================
    // SECTION 2: 2-STRIKE CIRCUIT BREAKER STRESS TESTING
    // =========================================================================

    @Test("Two low-confidence attempts leave an unmatched target unresolved")
    func testCircuitBreakerTwoLowConfidenceEscalationsTriggerConclusion() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let candidates = [
            UIElementCandidate(id: "btn_other", role: "AXButton", label: "Other Button", bounds: CGRect(x: 10, y: 10, width: 50, height: 20))
        ]

        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.35, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.35, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click phantom mystery icon",
            candidates: candidates,
            history: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: decision))
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(decision.reasoning?.contains("remains unresolved") == true)
    }

    @Test("Two low-confidence attempts with empty candidates require resolution")
    func testCircuitBreakerWithEmptyCandidatesInFallback() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.20, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click whatever is visible",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("decideNextAction preserves unresolved empty candidates after two attempts")
    func testCircuitBreakerDecideNextActionWithEmptyCandidates() async throws {
        let mock = MockTypeSafeEvaluator.scripted(targetChoice: "none", targetConfidence: 0.0)
        let engine = TypeSafeDecisionEngine(client: mock, confidenceThreshold: 0.80)
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.20, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]

        let decision = try await engine.decideNextAction(
            goal: "Click whatever is visible",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Circuit Breaker: Graduated sequence from 0 to 1 to 2 lowConfidence escalations")
    func testCircuitBreakerGraduatedEscalationProgression() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let candidates = [
            UIElementCandidate(id: "btn_save", role: "AXButton", label: "Save", bounds: CGRect(x: 100, y: 100, width: 60, height: 30), isActionable: true),
            UIElementCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel", bounds: CGRect(x: 200, y: 100, width: 60, height: 30), isActionable: true)
        ]

        // Strike 0: Initial unmatched goal produces diagnostic low confidence (< 0.80) -> triggers Escalation #1
        let d0 = engine.fallbackLocalDecision(
            goal: "Click quantum teleport button",
            candidates: candidates,
            recentEscalations: []
        )
        #expect(d0.action == .none)
        #expect(d0.isCompleted == false)
        #expect(d0.confidence < 0.80)
        #expect(engine.shouldEscalate(decision: d0) == true)

        let esc1 = EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: d0.confidence, threshold: 0.80))

        // Strike 1: Following 1st escalation with replan "Interact with alternative interactive element for..."
        // Strategy 2 selects an actionable alternative element with confidence 0.80!
        let d1 = engine.fallbackLocalDecision(
            goal: "Interact with alternative interactive element for: click quantum teleport button",
            candidates: candidates,
            recentEscalations: [esc1]
        )
        #expect(d1.targetElementId == "btn_save")
        #expect(d1.action == .click)
        #expect(d1.confidence == 0.80)
        #expect(d1.isCompleted == false)
        #expect(engine.shouldEscalate(decision: d1) == false)

        // Strike 2: If alternative also failed and a second lowConfidence escalation is recorded:
        let esc2 = EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.50, threshold: 0.80))
        let d2 = engine.fallbackLocalDecision(
            goal: "Click quantum teleport button",
            candidates: candidates,
            recentEscalations: [esc1, esc2]
        )
        #expect(d2.action == .none)
        #expect(!d2.isCompleted, "Failed attempts cannot establish an observed outcome")
        #expect(d2.confidence == 0.0)
        #expect(d2.targetElementId == nil && d2.coordinates == nil)
        #expect(engine.shouldEscalate(decision: d2))
    }

    @Test("Three or more escalations still preserve an unresolved target")
    func testCircuitBreakerOvershootHandledCleanly() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.30, threshold: 0.80)),
            EscalationRecord(attempt: 3, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Do impossible action",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    // =========================================================================
    // SECTION 3: EXTREME QUERIES & TOKEN MATCHING STRESS TESTING
    // =========================================================================

    @Test("Token Matching: Japanese Kanji, Katakana, and mixed queries with particles")
    func testTokenMatchingJapaneseExtremeQueries() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_order", role: "AXButton", label: "注文確定", bounds: CGRect(x: 10, y: 10, width: 100, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_cart", role: "AXButton", label: "カートを見る", bounds: CGRect(x: 120, y: 10, width: 100, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_save", role: "AXButton", label: "保存", bounds: CGRect(x: 230, y: 10, width: 80, height: 40), isActionable: true),
            UIElementCandidate(id: "txt_search", role: "AXTextField", label: "商品を検索", bounds: CGRect(x: 320, y: 10, width: 150, height: 40), isActionable: true)
        ]

        // 1. Particle-laden query: "変更を保存してください" -> matches "保存"
        let d1 = engine.fallbackLocalDecision(goal: "変更を保存してください", candidates: candidates)
        #expect(d1.targetElementId == "btn_save")
        #expect(d1.confidence >= 0.80)

        // 2. Substring query: "注文を確定する" -> matches "注文確定"
        let d2 = engine.fallbackLocalDecision(goal: "注文確定ボタンをクリックして", candidates: candidates)
        #expect(d2.targetElementId == "btn_order")
        #expect(d2.confidence >= 0.80)

        // 3. Katakana query: "カートの中身を確認" -> matches "カートを見る"
        let d3 = engine.fallbackLocalDecision(goal: "カートの中身を確認して", candidates: candidates)
        #expect(d3.action == .none)
        #expect(d3.targetElementId == nil)
        #expect(engine.shouldEscalate(decision: d3))

        // 4. Japanese quotes: 「注文確定」を押す
        let d4 = engine.fallbackLocalDecision(goal: "「注文確定」を押す", candidates: candidates)
        #expect(d4.targetElementId == "btn_order")
        #expect(d4.confidence >= 0.80)
    }

    @Test("Token Matching: Heavy stop word sentence with multi-word target")
    func testTokenMatchingHeavyStopWordSentence() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_submit_order", role: "AXButton", label: "Submit Order", bounds: CGRect(x: 50, y: 50, width: 120, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel and Return", bounds: CGRect(x: 200, y: 50, width: 140, height: 40), isActionable: true)
        ]

        // Heavily padded with stop words: "Please can you click on the button for submitting the order now"
        let goal = "Please can you click on the button for submitting the order now"
        let decision = engine.fallbackLocalDecision(goal: goal, candidates: candidates)

        #expect(decision.targetElementId == "btn_submit_order")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Token Matching: Empty label matching against candidate value and ID")
    func testTokenMatchingEmptyLabelMatchingValueAndId() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(
                id: "email_address_input_field",
                role: "AXTextField",
                label: "",
                value: "user@example.com",
                bounds: CGRect(x: 10, y: 10, width: 200, height: 30),
                isActionable: true
            ),
            UIElementCandidate(
                id: "btn_submit_checkout_v2",
                role: "AXButton",
                label: "",
                value: nil,
                bounds: CGRect(x: 10, y: 60, width: 100, height: 30),
                isActionable: true
            )
        ]

        // 1. Goal matching value: "Type into user@example.com"
        let d1 = engine.fallbackLocalDecision(goal: "Type into user@example.com", candidates: candidates)
        #expect(d1.targetElementId == "email_address_input_field")
        #expect(d1.confidence >= 0.80)

        // 2. Goal matching ID token: "Click the checkout button"
        let d2 = engine.fallbackLocalDecision(goal: "Click the checkout button", candidates: candidates)
        #expect(d2.targetElementId == "btn_submit_checkout_v2")
        #expect(d2.confidence >= 0.80)

        // 3. Goal matching exact ID: "Click btn_submit_checkout_v2"
        let d3 = engine.fallbackLocalDecision(goal: "Click btn_submit_checkout_v2", candidates: candidates)
        #expect(d3.targetElementId == "btn_submit_checkout_v2")
        #expect(d3.confidence >= 0.80)
    }

    @Test("Token Matching: Numeric disambiguation between similarly named tabs or items")
    func testTokenMatchingNumericDisambiguation() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "tab_1", role: "AXTab", label: "Tab 1: Overview", bounds: CGRect(x: 0, y: 0, width: 100, height: 30), isActionable: true),
            UIElementCandidate(id: "tab_2", role: "AXTab", label: "Tab 2: Details", bounds: CGRect(x: 100, y: 0, width: 100, height: 30), isActionable: true),
            UIElementCandidate(id: "tab_3", role: "AXTab", label: "Tab 3: Settings", bounds: CGRect(x: 200, y: 0, width: 100, height: 30), isActionable: true)
        ]

        let dOverview = engine.fallbackLocalDecision(goal: "Select Tab 1", candidates: candidates)
        #expect(dOverview.targetElementId == "tab_1")

        let dDetails = engine.fallbackLocalDecision(goal: "Select Tab 2", candidates: candidates)
        #expect(dDetails.targetElementId == "tab_2")

        let dSettings = engine.fallbackLocalDecision(goal: "Select Tab 3", candidates: candidates)
        #expect(dSettings.targetElementId == "tab_3")
    }

    @Test("Token Matching: Highly adversarial unicode, punctuation and emoji strings")
    func testTokenMatchingAdversarialUnicodeAndEmojis() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [
            UIElementCandidate(id: "btn_emoji", role: "AXButton", label: "🚀 Launch App", bounds: CGRect(x: 10, y: 10, width: 120, height: 40), isActionable: true),
            UIElementCandidate(id: "btn_brackets", role: "AXButton", label: "【重要】今すぐ確認", bounds: CGRect(x: 150, y: 10, width: 140, height: 40), isActionable: true)
        ]

        // 1. Goal with emoji: "Click 🚀 Launch App"
        let d1 = engine.fallbackLocalDecision(goal: "Click 🚀 Launch App", candidates: candidates)
        #expect(d1.targetElementId == "btn_emoji")
        #expect(d1.confidence >= 0.80)

        // 2. Goal with Japanese bracketed text: "【重要】今すぐ確認をクリックして"
        let d2 = engine.fallbackLocalDecision(goal: "【重要】今すぐ確認をクリックして", candidates: candidates)
        #expect(d2.targetElementId == "btn_brackets")
        #expect(d2.confidence >= 0.80)

        // 3. Huge string of 1000 characters with mixed scripts does not crash
        let hugeGoal = String(repeating: "🌟✨ こんにちは 世界 Hello World 123 ", count: 30)
        let dHuge = engine.fallbackLocalDecision(goal: hugeGoal, candidates: candidates)
        #expect(dHuge.confidence >= 0.0)
    }

    // =========================================================================
    // SECTION 4: EMPIRICAL DEFECT REGRESSION TESTS
    // =========================================================================

    @Test("Defect 1: Short label ('OK') falsely matches goal words containing 'ok' ('Lookup') due to unanchored substring matching")
    func testDefectShortLabelFalseMatch() {
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

        // Goal 'Lookup warehouse catalog' should NOT match 'OK' button, but currently matches with 0.85 confidence
        #expect(decision.targetElementId == nil, "Goal 'Lookup warehouse catalog' must NOT match button labeled 'OK'")
        #expect(decision.confidence < 0.80, "Unmatched goal must return low diagnostic confidence")
    }
}
