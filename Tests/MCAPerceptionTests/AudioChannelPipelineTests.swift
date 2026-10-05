import Foundation
import MCACore
import Testing

@testable import MCAPerception

/// A transcriber that refuses to start, standing in for the real failure this
/// covers: `SpeechAnalyzer` cannot install the locale's speech model.
private actor FailingTranscriber: Transcribing {
    struct Refused: Error {}

    private let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    nonisolated var results: AsyncStream<TranscriptChunk> { stream }

    private(set) var appended = 0

    func start() async throws { throw Refused() }
    func append(samples: [Float], sampleRate: Double) async { appended += samples.count }
    func finish() async { continuation.finish() }
}

private actor TapRecorder {
    private(set) var samples: [Float] = []
    func record(_ chunk: [Float]) { samples.append(contentsOf: chunk) }
}

@Suite("Audio channel pipeline")
struct AudioChannelPipelineTests {
    /// The bug this covers had no visible symptom of its own. On-device
    /// transcription failing took the drain pump down with it, and the pump is
    /// also what feeds captured audio to a realtime voice session — so pressing
    /// the voice button opened a session that could never hear anything, with
    /// nothing on screen to say why.
    @Test("audio still reaches the tap when the transcriber cannot start")
    func tapSurvivesATranscriberFailure() async throws {
        let ring = AudioRingBuffer(capacity: 4096)
        let pipeline = AudioChannelPipeline(
            channel: .microphone,
            ringBuffer: ring,
            sampleRate: 16_000,
            transcriber: FailingTranscriber())

        await #expect(throws: (any Error).self) { try await pipeline.start() }

        let recorder = TapRecorder()
        await pipeline.setAudioTap { samples, _ in
            Task { await recorder.record(samples) }
        }

        let frames = [Float](repeating: 0.25, count: 1024)
        frames.withUnsafeBufferPointer { _ = ring.write($0) }

        // The pump drains on a 100 ms cadence, but it and the tap's Task share
        // the cooperative pool with the whole parallel suite: wait for the
        // samples (up to 5 s) rather than for a fixed time.
        var received = await recorder.samples
        for _ in 0..<100 where received.count < frames.count {
            try await Task.sleep(for: .milliseconds(50))
            received = await recorder.samples
        }

        #expect(received.count == frames.count)
        await pipeline.stop()
    }
}
