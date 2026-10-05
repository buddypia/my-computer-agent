import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer for Float32 PCM.
///
/// This is the *only* sanctioned boundary between a CoreAudio realtime thread
/// and the rest of the app. The producer side (`write`) performs no allocation,
/// takes no locks and never blocks, which is what the realtime IOProc contract
/// requires — a `malloc` or a mutex in an IOProc will glitch the audio stream.
///
/// Capacity is rounded up to a power of two so index wrapping is a mask.
public final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int

    // Producer writes `writeIndex`, consumer writes `readIndex`. Each side only
    // ever loads the other's index, so relaxed/acquire-release ordering is
    // sufficient and no mutual exclusion is required.
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    public init(capacity requested: Int) {
        var size = 1
        while size < max(requested, 2) { size <<= 1 }
        self.capacity = size
        self.mask = size - 1
        self.storage = .allocate(capacity: size)
        self.storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Realtime-safe. Returns the number of frames actually written; a short
    /// write means the consumer fell behind and the remainder was dropped.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let available = capacity - (write - read) - 1
        let toWrite = min(samples.count, max(available, 0))

        if toWrite < samples.count {
            droppedFrames.add(samples.count - toWrite, ordering: .relaxed)
        }
        guard toWrite > 0 else { return 0 }

        for i in 0..<toWrite {
            storage[(write &+ i) & mask] = samples[i]
        }
        writeIndex.store(write &+ toWrite, ordering: .releasing)
        return toWrite
    }

    /// Consumer side. Safe to allocate here — this runs off the realtime thread.
    public func read(maxFrames: Int) -> [Float] {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let toRead = min(maxFrames, write - read)
        guard toRead > 0 else { return [] }

        var out = [Float](repeating: 0, count: toRead)
        for i in 0..<toRead {
            out[i] = storage[(read &+ i) & mask]
        }
        readIndex.store(read &+ toRead, ordering: .releasing)
        return out
    }

    public var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    /// Frames the producer had to discard because the consumer was too slow.
    /// Non-zero here means the pipeline is not keeping up.
    public var dropped: Int { droppedFrames.load(ordering: .relaxed) }

    public func resetDropCount() { droppedFrames.store(0, ordering: .relaxed) }
}
