import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

private enum InputCancellationStage: String, CaseIterable, Sendable {
    case dispatchEntry, clickBeforeTyping, clickBeforeKeys, firstKey
}

/// Records only; never posts native input. Cancellation is injected at a
/// synchronous input boundary after the coordinator's outer token check.
private final class CancellingInputRecorder: EventSynthesizing, @unchecked Sendable {
    let token: CancellationToken
    let stage: InputCancellationStage
    private let lock = NSLock()
    private var recorded: [String] = []

    init(token: CancellationToken, stage: InputCancellationStage) {
        self.token = token
        self.stage = stage
    }
    var isSimulation: Bool {
        if stage == .dispatchEntry { token.cancel() }
        return true
    }
    var isTrusted: Bool { true }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ event: String) {
        lock.lock(); recorded.append(event); lock.unlock()
    }
    func cursorPosition() throws -> CGPoint { .zero }
    func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws {
        record("click")
        if stage == .clickBeforeTyping || stage == .clickBeforeKeys { token.cancel() }
    }
    func typeText(_ text: String) throws { record("type:" + text) }
    func pressKey(_ chordString: String) throws {
        record("key:" + chordString)
        if stage == .firstKey { token.cancel() }
    }
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws { record("scroll") }
    func mouseMove(to point: CGPoint) throws { record("move") }
    func drag(from start: CGPoint, to end: CGPoint) throws { record("drag") }
    func releaseAllHeldEvents() { record("release") }
}

@Suite("Coordinated input cancellation boundaries")
struct CoordinatedInputCancellationTests {
    @Test("A cancelled token prevents remaining input within the same decision",
          arguments: InputCancellationStage.allCases)
    fileprivate func remainingInput(stage: InputCancellationStage) async throws {
        let token = CancellationToken()
        let synth = CancellingInputRecorder(token: token, stage: stage)
        let field = UIElementCandidate(id: "field", role: "AXTextField", label: "Fixture field",
            bounds: CGRect(x: 50, y: 80, width: 200, height: 30))
        let snapshot = UIStateSnapshot(windowTitle: "Owned unit fixture",
            focusedElementId: field.id, visibleCandidates: [field])
        let action = stage == .dispatchEntry ? "click" : stage == .clickBeforeTyping ? "type" : "key"
        let evaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: stage == .firstKey ? "none" : field.id,
            actionChoice: action, textInput: "must not be typed", keyCombination: "a,b")
        let planner = MockPlanningLLM.staticPlan(subgoals: [
            Subgoal(description: "Update fixture field", expectedOutcome: "Changed", maxSteps: 2)
        ])
        let coordinator = TwoTierAutonomousLoopCoordinator(planner: planner,
            decisionEngine: TypeSafeDecisionEngine(client: evaluator), synthesizer: synth,
            inspector: MockUIInspector(snapshots: [snapshot]), config: .testing,
            keystrokeApprover: AutoApproveToolApprover())

        await #expect(throws: LoopExecutionError.cancelled) {
            try await coordinator.execute(goal: "Update fixture field", cancellationToken: token)
        }
        #expect(evaluator.recordedRequests.count == 1)
        let expected: [String] = stage == .dispatchEntry ? [] : stage == .firstKey ? ["key:a"] : ["click"]
        #expect(synth.events.filter { $0 != "release" } == expected)
        #expect(synth.events.contains("release"))
    }
}
