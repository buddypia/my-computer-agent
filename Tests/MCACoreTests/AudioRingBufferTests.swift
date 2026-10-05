import Foundation
import Testing

@testable import MCACore

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {
    @Test("round-trips samples in order")
    func roundTrip() {
        let ring = AudioRingBuffer(capacity: 64)
        let input: [Float] = (0..<32).map { Float($0) }

        let written = input.withUnsafeBufferPointer { ring.write($0) }
        #expect(written == 32)
        #expect(ring.availableToRead == 32)
        #expect(ring.read(maxFrames: 32) == input)
        #expect(ring.availableToRead == 0)
    }

    @Test("wraps past the end of the backing store")
    func wrapAround() {
        // Capacity rounds to 8; usable capacity is one less so full and empty
        // stay distinguishable.
        let ring = AudioRingBuffer(capacity: 8)

        for round in 0..<5 {
            let chunk: [Float] = (0..<4).map { Float(round * 4 + $0) }
            _ = chunk.withUnsafeBufferPointer { ring.write($0) }
            #expect(ring.read(maxFrames: 4) == chunk)
        }
    }

    @Test("drops rather than blocking when the consumer falls behind")
    func dropsWhenFull() {
        let ring = AudioRingBuffer(capacity: 8)
        let input: [Float] = Array(repeating: 1, count: 32)

        let written = input.withUnsafeBufferPointer { ring.write($0) }

        // The producer runs on a realtime thread and must never block, so an
        // overrun has to be a short write plus a counter — not backpressure.
        #expect(written < 32)
        #expect(ring.dropped == 32 - written)

        ring.resetDropCount()
        #expect(ring.dropped == 0)
    }

    @Test("partial reads leave the remainder queued")
    func partialRead() {
        let ring = AudioRingBuffer(capacity: 64)
        let input: [Float] = (0..<20).map { Float($0) }
        _ = input.withUnsafeBufferPointer { ring.write($0) }

        #expect(ring.read(maxFrames: 5) == Array(input[0..<5]))
        #expect(ring.availableToRead == 15)
        #expect(ring.read(maxFrames: 100) == Array(input[5...]))
    }

    @Test("survives concurrent producer and consumer")
    func concurrentAccess() async {
        let ring = AudioRingBuffer(capacity: 4096)
        let totalFrames = 100_000

        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var sent = 0
                let chunk = [Float](repeating: 0.5, count: 128)
                while sent < totalFrames {
                    let written = chunk.withUnsafeBufferPointer { ring.write($0) }
                    sent += written
                    if written == 0 { await Task.yield() }
                }
                return sent
            }
            group.addTask {
                var received = 0
                while received < totalFrames {
                    let samples = ring.read(maxFrames: 256)
                    if samples.isEmpty {
                        await Task.yield()
                    } else {
                        // Every sample must be exactly what was written; a torn
                        // read would show up as some other value.
                        #expect(samples.allSatisfy { $0 == 0.5 })
                        received += samples.count
                    }
                }
                return received
            }
            _ = await group.reduce(0, +)
        }
    }
}

@Suite("Timeouts")
struct TimeoutTests {
    @Test("returns the value when the operation finishes in time")
    func completesInTime() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("throws when an async operation overruns")
    func asyncOverrun() async {
        await #expect(throws: TimedOutError.self) {
            try await withTimeout(seconds: 0.2) {
                try await Task.sleep(for: .seconds(10))
            }
        }
    }

    @Test("bounds blocking work that cannot be cancelled")
    func blockingOverrun() async {
        // The whole point: a synchronous C call that ignores cancellation must
        // still surface as a timeout rather than hanging the subsystem forever.
        let started = Date()
        await #expect(throws: TimedOutError.self) {
            try await withBlockingTimeout(seconds: 0.3) {
                Thread.sleep(forTimeInterval: 5)
                return 1
            }
        }
        #expect(Date().timeIntervalSince(started) < 3, "timeout did not fire promptly")
    }

    @Test("blocking work that finishes in time returns normally")
    func blockingCompletes() async throws {
        let value = try await withBlockingTimeout(seconds: 5) {
            Thread.sleep(forTimeInterval: 0.05)
            return "done"
        }
        #expect(value == "done")
    }

    @Test("errors from blocking work propagate unchanged")
    func blockingThrows() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withBlockingTimeout(seconds: 5) { throw Boom() }
        }
    }
}
