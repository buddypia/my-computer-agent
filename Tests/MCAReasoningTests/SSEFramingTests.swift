import Foundation
import Testing

@testable import MCAReasoning

/// Framing tests for the shared SSE transport.
///
/// These exist because the original implementation was built on
/// `AsyncLineSequence`, which silently drops empty lines — the very thing that
/// terminates an SSE event. Every event in a response arrived concatenated with
/// the next, each executor's JSON parse failed, and a model answer that spanned
/// more than one chunk surfaced as no answer at all. Nothing in the suite caught
/// it because the framing was only ever exercised against a live provider.
@Suite("SSE framing")
struct SSEFramingTests {
    /// Feeds a recorded body through the real decoder, one byte at a time, the
    /// way `URLSession.AsyncBytes` delivers it.
    private func events(_ body: String) async throws -> [String] {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Array(body.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var collected: [String] = []
        for try await payload in HTTPStreaming.events(from: bytes) {
            collected.append(payload)
        }
        return collected
    }

    @Test("Each event is delivered separately")
    func separatesEvents() async throws {
        let body = "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"
        #expect(try await events(body) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    /// The exact shape Gemini sends: CRLF terminators, two chunks, the answer
    /// text in the first one.
    @Test("CRLF-framed chunks are not glued together")
    func handlesCarriageReturns() async throws {
        let body = "data: {\"text\":\"PONG\"}\r\n\r\ndata: {\"finishReason\":\"STOP\"}\r\n\r\n"
        let collected = try await events(body)
        #expect(collected.count == 2)
        for payload in collected {
            #expect(parseJSONObject(payload) != nil, "payload must be valid JSON on its own")
        }
    }

    @Test("A body that ends without a blank line still yields its last event")
    func flushesTrailingEvent() async throws {
        #expect(try await events("data: {\"a\":1}") == [#"{"a":1}"#])
    }

    @Test("Non-data fields and comments are ignored")
    func skipsOtherFields() async throws {
        let body = ": ping\nevent: content_block_delta\nid: 7\ndata: {\"a\":1}\n\n"
        #expect(try await events(body) == [#"{"a":1}"#])
    }

    /// SSE joins a multi-line payload with newlines. No provider here splits
    /// JSON that way, but the spec allows it and concatenating without the
    /// separator would corrupt any payload that relied on it.
    @Test("Multiple data lines in one event join with a newline")
    func joinsMultiLinePayload() async throws {
        #expect(try await events("data: {\ndata: \"a\":1}\n\n") == ["{\n\"a\":1}"])
    }

    @Test("[DONE] ends the stream and is not delivered")
    func stopsAtDoneSentinel() async throws {
        let body = "data: {\"a\":1}\n\ndata: [DONE]\n\ndata: {\"b\":2}\n\n"
        #expect(try await events(body) == [#"{"a":1}"#])
    }

    @Test("Only the first space after the colon is a separator")
    func keepsPayloadWhitespace() async throws {
        #expect(try await events("data:  {\"a\":1}\n\n") == [#" {"a":1}"#])
    }
}
