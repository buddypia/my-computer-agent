import AppKit
import Foundation
import Testing

@testable import MCAPresentation

/// Titled windows behave like ordinary macOS windows: resizable from the edges,
/// with minimize and zoom buttons. A `.utilityWindow` panel shows only a close
/// button, and a window without `.resizable` cannot be resized at all — both
/// shipped once without anyone noticing.
@Suite("Window chrome", .serialized)
@MainActor
struct WindowChromeTests {
    @Test("every titled window in Sources is resizable and miniaturizable")
    func titledWindowsHaveStandardControls() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let mask = try Regex(#"styleMask:\s*\[([^\]]*)\]"#)
        var titled: Set<String> = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: mask) {
                let options = String(text[match.range])
                guard options.contains(".titled") else { continue }
                titled.insert(file.lastPathComponent)
                let place = "\(file.lastPathComponent): \(options)"
                #expect(options.contains(".resizable"), "\(place)")
                #expect(options.contains(".miniaturizable"), "\(place)")
                #expect(!options.contains(".utilityWindow"), "\(place)")
            }
        }
        // The scan has to see the windows it guards, or a moved Sources/ or a
        // rewritten styleMask passes it vacuously.
        #expect(titled.isSuperset(of: [
            "ChatWindow.swift", "ScreenPicker.swift", "SettingsWindow.swift", "SetupWindow.swift",
        ]), "\(titled)")
    }

    @Test("a minimized chat is not on screen until restored from the Dock or toggled back")
    func chatMiniaturize() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }
        chat.present()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)

        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized && !state.isChatOpen }

        // The Dock path: `present()` would set the flag itself.
        window.deminiaturize(nil)
        try await waitUntil { !window.isMiniaturized && state.isChatOpen }

        // The hot key / HUD button path on a minimized chat brings it back.
        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized && !state.isChatOpen }
        chat.toggle()
        try await waitUntil { !window.isMiniaturized && state.isChatOpen }
    }

    @Test("minimizing the screen picker stops its thumbnail refresh")
    func pickerMiniaturize() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let picker = ScreenPickerWindow(state: state)
        defer { picker.destroy() }
        picker.present()
        let window = try #require(NSApp.windows.first { $0.delegate === picker })

        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized && !state.isScreenPickerOpen }

        window.deminiaturize(nil)
        try await waitUntil { !window.isMiniaturized && state.isScreenPickerOpen }
    }

    /// The minimize animation takes about 1.5 s locally; 10 s leaves room for
    /// a loaded CI runner, and a timeout fails here rather than at a later,
    /// less telling expectation.
    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "timed out", sourceLocation: sourceLocation)
    }
}
