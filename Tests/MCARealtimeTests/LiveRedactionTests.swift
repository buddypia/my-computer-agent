import Foundation
import Testing

@testable import MCARealtime

@Suite("Gemini Live key redaction")
struct LiveRedactionTests {
    private let key = "AIzaSyExampleKey1234567890abcdefghij"

    @Test("the literal key is masked wherever it appears")
    func masksLiteralKey() {
        let text = "failed: wss://host/ws?key=\(key) refused (\(key))"
        let clean = GeminiLiveSession.redact(text, apiKey: key)
        #expect(!clean.contains(key))
    }

    @Test("a key= query value is masked even when the key itself is not known")
    func masksQueryParameter() {
        let clean = GeminiLiveSession.redact(
            "could not connect to wss://h/ws?alt=x&key=SomethingElse123&b=1", apiKey: key)
        #expect(!clean.contains("SomethingElse123"))
        #expect(clean.contains("&b=1"))
    }

    @Test("text without a key is unchanged")
    func leavesOtherTextAlone() {
        #expect(GeminiLiveSession.redact("the server closed the session (code 1008)", apiKey: key)
            == "the server closed the session (code 1008)")
    }
}
