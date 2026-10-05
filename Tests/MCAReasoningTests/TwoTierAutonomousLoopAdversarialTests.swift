import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("TwoTierAutonomousLoopCoordinator Adversarial Tests")
struct TwoTierAutonomousLoopAdversarialTests {

    private func makeCandidate(
        id: String,
        role: String = "AXButton",
        label: String = "Test Button",
        x: Double = 100,
        y: Double = 100,
        w: Double = 80,
        h: Double = 30
    ) -> UIElementCandidate {
        UIElementCandidate(
            id: id,
            role: role,
            label: label,
            bounds: CGRect(x: x, y: y, width: w, height: h)
        )
    }

    private func makeSnapshot(
        title: String = "Test Window",
        candidates: [UIElementCandidate],
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

    // MARK: - 1. Escalation Cascades & Loop Limits

    @Test("Escalation Cascade: empty candidates repeatedly escalating reaches maxConsecutiveEscalations and halts with .escalationFailed")
    func testEscalationCascadeLimitOnEmptyCandidates() async throws {
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Empty search", expectedOutcome: "Found", maxSteps: 5)
                ])
            },
            escalationHandler: { _, subgoal, _, _ in
                // System 2 repeatedly tries to retry the subgoal
                .retrySubgoal(subgoal)
            }
        )

        let inspector = MockUIInspector(repeating: makeSnapshot(title: "Empty Window", candidates: []))
        let synthesizer = MockEventSynthesizer()
        let config = AutonomousLoopConfig(
            maxTotalSteps: 20,
            settlingDelayMs: 0,
            maxConsecutiveEscalations: 3
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(confidenceThreshold: 0.80),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Search with empty screen")
            #expect(Bool(false), "Coordinator should have failed due to exceeding escalation limit")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Exceeded maximum consecutive escalations"), "Error reason should mention escalation limit: \(reason)")
            } else {
                #expect(Bool(false), "Expected LoopExecutionError.escalationFailed, but got \(error)")
            }
        }

        let escalations = await planner.recordedEscalations
        // When maxConsecutiveEscalations is 3, count reaches 3 on the 3rd attempt and checkEscalationLimit aborts before the 3rd replan call.
        #expect(escalations.count == 2, "Recorded 2 replan calls before 3rd attempt aborted at limit, recorded: \(escalations.count)")
    }

    struct CustomReplanError: Error, LocalizedError {
        var errorDescription: String? { "System 2 LLM server crashed" }
    }

    @Test("Escalation Cascade: replan throwing an error produces LoopExecutionError.escalationFailed")
    func testReplanThrowingErrorHandling() async throws {
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Search", expectedOutcome: "Done", maxSteps: 5)
                ])
            },
            escalationHandler: { _, _, _, _ in
                throw CustomReplanError()
            }
        )

        let inspector = MockUIInspector(repeating: makeSnapshot(title: "Empty Window", candidates: []))
        let synthesizer = MockEventSynthesizer()
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(confidenceThreshold: 0.80),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Trigger throwing replan")
            #expect(Bool(false), "Should have thrown an error")
        } catch let error as LoopExecutionError {
            switch error {
            case .escalationFailed(let reason):
                #expect(reason.contains("System 2 LLM server crashed"))
            case .executionFailed:
                #expect(Bool(false), "Coordinator should produce .escalationFailed on replan throw, got .executionFailed")
            default:
                #expect(Bool(false), "Unexpected error type: \(error)")
            }
        }
    }

    @Test("Escalation Cascade: replan returning .replacePlan with empty list terminates without crash")
    func testReplanReturningEmptyPlan() async throws {
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "First subgoal", expectedOutcome: "Done", maxSteps: 5)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .replacePlan([])
            }
        )

        let inspector = MockUIInspector(repeating: makeSnapshot(title: "Empty Window", candidates: []))
        let synthesizer = MockEventSynthesizer()
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(confidenceThreshold: 0.80),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: AutonomousLoopConfig(settlingDelayMs: 0, maxConsecutiveEscalations: 2)
        )

        do {
            _ = try await coordinator.execute(goal: "Replace with empty plan")
        } catch let error as LoopExecutionError {
            if case .escalationFailed = error {
                #expect(Bool(true))
            }
        }
    }

    // MARK: - 2. Confidence Threshold Boundaries (0.7999 vs 0.8000 vs 0.8001)

    @Test("Confidence Boundary: 0.7999 escalates to System 2")
    func testConfidence07999Escalates() async throws {
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let snapshot = makeSnapshot(title: "Boundary Window", candidates: [candidate])
        let inspector = MockUIInspector(repeating: snapshot)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Click OK", expectedOutcome: "OK clicked", maxSteps: 5)
                ])
            },
            escalationHandler: { reason, _, _, _ in
                if case .lowConfidence(let conf, let thresh) = reason {
                    #expect(conf < 0.80, "Confidence should be < 0.80: \(conf)")
                    #expect(thresh == 0.80, "Threshold should be 0.80: \(thresh)")
                } else {
                    #expect(Bool(false), "Expected lowConfidence escalation, got \(reason)")
                }
                return .abort(reason: "Escalated on 0.7999")
            }
        )

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.7999, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Boundary test 0.7999")
            #expect(Bool(false), "Expected escalation abort")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                #expect(Bool(false), "Expected .escalationFailed, got \(error)")
                return
            }
            #expect(reason.contains("Escalated on 0.7999"))
        }

        let escalations = await planner.recordedEscalations
        #expect(escalations.count == 1, "Should have escalated exactly once")
        let actions = synthesizer.recordedEvents.filter { $0 != .releaseAllHeldEvents }
        #expect(actions.isEmpty, "No synthetic actions should have been executed")
    }

    @Test("Confidence Boundary: 0.8000 proceeds without escalation")
    func testConfidence08000Proceeds() async throws {
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let s0 = makeSnapshot(title: "Window", candidates: [candidate])
        let s1 = makeSnapshot(title: "New Window Title", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click OK", expectedOutcome: "window title changed", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.8000, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Boundary test 0.8000")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)

        let escalations = await planner.recordedEscalations
        #expect(escalations.isEmpty, "Confidence 0.8000 must NOT escalate")
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false }, "Click event must be synthesized")
    }

    @Test("Confidence Boundary: 0.8001 proceeds without escalation")
    func testConfidence08001Proceeds() async throws {
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let s0 = makeSnapshot(title: "Window", candidates: [candidate])
        let s1 = makeSnapshot(title: "New Window Title", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click OK", expectedOutcome: "window title changed", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.8001, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Boundary test 0.8001")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)

        let escalations = await planner.recordedEscalations
        #expect(escalations.isEmpty, "Confidence 0.8001 must NOT escalate")
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("Confidence Config Mismatch: coordinator config threshold vs TypeSafeDecisionEngine threshold")
    func testConfidenceConfigMismatchBehavior() async throws {
        // When AutonomousLoopConfig has confidenceThreshold: 0.90, but TypeSafeDecisionEngine has threshold: 0.80
        // A decision with confidence 0.85 will NOT escalate because coordinator delegates to decisionEngine.shouldEscalate
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let s0 = makeSnapshot(title: "Window", candidates: [candidate])
        let s1 = makeSnapshot(title: "New Window Title", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click OK", expectedOutcome: "window title changed", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_ok", targetConfidence: 0.85, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80) // 0.80

        let config = AutonomousLoopConfig(confidenceThreshold: 0.90, settlingDelayMs: 0) // 0.90 configured

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        do {
            _ = try await coordinator.execute(goal: "Config mismatch test")
            #expect(Bool(false), "Expected escalation abort when confidence 0.85 < config threshold 0.90")
        } catch let error as LoopExecutionError {
            if case .escalationFailed(let reason) = error {
                #expect(reason.contains("Static abort"))
            } else {
                #expect(Bool(false), "Expected .escalationFailed, got \(error)")
            }
        }
        let escalations = await planner.recordedEscalations
        #expect(escalations.count == 1, "Coordinator config threshold (0.90) correctly triggered escalation for confidence 0.85")
        if case .lowConfidence(let conf, let thresh) = escalations.first?.reason {
            #expect(conf == 0.85)
            #expect(thresh == 0.90)
        }
    }

    // MARK: - 3. Action .none with isCompleted = false vs true

    @Test("Decision with .none action and isCompleted = false MUST trigger escalation")
    func testActionNoneWithCompletedFalseEscalates() async throws {
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let snapshot = makeSnapshot(title: "Window", candidates: [candidate])
        let inspector = MockUIInspector(repeating: snapshot)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Do task", expectedOutcome: "Done", maxSteps: 5)
                ])
            },
            escalationHandler: { _, _, _, _ in
                .abort(reason: "Escalated on .none action")
            }
        )

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: nil, targetConfidence: 0.95, actionChoice: "none")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Test action none with completed false")
            #expect(Bool(false), "Must escalate and abort on .none action with isCompleted = false")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                #expect(Bool(false), "Expected .escalationFailed, got \(error)")
                return
            }
            #expect(reason.contains("Escalated on .none action"))
        }

        let escalations = await planner.recordedEscalations
        #expect(escalations.count == 1, "Must escalate to System 2")
        let actions = synthesizer.recordedEvents.filter { $0 != .releaseAllHeldEvents }
        #expect(actions.isEmpty, "No synthetic actions executed")
    }

    @Test("Decision with .none action and isCompleted = true completes successfully without escalation")
    func testActionNoneWithCompletedTrueCompletes() async throws {
        let candidate = makeCandidate(id: "btn_ok", label: "OK")
        let snapshot = makeSnapshot(title: "Window", candidates: [candidate])
        let inspector = MockUIInspector(repeating: snapshot)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Goal already met", expectedOutcome: "Done", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: nil as String?, action: "none", confidence: 0.95, text: nil as String?, isCompleted: 0.85)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Goal already met")
        #expect(summary.isSuccess)
        // Step budget increments on step start before evaluating decision.isCompleted
        #expect(summary.totalSteps == 1)
        #expect(summary.stepRecords.isEmpty, "No synthetic step records created when completed immediately")
        #expect(summary.subgoalsCompleted == 1)

        let escalations = await planner.recordedEscalations
        #expect(escalations.isEmpty, "Must NOT escalate when isCompleted = true")
        let actions = synthesizer.recordedEvents.filter { $0 != .releaseAllHeldEvents }
        #expect(actions.isEmpty)
    }

    // MARK: - 4. Empty / Corrupted UI Snapshots

    @Test("Empty Candidates: immediately escalates to System 2 without invoking Jev or synthesizer")
    func testEmptyCandidatesImmediateEscalation() async throws {
        let emptySnapshot = makeSnapshot(title: "Empty Workspace", candidates: [])
        let inspector = MockUIInspector(repeating: emptySnapshot)
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [
                    Subgoal(id: "sg_1", description: "Click missing button", expectedOutcome: "Done", maxSteps: 5)
                ])
            },
            escalationHandler: { reason, _, _, _ in
                return .abort(reason: "No candidates on screen")
            }
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        do {
            _ = try await coordinator.execute(goal: "Click missing button")
            #expect(Bool(false), "Should abort on empty candidates")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                #expect(Bool(false), "Expected .escalationFailed, got \(error)")
                return
            }
            #expect(reason.contains("No candidates on screen"))
        }

        let escalations = await planner.recordedEscalations
        #expect(escalations.first?.reason == .emptyCandidates, "Escalation reason must be .emptyCandidates")
        let actions = synthesizer.recordedEvents.filter { $0 != .releaseAllHeldEvents }
        #expect(actions.isEmpty, "Synthesizer must not execute any actions")
    }

    @Test("Corrupted Snapshot: duplicate candidate IDs handled without crash")
    func testDuplicateCandidateIDsHandledGracefully() async throws {
        var dupes: [UIElementCandidate] = []
        for i in 0..<20 {
            let lbl = "Option \(i)"
            let cand = makeCandidate(
                id: "duplicate_btn",
                role: "AXButton",
                label: lbl,
                x: Double(50 + i * 20),
                y: Double(100 + i * 10)
            )
            dupes.append(cand)
        }
        let s0 = makeSnapshot(title: "Dup Window", candidates: dupes)
        let s1 = makeSnapshot(title: "New Window Title", candidates: dupes)

        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Select duplicate", expectedOutcome: "window title changed", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "duplicate_btn", targetConfidence: 0.85, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Handle duplicates")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)
        #expect(synthesizer.recordedEvents.contains { if case .click = $0 { return true }; return false })
    }

    @Test("Corrupted Snapshot: extreme and zero-sized bounds handled without crash")
    func testExtremeBoundsHandledGracefully() async throws {
        let validCandidate = makeCandidate(id: "btn_valid", label: "Valid Button", x: 100, y: 100)
        let zeroCandidate = UIElementCandidate(
            id: "btn_zero",
            role: "AXButton",
            label: "Zero Button",
            bounds: CGRect(x: -9999, y: -9999, width: 0, height: 0)
        )
        let hugeCandidate = UIElementCandidate(
            id: "btn_huge",
            role: "AXButton",
            label: "Huge Button",
            bounds: CGRect(x: 0, y: 0, width: 999999, height: 999999)
        )

        let s0 = makeSnapshot(title: "Corrupt Window", candidates: [zeroCandidate, hugeCandidate, validCandidate])
        let s1 = makeSnapshot(title: "New Window Title", candidates: [zeroCandidate, hugeCandidate, validCandidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click valid button", expectedOutcome: "window title changed", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_valid", targetConfidence: 0.90, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing
        )

        let summary = try await coordinator.execute(goal: "Test extreme coordinates")
        #expect(summary.isSuccess)
        #expect(summary.totalSteps == 1)
    }

    // MARK: - 5. Lifecycle & Emergency Cleanup

    struct HardwareSynthesisError: Error, LocalizedError {
        var errorDescription: String? { "CoreGraphics window server connection dropped" }
    }

    @Test("Lifecycle: synthesizer error during action dispatch triggers releaseAllHeldEvents and records executionFailed")
    func testSynthesizerFailureTriggersReleaseAllHeldEvents() async throws {
        let candidate = makeCandidate(id: "btn_fail", label: "Fail Button")
        let snapshot = makeSnapshot(title: "Fail Window", candidates: [candidate])
        let inspector = MockUIInspector(repeating: snapshot)

        let synthesizer = MockEventSynthesizer(injectedError: HardwareSynthesisError())
        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Click failing button", expectedOutcome: "Done", maxSteps: 5)
        ])

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_fail", targetConfidence: 0.90, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        final class FailureDelegate: AutonomousLoopDelegate, @unchecked Sendable {
            var failedError: LoopExecutionError?
            func loopDidFail(error: LoopExecutionError) async {
                failedError = error
            }
        }
        let delegate = FailureDelegate()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing,
            delegate: delegate
        )

        do {
            _ = try await coordinator.execute(goal: "Trigger synthesizer error")
            #expect(Bool(false), "Must fail when synthesizer throws")
        } catch let error as LoopExecutionError {
            guard case .executionFailed(let reason) = error else {
                #expect(Bool(false), "Expected .executionFailed, got \(error)")
                return
            }
            #expect(reason.contains("CoreGraphics window server connection dropped"))
        }

        let events = synthesizer.recordedEvents
        #expect(events.contains(.releaseAllHeldEvents), "Must invoke releaseAllHeldEvents upon synthesis failure")
        #expect(delegate.failedError != nil, "Delegate must be notified of failure")
    }

    @Test("Lifecycle: delegate loopDidEscalate throwing error releases held events and fails gracefully")
    func testDelegateEscalationThrowingError() async throws {
        let emptySnapshot = makeSnapshot(title: "Empty Window", candidates: [])
        let inspector = MockUIInspector(repeating: emptySnapshot)
        let synthesizer = MockEventSynthesizer()
        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(id: "sg_1", description: "Task", expectedOutcome: "Done", maxSteps: 5)
        ])

        struct DelegateEscalationError: Error, LocalizedError {
            var errorDescription: String? { "Delegate rejected escalation" }
        }

        final class ThrowingDelegate: AutonomousLoopDelegate, @unchecked Sendable {
            var failedError: LoopExecutionError?
            func loopDidEscalate(reason: EscalationReason, subgoal: Subgoal) async throws -> EscalationResolution? {
                throw DelegateEscalationError()
            }
            func loopDidFail(error: LoopExecutionError) async {
                failedError = error
            }
        }
        let delegate = ThrowingDelegate()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: TypeSafeDecisionEngine(),
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing,
            delegate: delegate
        )

        do {
            _ = try await coordinator.execute(goal: "Delegate throw test")
            #expect(Bool(false), "Must fail when delegate throws")
        } catch let error as LoopExecutionError {
            guard case .executionFailed(let reason) = error else {
                #expect(Bool(false), "Expected .executionFailed, got \(error)")
                return
            }
            #expect(reason.contains("Delegate rejected escalation"))
        }

        #expect(synthesizer.recordedEvents.contains(.releaseAllHeldEvents), "Must release held events when delegate throws")
        #expect(delegate.failedError != nil, "Delegate must be notified of failure via loopDidFail")
    }

    // MARK: - 6. Adversarial Deep Invariants: Infinite Loops & Subgoal Replan Replacement

    @Test("Adversarial: Subgoal step budget exhaustion repeated replan retry loop")
    func testSubgoalBudgetExhaustionInfiniteReplanGuard() async throws {
        // Subgoal maxSteps is 2. Subgoal outcome is unverified.
        // When step budget is exhausted, replan returns .retrySubgoal.
        // Demonstrates that the coordinator enters an infinite loop of replan calls
        // because consecutiveEscalations is not incremented and stepBudget is not reset.
        let candidate = makeCandidate(id: "btn_stay", label: "Stay")
        let s0 = makeSnapshot(title: "Same Window", candidates: [candidate])
        let inspector = MockUIInspector(repeating: s0)
        let synthesizer = MockEventSynthesizer()

        let subgoal = Subgoal(id: "sg_budget", description: "Try button", expectedOutcome: "Never happens", maxSteps: 2)
        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [subgoal])
            },
            escalationHandler: { reason, currentSubgoal, _, _ in
                return .retrySubgoal(Subgoal(
                    id: "\(currentSubgoal.id)_revised",
                    description: "Revised try",
                    expectedOutcome: "Still never happens",
                    maxSteps: 2
                ))
            }
        )

        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "btn_stay", targetConfidence: 0.90, actionChoice: "click")
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        let config = AutonomousLoopConfig(
            maxTotalSteps: 10,
            defaultSubgoalMaxSteps: 2,
            settlingDelayMs: 0,
            maxConsecutiveEscalations: 3,
            identicalActionThreshold: 10,
            unchangedStateThreshold: 10
        )

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: config
        )

        // Watchdog cancellation token to prevent hanging forever
        let token = CancellationToken()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s watchdog
            token.cancel()
        }

        do {
            _ = try await coordinator.execute(goal: "Test budget replan loop", cancellationToken: token)
            #expect(Bool(false), "Should have terminated with error")
        } catch let error as LoopExecutionError {
            let escalations = await planner.recordedEscalations
            switch error {
            case .escalationFailed(let reason):
                #expect(reason.contains("Exceeded maximum consecutive escalations"))
                #expect(escalations.count == 2, "Halted at maxConsecutiveEscalations without infinite replanning")
            default:
                #expect(Bool(false), "Expected .escalationFailed, got \(error)")
            }
        }
    }

    @Test("Adversarial: replacePlan updates active subgoal in coordinator")
    func testReplacePlanSubgoalUpdate() async throws {
        // Subgoal 1 fails on low confidence, replan replaces it with Subgoal 2
        let candidate = makeCandidate(id: "btn_special", label: "Special Button")
        let s0 = makeSnapshot(title: "Window", candidates: [candidate])
        let s1 = makeSnapshot(title: "New Window Title", candidates: [candidate])
        let inspector = MockUIInspector(snapshots: [s0, s1])
        let synthesizer = MockEventSynthesizer()

        let initialSubgoal = Subgoal(id: "sg_initial", description: "Initial goal", expectedOutcome: "never", maxSteps: 5)
        let revisedSubgoal = Subgoal(id: "sg_revised", description: "Revised goal", expectedOutcome: "window title changed", maxSteps: 5)

        let planner = MockPlanningLLM(
            planProvider: { goal, _ in
                SubgoalPlan(goal: goal, subgoals: [initialSubgoal])
            },
            escalationHandler: { reason, _, _, _ in
                .replacePlan([revisedSubgoal])
            }
        )

        let evaluator = MockTypeSafeEvaluator.stepSequence([
            (target: "btn_special", action: "click", confidence: 0.50, text: nil as String?, isCompleted: 0.0),
            (target: "btn_special", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "btn_special", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0),
            (target: "btn_special", action: "click", confidence: 0.95, text: nil as String?, isCompleted: 0.0)
        ])
        let decisionEngine = TypeSafeDecisionEngine(client: evaluator, confidenceThreshold: 0.80)

        final class StepTrackingDelegate: AutonomousLoopDelegate, @unchecked Sendable {
            var subgoalsObserved: [Subgoal] = []
            func loopDidStep(step: Int, subgoal: Subgoal, action: ComputerActionDecision, diff: UIStateDiff) async {
                subgoalsObserved.append(subgoal)
            }
        }
        let delegate = StepTrackingDelegate()

        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: planner,
            decisionEngine: decisionEngine,
            synthesizer: synthesizer,
            snapshotProvider: inspector,
            config: .testing,
            delegate: delegate
        )

        do {
            _ = try await coordinator.execute(goal: "Replace plan test")
        } catch {
            // Document behavior
        }

        // Verify delegate observed the revised subgoal
        if let observed = delegate.subgoalsObserved.first {
            #expect(observed.id == "sg_revised",
                    "Coordinator correctly executed micro-action with revised subgoal 'sg_revised'")
        } else {
            #expect(Bool(false), "Expected delegate to observe step with revised subgoal")
        }
    }
}
