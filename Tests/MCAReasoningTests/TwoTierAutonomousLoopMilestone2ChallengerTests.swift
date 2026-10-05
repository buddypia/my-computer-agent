import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Milestone 2 Challenger: Heuristic Replan & Escalation Guard Empirical Stress Tests")
struct TwoTierAutonomousLoopMilestone2ChallengerTests {

    private func makeCandidate(
        id: String,
        role: String,
        label: String,
        x: Double,
        y: Double,
        w: Double = 80,
        h: Double = 30,
        value: String? = nil
    ) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            value: value,
            bounds: CGRect(x: x, y: y, width: w, height: h)
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
            frameHash: frameHash ?? "hash_\(title.hashValue)"
        )
    }

    // =========================================================================
    // SECTION 1: FEATURE 6 — NON-RECURSIVE HEURISTIC REPLAN HARDENING
    // =========================================================================

    @Test("Feature 6: Standard multi-layer replan prefixes strip down cleanly to bare core")
    func testStripReplanBoilerplateDeepRecursiveNesting() {
        let deeplyNested = """
        Navigate using alternative elements or shortcuts for: \
        Interact with alternative interactive element for: \
        Retry after low confidence: \
        Retry subgoal with adjusted interaction: \
        Conclude subgoal after reaching boundary: \
        retry: \
        for: \
        Navigate using alternative elements or shortcuts to: \
        Interact with alternative interactive element to: \
        Click Confirm Order Button
        """

        let unnested = DefaultSubgoalPlanner.stripReplanBoilerplate(from: deeplyNested)
        #expect(unnested == "Click Confirm Order Button", "Must strip standard nested boilerplate layers")

        // Edge case: input that is ONLY boilerplate prefixes
        let onlyBoilerplate = "Retry after low confidence: Navigate using alternative elements or shortcuts for: for:"
        let emptyResult = DefaultSubgoalPlanner.stripReplanBoilerplate(from: onlyBoilerplate)
        #expect(emptyResult.isEmpty, "Only boilerplate should reduce to empty string")

        // Edge case: irregular whitespace and colons
        let irregular = "Retry after low confidence:   navigate using alternative elements or shortcuts for:   Submit Form"
        let strippedIrregular = DefaultSubgoalPlanner.stripReplanBoilerplate(from: irregular)
        #expect(strippedIrregular == "Submit Form")
    }

    @Test("Feature 6: Punctuation/colon-delimited boilerplate cleanly unnests without premature termination")
    func testStripReplanBoilerplate_ColonDelimitedPrefixes() {
        let prefixWithColon = "Wait for UI to finish loading or rendering: retry: Click Confirm Order Button"
        let unnested = DefaultSubgoalPlanner.stripReplanBoilerplate(from: prefixWithColon)
        #expect(unnested == "Click Confirm Order Button", "Must fully unnest colon-delimited chained prefixes")

        let hyphenDelimited = "Retry after low confidence: - retry: Click Confirm Order Button"
        let unnestedHyphen = DefaultSubgoalPlanner.stripReplanBoilerplate(from: hyphenDelimited)
        #expect(unnestedHyphen == "Click Confirm Order Button", "Must strip prefixes delimited by hyphens")

        let commaDelimited = "Conclude subgoal after reaching boundary: , retry: Submit Order"
        let unnestedComma = DefaultSubgoalPlanner.stripReplanBoilerplate(from: commaDelimited)
        #expect(unnestedComma == "Submit Order", "Must strip prefixes delimited by commas")
    }

    @Test("Feature 6 Adversarial: English word boundary preserves words with stagnant substrings")
    func testStripStagnantKeywordsEnglishBoundaryAndFalsePositives() {
        // Words containing 'down' or 'up' must NOT be corrupted
        let downloadGoal = "Download latest report file and update spreadsheet"
        let strippedDownload = DefaultSubgoalPlanner.stripStagnantKeywords(from: downloadGoal)
        #expect(strippedDownload == "Download latest report file and update spreadsheet",
                "'Download' and 'update' must not be stripped by 'down' or 'up' regex")

        // Exact matches for stagnant terms MUST be stripped
        let stagnantGoal = "Scroll feed down to inspect timeline comments"
        let strippedStagnant = DefaultSubgoalPlanner.stripStagnantKeywords(from: stagnantGoal)
        #expect(strippedStagnant == "inspect comments",
                "'Scroll', 'feed', 'down', 'to', and 'timeline' must be cleanly stripped")

        // Leading prepositions and conjunctions stripping
        let prepGoal = "for the and with details of user profile"
        let strippedPrep = DefaultSubgoalPlanner.stripStagnantKeywords(from: prepGoal)
        #expect(strippedPrep == "details of user profile")

        // Upward / downward variations
        let directionalGoal = "scroll upward and then downward to check table"
        let strippedDirectional = DefaultSubgoalPlanner.stripStagnantKeywords(from: directionalGoal)
        #expect(strippedDirectional == "check table")
    }

    @Test("Feature 6 Adversarial: Japanese complex stagnant phrasing, grammar particles, and combinations")
    func testStripStagnantKeywordsJapaneseComplexPhrasesAndParticles() {
        // 1. Full realistic Japanese stagnant phrase with particles
        let j1 = "タイムラインを下へスクロールをして最新のニュースを確認する"
        let s1 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j1)
        #expect(s1 == "最新のニュースを確認する", "Must strip タイムライン, 下へ, スクロール, and leading particle をして")

        // 2. Feed scrolling with 'して' particle
        let j2 = "フィードをスクロールして投稿を探す"
        let s2 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j2)
        #expect(s2 == "投稿を探す", "Must strip フィード, を, スクロール, して")

        // 3. Directional phrases
        let j3 = "上を見てメニューを選択"
        let s3 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j3)
        #expect(s3 == "メニューを選択", "Must strip 上を見て")

        let j4 = "下にスクロールで次のページを表示"
        let s4 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j4)
        #expect(s4 == "次のページを表示", "Must strip 下に, スクロール, で")

        // 4. All stagnant terms in Japanese
        let jAll = "スクロール タイムライン 下へ 上へ フィード"
        let sAll = DefaultSubgoalPlanner.stripStagnantKeywords(from: jAll)
        #expect(sAll.isEmpty, "All-stagnant Japanese input should reduce to empty")
    }

    @Test("Feature 6 Adversarial: Empty stripped core falls back cleanly to 'target elements or controls'")
    func testHeuristicReplanEmptyStrippedKeywordsFallback() {
        let allStagnantEnglish = Subgoal(
            id: "sg_empty_eng",
            description: "Scroll feed down",
            expectedOutcome: "screen changes",
            maxSteps: 3
        )
        let resEng = DefaultSubgoalPlanner.heuristicReplan(
            failedSubgoal: allStagnantEnglish,
            reason: .actionStagnant(reason: "Unchanged state")
        )
        if case .retrySubgoal(let retrySg) = resEng {
            #expect(retrySg.description == "Navigate using alternative elements or shortcuts for: target elements or controls",
                    "Must fallback to default target text when description is completely stripped")
        } else {
            #expect(Bool(false), "Expected retrySubgoal")
        }

        let allStagnantJapanese = Subgoal(
            id: "sg_empty_jp",
            description: "タイムラインを下へスクロール",
            expectedOutcome: "画面更新",
            maxSteps: 3
        )
        let resJp = DefaultSubgoalPlanner.heuristicReplan(
            failedSubgoal: allStagnantJapanese,
            reason: .actionStagnant(reason: "画面変化なし")
        )
        if case .retrySubgoal(let retrySg) = resJp {
            #expect(retrySg.description == "Navigate using alternative elements or shortcuts for: target elements or controls")
        } else {
            #expect(Bool(false), "Expected retrySubgoal")
        }
    }

    @Test("Feature 6 Adversarial: nextRetryId generates strictly monotonic attempt counters across all retry suffixes")
    func testNextRetryIdAttemptProgression() {
        // Test suffix: alt
        let r1 = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_1", suffix: "alt")
        #expect(r1.id == "subgoal_1_alt" && r1.attempt == 1)

        let r2 = DefaultSubgoalPlanner.nextRetryId(from: r1.id, suffix: "alt")
        #expect(r2.id == "subgoal_1_alt_2" && r2.attempt == 2)

        let r3 = DefaultSubgoalPlanner.nextRetryId(from: r2.id, suffix: "alt")
        #expect(r3.id == "subgoal_1_alt_3" && r3.attempt == 3)

        let r4 = DefaultSubgoalPlanner.nextRetryId(from: r3.id, suffix: "alt")
        #expect(r4.id == "subgoal_1_alt_4" && r4.attempt == 4)

        // Test suffix: retry_conf
        let c1 = DefaultSubgoalPlanner.nextRetryId(from: "task_search", suffix: "retry_conf")
        #expect(c1.id == "task_search_retry_conf" && c1.attempt == 1)

        let c2 = DefaultSubgoalPlanner.nextRetryId(from: c1.id, suffix: "retry_conf")
        #expect(c2.id == "task_search_retry_conf_2" && c2.attempt == 2)

        let c3 = DefaultSubgoalPlanner.nextRetryId(from: c2.id, suffix: "retry_conf")
        #expect(c3.id == "task_search_retry_conf_3" && c3.attempt == 3)

        // Test suffix: retry
        let e1 = DefaultSubgoalPlanner.nextRetryId(from: "step_ui", suffix: "retry")
        #expect(e1.id == "step_ui_retry" && e1.attempt == 1)

        let e2 = DefaultSubgoalPlanner.nextRetryId(from: e1.id, suffix: "retry")
        #expect(e2.id == "step_ui_retry_2" && e2.attempt == 2)

        let e3 = DefaultSubgoalPlanner.nextRetryId(from: e2.id, suffix: "retry")
        #expect(e3.id == "step_ui_retry_3" && e3.attempt == 3)
    }

    @Test("Feature 6 Adversarial: recovery exhaustion stops with an unverified outcome")
    func testHeuristicReplanTerminationSemantics() {
        // 1. Action Stagnant:
        // Attempt 1 -> retry
        let sg1 = Subgoal(id: "sg_stuck", description: "Read article", expectedOutcome: "read", maxSteps: 3)
        let r1 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .actionStagnant(reason: "diff unchanged"))
        if case .retrySubgoal(let s) = r1 {
            #expect(s.id == "sg_stuck_alt")
        } else {
            #expect(Bool(false), "Attempt 1 must retry")
        }

        // Attempt 2 without boundary -> retry
        let sg2 = Subgoal(id: "sg_stuck_alt", description: "Read article", expectedOutcome: "read", maxSteps: 3)
        let r2 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "diff unchanged"))
        if case .retrySubgoal(let s) = r2 {
            #expect(s.id == "sg_stuck_alt_2")
        } else {
            #expect(Bool(false), "Attempt 2 non-boundary must retry")
        }

        // Attempt 2 WITH boundary indicator -> abort
        let r2Boundary = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "Container boundary reached"))
        if case .abort(let reason) = r2Boundary {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            #expect(Bool(false), "Attempt 2 with boundary indicator must conclude with abort")
        }

        // Attempt 2 WITH inert indicator -> abort
        let r2Inert = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "Target element is inert"))
        if case .abort(let reason) = r2Inert {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            #expect(Bool(false), "Attempt 2 with inert indicator must conclude with abort")
        }

        // Attempt 3 without boundary -> abort (limit hit)
        let sg3 = Subgoal(id: "sg_stuck_alt_2", description: "Read article", expectedOutcome: "read", maxSteps: 3)
        let r3 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg3, reason: .actionStagnant(reason: "diff unchanged"))
        if case .abort(let reason) = r3 {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            #expect(Bool(false), "Attempt 3 must conclude with abort")
        }

        // 2. Low Confidence:
        // Attempt 1 -> retry
        let sgC1 = Subgoal(id: "sg_conf", description: "Find button", expectedOutcome: "found", maxSteps: 3)
        let rC1 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgC1, reason: .lowConfidence(confidence: 0.40, threshold: 0.80))
        if case .retrySubgoal(let s) = rC1 {
            #expect(s.id == "sg_conf_retry_conf")
        } else {
            #expect(Bool(false))
        }

        // Attempt 3 -> abort
        let sgC3 = Subgoal(id: "sg_conf_retry_conf_2", description: "Find button", expectedOutcome: "found", maxSteps: 3)
        let rC3 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgC3, reason: .lowConfidence(confidence: 0.40, threshold: 0.80))
        if case .abort(let reason) = rC3 {
            #expect(reason.contains("3 low-confidence attempts"))
        } else {
            #expect(Bool(false), "Low confidence attempt 3 must conclude with abort")
        }

        // 3. Empty Candidates:
        // Attempt 3 -> abort
        let sgE3 = Subgoal(id: "sg_empty_retry_2", description: "Wait elements", expectedOutcome: "appear", maxSteps: 3)
        let rE3 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgE3, reason: .emptyCandidates)
        if case .abort(let reason) = rE3 {
            #expect(reason.contains("after 3 attempts"))
        } else {
            #expect(Bool(false), "Empty candidates attempt 3 must conclude with abort")
        }

        // 4. Terminal Abort Cases:
        let rAbortLoop = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .loopDetected(reason: "Infinite loop"))
        if case .abort(let reason) = rAbortLoop {
            #expect(reason.contains("Execution halted"))
        } else {
            #expect(Bool(false))
        }

        let rAbortBudget = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .subgoalBudgetExceeded(subgoal: sg1, stepsTaken: 10))
        if case .abort(let reason) = rAbortBudget {
            #expect(reason.contains("step budget exceeded"))
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Feature 6: boundary or inert indicator cannot establish completion")
    func testHeuristicReplanAttempt1BoundaryConcludesImmediately() {
        let sg1 = Subgoal(id: "sg_boundary_test", description: "Scroll feed down to bottom", expectedOutcome: "End reached", maxSteps: 3)
        let res = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .actionStagnant(reason: "Page boundary reached or target inert"))
        if case .abort(let reason) = res {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            #expect(Bool(false), "Attempt 1 with boundary indicator must conclude immediately with abort")
        }
    }

    // =========================================================================
    // SECTION 2: FEATURE 8 — ESCALATION RECOVERY GUARD STRESS TESTING
    // =========================================================================

    @Test("Feature 8 Adversarial: 5 sequential subgoals each experiencing isolated escalation succeed cleanly under maxConsecutiveEscalations = 2")
    func testMultiStepWorkflowWithRepeatedIsolatedEscalationsSucceeds() async throws {
        // Setup 5 subgoals, each will fail outcome once, escalate, retry with valid action, produce screen diff progress, and verify.
        let subgoals = (1...5).map { i in
            Subgoal(id: "sg_\(i)_init", description: "Initial step \(i)", expectedOutcome: "title changed to Step \(i) Verified", maxSteps: 2)
        }

        var snapshots: [UIStateSnapshot] = []
        for i in 1...5 {
            let btn = makeCandidate(id: "btn_\(i)", role: "AXButton", label: "Button \(i)", x: 10, y: Double(i * 30))
            snapshots.append(makeSnapshot(title: "Step \(i) Init", candidates: [btn]))
            snapshots.append(makeSnapshot(title: "Step \(i) Retrying", candidates: [btn]))
            snapshots.append(makeSnapshot(title: "Step \(i) Verified", candidates: [btn]))
        }

        let inspector = MockUIInspector(snapshots: snapshots)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: subgoals)
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                let id = failedSubgoal.id
                for i in 1...5 {
                    if id.hasPrefix("sg_\(i)") {
                        return .retrySubgoal(Subgoal(
                            id: "sg_\(i)_ok",
                            description: "Click Button \(i)",
                            expectedOutcome: "title changed to Step \(i) Verified",
                            maxSteps: 2
                        ))
                    }
                }
                return .abort(reason: "Unknown subgoal \(failedSubgoal.id)")
            }
        )

        var config = AutonomousLoopConfig.testing
        // Strict guard: If consecutiveEscalations did not reset after each verified progress,
        // it would trip after Subgoal 2 (since 2 consecutive escalations would accumulate)!
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Execute 5 subgoals with isolated escalations")

        #expect(summary.isSuccess, "Workflow must succeed without tripping maxConsecutiveEscalations = 2")
        #expect(summary.completedSubgoals == 5, "All 5 subgoals must be marked completed")
    }

    @Test("Feature 8 Adversarial: Consecutive escalations WITHOUT screen progress strictly trip and abort at max limit")
    func testConsecutiveEscalationsTripWhenNoProgressIsMade() async throws {
        let staticCand = makeCandidate(id: "btn_stuck", role: "AXButton", label: "Stuck", x: 10, y: 10)
        let s0 = makeSnapshot(title: "Static Page", candidates: [staticCand])

        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_unrecoverable", description: "Click Stuck", expectedOutcome: "title changed to New Page", maxSteps: 3)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [sg])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                return .retrySubgoal(Subgoal(
                    id: failedSubgoal.id + "_alt",
                    description: "Click Stuck again",
                    expectedOutcome: "title changed to New Page",
                    maxSteps: 3
                ))
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Expect consecutive escalation failure")
            #expect(Bool(false), "Must throw LoopExecutionError.escalationFailed")
        } catch let err as LoopExecutionError {
            if case .escalationFailed(let reason) = err {
                #expect(reason.contains("Exceeded maximum consecutive escalations (2)"),
                        "Must fail with limit 2 message: got '\(reason)'")
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        }
    }

    @Test("Feature 8 Adversarial: Mid-subgoal screen diff progress resets consecutiveEscalations before subsequent low confidence")
    func testConsecutiveEscalationsResetOnStateDiffProgressDuringSubgoalStep() async throws {
        let cand1 = makeCandidate(id: "c1", role: "AXButton", label: "Alpha", x: 10, y: 10)
        let cand2 = makeCandidate(id: "c2", role: "AXButton", label: "Beta", x: 10, y: 50)

        let s0 = makeSnapshot(title: "Initial", candidates: [cand1])
        let s1 = makeSnapshot(title: "Halfway Changed", candidates: [cand2])
        let sFinal = makeSnapshot(title: "Final Target Done", candidates: [cand2])

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, sFinal])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "c1", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0), // escalates (count 1)
            (target: "c1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0), // makes diff progress! (resets to 0)
            (target: "c2", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0), // escalates (count 1, not 2!)
            (target: "c2", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0)  // satisfies outcome!
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let initialSubgoal = Subgoal(id: "sg_main", description: "Reach final", expectedOutcome: "title changed to Final Target Done", maxSteps: 5)

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                return .retrySubgoal(Subgoal(
                    id: failedSubgoal.id + "_retry",
                    description: "Continue to reach final",
                    expectedOutcome: "title changed to Final Target Done",
                    maxSteps: 5
                ))
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Test diff progress reset mid-subgoal")
        #expect(summary.isSuccess, "Must succeed because state diff progress cleared consecutive escalations")
    }

    // =========================================================================
    // SECTION 3: BOUNDARY RECOVERY LIMIT — CLEAN CONCLUSION
    // =========================================================================

    @Test("Feature 6/8: static feed stops when the expected end notice is not observed")
    func testOfflineFeedScrollBoundaryConcludesGracefully() async throws {
        // Feed container candidate (only element visible on screen)
        let feedContainer = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Feed Content", x: 100, y: 100, w: 600, h: 800)
        let s0 = makeSnapshot(title: "Feed View", candidates: [feedContainer])

        // Unchanging snapshot to simulate reaching bottom/boundary of feed
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        // Unconfigured engine runs fallbackLocalDecision
        let engine = TypeSafeDecisionEngine()

        // Subgoal with explicit expected outcome triggers line 994 escalation when boundary is hit
        let subgoal = Subgoal(
            id: "sg_scroll_to_end",
            description: "Scroll feed down to bottom",
            expectedOutcome: "Reached end of feed notice",
            maxSteps: 5
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
            inspector: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Browse feed to bottom")
            Issue.record("End-of-feed notice was never observed, but task reported success")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                Issue.record("Unexpected failure: \(error)")
                return
            }
            #expect(reason.contains("Outcome unverified"))
        }
        #expect(synthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }.count == 1)
        #expect(synthesizer.recordedEvents.filter { if case .pressKey("PageDown") = $0 { return true }; return false }.count == 1)
    }
}
