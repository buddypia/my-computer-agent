import CoreGraphics
import MCACore
import MCAReasoning
import Testing

@Suite("Offline action constraints")
struct OfflineDecisionConstraintTests {
    private let candidates = [
        UIElementCandidate(id: "window", role: "AXWindow", label: "Selected native target",
            bounds: CGRect(x: 900, y: 300, width: 360, height: 230), isActionable: false),
        UIElementCandidate(id: "button", role: "AXButton", label: "Record selected click",
            bounds: CGRect(x: 930, y: 350, width: 290, height: 32)),
        UIElementCandidate(id: "field", role: "AXTextField", label: "Selected text",
            bounds: CGRect(x: 930, y: 400, width: 290, height: 26)),
    ]

    @Test("Unavailable evaluator escalates constrained goals instead of guessing a forbidden action", arguments: [
        "In the selected native target window, click the button labelled Record selected click. Do not type, use keys, or switch windows.",
        "Click Record selected click. Do not type 'changed' into Selected text.",
        "Do not click Record selected click.",
        "Record selected click をクリックして。Selected text に入力しないで。",
        "Record selected click 버튼을 클릭해. Selected text 에 입력하지 마.",
        "Click Record selected click; don't scroll the window.",
        "Avoid clicking Record selected click.",
        "Record selected click をクリックするな。",
        "Record selected click 클릭하면 안 돼.",
    ])
    func constrainedGoal(_ goal: String) async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(goal: goal, candidates: candidates)
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Window title matching cannot defeat an actionable button")
    func observedButton() async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(
            goal: "In the selected native target window, click Record selected click.", candidates: candidates)
        #expect(decision.action == .click)
        #expect(decision.targetElementId == "button")
        #expect(decision.coordinates == candidates[1].center)
        #expect(!decision.isCompleted)
    }

    @Test("Read-only matching text requires escalation")
    func readOnlyTarget() async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        let decision = try await engine.decideNextAction(
            goal: "Click Selected native target", candidates: [candidates[0]])
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }

    @Test("Typing never selects a non-actionable field")
    func readOnlyInput() async throws {
        let engine = TypeSafeDecisionEngine(client: TypeSafeClient(apiKey: ""))
        var readOnly = candidates[2]
        readOnly.isActionable = false
        let decision = try await engine.decideNextAction(
            goal: "Type 'changed' into Selected text", candidates: [readOnly])
        #expect(decision.action == .none)
        #expect(decision.targetElementId == nil)
        #expect(decision.coordinates == nil)
        #expect(!decision.isCompleted)
        #expect(engine.shouldEscalate(decision: decision))
    }
}
