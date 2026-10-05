import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("Challenger M3-2: Categories B & D Empirical Stress & Adversarial Hardening Tests")
struct TwoTierAutonomousLoopCategoriesBDChallengerTests {

    // =========================================================================
    // SECTION 1: CATEGORY B ADVERSARIAL STRESS (REPLAN BOILERPLATE & KEYWORDS)
    // =========================================================================

    @Test("Adversarial B.1: stripReplanBoilerplate handles 50-level nested recursive prefix chain")
    func testDeeplyChainedPrefixes50Levels() {
        let prefixes = [
            "navigate using alternative elements or shortcuts for: ",
            "interact with alternative interactive element for: ",
            "retry after low confidence: ",
            "retry subgoal with adjusted interaction: ",
            "conclude subgoal after reaching boundary: ",
            "wait for ui to finish loading or rendering: ",
            "retry: ",
            "for: ",
            "- ",
            ": "
        ]

        var input = "Click Checkout Button"
        for i in 0..<50 {
            input = prefixes[i % prefixes.count] + input
        }

        let stripped = DefaultSubgoalPlanner.stripReplanBoilerplate(from: input)
        #expect(stripped == "Click Checkout Button")
    }

    @Test("Adversarial B.2: stripReplanBoilerplate handles exotic delimiters, whitespace, and tabs")
    func testExoticDelimitersAndTabs() {
        let dirty = "  \t \n - :   retry after low confidence: \t \n - : retry:   \t Click Submit  \t \n - : "
        let stripped = DefaultSubgoalPlanner.stripReplanBoilerplate(from: dirty)
        #expect(stripped == "Click Submit")

        let onlyDelimiters = "  \t \n - : , : -   "
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: onlyDelimiters).isEmpty)
    }

    @Test("Adversarial B.3: stripStagnantKeywords protects complex compound words containing keywords")
    func testCompoundWordProtection() {
        // Words containing 'down': download, slowdown, countdown, downside, downturn, knockdown
        // Words containing 'feed': feedback, feedforward, feeder, feeding
        // Words containing 'scroll': scrollbar, scrollview, autoscroll
        // Words containing 'up': upload, update, popup, setup, backup, upgrade, upkeep
        let sentence = "Download the feedback form, setup the backup, update the scrollbar, and review downside risk"
        let result = DefaultSubgoalPlanner.stripStagnantKeywords(from: sentence)
        #expect(result == sentence, "Compound words must remain intact without partial word corruption")
    }

    @Test("Adversarial B.4: stripStagnantKeywords strips standalone stagnant words and cleans chained prepositions")
    func testStandaloneStagnantWordStripping() {
        let text1 = "Scroll feed down to see more posts"
        let stripped1 = DefaultSubgoalPlanner.stripStagnantKeywords(from: text1)
        #expect(stripped1 == "see more posts")

        let text2 = "Timeline feed scroll up to inspect header"
        let stripped2 = DefaultSubgoalPlanner.stripStagnantKeywords(from: text2)
        #expect(stripped2 == "inspect header")

        let text3 = "Scroll down"
        let stripped3 = DefaultSubgoalPlanner.stripStagnantKeywords(from: text3)
        #expect(stripped3.isEmpty)
    }

    @Test("Adversarial B.5: stripStagnantKeywords handles complex Japanese grammatical contexts")
    func testJapaneseStagnantTermAndParticleStripping() {
        let jp1 = "タイムラインをスクロールして最新情報を探す"
        let stripped1 = DefaultSubgoalPlanner.stripStagnantKeywords(from: jp1)
        #expect(stripped1 == "最新情報を探す")

        let jp2 = "フィードを下にスクロールして次へ進む"
        let stripped2 = DefaultSubgoalPlanner.stripStagnantKeywords(from: jp2)
        #expect(stripped2 == "次へ進む")

        let jp3 = "上にスクロールをして完了する"
        let stripped3 = DefaultSubgoalPlanner.stripStagnantKeywords(from: jp3)
        #expect(stripped3 == "完了する")
    }

    @Test("Adversarial B.6: nextRetryId monotonically advances through high attempt numbers")
    func testNextRetryIdHighAttempts() {
        var currentId = "subgoal_checkout"
        for expectedAttempt in 1...10 {
            let result = DefaultSubgoalPlanner.nextRetryId(from: currentId, suffix: "alt")
            #expect(result.attempt == expectedAttempt)
            if expectedAttempt == 1 {
                #expect(result.id == "subgoal_checkout_alt")
            } else {
                #expect(result.id == "subgoal_checkout_alt_\(expectedAttempt)")
            }
            currentId = result.id
        }
    }

    @Test("Adversarial B.7: heuristicReplan terminates boundary stagnation on attempt 1 without cascading")
    func testHeuristicReplanImmediateBoundaryTermination() {
        let sg = Subgoal(id: "sg_1", description: "Scroll down feed", expectedOutcome: "", maxSteps: 3)
        
        // With "boundary" keyword in reason
        let resBoundary = DefaultSubgoalPlanner.heuristicReplan(
            failedSubgoal: sg,
            reason: .actionStagnant(reason: "page boundary reached")
        )
        if case .abort(let reason) = resBoundary {
            #expect(reason.contains("page boundary or recovery limit"))
        } else {
            Issue.record("Expected abort for boundary stagnation, got \(resBoundary)")
        }

        // With "inert" keyword in reason
        let resInert = DefaultSubgoalPlanner.heuristicReplan(
            failedSubgoal: sg,
            reason: .actionStagnant(reason: "target inert")
        )
        if case .abort(let reason) = resInert {
            #expect(reason.contains("Outcome unverified"))
        } else {
            Issue.record("Expected abort for inert stagnation, got \(resInert)")
        }
    }

    // =========================================================================
    // SECTION 2: CATEGORY D ADVERSARIAL STRESS (E2E REPRODUCTION & RECOVERY)
    // =========================================================================

    @Test("Adversarial D.1: Legacy failure trips exactly at custom maxConsecutiveEscalations limit")
    func testLegacyFailureTripsAtCustomLimit() async throws {
        // Test with maxConsecutiveEscalations = 2
        let feedArea = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 50, y: 50, width: 400, height: 600)
        )
        let s0 = UIStateSnapshot(windowTitle: "Feed View", visibleCandidates: [feedArea], frameHash: "hash_s0")
        let perceiver = MockScreenPerceiver(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let legacyEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "none",
            targetConfidence: 0.85,
            actionChoice: "scroll",
            scrollDelta: "down"
        )
        let legacyEngine = TypeSafeDecisionEngine(client: legacyEvaluator)

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
        config.maxConsecutiveEscalations = 2
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: legacyPlanner,
            decisionEngine: legacyEngine,
            synthesizer: synthesizer,
            snapshotProvider: perceiver,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Scroll feed")
            Issue.record("Should have failed with escalationFailed")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                Issue.record("Expected escalationFailed, got \(error)")
                return
            }
            #expect(reason.contains("Exceeded maximum consecutive escalations (2)"))
        }
    }

    @Test("Adversarial D.2: Fixed coordinator transitions from scroll to PageDown and succeeds when screen advances on PageDown")
    func testFixedCoordinatorRecoversWhenPageDownAdvancesScreen() async throws {
        let offlineEvaluator = MockTypeSafeEvaluator { _ in
            throw TypeSafeClient.ClientError.missingApiKey
        }
        let engine = TypeSafeDecisionEngine(client: offlineEvaluator, confidenceThreshold: 0.80)

        let feedArea = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 50, y: 50, width: 400, height: 600)
        )
        let s0 = UIStateSnapshot(windowTitle: "Feed Page 1", visibleCandidates: [feedArea], frameHash: "hash_s0")
        let s1 = UIStateSnapshot(windowTitle: "Feed Page 1", visibleCandidates: [feedArea], frameHash: "hash_s0") // stagnant after scroll
        let s2 = UIStateSnapshot(windowTitle: "Feed Page 2", visibleCandidates: [feedArea], frameHash: "hash_s2") // changed after PageDown!
        
        let perceiver = MockScreenPerceiver(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let subgoal = Subgoal(
            id: "sg_feed_advance",
            description: "Scroll down the feed to read posts",
            expectedOutcome: "window title changed to Feed Page 2",
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

        let summary = try await coordinator.execute(goal: "Browse feed")
        #expect(summary.isSuccess)
        #expect(summary.subgoalsCompleted == 1)

        let recorded = synthesizer.recordedEvents
        #expect(recorded.count >= 2)
        // First action was scroll
        guard case .scroll = recorded[0] else {
            Issue.record("Expected first action to be scroll, got \(recorded[0])")
            return
        }
        // Second action was keyPress(PageDown)
        let keyPresses = recorded.compactMap { event -> String? in
            if case .pressKey(let k) = event { return k }
            return nil
        }
        #expect(keyPresses.contains("PageDown"))
    }

    @Test("Adversarial D.3: Zero consecutive escalations occur during full stagnant scroll recovery cycle")
    func testZeroEscalationsDuringCleanStagnantScrollRecovery() async throws {
        let offlineEvaluator = MockTypeSafeEvaluator { _ in
            throw TypeSafeClient.ClientError.missingApiKey
        }
        let engine = TypeSafeDecisionEngine(client: offlineEvaluator, confidenceThreshold: 0.80)

        let feedArea = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 50, y: 50, width: 400, height: 600)
        )
        let s0 = UIStateSnapshot(windowTitle: "Feed Page 1", visibleCandidates: [feedArea], frameHash: "hash_static")
        let perceiver = MockScreenPerceiver(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let subgoal = Subgoal(
            id: "sg_feed_stagnant",
            description: "Scroll feed down to read latest posts",
            expectedOutcome: "",
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

        let summary = try await coordinator.execute(goal: "Browse feed")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 3) // 1: scroll, 2: PageDown, 3: boundary conclusion (action: .none, isCompleted: true)
        let escalations = await planner.recordedEscalations
        #expect(escalations.isEmpty, "Subgoal with empty outcome concluding at boundary must generate 0 escalations")
    }
}
