import Foundation
import MCACore
import Testing

@testable import MCAReasoning

/// Asserts that each executor encodes the shared transcript into the shape its
/// provider actually documents.
///
/// These run without a network, but they are not self-referential: the expected
/// keys are the provider's published wire format, so a wrong key fails here
/// rather than as a confusing 400 at runtime.
@Suite("Provider wire formats")
struct WireFormatTests {
    static let transcript: [TranscriptEntry] = [
        .instructions("You are terse."),
        .prompt(Prompt(text: "What is on my screen?")),
        .response("A terminal."),
        .toolCalls([ToolCall(
            id: "call_1", name: "search_context",
            arguments: Data(#"{"query":"error"}"#.utf8))]),
        .toolOutput(ToolOutput(callID: "call_1", name: "search_context", content: "no matches")),
        // Must be dropped by every provider: replaying prior thinking inflates
        // input tokens and some providers reject it outright.
        .reasoning("internal deliberation"),
    ]

    static func request(
        tools: Bool = false,
        images: Bool = false,
        reasoning: ReasoningLevel? = nil,
        schema: Bool = false
    ) -> GenerationRequest {
        var entries = transcript
        if images {
            entries.append(.prompt(Prompt(
                text: "And this?",
                images: [ImageAttachment(data: Data([0x89, 0x50]), mimeType: "image/png")])))
        }
        return GenerationRequest(
            transcript: entries,
            tools: tools ? [ToolDefinition(
                name: "search_context", description: "Search history.",
                parameters: Data(#"{"type":"object","properties":{}}"#.utf8))] : [],
            options: GenerationOptions(
                temperature: 0.3,
                maximumResponseTokens: 1024,
                reasoningLevel: reasoning,
                responseSchema: schema ? Data(#"{"type":"object"}"#.utf8) : nil))
    }

    static func serialise(_ body: [String: Any]) throws -> String {
        String(
            data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys),
            encoding: .utf8) ?? ""
    }

    // MARK: - Gemini

    @Test("Gemini splits system instruction out of contents")
    func geminiSystemInstruction() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request())

        let system = try #require(body["systemInstruction"] as? [String: Any])
        let parts = try #require(system["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "You are terse.")

        // Gemini uses "model", not "assistant", for its own turns.
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.contains { $0["role"] as? String == "model" })
        #expect(!contents.contains { $0["role"] as? String == "assistant" })
    }

    @Test("Gemini encodes tool calls and results as function parts")
    func geminiFunctionCalls() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request(tools: true))

        let contents = try #require(body["contents"] as? [[String: Any]])
        let allParts = contents.flatMap { ($0["parts"] as? [[String: Any]]) ?? [] }

        let call = try #require(allParts.compactMap { $0["functionCall"] as? [String: Any] }.first)
        #expect(call["name"] as? String == "search_context")
        // Arguments must be a JSON object, not the string we carry internally.
        #expect(call["args"] is [String: Any])

        let result = try #require(
            allParts.compactMap { $0["functionResponse"] as? [String: Any] }.first)
        #expect(result["name"] as? String == "search_context")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["functionDeclarations"] != nil)
    }

    @Test("Gemini functionDeclarations sanitize unsupported JSON Schema keys (additionalProperties, $schema)")
    func geminiFunctionDeclarationsSanitizeUnsupportedKeys() throws {
        let dirtySchema = Data("""
        {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "nested": {
                    "type": "object",
                    "properties": {"k": {"type": "string"}},
                    "additionalProperties": false
                }
            },
            "additionalProperties": {"type": "string"}
        }
        """.utf8)
        let tool = ToolDefinition(name: "custom_tool", description: "A test tool", parameters: dirtySchema)
        let request = GenerationRequest(
            transcript: [.prompt(Prompt(text: "test"))],
            tools: [tool]
        )
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k").buildBody(request)
        let tools = try #require(body["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        let decl = try #require(declarations.first)
        let params = try #require(decl["parameters"] as? [String: Any])

        #expect(params["$schema"] == nil)
        #expect(params["additionalProperties"] == nil)
        let props = try #require(params["properties"] as? [String: Any])
        let nested = try #require(props["nested"] as? [String: Any])
        #expect(nested["additionalProperties"] == nil)
        #expect(nested["type"] as? String == "object")
    }

    /// Gemini 3 rejects a replayed tool call whose signature is missing with
    /// HTTP 400 — which is not retryable, so the whole answer fails on the round
    /// after the model asks for a tool. Every question that needs one.
    @Test("Gemini replays the thought signature next to the function call")
    func geminiThoughtSignature() throws {
        let request = GenerationRequest(transcript: [
            .prompt(Prompt(text: "What is on my screen?")),
            .toolCalls([ToolCall(
                id: "call_1", name: "search_context",
                arguments: Data("{}".utf8),
                providerState: ["thoughtSignature": "SIG"])]),
        ])
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k").buildBody(request)

        let contents = try #require(body["contents"] as? [[String: Any]])
        let allParts = contents.flatMap { ($0["parts"] as? [[String: Any]]) ?? [] }
        let part = try #require(allParts.first { $0["functionCall"] != nil })

        // A sibling of `functionCall` within the part, not a field inside it.
        #expect(part["thoughtSignature"] as? String == "SIG")
    }

    /// A round answered by the Anthropic/OpenAI fallback leaves calls with no
    /// Gemini signature in the transcript. Replaying them to Gemini failed the
    /// whole turn with HTTP 400 (`missing a thought_signature`).
    @Test("Gemini signs the first unsigned call of a step with the documented bypass value")
    func geminiUnsignedCallsGetBypassSignature() throws {
        let request = GenerationRequest(transcript: [
            .prompt(Prompt(text: "Collect posts")),
            .toolCalls([
                ToolCall(id: "a", name: "scroll_pinned_window", arguments: Data("{}".utf8)),
                ToolCall(id: "b", name: "read_screen", arguments: Data("{}".utf8)),
            ]),
            .toolOutput(ToolOutput(callID: "a", name: "scroll_pinned_window", content: "ok")),
            .toolOutput(ToolOutput(callID: "b", name: "read_screen", content: "ok")),
        ])
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k").buildBody(request)

        let contents = try #require(body["contents"] as? [[String: Any]])
        let callParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(callParts[0]["thoughtSignature"] as? String == "skip_thought_signature_validator")
        // Only the first call of a step is validated; the rest stay untouched.
        #expect(callParts[1]["thoughtSignature"] == nil)

        // Parallel results are grouped into one turn after the calls.
        #expect(contents.count == 3)
        let responseParts = try #require(contents[2]["parts"] as? [[String: Any]])
        #expect(responseParts.count == 2)
    }

    @Test("Gemini treats an empty signature as missing")
    func geminiEmptySignature() throws {
        let request = GenerationRequest(transcript: [
            .prompt(Prompt(text: "Collect posts")),
            .toolCalls([ToolCall(
                id: "a", name: "scroll_pinned_window", arguments: Data("{}".utf8),
                providerState: ["thoughtSignature": ""])]),
        ])
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k").buildBody(request)

        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(parts[0]["thoughtSignature"] as? String == "skip_thought_signature_validator")
    }

    @Test("Gemini keeps sequential steps as separate turns")
    func geminiSequentialSteps() throws {
        let request = GenerationRequest(transcript: [
            .prompt(Prompt(text: "Collect posts")),
            .toolCalls([ToolCall(id: "a", name: "x", arguments: Data("{}".utf8),
                                 providerState: ["thoughtSignature": "S1"])]),
            .toolOutput(ToolOutput(callID: "a", name: "x", content: "1")),
            .toolCalls([ToolCall(id: "b", name: "y", arguments: Data("{}".utf8),
                                 providerState: ["thoughtSignature": "S2"])]),
            .toolOutput(ToolOutput(callID: "b", name: "y", content: "2")),
        ])
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k").buildBody(request)

        let contents = try #require(body["contents"] as? [[String: Any]])
        // A result must never be merged across a model turn (FC1, FR1, FC2, FR2).
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user", "model", "user"])
        let second = try #require(contents[3]["parts"] as? [[String: Any]])
        #expect(second[0]["thoughtSignature"] as? String == "S2")
    }

    @Test("Gemini uses thinkingLevel, not thinkingBudget")
    func geminiThinkingLevel() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request(reasoning: .high))

        let config = try #require(body["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        // Gemini 3.x replaced the numeric budget with a discrete level; sending
        // the old key is silently ignored, producing minimal thinking.
        #expect(thinking["thinkingLevel"] as? String == "high")
        #expect(thinking["thinkingBudget"] == nil)
    }

    @Test("Gemini maps minimal reasoning to low thinkingLevel")
    func geminiMinimalThinkingLevel() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request(reasoning: .minimal))

        let config = try #require(body["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "low")
        #expect(thinking["thinkingBudget"] == nil)
    }

    @Test("Gemini omits thinkingConfig on models without reasoning capability")
    func geminiNonReasoningModel() throws {
        let body = GeminiExecutor(model: "gemini-1.5-flash", apiKey: "k")
            .buildBody(Self.request(reasoning: .high))

        let config = body["generationConfig"] as? [String: Any]
        #expect(config?["thinkingConfig"] == nil)
    }

    @Test("Gemini 2.5 uses thinkingBudget")
    func gemini25ThinkingBudget() throws {
        let body = GeminiExecutor(model: "gemini-2.5-flash", apiKey: "k")
            .buildBody(Self.request(reasoning: .minimal))

        let config = try #require(body["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingBudget"] as? Int == 0)
        #expect(thinking["thinkingLevel"] == nil)
    }

    @Test("Gemini sends inline image data")
    func geminiVision() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request(images: true))

        let contents = try #require(body["contents"] as? [[String: Any]])
        let allParts = contents.flatMap { ($0["parts"] as? [[String: Any]]) ?? [] }
        let inline = try #require(allParts.compactMap { $0["inlineData"] as? [String: Any] }.first)
        #expect(inline["mimeType"] as? String == "image/png")
        #expect(inline["data"] is String)
    }

    @Test("Gemini structured output sets both mime type and schema")
    func geminiSchema() throws {
        let body = GeminiExecutor(model: "gemini-3.8-flash", apiKey: "k")
            .buildBody(Self.request(schema: true))
        let config = try #require(body["generationConfig"] as? [String: Any])
        // Without the mime type the schema is ignored and prose comes back.
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["responseSchema"] != nil)
    }

    // MARK: - Anthropic

    @Test("Anthropic hoists system out of messages and always sets max_tokens")
    func anthropicSystem() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.request())

        #expect(body["system"] as? String == "You are terse.")
        // max_tokens is required by the API; omitting it is a 400.
        #expect(body["max_tokens"] as? Int == 1024)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(!messages.contains { $0["role"] as? String == "system" })
    }

    @Test("Anthropic pairs tool_use with tool_result")
    func anthropicToolBlocks() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.request(tools: true))

        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }

        let use = try #require(blocks.first { $0["type"] as? String == "tool_use" })
        #expect(use["id"] as? String == "call_1")

        let result = try #require(blocks.first { $0["type"] as? String == "tool_result" })
        // The IDs must match or Anthropic rejects the turn.
        #expect(result["tool_use_id"] as? String == "call_1")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["input_schema"] != nil)
    }

    /// A turn with no open tool loop: the fixture transcript ends inside one
    /// whose call carries no signed thinking, which disables a fixed budget.
    static func promptOnly(reasoning: ReasoningLevel?) -> GenerationRequest {
        GenerationRequest(
            transcript: [.instructions("You are terse."), .prompt(Prompt(text: "Why?"))],
            options: GenerationOptions(
                temperature: 0.3, maximumResponseTokens: 1024, reasoningLevel: reasoning))
    }

    @Test("Anthropic keeps the thinking budget below max_tokens")
    func anthropicThinkingBudget() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.promptOnly(reasoning: .high))

        let thinking = try #require(body["thinking"] as? [String: Any])
        let budget = try #require(thinking["budget_tokens"] as? Int)
        let maxTokens = try #require(body["max_tokens"] as? Int)
        // The API requires strict inequality here.
        #expect(budget < maxTokens)
    }

    @Test("Anthropic omits thinking at minimal")
    func anthropicNoThinking() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.request(reasoning: .minimal))
        #expect(body["thinking"] == nil)
    }

    @Test("Anthropic drops temperature when a thinking budget is set")
    func anthropicBudgetDropsTemperature() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.promptOnly(reasoning: .high))
        #expect(body["thinking"] != nil)
        #expect(body["temperature"] == nil)
    }

    @Test("Anthropic runs a fixed-budget turn without thinking when the open tool call is unsigned")
    func anthropicBudgetSkipsUnsignedLoop() throws {
        // The fixture's call has no thinking blocks (as after a Gemini failover);
        // a budget here is the 400 "final assistant message must start with a thinking block".
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k")
            .buildBody(Self.request(reasoning: .high))
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] as? Double == 0.3)
    }

    @Test("Anthropic replays signed thinking ahead of its tool_use and keeps the budget")
    func anthropicReplaysThinking() throws {
        let blocks = #"[{"type":"thinking","thinking":"plan","signature":"sig"}]"#
        let request = GenerationRequest(
            transcript: [
                .prompt(Prompt(text: "Open it")),
                .toolCalls([ToolCall(
                    id: "c1", name: "open", arguments: Data("{}".utf8),
                    providerState: [AnthropicExecutor.thinkingBlocksKey: blocks])]),
                .toolOutput(ToolOutput(callID: "c1", name: "open", content: "ok")),
            ],
            options: GenerationOptions(reasoningLevel: .high))
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k").buildBody(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let content = try #require(assistant["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "thinking")
        #expect(content.first?["signature"] as? String == "sig")
        #expect(content.last?["type"] as? String == "tool_use")
        #expect(body["thinking"] != nil)
    }

    @Test("Anthropic merges same-role turns, drops empty text, and marks cache breakpoints")
    func anthropicMessageShape() throws {
        let request = GenerationRequest(
            transcript: [
                .prompt(Prompt(text: "Go")),
                .response("  "),
                .toolCalls([
                    ToolCall(id: "a", name: "t", arguments: Data("{}".utf8)),
                    ToolCall(id: "b", name: "t", arguments: Data("[1]".utf8)),
                ]),
                .toolOutput(ToolOutput(callID: "a", name: "t", content: "1")),
                .toolOutput(ToolOutput(callID: "b", name: "t", content: "2")),
            ],
            tools: [ToolDefinition(name: "t", description: "d", parameters: Data("{}".utf8))])
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k").buildBody(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])

        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.allSatisfy { $0["type"] as? String == "tool_use" })
        #expect(assistant.allSatisfy { $0["input"] is [String: Any] })

        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.count == 2)
        #expect(results.last?["cache_control"] != nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.last?["cache_control"] != nil)
    }

    @Test("Anthropic model versions drive the wire format, including unreleased names")
    func anthropicVersionClassification() {
        #expect(AnthropicExecutor.version(of: "claude-sonnet-4-20250514")! == (4, 0))
        #expect(AnthropicExecutor.version(of: "anthropic.claude-opus-4-7-v1:0")! == (4, 7))
        #expect(AnthropicExecutor.version(of: "claude-3-7-sonnet-latest")! == (3, 7))
        #expect(AnthropicExecutor.version(of: "my-proxy-alias") == nil)
        #expect(!AnthropicExecutor.usesAdaptiveThinking(model: "claude-sonnet-4-5"))
        #expect(AnthropicExecutor.usesAdaptiveThinking(model: "claude-sonnet-4-6"))
        #expect(!AnthropicExecutor.rejectsSamplingParameters(model: "claude-sonnet-4-6"))
        #expect(AnthropicExecutor.rejectsSamplingParameters(model: "claude-opus-4-7"))
        #expect(AnthropicExecutor.rejectsSamplingParameters(model: "claude-opus-6"))
        #expect(AnthropicExecutor.supportsReasoning(model: "claude-opus-6"))
    }

    @Test("Anthropic puts replayed thinking ahead of text in a merged assistant turn")
    func anthropicThinkingLeadsMergedTurn() throws {
        let blocks = #"[{"type":"thinking","thinking":"plan","signature":"sig"}]"#
        let request = GenerationRequest(
            transcript: [
                .prompt(Prompt(text: "Open it")),
                .response("Opening."),
                .toolCalls([ToolCall(
                    id: "c1", name: "open", arguments: Data("{}".utf8),
                    providerState: [AnthropicExecutor.thinkingBlocksKey: blocks])]),
                .toolOutput(ToolOutput(callID: "c1", name: "open", content: "ok")),
            ],
            options: GenerationOptions(reasoningLevel: .high))
        let body = AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: "k").buildBody(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
    }

    @Test("Anthropic adaptive thinking drops temperature on models that still accept it")
    func anthropicAdaptiveDropsTemperature() throws {
        let thinking = AnthropicExecutor(model: "claude-sonnet-4-6", apiKey: "k")
            .buildBody(Self.promptOnly(reasoning: .medium))
        #expect(thinking["temperature"] == nil)
        let plain = AnthropicExecutor(model: "claude-sonnet-4-6", apiKey: "k")
            .buildBody(Self.promptOnly(reasoning: nil))
        #expect(plain["temperature"] as? Double == 0.3)
    }

    @Test("Anthropic accepts TLS or loopback endpoints only")
    func anthropicEndpointSafety() {
        #expect(AnthropicExecutor.isSafeEndpoint(URL(string: "https://api.anthropic.com/v1")!))
        #expect(AnthropicExecutor.isSafeEndpoint(URL(string: "http://127.0.0.1:8080/v1")!))
        #expect(!AnthropicExecutor.isSafeEndpoint(URL(string: "http://proxy.example.com/v1")!))
    }

    @Test("Anthropic uses adaptive thinking and effort on current models")
    func anthropicAdaptiveThinking() throws {
        let body = AnthropicExecutor(model: "claude-opus-4-8", apiKey: "k")
            .buildBody(Self.request(reasoning: .high))
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
    }

    @Test("Anthropic omits sampling parameters on models that reject them")
    func anthropicNoSamplingParameters() throws {
        let body = AnthropicExecutor(model: "claude-sonnet-5", apiKey: "k")
            .buildBody(Self.request())
        #expect(body["temperature"] == nil)
    }

    @Test("Anthropic omits thinking on models without reasoning capability")
    func anthropicNonReasoningModel() throws {
        let body = AnthropicExecutor(model: "claude-3-5-haiku", apiKey: "k")
            .buildBody(Self.request(reasoning: .high))
        #expect(body["thinking"] == nil)
    }

    // MARK: - OpenAI-compatible

    @Test("OpenAI-compatible keeps system as a message")
    func openAISystemMessage() throws {
        let body = OpenAICompatibleExecutor(model: "gpt-5.1", apiKey: "k")
            .buildBody(Self.request())

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(body["system"] == nil)
        #expect(body["stream"] as? Bool == true)
    }

    @Test("OpenAI-compatible serialises tool arguments as a JSON string")
    func openAIToolCalls() throws {
        let body = OpenAICompatibleExecutor(model: "gpt-5.1", apiKey: "k")
            .buildBody(Self.request(tools: true))

        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["tool_calls"] != nil })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let function = try #require(calls.first?["function"] as? [String: Any])
        // This protocol wants arguments as a string, unlike Gemini's object.
        #expect(function["arguments"] is String)

        let toolMessage = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "call_1")
    }

    @Test("OpenAI-compatible encodes images as data URLs")
    func openAIVision() throws {
        let body = OpenAICompatibleExecutor(model: "gpt-5.1", apiKey: "k")
            .buildBody(Self.request(images: true))

        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = messages.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
        let image = try #require(parts.first { $0["type"] as? String == "image_url" })
        let url = try #require((image["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url.hasPrefix("data:image/png;base64,"))
    }

    @Test("OpenAI-compatible requests usage in the stream")
    func openAIUsageOptions() throws {
        let body = OpenAICompatibleExecutor(model: "gpt-5.1", apiKey: "k")
            .buildBody(Self.request())
        // Streaming responses omit usage unless this is set.
        let options = try #require(body["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }

    @Test("OpenAI-compatible omits reasoning_effort on models without reasoning capability")
    func openAINonReasoningModel() throws {
        let body = OpenAICompatibleExecutor(model: "gpt-4o", apiKey: "k")
            .buildBody(Self.request(reasoning: .low))
        #expect(body["reasoning_effort"] == nil)
    }

    @Test("OpenAI-compatible sets reasoning_effort on reasoning models")
    func openAIReasoningModel() throws {
        let body = OpenAICompatibleExecutor(model: "o3-mini", apiKey: "k")
            .buildBody(Self.request(reasoning: .minimal))
        #expect(body["reasoning_effort"] as? String == "low")
    }

    @Test("Ollama preset needs no key and is marked on-device")
    func ollamaPreset() {
        let executor = OpenAICompatibleExecutor.ollama(model: "qwen3:8b")
        #expect(executor.capabilities.contains(.onDevice))
        #expect(executor.identifier.contains("qwen3:8b"))
    }

    // MARK: - Shared invariants

    @Test("no provider replays prior reasoning back to the model")
    func reasoningIsNeverReplayed() throws {
        let bodies = [
            try Self.serialise(GeminiExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
            try Self.serialise(AnthropicExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
            try Self.serialise(
                OpenAICompatibleExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
        ]
        for body in bodies {
            #expect(!body.contains("internal deliberation"))
        }
    }

    @Test("every provider carries the whole conversation")
    func transcriptIsComplete() throws {
        let bodies = [
            try Self.serialise(GeminiExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
            try Self.serialise(AnthropicExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
            try Self.serialise(
                OpenAICompatibleExecutor(model: "m", apiKey: "k").buildBody(Self.request())),
        ]
        for body in bodies {
            #expect(body.contains("What is on my screen?"))
            #expect(body.contains("A terminal."))
            #expect(body.contains("no matches"))
        }
    }
}
