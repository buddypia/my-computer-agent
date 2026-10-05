import Foundation
@testable import MCAReasoning
import Testing

@Suite("Tool child process cancellation", .serialized)
struct CancellableToolProcessTests {
    @Test("Timeout stops descendants holding output pipes")
    func descendantTimeout() async throws {
        let output = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "sleep 1; printf late"], timeout: 0.1)
        #expect(output.timedOut)
        // Measure the supervised process operation, not unrelated executor delay
        // before this awaiting test task is scheduled again under host load.
        #expect(output.supervisorElapsed < .milliseconds(700))
        #expect(!output.stdout.contains("late"))
    }
    @Test("Timeout escalates when the direct child ignores TERM")
    func resistantTimeout() async throws {
        let output = try await CancellableToolProcess.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 1"], timeout: 0.1)
        #expect(output.timedOut)
        #expect(output.supervisorElapsed < .milliseconds(700))
    }
    @Test("Cancellation terminates the child that was actually started")
    func cancellation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let clock = ContinuousClock(), begin = ContinuousClock.now
        let task = Task {
            try await CancellableToolProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 12,
                onStart: { started.continuation.yield(()); started.continuation.finish() })
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - begin < .seconds(3))
    }
    @Test("Output pipes are drained while the child runs")
    func output() async throws {
        let output = try await CancellableToolProcess.run(executable: "/usr/bin/printf", arguments: ["hello"])
        #expect(output.status == 0)
        #expect(output.stdout == "hello")
        #expect(!output.timedOut)
    }
}
