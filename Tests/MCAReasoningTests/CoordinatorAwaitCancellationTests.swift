import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

private enum LoopWaitStage: CaseIterable, Sendable { case observation, planning, decision, replanning }

private final class LoopWait: @unchecked Sendable {
    private var started = false
    private var finished = false
    enum WaitError: Error { case finishedBeforeStart, deadlineExceeded }
    func markFinished() { lock.withLock { finished = true } }
    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ started }) {
            if lock.withLock({ finished }) { throw WaitError.finishedBeforeStart }
            guard ContinuousClock.now < deadline else { throw WaitError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func waitUntilFinished() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ finished }) {
            guard ContinuousClock.now < deadline else { throw WaitError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private let barrier = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var cancelled = false
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func recordCancellation() { lock.lock(); cancelled = true; lock.unlock(); barrier.continuation.finish() }
    func release() { barrier.continuation.finish() }
    func wait() async throws {
        try await withTaskCancellationHandler {
            lock.withLock { started = true }
            for await _ in barrier.stream { }
            try Task.checkCancellation()
        } onCancel: { self.recordCancellation() }
    }
}

private struct WaitingSnapshotProvider: UIStateProviding {
    let stage: LoopWaitStage
    let wait: LoopWait
    func captureSnapshot() async throws -> UIStateSnapshot {
        if stage == .observation { try await wait.wait() }
        return UIStateSnapshot(visibleCandidates: [UIElementCandidate(id: "fixture", role: "AXButton",
            label: "Fixture", bounds: CGRect(x: 10, y: 20, width: 30, height: 40))])
    }
}

private struct WaitingLoopPlanner: System2Planning {
    let stage: LoopWaitStage
    let wait: LoopWait
    func plan(goal: String, initialSnapshot: UIStateSnapshot?) async throws -> SubgoalPlan {
        if stage == .planning { try await wait.wait() }
        return SubgoalPlan(goal: goal, subgoals: [Subgoal(description: "Inspect fixture", expectedOutcome: "Observed", maxSteps: 3)])
    }
    func replan(goal: String, failedSubgoal: Subgoal, reason: EscalationReason,
                currentSnapshot: UIStateSnapshot?, history: [LoopStepRecord]) async throws -> EscalationResolution {
        if stage == .replanning { try await wait.wait() }
        return .retrySubgoal(failedSubgoal)
    }
}

@Suite("Coordinator cancellation during awaited work")
struct CoordinatorAwaitCancellationTests {
    @Test("Cancellation reaches the suspended operation before the fixture releases it",
          arguments: LoopWaitStage.allCases, [false, true])
    fileprivate func cancelledWait(_ stage: LoopWaitStage, _ cancelTask: Bool) async throws {
        let wait = LoopWait(), token = CancellationToken()
        let synthesizer = DryRunEventSynthesizer()
        let engine = TypeSafeDecisionEngine(client: SystemOneBackend.Offline(), customEvaluator: { _ in
            if stage == .decision { try await wait.wait() }
            return TypeSafeClient.EvaluationResponse(model: "waiting-fixture", answers: [
                "target_element": .init(type: "choice", choice: "none", confidence: 0.1),
                "action_type": .init(type: "choice", choice: "none", confidence: 0.1),
                "is_completed": .init(type: "noul", noul: 0)
            ])
        })
        let coordinator = TwoTierAutonomousLoopCoordinator(planner: WaitingLoopPlanner(stage: stage, wait: wait),
            decisionEngine: engine, synthesizer: synthesizer,
            snapshotProvider: WaitingSnapshotProvider(stage: stage, wait: wait), config: .testing)
        let task = Task {
            defer { wait.markFinished() }
            return try await coordinator.execute(goal: "Inspect fixture", cancellationToken: token)
        }
        defer { task.cancel(); wait.release() }
        try await wait.waitUntilStarted()
        if cancelTask { task.cancel() } else { token.cancel() }
        #expect(wait.wasCancelled, "Cancellation must reach the awaited operation, not wait for its normal return")
        // Always release the owned fixture, so a failing implementation cannot hang the suite.
        wait.release()
        try await wait.waitUntilFinished()
        await #expect(throws: LoopExecutionError.cancelled) { try await task.value }
        #expect(synthesizer.recordedActions.allSatisfy { $0 == "releaseAllHeldEvents()" })
        #expect(synthesizer.recordedActions.contains("releaseAllHeldEvents()"))
    }
}
