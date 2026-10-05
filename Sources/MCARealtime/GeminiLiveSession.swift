import Foundation
import MCACore
import MCAReasoning
import OSLog

/// A live, bidirectional voice conversation with Gemini.
///
/// This is the *opt-in* half of the audio design. The always-on path keeps
/// every sample on the machine; this one streams PCM to Google, and is entered
/// only when the user deliberately starts a conversation.
///
/// The trade is worth making at that moment and only at that moment: the Live
/// API does VAD, endpointing, barge-in, transcription and native speech output
/// server-side over one socket, which is both better and far less code than
/// assembling the same thing locally. Running it continuously instead would
/// bill audio tokens around the clock and put the user's entire acoustic
/// environment on the network.
public actor GeminiLiveSession {
    public enum Event: Sendable {
        case connected
        case userTranscript(String)
        case modelTranscript(String)
        /// The model looked something up on the web before answering. Carries
        /// the queries it ran, which is the only account of where a spoken
        /// answer came from that the user ever gets.
        case searchedWeb([String])
        /// 24 kHz signed 16-bit PCM for playback.
        case audioOutput(Data)
        /// The user started speaking over the model. Playback must be flushed
        /// immediately — anything already queued is now stale.
        case interrupted
        case turnComplete
        case closed(CloseCause)
    }

    /// Why a session ended.
    ///
    /// The distinction is the whole point of this type. Both outcomes used to
    /// arrive as one `closed(reason:)`, so the UI treated them alike and simply
    /// switched the voice button back off — which is right for a user who
    /// pressed stop, and useless for a session that never opened. Pressing the
    /// button and watching it flip back with nothing said is indistinguishable
    /// from the button not working.
    public enum CloseCause: Sendable, Equatable {
        /// The client asked to end the session.
        case endedByUser
        /// The handshake, the socket, or the server ended it. The string is the
        /// reason as it arrived and is shown to the user verbatim.
        case failure(String)
    }

    public enum SessionError: Error, CustomStringConvertible {
        case notConnected
        case setupFailed(String)

        public var description: String {
            switch self {
            case .notConnected: return "Live session is not connected"
            case .setupFailed(let m): return "Live session setup failed: \(m)"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Live")

    private let model: String
    private let apiKey: String
    private let systemInstruction: String
    /// Whether the model may search the web mid-conversation.
    private let webSearchEnabled: Bool
    /// The Live API expects 16 kHz mono PCM on input; output arrives at 24 kHz.
    public static let inputSampleRate: Double = 16_000
    public static let outputSampleRate: Double = 24_000

    /// How long the server has to acknowledge the setup frame.
    ///
    /// Bounded because failing here is the ordinary case rather than the exotic
    /// one: a retired preview model ID, or a key without Live API access, is
    /// refused during setup. Without a deadline the session sits in "connecting"
    /// forever, which looks exactly like a hang.
    private static let setupTimeoutSeconds: Double = 15

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var setupWatchdog: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    /// Whether the server has sent `setupComplete`. Until it has, nothing sent
    /// on this socket lands anywhere.
    private var isConnected = false

    public init(
        model: String = "gemini-3.1-flash-live-preview",
        apiKey: String,
        systemInstruction: String = Prompts.live,
        webSearchEnabled: Bool = true
    ) {
        self.model = model
        self.apiKey = apiKey
        self.systemInstruction = systemInstruction
        self.webSearchEnabled = webSearchEnabled
    }

    public func connect() throws -> AsyncStream<Event> {
        guard !apiKey.isEmpty else {
            throw LanguageModelError.missingCredentials(provider: "gemini")
        }

        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/"
                + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        let socket = URLSession.shared.webSocketTask(with: components.url!)
        // Keep frames small enough that a burst of audio does not stall the
        // socket's send queue.
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        self.task = socket

        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation

        receiveLoop = Task { await self.receive() }
        setupWatchdog = Task { await self.performSetup() }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.close() }
        }
        return stream
    }

    /// Sends the setup frame and holds the session to a deadline for the reply.
    ///
    /// The failure to send used to be swallowed by a `try?`, which left a socket
    /// open that the server would never answer — the visible result being a
    /// voice button that turned itself off a moment later, for no stated reason.
    private func performSetup() async {
        do {
            try await sendSetup()
        } catch {
            finish(.failure("the setup frame could not be sent: \(error.localizedDescription)"))
            return
        }

        try? await Task.sleep(for: .seconds(Self.setupTimeoutSeconds))
        guard !Task.isCancelled, !isConnected else { return }
        finish(.failure("""
            the server did not confirm the session within \
            \(Int(Self.setupTimeoutSeconds))s — check that the model '\(model)' still exists \
            and that this API key has Live API access
            """))
    }

    private func sendSetup() async throws {
        try await send(json: Self.setupPayload(
            model: model,
            systemInstruction: systemInstruction,
            webSearchEnabled: webSearchEnabled))
    }

    /// The setup frame, built separately from the socket that sends it.
    ///
    /// Split out to be testable: this frame is the entire negotiation, and the
    /// server's answer to a malformed one is a close code rather than an error
    /// message — so a missing field shows up as "the voice button does not
    /// work" with nothing written down anywhere.
    static func setupPayload(
        model: String,
        systemInstruction: String,
        webSearchEnabled: Bool
    ) -> [String: Any] {
        var setup: [String: Any] = [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                // Minimal thinking: this path is optimised for turn latency,
                // not for depth. Hard questions belong on the text route.
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            // Transcripts of both sides so the HUD can show the
            // conversation and the store can keep it.
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
        ]

        // Server-side search, executed inside the model's turn. Worth the
        // latency it adds: a spoken assistant that can only answer from
        // training data is confidently wrong about anything current, and in a
        // voice conversation there is no link to click and no way for the user
        // to tell which kind of answer they just got.
        if webSearchEnabled {
            setup["tools"] = [["googleSearch": [String: Any]()]]
        }

        return ["setup": setup]
    }

    /// Streams captured microphone audio. Expects 16 kHz mono Int16.
    public func sendAudio(_ pcm: Data) async {
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcm.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=\(Int(Self.inputSampleRate))",
                ]
            ]
        ]
        try? await send(json: message)
    }

    /// Seeds the conversation with desktop context before the user speaks.
    public func sendContext(_ text: String) async {
        let message: [String: Any] = [
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": false,
            ]
        ]
        try? await send(json: message)
    }

    public func close() {
        finish(.endedByUser)
    }

    /// Tears the session down exactly once and says why.
    ///
    /// Every exit — the user pressing stop, a setup timeout, a socket error —
    /// goes through here, so a session can never end without the reason reaching
    /// the consumer.
    private func finish(_ cause: CloseCause) {
        guard let continuation else { return }
        // The handshake URL carries the API key in its query string (the Live
        // API takes no other form of auth on this socket), and URL-bearing
        // errors are exactly what ends up in `cause`. Everything that leaves
        // this type — to the UI, to a log — is scrubbed here.
        let cause: CloseCause = switch cause {
        case .failure(let reason): .failure(Self.redact(reason, apiKey: apiKey))
        case .endedByUser: cause
        }
        self.continuation = nil
        isConnected = false

        setupWatchdog?.cancel()
        setupWatchdog = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: Data("closed by client".utf8))
        task = nil

        continuation.yield(.closed(cause))
        continuation.finish()
    }

    // MARK: - Socket plumbing

    private func send(json: [String: Any]) async throws {
        guard let task else { throw SessionError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: json)
        try await task.send(.data(data))
    }

    private func receive() async {
        guard let task else { return }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard !Task.isCancelled else { return }
                log.info("Live socket closed: \(Self.redact(error.localizedDescription, apiKey: self.apiKey), privacy: .public)")
                finish(.failure(Self.describe(error, closing: task)))
                return
            }

            let data: Data
            switch message {
            case .data(let payload): data = payload
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { continue }

            // A rejected setup can arrive as a frame rather than as a close,
            // and it is the only place the actual cause is written down.
            if let failure = json["error"] as? [String: Any] {
                let message = failure["message"] as? String ?? String(describing: failure)
                finish(.failure(message))
                return
            }

            if json["setupComplete"] != nil, !isConnected {
                isConnected = true
                setupWatchdog?.cancel()
                setupWatchdog = nil
                continuation?.yield(.connected)
                continue
            }

            guard let serverContent = json["serverContent"] as? [String: Any] else {
                continue
            }

            // Order matters: report the interruption before anything else in
            // the frame, so the player flushes stale audio first.
            if serverContent["interrupted"] as? Bool == true {
                continuation?.yield(.interrupted)
            }

            // Reported before the transcript it explains, so the caption can
            // show "looking this up" while the answer is still being spoken
            // rather than after it has finished.
            let queries = Self.searchQueries(in: serverContent)
            if !queries.isEmpty {
                continuation?.yield(.searchedWeb(queries))
            }

            if let transcription = serverContent["inputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String, !text.isEmpty {
                continuation?.yield(.userTranscript(text))
            }
            if let transcription = serverContent["outputTranscription"] as? [String: Any],
               let text = transcription["text"] as? String, !text.isEmpty {
                continuation?.yield(.modelTranscript(text))
            }

            // A single frame can carry several parts; process all of them.
            if let turn = serverContent["modelTurn"] as? [String: Any],
               let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let encoded = inline["data"] as? String,
                       let audio = Data(base64Encoded: encoded) {
                        continuation?.yield(.audioOutput(audio))
                    }
                    if let text = part["text"] as? String, !text.isEmpty {
                        continuation?.yield(.modelTranscript(text))
                    }
                }
            }

            if serverContent["turnComplete"] as? Bool == true {
                continuation?.yield(.turnComplete)
            }
        }
    }

    /// What the model searched for, if this frame says it searched at all.
    ///
    /// The grounding block rides along with whichever frame the model happened
    /// to attach it to, and it is absent from every other frame in the turn — so
    /// this reads it wherever it lands rather than expecting a particular one.
    /// It can also arrive on the turn's `modelTurn` rather than on the server
    /// content itself, which is why both are checked.
    static func searchQueries(in serverContent: [String: Any]) -> [String] {
        let containers = [
            serverContent["groundingMetadata"] as? [String: Any],
            (serverContent["modelTurn"] as? [String: Any])?["groundingMetadata"]
                as? [String: Any],
        ]
        for container in containers.compactMap({ $0 }) {
            if let queries = container["webSearchQueries"] as? [String], !queries.isEmpty {
                return queries
            }
        }
        return []
    }

    /// Masks the API key in `text`: the literal key wherever it appears, and the
    /// value of any `key=` query parameter, which covers a URL that was
    /// percent-encoded or rewritten on its way into an error message.
    static func redact(_ text: String, apiKey: String) -> String {
        var result = text
        if !apiKey.isEmpty {
            result = result.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        }
        if let regex = try? NSRegularExpression(pattern: #"([?&]key=)[^&\s"'<>)]+"#, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1[REDACTED]")
        }
        return result
    }

    /// The most specific description of a socket failure available.
    ///
    /// The Live API refuses a bad model ID or a key without Live access in the
    /// WebSocket close frame rather than in a message, so the close reason is
    /// often the only account of the failure that exists. `URLError` on its own
    /// yields "Socket is not connected", which names no cause at all.
    private static func describe(
        _ error: Error, closing task: URLSessionWebSocketTask
    ) -> String {
        let code = task.closeCode
        guard code != .invalid else { return error.localizedDescription }

        let reason = task.closeReason
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty
            ? "the server closed the session (code \(code.rawValue))"
            : "\(reason) (close code \(code.rawValue))"
    }
}

public enum Prompts {
    public static let live = """
        You are a desktop copilot in a live voice conversation. Keep replies to \
        one or two sentences unless asked for detail — you are speaking, not \
        writing. Never read code aloud; say that you have put it on screen \
        instead.

        You can search the web. Use it whenever the answer depends on something \
        current, specific or checkable — prices, versions, releases, news, \
        documentation, anything dated after your training — rather than \
        answering from memory and hoping. Say in passing that you looked it up \
        and name the source when it matters; the user is listening, not reading, \
        and has no link to click.

        If you do not know something and cannot find it, say so immediately.
        """
}

/// Converts between the Float32 the capture layer produces and the Int16 PCM
/// the Live API expects.
public enum PCMConverter {
    public static func float32ToInt16(_ samples: [Float]) -> Data {
        var output = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        return output
    }

    public static func int16ToFloat32(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let base = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(base[$0]) / Float(Int16.max) }
        }
    }

    /// Naive linear resampling. Adequate for speech at these ratios and, unlike
    /// pulling in a full SRC, free of dependencies.
    public static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, from != to, !samples.isEmpty else { return samples }
        let ratio = to / from
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }

        return (0..<outputCount).map { index in
            let position = Double(index) / ratio
            let low = Int(position)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            return samples[low] * (1 - fraction) + samples[high] * fraction
        }
    }
}
