import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import MCASensing
import Testing

/// A tool stuck in a call that ignores cancellation, the way a synchronous AX
/// read on an unresponsive app does. `release()` lets the thread go at the end.
private final class StuckTool: AgentTool, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    var definition: ToolDefinition {
        ToolDefinition(name: "stuck", description: "never returns", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        block()
        return "late"
    }
    private func block() { gate.wait() }
    func release() { gate.signal() }
}

private struct ApprovalThenDoneTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(name: "approve_then_done", description: "", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        try await ActionAuthorization.requireApproval(
            operation: "test", target: "test", details: "", revalidate: { true })
        return "done"
    }
}

@Suite("Tool call timeout")
struct ToolTimeoutTests {
    @Test("A tool that never returns is abandoned with an error instead of hanging the turn")
    func stuckToolTimesOut() async throws {
        let tool = StuckTool()
        defer { tool.release() }
        let registry = ToolRegistry(tools: [tool], timeout: .milliseconds(200))
        let begin = ContinuousClock.now
        let output = await registry.invoke(ToolCall(id: "1", name: "stuck", arguments: Data("{}".utf8)))
        #expect(output.content.contains("did not finish within"))
        #expect(ContinuousClock.now - begin < .seconds(3))
    }

    @Test("A timed-out tool ends the action session")
    func timeoutAbortsSession() async throws {
        let tool = StuckTool()
        defer { tool.release() }
        let registry = ToolRegistry(tools: [tool], timeout: .milliseconds(200))
        let session = ActionAuthorization(goal: "Scroll", requestApproval: { _ in .approved })
        await ActionAuthorization.withSession(session) {
            _ = await registry.invoke(ToolCall(id: "1", name: "stuck", arguments: Data("{}".utf8)))
        }
        #expect(await session.terminalFailure?.contains("did not finish within") == true)
    }

    @Test("Time spent waiting on the user's approval is not held against the tool")
    func approvalWaitNotCounted() async throws {
        let registry = ToolRegistry(tools: [ApprovalThenDoneTool()], timeout: .milliseconds(300))
        let session = ActionAuthorization(goal: "Scroll", requestApproval: { _ in
            try await Task.sleep(for: .milliseconds(900))
            return .approved
        })
        let output = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "1", name: "approve_then_done", arguments: Data("{}".utf8)))
        }
        #expect(output.content == "done")
    }

    @Test("A fast tool returns its result unchanged")
    func fastToolUnaffected() async throws {
        let result = try await ToolClock.run(name: "fast", timeout: .seconds(5)) { "ok" }
        #expect(result == "ok")
    }
}

@Suite("Autonomous loop time limit")
struct AutonomousLoopTimeLimitTests {
    @Test("The loop stops with timeLimitExceeded once its wall-clock budget is spent")
    func wallClockLimit() async throws {
        let snapshot = UIStateSnapshot(
            windowTitle: "Firefox", appBundleId: "org.mozilla.firefox", appName: "Firefox",
            focusedElementId: nil,
            visibleCandidates: [UIElementCandidate(id: "a", role: "AXLink", label: "Article",
                                                   bounds: CGRect(x: 0, y: 0, width: 10, height: 10))],
            timestamp: Date(), frameHash: "h")
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: MockPlanningLLM.staticPlan(subgoals: [
                Subgoal(description: "Find article", expectedOutcome: "Found", maxSteps: 5)
            ]),
            synthesizer: MockEventSynthesizer(),
            snapshotProvider: MockUIInspector(snapshots: [snapshot]),
            config: AutonomousLoopConfig(settlingDelayMs: 0, isDebugMode: false, maxDurationSeconds: 0))
        await #expect(throws: LoopExecutionError.timeLimitExceeded(seconds: 0)) {
            _ = try await coordinator.execute(goal: "Scroll Firefox until an article matches")
        }
    }
}
