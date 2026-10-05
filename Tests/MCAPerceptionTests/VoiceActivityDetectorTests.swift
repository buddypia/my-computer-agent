import Foundation
import MCACore
import Testing

@testable import MCAPerception

@Suite("Voice activity detection")
struct VoiceActivityDetectorTests {
    static let sampleRate: Double = 16_000

    /// White-ish noise at a given amplitude, deterministic so failures reproduce.
    static func noise(amplitude: Float, seconds: Double, seed: UInt64 = 42) -> [Float] {
        var generator = SplitMix64(seed: seed)
        return (0..<Int(seconds * sampleRate)).map { _ in
            (Float(generator.nextUnitInterval()) * 2 - 1) * amplitude
        }
    }

    @Test("silence never triggers")
    func silenceIsQuiet() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        let transitions = detector.process(buffer: Self.noise(amplitude: 0.0005, seconds: 3))

        #expect(transitions.isEmpty)
        #expect(!detector.isSpeaking)
    }

    @Test("loud speech after quiet triggers an onset")
    func detectsOnset() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        // Let the noise floor settle first, as it would in a real room.
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 2))

        let transitions = detector.process(buffer: Self.noise(amplitude: 0.3, seconds: 1))
        #expect(transitions.contains(.speechStarted))
        #expect(detector.isSpeaking)
    }

    @Test("speech ends only after the hang-over expires")
    func detectsOffsetAfterHangover() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 2))
        _ = detector.process(buffer: Self.noise(amplitude: 0.3, seconds: 1))
        #expect(detector.isSpeaking)

        // Shorter than the hang-over: a pause between words, not an ending.
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 0.2))
        #expect(detector.isSpeaking, "a 200 ms gap must not end the utterance")

        let transitions = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 1))
        #expect(transitions.contains {
            if case .speechEnded = $0 { return true } else { return false }
        })
        #expect(!detector.isSpeaking)
    }

    @Test("hysteresis prevents chattering at the threshold")
    func hysteresisPreventsChatter() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 2))

        var transitionCount = 0
        // Amplitude hovering right around the decision boundary. Without
        // separate onset/offset thresholds this produces a burst of spurious
        // transitions — and every one of them would cancel the model's speech.
        for round in 0..<20 {
            let amplitude: Float = round.isMultiple(of: 2) ? 0.004 : 0.0035
            transitionCount += detector.process(
                buffer: Self.noise(amplitude: amplitude, seconds: 0.1, seed: UInt64(round))).count
        }
        #expect(transitionCount <= 2, "expected stability, saw \(transitionCount) transitions")
    }

    @Test("clicks shorter than the minimum are discarded")
    func rejectsShortBursts() {
        var config = VoiceActivityDetector.Configuration()
        config.minimumSpeechDuration = 0.5
        config.hangoverDuration = 0.1

        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate, configuration: config)
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 2))

        // 60 ms burst: a keystroke or a cough, not an utterance.
        _ = detector.process(buffer: Self.noise(amplitude: 0.4, seconds: 0.06))
        let transitions = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 1))

        #expect(!transitions.contains {
            if case .speechEnded = $0 { return true } else { return false }
        })
    }

    @Test("adapts to a loud room")
    func adaptsToNoiseFloor() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        let quietFloor = detector.noiseFloorDB

        _ = detector.process(buffer: Self.noise(amplitude: 0.05, seconds: 5))
        // A fan or air conditioning must raise the bar rather than register as
        // continuous speech.
        #expect(detector.noiseFloorDB > quietFloor)
    }

    @Test("frame size follows the sample rate")
    func frameSizeScales() {
        #expect(VoiceActivityDetector(sampleRate: 16_000).frameSampleCount == 480)
        #expect(VoiceActivityDetector(sampleRate: 48_000).frameSampleCount == 1440)
    }

    @Test("onset latency stays inside the barge-in budget")
    func onsetLatencyIsBounded() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        _ = detector.process(buffer: Self.noise(amplitude: 0.001, seconds: 2))

        // Feed frame by frame and count how many pass before onset fires. The
        // barge-in path budgets 100 ms; at 30 ms per frame that is three.
        let loud = Self.noise(amplitude: 0.3, seconds: 0.5)
        let frameSize = detector.frameSampleCount
        var framesUntilOnset = 0

        var offset = 0
        while offset + frameSize <= loud.count {
            framesUntilOnset += 1
            if detector.process(frame: loud[offset..<(offset + frameSize)]) == .speechStarted {
                break
            }
            offset += frameSize
        }
        #expect(framesUntilOnset <= 3, "onset took \(framesUntilOnset) frames")
    }

    @Test("an empty frame is a no-op")
    func emptyFrame() {
        var detector = VoiceActivityDetector(sampleRate: Self.sampleRate)
        #expect(detector.process(frame: [][...]) == .none)
    }
}

/// Deterministic PRNG so audio fixtures are reproducible across runs.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
