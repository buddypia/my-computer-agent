import CoreGraphics
import MCACore
import Testing

@testable import MCAReasoning

@Suite("Observation of navigation labels")
struct OfflineObservationNavigationLabelTests {
    @Test("Navigation words in observed labels do not request navigation", arguments: [
        "スクロール回数: 1 を確認してください。",
        "스크롤 횟수: 1 확인하세요.",
    ])
    func observedNavigationLabel(_ goal: String) async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let field = UIElementCandidate(id: "field", role: "AXTextField", label: "selected-original-1",
            bounds: CGRect(x: 40, y: 120, width: 180, height: 30))
        let decision = try await engine.decideNextAction(goal: goal, candidates: [field])
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }
}
