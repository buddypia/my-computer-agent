import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("TypeSafeDecisionEngine Challenger Stress Tests: Container Grounding & Coordinates")
struct TypeSafeDecisionEngineChallengerTests {

    // MARK: - 1. Ambiguous Candidate Container Resolution

    @Test("Ambiguous: Nested AXScrollArea selects inner container when goal matches inner container label")
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

        // Goal specifically targets comments
        let selectedForComments = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll user comments feed down"
        )
        #expect(selectedForComments?.id == "comments_scroll", "Goal match + keyword bonus must prioritize inner comments container")

        // Goal specifically targets navigation
        let selectedForNav = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll navigation sidebar"
        )
        #expect(selectedForNav?.id == "sidebar_scroll", "Goal match must prioritize navigation sidebar")
    }

    @Test("Ambiguous: Generic scroll goal tie-breaking prioritizes largest viewport area among nested AXScrollAreas")
    func testNestedScrollAreasGenericGoalLargestAreaWins() {
        let outerWindow = UIElementCandidate(
            id: "outer_window",
            role: "AXScrollArea",
            label: "Main Window",
            bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000) // Area: 1,600,000
        )
        let subPanel = UIElementCandidate(
            id: "sub_panel",
            role: "AXScrollArea",
            label: "Sub Panel",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300) // Area: 120,000
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [subPanel, outerWindow],
            goal: "Scroll down to see more"
        )
        #expect(selected?.id == "outer_window", "Generic scroll without keyword match must select primary window viewport based on area")
    }

    @Test("Ambiguous: AXWebArea vs AXTable role hierarchy and goal specificity")
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

        // Specific goal targeting table
        let tableDecision = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll employee records table down"
        )
        #expect(tableDecision?.id == "data_table", "Explicit goal match must elevate AXTable over AXWebArea")

        // Specific goal targeting web area / document
        let webDecision = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll company portal document"
        )
        #expect(webDecision?.id == "browser_web_area", "Explicit goal match must elevate AXWebArea")

        // Generic goal: AXWebArea has higher role priority (900 vs 800)
        let genericDecision = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: candidates,
            goal: "Scroll down"
        )
        #expect(genericDecision?.id == "browser_web_area", "Generic goal must favor AXWebArea (900) over AXTable (800)")
    }

    @Test("Ambiguous: Competing container labels with keyword match in label, value, or id")
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
        #expect(selected?.id == "chat_stream_container", "Container keyword in label/id ('chat' / 'stream') must win")
    }

    @Test("Ambiguous: Japanese container keywords match correctly (フィード, タイムライン, チャット)")
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

    // MARK: - 2. Coordinate Fallback & Geometric Stress Testing

    @Test("Geometry: Degenerate bounds (zero width, zero height, zero rect) are strictly filtered out")
    func testDegenerateBoundsFiltering() {
        let zeroWidth = UIElementCandidate(
            id: "zero_width",
            role: "AXScrollArea",
            label: "Zero Width Feed",
            bounds: CGRect(x: 100, y: 100, width: 0, height: 500)
        )
        let zeroHeight = UIElementCandidate(
            id: "zero_height",
            role: "AXScrollArea",
            label: "Zero Height Feed",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 0)
        )
        let zeroRect = UIElementCandidate(
            id: "zero_rect",
            role: "AXScrollArea",
            label: "Zero Rect",
            bounds: .zero
        )
        let validArea = UIElementCandidate(
            id: "valid_area",
            role: "AXScrollArea",
            label: "Valid Feed",
            bounds: CGRect(x: 200, y: 200, width: 400, height: 400)
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [zeroWidth, zeroHeight, zeroRect, validArea],
            goal: "Scroll feed"
        )
        #expect(selected?.id == "valid_area", "Degenerate bounds must never be selected as container")

        // Coordinate fallback calculation must also ignore degenerate bounds
        let fallbackCenter = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(
            candidates: [zeroWidth, zeroHeight, zeroRect, validArea]
        )
        #expect(fallbackCenter == CGPoint(x: 400, y: 400), "Fallback coordinates must only compute over valid bounds")
    }

    @Test("Geometry: Non-finite bounds (NaN, Infinity) are safely rejected without crash")
    func testNonFiniteBoundsFiltering() {
        let nanCandidate = UIElementCandidate(
            id: "nan_scroll",
            role: "AXScrollArea",
            label: "NaN Bounds",
            bounds: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 500)
        )
        let infCandidate = UIElementCandidate(
            id: "inf_scroll",
            role: "AXScrollArea",
            label: "Inf Bounds",
            bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 500)
        )
        let normalCandidate = UIElementCandidate(
            id: "normal_scroll",
            role: "AXScrollArea",
            label: "Normal Area",
            bounds: CGRect(x: 100, y: 100, width: 300, height: 300)
        )

        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [nanCandidate, infCandidate, normalCandidate],
            goal: "Scroll down"
        )
        #expect(selected?.id == "normal_scroll")

        let fallbackCenter = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(
            candidates: [nanCandidate, infCandidate, normalCandidate]
        )
        #expect(fallbackCenter == CGPoint(x: 250, y: 250))
    }

    @Test("Geometry Stress: Stress-test negative coordinates and off-screen bounds behavior")
    func testNegativeCoordinatesAndOffscreenBounds() {
        // Offscreen container: valid width and height, but negative coordinates (e.g. -5000, -5000)
        let offscreenContainer = UIElementCandidate(
            id: "offscreen_scroll",
            role: "AXScrollArea",
            label: "Hidden Offscreen Window",
            bounds: CGRect(x: -5000, y: -5000, width: 2000, height: 2000)
        )
        let onscreenContainer = UIElementCandidate(
            id: "onscreen_scroll",
            role: "AXScrollArea",
            label: "Visible Onscreen Viewport",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        // Observe what resolveScrollContainer selects
        let selected = TypeSafeDecisionEngine.resolveScrollContainer(
            candidates: [offscreenContainer, onscreenContainer],
            goal: "Scroll down"
        )

        // Observe fallback coordinates behavior when off-screen candidate is in the list
        let fallbackCenterWithOffscreen = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(
            candidates: [offscreenContainer, onscreenContainer]
        )

        // Record empirical observation:
        // Area of offscreenContainer is 4,000,000 (area bonus capped at 500).
        // Area of onscreenContainer is 480,000 (area bonus 480).
        // If offscreenContainer has higher score (1500 vs 1480), it wins, which yields negative center!
        // We test whether offscreenContainer is selected or onscreenContainer is selected.
        print("[Challenger Observation] Offscreen vs Onscreen: selected id = \(selected?.id ?? "none"), center = \(String(describing: selected?.center))")
        print("[Challenger Observation] Fallback center with offscreen candidate = \(fallbackCenterWithOffscreen)")
    }

    // MARK: - 3. TargetElementId and TargetCenter Non-Nil / Grounding Validation

    @Test("Grounding: When scroll container candidates are provided, targetElementId and targetCenter are NEVER nil")
    func testContainerCandidatesYieldNonNilTargetIdAndCenter() {
        let engine = TypeSafeDecisionEngine()
        let containerRoles = ["AXScrollArea", "AXWebArea", "AXTable", "AXList", "AXOutline"]

        for role in containerRoles {
            let container = UIElementCandidate(
                id: "container_\(role)",
                role: role,
                label: "Content View",
                bounds: CGRect(x: 50, y: 50, width: 500, height: 400)
            )

            let decision = engine.fallbackLocalDecision(
                goal: "Scroll down",
                candidates: [container]
            )

            #expect(decision.action == .scroll)
            #expect(decision.targetElementId == "container_\(role)", "Container role \(role) MUST populate targetElementId")
            #expect(decision.targetCenter != nil, "Container role \(role) MUST populate targetCenter")
            #expect(decision.targetCenter == CGPoint(x: 300, y: 250))
            #expect(decision.coordinates == CGPoint(x: 300, y: 250))
        }
    }

    @Test("Grounding: When ONLY non-container candidates are provided, targetCenter is ALWAYS non-nil")
    func testNonContainerCandidatesYieldCentroidTargetCenter() {
        let engine = TypeSafeDecisionEngine()
        let nonContainerCandidates = [
            UIElementCandidate(
                id: "btn_ok",
                role: "AXButton",
                label: "OK",
                bounds: CGRect(x: 100, y: 100, width: 80, height: 30)
            ),
            UIElementCandidate(
                id: "btn_cancel",
                role: "AXButton",
                label: "Cancel",
                bounds: CGRect(x: 200, y: 100, width: 80, height: 30)
            )
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down",
            candidates: nonContainerCandidates
        )

        #expect(decision.action == .scroll)
        // targetCenter MUST be non-nil and grounded to candidate centroid
        #expect(decision.targetCenter != nil, "targetCenter must never be nil when candidates are provided")
        #expect(decision.targetCenter?.x == 190, "Centroid x must be (100 + 280) / 2 = 190")
        #expect(decision.targetCenter?.y == 115, "Centroid y must be (100 + 130) / 2 = 115")

        // targetElementId is nil because no candidate is a container
        print("[Challenger Observation] When only non-container candidates exist: targetElementId = \(decision.targetElementId ?? "nil"), targetCenter = \(String(describing: decision.targetCenter))")
    }

    @Test("Grounding: When candidate list is completely empty, targetCenter is still non-nil (desktop center)")
    func testEmptyCandidatesYieldsNonNilTargetCenter() {
        let engine = TypeSafeDecisionEngine()
        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down",
            candidates: []
        )

        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == nil)
        #expect(decision.targetCenter != nil, "targetCenter must never be nil even when candidate list is empty")
    }

    // MARK: - 4. Stagnation Adaptation Ladder & Escalation Guards

    @Test("Stagnation: Consecutive unchanged scrolls trigger Tier 1 PageDown with preserved container coordinates")
    func testStagnationTier1PreservesContainerCoordinates() {
        let engine = TypeSafeDecisionEngine()
        let container = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 200, y: 100, width: 600, height: 800)
        )
        let priorAction = ComputerActionDecision(
            targetElementId: "feed_scroll",
            action: .scroll,
            confidence: 0.85,
            targetCenter: CGPoint(x: 500, y: 500)
        )
        let priorStep = LoopStepRecord(stepNumber: 1, subgoalId: "sg1", action: priorAction)
        let diff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down feed",
            candidates: [container],
            history: [priorStep],
            lastDiff: diff
        )

        #expect(decision.action == .keyPress)
        #expect(decision.keyCombination == ["PageDown"])
        #expect(decision.targetElementId == "feed_scroll")
        #expect(decision.targetCenter == CGPoint(x: 500, y: 500), "Tier 1 keyPress MUST retain container center coordinates")
    }

    @Test("Stagnation: When keyboard navigation is also stagnant, Tier 2 concludes subgoal")
    func testStagnationTier2ConcludesSubgoalWhenKeyNavFails() {
        let engine = TypeSafeDecisionEngine()
        let container = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 200, y: 100, width: 600, height: 800)
        )
        let step1 = LoopStepRecord(
            stepNumber: 1,
            subgoalId: "sg1",
            action: ComputerActionDecision(targetElementId: "feed_scroll", action: .scroll, confidence: 0.85)
        )
        let step2 = LoopStepRecord(
            stepNumber: 2,
            subgoalId: "sg1",
            action: ComputerActionDecision(targetElementId: "feed_scroll", action: .keyPress, confidence: 0.85, keyCombination: ["PageDown"])
        )
        let diff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down feed",
            candidates: [container],
            history: [step1, step2],
            lastDiff: diff
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true, "Tier 2 must conclude subgoal to break stagnation loop")
        #expect(decision.confidence >= 0.80)
    }

    @Test("Stagnation: High escalation risk (2 escalations) triggers immediate subgoal conclusion")
    func testStagnationTier2HighEscalationRisk() {
        let engine = TypeSafeDecisionEngine()
        let container = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 200, y: 100, width: 600, height: 800)
        )
        let escalations = [
            EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "Stagnant scroll 1"), timestamp: Date()),
            EscalationRecord(attempt: 2, reason: .actionStagnant(reason: "Stagnant scroll 2"), timestamp: Date())
        ]
        let diff = UIStateDiff(titleChanged: false, focusChanged: false)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down feed",
            candidates: [container],
            recentEscalations: escalations,
            lastDiff: diff
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true, "Must conclude before 3rd escalation trips failure threshold")
    }

    // MARK: - 5. Token Matching & Multi-Attribute Scoring Boundary Stress

    @Test("Matching: Token matching matches candidate by Value when label is missing")
    func testTokenMatchingMatchesByValue() {
        let engine = TypeSafeDecisionEngine()
        let candidate = UIElementCandidate(
            id: "user_name_input",
            role: "AXTextField",
            label: "", // Empty label
            value: "山田太郎",
            bounds: CGRect(x: 100, y: 100, width: 200, height: 30)
        )

        let decision = engine.fallbackLocalDecision(
            goal: "山田太郎を入力して",
            candidates: [candidate]
        )

        #expect(decision.targetElementId == "user_name_input")
        #expect(decision.action == .click || decision.action == .typeText)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Matching: Strips planner retry prefix and matches underlying intent")
    func testStripsPlannerRetryPrefix() {
        let engine = TypeSafeDecisionEngine()
        let button = UIElementCandidate(
            id: "btn_save",
            role: "AXButton",
            label: "保存",
            bounds: CGRect(x: 300, y: 300, width: 100, height: 40)
        )

        let decision = engine.fallbackLocalDecision(
            goal: "Interact with alternative interactive element for: 保存をクリックして",
            candidates: [button]
        )

        #expect(decision.targetElementId == "btn_save")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }
}
