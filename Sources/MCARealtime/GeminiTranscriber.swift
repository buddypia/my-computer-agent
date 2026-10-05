import Foundation
import MCACore
import MCAPerception
import OSLog

/// A cloud speech-to-text and intent-recognition transcriber backed by Google Gemini.
///
/// Unlike on-device SpeechAnalyzer, this transcriber uses multimodal LLM reasoning to
/// eliminate Japanese homophone confusion, accurately transcribe technical terminology,
/// and remove disfluencies (fillers such as "えーと", "あの") while strictly preserving
/// the speaker's intent.
public actor GeminiTranscriber: Transcribing {
    public enum TranscriberError: Error, CustomStringConvertible {
        case missingApiKey
        case networkError(String)
        case invalidResponse

        public var description: String {
            switch self {
            case .missingApiKey:
                return "Gemini API key is not configured"
            case .networkError(let message):
                return "Network request to Gemini failed: \(message)"
            case .invalidResponse:
                return "Invalid response structure from Gemini API"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "GeminiTranscriber")

    private let apiKey: String
    private let model: String
    private let locale: Locale
    private let customInstruction: String?
    private let baseURL: URL
    private let session: URLSession

    private let stream: AsyncStream<TranscriptChunk>
    private let continuation: AsyncStream<TranscriptChunk>.Continuation

    private var vad: VoiceActivityDetector
    private var isCapturing = false
    private var speechSamples: [Float] = []
    private var preRollBuffer: [Float] = []
    private var preRollMaxSamples: Int = 4800 // ~300ms at 16kHz default, updated on sample rate
    private var currentUtteranceStartTime: TimeInterval = 0
    private var currentSampleRate: Double = 16_000
    private var elapsedSamples: Int = 0

    public nonisolated var results: AsyncStream<TranscriptChunk> { stream }

    public init(
        apiKey: String,
        model: String = "gemini-3.8-flash",
        locale: Locale = Locale.current,
        customInstruction: String? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.locale = locale
        self.customInstruction = customInstruction
        self.baseURL = baseURL
        self.session = session
        self.vad = VoiceActivityDetector(sampleRate: 16_000)

        (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    }

    public func start() async throws {
        guard !apiKey.isEmpty else {
            throw TranscriberError.missingApiKey
        }
        speechSamples.removeAll()
        preRollBuffer.removeAll()
        elapsedSamples = 0
        log.info("GeminiTranscriber started using model: \(self.model, privacy: .public)")
    }

    public func append(samples: [Float], sampleRate: Double) async {
        guard !samples.isEmpty else { return }

        if currentSampleRate != sampleRate {
            currentSampleRate = sampleRate
            vad = VoiceActivityDetector(sampleRate: sampleRate)
            preRollMaxSamples = Int(sampleRate * 0.3) // 300ms pre-roll
        }

        let frameSize = vad.frameSampleCount
        var offset = 0

        while offset + frameSize <= samples.count {
            let frame = samples[offset..<(offset + frameSize)]
            let event = vad.process(frame: frame)
            let frameTime = Double(elapsedSamples + offset) / sampleRate

            switch event {
            case .speechStarted:
                // Prepend pre-roll buffer to avoid clipping the start of speech
                speechSamples = preRollBuffer
                speechSamples.append(contentsOf: frame)
                currentUtteranceStartTime = max(0, frameTime - Double(preRollBuffer.count) / sampleRate)
                isCapturing = true

            case .speechEnded:
                if isCapturing {
                    speechSamples.append(contentsOf: frame)
                    let duration = Double(speechSamples.count) / sampleRate
                    // Filter out microscopic acoustic transients (< 0.3s)
                    if duration >= 0.3 {
                        let utterance = speechSamples
                        let start = currentUtteranceStartTime
                        Task { [weak self] in
                            await self?.processUtterance(samples: utterance, sampleRate: sampleRate, start: start, duration: duration)
                        }
                    }
                    speechSamples.removeAll(keepingCapacity: true)
                    isCapturing = false
                }

            case .none:
                if isCapturing {
                    speechSamples.append(contentsOf: frame)
                    // Bound maximum continuous utterance to 30 seconds to prevent OOM / giant payloads
                    let currentDuration = Double(speechSamples.count) / sampleRate
                    if currentDuration >= 30.0 {
                        let utterance = speechSamples
                        let start = currentUtteranceStartTime
                        Task { [weak self] in
                            await self?.processUtterance(samples: utterance, sampleRate: sampleRate, start: start, duration: currentDuration)
                        }
                        speechSamples.removeAll(keepingCapacity: true)
                        currentUtteranceStartTime = frameTime
                    }
                } else {
                    // Update rolling pre-roll buffer during silence
                    preRollBuffer.append(contentsOf: frame)
                    if preRollBuffer.count > preRollMaxSamples {
                        preRollBuffer.removeFirst(preRollBuffer.count - preRollMaxSamples)
                    }
                }
            }

            offset += frameSize
        }

        elapsedSamples += samples.count
    }

    public func finish() async {
        if isCapturing && !speechSamples.isEmpty {
            let duration = Double(speechSamples.count) / currentSampleRate
            if duration >= 0.3 {
                let utterance = speechSamples
                let start = currentUtteranceStartTime
                let rate = currentSampleRate
                await processUtterance(samples: utterance, sampleRate: rate, start: start, duration: duration)
            }
        }
        speechSamples.removeAll()
        preRollBuffer.removeAll()
        continuation.finish()
        log.info("GeminiTranscriber finished")
    }

    // MARK: - API Transmission

    private func processUtterance(
        samples: [Float],
        sampleRate: Double,
        start: TimeInterval,
        duration: TimeInterval
    ) async {
        let wavData = WAVEncoder.encodeFloat32Samples(samples, sourceRate: sampleRate, targetRate: 16_000)
        guard !wavData.isEmpty else { return }

        do {
            let text = try await requestTranscription(wavData: wavData)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            log.info("Gemini transcribed (\(trimmed.count, privacy: .public) chars): \(trimmed, privacy: .public)")
            continuation.yield(TranscriptChunk(
                text: trimmed,
                isFinal: true,
                start: start,
                duration: duration
            ))
        } catch {
            log.error("Gemini transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestTranscription(wavData: Data) async throws -> String {
        let endpoint = baseURL.appending(path: "models/\(model):generateContent")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let prompt = buildPrompt()
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "audio/wav",
                                "data": wavData.base64EncodedString()
                            ]
                        ],
                        [
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 1024
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriberError.networkError("Invalid HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriberError.networkError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        return try parseResponse(data)
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String
        else {
            throw TranscriberError.invalidResponse
        }
        return text
    }

    private func buildPrompt() -> String {
        let language = locale.language.languageCode?.identifier ?? "ja"
        let isJapanese = language == "ja"

        if let custom = customInstruction, !custom.isEmpty {
            return custom
        }

        if isJapanese {
            return """
            You are a high-accuracy speech recognition engine for an AI desktop assistant.
            Instructions:
            1. Transcribe the spoken audio accurately in Japanese.
            2. Output ONLY the plain transcription. Do NOT include quotes, explanations, prefixes, or commentary.
            3. Clean up speech disfluencies and fillers (e.g., 'えーと', 'あのー', 'そのー', 'ええと') so that the transcribed text is clean, crisp, and natural.
            4. Choose appropriate Kanji, punctuation, and terminology based on context. Preserve English technical jargon and product names (e.g., Swift, Mac, GitHub, API, Terminal, Claude, Gemini, Xcode).
            5. If the audio is silent, inaudible, noise, cough, or contains no speech, output nothing (completely empty).
            """
        } else {
            return """
            You are a high-accuracy speech recognition engine for an AI desktop assistant.
            Instructions:
            1. Transcribe the spoken audio accurately in its spoken language.
            2. Output ONLY the plain transcription without quotes, labels, markdown formatting, or introductory phrases.
            3. Clean up filler words (e.g. 'um', 'uh', 'like') smoothly while preserving the speaker's true intent and meaning.
            4. Preserve technical jargon, product names, and proper capitalization.
            5. If the audio contains only silence, background noise, or no intelligible speech, output nothing.
            """
        }
    }
}
