import AppKit
import Foundation
import Testing

@testable import mca

@Suite("Advice card keystroke script")
struct AdviceActionScriptTests {
    @Test("does not press Return unless asked")
    func noReturnByDefault() {
        let script = ScreenWatcher.keystrokeScript(payload: "y", appName: "Terminal", pressReturn: false)
        #expect(script.contains("keystroke \"y\""))
        #expect(!script.contains("key code 36"))
    }

    @Test("presses Return when the user chose to")
    func returnWhenConfirmed() {
        let script = ScreenWatcher.keystrokeScript(payload: "y", appName: "Terminal", pressReturn: true)
        #expect(script.contains("key code 36"))
    }

    @Test("a hostile app name cannot break out of its string literal")
    func appNameIsEscaped() {
        let hostile = "Notes\" to activate\ndo shell script \"touch /tmp/pwned\ntell application \"Finder"
        let script = ScreenWatcher.keystrokeScript(payload: "y", appName: hostile, pressReturn: false)
        let firstLine = script.components(separatedBy: "\n")[0]
        #expect(firstLine == "tell application \"Notes\\\" to activate\\ndo shell script \\\"touch /tmp/pwned\\ntell application \\\"Finder\" to activate")
        #expect(!script.contains("\ndo shell script"))
    }

    @Test("a hostile payload is escaped too")
    func payloadIsEscaped() {
        let script = ScreenWatcher.keystrokeScript(payload: "x\" \nend tell\ndo shell script \"id", appName: "Terminal", pressReturn: false)
        #expect(!script.contains("\ndo shell script"))
        #expect(script.contains("set the clipboard to \"x\\\" \\nend tell\\ndo shell script \\\"id\""))
    }

    @Test("Type Only never turns a newline into a Return key press", arguments: ["a\nb", "a\r\nb", "a\rb", "a\u{2028}b"])
    func multilineTypeOnlyDoesNotSubmit(payload: String) {
        let script = ScreenWatcher.keystrokeScript(payload: payload, appName: "Terminal", pressReturn: false)
        #expect(!script.contains("key code 36"))
        // Pasted as one block, not typed key by key.
        #expect(script.contains("keystroke \"v\" using command down"))
        #expect(!script.contains("keystroke \"a"))
        #expect(script.contains("set the clipboard to \"a"))
    }

    @Test("a tab in the payload is pasted rather than moving focus")
    func tabIsPasted() {
        let script = ScreenWatcher.keystrokeScript(payload: "a\tb", appName: "Terminal", pressReturn: false)
        #expect(script.contains("keystroke \"v\" using command down"))
    }

    @Test("only Type and Press Return submits, and exactly once")
    func returnOnlyWhenChosenAndOnce() {
        let script = ScreenWatcher.keystrokeScript(payload: "a\nb", appName: "Terminal", pressReturn: true)
        #expect(script.components(separatedBy: "key code 36").count == 2)
    }

    @Test("a single line is still typed, not pasted")
    func singleLineIsTyped() {
        let script = ScreenWatcher.keystrokeScript(payload: "ls -la", appName: "Terminal", pressReturn: false)
        #expect(script.contains("keystroke \"ls -la\""))
        #expect(!script.contains("set the clipboard"))
    }
}

@Suite("Advice card clipboard handling")
@MainActor
struct AdviceActionClipboardTests {
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("mca-test-\(UUID().uuidString)"))
    }

    @Test("restoring puts back what the user had copied, including non-text types")
    func restoresOriginalItems() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("the user's own text", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        board.clearContents()
        board.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(board)
        board.clearContents()
        board.setString("approved payload", forType: .string)
        snapshot.restore(to: board)

        #expect(board.string(forType: .string) == "the user's own text")
        #expect(board.data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3]))
    }

    @Test("restoring an empty clipboard leaves it empty")
    func restoresEmpty() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let snapshot = PasteboardSnapshot.capture(board)
        board.setString("approved payload", forType: .string)
        snapshot.restore(to: board)
        #expect(board.string(forType: .string) == nil)
    }

    @Test("only a payload with control characters needs the clipboard", arguments: [
        ("ls -la", false), ("a\nb", true), ("a\tb", true), ("a\u{2028}b", true),
    ])
    func needsClipboard(payload: String, expected: Bool) {
        #expect(ScreenWatcher.needsPaste(payload) == expected)
    }
}
