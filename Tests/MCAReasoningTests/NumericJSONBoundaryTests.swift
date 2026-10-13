import Foundation
import MCACore
@testable import MCAPerception
@testable import MCAReasoning
@testable import MCASensing
import Testing

private actor FlushOnFinishTranscriber: Transcribing {
    private let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    nonisolated var results: AsyncStream<TranscriptChunk> { stream }

    func start() async throws {}
    func append(samples: [Float], sampleRate: Double) async {}
    func finish() async {
        continuation.yield(TranscriptChunk(text: "final words on stop", isFinal: true, start: 0, duration: 0.5))
        continuation.finish()
    }
}

@Suite("Shared numeric JSON boundaries")
struct NumericJSONBoundaryTests {
    @Test("Malformed integer arguments do not become truncated or trapping values")
    func invalidValues() throws {
        for value in ["1e100", "-1e100", "1.5", "true", "false", "null"] {
            let object = try #require(parseJSONObject("{\"value\":\(value)}"))
            #expect(object.int("value") == nil)
        }
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(["value": value as Any].int("value") == nil)
            #expect(JSONValue.number(value).intValue == nil)
            #expect(JSONValue.number(value).anyValue is NSNull)
        }
        #expect(JSONValue.number(1e100).intValue == nil)
        #expect(JSONValue.number(-1e100).intValue == nil)
    }
    @Test("Representable integer boundaries retain their exact values")
    func validValues() throws {
        for value in [Int.min, -1, 0, 1, 25, 100, Int.max] {
            let object = try #require(parseJSONObject("{\"value\":\(value)}"))
            #expect(object.int("value") == value)
        }
        #expect(["value": 25.0 as Any].int("value") == 25)
        #expect(JSONValue.number(42).intValue == 42)
    }

    @Test("AudioChannelPipeline.stop forwards final transcript chunks emitted during transcriber.finish")
    func pipelineStopFlushesFinalTranscriptChunk() async throws {
        let pipeline = AudioChannelPipeline(
            channel: .microphone,
            ringBuffer: AudioRingBuffer(capacity: 256),
            sampleRate: 16_000,
            transcriber: FlushOnFinishTranscriber()
        )
        try await pipeline.start()
        await pipeline.stop()

        var texts: [String] = []
        for await event in pipeline.events {
            if let obs = event.observation {
                texts.append(obs.text)
            }
        }
        #expect(texts == ["final words on stop"])
    }
}
