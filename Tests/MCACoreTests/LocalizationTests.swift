import Foundation
import Testing

@testable import MCACore

/// The language setting has one job that is easy to get subtly wrong: deciding
/// what `.automatic` means. Everything else — which of two strings to return —
/// cannot fail interestingly, but resolving a system language list can, and it
/// is the branch every fresh install takes.
@Suite("Language resolution")
struct LanguageResolutionTests {
    @Test("an explicit choice ignores the system entirely")
    func explicitChoiceWins() {
        #expect(LanguagePreference.japanese.resolved(systemLanguages: ["en-US"]) == .japanese)
        #expect(LanguagePreference.english.resolved(systemLanguages: ["ja-JP"]) == .english)
    }

    /// Region has to be ignored: macOS reports `ja-JP`, and matching the whole
    /// identifier would leave a Japanese Mac showing English.
    @Test("a regional identifier still matches its language")
    func matchesOnLanguageCode() {
        #expect(LanguagePreference.automatic.resolved(systemLanguages: ["ja-JP"]) == .japanese)
        #expect(LanguagePreference.automatic.resolved(systemLanguages: ["en-GB"]) == .english)
    }

    /// The list is ordered by the user's own preference, so the first language
    /// we ship strings for is the right answer — not the first entry outright.
    @Test("the first supported language in the list wins")
    func skipsUnsupportedLanguages() {
        #expect(
            LanguagePreference.automatic.resolved(systemLanguages: ["fr-FR", "ja-JP", "en-US"])
                == .japanese)
        #expect(
            LanguagePreference.automatic.resolved(systemLanguages: ["de-DE", "en-US", "ja-JP"])
                == .english)
    }

    /// Falling back to English is the only option — it is the language every
    /// other string can be read against — but it must not depend on the list
    /// being non-empty.
    @Test("a system with no language we ship falls back to English")
    func fallsBackToEnglish() {
        #expect(LanguagePreference.automatic.resolved(systemLanguages: ["fr-FR"]) == .english)
        #expect(LanguagePreference.automatic.resolved(systemLanguages: []) == .english)
    }

    /// The third language is the one most likely to be dropped by a resolver
    /// written when there were two: `ko-KR` used to fall through to English.
    @Test("Korean resolves rather than falling through to English")
    func koreanResolves() {
        #expect(LanguagePreference.automatic.resolved(systemLanguages: ["ko-KR"]) == .korean)
        #expect(LanguagePreference.korean.resolved(systemLanguages: ["en-US"]) == .korean)
        #expect(
            LanguagePreference.automatic.resolved(systemLanguages: ["fr-FR", "ko", "en-US"])
                == .korean)
    }
}

@Suite("Language preference storage")
@MainActor
struct LocalizationStorageTests {
    /// A private suite per test. `.standard` is what the running app reads, so
    /// a test that touched it would change the developer's own language.
    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "localization.tests.\(UUID().uuidString)"))
    }

    @Test("a fresh install follows macOS rather than picking for the user")
    func defaultsToAutomatic() throws {
        #expect(Localization(defaults: try freshDefaults()).preference == .automatic)
    }

    @Test("the choice survives a relaunch")
    func persists() throws {
        let defaults = try freshDefaults()
        Localization(defaults: defaults).preference = .japanese
        #expect(Localization(defaults: defaults).preference == .japanese)
        #expect(Localization(defaults: defaults).language == .japanese)
    }

    /// `language` is derived, and the derivation has to re-run on every change
    /// or the interface keeps drawing the previous language.
    @Test("changing the preference changes the rendered language")
    func derivedLanguageFollows() throws {
        let localization = Localization(defaults: try freshDefaults())
        localization.preference = .japanese
        #expect(localization.language == .japanese)
        localization.preference = .english
        #expect(localization.language == .english)
    }

    /// Someone in en-GB who never touched either setting must keep the speech
    /// model they had. Resolving `.automatic` to English and then handing the
    /// transcriber `en-US` would move them for a feature they did not use.
    @Test("automatic leaves the speech locale alone")
    func automaticKeepsTheSystemSpeechLocale() throws {
        let localization = Localization(defaults: try freshDefaults())
        #expect(localization.speechLocale == Locale.current)

        localization.preference = .japanese
        #expect(localization.speechLocale.identifier == "ja-JP")
    }

    /// The whole point of a separate speech setting: reading the app in one
    /// language while dictating in another. If the interface language could
    /// override a pinned speech language, the setting would be decorative.
    @Test("a pinned speech language survives an interface change")
    func pinnedSpeechLanguageWins() throws {
        let localization = Localization(defaults: try freshDefaults())
        localization.speechPreference = .english
        #expect(localization.speechLocale.identifier == "en-US")

        localization.preference = .korean
        #expect(localization.speechLocale.identifier == "en-US")
        #expect(localization.speechLanguage == .english)
    }

    /// `.automatic` is the default and means "follow the interface", which is
    /// only honest if the app can say what it came out as.
    @Test("automatic follows the interface language and names the result")
    func automaticFollowsTheInterface() throws {
        let localization = Localization(defaults: try freshDefaults())
        localization.preference = .korean

        #expect(localization.speechPreference == .automatic)
        #expect(localization.speechLocale.identifier == "ko-KR")
        #expect(localization.speechLanguage == .korean)
        #expect(localization.speechLocaleDescription == "한국어 (ko-KR)")
    }

    @Test("the speech choice survives a relaunch")
    func speechPreferencePersists() throws {
        let defaults = try freshDefaults()
        Localization(defaults: defaults).speechPreference = .korean
        #expect(Localization(defaults: defaults).speechPreference == .korean)
    }
}
