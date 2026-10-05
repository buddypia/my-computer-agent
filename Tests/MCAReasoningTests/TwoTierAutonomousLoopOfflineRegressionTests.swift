import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

// MARK: - Mock Infrastructure for Offline Regression Suite

/// Declarative builder for creating deterministic desktop UI state snapshots and candidate hierarchies.
struct MockWindowContext: Sendable {
    var title: String = "Test Application"
    var bundleId: String = "com.apple.Safari"
    var appName: String = "Safari"
    var windowBounds: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var candidates: [UIElementCandidate] = []
    var focusedId: String? = nil

    static func feedScenario(hasScrollArea: Bool = true, itemCount: Int = 3) -> MockWindowContext {
        var elements: [UIElementCandidate] = []
        if hasScrollArea {
            elements.append(UIElementCandidate(
                id: "feed_scroll_container",
                role: "AXScrollArea",
                label: "Timeline Feed",
                bounds: CGRect(x: 100, y: 100, width: 600, height: 600)
            ))
        }
        for i in 1...itemCount {
            elements.append(UIElementCandidate(
                id: "post_item_\(i)",
                role: "AXGroup",
                label: "Post Item \(i)",
                value: "Content of post \(i)",
                bounds: CGRect(x: 120, y: Double(100 + i * 120), width: 560, height: 100)
            ))
        }
        return MockWindowContext(title: "Social Feed App", candidates: elements)
    }

    static func unresponsiveModalScenario() -> MockWindowContext {
        let modal = UIElementCandidate(
            id: "alert_modal",
            role: "AXWindow",
            label: "Terms of Service Alert",
            bounds: CGRect(x: 300, y: 200, width: 500, height: 400)
        )
        let closeBtn = UIElementCandidate(
            id: "btn_close_inert",
            role: "AXButton",
            label: "Dismiss (Disabled)",
            bounds: CGRect(x: 450, y: 520, width: 120, height: 40),
            isActionable: true
        )
        return MockWindowContext(title: "System Dialog", candidates: [modal, closeBtn])
    }

    func makeSnapshot(frameHash: String? = nil) -> UIStateSnapshot {
        UIStateSnapshot(
            windowTitle: title,
            appBundleId: bundleId,
            appName: appName,
            focusedElementId: focusedId,
            visibleCandidates: candidates,
            timestamp: Date(),
            frameHash: frameHash ?? "hash_\(title.hashValue)_\(candidates.count)"
        )
    }
}

/// Actor-based mock screen perceiver conforming to UIStateProviding.
actor MockScreenPerceiver: UIStateProviding, @unchecked Sendable {
    private var snapshots: [UIStateSnapshot]
    private var currentIndex: Int = 0
    private var _capturedCount: Int = 0

    var capturedCount: Int { _capturedCount }

    init(snapshots: [UIStateSnapshot]) {
        self.snapshots = snapshots
    }

    init(repeating snapshot: UIStateSnapshot) {
        self.snapshots = [snapshot]
    }

    /// Simulates a screen that remains completely unchanged for `unchangedCount` steps,
    /// and then optionally transitions to an updated screen state.
    static func stagnant(initial: UIStateSnapshot, unchangedCount: Int = 3, followedBy: UIStateSnapshot? = nil) -> MockScreenPerceiver {
        var sequence = Array(repeating: initial, count: max(1, unchangedCount))
        if let next = followedBy {
            sequence.append(next)
        }
        return MockScreenPerceiver(snapshots: sequence)
    }

    func captureSnapshot() async throws -> UIStateSnapshot {
        _capturedCount += 1
        guard !snapshots.isEmpty else {
            return UIStateSnapshot(windowTitle: "Empty Perceiver", visibleCandidates: [])
        }
        let snap = snapshots[min(currentIndex, snapshots.count - 1)]
        if currentIndex < snapshots.count - 1 {
            currentIndex += 1
        }
        return snap
    }
}

// MARK: - Test Suite: TwoTierAutonomousLoop Offline Regression Tests

@Suite("TwoTierAutonomousLoop Offline Regression Tests (Requirements R1 - R4)")
struct TwoTierAutonomousLoopOfflineRegressionTests {

    // MARK: - Test Helpers

    private func makeCandidate(
        id: String,
        role: String = "AXButton",
        label: String = "Test Button",
        value: String? = nil,
        x: Double = 100,
        y: Double = 100,
        w: Double = 80,
        h: Double = 30,
        isActionable: Bool = true
    ) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            value: value,
            bounds: CGRect(x: x, y: y, width: w, height: h),
            isActionable: isActionable
        )
    }

    private func makeSnapshot(
        title: String = "Test Window",
        candidates: [UIElementCandidate] = [],
        focusedId: String? = nil,
        frameHash: String? = nil
    ) -> UIStateSnapshot {
        UIStateSnapshot(
            windowTitle: title,
            appBundleId: "com.apple.Safari",
            appName: "Safari",
            focusedElementId: focusedId,
            visibleCandidates: candidates,
            timestamp: Date(),
            frameHash: frameHash ?? "hash_\(title.hashValue)_\(candidates.count)"
        )
    }

    private func makeOfflineEngine(confidenceThreshold: Float = 0.80) -> TypeSafeDecisionEngine {
        let offlineEvaluator = MockTypeSafeEvaluator { _ in
            throw TypeSafeClient.ClientError.missingApiKey
        }
        return TypeSafeDecisionEngine(client: offlineEvaluator, confidenceThreshold: confidenceThreshold)
    }

    // =========================================================================
    // MARK: - CATEGORY A: STAGNANT SCROLL ADAPTATION & BOUNDARY TERMINATION (R1)
    // =========================================================================

    @Test("Category A1: Fallback scroll grounds to candidate AXScrollArea container and resolves center coordinates")
    func testA1_InitialScroll_GroundedToAXScrollAreaContainerCenter() {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 100, y: 200, w: 400, h: 600)
        let otherButton = makeCandidate(id: "btn_other", role: "AXButton", label: "Other", x: 10, y: 10, w: 50, h: 30)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down the feed to read more posts",
            candidates: [otherButton, feedArea]
        )

        #expect(decision.action == .scroll)
        #expect(decision.targetElementId == "feed_scroll")
        #expect(decision.targetCenter != nil)
        // Center of rect (x: 100, y: 200, w: 400, h: 600) is (300, 500)
        #expect(decision.targetCenter == CGPoint(x: 300, y: 500))
        #expect(decision.confidence >= 0.80)
        #expect(decision.scrollDelta?.dy != nil && decision.scrollDelta!.dy < 0)
    }

    @Test("Category A2: Coordinator dispatches grounded container center coordinates to synthetic event synthesizer")
    func testA2_InitialScroll_GroundedCoordinatesDispatchedToSynthesizer() async throws {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 100, y: 200, w: 400, h: 600)
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_s0")
        let s1 = makeSnapshot(title: "Feed View - Scrolled", candidates: [feedArea], frameHash: "hash_s1")
        let perceiver = MockScreenPerceiver(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let subgoal = Subgoal(
            id: "sg_scroll",
            description: "Scroll down the feed to read more posts",
            expectedOutcome: "title changed to Feed View - Scrolled",
            maxSteps: 3
        )
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Scroll feed")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        #expect(scrollEvents.first == CGPoint(x: 300, y: 500), "Scroll event must be grounded at container center rather than nil")
    }

    @Test("Category A3: Fallback scroll targets candidate centroid when no explicit container role is present")
    func testA3_CentroidFallbackCoordinates_WhenNoContainerAvailable() {
        let engine = makeOfflineEngine()
        let c1 = makeCandidate(id: "c1", role: "AXStaticText", label: "Row 1", x: 100, y: 100, w: 200, h: 50)
        let c2 = makeCandidate(id: "c2", role: "AXStaticText", label: "Row 2", x: 100, y: 200, w: 200, h: 50)

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll down to browse items",
            candidates: [c1, c2]
        )

        #expect(decision.action == .scroll)
        #expect(decision.targetCenter != nil, "Must resolve fallback scroll coordinates rather than nil")
        // Union of rects (100, 100, 200, 50) and (100, 200, 200, 50) spans (100, 100, 200, 150) -> centroid (200, 175)
        #expect(decision.targetCenter == CGPoint(x: 200, y: 175))
        #expect(decision.confidence >= 0.80)
    }

    @Test("Category A4: Stagnant scroll with unchanged diff adapts to PageDown keyboard navigation")
    func testA4_StagnantScrollWithUnchangedDiff_AdaptsToPageDown() {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let goal = "Scroll down the feed to read more posts"

        let initialDecision = engine.fallbackLocalDecision(goal: goal, candidates: [feedArea])
        #expect(initialDecision.action == .scroll)

        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_feed_static")
        let diff = UIStateDiff.compute(before: s0, after: s0)
        #expect(diff.isStateUnchanged)

        let step1Record = LoopStepRecord(
            stepNumber: 1,
            subgoalId: "sg_1",
            action: initialDecision,
            verificationResult: StateVerificationResult(status: .unverified, confidence: 0.2, rationale: "Unchanged")
        )

        let step2Decision = engine.fallbackLocalDecision(
            goal: goal,
            candidates: [feedArea],
            history: [step1Record],
            recentEscalations: [],
            lastDiff: diff
        )

        #expect(step2Decision.action == .keyPress)
        #expect(step2Decision.keyCombination == ["PageDown"])
        #expect(step2Decision.confidence >= 0.80)
        #expect(step2Decision.isCompleted == false)
        #expect(step2Decision.reasoning?.contains("adapting to keyboard navigation") == true)
    }

    @Test("Category A5: Stagnant upward scroll adapts to PageUp keyboard navigation")
    func testA5_StagnantUpwardScroll_AdaptsToPageUp() {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let goal = "Scroll up the feed to read earlier posts"

        let initialDecision = engine.fallbackLocalDecision(goal: goal, candidates: [feedArea])
        #expect(initialDecision.action == .scroll)

        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_feed_static")
        let diff = UIStateDiff.compute(before: s0, after: s0)

        let step1Record = LoopStepRecord(
            stepNumber: 1,
            subgoalId: "sg_1",
            action: initialDecision,
            verificationResult: StateVerificationResult(status: .unverified, confidence: 0.2, rationale: "Unchanged")
        )

        let step2Decision = engine.fallbackLocalDecision(
            goal: goal,
            candidates: [feedArea],
            history: [step1Record],
            recentEscalations: [],
            lastDiff: diff
        )

        #expect(step2Decision.action == .keyPress)
        #expect(step2Decision.keyCombination == ["PageUp"])
        #expect(step2Decision.confidence >= 0.80)
    }

    @Test("Category A6: Coordinator executes PageDown synthetically following stagnant scroll")
    func testA6_CoordinatorExecutesPageDownSynthetically() async throws {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_s0")
        let s1 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_s0") // unchanged
        let s2 = makeSnapshot(title: "Feed View - PageDown Loaded", candidates: [feedArea], frameHash: "hash_s2") // changed after key
        let perceiver = MockScreenPerceiver(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let subgoal = Subgoal(
            id: "sg_feed",
            description: "Scroll down the feed to read more posts",
            expectedOutcome: "title changed to Feed View - PageDown Loaded",
            maxSteps: 5
        )
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Read feed updates")
        #expect(summary.isSuccess)

        let recorded = synthesizer.recordedEvents
        #expect(recorded.count >= 2)
        guard case .scroll = recorded[0] else {
            Issue.record("Step 1 must be scroll, got: \(recorded[0])")
            return
        }
        // Step 2 adapts to keyPress: focus click followed by pressKey
        let keyPressEvents = recorded.compactMap { event -> String? in
            if case .pressKey(let k) = event { return k }
            return nil
        }
        #expect(!keyPressEvents.isEmpty, "Must execute pressKey event")
        #expect(keyPressEvents.first == "PageDown")
    }

    @Test("Category A7: Boundary termination concludes subgoal when keyboard navigation also produces no progress")
    func testA7_BoundaryTerminationAfterKeyboardNavStagnation() {
        let engine = makeOfflineEngine()
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let goal = "Scroll down the feed to read more posts"
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_static")
        let diff = UIStateDiff.compute(before: s0, after: s0)

        let step1Record = LoopStepRecord(
            stepNumber: 1,
            subgoalId: "sg_1",
            action: ComputerActionDecision(targetElementId: "feed_scroll", action: .scroll, confidence: 0.85, isCompleted: false),
            verificationResult: StateVerificationResult(status: .unverified, confidence: 0.2, rationale: "Unchanged")
        )
        let step2Record = LoopStepRecord(
            stepNumber: 2,
            subgoalId: "sg_1",
            action: ComputerActionDecision(targetElementId: "feed_scroll", action: .keyPress, confidence: 0.85, isCompleted: false, keyCombination: ["PageDown"]),
            verificationResult: StateVerificationResult(status: .unverified, confidence: 0.2, rationale: "Unchanged")
        )

        // Step 3: Both scroll and PageDown yielded isStateUnchanged == true
        let step3Decision = engine.fallbackLocalDecision(
            goal: goal,
            candidates: [feedArea],
            history: [step1Record, step2Record],
            recentEscalations: [],
            lastDiff: diff
        )

        #expect(step3Decision.action == .none)
        #expect(step3Decision.isCompleted == true)
        #expect(step3Decision.confidence >= 0.80)
        #expect(step3Decision.reasoning?.contains("page boundary reached or target inert") == true)
    }

    @Test("Category A8: High escalation risk immediately concludes stagnant subgoal at recovery limit")
    func testA8_HighEscalationRiskConcludesSubgoal() {
        let engine = makeOfflineEngine()
        let container = makeCandidate(id: "scroll_box", role: "AXScrollArea", label: "Feed", x: 50, y: 50, w: 400, h: 500)
        let s0 = makeSnapshot(title: "Feed View", candidates: [container], frameHash: "hash_s0")
        let unchangedDiff = UIStateDiff.compute(before: s0, after: s0)

        let esc1 = EscalationRecord(attempt: 1, reason: .actionStagnant(reason: "diff unchanged"), timestamp: Date())
        let esc2 = EscalationRecord(attempt: 2, reason: .actionStagnant(reason: "diff unchanged"), timestamp: Date())

        let decision = engine.fallbackLocalDecision(
            goal: "Scroll feed down to view updates",
            candidates: [container],
            recentEscalations: [esc1, esc2],
            lastDiff: unchangedDiff
        )

        #expect(decision.action == .none)
        #expect(decision.isCompleted == true)
        #expect(decision.confidence >= 0.80)
    }

    // =========================================================================
    // MARK: - CATEGORY B: REPLAN DE-DUPLICATION & BOILERPLATE UNNESTING (R2)
    // =========================================================================

    @Test("Category B1: stripReplanBoilerplate un-nests deeply chained and mixed-delimiter prefixes")
    func testB1_StripReplanBoilerplateChains() {
        let nested = "Navigate using alternative elements or shortcuts for: Retry after low confidence: Conclude subgoal after reaching boundary: retry: - Click Confirm"
        let unnested = DefaultSubgoalPlanner.stripReplanBoilerplate(from: nested)
        #expect(unnested == "Click Confirm")

        let onlyPrefix = "Retry after low confidence: Navigate using alternative elements or shortcuts for:"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: onlyPrefix).isEmpty)
    }

    @Test("Category B2: stripStagnantKeywords respects word boundaries and protects compound words")
    func testB2_StripStagnantKeywordsWordBoundaries() {
        let downloadGoal = "Download spreadsheet and update feedback form"
        let stripped = DefaultSubgoalPlanner.stripStagnantKeywords(from: downloadGoal)
        #expect(stripped == "Download spreadsheet and update feedback form", "Compound words containing down/feed must not be corrupted")

        let stagnantGoal = "Scroll feed down to see more"
        let strippedStagnant = DefaultSubgoalPlanner.stripStagnantKeywords(from: stagnantGoal)
        #expect(!strippedStagnant.lowercased().contains("scroll"))
        #expect(!strippedStagnant.lowercased().contains("feed"))

        let japaneseStagnant = "タイムラインをスクロールして最新情報を探す"
        let strippedJapanese = DefaultSubgoalPlanner.stripStagnantKeywords(from: japaneseStagnant)
        #expect(!strippedJapanese.contains("スクロール"))
        #expect(!strippedJapanese.contains("タイムライン"))
    }

    @Test("Category B3: nextRetryId produces strictly monotonic retry attempt identifiers")
    func testB3_NextRetryIdProgression() {
        let r1 = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_1", suffix: "alt")
        #expect(r1.id == "subgoal_1_alt" && r1.attempt == 1)

        let r2 = DefaultSubgoalPlanner.nextRetryId(from: r1.id, suffix: "alt")
        #expect(r2.id == "subgoal_1_alt_2" && r2.attempt == 2)

        let r3 = DefaultSubgoalPlanner.nextRetryId(from: r2.id, suffix: "alt")
        #expect(r3.id == "subgoal_1_alt_3" && r3.attempt == 3)

        // Low-confidence suffix
        let conf1 = DefaultSubgoalPlanner.nextRetryId(from: "sg_search", suffix: "retry_conf")
        #expect(conf1.id == "sg_search_retry_conf" && conf1.attempt == 1)

        let conf2 = DefaultSubgoalPlanner.nextRetryId(from: conf1.id, suffix: "retry_conf")
        #expect(conf2.id == "sg_search_retry_conf_2" && conf2.attempt == 2)
    }

    @Test("Category B4: heuristicReplan strips stagnant keywords and generates alternative navigation subgoal")
    func testB4_HeuristicReplanAdaptsStagnantSubgoal() {
        let failed = Subgoal(id: "sg_scroll", description: "Scroll down feed to find item", expectedOutcome: "item visible", maxSteps: 3)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failed, reason: .actionStagnant(reason: "Diff unchanged"))

        if case .retrySubgoal(let retry) = resolution {
            #expect(retry.id == "sg_scroll_alt")
            #expect(retry.description.contains("Navigate using alternative elements or shortcuts for:"))
            #expect(!retry.description.lowercased().contains("scroll"))
        } else {
            Issue.record("Expected retrySubgoal, got: \(resolution)")
        }
    }

    @Test("Category B5: heuristic recovery stops without proving an outcome")
    func testB5_HeuristicReplanConcludesAtBoundary() {
        let subgoal = Subgoal(
            id: "sg_scroll_feed",
            description: "Scroll down the feed to read more updates",
            expectedOutcome: "read more updates",
            maxSteps: 5
        )
        let reason = EscalationReason.actionStagnant(
            reason: "Scroll and keyboard navigation produced no state change; page boundary reached or target inert. Concluding subgoal (offline fallback)"
        )

        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: subgoal, reason: reason)

        guard case .abort(let reason) = resolution else {
            Issue.record("Expected abort on attempt 1 for boundary stagnation, got: \(resolution)")
            return
        }
        #expect(reason.contains("page boundary or recovery limit"))
    }

    // =========================================================================
    // MARK: - CATEGORY C: LOW-CONFIDENCE CIRCUIT BREAKER & FALLTHROUGH RECOVERY (R3)
    // =========================================================================

    @Test("Category C1: Token candidate matching matches compound label, avoiding 0.00 confidence fallthrough")
    func testC1_TokenCandidateMatching_CompoundLabel() {
        let engine = makeOfflineEngine()
        let submitBtn = makeCandidate(id: "btn_reg_submit", role: "AXButton", label: "Submit Application Form", x: 100, y: 100)
        let helpBtn = makeCandidate(id: "btn_help", role: "AXButton", label: "Help & FAQ", x: 200, y: 100)

        let decision = engine.fallbackLocalDecision(
            goal: "Click Submit",
            candidates: [helpBtn, submitBtn]
        )

        #expect(decision.targetElementId == "btn_reg_submit")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    @Test("Category C2: Token candidate matching matches value attribute when candidate label is empty")
    func testC2_TokenCandidateMatching_ValueAttribute() {
        let engine = makeOfflineEngine()
        let searchField = makeCandidate(id: "field_query", role: "AXTextField", label: "", value: "Search or enter query URL")

        let decision = engine.fallbackLocalDecision(
            goal: "Type swift into search",
            candidates: [searchField]
        )

        #expect(decision.targetElementId == "field_query")
        #expect(decision.action == .typeText)
        #expect(decision.textInput == "swift")
        #expect(decision.confidence >= 0.80)
    }

    @Test("Category C3: Japanese script segmentation and particle stripping grounds target correctly")
    func testC3_TokenCandidateMatching_JapaneseScript() {
        let engine = makeOfflineEngine()
        let settingsBtn = makeCandidate(id: "btn_settings", role: "AXButton", label: "設定")
        let helpBtn = makeCandidate(id: "btn_help", role: "AXButton", label: "ヘルプ")

        let decision = engine.fallbackLocalDecision(
            goal: "設定ボタンをクリックしてプロフィールを開く",
            candidates: [helpBtn, settingsBtn]
        )

        #expect(decision.targetElementId == "btn_settings")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Category C4: Replan boilerplate prefixes are stripped to maintain high confidence on retry")
    func testC4_TokenCandidateMatching_ReplanPrefixUnwrapped() {
        let engine = makeOfflineEngine()
        let saveBtn = makeCandidate(id: "btn_save", role: "AXButton", label: "Save Document Changes")

        let retryGoal = "Interact with alternative interactive element for: Save Document"
        let decision = engine.fallbackLocalDecision(
            goal: retryGoal,
            candidates: [saveBtn]
        )

        #expect(decision.targetElementId == "btn_save")
        #expect(decision.action == .click)
        #expect(decision.confidence >= 0.80)
    }

    @Test("Category C5: empty candidates remain unresolved after failed attempts")
    func testC5_CircuitBreaker_EmptyCandidatesGracefulConclusion() async throws {
        let engine = makeOfflineEngine()
        let priorEscalations = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.20, threshold: 0.80)),
            EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.20, threshold: 0.80))
        ]

        let decision = try await engine.decideNextAction(
            goal: "Click phantom button",
            candidates: [],
            recentEscalations: priorEscalations
        )

        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: decision))
        #expect(decision.reasoning?.contains("remains unresolved") == true)
    }

    @Test("Category C6: an unmatched target remains unresolved after failed attempts")
    func testC6_CircuitBreaker_UnresolvableCandidatesGracefulConclusion() {
        let engine = makeOfflineEngine()
        let randomBtn = makeCandidate(id: "btn_other", role: "AXButton", label: "Help Center", x: 100, y: 100)
        let esc1 = EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.0, threshold: 0.80), timestamp: Date())
        let esc2 = EscalationRecord(attempt: 2, reason: .lowConfidence(confidence: 0.0, threshold: 0.80), timestamp: Date())

        let decision = engine.fallbackLocalDecision(
            goal: "Click Delete Account Confirm Dialog",
            candidates: [randomBtn],
            recentEscalations: [esc1, esc2]
        )

        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil && decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(decision.confidence == 0.0)
        #expect(engine.shouldEscalate(decision: decision))
        #expect(decision.reasoning?.contains("remains unresolved") == true)
    }

    @Test("Category C7: First low-confidence escalation explores alternative actionable element before circuit breaking")
    func testC7_AlternativeInteractiveElementOnFirstLowConfidenceEscalation() {
        let engine = makeOfflineEngine()
        let actionableBtn = makeCandidate(id: "btn_actionable", role: "AXButton", label: "Generic Action", isActionable: true)
        let nonActionable = makeCandidate(id: "txt_info", role: "AXStaticText", label: "Info", isActionable: false)

        let singleEscalation = [
            EscalationRecord(attempt: 1, reason: .lowConfidence(confidence: 0.30, threshold: 0.80))
        ]

        let decision = engine.fallbackLocalDecision(
            goal: "Click Unmatched Phantom",
            candidates: [nonActionable, actionableBtn],
            recentEscalations: singleEscalation
        )

        // Attempt 1 selects alternative interactive element
        #expect(decision.targetElementId == "btn_actionable")
        #expect(decision.action == .click)
        #expect(decision.confidence == 0.80)
        #expect(decision.isCompleted == false)
    }

    @Test("Category C8: Screen state diff change (!diff.isStateUnchanged) resets consecutiveEscalations across subgoals")
    func testC8_DiffReset_VerifiedScreenProgressResetsConsecutiveEscalations() async throws {
        let engine = makeOfflineEngine()
        let btn1 = makeCandidate(id: "btn_step1", role: "AXButton", label: "Proceed Step 1")
        let btn2 = makeCandidate(id: "btn_step2", role: "AXButton", label: "Proceed Step 2")

        let s0 = makeSnapshot(title: "Step 1 Window", candidates: [btn1], frameHash: "hash_step1")
        let s1 = makeSnapshot(title: "Step 2 Window", candidates: [btn2], frameHash: "hash_step2") // Title change -> !diff.isStateUnchanged
        let s2 = makeSnapshot(title: "Step 2 Window - Completed", candidates: [], frameHash: "hash_step2_completed")
        let perceiver = MockScreenPerceiver(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Unknown Subgoal 1", expectedOutcome: "title changed to Step 2 Window", maxSteps: 3),
                    Subgoal(id: "sg_2", description: "Unknown Subgoal 2", expectedOutcome: "title changed to Step 2 Window - Completed", maxSteps: 3)
                ])
            },
            escalationHandler: { reason, subgoal, _, _ in
                if subgoal.id == "sg_1" {
                    return .replacePlan([
                        Subgoal(id: "sg_1_fixed", description: "Click Proceed Step 1", expectedOutcome: "title changed to Step 2 Window", maxSteps: 3),
                        Subgoal(id: "sg_2", description: "Unknown Subgoal 2", expectedOutcome: "title changed to Step 2 Window - Completed", maxSteps: 3)
                    ])
                } else if subgoal.id == "sg_2" {
                    return .replacePlan([
                        Subgoal(id: "sg_2_fixed", description: "Click Proceed Step 2", expectedOutcome: "title changed to Step 2 Window - Completed", maxSteps: 3)
                    ])
                }
                return .abort(reason: "Unexpected escalation: \(reason)")
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2 // Strict limit: 2 consecutive escalations would trip if not reset

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Two-step workflow with recovery")
        #expect(summary.isSuccess)
        #expect(summary.subgoalsCompleted == 2)
    }

    @Test("Category C9: Layout mutation (added elements) resets consecutiveEscalations counter")
    func testC9_DiffReset_LayoutMutationResetsEscalationCounter() async throws {
        let engine = makeOfflineEngine()
        let initialBtn = makeCandidate(id: "btn_open", role: "AXButton", label: "Open Modal")
        let modalBtn = makeCandidate(id: "btn_confirm", role: "AXButton", label: "Confirm Modal")

        let s0 = makeSnapshot(title: "Main Window", candidates: [initialBtn], frameHash: "hash_main")
        let s1 = makeSnapshot(title: "Main Window", candidates: [initialBtn, modalBtn], frameHash: "hash_modal") // Candidate added -> layoutMutated
        let perceiver = MockScreenPerceiver(snapshots: [s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_open", description: "Unmatched open", expectedOutcome: "modal appears", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .replacePlan([
                    Subgoal(id: "sg_open_fixed", description: "Click Open Modal", expectedOutcome: "modal appears", maxSteps: 2)
                ])
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Open modal and verify reset")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    // =========================================================================
    // MARK: - CATEGORY D: END-TO-END AUTONOMOUS LOOP WORKFLOW WITHOUT 3-STRIKE FAILURE (R4)
    // =========================================================================

    @Test("Category D1: E2E Reproduction of Original 3-Strike Stagnant Scroll Failure cleanly adapts and completes")
    func testD1_OriginalStagnantScrollFailureReproduction_RecoversCleanly() async throws {
        // Setup: Unkeyed engine, stagnant feed scenario (unchanging frameHash for 5 steps)
        let engine = makeOfflineEngine()
        let context = MockWindowContext.feedScenario(hasScrollArea: true, itemCount: 3)
        let staticSnapshot = context.makeSnapshot(frameHash: "hash_static_feed")
        let perceiver = MockScreenPerceiver.stagnant(initial: staticSnapshot, unchangedCount: 5)
        let synthesizer = MockEventSynthesizer()

        // Goal matching the original prompt, using "posts" to test downward PageDown adaptation
        let subgoal = Subgoal(
            id: "subgoal_feed_read",
            description: "Scroll feed down to read latest posts",
            expectedOutcome: "", // Empty expected outcome allows boundary completion
            maxSteps: 6
        )
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        // Execute: In the buggy implementation, this threw "Exceeded maximum consecutive escalations (3)".
        // In the fixed implementation, it must return a successful ExecutionSummary.
        let summary = try await coordinator.execute(goal: "Browse feed")

        #expect(summary.isSuccess, "Coordinator must complete cleanly without 3-strike escalation failure")
        #expect(summary.totalSteps >= 2, "Loop must have taken at least 2 steps before adapting and concluding")

        // Verify that initial step executed scroll
        let scrollEvents = synthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }
        #expect(!scrollEvents.isEmpty, "Initial step must execute .scroll")

        // Verify that subsequent step adapted to keyboard navigation (PageDown)
        let keyEvents = synthesizer.recordedEvents.filter {
            if case .pressKey(let k) = $0 { return k == "PageDown" }
            return false
        }
        #expect(!keyEvents.isEmpty, "Stagnant diff must trigger keyboard navigation adaptation [PageDown]")
    }

    @Test("Category D2: static feed stops as unverified with one escalation")
    func testD2_BoundaryStagnationWithExplicitOutcome_CompletesCleanlyWithOneEscalation() async throws {
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_feed_static")
        let perceiver = MockScreenPerceiver(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let engine = makeOfflineEngine()

        let subgoal = Subgoal(
            id: "sg_scroll_to_end",
            description: "Scroll down the feed to read more posts",
            expectedOutcome: "more posts loaded",
            maxSteps: 10
        )

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [subgoal])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failedSubgoal, reason: reason)
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Scroll down feed to read more posts")
            Issue.record("A static feed with an unverified outcome was reported as successful")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                Issue.record("Unexpected failure: \(error)")
                return
            }
            #expect(reason.contains("Outcome unverified"))
            #expect(reason.contains("boundary or recovery limit"))
        }

        #expect(synthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }.count == 1)
        #expect(synthesizer.recordedEvents.filter { if case .pressKey("PageDown") = $0 { return true }; return false }.count == 1)

        let recorded = synthesizer.recordedEvents
        #expect(recorded.count >= 2)
        guard case .scroll = recorded[0] else {
            Issue.record("Step 1 must be scroll, got: \(recorded[0])")
            return
        }
        let keyPressEvents = recorded.compactMap { event -> String? in
            if case .pressKey(let k) = event { return k }
            return nil
        }
        #expect(!keyPressEvents.isEmpty)
        #expect(keyPressEvents.first == "PageDown")

        let escalations = await planner.recordedEscalations
        #expect(escalations.count == 1, "Must undergo exactly 1 escalation (attempt 1) resolved by abort")
        if let firstEsc = escalations.first {
            #expect(firstEsc.reason.isActionStagnant)
        }
    }

    @Test("Category D3: Multi-subgoal mission recovers from stagnant scroll in Subgoal 1 and executes Subgoal 2")
    func testD3_MultiSubgoalMission_StagnantScrollThenSuccessfulAction() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline", x: 50, y: 50, w: 400, h: 500)
        let acceptBtn = makeCandidate(id: "btn_accept", role: "AXButton", label: "Accept Terms", x: 50, y: 580, w: 120, h: 40)

        let s0 = makeSnapshot(title: "Terms Window", candidates: [scrollArea, acceptBtn], frameHash: "hash_s0")
        let s1 = makeSnapshot(title: "Terms Window", candidates: [scrollArea, acceptBtn], frameHash: "hash_s0")
        let s2 = makeSnapshot(title: "Terms Window - Accepted", candidates: [scrollArea], frameHash: "hash_s2")

        let perceiver = MockScreenPerceiver(snapshots: [s0, s1, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg1", description: "Scroll feed down to read terms", expectedOutcome: "", maxSteps: 4)
        let sg2 = Subgoal(id: "sg2", description: "Click Accept Terms", expectedOutcome: "window title changed to Terms Window - Accepted", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Review and accept terms")

        #expect(summary.isSuccess)
        #expect(summary.subgoalsCompleted == 2)

        let clickEvents = synthesizer.recordedEvents.filter { if case .click = $0 { return true }; return false }
        #expect(!clickEvents.isEmpty, "Subgoal 2 must successfully execute click on Accept Terms button")
    }

    @Test("Category D4: Unresponsive modal dialog adapts away from stagnant actions without crashing")
    func testD4_UnresponsiveModalDialog_AdaptsAndConcludes() async throws {
        let engine = makeOfflineEngine()
        let context = MockWindowContext.unresponsiveModalScenario()
        let s0 = context.makeSnapshot(frameHash: "hash_modal_inert")
        let perceiver = MockScreenPerceiver.stagnant(initial: s0, unchangedCount: 6)
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_modal", description: "Scroll down dialog", expectedOutcome: "", maxSteps: 5)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Dismiss alert")
        #expect(summary.isSuccess)
    }

    @Test("Category D5: All synthesized scroll actions have non-nil target coordinates dispatched")
    func testD5_AllScrollActionsDispatchedWithCoordinates() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "container", role: "AXScrollArea", label: "List", x: 200, y: 300, w: 400, h: 400)
        let s0 = makeSnapshot(title: "List Window", candidates: [scrollArea], frameHash: "h0")
        let s1 = makeSnapshot(title: "List Window Scrolled", candidates: [scrollArea], frameHash: "h1")

        let perceiver = MockScreenPerceiver(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_scroll", description: "Scroll down list", expectedOutcome: "window title changed to List Window Scrolled", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: .testing
        )

        _ = try await coordinator.execute(goal: "Scroll list")

        let scrollEvents = synthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }
        #expect(!scrollEvents.isEmpty)
        for event in scrollEvents {
            if case .scroll(_, _, let point, _) = event {
                #expect(point != nil, "All synthesized scroll events must have non-nil coordinates")
            }
        }
    }

    @Test("Category D6: Unmitigated legacy comparison trips three-strike limit as expected")
    func testD6_UnmitigatedLegacyComparison_TripsThreeStrikeLimit() async throws {
        let feedArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedArea], frameHash: "hash_s0")
        let perceiver = MockScreenPerceiver(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        // Simulate legacy ungrounded decision engine (pre-fix behavior):
        // Scripted to output ungrounded scroll on target=none and ignore diff feedback
        let legacyEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "none",
            targetConfidence: 0.85,
            actionChoice: "scroll",
            scrollDelta: "down"
        )
        let legacyEngine = TypeSafeDecisionEngine(client: legacyEvaluator)

        // Legacy planner stubbornly retries identical subgoal
        let subgoal = Subgoal(
            id: "sg_scroll_legacy",
            description: "Scroll down the feed to read more updates",
            expectedOutcome: "read more updates",
            maxSteps: 10
        )
        let legacyPlanner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [subgoal])
            },
            escalationHandler: { _, currentSubgoal, _, _ in
                .retrySubgoal(currentSubgoal)
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 3
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: legacyPlanner,
            decisionEngine: legacyEngine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Scroll down the feed to read more updates")
            Issue.record("Expected coordinator to abort with Exceeded maximum consecutive escalations (3)")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                Issue.record("Expected escalationFailed, got: \(error)")
                return
            }
            #expect(reason.contains("Exceeded maximum consecutive escalations (3)"))
        }
    }
}
