import AppKit
import Carbon.HIToolbox
import Testing

@testable import MCAPresentation

/// Guards the regression that prompted this file: with no main menu installed,
/// ⌘V did nothing in the Settings window, because AppKit translates editing
/// chords into responder messages via `mainMenu.performKeyEquivalent(with:)`
/// and there was no main menu to consult.
///
/// The assertions are structural rather than behavioural — driving a real key
/// event needs a key window and a running loop, and neither exists here — but
/// they fail the moment an item is dropped or rebound, which is the only way
/// this breaks again.
@Suite("Application menu", .serialized)
@MainActor
struct AppMenuTests {
    init() {
        // `install` is a no-op once a menu exists, and NSApp is process-wide.
        NSApplication.shared.mainMenu = nil
        AppMenu.install()
    }

    @Test("the editing chords a text field needs are all bound")
    func editingChordsExist() throws {
        let expected: [(id: String, key: String, action: Selector)] = [
            (AppMenu.ID.cut, "x", #selector(NSText.cut(_:))),
            (AppMenu.ID.copy, "c", #selector(NSText.copy(_:))),
            (AppMenu.ID.paste, "v", #selector(NSText.paste(_:))),
            (AppMenu.ID.selectAll, "a", #selector(NSText.selectAll(_:))),
        ]
        for expectation in expected {
            let binding = try #require(
                AppMenu.binding(for: expectation.id, in: AppMenu.ID.edit),
                "no Edit ▸ \(expectation.id) item")
            #expect(binding.key == expectation.key)
            #expect(binding.modifiers == .command)
            #expect(binding.action == expectation.action)
        }
    }

    /// Redo is the one item whose modifiers are not a bare ⌘.
    @Test("redo is bound to ⇧⌘Z")
    func redoChord() throws {
        let undo = try #require(AppMenu.binding(for: AppMenu.ID.undo, in: AppMenu.ID.edit))
        #expect(undo.key == "z")
        #expect(undo.modifiers == .command)

        let redo = try #require(AppMenu.binding(for: AppMenu.ID.redo, in: AppMenu.ID.edit))
        #expect(redo.key == "z")
        #expect(redo.modifiers == [.command, .shift])
    }

    /// A target of `nil` is what sends the action down the responder chain. Any
    /// concrete target here would mean one object had to handle editing for
    /// every field in the app — which is the same as it not working.
    @Test("editing items dispatch through the responder chain")
    func itemsAreTargetless() throws {
        let edit = try #require(AppMenu.menu(AppMenu.ID.edit))
        for item in edit.items where !item.isSeparatorItem {
            #expect(item.target == nil, "\(item.title) was given an explicit target")
        }
    }

    @Test("⌘W closes the front window and ⌘Q quits")
    func windowAndApplicationChords() throws {
        let close = try #require(
            AppMenu.binding(for: AppMenu.ID.close, in: AppMenu.ID.window))
        #expect(close.key == "w")
        #expect(close.action == #selector(NSWindow.performClose(_:)))

        let quit = try #require(
            AppMenu.binding(for: AppMenu.ID.quit, in: AppMenu.ID.application))
        #expect(quit.key == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }

    /// `Copilot.start()` and `mca setup` both call it, and either may run first.
    @Test("installing twice keeps the first menu")
    func installIsIdempotent() {
        let first = NSApplication.shared.mainMenu
        AppMenu.install()
        #expect(NSApplication.shared.mainMenu === first)
    }
}

/// The Edit menu is only as good as the guarantee that nothing takes those
/// chords back. A global hot key would: `RegisterEventHotKey` claims a chord
/// system-wide, so it wins over the menu — and over every other app.
@Suite("Reserved chords")
@MainActor
struct ReservedChordTests {
    private func chord(_ keyCode: Int, _ label: String, command: Bool = true)
        -> GlobalHotKey.Chord
    {
        GlobalHotKey.Chord(
            keyCode: UInt32(keyCode),
            modifiers: UInt32(command ? cmdKey : cmdKey | optionKey),
            label: label)
    }

    @Test("the standard editing chords cannot become global hot keys")
    func editingChordsAreRejected() {
        for (code, label) in [
            (kVK_ANSI_V, "V"), (kVK_ANSI_C, "C"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_A, "A"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_Q, "Q"),
            (kVK_ANSI_W, "W"),
        ] {
            #expect(
                chord(code, label).reservedReason != nil,
                "⌘\(label) should be refused")
        }
    }

    /// Only bare ⌘ is reserved. Adding another modifier makes the chord
    /// available again for custom binding, rather than refusing all variants.
    @Test("adding another modifier makes the chord available again")
    func modifiedVariantsAreAllowed() {
        #expect(chord(kVK_ANSI_V, "V", command: false).reservedReason == nil)
        #expect(chord(kVK_ANSI_K, "K").reservedReason == nil)
    }

    /// The recorder refuses new reserved chords, but a binding saved before the
    /// rule existed is read straight out of `UserDefaults`. It must be refused
    /// at registration too, or the rule only applies to future users.
    @Test("a reserved chord already in defaults is never registered")
    func storedReservedChordIsRefused() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "hotkeys.reserved.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let center = HotKeyCenter(defaults: defaults)
        center.rebind(.ask, to: chord(kVK_ANSI_V, "V"))

        guard case .reserved = center.problems[.ask] else {
            Issue.record("⌘V was accepted as a global hot key: \(String(describing: center.problems[.ask]))")
            return
        }
    }

    /// None of the shipped defaults may trip the new rule — that would leave a
    /// fresh install with a shortcut that is broken out of the box.
    @Test("no default shortcut is reserved")
    func defaultsAreAllowed() {
        for action in HotKeyAction.allCases {
            #expect(
                action.defaultChord.reservedReason == nil,
                "\(action.title) defaults to a reserved chord")
        }
    }
}
