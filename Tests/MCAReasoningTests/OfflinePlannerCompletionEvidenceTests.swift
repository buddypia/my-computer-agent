import MCACore
@testable import MCAReasoning
import Testing

@Suite("Offline planner preserves unverified outcomes")
struct OfflinePlannerCompletionEvidenceTests {
    @Test("Retry exhaustion and inert boundaries cannot prove an outcome", arguments: [
        "missing_candidates", "low_confidence", "boundary", "stagnant_limit",
    ])
    func unverifiedRecovery(_ scenario: String) async throws {
        let id: String
        let reason: EscalationReason
        switch scenario {
        case "missing_candidates":
            id = "receipt_retry_2"
            reason = .noCandidates
        case "low_confidence":
            id = "receipt_retry_conf_2"
            reason = .lowConfidence(confidence: 0.3, threshold: 0.8)
        case "boundary":
            id = "receipt_alt"
            reason = .actionStagnant(reason: "Page boundary reached or target inert")
        default:
            id = "receipt_alt_2"
            reason = .actionStagnant(reason: "Repeating unchanged state")
        }
        let planner = DefaultSubgoalPlanner()
        let resolution = try await planner.replan(goal: "Find receipt",
            failedSubgoal: Subgoal(id: id, description: "Find receipt", expectedOutcome: "Receipt visible", maxSteps: 4),
            reason: reason, currentSnapshot: UIStateSnapshot(visibleCandidates: []), history: [])
        guard case .abort(let message) = resolution else {
            Issue.record("Unobserved receipt became a completed goal: \(resolution)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("A larger escalation budget still halts an unobserved goal without dispatch")
    func executionBoundary() async throws {
        let inspector = MockUIInspector(repeating: UIStateSnapshot(visibleCandidates: []))
        let synthesizer = MockEventSynthesizer(isSimulation: false)
        var config = AutonomousLoopConfig.testing
        config.maxConsecutiveEscalations = 5
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: DefaultSubgoalPlanner(), decisionEngine: TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: "")),
            synthesizer: synthesizer, snapshotProvider: inspector, config: config)
        do {
            _ = try await coordinator.execute(goal: "Find receipt")
            Issue.record("An unobserved receipt was reported as successful")
        } catch let error as LoopExecutionError {
            guard case .escalationFailed(let reason) = error else {
                Issue.record("Unexpected failure: \(error)")
                return
            }
            #expect(reason.contains("UI elements"))
        }
        #expect(!synthesizer.recordedEvents.contains { event in
            if case .releaseAllHeldEvents = event { return false }
            return true
        })
        #expect(await inspector.capturedCount <= 10)
    }
}
