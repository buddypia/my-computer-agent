import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

// MARK: - Test Suite: TwoTierAutonomousLoop Offline E2E Tests (Tiers 1-4)

@Suite("TwoTierAutonomousLoop Offline E2E Tests (Tiers 1-4)")
struct TwoTierAutonomousLoopOfflineE2ETests {

    // MARK: - Test Helpers

    private func makeCandidate(
        id: String,
        role: String = "AXButton",
        label: String = "Test Button",
        value: String? = nil,
        x: Double = 100,
        y: Double = 100,
        w: Double = 80,
        h: Double = 30
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

    private func makeOfflineEngine(confidenceThreshold: Float = 0.80) -> TypeSafeDecisionEngine {
        let offlineEvaluator = MockTypeSafeEvaluator { _ in
            throw TypeSafeClient.ClientError.missingApiKey
        }
        return TypeSafeDecisionEngine(client: offlineEvaluator, confidenceThreshold: confidenceThreshold)
    }

    // Tracking delegate for E2E observation
    private actor E2ETrackingDelegate: AutonomousLoopDelegate {
        var startedGoals: [String] = []
        var steppedActions: [(step: Int, action: ComputerActionDecision)] = []
        var diffs: [UIStateDiff] = []
        var escalations: [(reason: EscalationReason, subgoal: Subgoal)] = []
        var completedSummaries: [ExecutionSummary] = []
        var failedErrors: [LoopExecutionError] = []

        func loopDidStart(goal: String, initialPlan: SubgoalPlan) {
            startedGoals.append(goal)
        }

        func loopDidStep(step: Int, action: ComputerActionDecision, diff: UIStateDiff) {
            steppedActions.append((step, action))
            diffs.append(diff)
        }

        func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) -> EscalationResolution? {
            escalations.append((reason, subgoal))
            return nil
        }

        func loopDidComplete(summary: ExecutionSummary) {
            completedSummaries.append(summary)
        }

        func loopDidFail(error: LoopExecutionError) {
            failedErrors.append(error)
        }
    }

    // =========================================================================
    // MARK: - TIER 1: Feature Coverage (Features 1 - 8, 5 tests each = 40 tests)
    // =========================================================================

    // --- Feature 1: Container Grounded Fallback Scroll (5 tests) ---

    @Test("F1.1: AXScrollArea candidate is recognized and targeted for scroll actions in offline fallback")
    func testF1_01_AXScrollAreaCandidateGrounded() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 600)
        let otherButton = makeCandidate(id: "btn_refresh", role: "AXButton", label: "Refresh", x: 460, y: 50, w: 80, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "Scroll down feed to view more posts", candidates: [scrollArea, otherButton])

        #expect(decision.action == .scroll)
        #expect(decision.confidence >= 0.80)
        #expect(decision.scrollDelta?.dy != 0)
    }

    @Test("F1.2: AXWebArea candidate is targeted when no dedicated AXScrollArea is present")
    func testF1_02_AXWebAreaTargetedWhenNoScrollArea() async throws {
        let engine = makeOfflineEngine()
        let webArea = makeCandidate(id: "web_container", role: "AXWebArea", label: "Article Body", x: 0, y: 0, w: 800, h: 1000)

        let decision = engine.fallbackLocalDecision(goal: "Scroll feed down to read next section", candidates: [webArea])

        #expect(decision.action == .scroll)
        #expect(decision.confidence >= 0.80)
    }

    @Test("F1.3: AXList and AXTable containers support offline scroll action generation")
    func testF1_03_AXTableOrListContainerScrolling() async throws {
        let engine = makeOfflineEngine()
        let tableArea = makeCandidate(id: "data_table", role: "AXTable", label: "Accounts Table", x: 100, y: 100, w: 600, h: 400)

        let decision = engine.fallbackLocalDecision(goal: "Scroll down table to find account", candidates: [tableArea])

        #expect(decision.action == .scroll)
        #expect(decision.confidence >= 0.80)
    }

    @Test("F1.4: Scroll coordinates are safely dispatched to synthetic event synthesizer")
    func testF1_04_ScrollCoordinatesGroundingToContainerCenter() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "scroll_box", role: "AXScrollArea", label: "Message Box", x: 100, y: 200, w: 300, h: 400)
        let s0 = makeSnapshot(title: "Chat App", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Chat App - Scrolled", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_scroll", description: "Scroll feed down", expectedOutcome: "title changed to Chat App - Scrolled", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Scroll feed")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains { if case .scroll = $0 { return true }; return false })
    }

    @Test("F1.5: Multiple scroll areas prioritize relevant candidate or first available container")
    func testF1_05_MultipleScrollContainersSelection() async throws {
        let engine = makeOfflineEngine()
        let sidebar = makeCandidate(id: "sidebar_scroll", role: "AXScrollArea", label: "Sidebar Nav", x: 0, y: 0, w: 150, h: 600)
        let mainFeed = makeCandidate(id: "main_scroll", role: "AXScrollArea", label: "Main Feed", x: 160, y: 0, w: 600, h: 600)

        let decision = engine.fallbackLocalDecision(goal: "Scroll feed down", candidates: [sidebar, mainFeed])

        #expect(decision.action == .scroll)
        #expect(decision.confidence >= 0.80)
    }

    // --- Feature 2: Stagnation-Aware Action Adaptation (5 tests) ---

    @Test("F2.1: Repeated scroll without screen diff triggers loop stagnation detection")
    func testF2_01_UnchangedScreenTriggersStagnationDetection() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "stagnant_scroll", role: "AXScrollArea", label: "Static Feed", x: 0, y: 0, w: 400, h: 400)
        let staticSnap = makeSnapshot(title: "Unchanging Window", candidates: [scrollArea])
        let inspector = MockUIInspector(repeating: staticSnap)
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_stuck", description: "Scroll feed down", expectedOutcome: "screen changes", maxSteps: 10)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg], escalationResolution: .abort(reason: "Stagnant abort"))

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 3

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Scroll feed")
            Issue.record("Expected stagnation escalation or abort")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Stagnant abort") || reason.contains("stagnant") || reason.contains("infiniteLoopDetected"))
            }
        }
    }

    @Test("F2.2: Stagnation escalation allows planner to adapt by retrying with alternative action")
    func testF2_02_StagnationEscalationProvidesAlternativeNavigation() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_next", role: "AXButton", label: "Next", x: 100, y: 100, w: 80, h: 30)

        let s0 = makeSnapshot(title: "Page 1", candidates: [button])
        let s1 = makeSnapshot(title: "Page 2", candidates: [button])
        let inspector = MockUIInspector(snapshots: [s0, s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_scroll", description: "Scroll feed down", expectedOutcome: "title changed to Page 2", maxSteps: 3)
                ])
            },
            escalationHandler: { _, _, _, _ in
                // System 2 adapts plan to click button instead of scrolling
                .replacePlan([
                    Subgoal(id: "sg_click", description: "Click Next", expectedOutcome: "title changed to Page 2", maxSteps: 3)
                ])
            }
        )

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Navigate page")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("F2.3: observed title transition completes the subgoal after scrolling")
    func testF2_03_BoundaryStagnationConcludesSubgoalWhenTargetReached() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed", role: "AXScrollArea", label: "Feed", x: 0, y: 0, w: 400, h: 400)
        let s0 = makeSnapshot(title: "Feed End", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Feed End - Done", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_bound", description: "Scroll feed down", expectedOutcome: "title changed to Feed End - Done", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Complete at boundary")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)
        #expect(synthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }.count == 1)
    }

    @Test("F2.4: UIStateDiff accurately identifies unchanged state between identical snapshots")
    func testF2_04_StateDiffUnchangedFlagAccuratelyEvaluated() {
        let candidate = makeCandidate(id: "c1", role: "AXStaticText", label: "Text", x: 10, y: 10, w: 50, h: 20)
        let s0 = makeSnapshot(title: "Same Window", candidates: [candidate], frameHash: "hash_constant")
        let s1 = makeSnapshot(title: "Same Window", candidates: [candidate], frameHash: "hash_constant")

        let diff = UIStateDiff.compute(before: s0, after: s1)
        #expect(diff.isStateUnchanged)
        #expect(!diff.hasSignificantChange)

        let candidateNew = makeCandidate(id: "c2", role: "AXButton", label: "New Button", x: 10, y: 40, w: 80, h: 30)
        let s2 = makeSnapshot(title: "Same Window", candidates: [candidate, candidateNew], frameHash: "hash_mutated")
        let diffChanged = UIStateDiff.compute(before: s0, after: s2)
        #expect(!diffChanged.isStateUnchanged)
    }

    @Test("F2.5: Significant screen change resets stagnation tracking across successive steps")
    func testF2_05_ScreenChangeResetsConsecutiveStagnationCount() async throws {
        let engine = makeOfflineEngine()
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "Click Me", x: 10, y: 10, w: 80, h: 30)
        let s0 = makeSnapshot(title: "Step 0", candidates: [btn1])
        let s1 = makeSnapshot(title: "Step 1", candidates: [btn1])
        let s2 = makeSnapshot(title: "Step 2", candidates: [btn1])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_flow", description: "Click Click Me", expectedOutcome: "title changed to Step 2", maxSteps: 5)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Click button")
        #expect(summary.isSuccess)
    }

    // --- Feature 3: Token-Based Candidate Matching (5 tests) ---

    @Test("F3.1: Partial label match avoids 0.00 confidence fallthrough")
    func testF3_01_PartialLabelMatchAvoidsZeroConfidence() {
        let engine = makeOfflineEngine()
        let candidate = makeCandidate(id: "btn_submit", role: "AXButton", label: "Submit Application Form", x: 100, y: 100, w: 150, h: 40)

        let decision = engine.fallbackLocalDecision(goal: "Click Submit", candidates: [candidate])

        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_submit")
        #expect(decision.confidence >= 0.80)
    }

    @Test("F3.2: Value attribute is matched when element label is empty")
    func testF3_02_ValueAttributeMatchingWhenLabelEmpty() {
        let engine = makeOfflineEngine()
        let searchField = makeCandidate(id: "search_input", role: "AXTextField", label: "", value: "Search or enter URL", x: 50, y: 50, w: 300, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "Type swift in search field", candidates: [searchField])

        #expect(decision.action == .typeText)
        #expect(decision.targetElementId == "search_input")
        #expect(decision.textInput == "swift")
        #expect(decision.confidence >= 0.80)
    }

    @Test("F3.3: Multi-word goal tokens match compound candidate labels")
    func testF3_03_MultiWordTokenOverlapMatching() {
        let engine = makeOfflineEngine()
        let settingsBtn = makeCandidate(id: "btn_settings", role: "AXButton", label: "Account Profile Settings", x: 200, y: 50, w: 160, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "Click settings", candidates: [settingsBtn])

        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_settings")
        #expect(decision.confidence >= 0.80)
    }

    @Test("F3.4: Candidate matching is case-insensitive and ignores surrounding whitespace")
    func testF3_04_CaseAndWhitespaceInsensitiveMatching() {
        let engine = makeOfflineEngine()
        let saveBtn = makeCandidate(id: "btn_save", role: "AXButton", label: "Save Changes", x: 100, y: 300, w: 100, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "   SAVE CHANGES   ", candidates: [saveBtn])

        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_save")
    }

    @Test("F3.5: Best overlap score correctly disambiguates among multiple candidates")
    func testF3_05_DisambiguationPrefersLongestOrHighestOverlap() {
        let engine = makeOfflineEngine()
        let draftBtn = makeCandidate(id: "btn_draft", role: "AXButton", label: "Save Draft", x: 100, y: 100, w: 100, h: 30)
        let publishBtn = makeCandidate(id: "btn_publish", role: "AXButton", label: "Save and Publish Immediately", x: 210, y: 100, w: 200, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "Click Save and Publish Immediately", candidates: [draftBtn, publishBtn])

        #expect(decision.targetElementId == "btn_publish")
    }

    // --- Feature 4: Graceful Low-Confidence Recovery (5 tests) ---

    @Test("F4.1: Unmatched goal produces low confidence decision that escalates to System 2 Planner")
    func testF4_01_ZeroConfidenceEscalatesToSystem2() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel", x: 50, y: 50, w: 80, h: 30)
        let s0 = makeSnapshot(title: "Dialog", candidates: [button])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_unmatched", description: "Click Rocket Launch", expectedOutcome: "Launched", maxSteps: 3)
                ])
            },
            escalationHandler: { reason, _, _, _ in
                if case .lowConfidence(let conf, let thresh) = reason {
                    #expect(conf < thresh)
                }
                return .abort(reason: "Low confidence caught properly")
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Launch rocket")
            Issue.record("Expected escalation abort")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Low confidence caught properly"))
            }
        }
    }

    @Test("F4.2: Low confidence replanning allows coordinator to resume and complete execution")
    func testF4_02_PlannerReplanResolvesLowConfidenceWithoutAbort() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_cancel", role: "AXButton", label: "Cancel", x: 50, y: 50, w: 80, h: 30)
        let s0 = makeSnapshot(title: "Dialog", candidates: [button])
        let s1 = makeSnapshot(title: "Dialog Closed", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_low", description: "Unknown Action", expectedOutcome: "title changed to Dialog Closed", maxSteps: 3)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .replacePlan([
                    Subgoal(id: "sg_recovered", description: "Click Cancel", expectedOutcome: "title changed to Dialog Closed", maxSteps: 3)
                ])
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Handle dialog")
        #expect(summary.isSuccess)
    }

    @Test("F4.3: Low confidence step records are logged in delegate history")
    func testF4_03_LowConfidenceStepRecordedInHistory() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_noop", role: "AXButton", label: "Nothing", x: 10, y: 10, w: 50, h: 20)
        let s0 = makeSnapshot(title: "App", candidates: [button])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let delegate = E2ETrackingDelegate()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Unmatched Goal", expectedOutcome: "Done", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .abort(reason: "Escalated on low confidence")
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            delegate: delegate
        )

        _ = try? await coordinator.execute(goal: "Track steps")
        let escalations = await delegate.escalations
        #expect(!escalations.isEmpty)
    }

    @Test("F4.4: Low confidence decision reasoning contains informative diagnostics")
    func testF4_04_LowConfidenceReasoningContainsDiagnosticMessage() {
        let engine = makeOfflineEngine()
        let candidate = makeCandidate(id: "btn_save", role: "AXButton", label: "Save", x: 10, y: 10, w: 40, h: 20)

        let decision = engine.fallbackLocalDecision(goal: "Find missing records", candidates: [candidate])
        #expect(decision.confidence < 0.80)
        #expect(!(decision.reasoning?.isEmpty ?? true))
    }

    @Test("F4.5: Subgoal step budget resets upon successful escalation recovery")
    func testF4_05_SubgoalStepBudgetResetsOnEscalationResolution() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_ok", role: "AXButton", label: "OK", x: 50, y: 50, w: 50, h: 25)
        let s0 = makeSnapshot(title: "Window", candidates: [button])
        let s1 = makeSnapshot(title: "Window OK", candidates: [button])
        let inspector = MockUIInspector(snapshots: [s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_retry", description: "Mismatched", expectedOutcome: "title changed to Window OK", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .retrySubgoal(Subgoal(id: "sg_retry_fixed", description: "Click OK", expectedOutcome: "title changed to Window OK", maxSteps: 3))
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Reset budget test")
        #expect(summary.isSuccess)
    }

    // --- Feature 5: Feedback Loop to Decision Engine (5 tests) ---

    @Test("F5.1: Execution history records monotonically increasing step counts")
    func testF5_01_StepHistoryTrackedInCoordinatorExecution() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_step", role: "AXButton", label: "Next", x: 10, y: 10, w: 50, h: 20)
        let s0 = makeSnapshot(title: "Alpha", candidates: [btn])
        let s1 = makeSnapshot(title: "Beta", candidates: [btn])
        let s2 = makeSnapshot(title: "Gamma", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()
        let delegate = E2ETrackingDelegate()

        let sg = Subgoal(id: "sg_steps", description: "Click Next", expectedOutcome: "title changed to Gamma", maxSteps: 4)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            delegate: delegate
        )

        _ = try await coordinator.execute(goal: "Track steps")
        let stepped = await delegate.steppedActions
        #expect(stepped.count >= 2)
        #expect(stepped[0].step < stepped[1].step)
    }

    @Test("F5.2: Escalation records track exact escalation reason in coordinator state")
    func testF5_02_RecentEscalationsRecordedInCoordinatorState() async throws {
        let engine = makeOfflineEngine()
        let s0 = makeSnapshot(title: "Empty", candidates: [])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()
        let delegate = E2ETrackingDelegate()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_esc", description: "Do Something", expectedOutcome: "Done", maxSteps: 3)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .abort(reason: "Escalated correctly")
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            delegate: delegate
        )

        _ = try? await coordinator.execute(goal: "Empty candidates")
        let escalations = await delegate.escalations
        #expect(!escalations.isEmpty)
        guard case .emptyCandidates = escalations[0].reason else {
            Issue.record("Expected emptyCandidates escalation reason, got \(escalations[0].reason)")
            return
        }
    }

    @Test("F5.3: Post-action UIStateDiff is delivered with each step notification")
    func testF5_03_PostActionDiffDeliveredToDelegate() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_action", role: "AXButton", label: "Trigger", x: 20, y: 20, w: 60, h: 30)
        let s0 = makeSnapshot(title: "Initial", candidates: [btn])
        let s1 = makeSnapshot(title: "Mutated", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()
        let delegate = E2ETrackingDelegate()

        let sg = Subgoal(id: "sg_diff", description: "Click Trigger", expectedOutcome: "title changed to Mutated", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            delegate: delegate
        )

        _ = try await coordinator.execute(goal: "Diff test")
        let diffs = await delegate.diffs
        #expect(!diffs.isEmpty)
        #expect(diffs[0].titleChanged)
    }

    @Test("F5.4: Synthesized events accurately reflect the engine's decided action")
    func testF5_04_SynthesizedEventsReflectDecidedAction() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_tap", role: "AXButton", label: "Tap", x: 80, y: 90, w: 50, h: 25)
        let s0 = makeSnapshot(title: "Screen", candidates: [btn])
        let s1 = makeSnapshot(title: "Screen Done", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_tap", description: "Click Tap", expectedOutcome: "title changed to Screen Done", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        _ = try await coordinator.execute(goal: "Tap test")
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("F5.5: First step executes cleanly with clean initial state and zero prior history")
    func testF5_05_InitialStepExecutesCleanlyWithZeroHistory() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_start", role: "AXButton", label: "Start", x: 10, y: 10, w: 60, h: 30)
        let s0 = makeSnapshot(title: "Fresh", candidates: [btn])
        let s1 = makeSnapshot(title: "Fresh Started", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_init", description: "Click Start", expectedOutcome: "title changed to Fresh Started", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Initial start")
        #expect(summary.isSuccess)
    }

    // --- Feature 6: Non-Recursive Heuristic Replan (5 tests) ---

    @Test("F6.1: Heuristic replan for actionStagnant produces a retry subgoal")
    func testF6_01_HeuristicReplanForActionStagnantReturnsRetrySubgoal() {
        let failed = Subgoal(id: "sg_stuck", description: "Scroll feed", expectedOutcome: "Feed updated", maxSteps: 3)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failed, reason: .actionStagnant(reason: "Stuck"))

        if case .retrySubgoal(let retrySg) = resolution {
            #expect(!retrySg.description.isEmpty)
        } else {
            Issue.record("Expected .retrySubgoal resolution for actionStagnant")
        }
    }

    @Test("F6.2: Heuristic replan for lowConfidence produces an alternative element retry subgoal")
    func testF6_02_HeuristicReplanForLowConfidenceReturnsRetrySubgoal() {
        let failed = Subgoal(id: "sg_conf", description: "Click Widget", expectedOutcome: "Widget open", maxSteps: 2)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failed, reason: .lowConfidence(confidence: 0.1, threshold: 0.8))

        if case .retrySubgoal(let retrySg) = resolution {
            #expect(retrySg.maxSteps >= 3)
        } else {
            Issue.record("Expected .retrySubgoal resolution for lowConfidence")
        }
    }

    @Test("F6.3: Heuristic replan for loopDetected halts with abort resolution")
    func testF6_03_HeuristicReplanForLoopDetectedAborts() {
        let failed = Subgoal(id: "sg_loop", description: "Loop Action", expectedOutcome: "None", maxSteps: 3)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failed, reason: .loopDetected(reason: "Infinite loop"))

        if case .abort(let reason) = resolution {
            #expect(reason.contains("Infinite loop") || reason.contains("Execution halted"))
        } else {
            Issue.record("Expected .abort resolution for loopDetected")
        }
    }

    @Test("F6.4: Heuristic replan for outcomeUnverified aborts with informative cause")
    func testF6_04_HeuristicReplanForOutcomeUnverifiedAborts() {
        let failed = Subgoal(id: "sg_outcome", description: "Verify", expectedOutcome: "Dashboard loaded", maxSteps: 5)
        let resolution = DefaultSubgoalPlanner.heuristicReplan(failedSubgoal: failed, reason: .outcomeUnverified(expected: "Dashboard loaded", stepsTaken: 5))

        if case .abort(let reason) = resolution {
            #expect(reason.contains("Dashboard loaded"))
        } else {
            Issue.record("Expected .abort resolution for outcomeUnverified")
        }
    }

    @Test("F6.5: Heuristic decompose decomposes search and click phrases into sequential subgoals")
    func testF6_05_HeuristicDecomposeExtractsSubgoals() {
        let subgoals = DefaultSubgoalPlanner.heuristicDecompose(goal: "search Tokyo and click first link")
        #expect(subgoals.count == 2)
        #expect(subgoals[0].description.contains("search query") || subgoals[0].description.contains("search field"))
        #expect(subgoals[1].description.contains("Click"))
    }

    // --- Feature 7: Coordinator Coordinate Fallback (5 tests) ---

    @Test("F7.1: Scroll action with nil coordinates dispatches safely to synthesizer")
    func testF7_01_ScrollDispatchedWithNilPointSafely() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "scroll_view", role: "AXScrollArea", label: "View", x: 10, y: 10, w: 500, h: 400)
        let s0 = makeSnapshot(title: "Win", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Win Done", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_scr", description: "Scroll feed", expectedOutcome: "title changed to Win Done", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Scroll test")
        #expect(summary.isSuccess)
    }

    @Test("F7.2: Click action dispatches exact candidate center coordinates to synthesizer")
    func testF7_02_ClickDispatchesExactCandidateCenter() async throws {
        let engine = makeOfflineEngine()
        let button = makeCandidate(id: "btn_center", role: "AXButton", label: "Target", x: 100, y: 200, w: 80, h: 40)
        let s0 = makeSnapshot(title: "App", candidates: [button])
        let s1 = makeSnapshot(title: "App Clicked", candidates: [button])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_clk", description: "Click Target", expectedOutcome: "title changed to App Clicked", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        _ = try await coordinator.execute(goal: "Click target")
        let clicks = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .click(let pt, _, _) = event { return pt }
            return nil
        }
        #expect(!clicks.isEmpty)
        #expect(clicks[0].x == 140)
        #expect(clicks[0].y == 220)
    }

    @Test("F7.3: Scroll delta values are faithfully recorded in synthesizer events")
    func testF7_03_ScrollDeltaPreservedInSynthesizer() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "scroll_box", role: "AXScrollArea", label: "Feed", x: 0, y: 0, w: 300, h: 300)
        let s0 = makeSnapshot(title: "Screen", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Screen Scrolled", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_s", description: "Scroll feed down", expectedOutcome: "title changed to Screen Scrolled", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        _ = try await coordinator.execute(goal: "Scroll delta check")
        let scrolls = synthesizer.recordedEvents.compactMap { event -> Int32? in
            if case .scroll(_, let dy, _, _) = event { return dy }
            return nil
        }
        #expect(!scrolls.isEmpty)
        #expect(scrolls[0] < 0)
    }

    @Test("F7.4: TypeText action synthesizes string into targeted text field")
    func testF7_04_TypeTextSynthesizerDispatch() async throws {
        let engine = makeOfflineEngine()
        let tf = makeCandidate(id: "tf_input", role: "AXTextField", label: "Email", x: 10, y: 10, w: 200, h: 30)
        let s0 = makeSnapshot(title: "Form", candidates: [tf])
        let s1 = makeSnapshot(title: "Form Typed", candidates: [tf])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_t", description: "Type user@example.com into Email", expectedOutcome: "title changed to Form Typed", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        _ = try await coordinator.execute(goal: "Enter email")
        #expect(synthesizer.recordedEvents.contains { if case .typeText = $0 { return true }; return false })
    }

    @Test("F7.5: KeyPress action synthesizes key combinations into event stream")
    func testF7_05_KeyPressSynthesizerDispatch() async throws {
        let engine = makeOfflineEngine()
        let candidate = makeCandidate(id: "body", role: "AXGroup", label: "Body", x: 0, y: 0, w: 500, h: 500)
        let s0 = makeSnapshot(title: "Page", candidates: [candidate])
        let s1 = makeSnapshot(title: "Page Enter", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_k", description: "press key Return", expectedOutcome: "title changed to Page Enter", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        _ = try await coordinator.execute(goal: "Press enter")
        #expect(synthesizer.recordedEvents.contains { if case .pressKey = $0 { return true }; return false })
    }

    // --- Feature 8: Consecutive Escalation Recovery Guard (5 tests) ---

    @Test("F8.1: AutonomousLoopConfig respects custom maxConsecutiveEscalations limit")
    func testF8_01_MaxConsecutiveEscalationsConfigurable() {
        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 5
        #expect(config.maxConsecutiveEscalations == 5)
    }

    @Test("F8.2: Reaching maxConsecutiveEscalations halts execution with escalationFailed error")
    func testF8_02_ReachingLimitHaltsWithEscalationFailed() async throws {
        let engine = makeOfflineEngine()
        let s0 = makeSnapshot(title: "Empty Window", candidates: [])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_loop", description: "Empty Search", expectedOutcome: "Found", maxSteps: 5)
                ])
            },
            escalationHandler: { _, subgoal, _, _ in
                // System 2 stubbornly retries failed subgoal
                .retrySubgoal(subgoal)
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
            _ = try await coordinator.execute(goal: "Cascading escalation")
            Issue.record("Expected escalation limit error")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Exceeded maximum consecutive escalations"))
            }
        }
    }

    @Test("F8.3: Escalation limit error diagnostics include context on recent escalation causes")
    func testF8_03_ErrorDiagnosticIncludesRecentCauses() async throws {
        let engine = makeOfflineEngine()
        let s0 = makeSnapshot(title: "Empty Window", candidates: [])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_esc", description: "Search", expectedOutcome: "Result", maxSteps: 5)
                ])
            },
            escalationHandler: { _, subgoal, _, _ in
                .retrySubgoal(subgoal)
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

        do {
            _ = try await coordinator.execute(goal: "Diagnostic test")
            Issue.record("Expected failure")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("2") || reason.contains("escalation"))
            }
        }
    }

    @Test("F8.4: A single escalation that is successfully recovered allows overall goal to succeed")
    func testF8_04_SingleEscalationWithSubgoalResolutionCompletesSuccessfully() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_go", role: "AXButton", label: "Go", x: 20, y: 20, w: 50, h: 30)
        let s0 = makeSnapshot(title: "Phase 1", candidates: [btn])
        let s1 = makeSnapshot(title: "Phase 2", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_bad", description: "Nonexistent button", expectedOutcome: "title changed to Phase 2", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                // Successfully resolves by replacing plan
                .replacePlan([
                    Subgoal(id: "sg_good", description: "Click Go", expectedOutcome: "title changed to Phase 2", maxSteps: 2)
                ])
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Single escalation recovery")
        #expect(summary.isSuccess)
    }

    @Test("F8.5: Consecutive escalations counter resets when a subgoal makes progress or advances")
    func testF8_05_ConsecutiveEscalationsResetOnSubgoalAdvance() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn_next", role: "AXButton", label: "Next", x: 10, y: 10, w: 60, h: 30)
        let s0 = makeSnapshot(title: "Step 1", candidates: [btn])
        let s1 = makeSnapshot(title: "Step 2", candidates: [btn])
        let s2 = makeSnapshot(title: "Step 3", candidates: [btn])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Unknown Target", expectedOutcome: "title changed to Step 2", maxSteps: 2),
                    Subgoal(id: "sg_2", description: "Click Next", expectedOutcome: "title changed to Step 3", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                // Skip problematic subgoal 1
                .skipCurrentSubgoal
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Reset counter test")
        #expect(summary.isSuccess)
    }

    // =========================================================================
    // MARK: - TIER 2: Boundary & Corner Cases (8 tests)
    // =========================================================================

    @Test("T2.1: Empty candidates list produces 0.00 confidence without crash")
    func testT2_01_EmptyCandidatesListInOfflineFallback() {
        let engine = makeOfflineEngine()
        let decision = engine.fallbackLocalDecision(goal: "Click Submit", candidates: [])

        #expect(decision.action == .none)
        #expect(decision.confidence == 0.0)
        #expect(decision.targetElementId == nil)
    }

    @Test("T2.2: Single-pixel (1x1) candidate bounds compute valid center point")
    func testT2_02_SinglePixelCandidateBounds() {
        let candidate = makeCandidate(id: "pixel_elem", role: "AXButton", label: "Dot", x: 200, y: 300, w: 1, h: 1)
        #expect(candidate.center.x == 200.5)
        #expect(candidate.center.y == 300.5)

        let engine = makeOfflineEngine()
        let decision = engine.fallbackLocalDecision(goal: "Click Dot", candidates: [candidate])
        #expect(decision.targetCenter?.x == 200.5)
        #expect(decision.targetCenter?.y == 300.5)
    }

    @Test("T2.3: Extreme scroll delta values are parsed and bounded safely")
    func testT2_03_ExtremeScrollDeltaValues() {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "scroll_deep", role: "AXScrollArea", label: "Deep Feed", x: 0, y: 0, w: 500, h: 500)

        let downDecision = engine.fallbackLocalDecision(goal: "Scroll down 5000", candidates: [scrollArea])
        #expect(downDecision.action == .scroll)
        #expect(downDecision.scrollDelta?.dy != 0)

        let upDecision = engine.fallbackLocalDecision(goal: "Scroll up 5000", candidates: [scrollArea])
        #expect(upDecision.action == .scroll)
        #expect(upDecision.scrollDelta?.dy != 0)
    }

    @Test("T2.4: Unkeyed Jev with network failure seamlessly activates local fallback")
    func testT2_04_UnkeyedJevWithNetworkFailureFailover() async throws {
        let networkErrorEvaluator = MockTypeSafeEvaluator { _ in
            throw URLError(.timedOut)
        }
        let engine = TypeSafeDecisionEngine(client: networkErrorEvaluator)
        let btn = makeCandidate(id: "btn_fallback", role: "AXButton", label: "Proceed", x: 10, y: 10, w: 80, h: 30)

        let decision = try await engine.decideNextAction(goal: "Click Proceed", candidates: [btn])
        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_fallback")
    }

    @Test("T2.5: Zero maxTotalSteps configuration immediately throws stepBudgetExceeded")
    func testT2_05_ZeroMaxStepsThrowsBudgetExceededImmediately() async throws {
        let engine = makeOfflineEngine()
        let btn = makeCandidate(id: "btn1", role: "AXButton", label: "Button", x: 10, y: 10, w: 50, h: 20)
        let s0 = makeSnapshot(title: "Win", candidates: [btn])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click Button", expectedOutcome: "Clicked", maxSteps: 5)
        ])

        var config = AutonomousLoopConfig.testing
        config.maxTotalSteps = 0

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Zero steps")
            Issue.record("Expected stepBudgetExceeded error")
        } catch let error as LoopExecutionError {
            guard case .stepBudgetExceeded = error else {
                Issue.record("Expected .stepBudgetExceeded, got \(error)")
                return
            }
        }
    }

    @Test("T2.6: Confidence exactly at 0.80 proceeds without escalation while 0.79 escalates")
    func testT2_06_ExactConfidenceThresholdBoundary() async throws {
        let evalPassing = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.80, actionChoice: "click")
        let enginePassing = TypeSafeDecisionEngine(client: evalPassing, confidenceThreshold: 0.80)
        let btn = makeCandidate(id: "btn_ok", role: "AXButton", label: "OK", x: 10, y: 10, w: 50, h: 20)
        let decPassing = try await enginePassing.decideNextAction(goal: "Click OK", candidates: [btn])
        #expect(!enginePassing.shouldEscalate(decision: decPassing))

        let evalFailing = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.79, actionChoice: "click")
        let engineFailing = TypeSafeDecisionEngine(client: evalFailing, confidenceThreshold: 0.80)
        let decFailing = try await engineFailing.decideNextAction(goal: "Click OK", candidates: [btn])
        #expect(engineFailing.shouldEscalate(decision: decFailing))
    }

    @Test("T2.7: Large candidate lists (1000 items) are evaluated efficiently without memory spike")
    func testT2_07_LargeCandidateSetEvaluationPerformance() {
        let engine = makeOfflineEngine()
        var candidates: [UIElementCandidate] = []
        for i in 0..<1000 {
            candidates.append(makeCandidate(id: "elem_\(i)", role: "AXStaticText", label: "Item Number \(i)", x: Double(i * 10), y: Double(i * 10), w: 100, h: 20))
        }
        candidates.append(makeCandidate(id: "target_btn", role: "AXButton", label: "Target Action", x: 500, y: 500, w: 120, h: 40))

        var decision: ComputerActionDecision!
        let ms = threadCPUMilliseconds {
            decision = engine.fallbackLocalDecision(goal: "Click Target Action", candidates: candidates)
        }

        #expect(decision.targetElementId == "target_btn")
        #expect(ms < 100, "Sub-100ms evaluation (measured: \(ms)ms of CPU)")
    }

    @Test("T2.8: Unicode and Japanese punctuation in goals and candidate labels match accurately")
    func testT2_08_UnicodeAndJapanesePunctuationInGoalAndLabels() {
        let engine = makeOfflineEngine()
        let settingsBtn = makeCandidate(id: "btn_jp_settings", role: "AXButton", label: "設定", x: 10, y: 10, w: 80, h: 30)

        let decision = engine.fallbackLocalDecision(goal: "設定を開く", candidates: [settingsBtn])

        #expect(decision.action == .click)
        #expect(decision.targetElementId == "btn_jp_settings")
    }

    // =========================================================================
    // MARK: - TIER 3: Cross-Feature Combinations (5 tests)
    // =========================================================================

    @Test("T3.1: Stagnant scroll + low confidence + replan feedback resolves to clean completion")
    func testT3_01_StagnantScrollWithLowConfidenceAndReplanRecovery() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Feed", x: 0, y: 0, w: 400, h: 400)
        let targetBtn = makeCandidate(id: "btn_finish", role: "AXButton", label: "Finish", x: 100, y: 350, w: 80, h: 30)

        let s0 = makeSnapshot(title: "Feed View", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Feed View", candidates: [scrollArea])
        let s2 = makeSnapshot(title: "Target Appeared", candidates: [targetBtn])
        let s3 = makeSnapshot(title: "Goal Completed", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2, s3])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_scr", description: "Scroll feed down", expectedOutcome: "title changed to Target Appeared", maxSteps: 3)
                ])
            },
            escalationHandler: { reason, _, _, _ in
                // When stagnant or low confidence, switch to clicking finish
                .replacePlan([
                    Subgoal(id: "sg_clk", description: "Click Finish", expectedOutcome: "title changed to Goal Completed", maxSteps: 2)
                ])
            }
        )

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Scroll and finish")
        #expect(summary.isSuccess)
    }

    @Test("T3.2: Container scroll with observed state diff progress advances subgoal naturally")
    func testT3_02_ContainerScrollWithStateDiffProgress() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Feed", x: 0, y: 0, w: 400, h: 400)
        let s0 = makeSnapshot(title: "Top of Feed", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "Middle of Feed", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let sg = Subgoal(id: "sg_scroll_prog", description: "Scroll feed down", expectedOutcome: "title changed to Middle of Feed", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Progressive scroll")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 1)
    }

    @Test("T3.3: Network drop during multi-step workflow transitions to offline fallback and completes")
    func testT3_03_NetworkDropFailoverDuringMultiStepWorkflow() async throws {
        // Step 1 succeeds via Jev mock, Step 2 fails with missingApiKey and falls back
        final class RequestCounter: @unchecked Sendable {
            private var count = 0
            private let lock = NSLock()
            func nextCount() -> Int {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let counter = RequestCounter()
        let failingEvaluator = MockTypeSafeEvaluator { _ in
            let count = counter.nextCount()
            if count == 1 {
                return TypeSafeClient.EvaluationResponse(
                    model: "jev-mock",
                    answers: [
                        "target_element": TypeSafeClient.AnswerPayload(type: "choice", choice: "btn_step1", confidence: 0.95),
                        "action_type": TypeSafeClient.AnswerPayload(type: "choice", choice: "click", confidence: 0.95),
                        "is_completed": TypeSafeClient.AnswerPayload(type: "noul", noul: 0.0)
                    ]
                )
            } else {
                throw TypeSafeClient.ClientError.missingApiKey
            }
        }

        let engine = TypeSafeDecisionEngine(client: failingEvaluator)
        let btn1 = makeCandidate(id: "btn_step1", role: "AXButton", label: "Step One", x: 10, y: 10, w: 60, h: 30)
        let btn2 = makeCandidate(id: "btn_step2", role: "AXButton", label: "Step Two", x: 80, y: 10, w: 60, h: 30)

        let s0 = makeSnapshot(title: "Stage 0", candidates: [btn1, btn2])
        let s1 = makeSnapshot(title: "Stage 1", candidates: [btn2])
        let s2 = makeSnapshot(title: "Stage 2 Done", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_1", description: "Click Step One", expectedOutcome: "title changed to Stage 1", maxSteps: 2)
        let sg2 = Subgoal(id: "sg_2", description: "Click Step Two", expectedOutcome: "title changed to Stage 2 Done", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Failover workflow")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
    }

    @Test("T3.4: Multiple subgoals experiencing isolated escalations complete without tripping consecutive limit")
    func testT3_04_EscalationResetAcrossMultipleSubgoals() async throws {
        let engine = makeOfflineEngine()
        let btnA = makeCandidate(id: "btn_a", role: "AXButton", label: "Action A", x: 10, y: 10, w: 60, h: 30)
        let btnB = makeCandidate(id: "btn_b", role: "AXButton", label: "Action B", x: 80, y: 10, w: 60, h: 30)

        let s0 = makeSnapshot(title: "Screen 0", candidates: [btnA])
        let s1 = makeSnapshot(title: "Screen 1", candidates: [btnB])
        let s2 = makeSnapshot(title: "Screen 2 Done", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_a_bad", description: "Bad A", expectedOutcome: "title changed to Screen 1", maxSteps: 2),
                    Subgoal(id: "sg_b_bad", description: "Bad B", expectedOutcome: "title changed to Screen 2 Done", maxSteps: 2)
                ])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                if failedSubgoal.id == "sg_a_bad" {
                    return .retrySubgoal(Subgoal(id: "sg_a_ok", description: "Click Action A", expectedOutcome: "title changed to Screen 1", maxSteps: 2))
                } else {
                    return .retrySubgoal(Subgoal(id: "sg_b_ok", description: "Click Action B", expectedOutcome: "title changed to Screen 2 Done", maxSteps: 2))
                }
            }
        )

        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 2 // Would fail if counter didn't reset between subgoals!

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config
        )

        let summary = try await coordinator.execute(goal: "Multi-subgoal escalation reset")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
    }

    @Test("T3.5: Keyboard navigation action successfully replaces stagnant scroll and breaks stagnation")
    func testT3_05_KeyboardNavigationAfterStagnantScroll() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "feed", role: "AXScrollArea", label: "Feed", x: 0, y: 0, w: 400, h: 400)
        let s0 = makeSnapshot(title: "View 0", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "View 1", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s0, s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_scroll", description: "Scroll feed", expectedOutcome: "title changed to View 1", maxSteps: 2)
                ])
            },
            escalationHandler: { _, _, _, _ in
                // Adapt to keyboard navigation
                .replacePlan([
                    Subgoal(id: "sg_key", description: "press key Return", expectedOutcome: "title changed to View 1", maxSteps: 2)
                ])
            }
        )

        var config = AutonomousLoopConfig.testing
        config.identicalActionThreshold = 2

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: config,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Break stagnation with keypress")
        #expect(summary.isSuccess)
        #expect(synthesizer.recordedEvents.contains { if case .pressKey = $0 { return true }; return false })
    }

    // =========================================================================
    // MARK: - TIER 4: Real-World Application Scenarios (4 tests)
    // =========================================================================

    @Test("T4.1: Scenario 1 - Unkeyed feed scrolling workflow navigates to article and clicks cleanly")
    func testT4_01_UnkeyedFeedScrollingWorkflow() async throws {
        let engine = makeOfflineEngine()
        let scrollArea = makeCandidate(id: "social_feed", role: "AXScrollArea", label: "News Feed", x: 0, y: 0, w: 500, h: 600)
        let targetArticle = makeCandidate(id: "article_link", role: "AXButton", label: "Breaking Tech News", x: 50, y: 200, w: 300, h: 40)

        let s0 = makeSnapshot(title: "News Feed - Top", candidates: [scrollArea])
        let s1 = makeSnapshot(title: "News Feed - Article Visible", candidates: [scrollArea, targetArticle])
        let s2 = makeSnapshot(title: "Article Page Loaded", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_scroll", description: "Scroll feed down", expectedOutcome: "title changed to News Feed - Article Visible", maxSteps: 3)
        let sg2 = Subgoal(id: "sg_click", description: "Click Breaking Tech News", expectedOutcome: "title changed to Article Page Loaded", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Find and open Breaking Tech News")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
        #expect(synthesizer.recordedEvents.contains { if case .scroll = $0 { return true }; return false })
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("T4.2: Scenario 2 - Multi-field form entry with offline token matching and submit verification")
    func testT4_02_MultiFieldFormInputRecoveryWorkflow() async throws {
        let engine = makeOfflineEngine()
        let nameField = makeCandidate(id: "field_name", role: "AXTextField", label: "Full Name", x: 50, y: 50, w: 200, h: 30)
        let emailField = makeCandidate(id: "field_email", role: "AXTextField", label: "Email Address", x: 50, y: 100, w: 200, h: 30)
        let submitBtn = makeCandidate(id: "btn_submit", role: "AXButton", label: "Submit Registration", x: 50, y: 160, w: 120, h: 35)

        let s0 = makeSnapshot(title: "Registration Form", candidates: [nameField, emailField, submitBtn])
        let s1 = makeSnapshot(title: "Registration Form - Name Entered", candidates: [emailField, submitBtn])
        let s2 = makeSnapshot(title: "Registration Form - Ready to Submit", candidates: [submitBtn])
        let s3 = makeSnapshot(title: "Registration Success", candidates: [])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2, s3])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_name", description: "Type Alice into Full Name", expectedOutcome: "title changed to Registration Form - Name Entered", maxSteps: 2)
        let sg2 = Subgoal(id: "sg_email", description: "Type alice@test.com into Email Address", expectedOutcome: "title changed to Registration Form - Ready to Submit", maxSteps: 2)
        let sg3 = Subgoal(id: "sg_sub", description: "Click Submit Registration", expectedOutcome: "title changed to Registration Success", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2, sg3])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Complete registration form")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 3)
        #expect(synthesizer.recordedEvents.contains { if case .typeText = $0 { return true }; return false })
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("T4.3: Scenario 3 - Search stream exhaustion scrolls results and concludes upon reaching end")
    func testT4_03_SearchStreamExhaustionWorkflow() async throws {
        let engine = makeOfflineEngine()
        let searchInput = makeCandidate(id: "input_query", role: "AXTextField", label: "Search Products", x: 20, y: 20, w: 250, h: 30)
        let scrollArea = makeCandidate(id: "results_area", role: "AXScrollArea", label: "Product Feed", x: 20, y: 60, w: 600, h: 500)

        let s0 = makeSnapshot(title: "Store Home", candidates: [searchInput])
        let s1 = makeSnapshot(title: "Search Results - Top", candidates: [scrollArea])
        let s2 = makeSnapshot(title: "Search Results - End of Stream", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_search", description: "Type macbook into Search Products", expectedOutcome: "title changed to Search Results - Top", maxSteps: 2)
        let sg2 = Subgoal(id: "sg_scroll", description: "Scroll feed down", expectedOutcome: "title changed to Search Results - End of Stream", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing,
            keystrokeApprover: AutoApproveToolApprover()
        )

        let summary = try await coordinator.execute(goal: "Search macbook and scroll to end")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
    }

    @Test("T4.4: Scenario 4 - Settings navigation and dark mode toggle workflow")
    func testT4_04_SettingsNavigationAndToggleWorkflow() async throws {
        let engine = makeOfflineEngine()
        let settingsTab = makeCandidate(id: "tab_settings", role: "AXButton", label: "Settings", x: 10, y: 10, w: 80, h: 30)
        let scrollArea = makeCandidate(id: "settings_pane", role: "AXScrollArea", label: "Settings Pane", x: 100, y: 10, w: 500, h: 600)
        let darkModeSwitch = makeCandidate(id: "toggle_dark_mode", role: "AXCheckBox", label: "Dark Mode", x: 150, y: 300, w: 100, h: 25)

        let s0 = makeSnapshot(title: "App Overview", candidates: [settingsTab])
        let s1 = makeSnapshot(title: "Settings Pane", candidates: [scrollArea])
        let s2 = makeSnapshot(title: "Settings Pane - Switch Visible", candidates: [scrollArea, darkModeSwitch])
        let s3 = makeSnapshot(title: "Settings - Dark Mode Active", candidates: [scrollArea])
        let inspector = MockUIInspector(snapshots: [s0, s1, s2, s3])
        let synthesizer = MockEventSynthesizer()

        let sg1 = Subgoal(id: "sg_open", description: "Click Settings", expectedOutcome: "title changed to Settings Pane", maxSteps: 2)
        let sg2 = Subgoal(id: "sg_scroll", description: "Scroll feed down", expectedOutcome: "title changed to Settings Pane - Switch Visible", maxSteps: 2)
        let sg3 = Subgoal(id: "sg_toggle", description: "Click Dark Mode", expectedOutcome: "title changed to Settings - Dark Mode Active", maxSteps: 2)
        let planner = MockPlanningLLM.staticPlan(subgoals: [sg1, sg2, sg3])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Enable dark mode in settings")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 3)
    }
}
