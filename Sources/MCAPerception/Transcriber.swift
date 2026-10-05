@preconcurrency import AVFoundation
import Foundation
import MCACore
import OSLog
import Speech

/// A streaming speech-to-text engine.
///
/// Exists as a protocol so the on-device engine can be swapped — for a CoreML
/// Parakeet model, or for `gemini-3.5-transcribe-live` when the user opts into
/// cloud transcription — without anything upstream changing.
public protocol Transcribing: Actor {
    /// Continuous transcripts. Non-final entries are revisions in progress.
    var results: AsyncStream<TranscriptChunk> { get }
    func start() async throws
    func append(samples: [Float], sampleRate: Double) async
    func finish() async
}

public struct TranscriptChunk: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(text: String, isFinal: Bool, start: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.duration = duration
    }
}

/// On-device transcription via Apple's `SpeechAnalyzer` (macOS 26+).
///
/// Chosen over a bundled CoreML model for the default path because the model is
/// downloaded and updated by the OS, costs no app bundle size, runs on the ANE,
/// and — the part that matters for this app — never puts audio on the network.
public actor SpeechAnalyzerTranscriber: Transcribing {
    public enum TranscriberError: Error, CustomStringConvertible {
        case unavailable
        case localeUnsupported(String)
        case assetInstallationFailed(String)
        case formatUnavailable

        public var description: String {
            switch self {
            case .unavailable:
                return "SpeechTranscriber is unavailable on this device"
            case .localeUnsupported(let l):
                return "Locale \(l) is not supported for on-device transcription"
            case .assetInstallationFailed(let m):
                return "Speech model download failed: \(m)"
            case .formatUnavailable:
                return "No compatible audio format for the transcriber"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Transcriber")
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSourceRate: Double = 0
    private var resultsTask: Task<Void, Never>?

    private let stream: AsyncStream<TranscriptChunk>
    private let continuation: AsyncStream<TranscriptChunk>.Continuation

    public nonisolated var results: AsyncStream<TranscriptChunk> { stream }

    public init(locale: Locale = Locale.current) {
        self.locale = locale
        (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
    }

    public func start() async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeUnsupported(locale.identifier)
        }

        // `.progressiveTranscription` gives revisions as the user speaks, which
        // the HUD needs. Finality is derived below rather than guessed.
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        self.transcriber = transcriber

        // The locale model is an OS-managed asset; it may need downloading on
        // first run. This is slow but happens once.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]) {
                    log.info("Downloading speech model for \(supported.identifier, privacy: .public)")
                    try await request.downloadAndInstall()
                }
            } catch {
                throw TranscriberError.assetInstallationFailed(error.localizedDescription)
            }
        }
        _ = try? await AssetInventory.reserve(locale: supported)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw TranscriberError.formatUnavailable
        }
        analyzerFormat = format

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputStream)

        let continuation = self.continuation
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    // `resultsFinalizationTime` is the point through which the
                    // engine considers results settled. A chunk ending at or
                    // before it will not be revised again.
                    let end = result.range.end
                    let isFinal = CMTimeCompare(end, result.resultsFinalizationTime) <= 0

                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    continuation.yield(TranscriptChunk(
                        text: text,
                        isFinal: isFinal,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds))
                }
            } catch {
                self.log.error("Transcriber result stream ended: \(error.localizedDescription, privacy: .public)")
            }
            continuation.finish()
        }

        log.info("SpeechAnalyzer started for \(supported.identifier, privacy: .public)")
    }

    public func append(samples: [Float], sampleRate: Double) async {
        guard let inputContinuation, let analyzerFormat, !samples.isEmpty else { return }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count))
        else { return }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        // Fast path: the capture rate already matches what the model wants.
        if sourceFormat.sampleRate == analyzerFormat.sampleRate,
           sourceFormat.channelCount == analyzerFormat.channelCount,
           sourceFormat.commonFormat == analyzerFormat.commonFormat {
            inputContinuation.yield(AnalyzerInput(buffer: sourceBuffer))
            return
        }

        // Otherwise resample. The converter is stateful, so it is reused across
        // calls; recreating it per buffer would introduce clicks at the seams.
        if converter == nil || converterSourceRate != sampleRate {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            converterSourceRate = sampleRate
        }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = sourceBuffer
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let error {
            log.debug("Resample failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard outputBuffer.frameLength > 0 else { return }
        inputContinuation.yield(AnalyzerInput(buffer: outputBuffer))
    }

    /// Whether this Mac can transcribe a given language, and whether it can do
    /// it right now.
    ///
    /// Three answers rather than a boolean because the middle one is the common
    /// case on a fresh install and the only one the user can do something about
    /// by waiting: the locale is supported, but its model has not been
    /// downloaded yet, so the first session in that language stalls while the OS
    /// fetches it. Reported in Settings so the stall is expected rather than
    /// discovered as a voice mode that appears to hang.
    public enum LocaleAvailability: Sendable, Equatable {
        case installed
        case downloadable
        case unsupported
    }

    public static func availability(of locale: Locale) async -> LocaleAvailability {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return .unsupported }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [transcriber]) == .installed
            ? .installed
            : .downloadable
    }

    public func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        continuation.finish()
    }
}
