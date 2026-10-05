import Foundation
import MCACore

/// Which voice mode was used last, and whether the spoken words are captioned,
/// remembered across launches.
///
/// `UserDefaults` rather than `AgentConfiguration`, for the same reason the
/// overlay's placement is: this is a choice the user makes by pressing a button,
/// not policy they edit in a JSON file. A mode that reset to realtime on every
/// launch would quietly put the microphone back on the network for someone who
/// deliberately moved it off — and ⌥⌘V, which repeats whatever was used last,
/// would go with it.
public struct VoicePreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let mode = "voice.mode"
        static let caption = "voice.caption"
        static let engine = "voice.transcriptionEngine"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.caption: true])
    }

    /// The mode last started, which is what ⌥⌘V repeats. Realtime until
    /// something is pressed: it is the mode that answers back out loud, which is
    /// what "talk to the agent" is usually asking for.
    public var mode: VoiceMode {
        get { VoiceMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .realtime }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// On by default. The caption is the only evidence the user has that their
    /// words arrived as they meant them, and it is on screen only while a
    /// session is running — so it costs nothing the rest of the time.
    public var showsCaption: Bool {
        get { defaults.bool(forKey: Key.caption) }
        nonmutating set { defaults.set(newValue, forKey: Key.caption) }
    }

    /// The speech-to-text engine used for dictation and ambient monitoring.
    /// Defaults to .gemini.
    public var engine: TranscriptionEngine {
        get {
            guard let raw = defaults.string(forKey: Key.engine),
                  let parsed = TranscriptionEngine(rawValue: raw) else {
                return .gemini
            }
            return parsed
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.engine) }
    }
}
