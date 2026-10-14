import Foundation
import MCACore
import MCAPerception
@testable import MCARealtime
import Testing

struct WAVEncoderTests {
    @Test func encodesWavHeaderCorrectly() {
        let pcmData = Data([0x00, 0x00, 0x10, 0x20]) // 2 samples, 4 bytes
        let wav = WAVEncoder.encode(pcmData: pcmData, sampleRate: 16_000, channels: 1)

        #expect(wav.count == 44 + pcmData.count)

        // "RIFF"
        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
        // "WAVE"
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        // "fmt "
        #expect(String(data: wav[12..<16], encoding: .ascii) == "fmt ")

        // Audio format = 1 (PCM)
        let format = wav.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(format == 1)

        // Channels = 1
        let channels = wav.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1)

        // Sample rate = 16000
        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 16_000)

        // Bits per sample = 16
        let bitsPerSample = wav.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16)

        // "data"
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data")

        // Data size
        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(dataSize == UInt32(pcmData.count))
    }

    @Test func encodesFloat32Samples() {
        let samples: [Float] = [0.0, 0.5, -0.5, 0.0]
        let wav = WAVEncoder.encodeFloat32Samples(samples, sourceRate: 16_000, targetRate: 16_000)

        #expect(wav.count == 44 + samples.count * 2)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var responseDelaySeconds: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let delay = Self.responseDelaySeconds
        let work = { [weak self] in
            guard let self else { return }
            do {
                let (response, data) = try handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work()
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct GeminiTranscriberTests {
    @Test func transcribeParsesSuccessfulResponse() async throws {
        MockURLProtocol.responseDelaySeconds = 0
        let expectedText = "明日の天気を教えてください"
        let jsonResponse = """
        {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {
                                "text": "\(expectedText)"
                            }
                        ]
                    }
                }
            ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-api-key")
            #expect(request.url?.absoluteString.contains("gemini-3.8-flash:generateContent") == true)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(jsonResponse.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let transcriber = GeminiTranscriber(
            apiKey: "test-api-key",
            model: "gemini-3.8-flash",
            locale: Locale(identifier: "ja_JP"),
            session: mockSession
        )

        try await transcriber.start()

        // Generate synthetic voice samples: 1.0s of sound (~16,000 samples)
        let sampleRate = 16_000.0
        let frameCount = 16_000
        var samples = [Float]()
        for i in 0..<frameCount {
            // 440 Hz tone with audible amplitude (above VAD threshold)
            let val = sin(2.0 * .pi * 440.0 * Double(i) / sampleRate) * 0.5
            samples.append(Float(val))
        }

        await transcriber.append(samples: samples, sampleRate: sampleRate)
        await transcriber.finish()

        var results: [TranscriptChunk] = []
        for await chunk in transcriber.results {
            results.append(chunk)
        }

        #expect(!results.isEmpty)
        #expect(results.first?.text == expectedText)
        #expect(results.first?.isFinal == true)
    }

    @Test func finishWaitsForSpeechEndedUtteranceAndBuffersSubFrameChunks() async throws {
        defer { MockURLProtocol.responseDelaySeconds = 0 }
        MockURLProtocol.responseDelaySeconds = 0.04
        let expectedText = "サブフレームと発話終了テスト"
        let body = Data(#"{"candidates":[{"content":{"parts":[{"text":"\#(expectedText)"}]}}]}"#.utf8)
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let transcriber = GeminiTranscriber(apiKey: "test-api-key", locale: Locale(identifier: "ja_JP"), session: URLSession(configuration: config))
        try await transcriber.start()

        let rate = 16_000.0
        let allSamples = (0..<9_600).map { Float(sin(2.0 * .pi * 440.0 * Double($0) / rate) * 0.5) }
            + Array(repeating: Float(0), count: 12_800)
        for start in stride(from: 0, to: allSamples.count, by: 200) {
            await transcriber.append(samples: Array(allSamples[start..<min(start + 200, allSamples.count)]), sampleRate: rate)
        }
        await transcriber.finish()

        var results: [TranscriptChunk] = []
        for await chunk in transcriber.results { results.append(chunk) }
        #expect(results.map(\.text) == [expectedText])
    }

    @Test func missingApiKeyThrowsOnStart() async {
        let transcriber = GeminiTranscriber(apiKey: "")
        do {
            try await transcriber.start()
            Issue.record("Expected error when starting with empty API key")
        } catch {
            #expect(error is GeminiTranscriber.TranscriberError)
        }
    }
}
