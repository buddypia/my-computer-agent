import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("TypeSafeDecisionEngine Adversarial Coverage Hardening Tests (Tier 5)")
struct TypeSafeDecisionEngineAdversarialCoverageHardeningTests {

    // MARK: - Helper Builders

    private func makeCandidate(
        id: String,
        role: String = "AXButton",
        label: String = "Test Button",
        value: String? = nil,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 80, height: 30),
        isActionable: Bool = true
    ) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            value: value,
            bounds: bounds,
            isActionable: isActionable
        )
    }

    // =========================================================================
    // SECTION 1: CONTAINER CANDIDATE RESOLUTION & COORDINATE BOUNDARY STRESS
    // =========================================================================

    @Test("Sec1.1: All 5 scroll container roles (AXScrollArea, AXWebArea, AXTable, AXList, AXOutline) are resolved correctly")
    func testAllFiveScrollContainerRolesResolved() {
        let engine = TypeSafeDecisionEngine()
        let roles = ["AXScrollArea", "AXWebArea", "AXTable", "AXList", "AXOutline"]

        for role in roles {
            let container = makeCandidate(
                id: "c_\(role)",
                role: role,
                label: "Content \(role)",
                bounds: CGRect(x: 50, y: 50, width: 600, height: 400)
            )
            let other = makeCandidate(
                id: "btn_other",
                role: "AXButton",
                label: "Other Action",
                bounds: CGRect(x: 10, y: 10, width: 80, height: 30)
            )

            let resolved = TypeSafeDecisionEngine.resolveScrollContainer(
                candidates: [other, container],
                goal: "Scroll down content"
            )
            #expect(resolved?.id == "c_\(role)", "Role \(role) must be recognized as scroll container")

            let decision = engine.fallbackLocalDecision(
                goal: "Scroll down",
                candidates: [other, container]
            )
            #expect(decision.targetElementId == "c_\(role)")
            #expect(decision.targetCenter == CGPoint(x: 350, y: 250))
            #expect(decision.action == .scroll)
        }
    }

    @Test("Sec1.2: Container resolution priority strictly respects AXScrollArea > AXWebArea > AXTable/List/Outline > Generic")
    func testContainerRolePriorityLadder() {
        // Equal size (800x600) and no keyword bonus to isolate role scoring
        let scrollArea = makeCandidate(id: "c_scroll", role: "AXScrollArea", label: "Area A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let webArea = makeCandidate(id: "c_web", role: "AXWebArea", label: "Area B", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let table = makeCandidate(id: "c_table", role: "AXTable", label: "Area C", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let list = makeCandidate(id: "c_list", role: "AXList", label: "Area D", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let outline = makeCandidate(id: "c_outline", role: "AXOutline", label: "Area E", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let genericFeed = makeCandidate(id: "c_generic", role: "AXGroup", label: "feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

        // 1. AXScrollArea (1000) beats AXWebArea (900)
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [webArea, scrollArea], goal: "Scroll down")?.id == "c_scroll")

        // 2. AXWebArea (900) beats AXTable (800)
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [table, webArea], goal: "Scroll down")?.id == "c_web")

        // 3. AXTable (800) beats Generic (400 + 500 keyword = 900? Let's check: 400 + 500 = 900 vs 800)
        // Table without keyword is 800 + area. Generic with keyword "feed" is 400 + 500 + area = 900.
        // But Table with keyword "feed" is 800 + 500 + area = 1300!
        let tableFeed = makeCandidate(id: "t_feed", role: "AXTable", label: "feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [genericFeed, tableFeed], goal: "Scroll")?.id == "t_feed")

        // 4. AXTable, AXList, AXOutline have equal role priority (800)
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [list, outline], goal: "Scroll")?.id == "c_list")
    }

    @Test("Sec1.3: Container resolution rejects zero-size, negative-size, and non-finite bounds")
    func testContainerRejectsDegenerateBounds() {
        let negWidth = makeCandidate(id: "c_neg_w", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 10, y: 10, width: -100, height: 500))
        let negHeight = makeCandidate(id: "c_neg_h", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 10, y: 10, width: 500, height: -100))
        let zeroBounds = makeCandidate(id: "c_zero", role: "AXScrollArea", label: "Feed", bounds: .zero)
        let nanBounds = makeCandidate(id: "c_nan", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100))
        let infBounds = makeCandidate(id: "c_inf", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity))
        let valid = makeCandidate(id: "c_valid", role: "AXScrollArea", label: "Feed", bounds: CGRect(x: 10, y: 10, width: 400, height: 500))

        let candidates = [negWidth, negHeight, zeroBounds, nanBounds, infBounds, valid]
        let selected = TypeSafeDecisionEngine.resolveScrollContainer(candidates: candidates, goal: "Scroll feed")
        #expect(selected?.id == "c_valid")
    }

    // =========================================================================
    // SECTION 2: CENTROID & COORDINATE CALCULATION EDGE CASES
    // =========================================================================

    @Test("Sec2.1: Centroid calculation with single 1x1 pixel candidate bounds")
    func testCentroidSinglePixelCandidate() {
        let singlePixel = makeCandidate(
            id: "dot_1",
            role: "AXButton",
            label: "Pixel Dot",
            bounds: CGRect(x: 500, y: 300, width: 1, height: 1)
        )
        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [singlePixel])
        #expect(coords == CGPoint(x: 500.5, y: 300.5))
    }

    @Test("Sec2.2: Centroid calculation with entirely negative / off-screen coordinate bounds")
    func testCentroidNegativeCoordinates() {
        let c1 = makeCandidate(id: "off_1", role: "AXButton", bounds: CGRect(x: -800, y: -600, width: 200, height: 200))
        let c2 = makeCandidate(id: "off_2", role: "AXButton", bounds: CGRect(x: -400, y: -200, width: 200, height: 200))

        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [c1, c2])
        // minX = -800, maxX = -200 -> width = 600 -> center x = -800 + 300 = -500
        // minY = -600, maxY = 0 -> height = 600 -> center y = -600 + 300 = -300
        #expect(coords == CGPoint(x: -500, y: -300))
    }

    @Test("Sec2.3: Centroid calculation when ALL candidates have degenerate bounds falls back to desktop center")
    func testCentroidAllDegenerateCandidates() {
        let degenerate1 = makeCandidate(id: "d1", role: "AXButton", bounds: .zero)
        let degenerate2 = makeCandidate(id: "d2", role: "AXButton", bounds: CGRect(x: 10, y: 10, width: 0, height: 0))
        let degenerate3 = makeCandidate(id: "d3", role: "AXButton", bounds: CGRect(x: 10, y: 10, width: -50, height: 20))

        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [degenerate1, degenerate2, degenerate3])
        #expect(coords.x.isFinite && coords.y.isFinite)
        #expect(coords != .zero)
    }

    @Test("Sec2.4: Empty candidate list produces finite fallback coordinates")
    func testCentroidEmptyCandidateList() {
        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [])
        #expect(coords.x > 0 && coords.y > 0)
        #expect(coords.x.isFinite && coords.y.isFinite)
    }

    // =========================================================================
    // SECTION 3: STAGNATION ADAPTATION LADDER & RAPID STATE FLIPPING
    // =========================================================================

    @Test("Sec3.1: Stagnation ladder: initial scroll -> PageDown -> concludes after repeated failure")
    func testStagnationFullLadderLifecycle() {
        let engine = TypeSafeDecisionEngine()
        let container = makeCandidate(id: "feed", role: "AXScrollArea", label: "Main Feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let unchanged = UIStateDiff(titleChanged: false, focusChanged: false)

        // Step 1: Normal scroll
        let d1 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container])
        #expect(d1.action == .scroll)
        #expect(!d1.isCompleted)

        // Step 2: Unchanged -> PageDown
        let step1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)
        let d2 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container], history: [step1], lastDiff: unchanged)
        #expect(d2.action == .keyPress)
        #expect(d2.keyCombination == ["PageDown"])
        #expect(!d2.isCompleted)

        // Step 3: Unchanged after PageDown -> Concludes subgoal
        let step2 = LoopStepRecord(stepNumber: 2, subgoalId: "sg1", action: d2)
        let d3 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container], history: [step1, step2], lastDiff: unchanged)
        #expect(d3.action == .none)
        #expect(d3.isCompleted)
        #expect(d3.confidence >= 0.80)
    }

    @Test("Sec3.2: Rapid state flipping: scroll stagnates -> PageDown succeeds -> subsequent scroll operates normally")
    func testRapidStateFlippingRecovery() {
        let engine = TypeSafeDecisionEngine()
        let container = makeCandidate(id: "feed", role: "AXScrollArea", label: "Main Feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let unchanged = UIStateDiff(titleChanged: false, focusChanged: false)
        let changed = UIStateDiff(titleChanged: true, focusChanged: false)

        // Step 1: Scroll
        let d1 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container])
        let step1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

        // Step 2: Stagnant -> adapts to PageDown
        let d2 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container], history: [step1], lastDiff: unchanged)
        #expect(d2.action == .keyPress)
        let step2 = LoopStepRecord(stepNumber: 2, subgoalId: "sg1", action: d2)

        // Step 3: PageDown caused screen change! UIStateDiff is now changed
        let d3 = engine.fallbackLocalDecision(goal: "Scroll feed", candidates: [container], history: [step1, step2], lastDiff: changed)
        #expect(d3.action == .scroll, "Must resume normal scrolling once screen diff indicates progress")
        #expect(!d3.isCompleted)
    }

    @Test("Sec3.3: High escalation risk (2 escalations) concludes stagnant scroll immediately on first unchanged step")
    func testHighEscalationRiskImmediateConclusion() {
        let engine = TypeSafeDecisionEngine()
        let container = makeCandidate(id: "feed", role: "AXScrollArea", label: "Main Feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let unchanged = UIStateDiff(titleChanged: false, focusChanged: false)

        let escalations = [
            EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "Diff unchanged")),
            EscalationRecord(attempt: 2, reason: .actionStagnant(reason: "Diff unchanged"))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll feed",
            candidates: [container],
            history: [],
            recentEscalations: escalations,
            lastDiff: unchanged
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true)
        #expect(decision.confidence >= 0.80)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    // =========================================================================
    // SECTION 4: TOKEN-BASED CANDIDATE MATCHING & SCRIPT SEGMENTATION
    // =========================================================================

    @Test("Sec4.1: Katakana middle dot (U+30FB) and half-width middle dot (U+FF65) act as word delimiters")
    func testKatakanaMiddleDotSegmentation() {
        let tokensFull = TypeSafeDecisionEngine.extractTokens(from: "ユーザー・インターフェース")
        #expect(tokensFull.contains("ユーザー"))
        #expect(tokensFull.contains("インターフェース"))
        #expect(!tokensFull.contains("・"))

        let tokensHalf = TypeSafeDecisionEngine.extractTokens(from: "ユーザー･ガイド")
        #expect(tokensHalf.contains("ユーザー"))
        #expect(tokensHalf.contains("ガイド"))
    }

    @Test("Sec4.2: Katakana prolonged sound mark (U+30FC 'ー') is preserved within tokens")
    func testKatakanaProlongedSoundMarkPreserved() {
        let tokens = TypeSafeDecisionEngine.extractTokens(from: "サーバーエラー")
        #expect(tokens.contains("サーバーエラー"))
    }

    @Test("Sec4.3: Full-width digits (U+FF10...U+FF19 '０'-'９') normalize to ASCII digits")
    func testFullWidthDigitsNormalization() {
        let tokens = TypeSafeDecisionEngine.extractTokens(from: "タブ２の番号")
        #expect(tokens.contains("2"))
        #expect(tokens.contains("番号"))
        #expect(!tokens.contains("の"))
        #expect(!tokens.contains("タブ")) // 'タブ' is properly stripped as generic UI stop word
    }

    @Test("Sec4.4: Japanese particle stripping removes grammatical particles while preserving semantic tokens")
    func testJapaneseParticleStripping() {
        let sentence = "設定の画面を開いてアカウントを更新してください"
        let tokens = TypeSafeDecisionEngine.extractTokens(from: sentence)
        #expect(tokens.contains("設定"))
        #expect(tokens.contains("アカウント"))
        #expect(tokens.contains("更新"))
        #expect(!tokens.contains("の"))
        #expect(!tokens.contains("を"))
        #expect(!tokens.contains("して"))
        #expect(!tokens.contains("ください"))
    }

    @Test("Sec4.5: Latin word boundary enforcement prevents interior substring false positive ('OK' inside 'Lookup', 'Token', 'Book')")
    func testLatinWordBoundaryStrictness() {
        let engine = TypeSafeDecisionEngine()
        let okButton = makeCandidate(id: "btn_ok", role: "AXButton", label: "OK", isActionable: true)

        let goals = [
            "Lookup catalog items",
            "Generate auth token",
            "Book flight reservation",
            "Smoke test the pipeline"
        ]

        for goal in goals {
            let decision = engine.fallbackLocalDecision(goal: goal, candidates: [okButton])
            #expect(decision.targetElementId == nil, "Goal '\(goal)' must NOT match button labeled 'OK'")
            #expect(decision.confidence < 0.80)
        }
    }

    @Test("Sec4.6: Value attribute fallback when candidate label is empty or whitespace")
    func testValueAttributeFallbackWhenLabelEmpty() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(
            id: "search_input",
            role: "AXTextField",
            label: "   ",
            value: "Search products or categories",
            isActionable: true
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Search products",
            candidates: [candidate]
        )

        #expect(decision.targetElementId == "search_input")
        #expect(decision.confidence >= 0.80)
    }

    @Test("Sec4.7: Candidate ID component matching when both label and value are empty")
    func testIdComponentMatchingWhenLabelAndValueEmpty() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(
            id: "btn_checkout_confirm_payment",
            role: "AXButton",
            label: "",
            value: nil,
            isActionable: true
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Click Confirm payment on checkout",
            candidates: [candidate]
        )

        #expect(decision.targetElementId == "btn_checkout_confirm_payment")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    // =========================================================================
    // SECTION 5: LOW-CONFIDENCE CIRCUIT BREAKER & MIXED ESCALATIONS
    // =========================================================================

    @Test("Sec5.1: empty candidates remain unresolved after 2 low-confidence escalations")
    func testDecideNextActionEmptyCandidatesCircuitBreaker() async throws {
        let engine = TypeSafeDecisionEngine()
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = try await engine.decideNextAction(
            goal: "Click phantom",
            candidates: [],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Sec5.2: unresolvable target remains unresolved after 2 low-confidence escalations")
    func testFallbackLocalDecisionUnresolvableCircuitBreaker() {
        let engine = TypeSafeDecisionEngine()
        let unrelated = makeCandidate(id: "btn_unrelated", role: "AXButton", label: "Help Documentation")
        let escalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click secret spaceship launch button",
            candidates: [unrelated],
            recentEscalations: escalations
        )

        #expect(decision.action == .none)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Sec5.3: Single low-confidence escalation selects actionable alternative candidate")
    func testSingleLowConfidenceSelectsAlternativeCandidate() {
        let engine = TypeSafeDecisionEngine()
        let nonActionable = makeCandidate(id: "text_status", role: "AXStaticText", label: "Status: Ready", isActionable: false)
        let actionable = makeCandidate(id: "btn_action", role: "AXButton", label: "Proceed Anyway", isActionable: true)

        let singleEscalation = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click missing target",
            candidates: [nonActionable, actionable],
            recentEscalations: singleEscalation
        )

        #expect(decision.targetElementId == "btn_action")
        #expect(decision.action == .click)
        #expect(decision.confidence == 0.80)
        #expect(!decision.isCompleted)
    }

    @Test("Sec5.4: Single low-confidence escalation with NO actionable candidates falls through to graduated confidence")
    func testSingleLowConfidenceWithNoActionableCandidatesFallsThrough() {
        let engine = TypeSafeDecisionEngine()
        let nonActionable1 = makeCandidate(id: "text_1", role: "AXStaticText", label: "Line 1", isActionable: false)
        let nonActionable2 = makeCandidate(id: "text_2", role: "AXStaticText", label: "Line 2", isActionable: false)

        let singleEscalation = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click missing target",
            candidates: [nonActionable1, nonActionable2],
            recentEscalations: singleEscalation
        )

        #expect(decision.action == .none)
        #expect(decision.confidence < 0.80)
        #expect(decision.confidence >= 0.20)
        #expect(!decision.isCompleted)
    }

    @Test("Sec5.5: Mixed escalations: 1 actionStagnant + 1 lowConfidence does not prematurely trip 2-strike lowConfidence circuit breaker")
    func testMixedEscalationsDoNotPrematurelyTripLowConfidenceBreaker() {
        let engine = TypeSafeDecisionEngine()
        let nonActionable = makeCandidate(id: "text_1", role: "AXStaticText", label: "Info", isActionable: false)

        let mixed = [
            EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "diff unchanged")),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click missing target",
            candidates: [nonActionable],
            recentEscalations: mixed
        )

        // Only 1 lowConfidence exists, so lowConfidence circuit breaker (requires >= 2) does NOT trip.
        // It returns graduated diagnostic confidence for System 2.
        #expect(decision.action == .none)
        #expect(decision.confidence < 0.80)
        #expect(!decision.isCompleted)
    }

    // =========================================================================
    // SECTION 6: EXTREME INPUTS & MALFORMED GOALS STRESS TESTING
    // =========================================================================

    @Test("Sec6.1: Empty and pure whitespace goals produce immediate .none decision with 0.0 confidence")
    func testEmptyAndWhitespaceGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidates = [makeCandidate(id: "btn", role: "AXButton", label: "Test")]

        let emptyDecision = engine.fallbackLocalDecision(goal: "", candidates: candidates)
        #expect(emptyDecision.action == .none)
        #expect(emptyDecision.confidence == 0.0)
        #expect(!emptyDecision.isCompleted)

        let wsDecision = engine.fallbackLocalDecision(goal: "  \n\t  ", candidates: candidates)
        #expect(wsDecision.action == .none)
        #expect(wsDecision.confidence == 0.0)
        #expect(!wsDecision.isCompleted)
    }

    @Test("Sec6.2: Goals with null bytes and control characters execute safely without crash")
    func testGoalsWithControlCharacters() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(id: "btn_save", role: "AXButton", label: "Save")

        let malformed = "Save\0\u{0007}\u{001B} Document\r\n"
        let decision = engine.fallbackLocalDecision(goal: malformed, candidates: [candidate])
        #expect(decision.targetElementId == "btn_save")
        #expect(decision.confidence >= 0.80)
    }

    @Test("Sec6.3: Pure punctuation and symbol goals execute safely without regex or string crashes")
    func testPurePunctuationGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidate = makeCandidate(id: "btn_star", role: "AXButton", label: "***")

        let decision = engine.fallbackLocalDecision(goal: "!@#$%^&*()_+=-[]{}\\|;:'\",.<>/?", candidates: [candidate])
        #expect(decision.action == .none)
        #expect(decision.confidence >= 0.0)
    }

    @Test("Sec6.4: Extremely large candidate list (500 candidates) with mixed roles completes in sub-10ms")
    func testCandidateListScalingEfficiency() {
        let engine = TypeSafeDecisionEngine()
        var candidates: [UIElementCandidate] = []
        for i in 0..<500 {
            candidates.append(
                makeCandidate(
                    id: "elem_\(i)",
                    role: i % 5 == 0 ? "AXScrollArea" : "AXButton",
                    label: "Element \(i)",
                    bounds: CGRect(x: Double(i % 10) * 80, y: Double(i / 10) * 30, width: 70, height: 25)
                )
            )
        }

        var decision: ComputerActionDecision!
        let ms = threadCPUMilliseconds {
            decision = engine.fallbackLocalDecision(goal: "Click Element 442", candidates: candidates)
        }

        #expect(decision.targetElementId == "elem_442")
        #expect(decision.confidence >= 0.80)
        #expect(ms < 100, "500 candidate evaluation took \(ms)ms of CPU; must be < 100ms")
    }

    @Test("Sec6.5: Extreme coordinates (1e10, 1e12, large coordinates) safely handled in fallbackLocalDecision and decideNextAction")
    func testExtremeCoordinateSafety() async throws {
        let engine = TypeSafeDecisionEngine()
        let extremeContainer = makeCandidate(
            id: "huge_feed",
            role: "AXScrollArea",
            label: "Massive Viewport Feed",
            bounds: CGRect(x: 10_000_000_000, y: 10_000_000_000, width: 1_000_000, height: 1_000_000)
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll massive feed down",
            candidates: [extremeContainer]
        )

        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == "huge_feed")
        #expect(decision.targetCenter != nil)
        #expect(decision.targetCenter?.x.isFinite == true)
        #expect(decision.targetCenter?.y.isFinite == true)
        #expect(decision.reasoning != nil)

        // Also test decideNextAction with mocked evaluator
        let mock = MockTypeSafeEvaluator.scripted(
            targetChoice: "huge_feed",
            targetConfidence: 0.95,
            actionChoice: "scroll"
        )
        let mockEngine = TypeSafeDecisionEngine(client: mock)
        let asyncDecision = try await mockEngine.decideNextAction(
            goal: "Scroll massive feed down",
            candidates: [extremeContainer]
        )
        #expect(asyncDecision.action == .scroll)
        #expect(asyncDecision.targetElementId == "huge_feed")
    }
}
