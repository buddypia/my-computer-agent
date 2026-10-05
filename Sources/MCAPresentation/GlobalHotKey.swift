import AppKit
import Carbon.HIToolbox
import MCACore
import OSLog

/// System-wide keyboard shortcuts.
///
/// Uses Carbon's `RegisterEventHotKey` rather than a `CGEventTap`, and that
/// choice is deliberate: an event tap would require the Input Monitoring
/// permission, which means asking the user to grant something indistinguishable
/// from a keylogger. `RegisterEventHotKey` needs no permission at all and only
/// ever sees the specific chords we register.
///
/// Registration is fallible and the failure is *silent* at the OS level — the
/// chord simply belongs to whichever app claimed it first. `register` therefore
/// reports success rather than logging and moving on, so the layer above can
/// tell the user which shortcut is dead and let them pick another one.
@MainActor
public final class GlobalHotKey {
    /// A key plus its modifiers, in Carbon's encoding.
    ///
    /// `label` is stored rather than derived. Deriving a display string from a
    /// virtual key code means either hardcoding a US layout — wrong for anyone
    /// else — or round-tripping through `UCKeyTranslate`, which still cannot
    /// tell you what the key was called on the layout in force when the user
    /// pressed it. The recorder already has the answer in
    /// `charactersIgnoringModifiers`, so it keeps it.
    public struct Chord: Sendable, Hashable, Codable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        /// What to draw for the key itself, e.g. `Space`, `C`, `←`.
        public var label: String

        public init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        // MARK: Defaults

        /// ⌥⌘Space — ask a question.
        public static let ask = Chord(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey), label: "Space")
        /// ⌥⌘X — toggle click-through.
        ///
        /// X rather than C: ⌥⌘C is taken by "Copy Pathname" in macOS Finder,
        /// and registering it system-wide breaks file copying in Finder.
        public static let toggleClickThrough = Chord(
            keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(optionKey | cmdKey), label: "X")
        /// ⌥⌘H — show or hide the overlay.
        public static let toggleVisibility = Chord(
            keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey | cmdKey), label: "H")
        /// ⌥⌘J — collapse the overlay to a pill, or expand it again.
        ///
        /// J rather than the obvious M: ⌥⌘M is taken by "Minimise All" in most
        /// apps, and `RegisterEventHotKey` would take it away from them
        /// system-wide.
        public static let toggleCollapse = Chord(
            keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey | cmdKey), label: "J")
        /// ⌥⌘V — start or stop a live voice conversation.
        public static let toggleVoice = Chord(
            keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey), label: "V")
        /// ⌥⌘W — pin the watch to the window in front, or let it go.
        ///
        /// W for "watch". Safe despite ⌘W being Close everywhere, because the
        /// option key is part of it: `RegisterEventHotKey` matches the whole
        /// chord, so ⌘W keeps closing windows.
        public static let pinWatch = Chord(
            keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey | cmdKey), label: "W")

        // MARK: Display

        /// `⌥⌘Space`, in the order macOS draws modifiers.
        public var displayString: String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + label
        }

        /// The same chord as an `NSMenuItem` key equivalent, or `nil` when the
        /// key has no single-character form a menu can show.
        public var menuKeyEquivalent: String? {
            if keyCode == UInt32(kVK_Space) { return " " }
            guard label.count == 1, let character = label.lowercased().first,
                  character.isLetter || character.isNumber
            else { return nil }
            return String(character)
        }

        public var menuModifierMask: NSEvent.ModifierFlags {
            var mask: NSEvent.ModifierFlags = []
            if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
            if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
            if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
            if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
            return mask
        }

        // MARK: Recording

        /// Builds a chord from a recorded key-down event.
        ///
        /// Returns `nil` for anything macOS would not accept as a global hot
        /// key. A bare letter is rejected on purpose: `RegisterEventHotKey`
        /// takes the chord away from every other application, so binding `A`
        /// with no modifier would make the keyboard unusable.
        public static func from(event: NSEvent) -> Chord? {
            var carbon: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }

            // Shift alone is not enough — ⇧A is a capital letter, not a chord.
            let anchoring = UInt32(cmdKey | optionKey | controlKey)
            guard carbon & anchoring != 0 else { return nil }

            guard let label = label(for: event) else { return nil }
            return Chord(keyCode: UInt32(event.keyCode), modifiers: carbon, label: label)
        }

        /// Why this chord must not become a global hot key, if it must not.
        ///
        /// `RegisterEventHotKey` claims a chord for the *whole system*, not for
        /// this app. Binding ⌘V here would therefore stop paste working in
        /// Xcode, Mail and everywhere else, with no visible cause and no way to
        /// undo it except finding this window again — and it would break
        /// pasting an API key into the field two tabs over, which is the one
        /// thing Settings exists to do.
        @MainActor
        public var reservedReason: String? {
            guard modifiers == UInt32(cmdKey) else { return nil }
            let reserved: [String: LocalizedText] = [
                "V": ("Paste", "ペースト", "붙여넣기"), "C": ("Copy", "コピー", "복사하기"),
                "X": ("Cut", "カット", "오려두기"),
                "A": ("Select All", "すべてを選択", "전체 선택"),
                "Z": ("Undo", "取り消す", "실행 취소"), "Q": ("Quit", "終了", "종료"),
                "W": ("Close", "閉じる", "닫기"), "H": ("Hide", "隠す", "가리기"),
            ]
            guard let name = reserved[label] else { return nil }
            return localized(
                "⌘\(label) is \(name.english) everywhere on this Mac — a global shortcut would take it from every app.",
                "⌘\(label) はこの Mac 全体で「\(name.japanese)」です。グローバルショートカットにすると、すべてのアプリからこの操作を奪ってしまいます。",
                """
                ⌘\(label)는 이 Mac 전체에서 ‘\(name.korean)’입니다. \
                전역 단축키로 지정하면 모든 앱에서 이 동작을 빼앗게 됩니다.
                """)
        }

        /// Names for the keys that produce no character, plus a fall back to
        /// whatever the current layout says the key types.
        private static func label(for event: NSEvent) -> String? {
            switch Int(event.keyCode) {
            case kVK_Space: return "Space"
            case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
            case kVK_Tab: return "⇥"
            case kVK_Escape: return "⎋"
            case kVK_Delete: return "⌫"
            case kVK_ForwardDelete: return "⌦"
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            case kVK_Home: return "↖"
            case kVK_End: return "↘"
            case kVK_PageUp: return "⇞"
            case kVK_PageDown: return "⇟"
            default:
                // Function keys are looked up rather than range-matched: their
                // virtual key codes are not in numeric order (kVK_F1 is 0x7A,
                // kVK_F12 is 0x6F), so `kVK_F1...kVK_F12` is not even a valid
                // range.
                if let number = functionNumber(event.keyCode) { return "F\(number)" }
                guard let characters = event.charactersIgnoringModifiers,
                      let first = characters.first, !first.isWhitespace
                else { return nil }
                return String(first).uppercased()
            }
        }

        private static let functionKeyCodes: [Int] = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]

        private static func functionNumber(_ keyCode: UInt16) -> Int? {
            functionKeyCodes.firstIndex(of: Int(keyCode)).map { $0 + 1 }
        }
    }

    private static let signature: OSType = 0x4D_43_41_31  // 'MCA1'

    private let log = Logger(subsystem: "com.buddypia.mca", category: "HotKey")
    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    public init() {}

    /// Releases every registered chord.
    ///
    /// Explicit rather than a `deinit` because Carbon's handles are not
    /// `Sendable` and a nonisolated deinit cannot touch main-actor state. In
    /// practice this object lives as long as the app, so teardown is a shutdown
    /// step rather than a lifetime concern.
    public func unregisterAll() {
        for (_, reference) in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        handlers.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Claims `chord` system-wide. `false` means another application already
    /// owns it and the handler will never fire.
    @discardableResult
    public func register(_ chord: Chord, handler: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            chord.keyCode, chord.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &reference)

        guard status == noErr, let reference else {
            log.warning("""
                Could not register \(chord.displayString, privacy: .public); \
                another app probably owns it
                """)
            return false
        }
        handlers[id] = handler
        references[id] = reference
        return true
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }

            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // The Carbon callback runs on the main thread already, but hopping
            // makes the isolation explicit to the compiler.
            MainActor.assumeIsolated { hotKey.fire(id: hotKeyID.id) }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func fire(id: UInt32) {
        handlers[id]?()
    }
}
