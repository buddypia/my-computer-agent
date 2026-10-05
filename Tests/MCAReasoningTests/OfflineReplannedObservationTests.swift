import CoreGraphics
import MCACore
import Testing

@testable import MCAReasoning

@Suite("Replanned offline observation intent")
struct OfflineReplannedObservationTests {
    @Test("Planner wrappers cannot turn verification into input", arguments: [
        "Interact with alternative interactive element for: ",
        "Navigate using alternative elements or shortcuts for: ",
        "Retry after low confidence: Interact with alternative interactive element for: ",
    ])
    func wrappedObservation(_ prefix: String) async throws {
        try await assertNoInput(prefix + "Verify the 'Selected click count' text displays 'Selected click count: 1'.")
    }

    @Test("The default planner's low-confidence retry retains observation intent")
    func actualPlannerRetry() async throws {
        let snapshot = UIStateSnapshot(visibleCandidates: candidates)
        let resolution = try await DefaultSubgoalPlanner().replan(
            goal: "Verify the Selected click count is 1.",
            failedSubgoal: Subgoal(id: "verify", description: "Verify the Selected click count is 1.",
                expectedOutcome: "Selected click count: 1 is observed"),
            reason: .lowConfidence(confidence: 0.0, threshold: 0.8),
            currentSnapshot: snapshot, history: [])
        guard case .retrySubgoal(let retry) = resolution else {
            Issue.record("Default planner did not produce the expected first retry")
            return
        }
        try await assertNoInput(retry.description)
    }

    private var candidates: [UIElementCandidate] {
        [UIElementCandidate(id: "field", role: "AXTextField", label: "selected-original-1",
            bounds: CGRect(x: 40, y: 120, width: 180, height: 30))]
    }

    private func assertNoInput(_ goal: String) async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: goal, candidates: candidates,
            recentEscalations: [EscalationRecord(attempt: 1,
                reason: .lowConfidence(confidence: 0.0, threshold: 0.8))])
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }
}
