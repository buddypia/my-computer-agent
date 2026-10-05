import Foundation
import MCACore

/// Any endpoint speaking the OpenAI Chat Completions protocol.
///
/// One implementation covers OpenAI, Ollama, LM Studio, vLLM, Groq, OpenRouter,
/// DeepSeek and every other service that settled on this wire format. Local
/// models arrive through this path too, which is why `baseURL` is a parameter
/// and the API key is optional — Ollama does not use one.
public struct OpenAICompatibleExecutor: LanguageModelExecuting {
    public let identifier: String
    public let capabilities: ModelCapabilities

    private let model: String
    private let apiKey: String?
    private let baseURL: URL

    public static func supportsReasoning(model: String) -> Bool {
        let lower = model.lowercased()
        return lower.hasPrefix("o1") || lower.hasPrefix("o3")
            || lower.contains("gpt-5") || lower.contains("deepseek-r1")
            || lower.contains("reasoning")
    }

    public init(
        model: String,
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        capabilities: ModelCapabilities? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.identifier = "openai-compatible/\(model)"
        if let capabilities {
            self.capabilities = capabilities
        } else {
            var caps: ModelCapabilities = [.toolCalling, .guidedGeneration, .vision, .streaming]
            if Self.supportsReasoning(model: model) {
                caps.insert(.reasoning)
            }
            self.capabilities = caps
        }
    }

    /// Points at a local Ollama server. No key, no network egress.
    public static func ollama(
        model: String,
        host: URL = URL(string: "http://127.0.0.1:11434/v1")!
    ) -> OpenAICompatibleExecutor {
        OpenAICompatibleExecutor(
            model: model, apiKey: nil, baseURL: host,
            capabilities: [.toolCalling, .streaming, .onDevice])
    }

    public func respond(
        to request: GenerationRequest,
        streamingInto channel: GenerationChannel
    ) async throws {
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildBody(request))

        channel.send(.metadata([
            "provider": "openai-compatible",
            "modelID": model,
            "requestID": request.id.uuidString,
        ]))

        var usage = TokenUsage()
        var finish: FinishReason = .stop
        // Tool calls stream as fragments indexed within the delta.
        var pendingToolCalls: [Int: (id: String, name: String, json: String)] = [:]

        for try await payload in try await HTTPStreaming.sseLines(for: urlRequest) {
            guard let json = parseJSONObject(payload) else { continue }

            if let usageObject = json.object("usage") {
                usage = TokenUsage(
                    inputTokens: usageObject.int("prompt_tokens") ?? 0,
                    cachedInputTokens: usageObject.object("prompt_tokens_details")?
                        .int("cached_tokens") ?? 0,
                    outputTokens: usageObject.int("completion_tokens") ?? 0,
                    reasoningTokens: usageObject.object("completion_tokens_details")?
                        .int("reasoning_tokens") ?? 0)
            }

            guard let choice = json.array("choices")?.first else { continue }

            if let reason = choice.string("finish_reason") {
                switch reason {
                case "stop": finish = .stop
                case "length": finish = .length
                case "tool_calls", "function_call": finish = .toolCalls
                case "content_filter": finish = .contentFilter
                default: break
                }
            }

            guard let delta = choice.object("delta") else { continue }

            if let content = delta.string("content"), !content.isEmpty {
                channel.send(.text(content))
            }
            // Reasoning models expose thinking under a non-standard key; both
            // spellings are in the wild.
            if let reasoning = delta.string("reasoning_content") ?? delta.string("reasoning"),
               !reasoning.isEmpty {
                channel.send(.reasoning(reasoning))
            }

            for toolCall in delta.array("tool_calls") ?? [] {
                let index = toolCall.int("index") ?? 0
                var entry = pendingToolCalls[index] ?? (id: "", name: "", json: "")
                if let id = toolCall.string("id") { entry.id = id }
                if let function = toolCall.object("function") {
                    if let name = function.string("name") { entry.name = name }
                    if let arguments = function.string("arguments") { entry.json += arguments }
                }
                pendingToolCalls[index] = entry
            }
        }

        // Emitted at the end because the protocol never signals a tool call is
        // complete — only the stream ending tells us that.
        for (_, call) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
            channel.send(.toolCall(ToolCall(
                id: call.id.isEmpty ? UUID().uuidString : call.id,
                name: call.name,
                arguments: Data((call.json.isEmpty ? "{}" : call.json).utf8))))
            finish = .toolCalls
        }

        channel.send(.usage(usage))
        channel.send(.finished(finish))
    }

    // Internal rather than private so the wire-format tests can assert on it
    // without a network round trip.
    func buildBody(_ request: GenerationRequest) -> [String: Any] {
        var messages: [[String: Any]] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let text):
                messages.append(["role": "system", "content": text])

            case .prompt(let prompt):
                if prompt.images.isEmpty {
                    messages.append(["role": "user", "content": prompt.text])
                } else {
                    var parts: [[String: Any]] = []
                    if !prompt.text.isEmpty {
                        parts.append(["type": "text", "text": prompt.text])
                    }
                    for image in prompt.images {
                        let encoded = image.data.base64EncodedString()
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mimeType);base64,\(encoded)"],
                        ])
                    }
                    messages.append(["role": "user", "content": parts])
                }

            case .response(let text):
                messages.append(["role": "assistant", "content": text])

            case .toolCalls(let calls):
                messages.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": String(data: call.arguments, encoding: .utf8) ?? "{}",
                            ],
                        ]
                    },
                ])

            case .toolOutput(let output):
                messages.append([
                    "role": "tool",
                    "tool_call_id": output.callID,
                    "content": output.content,
                ])

            case .reasoning:
                continue
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let temperature = request.options.temperature { body["temperature"] = temperature }
        if let maxTokens = request.options.maximumResponseTokens {
            body["max_completion_tokens"] = maxTokens
        }
        if capabilities.contains(.reasoning), let level = request.options.reasoningLevel {
            body["reasoning_effort"] = level == .minimal ? "low" : level.rawValue
        }
        if let schema = request.options.responseSchema,
           let object = try? JSONSerialization.jsonObject(with: schema) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "schema": object, "strict": true],
            ]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                var function: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                if let parameters = try? JSONSerialization.jsonObject(with: tool.parameters) {
                    function["parameters"] = parameters
                }
                return ["type": "function", "function": function]
            }
        }
        return body
    }
}
