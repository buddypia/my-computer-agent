import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Scroll Container Grounding, Stagnation Ladder & Low-Confidence Recovery Tests")
struct ScrollAndStagnationDecisionTests {

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

    // MARK: - 1. Scroll Container Resolution & Role Priority

    @Test("All 5 scroll container roles (AXScrollArea, AXWebArea, AXTable, AXList, AXOutline) are resolved correctly")
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

    @Test("Container resolution priority strictly respects AXScrollArea > AXWebArea > AXTable/List/Outline > Generic")
    func testContainerRolePriorityLadder() {
        let scrollArea = makeCandidate(id: "c_scroll", role: "AXScrollArea", label: "Area A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let webArea = makeCandidate(id: "c_web", role: "AXWebArea", label: "Area B", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let table = makeCandidate(id: "c_table", role: "AXTable", label: "Area C", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let list = makeCandidate(id: "c_list", role: "AXList", label: "Area D", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let outline = makeCandidate(id: "c_outline", role: "AXOutline", label: "Area E", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let genericFeed = makeCandidate(id: "c_generic", role: "AXGroup", label: "feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let tableFeed = makeCandidate(id: "t_feed", role: "AXTable", label: "feed", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [webArea, scrollArea], goal: "Scroll down")?.id == "c_scroll")
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [table, webArea], goal: "Scroll down")?.id == "c_web")
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [genericFeed, tableFeed], goal: "Scroll")?.id == "t_feed")
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: [list, outline], goal: "Scroll")?.id == "c_list")
    }

    @Test("Nested AXScrollArea selects inner container when goal matches inner container label")
    func testNestedScrollAreasGoalSpecificInner() {
        let outerWindow = UIElementCandidate(
            id: "window_scroll",
            role: "AXScrollArea",
            label: "Main Application Window",
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let innerComments = UIElementCandidate(
            id: "comments_scroll",
            role: "AXScrollArea",
            label: "User Comments Feed",
            bounds: CGRect(x: 500, y: 200, width: 400, height: 600)
        )
        let sidebarNav = UIElementCandidate(
            id: "sidebar_scroll",
            role: "AXScrollArea",
            label: "Navigation Sidebar",
            bounds: CGRect(x: 0, y: 0, width: 250, height: 1080)
        )

        let candidates = [outerWindow, innerComments, sidebarNav]

        let selectedForComments = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll user comments feed down"
        )
        #expect(selectedForComments?.id == "comments_scroll", "Goal match + keyword bonus must prioritize inner comments container")

        let selectedForNav = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll navigation sidebar"
        )
        #expect(selectedForNav?.id == "sidebar_scroll", "Goal match must prioritize navigation sidebar")
    }

    @Test("Generic scroll goal tie-breaking prioritizes largest viewport area among nested AXScrollAreas")
    func testNestedScrollAreasGenericGoalLargestAreaWins() {
        let outerWindow = UIElementCandidate(
            id: "outer_window",
            role: "AXScrollArea",
            label: "Main Window",
            bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        let subPanel = UIElementCandidate(
            id: "sub_panel",
            role: "AXScrollArea",
            label: "Sub Panel",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300)
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [subPanel, outerWindow],
            goal: "Scroll down to see more"
        )
        #expect(selected?.id == "outer_window", "Generic scroll without keyword match must select primary window viewport based on area")
    }

    @Test("AXWebArea vs AXTable role hierarchy and goal specificity")
    func testAXWebAreaVsAXTableScoring() {
        let webArea = UIElementCandidate(
            id: "browser_web_area",
            role: "AXWebArea",
            label: "Company Portal Document",
            bounds: CGRect(x: 0, y: 50, width: 1200, height: 800)
        )
        let tableArea = UIElementCandidate(
            id: "data_table",
            role: "AXTable",
            label: "Employee Records Table",
            bounds: CGRect(x: 50, y: 100, width: 1000, height: 600)
        )
        let candidates = [webArea, tableArea]

        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: candidates, goal: "Scroll employee records table down")?.id == "data_table")
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: candidates, goal: "Scroll company portal document")?.id == "browser_web_area")
        #expect(TypeSafeDecisionEngine.resolveScrollContainer(candidates: candidates, goal: "Scroll down")?.id == "browser_web_area")
    }

    @Test("Competing container labels with keyword match in label, value, or id")
    func testCompetingContainerLabelsWithKeywords() {
        let chatContainer = UIElementCandidate(
            id: "chat_stream_container",
            role: "AXScrollArea",
            label: "Live Chat Stream",
            bounds: CGRect(x: 800, y: 0, width: 400, height: 700)
        )
        let documentContainer = UIElementCandidate(
            id: "doc_container",
            role: "AXScrollArea",
            label: "Article Text",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 700)
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [documentContainer, chatContainer],
            goal: "Scroll chat messages"
        )
        #expect(selected?.id == "chat_stream_container")
    }

    @Test("Japanese container keywords match correctly (フィード, タイムライン, チャット)")
    func testJapaneseContainerKeywordsResolution() {
        let timeline = UIElementCandidate(
            id: "timeline_view",
            role: "AXScrollArea",
            label: "新着タイムライン",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 800)
        )
        let settings = UIElementCandidate(
            id: "settings_view",
            role: "AXScrollArea",
            label: "環境設定パネル",
            bounds: CGRect(x: 750, y: 100, width: 300, height: 800)
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [settings, timeline],
            goal: "タイムラインを下にスクロールして"
        )
        #expect(selected?.id == "timeline_view")
    }

    // MARK: - 2. Coordinate Fallback & Geometric Bounds

    @Test("Degenerate bounds (zero width, zero height, zero rect) are strictly filtered out")
    func testDegenerateBoundsFiltering() {
        let zeroWidth = makeCandidate(id: "zero_width", role: "AXScrollArea", label: "Zero Width Feed", bounds: CGRect(x: 100, y: 100, width: 0, height: 500))
        let zeroHeight = makeCandidate(id: "zero_height", role: "AXScrollArea", label: "Zero Height Feed", bounds: CGRect(x: 100, y: 100, width: 500, height: 0))
        let zeroRect = makeCandidate(id: "zero_rect", role: "AXScrollArea", label: "Zero Rect", bounds: .zero)
        let validArea = makeCandidate(id: "valid_area", role: "AXScrollArea", label: "Valid Feed", bounds: CGRect(x: 200, y: 200, width: 400, height: 400))

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [zeroWidth, zeroHeight, zeroRect, validArea],
            goal: "Scroll feed"
        )
        #expect(selected?.id == "valid_area")

        let fallbackCenter = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(
            candidates: [zeroWidth, zeroHeight, zeroRect, validArea]
        )
        #expect(fallbackCenter == CGPoint(x: 400, y: 400))
    }

    @Test("Non-finite bounds (NaN, Infinity) are safely rejected without crash")
    func testNonFiniteBoundsFiltering() {
        let nanOrigin = makeCandidate(id: "nan_origin", role: "AXScrollArea", label: "NaN Bounds", bounds: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 500))
        let nanWidth = makeCandidate(id: "nan_width", role: "AXScrollArea", label: "NaN Width", bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 500))
        let infHeight = makeCandidate(id: "inf_height", role: "AXScrollArea", label: "Inf Height", bounds: CGRect(x: 0, y: 0, width: 500, height: CGFloat.infinity))
        let normalCandidate = makeCandidate(id: "normal_scroll", role: "AXScrollArea", label: "Normal Area", bounds: CGRect(x: 100, y: 100, width: 300, height: 300))

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [nanOrigin, nanWidth, infHeight, normalCandidate],
            goal: "Scroll down"
        )
        #expect(selected?.id == "normal_scroll")

        let fallbackCenter = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(
            candidates: [nanOrigin, nanWidth, infHeight, normalCandidate]
        )
        #expect(fallbackCenter == CGPoint(x: 250, y: 250))
    }

    @Test("Centroid calculation with single 1x1 pixel candidate bounds")
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

    @Test("Centroid calculation with entirely negative / off-screen coordinate bounds")
    func testCentroidNegativeCoordinates() {
        let c1 = makeCandidate(id: "off_1", role: "AXButton", bounds: CGRect(x: -800, y: -600, width: 200, height: 200))
        let c2 = makeCandidate(id: "off_2", role: "AXButton", bounds: CGRect(x: -400, y: -200, width: 200, height: 200))

        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [c1, c2])
        #expect(coords == CGPoint(x: -500, y: -300))
    }

    @Test("Empty candidate list produces finite fallback coordinates and non-nil targetCenter")
    func testEmptyCandidateListFallbackCoordinates() {
        let coords = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [])
        #expect(coords.x > 0 && coords.y > 0)
        #expect(coords.x.isFinite && coords.y.isFinite)

        let engine = TypeSafeDecisionEngine()
        let decision = engine.fallbackLocalDecision(goal: "Scroll down", candidates: [])
        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter != nil)
    }

    @Test("Extreme coordinates (1e10) safely handled in fallbackLocalDecision and decideNextAction")
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
        #expect(decision.targetCenter?.x.isFinite == true)
        #expect(decision.targetCenter?.y.isFinite == true)

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

    // MARK: - 3. Scroll Stagnation Adaptation Ladder

    @Test("3-step sequential transition from .scroll -> .keyPress(PageDown) -> .none(isCompleted: true)")
    func testStagnationLadderSequentialTransition() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let goal = "Scroll down the timeline feed"

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
        #expect(d1.targetElementId == "feed_scroll_view")
        #expect(d1.targetCenter == CGPoint(x: 500, y: 420), "KeyPress must preserve container target coordinates")

        let step1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

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

    @Test("Upward scroll stagnation adapts to PageUp then concludes")
    func testStagnationLadderUpwardScrollTransition() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let goal = "Scroll up to top of timeline feed"

        let d0 = engine.fallbackLocalDecision(goal: goal, candidates: candidates)
        #expect(d0.action == .scroll)
        #expect(d0.scrollDelta?.dy ?? 0 > 0, "Upward scroll must have positive dy")

        let step0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: d0)

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

        let d2 = engine.fallbackLocalDecision(
            goal: goal,
            candidates: candidates,
            history: [step0, step1],
            lastDiff: unchangedDiff
        )
        #expect(d2.action == .none)
        #expect(d2.isCompleted == true)
    }

    @Test("Japanese scroll goals adapt to PageDown/PageUp and conclude cleanly")
    func testStagnationLadderJapaneseGoals() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)

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

        let upGoal = "上へ戻るようにスクロールして"
        let dUp0 = engine.fallbackLocalDecision(goal: upGoal, candidates: candidates)
        #expect(dUp0.action == .scroll)
        let sUp0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg2", action: dUp0)

        let dUp1 = engine.fallbackLocalDecision(goal: upGoal, candidates: candidates, history: [sUp0], lastDiff: unchangedDiff)
        #expect(dUp1.action == .keyPress)
        #expect(dUp1.keyCombination == ["PageUp"])
    }

    @Test("Resumes .scroll if keyboard navigation breaks stagnation (UI changed)")
    func testStagnationRecoveryWhenScreenStateChanges() {
        let engine = TypeSafeDecisionEngine()
        let candidates = makeContainerCandidates()
        let unchangedDiff = UIStateDiff(titleChanged: false, focusChanged: false)
        let changedDiff = UIStateDiff(titleChanged: true, focusChanged: false)
        let goal = "Scroll down feed"

        let d0 = engine.fallbackLocalDecision(goal: goal, candidates: candidates)
        let s0 = LoopStepRecord(stepNumber: 0, subgoalId: "sg1", action: d0)

        let d1 = engine.fallbackLocalDecision(goal: goal, candidates: candidates, history: [s0], lastDiff: unchangedDiff)
        #expect(d1.action == .keyPress)
        let s1 = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: d1)

        let d2 = engine.fallbackLocalDecision(goal: goal, candidates: candidates, history: [s0, s1], lastDiff: changedDiff)
        #expect(d2.action == .scroll, "When UI state changes, engine should resume normal scrolling")
        #expect(d2.isCompleted == false)
    }

    @Test("High escalation risk (2 actionStagnant escalations) concludes stagnant scroll immediately on first unchanged step")
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

    // MARK: - 4. Low-Confidence Recovery & 2-Strike Circuit Breaker

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

    @Test("Two or more low-confidence attempts with empty candidates require resolution")
    func testCircuitBreakerWithEmptyCandidatesInFallback() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let twoEscalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.20, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]
        let threeEscalations = twoEscalations + [
            EscalationRecord(attempt: 3, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]

        for escalations in [twoEscalations, threeEscalations] {
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
    }

    @Test("Graduated sequence from 0 to 1 to 2 lowConfidence escalations")
    func testCircuitBreakerGraduatedEscalationProgression() {
        let engine = TypeSafeDecisionEngine(confidenceThreshold: 0.80)
        let candidates = [
            UIElementCandidate(id: "btn_save", role: "AXButton", label: "Save", bounds: CGRect(x: 100, y: 100, width: 60, height: 30), isActionable: true),
            UIElementCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel", bounds: CGRect(x: 200, y: 100, width: 60, height: 30), isActionable: true)
        ]

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

        let esc2 = EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.50, threshold: 0.80))
        let d2 = engine.fallbackLocalDecision(
            goal: "Click quantum teleport button",
            candidates: candidates,
            recentEscalations: [esc1, esc2]
        )
        #expect(d2.action == .none)
        #expect(!d2.isCompleted)
        #expect(d2.confidence == 0.0)
        #expect(d2.targetElementId == nil && d2.coordinates == nil)
        #expect(engine.shouldEscalate(decision: d2))
    }

    @Test("Single low-confidence escalation selects actionable alternative candidate")
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

    @Test("Single low-confidence escalation with no actionable candidates falls through to graduated confidence")
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

    @Test("Mixed escalations (1 actionStagnant + 1 lowConfidence) do not trip 2-strike lowConfidence circuit breaker")
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

        // Graduated confidence is >= 0.20, whereas a tripped 2-strike breaker returns 0.0.
        #expect(decision.action == .none)
        #expect(decision.confidence >= 0.20)
        #expect(decision.confidence < 0.80)
        #expect(!decision.isCompleted)
    }
}
