import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Milestone 2 Challenger: Feedback Loop Wiring & Coordinate Fallback Empirical Stress Tests")
struct TwoTierAutonomousLoopMilestone2FeedbackCoordinateChallengerTests {

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

    // =========================================================================
    // SECTION 1: FEATURE 5 — FEEDBACK LOOP WIRING STRESS TESTS
    // =========================================================================

    @Test("Feature 5 Wiring: Repeated unchanged diffs cause local offline engine to adapt away from stagnant scroll")
    func testFeedbackLoopPassesHistoryAndLastDiffToFallbackEngine() async throws {
        // Feed container candidate
        let scrollArea = makeCandidate(id: "feed_scroll", role: "AXScrollArea", label: "Timeline Feed", x: 50, y: 50, w: 400, h: 500)
        let s0 = makeSnapshot(title: "Feed View", candidates: [scrollArea])

        // Mock inspector that returns s0 indefinitely (unchanging screen)
        let mockInspector = MockUIInspector(repeating: s0)
        let mockSynthesizer = MockEventSynthesizer()

        // Unconfigured engine will run offline fallbackLocalDecision which depends on lastDiff and history
        let engine = TypeSafeDecisionEngine()

        // Subgoal with empty expectedOutcome so boundary completion succeeds cleanly without escalation
        let subgoal = Subgoal(id: "sg_feed", description: "Scroll feed down", expectedOutcome: "", maxSteps: 5)
        let mockPlanner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: mockPlanner,
            decisionEngine: engine,
            synthesizer: mockSynthesizer,
            inspector: mockInspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Browse feed")
        #expect(summary.isSuccess)

        // Verify Step 1 executed .scroll
        let scrollEvents = mockSynthesizer.recordedEvents.filter { if case .scroll = $0 { return true }; return false }
        #expect(!scrollEvents.isEmpty, "Step 1 should execute initial scroll")

        // Verify Step 2 executed .pressKey("PageDown") due to lastDiff.isStateUnchanged == true
        let keyEvents = mockSynthesizer.recordedEvents.filter {
            if case .pressKey(let k) = $0 { return k == "PageDown" }
            return false
        }
        #expect(!keyEvents.isEmpty, "Step 2 should adapt to PageDown keyboard navigation when lastDiff is passed")
    }

    @Test("Feature 5 Upward Stagnation: Upward scroll goal adapts to PageUp keyboard navigation")
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

        let events = synthesizer.recordedEvents
        let pageUpEvents = events.filter {
            if case .pressKey(let k) = $0 { return k == "PageUp" }
            return false
        }
        #expect(!pageUpEvents.isEmpty, "Upward scroll stagnation must adapt to PageUp keyboard navigation")
    }

    @Test("Feature 5 Boundary Stagnation: Unfulfilled explicit expected outcome triggers actionStagnant escalation")
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
            escalationHandler: { reason, failedSubgoal, _, _ in
                holder.set(reason)
                // Return completeGoal to terminate cleanly
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
        let escReason = holder.reason
        #expect(escReason != nil, "Boundary conclusion with unfulfilled expected outcome must escalate")
        if case .actionStagnant = escReason {
            // Expected: actionStagnant
        } else {
            #expect(Bool(false), "Expected .actionStagnant escalation but got \(String(describing: escReason))")
        }
    }

    @Test("Feature 5 Subgoal Advance: Screen state change resets lastDiff and consecutive escalations")
    func testFeedbackLoopScreenStateChangeResetsConsecutiveEscalations() async throws {
        let btn1 = makeCandidate(id: "btn1", role: "AXButton", label: "Proceed 1", x: 10, y: 10)
        let btn2 = makeCandidate(id: "btn2", role: "AXButton", label: "Proceed 2", x: 10, y: 50)
        let s0 = makeSnapshot(title: "Step 0", candidates: [btn1])
        let s1 = makeSnapshot(title: "Step 1 Progress", candidates: [btn2])
        let s2 = makeSnapshot(title: "Step 2 Final", candidates: [btn2])

        let inspector = MockUIInspector(snapshots: [s0, s0, s1, s1, s2])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1_bad", description: "Bad Step 1", expectedOutcome: "title changed to Step 1 Progress", maxSteps: 2),
                    Subgoal(id: "sg_2_bad", description: "Bad Step 2", expectedOutcome: "title changed to Step 2 Final", maxSteps: 2)
                ])
            },
            escalationHandler: { reason, failedSubgoal, _, _ in
                if failedSubgoal.id == "sg_1_bad" {
                    return .retrySubgoal(Subgoal(id: "sg_1_ok", description: "Click Proceed 1", expectedOutcome: "title changed to Step 1 Progress", maxSteps: 2))
                } else {
                    return .retrySubgoal(Subgoal(id: "sg_2_ok", description: "Click Proceed 2", expectedOutcome: "title changed to Step 2 Final", maxSteps: 2))
                }
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

        let summary = try await coordinator.execute(goal: "Test progress resets consecutive escalations")
        #expect(summary.isSuccess)
        #expect(summary.completedSubgoals == 2)
    }

    // =========================================================================
    // SECTION 2: FEATURE 7 — COORDINATOR COORDINATE FALLBACK STRESS TESTS
    // =========================================================================

    @Test("Feature 7: Empty candidates list resolves valid non-nil point for scroll action",
          arguments: [CGRect(x: 40, y: 80, width: 600, height: 400),
                      CGRect(x: 100, y: 120, width: 1000, height: 600)])
    func testFeature7_EmptyCandidatesList_ScrollResolvesValidNonNilPoint(viewport: CGRect) async throws {
        try await TypeSafeDecisionEngine.$fallbackScrollViewport.withValue(viewport) {
            // 1. Direct evaluation with empty candidates list
            let emptyPoint = TypeSafeDecisionEngine.resolveFallbackScrollCoordinates(candidates: [])
            #expect(emptyPoint == CGPoint(x: viewport.midX, y: viewport.midY))
            #expect(!emptyPoint.x.isNaN && !emptyPoint.y.isNaN, "Coordinates must not be NaN")
            #expect(emptyPoint.x.isFinite && emptyPoint.y.isFinite, "Coordinates must be finite")
            #expect(emptyPoint.x > 0 && emptyPoint.y > 0, "Coordinates must be positive viewport coordinate")

            // 2. Coordinator execution: Candidate with degenerate bounds so validBounds is empty,
            // exercising the empty candidate fallback path inside executeSyntheticAction.
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

            // Decision with action .scroll, but all coordinates are nil and targetElementId is nil
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
            #expect(!scrollEvents.isEmpty, "Scroll event must be recorded")
            for pt in scrollEvents {
                #expect(!pt.x.isNaN && !pt.y.isNaN, "Coordinates must not be NaN")
                #expect(pt.x.isFinite && pt.y.isFinite, "Coordinates must be finite")
                #expect(pt.x > 0 && pt.y > 0, "Coordinates must be positive viewport coordinate")
                #expect(pt == emptyPoint, "Degenerate candidates must fall back to the exact same point as empty candidates")
            }
        }
        #expect(TypeSafeDecisionEngine.fallbackScrollViewport == nil)
    }

    @Test("Feature 7: Missing container roles resolves candidate bounding box centroid")
    func testFeature7_MissingContainerRoles_ScrollResolvesCandidateCentroid() async throws {
        // Only buttons and static text, NO AXScrollArea or container roles
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
        #expect(!scrollEvents.isEmpty)
        let pt = scrollEvents[0]
        #expect(!pt.x.isNaN && !pt.y.isNaN)
        #expect(pt.x.isFinite && pt.y.isFinite)

        // Expected centroid of union of bounds:
        // btn1: minX: 100, minY: 100, maxX: 200, maxY: 150
        // btn2: minX: 500, minY: 700, maxX: 600, maxY: 750
        // Union: minX: 100, minY: 100, maxX: 600, maxY: 750
        // Centroid: (100 + 500/2, 100 + 650/2) = (350, 425)
        #expect(pt.x == 350 && pt.y == 425, "Must match bounding box union centroid: got (\(pt.x), \(pt.y))")
    }

    @Test("Feature 7: Offscreen candidate coordinates resolve finite non-nil point without crashing")
    func testFeature7_OffscreenCandidateCoordinates_ScrollResolvesFiniteNonNilPoint() async throws {
        // Candidates located in offscreen negative coordinate space
        let offscreen1 = makeCandidate(id: "off1", role: "AXButton", label: "Hidden 1", x: -2000, y: -2000, w: 200, h: 200)
        let offscreen2 = makeCandidate(id: "off2", role: "AXButton", label: "Hidden 2", x: -1000, y: -1000, w: 200, h: 200)
        let s0 = makeSnapshot(title: "Offscreen View", candidates: [offscreen1, offscreen2])
        let sDone = makeSnapshot(title: "Offscreen View - Done", candidates: [offscreen1, offscreen2])

        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_offscreen", description: "scroll offscreen", expectedOutcome: "title changed to Offscreen View - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test offscreen coordinates scroll")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        let pt = scrollEvents[0]
        #expect(!pt.x.isNaN && !pt.y.isNaN)
        #expect(pt.x.isFinite && pt.y.isFinite, "Point must be finite")
    }

    @Test("Feature 7: TargetElementId matching resolves candidate center when targetCenter is nil")
    func testFeature7_TargetElementIdMatchingResolvesCandidateCenter() async throws {
        let otherCand = makeCandidate(id: "other", role: "AXButton", label: "Other", x: 10, y: 10, w: 50, h: 20)
        let targetBox = makeCandidate(id: "specific_box", role: "AXGroup", label: "Custom Box", x: 300, y: 400, w: 200, h: 100)
        let s0 = makeSnapshot(title: "Custom View", candidates: [otherCand, targetBox])
        let sDone = makeSnapshot(title: "Custom View - Done", candidates: [otherCand, targetBox])

        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        // Decision with targetElementId set, but targetCenter and coordinates are nil
        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "specific_box", action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_specific", description: "scroll specific", expectedOutcome: "title changed to Custom View - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test targetId matching")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        let pt = scrollEvents[0]
        #expect(pt == targetBox.center, "Must resolve to matched candidate center: expected \(targetBox.center), got \(pt)")
    }

    @Test("Feature 7: Scroll container candidate takes priority over buttons when targetCenter and targetId are nil")
    func testFeature7_ScrollContainerCandidateTakesPriorityOverButtons() async throws {
        let button = makeCandidate(id: "btn", role: "AXButton", label: "Submit", x: 50, y: 50, w: 100, h: 30)
        let scrollArea = makeCandidate(id: "container", role: "AXScrollArea", label: "Main Scroll Area", x: 200, y: 150, w: 500, h: 400)
        let s0 = makeSnapshot(title: "Page View", candidates: [button, scrollArea])
        let sDone = makeSnapshot(title: "Page View - Done", candidates: [button, scrollArea])

        let inspector = MockUIInspector(snapshots: [s0, sDone])
        let synthesizer = MockEventSynthesizer()

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "scroll", confidence: 0.90, text: nil as String?, isCompleted: 0.0),
            (target: nil as String?, action: "none", confidence: 0.90, text: nil as String?, isCompleted: 1.0)
        ])
        let engine = TypeSafeDecisionEngine(client: evaluator)

        let subgoal = Subgoal(id: "sg_container_priority", description: "scroll content", expectedOutcome: "title changed to Page View - Done", maxSteps: 3)
        let planner = MockPlanningLLM.staticPlan(subgoals: [subgoal])

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test container priority")
        #expect(summary.isSuccess)

        let scrollEvents = synthesizer.recordedEvents.compactMap { event -> CGPoint? in
            if case .scroll(_, _, let point, _) = event { return point }
            return nil
        }
        #expect(!scrollEvents.isEmpty)
        let pt = scrollEvents[0]
        #expect(pt == scrollArea.center, "Must prioritize AXScrollArea center: expected \(scrollArea.center), got \(pt)")
    }

    @Test("Feature 7: Degenerate or non-finite candidate bounds fall back safely to valid screen coordinate")
    func testFeature7_DegenerateCandidateBounds_ScrollFallsBackSafely() async throws {
        // Candidates with 0 width, 0 height, NaN bounds
        let zeroCandidate = UIElementCandidate(id: "zero", role: "AXButton", label: "Zero", bounds: CGRect(x: 100, y: 100, width: 0, height: 0))
        let negativeSizeCandidate = UIElementCandidate(id: "neg", role: "AXButton", label: "Neg", bounds: CGRect(x: 100, y: 100, width: -50, height: -50))
        let nanCandidate = UIElementCandidate(id: "nan", role: "AXButton", label: "NaN", bounds: CGRect(x: Double.nan, y: Double.nan, width: 100, height: 100))

        let s0 = makeSnapshot(title: "Degenerate View", candidates: [zeroCandidate, negativeSizeCandidate, nanCandidate])
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
        #expect(!pt.x.isNaN && !pt.y.isNaN)
        #expect(pt.x.isFinite && pt.y.isFinite)
        #expect(pt.x > 0 && pt.y > 0)
    }
}
