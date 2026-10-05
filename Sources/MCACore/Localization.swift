import Foundation
import Observation

/// A language the app ships strings for.
///
/// Three, written as a triple at each call site rather than pulled from a
/// `.strings` catalogue. The pair this replaced was justified by the pair being
/// small enough to read inline; a triple is still small enough, and the reason
/// to keep the strings next to the code that shows them has not changed — most
/// of them are load-bearing explanations, not labels. A fourth language is the
/// point at which this should become a table lookup instead.
public enum Language: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    /// What to show in a picker, in that language's own words. A language list
    /// written in the language you cannot read is useless to the one person who
    /// needs it.
    public var endonym: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    /// Picks one of three strings, without going through `Localization`.
    ///
    /// For the code that holds its own copy of the language — the reasoning
    /// actor, which is not on the main actor and must not hop to it to decide
    /// what to write in a fallback message.
    public func choose(_ english: String, _ japanese: String, _ korean: String) -> String {
        switch self {
        case .english: return english
        case .japanese: return japanese
        case .korean: return korean
        }
    }

    /// The locale handed to on-device speech recognition.
    ///
    /// Region-qualified because `SpeechTranscriber.supportedLocale(equivalentTo:)`
    /// matches against installed locale assets, and a bare `"ja"` is not one of
    /// them.
    public var speechLocale: Locale {
        switch self {
        case .english: return Locale(identifier: "en-US")
        case .japanese: return Locale(identifier: "ja-JP")
        case .korean: return Locale(identifier: "ko-KR")
        }
    }
}

/// What the user picked, which is not the same thing as what gets drawn:
/// `.automatic` is resolved against the system's language list at read time.
public enum LanguagePreference: String, CaseIterable, Codable, Sendable {
    case automatic
    case english
    case japanese
    case korean

    public var title: LocalizedText {
        switch self {
        case .automatic: return ("Match macOS", "macOS に合わせる", "macOS 설정 따르기")
        case .english: return ("English", "English", "English")
        case .japanese: return ("日本語", "日本語", "日本語")
        case .korean: return ("한국어", "한국어", "한국어")
        }
    }

    /// Resolves to one of the languages that actually exist.
    ///
    /// Matches on the language code alone: `ja-JP` and `ja` are the same choice
    /// here, and there is nothing regional to tell apart. Anything the app does
    /// not ship strings for falls to English, because that is the language every
    /// other string in the interface can be read against.
    public func resolved(
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> Language {
        switch self {
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .automatic:
            for identifier in systemLanguages {
                guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                      let match = Language(rawValue: code)
                else { continue }
                return match
            }
            return .english
        }
    }
}

/// Which language the on-device transcriber is told to expect.
///
/// Separate from the interface language because the two are genuinely separate
/// choices: someone who reads the app in Korean may well dictate in English, and
/// tying the microphone to the menus would make one of those two wrong with no
/// way to say so.
///
/// There is no "detect it for me" here, and that is a limit of the platform
/// rather than a decision. `SpeechTranscriber` is constructed against exactly
/// one locale and does no language identification; a mode that claimed to detect
/// would have to run several recognisers at once and guess, which costs battery
/// continuously and still gets code-switched speech wrong. `.automatic`
/// therefore means "follow the interface language" — and every surface that uses
/// it says which language that came out as, so it is never something the user has
/// to infer from bad transcripts.
public enum SpeechLanguagePreference: String, CaseIterable, Codable, Sendable {
    /// Follow the interface language, which itself may be following macOS.
    case automatic
    case english
    case japanese
    case korean

    public var title: LocalizedText {
        switch self {
        case .automatic: return ("Automatic", "自動", "자동")
        case .english: return ("English", "English", "English")
        case .japanese: return ("日本語", "日本語", "日本語")
        case .korean: return ("한국어", "한국어", "한국어")
        }
    }

    /// The language explicitly asked for, or `nil` for `.automatic`.
    public var pinned: Language? {
        switch self {
        case .automatic: return nil
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        }
    }
}

/// An English/Japanese/Korean triple, for a value that has to carry its own
/// translations rather than be written at the point it is displayed.
public typealias LocalizedText = (english: String, japanese: String, korean: String)

/// The app's current language, and the one place it is stored.
///
/// `UserDefaults` rather than `AgentConfiguration` for the same reason the
/// overlay's placement is: this is something the user changes by clicking a
/// picker, not policy they edit in a JSON file, and it has to survive a quit.
///
/// `@Observable` is what makes the switch take effect without a relaunch — every
/// localized string in a SwiftUI view reads `language` while the view body runs,
/// so changing it invalidates exactly the views that render text.
@MainActor
@Observable
public final class Localization {
    public static let shared = Localization()

    private static let storageKey = "app.language"
    private static let speechStorageKey = "app.speechLanguage"

    @ObservationIgnored private let defaults: UserDefaults

    /// What the user chose. Setting it is the only way the language changes.
    public var preference: LanguagePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.storageKey)
            language = preference.resolved()
        }
    }

    /// Which language the microphone is transcribed as.
    ///
    /// Stored separately from `preference` so that pinning one does not silently
    /// pin the other — a user who sets the interface to Korean and leaves this on
    /// automatic gets Korean speech, and a user who sets this to English keeps it
    /// however the interface later moves.
    public var speechPreference: SpeechLanguagePreference {
        didSet {
            guard speechPreference != oldValue else { return }
            defaults.set(speechPreference.rawValue, forKey: Self.speechStorageKey)
        }
    }

    /// The language strings are actually drawn in. Derived, never set directly,
    /// so `.automatic` cannot drift out of step with the system.
    public private(set) var language: Language

    /// The locale for on-device transcription.
    ///
    /// The fully automatic case — speech following the interface, the interface
    /// following macOS — deliberately yields `Locale.current` rather than the
    /// resolved language's canned locale: someone in en-GB or en-AU who never
    /// touched either setting should keep the speech model they had, not be moved
    /// to en-US by a feature they did not ask for.
    public var speechLocale: Locale {
        if let pinned = speechPreference.pinned { return pinned.speechLocale }
        return preference == .automatic ? Locale.current : language.speechLocale
    }

    /// The language the transcriber will actually listen for, when it is one the
    /// app knows by name. `nil` for a system locale outside the three — en-GB
    /// resolves to English, but `fr-CA` is a locale this app cannot name.
    public var speechLanguage: Language? {
        guard let code = speechLocale.language.languageCode?.identifier else { return nil }
        return Language(rawValue: code)
    }

    /// The resolved speech locale, named so a person can check it at a glance:
    /// `日本語 (ja-JP)`. This is what makes `.automatic` honest — the setting says
    /// "follow the interface", and this says what that came out as today.
    public var speechLocaleDescription: String {
        // Rebuilt from the components rather than printed raw: `Locale.current`
        // is an ICU identifier and carries the user's calendar, currency and
        // measurement overrides — `en_US@currency=JPY` says nothing about which
        // language is being listened for, which is the only question here.
        let locale = speechLocale
        let tag = [locale.language.languageCode?.identifier, locale.region?.identifier]
            .compactMap { $0 }
            .joined(separator: "-")
        let identifier = tag.isEmpty ? locale.identifier : tag
        guard let endonym = speechLanguage?.endonym else { return identifier }
        return "\(endonym) (\(identifier))"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.storageKey)
            .flatMap(LanguagePreference.init(rawValue:))
        let preference = stored ?? .automatic
        self.preference = preference
        self.language = preference.resolved()
        self.speechPreference = defaults.string(forKey: Self.speechStorageKey)
            .flatMap(SpeechLanguagePreference.init(rawValue:)) ?? .automatic
    }
}

/// The string for the language the user picked.
///
/// Written as an English/Japanese/Korean triple at the call site on purpose. The
/// alternative — a key into a catalogue — moves the translations of every message
/// away from the code that decides when to show it, and this app's strings are
/// mostly load-bearing explanations rather than labels: "why is this off", "what
/// breaks without it", "what happens if you turn this on". Those go stale the
/// instant they are one file away from the behaviour they describe.
@MainActor
public func localized(_ english: String, _ japanese: String, _ korean: String) -> String {
    switch Localization.shared.language {
    case .english: return english
    case .japanese: return japanese
    case .korean: return korean
    }
}

/// The same choice, for a value that is already language-tagged.
@MainActor
public func localized(_ text: LocalizedText) -> String {
    localized(text.english, text.japanese, text.korean)
}
