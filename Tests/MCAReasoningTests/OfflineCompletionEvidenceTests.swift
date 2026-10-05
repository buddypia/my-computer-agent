import CoreGraphics
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Offline completion requires observation evidence")
struct OfflineCompletionEvidenceTests {
    @Test("Completion words in requested button labels still require the click", arguments: [
        "Done", "Finished", "Completed", "Success", "完了", "達成", "終了",
    ])
    func completionLabel(_ label: String) async throws {
        let candidate = UIElementCandidate(id: "button", role: "AXButton", label: label,
            bounds: CGRect(x: 40, y: 80, width: 180, height: 30))
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: "Click '\(label)'.", candidates: [candidate])
        #expect(!decision.isCompleted)
        #expect(decision.action == .click)
        #expect(decision.targetElementId == candidate.id)
        #expect(decision.coordinates == candidate.center)
    }

    @Test("Low-confidence history cannot establish completion with no screen candidates", arguments: [2, 3])
    func emptyObservation(_ attempts: Int) async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: "Click phantom", candidates: [],
            recentEscalations: escalations(attempts))
        #expect(!decision.isCompleted)
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Low-confidence history cannot establish completion of an unmatched target")
    func unmatchedObservation() async throws {
        let candidate = UIElementCandidate(id: "help", role: "AXButton", label: "Help Documentation",
            bounds: CGRect(x: 40, y: 80, width: 180, height: 30))
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: "Click secret spaceship launch button",
            candidates: [candidate], recentEscalations: escalations(2))
        #expect(!decision.isCompleted)
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Autonomous execution cannot skip a Done button and report success without authorization")
    func executionBoundary() async throws {
        let candidate = UIElementCandidate(id: "done", role: "AXButton", label: "Done",
            bounds: CGRect(x: 40, y: 80, width: 180, height: 30))
        let inspector = MockUIInspector(repeating: UIStateSnapshot(windowTitle: "Owned fixture",
            visibleCandidates: [candidate]))
        let synthesizer = MockEventSynthesizer(isSimulation: false)
        let coordinator = TwoTierAutonomousLoopCoordinator(
            decisionEngine: TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: "")),
            synthesizer: synthesizer, snapshotProvider: inspector)
        do {
            _ = try await coordinator.execute(goal: "Click Done")
            Issue.record("Unapproved Done click was reported as a completed goal")
        } catch {
            #expect(error.localizedDescription.contains("approval_required"))
        }
        #expect(!synthesizer.recordedEvents.contains { event in
            if case .releaseAllHeldEvents = event { return false }
            return true
        })
    }

    @Test("Observed model completion remains available")
    func modelCompletion() async throws {
        let evaluator = MockTypeSafeEvaluator.scripted(isCompletedProbability: 0.95)
        let engine = TypeSafeDecisionEngine(client: evaluator)
        let candidate = UIElementCandidate(id: "status", role: "AXStaticText", label: "Receipt delivered",
            bounds: CGRect(x: 40, y: 80, width: 180, height: 30), isActionable: false)
        let decision = try await engine.decideNextAction(goal: "Deliver receipt", candidates: [candidate])
        #expect(decision.isCompleted)
        #expect(decision.action == .none)
        #expect(!engine.shouldEscalate(decision: decision))
    }

    private func escalations(_ attempts: Int) -> [EscalationRecord] {
        (1...attempts).map { EscalationRecord(attempt: $0, reason: .lowConfidence(confidence: 0.3, threshold: 0.8)) }
    }
}
