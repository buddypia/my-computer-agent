import Foundation
import Testing

@testable import MCAReasoning

@Suite("Anthropic stream decoding")
struct AnthropicStreamDecoderTests {
    final class Sink: @unchecked Sendable {
        var events: [GenerationEvent] = []
        var channel: GenerationChannel { GenerationChannel { [self] in events.append($0) } }
        var toolCalls: [ToolCall] {
            events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
        }
    }

    static func decode(_ lines: [String]) throws -> (AnthropicExecutor.StreamDecoder, Sink) {
        var decoder = AnthropicExecutor.StreamDecoder()
        let sink = Sink()
        for line in lines {
            try decoder.consume(try #require(parseJSONObject(line)), into: sink.channel)
        }
        return (decoder, sink)
    }

    @Test("Signed thinking is attached to the tool call that follows it")
    func thinkingRoundTrip() throws {
        let (decoder, sink) = try Self.decode([
            #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90,"cache_creation_input_tokens":5}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"open"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let call = try #require(sink.toolCalls.first)
        let blocks = AnthropicExecutor.thinkingBlocks(from: call)
        #expect(blocks.first?["signature"] as? String == "sig")
        #expect(blocks.first?["thinking"] as? String == "plan")
        #expect(decoder.finishReason == .toolCalls)
        // input_tokens excludes cache traffic on Anthropic; normalized to the whole prompt.
        #expect(decoder.usage.inputTokens == 105)
        #expect(decoder.usage.cachedInputTokens == 90)
        #expect(decoder.usage.outputTokens == 7)
    }

    @Test("A tool call truncated by max_tokens is not emitted")
    func truncatedToolCall() throws {
        let (decoder, sink) = try Self.decode([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"click"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(sink.toolCalls.isEmpty)
        #expect(decoder.finishReason == .length)
    }

    @Test("A stream without message_stop finishes as an error, not a clean stop")
    func cutOffStream() throws {
        let (decoder, _) = try Self.decode([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}"#,
        ])
        #expect(!decoder.sawMessageStop)
        #expect(decoder.finishReason == .error)
    }

    @Test("A message_delta without cache fields keeps the counts message_start gave")
    func partialUsageDelta() throws {
        let (decoder, _) = try Self.decode([
            #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90}}}"#,
            #"{"type":"message_delta","delta":{},"usage":{"input_tokens":10,"output_tokens":3}}"#,
        ])
        #expect(decoder.usage.inputTokens == 100)
        #expect(decoder.usage.cachedInputTokens == 90)
    }

    @Test("An in-stream overload maps to a retryable status")
    func overloadIsRetryable() {
        #expect(throws: LanguageModelError.self) {
            _ = try Self.decode([
                #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            ])
        }
        #expect(AnthropicExecutor.StreamDecoder.status(forErrorType: "overloaded_error") == 529)
        #expect(LanguageModelError.http(status: 529, body: "").isRetryable)
        #expect(!LanguageModelError.http(status: 400, body: "invalid_request_error: bad").isRetryable)
    }

    @Test("Refusal surfaces as contentFilter")
    func refusal() throws {
        let (decoder, _) = try Self.decode([
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(decoder.finishReason == .contentFilter)
    }
}
