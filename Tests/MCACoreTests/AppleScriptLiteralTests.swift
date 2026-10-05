import Foundation
import Testing

@testable import MCACore

@Suite("AppleScript string literals")
struct AppleScriptLiteralTests {
    @Test("escapes quotes and backslashes", arguments: [
        ("plain", "plain"),
        ("say \"hi\"", "say \\\"hi\\\""),
        ("C:\\path", "C:\\\\path"),
        ("a\\\"b", "a\\\\\\\"b"),
    ])
    func escapes(input: String, expected: String) {
        #expect(AppleScriptLiteral.escape(input) == expected)
    }

    @Test("escapes control characters so a literal cannot span lines")
    func controlCharacters() {
        #expect(AppleScriptLiteral.escape("a\nb\rc\td") == "a\\nb\\rc\\td")
    }

    @Test("a closing-quote injection stays inside the literal")
    func injection() {
        let hostile = "Notes\" to quit\ndo shell script \"touch /tmp/pwned"
        let quoted = AppleScriptLiteral.quoted(hostile)
        #expect(quoted == "\"Notes\\\" to quit\\ndo shell script \\\"touch /tmp/pwned\"")

        // Every interior quote is backslash-escaped, so only the outer pair
        // is live.
        var live = 0
        var escaped = false
        for character in quoted {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { live += 1 }
        }
        #expect(live == 2)
    }

    @Test("non-ASCII text passes through untouched")
    func unicode() {
        #expect(AppleScriptLiteral.escape("日本語 한국어 🙂") == "日本語 한국어 🙂")
    }

    @Test("quoted wraps in quotes")
    func quoted() {
        #expect(AppleScriptLiteral.quoted("y") == "\"y\"")
    }
}
