import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MCACore
import OSLog

/// Identifies mouse buttons for event synthesis.
public enum MouseButton: String, Sendable, CaseIterable {
    case left
    case right
    case middle
}

/// Synthesizes hardware mouse and keyboard events at the macOS HID level.
///
/// Requires Accessibility TCC permissions (`AXIsProcessTrusted`).
/// All coordinates are in global Quartz display coordinates (origin at top-left
/// of the primary display).
public struct EventSynthesizer: Sendable {
    @TaskLocal public static var expectedTargetPID: pid_t?
    @TaskLocal public static var expectedTargetWindowID: UInt32?
    public enum SynthesizerError: LocalizedError, Sendable {
        case accessibilityPermissionDenied
        case coordinateOutOfBounds(x: Double, y: Double)
        case unknownKey(String)
        case eventCreationFailed
        case inputTooLong(Int)
        case targetChanged

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionDenied:
                return """
                    Accessibility permission is not granted. \
                    Please grant Accessibility permission to MyComputerAgent (or the parent terminal) in: \
                    System Settings ▸ Privacy & Security ▸ Accessibility \
                    (x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility)
                    """
            case .coordinateOutOfBounds(let x, let y):
                return "Coordinate (\(x), \(y)) is outside of any active display bounds."
            case .unknownKey(let key):
                return "Unknown or unsupported key identifier: '\(key)'."
            case .eventCreationFailed:
                return "Failed to synthesize CGEvent."
            case .targetChanged: return "Input target changed; remaining input was stopped."
            case .inputTooLong(let count):
                return "Text input too long (\(count) characters). Maximum is 5,000 characters per action."
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "EventSynthesizer")

    public init() {}

    /// Checks whether Accessibility permission is currently granted.
    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Queries the current cursor position in Quartz screen coordinates.
    public func cursorPosition() throws -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            throw SynthesizerError.eventCreationFailed
        }
        return event.location
    }

    /// Moves the cursor to the target coordinate.
    public func mouseMove(to point: CGPoint) throws {
        try ensureTrusted()
        try validateCoordinate(point)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw SynthesizerError.eventCreationFailed
        }
        try ensureInputTarget()
        try validateCoordinate(point)
        event.post(tap: .cghidEventTap)
    }

    /// Performs a mouse click (single, double, or triple) at the specified or current position.
    public func click(
        at point: CGPoint? = nil,
        button: MouseButton = .left,
        clickCount: Int = 1
    ) throws {
        try ensureTrusted()
        let targetPoint: CGPoint
        if let point {
            try validateCoordinate(point)
            targetPoint = point
            try mouseMove(to: targetPoint)
        } else {
            targetPoint = try cursorPosition()
            try validateCoordinate(targetPoint)
        }

        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
            cgButton = .left
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
            cgButton = .right
        case .middle:
            downType = .otherMouseDown
            upType = .otherMouseUp
            cgButton = .center
        }

        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: targetPoint,
            mouseButton: cgButton
        ), let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: upType,
            mouseCursorPosition: targetPoint,
            mouseButton: cgButton
        ) else {
            throw SynthesizerError.eventCreationFailed
        }

        try ensureInputTarget()
        try validateCoordinate(targetPoint)
        let count = Int64(max(1, clickCount))
        downEvent.setIntegerValueField(.mouseEventClickState, value: count)
        upEvent.setIntegerValueField(.mouseEventClickState, value: count)

        downEvent.post(tap: .cghidEventTap)
        // Brief pause to allow the OS and target app to register mouse-down
        Thread.sleep(forTimeInterval: 0.015)
        upEvent.post(tap: .cghidEventTap)
    }

    /// Drags from a starting point to an ending point.
    public func drag(from start: CGPoint, to end: CGPoint) throws {
        try ensureTrusted()
        try validateCoordinate(start)
        try validateCoordinate(end)

        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        ), let dragEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: end,
            mouseButton: .left
        ), let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        ) else {
            throw SynthesizerError.eventCreationFailed
        }

        try Self.dispatchDrag(from: start, to: end,
            validate: { point in try ensureTrusted(); try validateCoordinate(point) },
            move: { try mouseMove(to: start) },
            post: { type, point in
                let event = type == .leftMouseDown ? downEvent : (type == .leftMouseDragged ? dragEvent : upEvent)
                event.location = point
                event.post(tap: .cghidEventTap)
            },
            pause: { Thread.sleep(forTimeInterval: $0) })
    }

    /// The sequencing used by the native primitive; recording emitters avoid HID in tests.
    static func dispatchDrag(from start: CGPoint, to end: CGPoint,
        validate: (CGPoint) throws -> Void, move: () throws -> Void,
        post: (CGEventType, CGPoint) -> Void, pause: (TimeInterval) -> Void
    ) throws {
        try validate(start)
        try move()
        pause(0.01)
        try validate(start)
        post(.leftMouseDown, start)
        var releasePoint = start
        // Cleanup is allowed after cancellation; it must not move to an undispatched endpoint.
        defer { post(.leftMouseUp, releasePoint) }
        pause(0.02)
        try validate(end)
        post(.leftMouseDragged, end)
        releasePoint = end
        pause(0.02)
        try validate(end)
    }

    /// Types text into the currently active text field. Supports Unicode (Japanese, emoji, etc.).
    public func typeText(_ text: String) throws {
        try ensureTrusted()
        guard text.count <= 5000 else {
            throw SynthesizerError.inputTooLong(text.count)
        }

        let focused = Self.expectedTargetPID.flatMap { focusedAXElement(pid: $0, attribute: kAXFocusedUIElementAttribute) }
        if Self.expectedTargetPID != nil && focused == nil { throw SynthesizerError.targetChanged }
        for char in text {
            try ensureInputTarget()
            if let focused, let pid = Self.expectedTargetPID {
                guard let current = focusedAXElement(pid: pid, attribute: kAXFocusedUIElementAttribute), CFEqual(focused, current) else { throw SynthesizerError.targetChanged }
            }
            if char == "\n" {
                try pressKeyCode(UInt16(kVK_Return), modifiers: [])
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            if char == "\t" {
                try pressKeyCode(UInt16(kVK_Tab), modifiers: [])
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            let utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            try ensureInputTarget()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Parses and presses a key chord string, such as "Return", "Escape", "cmd+c", "ctrl+alt+delete".
    public func pressKey(_ chordString: String) throws {
        try ensureTrusted()
        let (keyCode, flags) = try parseKeyChord(chordString)
        try pressKeyCode(keyCode, modifiers: flags)
    }

    /// Scrolls the mouse wheel by the specified line deltas.
    /// `deltaY`: positive scrolls up, negative scrolls down.
    /// `deltaX`: positive scrolls right, negative scrolls left.
    /// When `targetPID` is provided, the scroll event is posted directly to that process without moving the physical cursor.
    public func scroll(deltaX: Int32 = 0, deltaY: Int32 = 0, at point: CGPoint? = nil, targetPID: pid_t? = nil) throws {
        if let targetPID {
            let targetPoint = point ?? (try? cursorPosition()) ?? CGPoint(x: 100, y: 100)
            try scrollProcess(pid: targetPID, at: targetPoint, deltaX: deltaX, deltaY: deltaY)
            return
        }
        try ensureTrusted()

        let targetPoint: CGPoint
        if let point {
            try validateCoordinate(point)
            targetPoint = point
            try mouseMove(to: targetPoint)
        } else {
            targetPoint = try cursorPosition()
            try validateCoordinate(targetPoint)
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw SynthesizerError.eventCreationFailed
        }

        event.location = targetPoint
        try ensureInputTarget()
        try validateCoordinate(targetPoint)
        event.post(tap: .cghidEventTap)
    }

    /// Scrolls a target application process in the background without moving the physical cursor or bringing the app frontmost.
    /// - Parameters:
    ///   - pid: The target application process ID.
    ///   - point: The target location within the screen/window coordinates.
    ///   - deltaX: Horizontal scroll lines.
    ///   - deltaY: Vertical scroll lines (negative = scroll down, positive = scroll up).
    public func scrollProcess(pid: pid_t, at point: CGPoint, deltaX: Int32 = 0, deltaY: Int32 = 0) throws {
        try validateProcessScrollTarget(pid: pid, at: point)
        guard isTrusted else { throw SynthesizerError.accessibilityPermissionDenied }
        let targetPoint = point

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw SynthesizerError.eventCreationFailed
        }

        event.location = targetPoint
        try validateProcessScrollTarget(pid: pid, at: targetPoint)
        event.postToPid(pid)
    }

    /// Background delivery checks the explicitly addressed process/window, independent of chat focus.
    func validateProcessScrollTarget(pid: pid_t, at point: CGPoint) throws {
        try Task.checkCancellation()
        if let expected = Self.expectedTargetPID, expected != pid { throw SynthesizerError.targetChanged }
        if let frame = try scopedWindowFrame(), !frame.contains(point) { throw SynthesizerError.targetChanged }
        try validateDisplayCoordinate(point)
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else {
            throw SynthesizerError.targetChanged
        }
    }

    /// Emergency release of all mouse buttons and keyboard modifiers.
    /// Ensures the system HID is not left in a dragging or modifier-down state if an action loop is interrupted.
    public func releaseAllHeldEvents() {
        guard isTrusted else { return }
        let currentPoint = (try? cursorPosition()) ?? CGPoint(x: 100, y: 100)

        // 1. Post mouse-up events for all standard buttons (left, right, middle/other)
        let mouseReleases: [(CGEventType, CGMouseButton)] = [
            (.leftMouseUp, .left),
            (.rightMouseUp, .right),
            (.otherMouseUp, .center)
        ]

        for (mouseType, button) in mouseReleases {
            if let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseType,
                mouseCursorPosition: currentPoint,
                mouseButton: button
            ) {
                upEvent.post(tap: .cghidEventTap)
            }
        }

        // 2. Clear all modifier keys (Cmd, Shift, Alt, Ctrl, Fn)
        if let dummyEvent = CGEvent(source: nil) {
            dummyEvent.flags = []
            dummyEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    public func pressKeyCode(_ keyCode: UInt16, modifiers: CGEventFlags = []) throws {
        try ensureInputTarget()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw SynthesizerError.eventCreationFailed
        }

        if !modifiers.isEmpty {
            down.flags = modifiers
            up.flags = modifiers
        }

        try ensureInputTarget()
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
        up.post(tap: .cghidEventTap)
    }

    private func focusedAXElement(pid: pid_t, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func ensureInputTarget() throws {
        try Task.checkCancellation()
        guard let expected = Self.expectedTargetPID else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expected else { throw SynthesizerError.targetChanged }
        if let windowID = Self.expectedTargetWindowID {
            guard let focused = focusedAXElement(pid: expected, attribute: kAXFocusedWindowAttribute),
                  let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
                  let entry = info.first,
                  (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expected,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let expectedFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { throw SynthesizerError.targetChanged }
            var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &rawPosition) == .success,
                  AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let rawPosition, let rawSize, CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { throw SynthesizerError.targetChanged }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
                  AXValueGetValue(rawSize as! AXValue, .cgSize, &size), CGRect(origin: point, size: size) == expectedFrame else { throw SynthesizerError.targetChanged }
            var rawTitle: CFTypeRef?
            guard AXUIElementCopyAttributeValue(focused, kAXTitleAttribute as CFString, &rawTitle) == .success,
                  let title = rawTitle as? String,
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { throw SynthesizerError.targetChanged }
            let matches = windows.filter { item in
                guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expected,
                      (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      item[kCGWindowName as String] as? String == title,
                      let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return false }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary) == expectedFrame
            }
            guard matches.count == 1, (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID else { throw SynthesizerError.targetChanged }
        }
    }

    private func scopedWindowFrame() throws -> CGRect? {
        guard let windowID = Self.expectedTargetWindowID else { return nil }
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = info.first,
              Self.expectedTargetPID == nil || (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == Self.expectedTargetPID,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), !frame.isEmpty else { throw SynthesizerError.targetChanged }
        return frame
    }

    private func ensureTrusted() throws {
        try ensureInputTarget()
        guard isTrusted else {
            throw SynthesizerError.accessibilityPermissionDenied
        }
    }

    /// Clamps a coordinate point to stay within active display bounds, or returns the original point if valid.
    public func clampedCoordinate(_ point: CGPoint) -> CGPoint {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return point }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        for displayID in displays {
            let bounds = CGDisplayBounds(displayID)
            if bounds.contains(point) {
                return point
            }
        }

        // Clamp to nearest active display's interior
        if let primary = displays.first {
            let bounds = CGDisplayBounds(primary)
            let clampedX = min(max(point.x, bounds.minX + 20), bounds.maxX - 20)
            let clampedY = min(max(point.y, bounds.minY + 20), bounds.maxY - 20)
            return CGPoint(x: clampedX, y: clampedY)
        }

        return point
    }

    public func validateCoordinate(_ point: CGPoint) throws {
        if let frame = try scopedWindowFrame() {
            guard frame.contains(point),
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                  let hit = windows.first(where: { item in
                      guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
                            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                            (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { return false }
                      return frame.contains(point)
                  }), (hit[kCGWindowNumber as String] as? NSNumber)?.uint32Value == Self.expectedTargetWindowID else { throw SynthesizerError.targetChanged }
        }
        try validateDisplayCoordinate(point)
    }

    private func validateDisplayCoordinate(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw SynthesizerError.coordinateOutOfBounds(x: point.x, y: point.y)
        }
        // Find if the point is within any active display.
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else {
            throw SynthesizerError.coordinateOutOfBounds(x: point.x, y: point.y)
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        let inAnyDisplay = displays.contains { displayID in
            let bounds = CGDisplayBounds(displayID)
            return bounds.contains(point)
        }

        guard inAnyDisplay else {
            throw SynthesizerError.coordinateOutOfBounds(x: point.x, y: point.y)
        }
    }

    /// Parses a chord string like "cmd+shift+a" or "Return" into a CGKeyCode and CGEventFlags.
    public func parseKeyChord(_ chord: String) throws -> (UInt16, CGEventFlags) {
        let parts = chord
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard !parts.isEmpty else {
            throw SynthesizerError.unknownKey(chord)
        }

        var flags: CGEventFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "cmd", "command", "super":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "fn":
                flags.insert(.maskSecondaryFn)
            default:
                if keyPart == nil {
                    keyPart = part
                } else {
                    throw SynthesizerError.unknownKey(chord)
                }
            }
        }

        guard let targetKey = keyPart else {
            throw SynthesizerError.unknownKey(chord)
        }

        guard let keyCode = KeyCodeMap.lookup(targetKey) else {
            throw SynthesizerError.unknownKey(targetKey)
        }

        return (keyCode, flags)
    }
}

// MARK: - KeyCodeMap

public enum KeyCodeMap {
    public static func lookup(_ key: String) -> UInt16? {
        let normalized = key.lowercased()
        if let special = specialKeys[normalized] {
            return special
        }
        if normalized.count == 1, let char = normalized.first {
            return characterKeys[char]
        }
        return nil
    }

    private static let specialKeys: [String: UInt16] = [
        "return": UInt16(kVK_Return),
        "enter": UInt16(kVK_Return),
        "tab": UInt16(kVK_Tab),
        "space": UInt16(kVK_Space),
        "backspace": UInt16(kVK_Delete),
        "delete": UInt16(kVK_Delete),
        "forwarddelete": UInt16(kVK_ForwardDelete),
        "escape": UInt16(kVK_Escape),
        "esc": UInt16(kVK_Escape),
        "left": UInt16(kVK_LeftArrow),
        "right": UInt16(kVK_RightArrow),
        "down": UInt16(kVK_DownArrow),
        "up": UInt16(kVK_UpArrow),
        "home": UInt16(kVK_Home),
        "end": UInt16(kVK_End),
        "pageup": UInt16(kVK_PageUp),
        "pagedown": UInt16(kVK_PageDown),
        "f1": UInt16(kVK_F1),
        "f2": UInt16(kVK_F2),
        "f3": UInt16(kVK_F3),
        "f4": UInt16(kVK_F4),
        "f5": UInt16(kVK_F5),
        "f6": UInt16(kVK_F6),
        "f7": UInt16(kVK_F7),
        "f8": UInt16(kVK_F8),
        "f9": UInt16(kVK_F9),
        "f10": UInt16(kVK_F10),
        "f11": UInt16(kVK_F11),
        "f12": UInt16(kVK_F12),
    ]

    private static let characterKeys: [Character: UInt16] = [
        "a": UInt16(kVK_ANSI_A),
        "b": UInt16(kVK_ANSI_B),
        "c": UInt16(kVK_ANSI_C),
        "d": UInt16(kVK_ANSI_D),
        "e": UInt16(kVK_ANSI_E),
        "f": UInt16(kVK_ANSI_F),
        "g": UInt16(kVK_ANSI_G),
        "h": UInt16(kVK_ANSI_H),
        "i": UInt16(kVK_ANSI_I),
        "j": UInt16(kVK_ANSI_J),
        "k": UInt16(kVK_ANSI_K),
        "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M),
        "n": UInt16(kVK_ANSI_N),
        "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P),
        "q": UInt16(kVK_ANSI_Q),
        "r": UInt16(kVK_ANSI_R),
        "s": UInt16(kVK_ANSI_S),
        "t": UInt16(kVK_ANSI_T),
        "u": UInt16(kVK_ANSI_U),
        "v": UInt16(kVK_ANSI_V),
        "w": UInt16(kVK_ANSI_W),
        "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y),
        "z": UInt16(kVK_ANSI_Z),
        "0": UInt16(kVK_ANSI_0),
        "1": UInt16(kVK_ANSI_1),
        "2": UInt16(kVK_ANSI_2),
        "3": UInt16(kVK_ANSI_3),
        "4": UInt16(kVK_ANSI_4),
        "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6),
        "7": UInt16(kVK_ANSI_7),
        "8": UInt16(kVK_ANSI_8),
        "9": UInt16(kVK_ANSI_9),
        "-": UInt16(kVK_ANSI_Minus),
        "=": UInt16(kVK_ANSI_Equal),
        "[": UInt16(kVK_ANSI_LeftBracket),
        "]": UInt16(kVK_ANSI_RightBracket),
        ";": UInt16(kVK_ANSI_Semicolon),
        "'": UInt16(kVK_ANSI_Quote),
        ",": UInt16(kVK_ANSI_Comma),
        ".": UInt16(kVK_ANSI_Period),
        "/": UInt16(kVK_ANSI_Slash),
        "\\": UInt16(kVK_ANSI_Backslash),
        "`": 0x32,
    ]
}

// MARK: - EventSynthesizing Protocol

/// Abstraction for low-level mouse and keyboard event synthesis.
/// In production, implemented by EventSynthesizer via Quartz CGEvent.
/// In testing, implemented by MockEventSynthesizer recording executed actions.
public protocol EventSynthesizing: Sendable {
    /// True only for implementations that never post input to another process.
    var isSimulation: Bool { get }
    var isTrusted: Bool { get }
    func cursorPosition() throws -> CGPoint
    func mouseMove(to point: CGPoint) throws
    func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws
    func drag(from start: CGPoint, to end: CGPoint) throws
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws
    func typeText(_ text: String) throws
    func pressKey(_ key: String) throws
    func releaseAllHeldEvents()
}

public extension EventSynthesizing {
    var isSimulation: Bool { false }
    func click(at point: CGPoint? = nil, button: MouseButton = .left, clickCount: Int = 1) throws {
        try click(at: point, button: button, clickCount: clickCount)
    }

    func scroll(deltaX: Int32 = 0, deltaY: Int32 = 0, at point: CGPoint? = nil, targetPID: pid_t? = nil) throws {
        try scroll(deltaX: deltaX, deltaY: deltaY, at: point, targetPID: targetPID)
    }
}

extension EventSynthesizer: EventSynthesizing {}

/// An EventSynthesizing implementation for non-destructive dry-run evaluations and testing.
/// Records all requested actions in an in-memory audit log without synthesizing Quartz CGEvents.
public final class DryRunEventSynthesizer: EventSynthesizing, @unchecked Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "DryRunEventSynthesizer")
    public let isSimulation = true
    public let isTrusted: Bool = true
    private let lock = NSLock()
    private var _recordedActions: [String] = []
    public var onAction: (@Sendable (String) -> Void)?

    public var recordedActions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedActions
    }

    public init(onAction: (@Sendable (String) -> Void)? = nil) {
        self.onAction = onAction
    }

    public func cursorPosition() throws -> CGPoint {
        CGPoint(x: 100, y: 100)
    }

    public func mouseMove(to point: CGPoint) throws {
        let msg = "mouseMove(to: (\(Int(point.x)), \(Int(point.y))))"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws {
        let ptStr = point.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "current"
        let msg = "click(at: \(ptStr), button: \(button), clickCount: \(clickCount))"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func drag(from start: CGPoint, to end: CGPoint) throws {
        let msg = "drag(from: (\(Int(start.x)), \(Int(start.y))), to: (\(Int(end.x)), \(Int(end.y))))"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws {
        let ptStr = point.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "current"
        let msg = "scroll(deltaX: \(deltaX), deltaY: \(deltaY), at: \(ptStr))"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func typeText(_ text: String) throws {
        let msg = "typeText(\"\(text)\")"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func pressKey(_ key: String) throws {
        let msg = "pressKey(\"\(key)\")"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func releaseAllHeldEvents() {
        let msg = "releaseAllHeldEvents()"
        log.info("[DRY-RUN] \(msg)")
        lock.lock()
        _recordedActions.append(msg)
        lock.unlock()
        onAction?(msg)
    }

    public func reset() {
        lock.lock()
        _recordedActions.removeAll()
        lock.unlock()
    }
}
