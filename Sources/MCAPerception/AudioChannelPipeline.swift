import Foundation
import MCACore
import MCASensing
import OSLog

/// Drains one capture ring buffer, gates it through VAD, and turns speech into
/// `AudioObservation`s.
///
/// One instance per channel. Running the microphone and the system tap through
/// two independent pipelines is what gives us speaker separation for free: mic
/// is the local user, tap is everyone else. That covers the "me vs them"
/// distinction, which is the part that actually matters for meeting context;
/// separating multiple remote speakers within the tap channel is a further step
/// that needs a diarization model.
public actor AudioChannelPipeline {
    public struct Event: Sendable {
        public var observation: AudioObservation?
        /// Raised the instant speech starts. Drives the HUD listening
        /// indicator. It must NOT close a realtime voice session: the Live
        /// API does server-side barge-in from the forwarded audio instead.
        public var speechStarted: Bool
        public var speechEnded: Bool
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "AudioPipeline")

    private let channel: AudioChannel
    private let ringBuffer: AudioRingBuffer
    private let sampleRate: Double
    private let transcriber: any Transcribing

    private var vad: VoiceActivityDetector
    private var pump: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var residue: [Float] = []
    /// Fan-out for drained PCM (e.g. forwarding mic audio to a realtime voice
    /// session). Invoked synchronously from `drain()` with the same samples
    /// the transcriber receives, so implementations must not block — spawn a
    /// `Task` for any async work.
    private var audioTap: (@Sendable ([Float], Double) -> Void)?

    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    public nonisolated var events: AsyncStream<Event> { stream }

    public init(
        channel: AudioChannel,
        ringBuffer: AudioRingBuffer,
        sampleRate: Double,
        transcriber: any Transcribing
    ) {
        self.channel = channel
        self.ringBuffer = ringBuffer
        self.sampleRate = sampleRate
        self.transcriber = transcriber
        self.vad = VoiceActivityDetector(sampleRate: sampleRate)
        (stream, continuation) = AsyncStream<Event>.makeStream()
    }

    /// Starts draining the ring buffer, then starts the transcriber.
    ///
    /// The order is deliberate and the throw is deliberately late. Drained PCM
    /// feeds two consumers — the transcriber and any `audioTap` — and starting
    /// the transcriber first meant a speech model that could not install took
    /// the pump down with it. The tap is how a realtime voice session hears the
    /// microphone at all, so an on-device transcription failure silently made
    /// voice sessions deaf: connected, billing, and hearing nothing.
    ///
    /// The transcriber's failure is still thrown, so the caller can report it;
    /// it just no longer stops the audio.
    public func start() async throws {
        // 100 ms cadence: long enough that we are not spinning, short enough
        // that VAD onset latency stays inside the barge-in budget when combined
        // with the 30 ms frame size.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        try await transcriber.start()

        let transcriber = self.transcriber
        let channel = self.channel
        let continuation = self.continuation

        // Transcript chunks arrive asynchronously and out of step with VAD, so
        // they get their own forwarding task.
        forwarder = Task {
            for await chunk in await transcriber.results {
                continuation.yield(Event(
                    observation: AudioObservation(
                        timestamp: Date(),
                        channel: channel,
                        speakerID: channel == .microphone ? "me" : nil,
                        text: chunk.text,
                        isFinal: chunk.isFinal,
                        duration: chunk.duration),
                    speechStarted: false,
                    speechEnded: false))
            }
        }
    }

    public func stop() async {
        pump?.cancel()
        forwarder?.cancel()
        pump = nil
        forwarder = nil
        audioTap = nil
        await transcriber.finish()
        continuation.finish()
    }

    /// Sets (or clears) the fan-out tap for drained PCM.
    public func setAudioTap(_ tap: (@Sendable ([Float], Double) -> Void)?) {
        audioTap = tap
    }

    /// Pulls whatever the capture thread has produced, runs VAD over whole
    /// frames, and feeds the transcriber.
    private func drain() async {
        let available = ringBuffer.availableToRead
        guard available > 0 else { return }

        let samples = ringBuffer.read(maxFrames: available)
        guard !samples.isEmpty else { return }

        if ringBuffer.dropped > 0 {
            log.warning("""
                \(self.channel.rawValue, privacy: .public) dropped \
                \(self.ringBuffer.dropped, privacy: .public) frames — consumer is behind
                """)
            ringBuffer.resetDropCount()
        }

        // VAD consumes fixed-size frames; carry the remainder to the next drain
        // so frame boundaries stay aligned across calls.
        residue.append(contentsOf: samples)
        let frameSize = vad.frameSampleCount
        var offset = 0
        while offset + frameSize <= residue.count {
            switch vad.process(frame: residue[offset..<(offset + frameSize)]) {
            case .speechStarted:
                continuation.yield(Event(observation: nil, speechStarted: true, speechEnded: false))
            case .speechEnded:
                continuation.yield(Event(observation: nil, speechStarted: false, speechEnded: true))
            case .none:
                break
            }
            offset += frameSize
        }
        residue.removeFirst(offset)

        // The transcriber gets everything, not just voiced frames: it needs the
        // leading context to segment words correctly, and it does its own
        // endpointing.
        await transcriber.append(samples: samples, sampleRate: sampleRate)

        // Same for any tap (e.g. the realtime voice session, which does its
        // own server-side VAD/endpointing): gating locally would break it.
        if let tap = audioTap {
            tap(samples, sampleRate)
        }
    }

    public var isSpeaking: Bool { vad.isSpeaking }
}
