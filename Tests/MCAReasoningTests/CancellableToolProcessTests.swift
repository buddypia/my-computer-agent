import Foundation
@testable import MCAReasoning
import Testing

@Suite("Tool child process cancellation", .serialized)
struct CancellableToolProcessTests {
    @Test("Timeout stops descendants holding output pipes")
    func descendantTimeout() async throws {
        let output = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "sleep 20; printf late"], timeout: 0.1)
        #expect(output.timedOut)
        #expect(output.supervisorElapsed < .seconds(10))
        #expect(!output.stdout.contains("late"))
    }
    @Test("Timeout escalates when the direct child ignores TERM")
    func resistantTimeout() async throws {
        let output = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 20"], timeout: 0.1)
        #expect(output.timedOut)
        #expect(output.supervisorElapsed < .seconds(10))
    }
    @Test("Cancellation terminates the child that was actually started")
    func cancellation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let clock = ContinuousClock(), begin = ContinuousClock.now
        let task = Task {
            try await CancellableToolProcess.run(executable: "/bin/sleep", arguments: ["20"], timeout: 25,
                onStart: { started.continuation.yield(()); started.continuation.finish() })
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - begin < .seconds(10))
    }
    @Test("Timeout and cancellation finish within their wall-clock budget")
    func processTerminationPromptnessIsolated() async throws {
        let descendant = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "sleep 5; printf late"], timeout: 0.1)
        let resistant = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 5"], timeout: 0.1)
        let started = AsyncStream<Void>.makeStream()
        let clock = ContinuousClock(), begin = ContinuousClock.now
        let task = Task {
            try await CancellableToolProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 12,
                onStart: { started.continuation.yield(()); started.continuation.finish() })
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelElapsed = clock.now - begin
        #expect(descendant.timedOut && resistant.timedOut)
        // TERM, a 0.25 s grace, then KILL: about 0.35 s. A missed escalation runs the 5 s sleep out, so the
        // budget leaves room for a stalled CI VM (0.72 s observed) and still tells the two apart.
        let supervisorBudget: Duration = IsolatedTiming.enabled ? .milliseconds(1500) : .seconds(10)
        let cancelBudget: Duration = IsolatedTiming.enabled ? .seconds(3) : .seconds(10)
        #expect(descendant.supervisorElapsed < supervisorBudget)
        #expect(resistant.supervisorElapsed < supervisorBudget)
        #expect(cancelElapsed < cancelBudget)
    }
    @Test("Output pipes are drained while the child runs")
    func output() async throws {
        let output = try await CancellableToolProcess.run(executable: "/usr/bin/printf", arguments: ["hello"])
        #expect(output.status == 0)
        #expect(output.stdout == "hello")
        #expect(!output.timedOut)
    }
}
