import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
@testable import MCASensing
import Synchronization
import Testing

/// Waits until released, ignoring cancellation, then tries to act. Records
/// whether the session let the late action through.
private final class LateActingTool: AgentTool, Sendable {
    private let gate = Mutex<(released: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
    let acted = Mutex<Bool?>(nil)
    var definition: ToolDefinition {
        ToolDefinition(name: "late_act", description: "", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        await withCheckedContinuation { continuation in
            let runNow = gate.withLock { state -> Bool in
                if state.released { return true }
                state.waiter = continuation
                return false
            }
            if runNow { continuation.resume() }
        }
        do {
            try await ActionAuthorization.current?.consumeAction()
            acted.withLock { $0 = true }
        } catch {
            acted.withLock { $0 = false }
        }
        return "late"
    }
    func release() {
        let waiter = gate.withLock { state in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

@Suite("Timeout follow-ups")
struct TimeoutFollowupTests {
    @Test("A call abandoned by the timeout cannot act when it finally resumes")
    func abandonedBodyCannotAct() async throws {
        let tool = LateActingTool()
        let registry = ToolRegistry(tools: [tool], timeout: .milliseconds(100))
        let session = ActionAuthorization(goal: "Scroll", requestApproval: { _ in .approved })
        let output = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "1", name: "late_act", arguments: Data("{}".utf8)))
        }
        #expect(output.content.contains("did not finish within"))
        tool.release()
        for _ in 0..<100 where tool.acted.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tool.acted.withLock { $0 } == false)
    }

    @Test("The AX walk stops at its deadline and when its task is cancelled")
    func walkGuard() async {
        #expect(AccessibilityInspector.walkMayContinue(until: .now + .seconds(5)))
        #expect(!AccessibilityInspector.walkMayContinue(until: .now - .milliseconds(1)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return AccessibilityInspector.walkMayContinue(until: .now + .seconds(5))
        }
        #expect(await task.value == false)
    }

    @Test("Time spent waiting on a keystroke approval does not count toward the loop's time limit")
    func approvalWaitExcludedFromLoopLimit() async throws {
        let engine = TypeSafeDecisionEngine(
            client: MockTypeSafeEvaluator { _ in throw TypeSafeClient.ClientError.missingApiKey },
            confidenceThreshold: 0.80)
        let field = UIElementCandidate(
            id: "tf_input", role: "AXTextField", label: "Email", value: nil,
            bounds: CGRect(x: 10, y: 10, width: 200, height: 30))
        func snapshot(_ title: String) -> UIStateSnapshot {
            UIStateSnapshot(
                windowTitle: title, appBundleId: "com.apple.Safari", appName: "Safari",
                focusedElementId: nil, visibleCandidates: [field], timestamp: Date(), frameHash: "hash_\(title)")
        }
        var config = AutonomousLoopConfig.testing
        config.maxDurationSeconds = 3
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: MockPlanningLLM.staticPlan(subgoals: [Subgoal(
                id: "sg_t", description: "Type user@example.com into Email",
                expectedOutcome: "title changed to Form Typed", maxSteps: 3)]),
            decisionEngine: engine,
            synthesizer: MockEventSynthesizer(),
            inspector: MockUIInspector(snapshots: [snapshot("Form"), snapshot("Form"), snapshot("Form Typed")]),
            config: config,
            keystrokeApprover: SlowApprover(delay: .seconds(4)))
        _ = try await coordinator.execute(goal: "Enter email")
    }
}

private struct SlowApprover: ToolApproving {
    let delay: Duration
    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        try? await Task.sleep(for: delay)
        return .approved
    }
}
