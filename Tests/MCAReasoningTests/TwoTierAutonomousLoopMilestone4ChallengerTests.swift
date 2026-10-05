import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("Milestone 4 Challenger: Tier 5 Adversarial Coverage Hardening (Loop Coordinator & Planner)")
struct TwoTierAutonomousLoopMilestone4ChallengerTests {

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
    // SECTION 1: DELIMITER-AWARE PREFIX UNNESTING & STAGNANT KEYWORD HARDENING
    // =========================================================================

    @Test("Adversarial M4.1: stripReplanBoilerplate cleanly strips malformed and irregular punctuation chains")
    func testStripReplanBoilerplate_MalformedPunctuationChains() {
        let dirtyInput = ":::---  ,,,  retry:   for:   Navigate using alternative elements or shortcuts for: :: - Click Save"
        let unnested = DefaultSubgoalPlanner.stripReplanBoilerplate(from: dirtyInput)
        #expect(unnested == "Click Save", "Should cleanly un-nest mixed colons, hyphens, commas, and prefixes")

        let caseInsensitive = "RETRY AFTER LOW CONFIDENCE: NAVIGATE USING ALTERNATIVE ELEMENTS OR SHORTCUTS FOR: Submit Form"
        let unnestedCase = DefaultSubgoalPlanner.stripReplanBoilerplate(from: caseInsensitive)
        #expect(unnestedCase == "Submit Form", "Must be case-insensitive across uppercase prefix chains")
    }

    @Test("Adversarial M4.2: stripReplanBoilerplate preserves internal target text containing delimiters and keywords")
    func testStripReplanBoilerplate_InternalTargetPreservation() {
        let internalText = "Search for: flight options to Tokyo"
        let result = DefaultSubgoalPlanner.stripReplanBoilerplate(from: internalText)
        #expect(result == "Search for: flight options to Tokyo", "Internal 'for:' must not be stripped")

        let emptyString = DefaultSubgoalPlanner.stripReplanBoilerplate(from: "   \t \n - : , : -   ")
        #expect(emptyString.isEmpty, "String consisting only of whitespace and delimiters must reduce to empty")
    }

    @Test("Adversarial M4.3: stripStagnantKeywords protects compound words and strips standalone keywords")
    func testStripStagnantKeywords_CompoundWordsAndStandalone() {
        let compoundSentence = "Upload the update, setup the backup, check downtime in the scrollview, and inspect feedback"
        let preserved = DefaultSubgoalPlanner.stripStagnantKeywords(from: compoundSentence)
        #expect(preserved == compoundSentence, "Compound words containing stagnant substrings must not be altered")

        let stagnantSentence = "Scroll feed down to the timeline to read comments"
        let stripped = DefaultSubgoalPlanner.stripStagnantKeywords(from: stagnantSentence)
        #expect(stripped == "read comments", "Standalone stagnant words and chained prepositions must be stripped")
    }

    @Test("Adversarial M4.4: stripStagnantKeywords cleans Japanese complex stagnant phrasing and particles")
    func testStripStagnantKeywords_JapaneseComplexPhrasing() {
        let j1 = "フィードを下にスクロールして次へ進む"
        let s1 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j1)
        #expect(s1 == "次へ進む", "Must strip フィード, を, 下に, スクロール, して")

        let j2 = "上にスクロールをして最新のニュースを確認する"
        let s2 = DefaultSubgoalPlanner.stripStagnantKeywords(from: j2)
        #expect(s2 == "最新のニュースを確認する", "Must strip 上に, スクロール, をして")
    }

    @Test("Adversarial M4.5: heuristicReplan falls back to safe defaults when core text is completely stripped")
    func testHeuristicReplan_AllStagnantCoreFallback() {
        // Completely stripped actionStagnant goal falls back to "target elements or controls"
        let sgStagnant = Subgoal(id: "sg_stagnant_empty", description: "Scroll feed down", expectedOutcome: "", maxSteps: 3)
        let resStagnant = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgStagnant, reason: .actionStagnant(reason: "Unchanged diff"))
        if case .retrySubgoal(let retry) = resStagnant {
            #expect(retry.description == "Navigate using alternative elements or shortcuts for: target elements or controls")
        } else {
            Issue.record("Expected retrySubgoal, got: \(resStagnant)")
        }

        // Completely stripped lowConfidence goal falls back to "interactive elements on screen"
        let sgConf = Subgoal(id: "sg_conf_empty", description: "retry after low confidence: retry:", expectedOutcome: "", maxSteps: 3)
        let resConf = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sgConf, reason: .lowConfidence(confidence: 0.3, threshold: 0.8))
        if case .retrySubgoal(let retry) = resConf {
            #expect(retry.description == "Interact with alternative interactive element for: interactive elements on screen")
        } else {
            Issue.record("Expected retrySubgoal, got: \(resConf)")
        }
    }

    // =========================================================================
    // SECTION 2: MONOTONIC ATTEMPT NUMBERING (`nextRetryId`) DYNAMIC PROGRESSION
    // =========================================================================

    @Test("Adversarial M4.6: nextRetryId monotonically advances attempt numbers across changing suffixes")
    func testNextRetryId_MonotonicAcrossChangingSuffixes() {
        let (id1, attempt1) = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_checkout", suffix: "alt")
        #expect(id1 == "subgoal_checkout_alt" && attempt1 == 1)

        let (id2, attempt2) = DefaultSubgoalPlanner.nextRetryId(from: id1, suffix: "retry_conf")
        #expect(id2 == "subgoal_checkout_retry_conf_2" && attempt2 == 2)

        let (id3, attempt3) = DefaultSubgoalPlanner.nextRetryId(from: id2, suffix: "retry")
        #expect(id3 == "subgoal_checkout_retry_3" && attempt3 == 3)

        let (id4, attempt4) = DefaultSubgoalPlanner.nextRetryId(from: id3, suffix: "alt")
        #expect(id4 == "subgoal_checkout_alt_4" && attempt4 == 4)
    }

    @Test("Adversarial M4.7: nextRetryId preserves numbers embedded in base subgoal names")
    func testNextRetryId_ExistingNumbersInBaseName() {
        let (id1, attempt1) = DefaultSubgoalPlanner.nextRetryId(from: "subgoal_1_step_2", suffix: "alt")
        #expect(id1 == "subgoal_1_step_2_alt" && attempt1 == 1, "Should not treat base name numbers as retry attempt counts")

        let (id2, attempt2) = DefaultSubgoalPlanner.nextRetryId(from: id1, suffix: "alt")
        #expect(id2 == "subgoal_1_step_2_alt_2" && attempt2 == 2)
    }

    // =========================================================================
    // SECTION 3: SYNTHETIC ACTUATOR COORDINATE RESOLUTION & MISSING TARGETS
    // =========================================================================

    @Test("Adversarial M4.8: Unmatched action target generates confidence 0.0 and safely escalates to System 2 for recovery")
    func testExecuteSyntheticAction_UnmatchedTargetEscalatesToSystem2() async throws {
        let dummyCand = makeCandidate(id: "dummy_btn", role: "AXButton", label: "Other Button", x: 10, y: 10)
        let resolvedCand = makeCandidate(id: "target_btn", role: "AXButton", label: "Target Button", x: 100, y: 100)
        let s0 = makeSnapshot(title: "Initial Window", candidates: [dummyCand])
        let s1 = makeSnapshot(title: "Target Appeared Window", candidates: [resolvedCand])
        let sDone = makeSnapshot(title: "Completed Window", candidates: [resolvedCand])
        let inspector = MockUIInspector(snapshots: [s0, s1, sDone])
        let synthesizer = MockEventSynthesizer()

        // Step 1: Decision targets "nonexistent_button" -> Engine outputs confidence 0.0, action .none
        // Step 2: System 2 replans with alternative subgoal -> Engine matches target_btn with confidence 0.90
        // Step 3: Completed
        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "nonexistent_button", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: "target_btn", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0),
            (target: nil, action: "none", confidence: 0.90, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_unmatched", description: "Click missing button", expectedOutcome: "title changed to Completed Window", maxSteps: 4)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in SubgoalPlan(goal: goal, subgoals: [subgoal]) },
            escalationHandler: { reason, failedSubgoal, _, _ in
                // System 2 provides revised subgoal targeting valid button
                return .retrySubgoal(Subgoal(
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
        #expect(summary.isSuccess, "Must recover cleanly from unmatched target escalation")

        // Verify that click was eventually executed on target_btn at (140, 115)
        let clicks = synthesizer.recordedEvents.filter { event in
            if case .click(let pt, _, _) = event { return pt == resolvedCand.center }
            return false
        }
        #expect(!clicks.isEmpty, "Resolved click event must be recorded at valid candidate center")
    }

    @Test("Adversarial M4.9: executeSyntheticAction focuses element and types text for typeText action")
    func testExecuteSyntheticAction_TypeTextFocusAndType() async throws {
        let inputField = makeCandidate(id: "search_box", role: "AXTextField", label: "Search Field", x: 50, y: 50, w: 200, h: 40)
        let s0 = makeSnapshot(title: "Active Input View", candidates: [inputField])
        let s1 = makeSnapshot(title: "Active Input View - Typed", candidates: [inputField])
        let s2 = makeSnapshot(title: "Active Input View - Submitted", candidates: [inputField])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        // Decision sequence: typeText into search_box, followed by completion
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

        // Verify focus click at inputField.center
        let focusClicks = synthesizer.recordedEvents.filter { event in
            if case .click(let pt, _, _) = event { return pt == inputField.center }
            return false
        }
        #expect(!focusClicks.isEmpty, "typeText must focus field at candidate center before typing")

        // Verify text synthesis
        let textEvents = synthesizer.recordedEvents.compactMap { event -> String? in
            if case .typeText(let t) = event { return t }
            return nil
        }
        #expect(textEvents.contains("Hello World"), "typeText must synthesize text string into input field")
    }

    @Test("Adversarial M4.10: executeSyntheticAction correctly executes doubleClick and rightClick with coordinates")
    func testExecuteSyntheticAction_DoubleClickAndRightClick() async throws {
        let candidate = makeCandidate(id: "file_icon", role: "AXImage", label: "Document.txt", x: 200, y: 300, w: 60, h: 60)
        let s0 = makeSnapshot(title: "Desktop", candidates: [candidate])
        let s1 = makeSnapshot(title: "Document Opened", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "file_icon", action: "doubleClick", confidence: 0.95, text: nil, isCompleted: 0.0),
            (target: nil, action: "none", confidence: 0.95, text: nil, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_open_file", description: "Open document", expectedOutcome: "title changed to Document Opened", maxSteps: 3)
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

        let doubleClicks = synthesizer.recordedEvents.filter { event in
            if case .click(let pt, _, let count) = event {
                return count == 2 && pt == candidate.center
            }
            return false
        }
        #expect(!doubleClicks.isEmpty, "doubleClick must dispatch clickCount = 2 at candidate center")
    }

    @Test("Adversarial M4.11: Hardware synthesizer error triggers rollback and releases held events")
    func testExecuteSyntheticAction_HardwareSynthesizerErrorHandling() async throws {
        struct HardwareCrash: Error, LocalizedError {
            var errorDescription: String? { "CoreGraphics event generation failed" }
        }

        let cand = makeCandidate(id: "btn", role: "AXButton", label: "Button", x: 100, y: 100)
        let s0 = makeSnapshot(title: "Hardware Error Test", candidates: [cand])
        let inspector = MockUIInspector(repeating: s0)

        // Inject error into synthesizer
        let synthesizer = MockEventSynthesizer(injectedError: HardwareCrash())

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn", action: "click", confidence: 0.90, text: nil, isCompleted: 0.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_hw_fail", description: "Click button", expectedOutcome: "", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Test hardware error")
            Issue.record("Should have failed with executionFailed")
        } catch let err as LoopExecutionError {
            guard case .executionFailed(let reason) = err else {
                Issue.record("Expected executionFailed, got \(err)")
                return
            }
            #expect(reason.contains("CoreGraphics event generation failed"))
        }

        #expect(synthesizer.recordedEvents.contains { if case .releaseAllHeldEvents = $0 { return true }; return false })
    }

    // =========================================================================
    // SECTION 4: ESCALATION RECOVERY GUARD TRIPPING & MULTI-FACTOR RESET
    // =========================================================================

    @Test("Adversarial M4.12: Escalation limit trips immediately on first escalation when maxConsecutiveEscalations = 1")
    func testEscalationGuard_TripsAtLimit1() async throws {
        let s0 = makeSnapshot(title: "Empty Page", candidates: [])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [Subgoal(id: "sg_1", description: "Wait elements", expectedOutcome: "", maxSteps: 3)])
            },
            escalationHandler: { _, subgoal, _, _ in
                .retrySubgoal(subgoal)
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 1

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Test limit 1")
            Issue.record("Should have failed immediately with escalationFailed at limit 1")
        } catch let err as LoopExecutionError {
            guard case .escalationFailed(let reason) = err else {
                Issue.record("Expected escalationFailed, got \(err)")
                return
            }
            #expect(reason.contains("Exceeded maximum consecutive escalations (1)"))
        }
    }

    @Test("Adversarial M4.13: Escalation limit formatting includes diagnostic history across multiple reasons")
    func testEscalationGuard_MultiReasonHistorySummary() async throws {
        let s0 = makeSnapshot(title: "Static Page", candidates: [])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [Subgoal(id: "sg_multi", description: "Search", expectedOutcome: "", maxSteps: 5)])
            },
            escalationHandler: { reason, subgoal, _, _ in
                .retrySubgoal(subgoal)
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Test diagnostic history")
            Issue.record("Should have failed with escalationFailed")
        } catch let err as LoopExecutionError {
            guard case .escalationFailed(let reason) = err else {
                Issue.record("Expected escalationFailed, got \(err)")
                return
            }
            #expect(reason.contains("#1:"))
            #expect(reason.contains("#2:"))
            #expect(reason.contains("No actionable UI element candidates observed on screen"))
        }
    }

    @Test("Adversarial M4.14: Focus change resets consecutive escalations counter")
    func testEscalationGuard_ResetOnFocusChange() async throws {
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "First", x: 10, y: 10)
        let s0 = makeSnapshot(title: "Page", candidates: [btn1], focusedId: "btn1")
        let s1 = makeSnapshot(title: "Page", candidates: [btn1], focusedId: "btn2") // focus changed!
        let sFinal = makeSnapshot(title: "Page Done", candidates: [btn1], focusedId: "btn2")

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, sFinal])
        let synthesizer = MockEventSynthesizer()

        // 1st step: low confidence escalation (count: 1)
        // 2nd step: action executes, s0 -> s1 focus changes! diff.focusChanged == true -> resets consecutive escalations to 0!
        // 3rd step: low confidence escalation (count: 1, not 2!)
        // 4th step: completes
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
        config.maxConsecutiveEscalations = 2 // Would trip if focus change didn't reset!

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Focus reset test")
        #expect(summary.isSuccess)
    }

    // =========================================================================
    // SECTION 5: LOOP STAGNATION VS LOOP DETECTION DISTINCTION
    // =========================================================================

    @Test("Adversarial M4.15: System 2 loopDetected escalation immediately aborts execution")
    func testLoopStagnationVsDetection_LoopDetectedImmediatelyAborts() {
        let sg = Subgoal(id: "sg_loop", description: "Click repeat", expectedOutcome: "", maxSteps: 5)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(
            failedSubgoal: sg,
            reason: .loopDetected(reason: "Repeating identical subgoal sequence [sg_1 -> sg_2 -> sg_1]")
        )

        guard case .abort(let reason) = resolution else {
            Issue.record("Expected .abort for loopDetected reason, got: \(resolution)")
            return
        }
        #expect(reason.contains("Execution halted: Repeating identical subgoal sequence"))
    }

    // =========================================================================
    // SECTION 6: BOUNDARY DETECTION SEMANTICS ACROSS ATTEMPTS 1, 2, AND 3
    // =========================================================================

    @Test("Adversarial M4.16: Boundary detection semantics across attempt 1, attempt 2, and attempt 3")
    func testBoundaryDetection_AttemptsProgression() {
        let sg = Subgoal(id: "sg_boundary_sweep", description: "Scroll feed down to inspect table", expectedOutcome: "Table inspected", maxSteps: 3)

        // Attempt 1 without boundary keyword: retries
        let r1NonBoundary = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg, reason: .actionStagnant(reason: "diff unchanged"))
        if case .retrySubgoal(let retry) = r1NonBoundary {
            #expect(retry.id == "sg_boundary_sweep_alt")
        } else {
            Issue.record("Attempt 1 non-boundary must retry")
        }

        // Attempt 1 WITH boundary keyword: concludes immediately
        let r1Boundary = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg, reason: .actionStagnant(reason: "page boundary reached"))
        if case .abort(let reason) = r1Boundary {
            #expect(reason.contains("page boundary or recovery limit"))
        } else {
            Issue.record("Attempt 1 with boundary must conclude immediately")
        }

        // Attempt 1 WITH inert keyword: concludes immediately
        let r1Inert = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg, reason: .actionStagnant(reason: "target element is inert"))
        if case .abort(let reason) = r1Inert {
            #expect(reason.contains("page boundary or recovery limit"))
        } else {
            Issue.record("Attempt 1 with inert must conclude immediately")
        }

        // Attempt 2 without boundary keyword: retries with _alt_2
        let sg2 = Subgoal(id: "sg_boundary_sweep_alt", description: "Inspect table", expectedOutcome: "Table inspected", maxSteps: 3)
        let r2NonBoundary = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg2, reason: .actionStagnant(reason: "diff unchanged"))
        if case .retrySubgoal(let retry) = r2NonBoundary {
            #expect(retry.id == "sg_boundary_sweep_alt_2")
        } else {
            Issue.record("Attempt 2 non-boundary must retry")
        }

        // Attempt 3 without boundary keyword: concludes because attempt >= 3
        let sg3 = Subgoal(id: "sg_boundary_sweep_alt_2", description: "Inspect table", expectedOutcome: "Table inspected", maxSteps: 3)
        let r3 = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: sg3, reason: .actionStagnant(reason: "diff unchanged"))
        if case .abort(let reason) = r3 {
            #expect(reason.contains("page boundary or recovery limit"))
        } else {
            Issue.record("Attempt 3 must conclude even without boundary keyword")
        }
    }

    // =========================================================================
    // SECTION 7: EMPTY / MALFORMED GOALS & DELEGATE RECOVERY
    // =========================================================================

    @Test("Adversarial M4.17: Empty goal string throws executionFailed immediately")
    func testEmptyGoalThrowsExecutionFailed() async throws {
        let coordinator = TwoTierAutonomousLoopCoordinator()

        do {
            _ = try await coordinator.execute(goal: "")
            Issue.record("Empty goal should throw")
        } catch let err as LoopExecutionError {
            guard case .executionFailed(let reason) = err else {
                Issue.record("Expected executionFailed, got \(err)")
                return
            }
            #expect(reason == "Goal cannot be empty.")
        }

        do {
            _ = try await coordinator.execute(goal: "   \t \n  ")
            Issue.record("Whitespace-only goal should throw")
        } catch let err as LoopExecutionError {
            guard case .executionFailed(let reason) = err else {
                Issue.record("Expected executionFailed, got \(err)")
                return
            }
            #expect(reason == "Goal cannot be empty.")
        }
    }

    @Test("Adversarial M4.18: Planner returning empty subgoals falls back to single default subgoal")
    func testEmptyPlanFallbackExecutesCleanly() async throws {
        let cand = makeCandidate(id: "btn", role: "AXButton", label: "Proceed", x: 50, y: 50)
        let s0 = makeSnapshot(title: "Fallback View", candidates: [cand])
        let s1 = makeSnapshot(title: "Fallback View - Done", candidates: [cand])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        // Planner returns completely empty subgoals
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [])
            }
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
        #expect(summary.totalSubgoals == 1, "Should fall back to single generated subgoal")
    }

    @Test("Adversarial M4.19: Subgoal step budget exceeded resolved by delegate skip advances cleanly")
    func testSubgoalBudgetExceeded_SkipResolution() async throws {
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

        // Subgoal 1 has budget of 2 steps, both fail outcome verification
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
