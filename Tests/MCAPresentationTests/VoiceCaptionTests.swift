import Foundation
import Testing

@testable import MCACore
@testable import MCAPresentation

/// The caption exists to be readable across a room, on whatever display the
/// user happens to be working on. These assertions pin the two ways that goes
/// wrong: type that does not grow with the screen, and type that grows without
/// limit.
@Suite("Voice caption")
@MainActor
struct VoiceCaptionTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "voice.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A 13" laptop and a 32" display are read from different distances, and a
    /// point size chosen for one is wrong on the other.
    @Test("the caption grows with the display")
    func scalesWithTheScreen() {
        let laptop = VoiceCaptionMetrics.forScreen(width: 1440, height: 900)
        let large = VoiceCaptionMetrics.forScreen(width: 2560, height: 1440)

        #expect(large.fontSize > laptop.fontSize)
        #expect(large.width > laptop.width)
    }

    /// A 6K panel would otherwise be handed 140-point text — a caption that
    /// covers a third of the screen and reads as a bug.
    @Test("a very large display does not get absurd type")
    func clampsAtTheTop() {
        let sixK = VoiceCaptionMetrics.forScreen(width: 6016, height: 3384)

        #expect(sixK.fontSize <= 76)
        #expect(sixK.width <= 1500)
        #expect(sixK.height <= 420)
    }

    @Test("a small display still gets legible type")
    func clampsAtTheBottom() {
        let small = VoiceCaptionMetrics.forScreen(width: 800, height: 480)

        #expect(small.fontSize >= 22)
        #expect(small.width >= 300)
    }

    /// A band across the screen, not a box in the corner — but never wider than
    /// the screen it sits on.
    @Test("the caption always fits the screen it is on")
    func fitsWithinTheScreen() {
        for (width, height) in [(1280.0, 800.0), (1920.0, 1080.0), (3840.0, 2160.0)] {
            let metrics = VoiceCaptionMetrics.forScreen(width: width, height: height)
            #expect(metrics.width <= width)
            #expect(metrics.height + metrics.bottomInset <= height)
        }
    }

    /// Nonsense in — a display reporting a zero-sized frame during a
    /// reconfiguration — must not produce a zero-sized caption.
    @Test("a degenerate screen size does not produce an invisible caption")
    func survivesNonsenseInput() {
        let metrics = VoiceCaptionMetrics.forScreen(width: 0, height: 0)
        #expect(metrics.fontSize >= 22)
        #expect(metrics.width >= 300)
        #expect(metrics.height >= 140)
    }

    // MARK: - Mode

    /// Realtime streams the microphone to Google; dictation does not. A mode
    /// that reset on relaunch would quietly put the audio back on the network
    /// for someone who deliberately moved it off.
    @Test("the chosen mode survives a relaunch")
    func modePersists() {
        let defaults = freshDefaults()
        VoicePreferences(defaults: defaults).mode = .dictation
        #expect(VoicePreferences(defaults: defaults).mode == .dictation)
    }

    @Test("the voice button starts a live conversation by default")
    func realtimeIsTheDefault() {
        #expect(VoicePreferences(defaults: freshDefaults()).mode == .realtime)
        #expect(HUDState().voiceMode == .realtime)
    }

    @Test("the caption is on by default")
    func captionIsOnByDefault() {
        #expect(VoicePreferences(defaults: freshDefaults()).showsCaption == true)
    }

    /// The dictation path revises the whole utterance in place. Appending its
    /// output would repeat every word each time the engine changed its mind
    /// about the last one.
    @Test("dictation replaces the caption rather than appending to it")
    func dictationReplacesTheTranscript() {
        let state = HUDState()
        state.setVoiceTranscript(settled: "open the")
        state.setVoiceTranscript(settled: "open the file")

        #expect(state.voiceTranscript == "open the file")
    }

    /// The caption draws the two halves differently, so they have to arrive
    /// apart. Concatenating them upstream would leave the view unable to tell
    /// "this is what you said" from "this is what you might be saying".
    @Test("settled and in-progress text stay separable")
    func pendingTextIsKeptApart() {
        let state = HUDState()
        state.setVoiceTranscript(settled: "rename ", pending: "this fi")

        #expect(state.voiceTranscriptSettled == "rename ")
        #expect(state.voiceTranscriptPending == "this fi")
        #expect(state.voiceTranscript == "rename this fi")

        // A revision replaces the guess wholesale rather than growing it.
        state.setVoiceTranscript(settled: "rename ", pending: "this file")
        #expect(state.voiceTranscript == "rename this file")
    }

    /// The realtime path is the opposite: the server sends the utterance in
    /// pieces and the client assembles them.
    @Test("realtime chunks are assembled into one utterance")
    func realtimeAppendsChunks() {
        let state = HUDState()
        state.appendUserSpeech("what is ")
        state.appendUserSpeech("on my screen")

        #expect(state.voiceTranscript == "what is on my screen")
    }

    /// The searches belonged to the answer to the last thing said. Carrying
    /// them into the next question credits an answer with lookups it never
    /// made.
    @Test("a new utterance forgets the last turn's searches")
    func searchesAreClearedOnANewUtterance() {
        let state = HUDState()
        state.appendUserSpeech("when did it ship")
        state.voiceSearchQueries = ["mac mini m5 release date"]
        state.endVoiceTurn()

        state.appendUserSpeech("and how much")
        #expect(state.voiceSearchQueries.isEmpty)
    }

    @Test("ending a session clears everything the caption was showing")
    func endingClearsTheCaption() {
        let state = HUDState()
        state.voicePhase = .live
        state.appendUserSpeech("hello")
        state.voiceSearchQueries = ["something"]

        state.endVoiceSession()

        #expect(state.voicePhase == .off)
        #expect(state.voiceTranscript.isEmpty)
        #expect(state.voiceSearchQueries.isEmpty)
    }

    @Test("setting transcript with cumulative pending strips the duplicate settled prefix")
    func setVoiceTranscriptDeduplicatesPending() {
        let state = HUDState()
        state.setVoiceTranscript(
            settled: "日本語 (ja-US) で聞き取ります。",
            pending: "日本語 (ja-US) で聞き取ります。質問を声に出して話してください。")

        #expect(state.voiceTranscriptSettled == "日本語 (ja-US) で聞き取ります。")
        #expect(state.voiceTranscriptPending == "質問を声に出して話してください。")
        #expect(state.voiceTranscript == "日本語 (ja-US) で聞き取ります。質問を声に出して話してください。")
    }
}
