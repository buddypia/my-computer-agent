import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("Autonomous Loop Heuristic Replan, Escalation Guard & Coordinate Fallback Tests")
struct AutonomousLoopReplanAndEscalationTests {

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

    final class ReasonHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _reason: EscalationReason?
        var reason: EscalationReason? {
            lock.lock(); defer { lock.unlock() }
            return _reason
        }
        func set(_ r: EscalationReason) {
            lock.lock(); defer { lock.unlock() }
            _reason = r
        }
    }

    // MARK: - 1. DefaultSubgoalPlanner Replan Boilerplate & Stagnant Keyword Stripping

    @Test("stripReplanBoilerplate strips deeply nested and colon/hyphen/comma-delimited prefixes")
    func testStripReplanBoilerplateDeepAndDelimitedPrefixes() {
        let prefixes = [
            "navigate using alternative elements or shortcuts for: ",
            "interact with alternative interactive element for: ",
            "retry after low confidence: ",
            "retry subgoal with adjusted interaction: ",
            "conclude subgoal after reaching boundary: ",
            "wait for ui to finish loading or rendering: ",
            "navigate using alternative elements or shortcuts to: ",
            "interact with alternative interactive element to: ",
            "retry: ",
            "for: ",
            "- ",
            ": "
        ]

        var input = "Click Checkout Button"
        for i in 0..<50 {
            input = prefixes[i % prefixes.count] + input
        }
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: input) == "Click Checkout Button")

        let dirtyInput = ":::---  ,,,  retry:   for:   Navigate using alternative elements or shortcuts for: :: - Click Save"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: dirtyInput) == "Click Save")

        let caseInsensitive = "RETRY AFTER LOW CONFIDENCE: NAVIGATE USING ALTERNATIVE ELEMENTS OR SHORTCUTS FOR: Submit Form"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: caseInsensitive) == "Submit Form")

        let commaDelimited = "Conclude subgoal after reaching boundary: , retry: Submit Order"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: commaDelimited) == "Submit Order")
    }

    @Test("stripReplanBoilerplate preserves internal target text and reduces pure boilerplate/delimiters to empty")
    func testStripReplanBoilerplateInternalTargetAndEmptyCases() {
        let internalText = "Search for: flight options to Tokyo"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: internalText) == "Search for: flight options to Tokyo")

        let onlyBoilerplate = "Retry after low confidence: Navigate using alternative elements or shortcuts for: for:"
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: onlyBoilerplate).isEmpty)

        let onlyDelimiters = "  \t \n - : , : -   "
        #expect(DefaultSubgoalPlanner.stripReplanBoilerplate(from: onlyDelimiters).isEmpty)
    }

    @Test("stripStagnantKeywords protects compound words and strips standalone stagnant keywords")
    func testStripStagnantKeywordsEnglishBoundaries() {
        let compoundSentence = "Download the feedback form, setup the backup, update the scrollbar, and review downside risk"
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: compoundSentence) == compoundSentence)

        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "Scroll feed down to see more posts") == "see more posts")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "Timeline feed scroll up to inspect header") == "inspect header")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "Scroll feed down to inspect timeline comments") == "inspect comments")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "for the and with details of user profile") == "details of user profile")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "scroll upward and then downward to check table") == "check table")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "Scroll down").isEmpty)
    }

    @Test("stripStagnantKeywords handles Japanese stagnant terms and grammatical particles")
    func testStripStagnantKeywordsJapaneseContexts() {
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "タイムラインをスクロールして最新情報を探す") == "最新情報を探す")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "フィードを下にスクロールして次へ進む") == "次へ進む")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "上にスクロールをして完了する") == "完了する")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "タイムラインを下へスクロールをして最新のニュースを確認する") == "最新のニュースを確認する")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "上を見てメニューを選択") == "メニューを選択")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "下にスクロールで次のページを表示") == "次のページを表示")
        #expect(DefaultSubgoalPlanner.stripStagnantKeywords(from: "スクロール タイムライン 下へ 上へ フィード").isEmpty)
    }

    @Test("heuristicReplan falls back to default descriptions when core text is completely stripped")
    func testHeuristicReplanAllStagnantCoreFallback() {
        let sgEng = Subgoal(id: "sg_empty_eng", description: "Scroll feed down", expectedOutcome: "screen changes", maxSteps: 3)
        if case .retrySubgoal(let retry) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgEng, reason: .actionStagnant(reason: "Unchanged state")) {
            #expect(retry.description == "Navigate using alternative elements or shortcuts for: target elements or controls")
        } else {
            Issue.record("Expected retrySubgoal for English stagnant fallback")
        }

        let sgJp = Subgoal(id: "sg_empty_jp", description: "タイムラインを下へスクロール", expectedOutcome: "画面更新", maxSteps: 3)
        if case .retrySubgoal(let retry) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgJp, reason: .actionStagnant(reason: "画面変化なし")) {
            #expect(retry.description == "Navigate using alternative elements or shortcuts for: target elements or controls")
        } else {
            Issue.record("Expected retrySubgoal for Japanese stagnant fallback")
        }

        let sgConf = Subgoal(id: "sg_conf_empty", description: "retry after low confidence: retry:", expectedOutcome: "", maxSteps: 3)
        if case .retrySubgoal(let retry) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgConf, reason: .lowConfidence(confidence: 0.3, threshold: 0.8)) {
            #expect(retry.description == "Interact with alternative interactive element for: interactive elements on screen")
        } else {
            Issue.record("Expected retrySubgoal for low-confidence fallback")
        }
    }

    @Test("nextRetryId monotonically advances attempt numbers across fixed and changing suffixes while preserving base numbers")
    func testNextRetryIdAttemptProgression() {
        var currentId = "subgoal_checkout"
        for expectedAttempt in 1...10 {
            let result = DefaultSubgoalPlanner.nextRetryId(from: currentId, suffix: "alt")
            #expect(result.attempt == expectedAttempt)
            #expect(result.id == (expectedAttempt == 1 ? "subgoal_checkout_alt" : "subgoal_checkout_alt_\(expectedAttempt)"))
            currentId = result.id
        }

        let (m1, a1) = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_checkout", suffix: "alt")
        #expect(m1 == "subgoal_checkout_alt" && a1 == 1)
        let (m2, a2) = DefaultSubgoalPlanner.nextRetryId(from: m1, suffix: "retry_conf")
        #expect(m2 == "subgoal_checkout_retry_conf_2" && a2 == 2)
        let (m3, a3) = DefaultSubgoalPlanner.nextRetryId(from: m2, suffix: "retry")
        #expect(m3 == "subgoal_checkout_retry_3" && a3 == 3)
        let (m4, a4) = DefaultSubgoalPlanner.nextRetryId(from: m3, suffix: "alt")
        #expect(m4 == "subgoal_checkout_alt_4" && a4 == 4)

        let (b1, ba1) = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_1_step_2", suffix: "alt")
        #expect(b1 == "subgoal_1_step_2_alt" && ba1 == 1)
        let (b2, ba2) = DefaultSubgoalPlanner.nextRetryId(from: b1, suffix: "alt")
        #expect(b2 == "subgoal_1_step_2_alt_2" && ba2 == 2)
    }

    @Test("heuristicReplan boundary, retry, and recovery exhaustion semantics across escalation reasons")
    func testHeuristicReplanTerminationSemantics() {
        let sg1 = Subgoal(id: "sg_stuck", description: "Read article", expectedOutcome: "read", maxSteps: 3)

        // Attempt 1 without boundary -> retry
        if case .retrySubgoal(let s) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .actionStagnant(reason: "diff unchanged")) {
            #expect(s.id == "sg_stuck_alt")
        } else {
            Issue.record("Attempt 1 non-boundary must retry")
        }

        // Attempt 1 WITH boundary or inert keyword -> immediate abort
        for boundaryReason in ["page boundary reached", "target element is inert"] {
            if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .actionStagnant(reason: boundaryReason)) {
                #expect(reason.contains("page boundary or recovery limit"))
            } else {
                Issue.record("Attempt 1 with '\(boundaryReason)' must conclude immediately with abort")
            }
        }

        // Attempt 2 without boundary -> retry; with boundary/inert -> abort
        let sg2 = Subgoal(id: "sg_stuck_alt", description: "Read article", expectedOutcome: "read", maxSteps: 3)
        if case .retrySubgoal(let s) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "diff unchanged")) {
            #expect(s.id == "sg_stuck_alt_2")
        } else {
            Issue.record("Attempt 2 non-boundary must retry")
        }
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "Container boundary reached")) {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            Issue.record("Attempt 2 with boundary indicator must conclude with abort")
        }

        // Attempt 3 without boundary -> abort (recovery limit hit)
        let sg3 = Subgoal(id: "sg_stuck_alt_2", description: "Read article", expectedOutcome: "read", maxSteps: 3)
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg3, reason: .actionStagnant(reason: "diff unchanged")) {
            #expect(reason.contains("boundary or recovery limit"))
        } else {
            Issue.record("Attempt 3 must conclude with abort")
        }

        // Low confidence: attempt 1 retries, attempt 3 aborts
        let sgC1 = Subgoal(id: "sg_conf", description: "Find button", expectedOutcome: "found", maxSteps: 3)
        if case .retrySubgoal(let s) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgC1, reason: .lowConfidence(confidence: 0.40, threshold: 0.80)) {
            #expect(s.id == "sg_conf_retry_conf")
        } else {
            Issue.record("Low confidence attempt 1 must retry")
        }
        let sgC3 = Subgoal(id: "sg_conf_retry_conf_2", description: "Find button", expectedOutcome: "found", maxSteps: 3)
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgC3, reason: .lowConfidence(confidence: 0.40, threshold: 0.80)) {
            #expect(reason.contains("3 low-confidence attempts"))
        } else {
            Issue.record("Low confidence attempt 3 must abort")
        }

        // Empty candidates attempt 3 -> abort
        let sgE3 = Subgoal(id: "sg_empty_retry_2", description: "Wait elements", expectedOutcome: "appear", maxSteps: 3)
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgE3, reason: .emptyCandidates) {
            #expect(reason.contains("after 3 attempts"))
        } else {
            Issue.record("Empty candidates attempt 3 must abort")
        }

        // Terminal abort cases: loopDetected and subgoalBudgetExceeded
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .loopDetected(reason: "Repeating identical subgoal sequence [sg_1 -> sg_2 -> sg_1]")) {
            #expect(reason.contains("Execution halted: Repeating identical subgoal sequence"))
        } else {
            Issue.record("loopDetected must abort")
        }
        if case .abort(let reason) = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg1, reason: .subgoalBudgetExceeded(subgoal: sg1, stepsTaken: 10)) {
            #expect(reason.contains("step budget exceeded"))
        } else {
            Issue.record("subgoalBudgetExceeded must abort")
        }
    }

    // MARK: - 2. Escalation Recovery Guard, Limits & Reset

    @Test("5 sequential subgoals each experiencing an isolated escalation succeed under maxConsecutiveEscalations = 2")
    func testMultiStepWorkflowWithRepeatedIsolatedEscalationsSucceeds() async throws {
        // Initial descriptions have zero token overlap with "Alpha..Echo" so step 1 genuinely escalates
        // with lowConfidence on each subgoal; the retry subgoal matches the button and advances the screen.
        let labels = ["Alpha", "Beta", "Gamma", "Delta", "Echo"]
        let subgoals = (0..<5).map { i in
            Subgoal(
                id: "sg_\(i)_init",
                description: "Locate phantom xylophone widget",
                expectedOutcome: "title changed to Step \(i) Verified",
                maxSteps: 2
            )
        }

        var snapshots: [UIStateSnapshot] = [
            makeSnapshot(title: "Step 0 Init", candidates: [
                makeCandidate(id: "btn_0", role: "AXButton", label: labels[0], x: 10, y: 30)
            ])
        ]
        for i in 0..<5 {
            let btn = makeCandidate(id: "btn_\(i)", role: "AXButton", label: labels[i], x: 10, y: Double((i + 1) * 30))
            snapshots.append(makeSnapshot(title: "Step \(i) Retrying", candidates: [btn]))
            snapshots.append(makeSnapshot(title: "Step \(i) Verified", candidates: [btn]))
        }

        let inspector = MockUIInspector(snapshots: snapshots)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: subgoals)
            },
            escalationHandler: { _, failedSubgoal, _, _ in
                for i in 0..<5 where failedSubgoal.id == "sg_\(i)_init" {
                    return .retrySubgoal(Subgoal(
                        id: "sg_\(i)_ok",
                        description: "Click \(labels[i])",
                        expectedOutcome: "title changed to Step \(i) Verified",
                        maxSteps: 2
                    ))
                }
                return .abort(reason: "Unexpected escalation on \(failedSubgoal.id)")
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

        let summary = try await coordinator.execute(goal: "Execute 5 subgoals with isolated escalations")

        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 5)
        let escalations = await planner.recordedEscalations
        #expect(escalations.count == 5, "Each of the 5 subgoals must have escalated once before resetting on progress")
    }

    @Test("Consecutive escalations without screen progress trip and abort at configured limits (1 and 2)")
    func testConsecutiveEscalationsTripWhenNoProgressIsMade() async throws {
        for limit in [1, 2] {
            let s0 = makeSnapshot(title: "Static Page", candidates: [])
            let inspector = MockUIInspector(repeating: s0)
            let synthesizer = MockEventSynthesizer()

            let sg = Subgoal(id: "sg_unrecoverable", description: "Search", expectedOutcome: "title changed to New Page", maxSteps: 5)
            let planner = MockPlanningLLM(
                planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [sg]) },
                escalationHandler: { _, failedSubgoal, _, _ in .retrySubgoal(failedSubgoal) }
            )

            var config = AutonomousLoopConfig.testing
            config.maxConsecutiveEscalations = limit

            let coordinator = TwoTierAutonomousLoopCoordinator(
                planner: planner,
                decisionEngine: TypeSafeDecisionEngine(),
                synthesizer: synthesizer,
                inspector: inspector,
                config: config
            )

            do {
                _ = try await coordinator.execute(goal: "Expect consecutive escalation failure")
                Issue.record("Should have failed with escalationFailed at limit \(limit)")
            } catch let err as LoopExecutionError {
                guard case .escalationFailed(let reason) = err else {
                    Issue.record("Expected escalationFailed, got \(err)")
                    return
                }
                #expect(reason.contains("Exceeded maximum consecutive escalations (\(limit))"))
                #expect(reason.contains("#1:"))
                if limit == 2 {
                    #expect(reason.contains("#2:"))
                }
                #expect(reason.contains("No actionable UI element candidates observed on screen"))
            }
        }
    }

    @Test("Repeated identical scroll actions trip Factor 1 loop detection and respect custom maxConsecutiveEscalations")
    func testRepeatedIdenticalScrollTripsAtCustomEscalationLimit() async throws {
        let feedArea = UIElementCandidate(
            id: "feed_scroll",
            role: "AXScrollArea",
            label: "Timeline Feed",
            bounds: CGRect(x: 50, y: 50, width: 400, height: 600)
        )
        let s0 = UIStateSnapshot(windowTitle: "Feed View", visibleCandidates: [feedArea], frameHash: "hash_s0")
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let scriptedEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "none",
            targetConfidence: 0.85,
            actionChoice: "scroll",
            scrollDelta: "down"
        )
        let engine = TypeSafeDecisionEngine(client: scriptedEvaluator)

        let subgoal = Subgoal(
            id: "sg_scroll_legacy",
            description: "Scroll down the feed to read more updates",
            expectedOutcome: "read more updates",
            maxSteps: 10
        )
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { _, currentSubgoal, _, _ in .retrySubgoal(currentSubgoal) }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
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

    @Test("Mid-subgoal screen diff progress resets consecutiveEscalations before subsequent low confidence")
    func testConsecutiveEscalationsResetOnStateDiffProgressDuringSubgoalStep() async throws {
        let cand1 = makeCandidate(id: "c1", role: "AXButton", label: "Alpha", x: 10, y: 10)
        let cand2 = makeCandidate(id: "c2", role: "AXButton", label: "Beta", x: 10, y: 50)

        let s0 = makeSnapshot(title: "Initial", candidates: [cand1])
        // Same title: the swapped element is progress, but not the expected outcome.
        let s1 = makeSnapshot(title: "Initial", candidates: [cand2])
        let sFinal = makeSnapshot(title: "Final Target Done", candidates: [cand2])

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, sFinal])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "c1", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0),
            (target: "c1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "c2", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0),
            (target: "c2", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let initialSubgoal = Subgoal(id: "sg_main", description: "Reach final", expectedOutcome: "title changed to Final Target Done", maxSteps: 5)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [initialSubgoal]) },
            escalationHandler: { _, failedSubgoal, _, _ in
                .retrySubgoal(Subgoal(
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
        #expect(summary.isSuccess)
        // Two escalations under a cap of 2 succeed only if the counter reset between them.
        #expect(await planner.recordedEscalations.count == 2)
    }

    @Test("Focus change resets consecutive escalations counter")
    func testEscalationGuardResetOnFocusChange() async throws {
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "First", x: 10, y: 10)
        let s0 = makeSnapshot(title: "Page", candidates: [btn1], focusedId: "btn1")
        let s1 = makeSnapshot(title: "Page", candidates: [btn1], focusedId: "btn2")
        let sFinal = makeSnapshot(title: "Page Done", candidates: [btn1], focusedId: "btn2")

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, sFinal])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn1", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0),
            (target: "btn1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "btn1", action: "click", confidence: 0.50, text: nil, isCompleted: 0.0),
            (target: "btn1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_focus", description: "Navigate focus", expectedOutcome: "title changed to Page Done", maxSteps: 5)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { _, sg, _, _ in .retrySubgoal(sg) }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Focus reset test")
        #expect(summary.isSuccess)
        // Two escalations under a cap of 2 succeed only if the counter reset between them.
        #expect(await planner.recordedEscalations.count == 2)
    }

    // MARK: - 3. Feedback Loop Stagnation & Boundary Handling

    @Test("Upward scroll goal adapts to PageUp keyboard navigation on unchanged diff")
    func testFeedbackLoopUpwardScrollStagnationAdaptsToPageUp() async throws {
        let scrollArea = makeCandidate(id: "feed", role: "AXScrollArea", label: "Timeline", x: 50, y: 50, w: 500, h: 600)
        let s0 = makeSnapshot(title: "Timeline View", candidates: [scrollArea])

        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let engine = TypeSafeDecisionEngine()

        let subgoal = Subgoal(id: "sg_up", description: "Scroll up feed to see older posts", expectedOutcome: "", maxSteps: 5)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Scroll up timeline")
        #expect(summary.isSuccess)

        let pageUpEvents = synthesizer.recordedEvents.filter {
            if case .pressKey(let k) = $0 { return k == "PageUp" }
            return false
        }
        #expect(!pageUpEvents.isEmpty, "Upward scroll stagnation must adapt to PageUp keyboard navigation")
    }

    @Test("Zero escalations occur when subgoal with empty expectedOutcome concludes at scroll boundary")
    func testZeroEscalationsDuringCleanStagnantScrollRecovery() async throws {
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let s0 = makeSnapshot(title: "Feed Page 1", candidates: [scrollArea], frameHash: "hash_static")
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let engine = TypeSafeDecisionEngine()

        let subgoal = Subgoal(id: "sg_feed_stagnant", description: "Scroll feed down to read latest posts", expectedOutcome: "", maxSteps: 6)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Browse feed")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 3)
        let escalations = await planner.recordedEscalations
        #expect(escalations.isEmpty)
    }

    @Test("Unfulfilled explicit expected outcome at scroll boundary triggers actionStagnant escalation")
    func testFeedbackLoopBoundaryStagnationWithUnfulfilledExplicitOutcomeEscalates() async throws {
        let scrollArea = makeCandidate(id: "feed", role: "AXScrollArea", label: "Timeline", x: 50, y: 50, w: 500, h: 600)
        let s0 = makeSnapshot(title: "Timeline View", candidates: [scrollArea])

        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let engine = TypeSafeDecisionEngine()

        let holder = ReasonHolder()
        let subgoal = Subgoal(
            id: "sg_search_post",
            description: "Scroll feed down to find post",
            expectedOutcome: "Post from Alice is visible",
            maxSteps: 5
        )

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { reason, _, _, _ in
                holder.set(reason)
                return .completeGoal(summary: "Concluded following boundary escalation")
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Find post")
        #expect(summary.isSuccess)
        if case .actionStagnant = holder.reason {
            // Expected
        } else {
            Issue.record("Expected .actionStagnant escalation but got \(String(describing: holder.reason))")
        }
    }

    // MARK: - 4. Synthetic Action Coordinate Resolution & Actuation

    @Test("Empty or zero-area candidates resolve valid viewport center for scroll action",
          arguments: [CGRect(x: 40, y: 80, width: 600, height: 400),
                      CGRect(x: 100, y: 120, width: 1000, height: 600)])
    func testEmptyCandidatesListScrollResolvesViewportCenter(viewport: CGRect) async throws {
        try await TypeSafeDecisionEngine.$fallbackScrollViewport.withValue(viewport) {
            let emptyPoint = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [])
            #expect(emptyPoint == CGPoint(x: viewport.midX, y: viewport.midY))

            let degenerateCandidate = UIElementCandidate(
                id: "placeholder",
                role: "AXGroup",
                label: "Empty Placeholder",
                bounds: CGRect(x: 0, y: 0, width: 0, height: 0)
            )
            let s0 = makeSnapshot(title: "Degenerate Page", candidates: [degenerateCandidate])
            let sDone = makeSnapshot(title: "Degenerate Page - Done", candidates: [degenerateCandidate])
            let inspector = MockUIInspector(snapshots: [s0, sDone])
            let synthesizer = MockEventSynthesizer()

            let evaluator = MockTypeSafeEvaluator.stepSequence([
                (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
                (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
            ])
            let engine = TypeSafeDecisionEngine(client: evaluator)

            let subgoal = Subgoal(id: "sg_scroll_degen_empty", description: "scroll page", expectedOutcome: "title changed to Degenerate Page - Done", maxSteps: 3)
            let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

            let coordinator = TwoTierAutonomousLoopCoordinator(
                planner: planner,
                decisionEngine: engine,
                synthesizer: synthesizer,
                inspector: inspector,
                config: .testing
            )

            let summary = try await coordinator.execute(goal: "Test empty candidates scroll")
            #expect(summary.isSuccess)

            let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
                if case .scroll(_, _, let point, _) = event { return point }
                return nil
            }
            #expect(!scrollEvents.isEmpty)
            for pt in scrollEvents {
                #expect(pt == emptyPoint, "Degenerate candidates must fall back to the exact same point as empty candidates")
            }
        }
        #expect(TypeSafeDecisionEngine.fallbackScrollViewport == nil)
    }

    @Test("Missing container roles resolve candidate bounding box centroid for scroll")
    func testMissingContainerRolesScrollResolvesCandidateCentroid() async throws {
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "Top Left", x: 100, y: 100, w: 100, h: 50)
        let btn2 = makeCandidate(id: "btn2", role: "AXButton", label: "Bottom Right", x: 500, y: 700, w: 100, h: 50)
        let s0 = makeSnapshot(title: "Form View", candidates: [btn1, btn2])
        let sDone = makeSnapshot(title: "Form View - Done", candidates: [btn1, btn2])

        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_scroll_form", description: "scroll form", expectedOutcome: "title changed to Form View - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test missing container scroll")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(scrollEvents.first == CGPoint(x: 350, y: 425))
    }

    @Test("targetElementId and scroll container priority resolve scroll coordinates when targetCenter is nil")
    func testScrollCoordinateResolutionFromTargetIdAndContainerPriority() async throws {
        let button = makeCandidate(id: "btn", role: "AXButton", label: "Submit", x: 50, y: 50, w: 100, h: 30)
        let customBox = makeCandidate(id: "specific_box", role: "AXGroup", label: "Custom Box", x: 300, y: 400, w: 200, h: 100)
        let scrollArea = makeCandidate(id: "container", role: "AXScrollArea", label: "Main Scroll Area", x: 200, y: 150, w: 500, h: 400)

        let s0 = makeSnapshot(title: "View 0", candidates: [button, customBox, scrollArea])
        let s1 = makeSnapshot(title: "View 1", candidates: [button, customBox, scrollArea])
        let sDone = makeSnapshot(title: "View Done", candidates: [button, customBox, scrollArea])

        let inspector = MockUIInspector(snapshots: [s0, s1, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "specific_box", action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_scroll_coords", description: "scroll content", expectedOutcome: "", maxSteps: 4)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test scroll coordinate priority")
        #expect(summary.isSuccess)

        let scrollPoints = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(scrollPoints.count == 2)
        #expect(scrollPoints[0] == customBox.center, "Step 1 with explicit targetElementId must use matched candidate center")
        #expect(scrollPoints[1] == scrollArea.center, "Step 2 with nil targetElementId must prioritize AXScrollArea center")
    }

    @Test("Degenerate or non-finite candidate bounds fall back safely to valid screen coordinate")
    func testDegenerateCandidateBoundsScrollFallsBackSafely() async throws {
        let zeroCandidate = UIElementCandidate(id: "zero", role: "AXButton", label: "Zero", bounds: CGRect(x: 100, y: 100, width: 0, height: 0))
        let nanCandidate = UIElementCandidate(id: "nan", role: "AXButton", label: "NaN", bounds: CGRect(x: Double.nan, y: Double.nan, width: 100, height: 100))

        let s0 = makeSnapshot(title: "Degenerate View", candidates: [zeroCandidate, nanCandidate])
        let sDone = makeSnapshot(title: "Degenerate View - Done", candidates: [zeroCandidate])

        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_degen", description: "scroll degenerate", expectedOutcome: "title changed to Degenerate View - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test degenerate bounds scroll")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        let pt = scrollEvents[0]
        #expect(pt.x.isFinite && pt.y.isFinite && pt.x > 0 && pt.y > 0)
    }

    @Test("Unmatched action target escalates to System 2 and recovers on replanned subgoal")
    func testExecuteSyntheticActionUnmatchedTargetEscalatesToSystem2() async throws {
        let dummyCand = makeCandidate(id: "dummy_btn", role: "AXButton", label: "Other Button", x: 10, y: 10)
        let resolvedCand = makeCandidate(id: "target_btn", role: "AXButton", label: "Target Button", x: 100, y: 100)
        let s0 = makeSnapshot(title: "Initial Window", candidates: [dummyCand])
        let s1 = makeSnapshot(title: "Target Appeared Window", candidates: [resolvedCand])
        let sDone = makeSnapshot(title: "Completed Window", candidates: [resolvedCand])
        let inspector = MockUIInspector(snapshots: [s0, s1, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "nonexistent_button", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "target_btn", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: nil, action: "none", confidence: 0.90, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_unmatched", description: "Click missing button", expectedOutcome: "title changed to Completed Window", maxSteps: 4)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { _, failedSubgoal, _, _ in
                .retrySubgoal(Subgoal(
                    id: failedSubgoal.id + "_resolved",
                    description: "Click Target Button",
                    expectedOutcome: "title changed to Completed Window",
                    maxSteps: 4
                ))
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Click button with recovery")
        #expect(summary.isSuccess)

        let clicks = synthesizer.recordedEvents.filter { event in
            if case .click(let pt, _, _) = event { return pt == resolvedCand.center }
            return false
        }
        #expect(!clicks.isEmpty)
    }

    @Test("executeSyntheticAction focuses element and types text for typeText action")
    func testExecuteSyntheticActionTypeTextFocusAndType() async throws {
        let inputField = makeCandidate(id: "search_box", role: "AXTextField", label: "Search Field", x: 50, y: 50, w: 200, h: 40)
        let s0 = makeSnapshot(title: "Active Input View", candidates: [inputField])
        let s1 = makeSnapshot(title: "Active Input View - Typed", candidates: [inputField])
        let s2 = makeSnapshot(title: "Active Input View - Submitted", candidates: [inputField])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "search_box", action: "typeText", confidence: 0.90, text: "Hello World", isCompleted: 0.0),
            (target: nil, action: "none", confidence: 0.90, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_type_text", description: "Type query into search box", expectedOutcome: "title changed to Active Input View - Submitted", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Search query typing")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains(.click(point: inputField.center, button: .left, clickCount: 1)))
        #expect(synthesizer.recordedEvents.contains(.typeText("Hello World")))
    }

    @Test("executeSyntheticAction dispatches doubleClick and rightClick at candidate center")
    func testExecuteSyntheticActionDoubleClickAndRightClick() async throws {
        let candidate = makeCandidate(id: "file_icon", role: "AXImage", label: "Document.txt", x: 200, y: 300, w: 60, h: 60)
        let s0 = makeSnapshot(title: "Desktop", candidates: [candidate])
        let s1 = makeSnapshot(title: "Context Menu", candidates: [candidate])
        let s2 = makeSnapshot(title: "Document Opened", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "file_icon", action: "rightClick", confidence: 0.95, text: nil, isCompleted: 0.0),
            (target: "file_icon", action: "doubleClick", confidence: 0.95, text: nil, isCompleted: 0.0),
            (target: nil, action: "none", confidence: 0.95, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_open_file", description: "Inspect and open document", expectedOutcome: "title changed to Document Opened", maxSteps: 4)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Open file")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains(.click(point: candidate.center, button: .right, clickCount: 1)))
        #expect(synthesizer.recordedEvents.contains(.click(point: candidate.center, button: .left, clickCount: 2)))
    }

    // MARK: - 5. Input Validation, Empty Plan Fallback & Delegate Skip

    @Test("Empty or whitespace-only goal throws executionFailed immediately")
    func testEmptyGoalThrowsExecutionFailed() async throws {
        let coordinator = TwoTierAutonomousLoopCoordinator()

        for goal in ["", "   \t \n  "] {
            do {
                _ = try await coordinator.execute(goal: goal)
                Issue.record("Empty goal '\(goal)' should throw")
            } catch let err as LoopExecutionError {
                guard case .executionFailed(let reason) = err else {
                    Issue.record("Expected executionFailed, got \(err)")
                    return
                }
                #expect(reason == "Goal cannot be empty.")
            }
        }
    }

    @Test("Planner returning empty subgoals falls back to single default subgoal")
    func testEmptyPlanFallbackExecutesCleanly() async throws {
        let cand = makeCandidate(id: "btn", role: "AXButton", label: "Proceed", x: 50, y: 50)
        let s0 = makeSnapshot(title: "Fallback View", candidates: [cand])
        let s1 = makeSnapshot(title: "Fallback View - Done", candidates: [cand])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: []) }
        )

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn", action: "click", confidence: 0.90, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Click Proceed")
        #expect(summary.isSuccess)
        #expect(summary.totalSubgoals == 1)
    }

    @Test("Subgoal step budget exceeded resolved by delegate skip advances to next subgoal")
    func testSubgoalBudgetExceededSkipResolution() async throws {
        final class SkipDelegate: AutonomousLoopDelegate, @unchecked Sendable {
            func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) async throws -> EscalationResolution? {
                switch reason {
                case .subgoalBudgetExceeded, .outcomeUnverified:
                    return .skipSubgoal(reason: "Skipping stuck subgoal")
                default:
                    return nil
                }
            }
        }

        let cand1 = makeCandidate(id: "btn1", role: "AXButton", label: "Stuck Button", x: 10, y: 10)
        let cand2 = makeCandidate(id: "btn2", role: "AXButton", label: "Final Button", x: 10, y: 50)
        let s0 = makeSnapshot(title: "Step 1", candidates: [cand1])
        let s1 = makeSnapshot(title: "Step 2 Done", candidates: [cand2])
        let inspector = MockUIInspector(snapshots: [s0, s0, s0, s1, s1])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_stuck_budget", description: "Click Stuck Button", expectedOutcome: "title changed to Nonexistent", maxSteps: 2)
        let sg2 = Subgoal(id: "sg_final", description: "Click Final Button", expectedOutcome: "title changed to Step 2 Done", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2])

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "btn1", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "btn2", action: "click", confidence: 0.90, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let delegate = SkipDelegate()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing,
            delegate: delegate
        )

        let summary = try await coordinator.execute(goal: "Skip budget test")
        #expect(summary.isSuccess)
    }
}
