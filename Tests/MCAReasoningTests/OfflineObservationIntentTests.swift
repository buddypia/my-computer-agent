import CoreGraphics
import MCACore
import Testing

@testable import MCAReasoning

@Suite("Offline observation intent")
struct OfflineObservationIntentTests {
    @Test("Observing a result cannot authorize an unrelated input", arguments: [
        "Verify the 'Selected click count' text displays 'Selected click count: 1'.",
        "Observe Selected click count become 1.",
        "Read the Selected click count: 1.",
        "Check the Selected click count is 1.",
        "Selected click count: 1 を確認してください。",
        "Selected click count: 1 확인하세요.",
    ])
    func observationOnly(_ goal: String) async throws {
        let candidates = [
            UIElementCandidate(id: "button", role: "AXButton", label: "Record selected click",
                bounds: CGRect(x: 40, y: 80, width: 180, height: 30)),
            UIElementCandidate(id: "field", role: "AXTextField", label: "selected-original-1",
                bounds: CGRect(x: 40, y: 120, width: 180, height: 30)),
            UIElementCandidate(id: "count", role: "AXStaticText", label: "Selected click count: 1",
                bounds: CGRect(x: 40, y: 160, width: 180, height: 30), isActionable: false),
        ]
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: goal, candidates: candidates)
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(decision.textInput == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("A requested click on a Verify button remains actionable")
    func verificationLabelIsNotObservationIntent() async throws {
        let candidate = UIElementCandidate(id: "verify", role: "AXButton", label: "Verify",
            bounds: CGRect(x: 40, y: 80, width: 180, height: 30))
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: "Click 'Verify'.", candidates: [candidate])
        #expect(decision.action == .click)
        #expect(decision.targetElementId == candidate.id)
        #expect(!decision.isCompleted)
    }
}
