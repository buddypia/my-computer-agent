import Foundation
import MCACore

/// Anthropic Claude via the Messages API.
///
/// Implemented natively rather than through an OpenAI-compatibility shim
/// because the parts worth having — extended thinking blocks, the tool_use /
/// tool_result pairing, and prompt caching breakpoints — do not survive
/// translation.
public struct AnthropicExecutor: LanguageModelExecuting {
    public let identifier: String
    public let capabilities: ModelCapabilities

    private let model: String
    private let apiKey: String
    private let baseURL: URL
    private let apiVersion = "2023-06-01"

    /// `ToolCall.providerState` key carrying the thinking blocks (with their
    /// signatures) that preceded the call. With thinking on, Anthropic
    /// verifies those blocks when the tool loop continues, so they have to come
    /// back verbatim — the same contract as Gemini's `thoughtSignature`.
    static let thinkingBlocksKey = "anthropic.thinkingBlocks"

    public static func supportsReasoning(model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("claude-sonnet-4") || lower.contains("claude-opus-4")
            || lower.contains("claude-4") || lower.contains("thinking")
            || usesAdaptiveThinking(model: model)
    }

    /// Claude 4.6 and later take `thinking: {type: "adaptive"}` plus an effort
    /// level; a fixed `budget_tokens` is rejected with a 400 from Opus 4.7 on.
    ///
    /// Decided by version rather than by a list of names, so a model released
    /// after this was written lands on the current API instead of on the one
    /// it rejects.
    static func usesAdaptiveThinking(model: String) -> Bool {
        guard let version = version(of: model) else { return false }
        return version >= (4, 6)
    }

    /// Opus 4.7 and later reject `temperature` / `top_p` / `top_k` with a 400.
    static func rejectsSamplingParameters(model: String) -> Bool {
        guard let version = version(of: model) else { return false }
        return version >= (4, 7)
    }

    /// `(major, minor)` of a Claude model ID, or nil when the name does not
    /// follow either Anthropic naming scheme (a proxy alias, say) — callers
    /// then keep the conservative pre-4.6 wire format.
    ///
    /// Handles `claude-opus-4-7`, `claude-sonnet-4.6`, `claude-sonnet-4-20250514`
    /// (the date is not a minor version), Bedrock/Vertex prefixes and suffixes,
    /// and the older `claude-3-7-sonnet` order.
    static func version(of model: String) -> (Int, Int)? {
        let lower = model.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        for pattern in versionPatterns {
            guard let match = pattern.firstMatch(in: lower, range: range),
                  let majorRange = Range(match.range(at: 1), in: lower),
                  let major = Int(lower[majorRange])
            else { continue }
            let minor = Range(match.range(at: 2), in: lower).flatMap { Int(lower[$0]) } ?? 0
            return (major, minor)
        }
        return nil
    }

    private static let versionPatterns: [NSRegularExpression] = [
        // A minor version is one or two digits; eight digits is a snapshot date.
        #"claude-(?:opus|sonnet|haiku|fable|mythos)-(\d+)(?:[-.](\d{1,2}))?(?!\d)"#,
        #"claude-(\d+)(?:[-.](\d{1,2}))?-(?:opus|sonnet|haiku)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public init(
        model: String,
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        capabilities: ModelCapabilities? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.identifier = "anthropic/\(model)"
        if let capabilities {
            self.capabilities = capabilities
        } else {
            var caps: ModelCapabilities = [.toolCalling, .vision, .streaming]
            if Self.supportsReasoning(model: model) {
                caps.insert(.reasoning)
            }
            self.capabilities = caps
        }
    }

    /// The API key travels in a header, so it may only go over TLS. Plain HTTP
    /// is allowed to loopback, where a local proxy or test server listens.
    static func isSafeEndpoint(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default:
            return false
        }
    }

    public func respond(
        to request: GenerationRequest,
        streamingInto channel: GenerationChannel
    ) async throws {
        guard !apiKey.isEmpty else {
            throw LanguageModelError.missingCredentials(provider: "anthropic")
        }
        guard Self.isSafeEndpoint(baseURL) else {
            // Thrown before the request exists, so the key never leaves. A
            // transport error rather than a capability one: the next provider
            // in the chain can still answer, as with a missing key.
            throw LanguageModelError.transport(
                "Refusing to send the Anthropic key over a non-TLS endpoint (\(baseURL.scheme ?? "?")://\(baseURL.host ?? "?"))")
        }

        var urlRequest = URLRequest(url: baseURL.appending(path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildBody(request))

        channel.send(.metadata([
            "provider": "anthropic",
            "modelID": model,
            "requestID": request.id.uuidString,
        ]))

        var decoder = StreamDecoder()
        for try await payload in try await HTTPStreaming.sseLines(for: urlRequest) {
            guard let json = parseJSONObject(payload) else { continue }
            try decoder.consume(json, into: channel)
        }

        // The Agent returns any non-empty text as the answer, so a cut-off
        // stream has to fail here — where the router can fail over — rather
        // than finish with a reason nobody on the success path reads.
        guard decoder.sawMessageStop else {
            throw LanguageModelError.transport("Anthropic stream ended before message_stop")
        }
        channel.send(.usage(decoder.usage))
        channel.send(.finished(decoder.finishReason))
    }

    /// Turns Anthropic stream events into `GenerationEvent`s.
    ///
    /// A value type separate from the network call so the decoding — which is
    /// where truncation and malformed tool input surface — can be tested
    /// against recorded events.
    struct StreamDecoder {
        private(set) var usage = TokenUsage()
        private var finish: FinishReason = .stop
        private(set) var sawMessageStop = false
        private var droppedToolCall = false
        private var rawInput = 0, cacheRead = 0, cacheWritten = 0

        // Anthropic streams tool arguments as incremental JSON fragments keyed
        // by content-block index, so partial calls are assembled here and
        // emitted only once their block closes.
        private var pendingToolCalls: [Int: (id: String, name: String, json: String)] = [:]
        private var pendingThinking: [Int: (text: String, signature: String)] = [:]
        /// Thinking blocks since the last emitted tool call, in stream order.
        private var thinkingSinceLastCall: [[String: String]] = []

        /// A stream that ends without `message_stop` was cut off — by the
        /// network, a proxy, or the resource timeout. Reporting that as `.stop`
        /// would pass a truncated answer off as a complete one.
        var finishReason: FinishReason {
            guard sawMessageStop else { return .error }
            if droppedToolCall, finish != .length { return .error }
            return finish
        }

        mutating func consume(_ json: [String: Any], into channel: GenerationChannel) throws {
            guard let type = json.string("type") else { return }

            switch type {
            case "message_start":
                if let messageUsage = json.object("message")?.object("usage") {
                    record(messageUsage)
                }

            case "content_block_start":
                guard let index = json.int("index"),
                      let block = json.object("content_block")
                else { return }
                switch block.string("type") {
                case "tool_use":
                    pendingToolCalls[index] = (
                        id: block.string("id") ?? UUID().uuidString,
                        name: block.string("name") ?? "",
                        json: "")
                case "thinking":
                    pendingThinking[index] = (text: "", signature: "")
                case "redacted_thinking":
                    if let data = block.string("data") {
                        thinkingSinceLastCall.append(["type": "redacted_thinking", "data": data])
                    }
                default:
                    break
                }

            case "content_block_delta":
                guard let delta = json.object("delta") else { return }
                switch delta.string("type") {
                case "text_delta":
                    if let text = delta.string("text") { channel.send(.text(text)) }
                case "thinking_delta":
                    if let thinking = delta.string("thinking") {
                        if let index = json.int("index") { pendingThinking[index]?.text += thinking }
                        channel.send(.reasoning(thinking))
                    }
                case "signature_delta":
                    if let index = json.int("index"), let signature = delta.string("signature") {
                        pendingThinking[index]?.signature += signature
                    }
                case "input_json_delta":
                    if let index = json.int("index"),
                       let fragment = delta.string("partial_json") {
                        pendingToolCalls[index]?.json += fragment
                    }
                default:
                    break
                }

            case "content_block_stop":
                guard let index = json.int("index") else { return }
                if let thinking = pendingThinking.removeValue(forKey: index), !thinking.signature.isEmpty {
                    thinkingSinceLastCall.append([
                        "type": "thinking", "thinking": thinking.text, "signature": thinking.signature,
                    ])
                }
                if let call = pendingToolCalls.removeValue(forKey: index) {
                    emit(call, into: channel)
                }

            case "message_delta":
                if let deltaUsage = json.object("usage") {
                    record(deltaUsage)
                }
                if let reason = json.object("delta")?.string("stop_reason") {
                    switch reason {
                    case "end_turn", "stop_sequence", "pause_turn": finish = .stop
                    case "max_tokens", "model_context_window_exceeded": finish = .length
                    case "tool_use": finish = .toolCalls
                    case "refusal": finish = .contentFilter
                    default: break
                    }
                }

            case "message_stop":
                sawMessageStop = true

            case "error":
                // The status of the HTTP response was already 200 when this
                // arrives, so the real class of failure is only in the error
                // type. Mapping it back to a status is what lets the router
                // fail over on an overload instead of treating it as a 400.
                let error = json.object("error")
                let kind = error?.string("type") ?? "unknown"
                let message = error?.string("message") ?? "unknown"
                throw LanguageModelError.http(
                    status: Self.status(forErrorType: kind), body: "\(kind): \(message)")

            default:
                break
            }
        }

        private mutating func emit(
            _ call: (id: String, name: String, json: String), into channel: GenerationChannel
        ) {
            let arguments = call.json.isEmpty ? "{}" : call.json
            // A block cut off by max_tokens still gets a content_block_stop, with
            // half an object in it. Running a desktop action on arguments that
            // were never finished is worse than not running it.
            guard (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] else {
                droppedToolCall = true
                return
            }
            var state: [String: String] = [:]
            if !thinkingSinceLastCall.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: thinkingSinceLastCall),
               let encoded = String(data: data, encoding: .utf8) {
                state[AnthropicExecutor.thinkingBlocksKey] = encoded
            }
            thinkingSinceLastCall.removeAll()
            channel.send(.toolCall(ToolCall(
                id: call.id,
                name: call.name,
                arguments: Data(arguments.utf8),
                providerState: state)))
            finish = .toolCalls
        }

        /// Anthropic's `input_tokens` excludes cache reads and writes, while
        /// every other provider here reports the whole prompt. Summing keeps
        /// `inputTokens` meaning the same thing whichever provider answered.
        private mutating func record(_ fields: [String: Any]) {
            // `message_delta` repeats only some fields; one it omits keeps the
            // value `message_start` gave it.
            rawInput = fields.int("input_tokens") ?? rawInput
            cacheRead = fields.int("cache_read_input_tokens") ?? cacheRead
            cacheWritten = fields.int("cache_creation_input_tokens") ?? cacheWritten
            usage.inputTokens = rawInput + cacheRead + cacheWritten
            usage.cachedInputTokens = cacheRead
            if let output = fields.int("output_tokens") { usage.outputTokens = output }
        }

        static func status(forErrorType type: String) -> Int {
            switch type {
            case "invalid_request_error": return 400
            case "authentication_error": return 401
            case "billing_error": return 402
            case "permission_error": return 403
            case "not_found_error": return 404
            case "request_too_large": return 413
            case "rate_limit_error": return 429
            case "timeout_error": return 504
            case "overloaded_error": return 529
            default: return 500
            }
        }
    }

    // Internal rather than private so the wire-format tests can assert on it
    // without a network round trip.
    func buildBody(_ request: GenerationRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // Anthropic requires max_tokens; pick a sane ceiling if unset.
            "max_tokens": request.options.maximumResponseTokens ?? 4096,
        ]

        var system: [String] = []
        var messages: [[String: Any]] = []

        // Consecutive entries of one role become one message: parallel tool
        // results have to answer their tool_use turn together, and a text
        // reply followed by its tool calls is one assistant turn.
        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = messages.last, last["role"] as? String == role,
               let existing = last["content"] as? [[String: Any]] {
                var merged = existing + blocks
                if role == "assistant" {
                    // Claude emits thinking before any text in a turn, and a
                    // replayed turn is rejected unless it starts that way.
                    let isThinking = { (block: [String: Any]) in
                        ["thinking", "redacted_thinking"].contains(block["type"] as? String ?? "")
                    }
                    merged = merged.filter(isThinking) + merged.filter { !isThinking($0) }
                }
                last["content"] = merged
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        // Whether the tool loop since the last user prompt can be replayed
        // with its thinking intact; see the budget branch below.
        var loopHasUnsignedCalls = false

        for entry in request.transcript {
            switch entry {
            case .instructions(let text):
                system.append(text)

            case .prompt(let prompt):
                loopHasUnsignedCalls = false
                var content: [[String: Any]] = []
                for image in prompt.images {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image.mimeType,
                            "data": image.data.base64EncodedString(),
                        ],
                    ])
                }
                // An empty or whitespace-only text block is a 400.
                if !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content.append(["type": "text", "text": prompt.text])
                }
                append("user", content)

            case .response(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                append("assistant", [["type": "text", "text": text]])

            case .toolCalls(let calls):
                var content: [[String: Any]] = []
                for (index, call) in calls.enumerated() {
                    let thinking = Self.thinkingBlocks(from: call)
                    if index == 0, thinking.isEmpty { loopHasUnsignedCalls = true }
                    content += thinking
                    // `input` must be an object; a replayed call whose arguments
                    // were not one would fail the whole turn.
                    let input = (try? JSONSerialization.jsonObject(with: call.arguments))
                        as? [String: Any] ?? [:]
                    content.append([
                        "type": "tool_use", "id": call.id,
                        "name": call.name, "input": input,
                    ])
                }
                append("assistant", content)

            case .toolOutput(let output):
                append("user", [[
                    "type": "tool_result",
                    "tool_use_id": output.callID,
                    "content": output.content,
                ]])

            case .reasoning:
                continue
            }
        }

        markCacheBreakpoint(in: &messages)
        body["messages"] = messages
        if !system.isEmpty { body["system"] = system.joined(separator: "\n\n") }
        if let temperature = request.options.temperature, !Self.rejectsSamplingParameters(model: model) {
            body["temperature"] = temperature
        }

        // Map the shared reasoning scale onto adaptive thinking + effort on
        // current models, or onto a thinking budget on older ones (which
        // Anthropic requires to be below max_tokens).
        // Models without reasoning capability drop thinking configuration.
        if capabilities.contains(.reasoning),
           let level = request.options.reasoningLevel, level > .minimal {
            let maxTokens = request.options.maximumResponseTokens ?? 4096
            let budget: Int
            switch level {
            case .minimal: budget = 0
            case .low: budget = 2048
            case .medium: budget = 6144
            case .high: budget = 12288
            }

            if Self.usesAdaptiveThinking(model: model) {
                body["thinking"] = ["type": "adaptive"]
                let effort: String
                switch level {
                case .minimal, .low: effort = "low"
                case .medium: effort = "medium"
                case .high: effort = "high"
                }
                body["output_config"] = ["effort": effort]
                // Thinking of either kind does not accept a modified temperature.
                body.removeValue(forKey: "temperature")
                // Adaptive thinking spends from max_tokens too. Without the
                // same headroom the budget path gets, a high-effort turn can
                // think through the whole allowance and answer nothing.
                body["max_tokens"] = max(maxTokens, budget + 1024)
            } else if budget > 0, !loopHasUnsignedCalls {
                // With a fixed budget the API requires the open tool loop's
                // assistant turn to start with its signed thinking. Calls made
                // by another provider (after a failover) or by a turn with
                // thinking off have none, and sending the budget anyway is a
                // 400 — one `isRetryable` treats as a reason to leave Claude
                // altogether. Such a turn runs without thinking instead.
                body["max_tokens"] = max(maxTokens, budget + 1024)
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                // Extended thinking does not accept a modified temperature.
                body.removeValue(forKey: "temperature")
            }
        }

        if !request.tools.isEmpty {
            var tools = request.tools.map { tool -> [String: Any] in
                var definition: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let schema = try? JSONSerialization.jsonObject(with: tool.parameters) {
                    definition["input_schema"] = schema
                }
                return definition
            }
            // Tools are the start of the cached prefix and identical on every
            // round of an agent loop.
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = tools
        }

        return body
    }

    static func thinkingBlocks(from call: ToolCall) -> [[String: Any]] {
        guard let encoded = call.providerState[thinkingBlocksKey],
              let blocks = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [[String: Any]]
        else { return [] }
        return blocks
    }

    /// Marks the end of the transcript as a cache breakpoint.
    ///
    /// An agent loop resends everything so far plus one tool result per round,
    /// so the next round reads this prefix from cache at a tenth of the input
    /// price. Prompts shorter than the model's cache minimum are simply not
    /// cached; the marker costs nothing there.
    private func markCacheBreakpoint(in messages: inout [[String: Any]]) {
        guard var last = messages.last,
              var content = last["content"] as? [[String: Any]],
              let type = content.last?["type"] as? String,
              // Thinking blocks cannot carry cache_control.
              type != "thinking", type != "redacted_thinking"
        else { return }
        content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
        last["content"] = content
        messages[messages.count - 1] = last
    }
}
