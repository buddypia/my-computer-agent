import Foundation

/// Translates key names the model writes (`Enter`, `Cmd+A`, `Shift+Tab`, `a`)
/// into the `Input.dispatchKeyEvent` payloads Chromium expects.
///
/// Two details
/// matter for correctness and are easy to get wrong:
///
/// - A printable key with a non-Shift modifier must be sent as `rawKeyDown`
///   without `text`, or Chrome inserts the character instead of running the
///   accelerator.
/// - On macOS, editing shortcuts (`Cmd+A`, `Cmd+C`, `Cmd+V`, …) only work when
///   the matching editing `commands` are attached to the key event; Chrome
///   does not derive them from modifiers on its own.
public enum CDPKeyMap {
    public struct NamedKey: Sendable, Equatable {
        public var key: String
        public var code: String
        public var virtualKeyCode: Int
        public var text: String?
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let alt = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let meta = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    /// One `Input.dispatchKeyEvent` call.
    public struct KeyEvent: Sendable, Equatable {
        public var type: String
        public var params: [String: JSONValue]
    }

    public static let namedKeys: [String: NamedKey] = [
        "Enter": NamedKey(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\r"),
        "Tab": NamedKey(key: "Tab", code: "Tab", virtualKeyCode: 9),
        "Backspace": NamedKey(key: "Backspace", code: "Backspace", virtualKeyCode: 8),
        "Escape": NamedKey(key: "Escape", code: "Escape", virtualKeyCode: 27),
        "Delete": NamedKey(key: "Delete", code: "Delete", virtualKeyCode: 46),
        "ArrowLeft": NamedKey(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37),
        "ArrowUp": NamedKey(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38),
        "ArrowRight": NamedKey(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39),
        "ArrowDown": NamedKey(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40),
        "Home": NamedKey(key: "Home", code: "Home", virtualKeyCode: 36),
        "End": NamedKey(key: "End", code: "End", virtualKeyCode: 35),
        "PageUp": NamedKey(key: "PageUp", code: "PageUp", virtualKeyCode: 33),
        "PageDown": NamedKey(key: "PageDown", code: "PageDown", virtualKeyCode: 34),
        "Space": NamedKey(key: " ", code: "Space", virtualKeyCode: 32, text: " "),
        "Alt": NamedKey(key: "Alt", code: "AltLeft", virtualKeyCode: 18),
        "Control": NamedKey(key: "Control", code: "ControlLeft", virtualKeyCode: 17),
        "Meta": NamedKey(key: "Meta", code: "MetaLeft", virtualKeyCode: 91),
        "Shift": NamedKey(key: "Shift", code: "ShiftLeft", virtualKeyCode: 16),
    ]

    /// Aliases people (and models) use for the canonical names above.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "cmd", "command", "meta", "super", "win": return "Meta"
        case "ctrl", "control": return "Control"
        case "alt", "opt", "option": return "Alt"
        case "shift": return "Shift"
        case "enter", "return": return "Enter"
        case "esc", "escape": return "Escape"
        case "tab": return "Tab"
        case "backspace", "bs": return "Backspace"
        case "delete", "del": return "Delete"
        case "space", "spacebar": return "Space"
        case "up", "arrowup": return "ArrowUp"
        case "down", "arrowdown": return "ArrowDown"
        case "left", "arrowleft": return "ArrowLeft"
        case "right", "arrowright": return "ArrowRight"
        case "home": return "Home"
        case "end": return "End"
        case "pageup", "pgup": return "PageUp"
        case "pagedown", "pgdn": return "PageDown"
        default:
            // DevTools `code` names (`KeyA`, `Digit5`) are what models emit
            // for chords; the key itself is the character.
            if trimmed.count == 4, trimmed.hasPrefix("Key"), let letter = trimmed.last, letter.isLetter {
                return String(letter).lowercased()
            }
            if trimmed.count == 6, trimmed.hasPrefix("Digit"), let digit = trimmed.last, digit.isNumber {
                return String(digit)
            }
            return trimmed
        }
    }

    /// Splits `Cmd+Shift+A` into modifiers and the main key. A lone `+` is the
    /// plus key itself.
    public static func parseChord(_ chord: String) -> (modifiers: [String], key: String) {
        if chord == "+" { return ([], "+") }
        var parts: [String] = []
        var current = ""
        for character in chord {
            if character == "+" && !current.isEmpty {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard let last = parts.last else { return ([], chord) }
        return (parts.dropLast().map(normalize), normalize(last))
    }

    /// The full keyDown/keyUp sequence for a chord, modifiers held around the
    /// main key in the order a person would press them.
    public static func events(forChord chord: String) -> [KeyEvent] {
        let (modifierNames, mainKey) = parseChord(chord)
        var held: Modifiers = []
        var sequence: [KeyEvent] = []

        for name in modifierNames {
            if let bit = modifierBit(name) { held.insert(bit) }
            sequence.append(keyDown(name, held: held))
        }
        sequence.append(keyDown(mainKey, held: held))
        sequence.append(keyUp(mainKey, held: held))
        for name in modifierNames.reversed() {
            sequence.append(keyUp(name, held: held))
            if let bit = modifierBit(name) { held.remove(bit) }
        }
        return sequence
    }

    static func modifierBit(_ name: String) -> Modifiers? {
        switch name {
        case "Alt": return .alt
        case "Control": return .control
        case "Meta": return .meta
        case "Shift": return .shift
        default: return nil
        }
    }

    public static func keyDown(_ rawKey: String, held: Modifiers) -> KeyEvent {
        let key = normalize(rawKey)
        let modifiers = JSONValue.number(Double(held.rawValue))

        if key.count == 1 {
            let hasNonShift = !held.intersection([.alt, .control, .meta]).isEmpty
            let printable = describePrintable(key, shiftDown: held.contains(.shift))
            if hasNonShift {
                var params: [String: JSONValue] = [
                    "type": "rawKeyDown",
                    "modifiers": modifiers,
                    "key": .string(printable.key),
                    "windowsVirtualKeyCode": .number(Double(printable.virtualKeyCode)),
                ]
                if let code = printable.code { params["code"] = .string(code) }
                let commands = macEditingCommands(code: printable.code ?? "", held: held)
                if !commands.isEmpty { params["commands"] = .array(commands.map(JSONValue.string)) }
                return KeyEvent(type: "rawKeyDown", params: params)
            }
            return KeyEvent(type: "keyDown", params: [
                "type": "keyDown",
                "modifiers": modifiers,
                "text": .string(key),
                "unmodifiedText": .string(key),
                "key": .string(key),
            ])
        }

        if let named = namedKeys[key] {
            let includeText = named.text != nil && held.isEmpty
            var params: [String: JSONValue] = [
                "type": .string(includeText ? "keyDown" : "rawKeyDown"),
                "modifiers": modifiers,
                "key": .string(named.key),
                "code": .string(named.code),
                "windowsVirtualKeyCode": .number(Double(named.virtualKeyCode)),
            ]
            if includeText, let text = named.text {
                params["text"] = .string(text)
                params["unmodifiedText"] = .string(text)
            }
            let commands = macEditingCommands(code: named.code, held: held)
            if !commands.isEmpty { params["commands"] = .array(commands.map(JSONValue.string)) }
            return KeyEvent(type: includeText ? "keyDown" : "rawKeyDown", params: params)
        }

        return KeyEvent(type: "keyDown", params: [
            "type": "keyDown",
            "modifiers": modifiers,
            "key": .string(key),
        ])
    }

    public static func keyUp(_ rawKey: String, held: Modifiers) -> KeyEvent {
        let key = normalize(rawKey)
        let modifiers = JSONValue.number(Double(held.rawValue))
        if key.count == 1 {
            let printable = describePrintable(key, shiftDown: held.contains(.shift))
            var params: [String: JSONValue] = [
                "type": "keyUp",
                "modifiers": modifiers,
                "key": .string(printable.key),
                "windowsVirtualKeyCode": .number(Double(printable.virtualKeyCode)),
            ]
            if let code = printable.code { params["code"] = .string(code) }
            return KeyEvent(type: "keyUp", params: params)
        }
        if let named = namedKeys[key] {
            return KeyEvent(type: "keyUp", params: [
                "type": "keyUp",
                "modifiers": modifiers,
                "key": .string(named.key),
                "code": .string(named.code),
                "windowsVirtualKeyCode": .number(Double(named.virtualKeyCode)),
            ])
        }
        return KeyEvent(type: "keyUp", params: ["type": "keyUp", "modifiers": modifiers, "key": .string(key)])
    }

    struct Printable {
        var key: String
        var code: String?
        var virtualKeyCode: Int
    }

    static func describePrintable(_ character: String, shiftDown: Bool) -> Printable {
        guard let scalar = character.unicodeScalars.first else {
            return Printable(key: character, code: nil, virtualKeyCode: 0)
        }
        if scalar.properties.isAlphabetic, scalar.isASCII {
            let upper = character.uppercased()
            return Printable(key: shiftDown ? upper : upper.lowercased(), code: "Key\(upper)", virtualKeyCode: Int(upper.unicodeScalars.first!.value))
        }
        if ("0"..."9").contains(character) {
            return Printable(key: character, code: "Digit\(character)", virtualKeyCode: Int(scalar.value))
        }
        if character == " " {
            return Printable(key: " ", code: "Space", virtualKeyCode: 32)
        }
        return Printable(key: shiftDown ? character.uppercased() : character, code: nil, virtualKeyCode: Int(character.uppercased().unicodeScalars.first!.value))
    }

    /// Chromium's macOS editing commands for the common Cmd shortcuts, without
    /// the trailing colon Chrome's key event wants stripped.
    static func macEditingCommands(code: String, held: Modifiers) -> [String] {
        guard held.contains(.meta), !held.contains(.control), !held.contains(.alt), !held.contains(.shift) else { return [] }
        switch code {
        case "KeyA": return ["selectAll"]
        case "KeyC": return ["copy"]
        case "KeyX": return ["cut"]
        case "KeyV": return ["paste"]
        case "KeyZ": return ["undo"]
        default: return []
        }
    }
}
