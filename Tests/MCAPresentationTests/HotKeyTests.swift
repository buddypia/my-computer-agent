import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import MCAPresentation

@Suite("Hot key chords")
@MainActor
struct ChordTests {
    @Test("draws modifiers in the order macOS does")
    func displayOrder() {
        let chord = GlobalHotKey.Chord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey),
            label: "K")
        #expect(chord.displayString == "⌃⌥⇧⌘K")
    }

    @Test("space becomes a menu key equivalent, arrows do not")
    func menuEquivalents() {
        #expect(GlobalHotKey.Chord.ask.menuKeyEquivalent == " ")
        #expect(GlobalHotKey.Chord.toggleVoice.menuKeyEquivalent == "v")

        let arrow = GlobalHotKey.Chord(
            keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey), label: "←")
        #expect(arrow.menuKeyEquivalent == nil)
    }

    @Test("toggleClickThrough uses ⌥⌘X to avoid macOS Finder shortcut collision")
    func clickThroughShortcut() {
        #expect(GlobalHotKey.Chord.toggleClickThrough.displayString == "⌥⌘X")
        #expect(GlobalHotKey.Chord.toggleClickThrough.label == "X")
        #expect(GlobalHotKey.Chord.toggleClickThrough.menuKeyEquivalent == "x")
    }

    @Test("toggleVoice uses ⌃⌥V to avoid macOS Finder 'Move items here' shortcut collision")
    func voiceShortcut() {
        #expect(GlobalHotKey.Chord.toggleVoice.displayString == "⌃⌥V")
        #expect(GlobalHotKey.Chord.toggleVoice.label == "V")
        #expect(GlobalHotKey.Chord.toggleVoice.menuKeyEquivalent == "v")
        #expect(GlobalHotKey.Chord.toggleVoice.menuModifierMask == [.control, .option])
    }

    @Test("carbon modifiers map back to AppKit's mask")
    func modifierMask() {
        let mask = GlobalHotKey.Chord.ask.menuModifierMask
        #expect(!mask.contains(.command))
        #expect(mask.contains(.option))
        #expect(!mask.contains(.shift))
        #expect(GlobalHotKey.Chord.ask.displayString == "⌥Space")
    }

    /// A bare key, or a key with only Shift, must be refused: registering it
    /// would take that key away from every other application system-wide.
    @Test("refuses a chord with no command, option or control")
    func rejectsUnanchoredChords() throws {
        #expect(GlobalHotKey.Chord.from(event: try keyDown(flags: [], character: "k")) == nil)
        #expect(GlobalHotKey.Chord.from(event: try keyDown(flags: .shift, character: "K")) == nil)
    }

    @Test("keeps the label the layout actually produced")
    func recordsLabel() throws {
        let event = try keyDown(flags: [.command, .option], character: "k")
        let chord = try #require(GlobalHotKey.Chord.from(event: event))
        #expect(chord.label == "K")
        #expect(chord.modifiers == UInt32(cmdKey | optionKey))
        #expect(chord.displayString == "⌥⌘K")
    }

    @Test("names keys that produce no character")
    func namesSpecialKeys() throws {
        let event = try keyDown(
            flags: .command, character: " ", keyCode: UInt16(kVK_Space))
        let chord = try #require(GlobalHotKey.Chord.from(event: event))
        #expect(chord.label == "Space")
    }

    /// Function-key codes are not in numeric order — kVK_F1 is 0x7A and
    /// kVK_F12 is 0x6F — so anything that range-matches them is wrong, and a
    /// literal `kVK_F1...kVK_F12` traps at runtime.
    @Test("names function keys, whose key codes are not contiguous")
    func namesFunctionKeys() throws {
        let f12 = try #require(GlobalHotKey.Chord.from(
            event: try keyDown(flags: .control, character: "\u{F70B}",
                               keyCode: UInt16(kVK_F12))))
        #expect(f12.label == "F12")

        let f1 = try #require(GlobalHotKey.Chord.from(
            event: try keyDown(flags: .control, character: "\u{F704}",
                               keyCode: UInt16(kVK_F1))))
        #expect(f1.label == "F1")
    }

    @Test("survives a round trip through storage")
    func codable() throws {
        let data = try JSONEncoder().encode(GlobalHotKey.Chord.toggleCollapse)
        let decoded = try JSONDecoder().decode(GlobalHotKey.Chord.self, from: data)
        #expect(decoded == .toggleCollapse)
    }

    private func keyDown(
        flags: NSEvent.ModifierFlags,
        character: String,
        keyCode: UInt16 = UInt16(kVK_ANSI_K)
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode))
    }
}

@Suite("Hot key center")
@MainActor
struct HotKeyCenterTests {
    /// A private suite per test: `UserDefaults.standard` would leak bindings
    /// between tests and into the developer's own copy of the app.
    private func makeDefaults() throws -> UserDefaults {
        let name = "mca.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test("starts on the documented defaults")
    func defaults() throws {
        let center = HotKeyCenter(defaults: try makeDefaults())
        #expect(center.chord(for: .ask) == .ask)
        #expect(center.chord(for: .toggleVisibility) == .toggleVisibility)
    }

    @Test("a rebinding is remembered across a restart")
    func persistsRebinding() throws {
        let defaults = try makeDefaults()
        let chord = GlobalHotKey.Chord(
            keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey), label: "P")

        HotKeyCenter(defaults: defaults).rebind(.ask, to: chord)

        let reloaded = HotKeyCenter(defaults: defaults)
        #expect(reloaded.chord(for: .ask) == chord)
    }

    /// Clearing has to be distinguishable from never having set anything, or
    /// the default silently comes back on the next launch and the shortcut the
    /// user deliberately removed starts firing again.
    @Test("a cleared shortcut stays cleared across a restart")
    func persistsClearing() throws {
        let defaults = try makeDefaults()
        HotKeyCenter(defaults: defaults).rebind(.toggleVoice, to: nil)

        let reloaded = HotKeyCenter(defaults: defaults)
        #expect(reloaded.chord(for: .toggleVoice) == nil)
        // Every other action keeps its default; clearing one must not clear all.
        #expect(reloaded.chord(for: .ask) == .ask)
    }

    @Test("reports which action already owns a chord")
    func detectsOwner() throws {
        let center = HotKeyCenter(defaults: try makeDefaults())
        #expect(center.owner(of: .toggleVisibility, excluding: .ask) == .toggleVisibility)
        // An action never collides with itself, or rebinding to the same chord
        // would be refused.
        #expect(center.owner(of: .toggleVisibility, excluding: .toggleVisibility) == nil)
    }

    @Test("two actions on the same chord leave the second one flagged")
    func flagsDuplicates() throws {
        let center = HotKeyCenter(defaults: try makeDefaults())
        // Bypasses `owner(of:)`, which the UI uses to refuse this — the point
        // is that a duplicate arriving from stored preferences is still caught.
        center.rebind(.toggleVoice, to: .ask)

        let duplicated = HotKeyAction.allCases.filter {
            if case .duplicate = center.problems[$0] { return true }
            return false
        }
        #expect(duplicated == [.toggleVoice])
    }

    @Test("clearing a shortcut is not reported as a fault")
    func unassignedIsNotAFault() throws {
        let center = HotKeyCenter(defaults: try makeDefaults())
        center.rebind(.toggleCollapse, to: nil)
        #expect(center.problems[.toggleCollapse] == .unassigned)
        #expect(center.problems[.toggleCollapse]?.isFault == false)
    }

    @Test("restoring defaults undoes every change")
    func resetAll() throws {
        let center = HotKeyCenter(defaults: try makeDefaults())
        center.rebind(.ask, to: nil)
        center.rebind(.toggleVoice, to: .ask)

        center.resetAll()

        for action in HotKeyAction.allCases {
            #expect(center.chord(for: action) == action.defaultChord)
        }
    }
}
