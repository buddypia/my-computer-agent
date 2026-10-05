import AVFoundation
import Foundation
import MCACore
import OSLog

/// Captures the local microphone with hardware acoustic echo cancellation.
///
/// AEC matters more here than in a normal recording app: we tap system audio at
/// the same time, so without cancellation the meeting participants' voices leak
/// back through the speakers into the mic and get transcribed twice — once on
/// the tap channel and once, garbled, on the mic channel.
///
/// `setVoiceProcessingEnabled(true)` puts the input node behind Apple's
/// VoiceProcessingIO audio unit, which performs echo cancellation, noise
/// suppression and AGC on the hardware path.
public final class MicrophoneCapture: @unchecked Sendable {
    public enum MicError: Error, CustomStringConvertible {
        case voiceProcessingUnavailable(Error)
        case engineStart(Error)
        case noInputChannels
        case permissionNotGranted(String)

        public var description: String {
            switch self {
            case .voiceProcessingUnavailable(let e):
                return "Could not enable voice processing (AEC): \(e.localizedDescription)"
            case .engineStart(let e):
                return "Audio engine failed to start: \(e.localizedDescription)"
            case .noInputChannels:
                return "Default input device reports zero channels"
            case .permissionNotGranted(let detail):
                return "Microphone permission \(detail)"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Microphone")
    private let engine = AVAudioEngine()

    public let ringBuffer = AudioRingBuffer(capacity: 48_000 * 4)
    public private(set) var sampleRate: Double = 48_000
    /// True when hardware AEC is actually engaged. If this is false the tap and
    /// mic channels will cross-contaminate and the caller should say so.
    public private(set) var echoCancellationActive = false

    private var isRunning = false

    public init() {}

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }

        // Checked up front because `AVAudioEngine` does not fail cleanly
        // without this permission — it blocks indefinitely inside CoreAudio
        // rather than throwing, which turns a missing checkbox in System
        // Settings into an apparent hang with no diagnostic.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied:
            throw MicError.permissionNotGranted(
                "denied — enable it in System Settings ▸ Privacy & Security ▸ Microphone")
        case .restricted:
            throw MicError.permissionNotGranted("restricted by policy")
        case .notDetermined:
            throw MicError.permissionNotGranted(
                "not yet granted — answer the prompt, then restart")
        @unknown default:
            throw MicError.permissionNotGranted("in an unknown state")
        }

        let input = engine.inputNode

        // Enable AEC before touching the format — toggling voice processing
        // reconfigures the node's format.
        do {
            try input.setVoiceProcessingEnabled(true)
            echoCancellationActive = true
        } catch {
            // Degrade rather than fail: mono transcription without AEC is still
            // useful, but the caller must surface it.
            echoCancellationActive = false
            log.warning("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw MicError.noInputChannels }
        sampleRate = format.sampleRate

        let ring = ringBuffer
        let channels = Int(format.channelCount)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            if channels == 1 {
                ring.write(UnsafeBufferPointer(start: channelData[0], count: frames))
            } else {
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { mono in
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += channelData[c][f] }
                        mono[f] = sum / Float(channels)
                    }
                    ring.write(UnsafeBufferPointer(start: mono.baseAddress!, count: frames))
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicError.engineStart(error)
        }

        isRunning = true
        log.info("""
            Microphone started at \(self.sampleRate, privacy: .public) Hz, \
            AEC=\(self.echoCancellationActive, privacy: .public)
            """)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        log.info("Microphone stopped")
    }
}
