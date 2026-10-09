import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import MCASensing
import Synchronization
import Testing

/// A tool stuck in a call that ignores cancellation, the way a synchronous AX
/// read on an unresponsive app does. It suspends rather than blocking a thread,
/// so parallel suites cannot starve the cooperative pool on a small CI runner.
/// `release()` lets every pending call return.
private final class StuckTool: AgentTool, Sendable {
    private let waiters = Mutex<(released: Bool, pending: [CheckedContinuation<Void, Never>])>((false, []))
    var definition: ToolDefinition {
        ToolDefinition(name: "stuck", description: "never returns", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        await withCheckedContinuation { continuation in
            let runNow = waiters.withLock { state -> Bool in
                if state.released { return true }
                state.pending.append(continuation)
                return false
            }
            if runNow { continuation.resume() }
        }
        return "late"
    }
    func release() {
        let pending = waiters.withLock { state in
            state.released = true
            defer { state.pending = [] }
            return state.pending
        }
        pending.forEach { $0.resume() }
    }
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
        let limits = ToolClock.Limits(working: .seconds(5), approvalAllowance: .seconds(5))
        let result = try await ToolClock.run(name: "fast", limits: limits) { "ok" }
        #expect(result == "ok")
    }

    @Test("An approval that never resolves is still bounded by the wall-clock ceiling")
    func pausedForeverHitsWallCeiling() async throws {
        let registry = ToolRegistry(tools: [ApprovalThenDoneTool()], timeout: .milliseconds(100),
                                    approvalAllowance: .milliseconds(200))
        let session = ActionAuthorization(goal: "Scroll", requestApproval: { _ in
            try await Task.sleep(for: .seconds(30))
            return .approved
        })
        let begin = ContinuousClock.now
        let output = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "1", name: "approve_then_done", arguments: Data("{}".utf8)))
        }
        #expect(output.content.contains("did not finish within"))
        #expect(ContinuousClock.now - begin < .seconds(3))
    }

    @Test("Once enough calls are stuck, further calls are refused without running")
    func stuckCallsSaturateRegistry() async throws {
        let tool = StuckTool()
        defer { tool.release() }
        let registry = ToolRegistry(tools: [tool, ApprovalThenDoneTool()], timeout: .milliseconds(100),
                                    stuckCallLimit: 2)
        _ = await registry.invoke(ToolCall(id: "1", name: "stuck", arguments: Data("{}".utf8)))
        _ = await registry.invoke(ToolCall(id: "2", name: "stuck", arguments: Data("{}".utf8)))
        let refused = await registry.invoke(ToolCall(id: "3", name: "approve_then_done", arguments: Data("{}".utf8)))
        #expect(refused.content.contains("still stuck"))
    }

    @Test("A stuck call that finally returns frees its slot")
    func stuckSlotReleased() async throws {
        let stuck = StuckToolCalls(limit: 1)
        let tool = StuckTool()
        let limits = ToolClock.Limits(working: .milliseconds(100), approvalAllowance: .zero)
        await #expect(throws: ToolTimeoutError.self) {
            _ = try await ToolClock.run(name: "stuck", limits: limits, stuck: stuck) {
                try await tool.invoke(arguments: Data())
            }
        }
        #expect(stuck.isSaturated)
        tool.release()
        for _ in 0..<50 where stuck.isSaturated { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!stuck.isSaturated)
    }

    @Test("A call cancelled before it starts never runs the tool")
    func cancelledBeforeStart() async throws {
        let ran = Mutex(false)
        let limits = ToolClock.Limits(working: .seconds(5), approvalAllowance: .zero)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolClock.run(name: "x", limits: limits) {
                ran.withLock { $0 = true }
                return "ran"
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran.withLock { $0 } == false)
    }

    @Test("browser_wait keeps its 120s maximum by declaring a longer limit than the default")
    func browserWaitLimit() {
        #expect(BrowserWaitTool.callTimeout > .seconds(120))
        #expect(ToolRegistry.defaultTimeout < .seconds(120))
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

@Suite("Autonomous loop config compatibility")
struct AutonomousLoopConfigCompatibilityTests {
    @Test("A config encoded before maxDurationSeconds existed still decodes")
    func legacyDecode() throws {
        let legacy = Data("""
            {"maxTotalSteps":12,"defaultSubgoalMaxSteps":4,"confidenceThreshold":0.9,"settlingDelayMs":50,
             "maxConsecutiveEscalations":2,"identicalActionThreshold":3,"unchangedStateThreshold":3,"isDebugMode":false}
            """.utf8)
        let config = try JSONDecoder().decode(AutonomousLoopConfig.self, from: legacy)
        #expect(config.maxTotalSteps == 12)
        #expect(config.maxDurationSeconds == 600)
        let roundTrip = try JSONDecoder().decode(AutonomousLoopConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip == config)
    }
}
