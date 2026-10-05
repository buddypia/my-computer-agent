import Foundation

/// Frame-level voice activity detection with an adaptive noise floor.
///
/// Purpose-built for the barge-in path, so it is deliberately cheap and
/// allocation-free: the decision has to be available within one 30 ms frame of
/// the user starting to speak, because that decision is what cancels in-flight
/// TTS. A neural VAD would be more accurate but adds model latency to exactly
/// the path that cannot afford it.
///
/// Hysteresis (separate onset/offset thresholds plus hang-over) is what stops
/// the detector chattering on the gaps between words.
public struct VoiceActivityDetector: Sendable {
    public struct Configuration: Sendable {
        /// Analysis frame length. 30 ms is the usual VAD granularity.
        public var frameDuration: Double = 0.030
        /// How far above the noise floor counts as speech starting (dB).
        public var onsetMarginDB: Float = 9
        /// How far above the noise floor still counts as speech continuing (dB).
        /// Lower than onset, which is the hysteresis.
        public var offsetMarginDB: Float = 5
        /// Keep the "speaking" state this long after the level drops, so short
        /// pauses between words do not end the utterance.
        public var hangoverDuration: Double = 0.45
        /// Utterances shorter than this are discarded as clicks or coughs.
        public var minimumSpeechDuration: Double = 0.20
        /// How quickly the noise floor tracks the ambient level.
        public var noiseFloorAdaptation: Float = 0.05
        /// Absolute floor so a silent room does not drive the threshold to zero.
        public var minimumNoiseFloorDB: Float = -60

        public init() {}
    }

    public enum Transition: Sendable, Equatable {
        case speechStarted
        case speechEnded(duration: Double)
        case none
    }

    public private(set) var isSpeaking = false
    public private(set) var noiseFloorDB: Float
    public private(set) var currentLevelDB: Float = -120

    private let config: Configuration
    private let sampleRate: Double
    private var hangoverRemaining: Double = 0
    private var speechDuration: Double = 0

    public init(sampleRate: Double, configuration: Configuration = Configuration()) {
        self.sampleRate = sampleRate
        self.config = configuration
        self.noiseFloorDB = configuration.minimumNoiseFloorDB
    }

    public var frameSampleCount: Int {
        Int(config.frameDuration * sampleRate)
    }

    /// Feeds exactly one frame. Returns the state transition, if any.
    public mutating func process(frame: ArraySlice<Float>) -> Transition {
        guard !frame.isEmpty else { return .none }

        var sumSquares: Float = 0
        for sample in frame { sumSquares += sample * sample }
        let rms = (sumSquares / Float(frame.count)).squareRoot()
        let levelDB = rms > 0 ? 20 * log10(rms) : -120
        currentLevelDB = levelDB

        let frameDuration = Double(frame.count) / sampleRate

        // Only let the noise floor track *downward-ish* levels; adapting it
        // during speech would make the detector deaf to a steady talker.
        if !isSpeaking {
            let target = max(levelDB, config.minimumNoiseFloorDB)
            noiseFloorDB += (target - noiseFloorDB) * config.noiseFloorAdaptation
            noiseFloorDB = max(noiseFloorDB, config.minimumNoiseFloorDB)
        }

        if isSpeaking {
            speechDuration += frameDuration
            if levelDB > noiseFloorDB + config.offsetMarginDB {
                hangoverRemaining = config.hangoverDuration
            } else {
                hangoverRemaining -= frameDuration
                if hangoverRemaining <= 0 {
                    isSpeaking = false
                    let total = speechDuration - config.hangoverDuration
                    speechDuration = 0
                    return total >= config.minimumSpeechDuration
                        ? .speechEnded(duration: total)
                        : .none
                }
            }
            return .none
        }

        if levelDB > noiseFloorDB + config.onsetMarginDB {
            isSpeaking = true
            hangoverRemaining = config.hangoverDuration
            speechDuration = frameDuration
            return .speechStarted
        }
        return .none
    }

    /// Convenience for a whole buffer; splits into frames internally.
    public mutating func process(buffer: [Float]) -> [Transition] {
        let size = frameSampleCount
        guard size > 0 else { return [] }
        var transitions: [Transition] = []
        var offset = 0
        while offset + size <= buffer.count {
            let t = process(frame: buffer[offset..<(offset + size)])
            if t != .none { transitions.append(t) }
            offset += size
        }
        return transitions
    }
}
