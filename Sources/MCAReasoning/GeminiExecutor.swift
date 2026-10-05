import Foundation
import MCACore
import OSLog

/// Google Gemini, over the REST API directly.
///
/// Not via the Firebase AI Logic SDK, which is the current official Swift
/// route: that SDK is built for mobile clients, pulls in the whole Firebase
/// stack, and since July 2026 enforces App Check attestation — all of which is
/// wrong for a local desktop daemon. The wire protocol is plain REST + SSE, so
/// talking to it directly is both smaller and a better fit for the
/// `LanguageModelExecuting` shape.
public struct GeminiExecutor: LanguageModelExecuting {
    public let identifier: String
    public let capabilities: ModelCapabilities

    private let model: String
    private let apiKey: String
    private let baseURL: URL

    public static func supportsReasoning(model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("gemini-3") || lower.contains("gemini-2.5") || lower.contains("thinking")
    }

    public init(
        model: String,
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        capabilities: ModelCapabilities? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.identifier = "gemini/\(model)"
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

    public func respond(
        to request: GenerationRequest,
        streamingInto channel: GenerationChannel
    ) async throws {
        guard !apiKey.isEmpty else {
            throw LanguageModelError.missingCredentials(provider: "gemini")
        }

        var urlRequest = URLRequest(
            url: baseURL.appending(path: "models/\(model):streamGenerateContent")
                .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")]))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildBody(request))

        channel.send(.metadata([
            "provider": "gemini",
            "modelID": model,
            "requestID": request.id.uuidString,
        ]))

        var finish: FinishReason = .stop
        var usage = TokenUsage()
        var sawToolCall = false

        for try await payload in try await HTTPStreaming.sseLines(for: urlRequest) {
            guard let json = parseJSONObject(payload) else { continue }

            if let metadata = json.object("usageMetadata") {
                usage = TokenUsage(
                    inputTokens: metadata.int("promptTokenCount") ?? 0,
                    cachedInputTokens: metadata.int("cachedContentTokenCount") ?? 0,
                    outputTokens: metadata.int("candidatesTokenCount") ?? 0,
                    reasoningTokens: metadata.int("thoughtsTokenCount") ?? 0)
            }

            guard let candidate = json.array("candidates")?.first else { continue }

            if let reason = candidate.string("finishReason") {
                switch reason {
                case "STOP": finish = .stop
                case "MAX_TOKENS": finish = .length
                case "SAFETY", "PROHIBITED_CONTENT": finish = .contentFilter
                default: finish = .stop
                }
            }

            for part in candidate.object("content")?.array("parts") ?? [] {
                // Gemini marks chain-of-thought parts with `thought: true`.
                // Routing them separately keeps reasoning out of the answer the
                // user sees and out of anything we persist as content.
                if let text = part.string("text") {
                    if part["thought"] as? Bool == true {
                        channel.send(.reasoning(text))
                    } else {
                        channel.send(.text(text))
                    }
                }
                if let call = part.object("functionCall"), let name = call.string("name") {
                    sawToolCall = true
                    let arguments = call["args"] ?? [String: Any]()
                    let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
                    // Carried, not dropped: sending this call back without its
                    // signature is rejected outright by Gemini 3, so a question
                    // that needs a tool fails on the round after the call.
                    var state: [String: String] = [:]
                    if let signature = part.string(Self.thoughtSignatureKey), !signature.isEmpty {
                        state[Self.thoughtSignatureKey] = signature
                    }
                    channel.send(.toolCall(ToolCall(
                        id: "\(name)-\(UUID().uuidString.prefix(8))",
                        name: name,
                        arguments: data,
                        providerState: state)))
                }
            }
        }

        channel.send(.usage(usage))
        channel.send(.finished(sawToolCall ? .toolCalls : finish))
    }

    static let thoughtSignatureKey = "thoughtSignature"

    /// The value Google documents for replaying a call that Gemini did not
    /// produce — one run by the Anthropic or OpenAI fallback in an earlier
    /// round, or one whose signature was lost. Without it the whole turn is
    /// rejected with HTTP 400, which the router rightly does not retry.
    /// https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures
    ///
    /// Not free: the model loses its prior reasoning for that step, so each use
    /// is logged — frequent ones mean the fallback chain is answering rounds
    /// that Gemini should have.
    static let unsignedCallSignature = "skip_thought_signature_validator"

    private static let log = Logger(subsystem: "com.buddypia.mca", category: "Gemini")

    // MARK: - Request encoding

    // Internal rather than private so the wire-format tests can assert on it
    // without a network round trip.
    func buildBody(_ request: GenerationRequest) -> [String: Any] {
        var body: [String: Any] = [:]
        var contents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let text):
                systemParts.append(["text": text])

            case .prompt(let prompt):
                var parts: [[String: Any]] = []
                if !prompt.text.isEmpty { parts.append(["text": prompt.text]) }
                for image in prompt.images {
                    parts.append([
                        "inlineData": [
                            "mimeType": image.mimeType,
                            "data": image.data.base64EncodedString(),
                        ]
                    ])
                }
                contents.append(["role": "user", "parts": parts])

            case .response(let text):
                contents.append(["role": "model", "parts": [["text": text]]])

            case .toolCalls(let calls):
                let parts = calls.enumerated().map { index, call -> [String: Any] in
                    let arguments = (try? JSONSerialization.jsonObject(with: call.arguments))
                        ?? [String: Any]()
                    var part: [String: Any] = [
                        "functionCall": ["name": call.name, "args": arguments]
                    ]
                    // Required by Gemini 3 whenever the call is replayed. It is
                    // a sibling of `functionCall` within the part, not a field
                    // inside it. Parallel calls carry it on the first part only,
                    // and only that part is validated. An empty string is
                    // rejected exactly like a missing one.
                    if let signature = call.providerState[Self.thoughtSignatureKey], !signature.isEmpty {
                        part[Self.thoughtSignatureKey] = signature
                    } else if index == 0 {
                        part[Self.thoughtSignatureKey] = Self.unsignedCallSignature
                        Self.log.notice(
                            "Replaying unsigned call \(call.name, privacy: .public) with the signature bypass")
                    }
                    return part
                }
                contents.append(["role": "model", "parts": parts])

            case .toolOutput(let output):
                let response: [String: Any] = [
                    "functionResponse": [
                        "name": output.name,
                        "response": ["result": output.content],
                    ]
                ]
                // Parallel results go back as one turn (FC1, FC2 → FR1, FR2),
                // the shape Gemini documents for parallel calls.
                if var last = contents.last,
                   last["role"] as? String == "user",
                   var parts = last["parts"] as? [[String: Any]],
                   parts.allSatisfy({ $0["functionResponse"] != nil }) {
                    parts.append(response)
                    last["parts"] = parts
                    contents[contents.count - 1] = last
                } else {
                    contents.append(["role": "user", "parts": [response]])
                }

            case .reasoning:
                // Prior thinking is not replayed: providers regenerate it, and
                // sending it back inflates input tokens for no benefit.
                continue
            }
        }

        body["contents"] = contents
        if !systemParts.isEmpty {
            body["systemInstruction"] = ["parts": systemParts]
        }

        var generationConfig: [String: Any] = [:]
        if let temperature = request.options.temperature {
            generationConfig["temperature"] = temperature
        }
        if let maxTokens = request.options.maximumResponseTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if capabilities.contains(.reasoning), let level = request.options.reasoningLevel {
            let lower = model.lowercased()
            if lower.contains("gemini-2.5") {
                // Gemini 2.5 takes a numeric `thinkingBudget`. Budget 0 disables thinking.
                let budget: Int
                switch level {
                case .minimal: budget = 0
                case .low: budget = 2048
                case .medium: budget = 4096
                case .high: budget = 8192
                }
                generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
            } else {
                // Gemini 3.x uses discrete `thinkingLevel` (low/medium/high).
                // "minimal" is rejected with HTTP 400 (INVALID_ARGUMENT), so
                // map .minimal to "low" to provide the lowest latency & cost tier.
                let wireLevel: String
                switch level {
                case .minimal, .low: wireLevel = "low"
                case .medium: wireLevel = "medium"
                case .high: wireLevel = "high"
                }
                generationConfig["thinkingConfig"] = ["thinkingLevel": wireLevel]
            }
        }
        if let schema = request.options.responseSchema,
           let object = try? JSONSerialization.jsonObject(with: schema) {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = Self.sanitizeSchemaForGemini(object)
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }

        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool -> [String: Any] in
                    var declaration: [String: Any] = [
                        "name": tool.name,
                        "description": tool.description,
                    ]
                    if let parameters = try? JSONSerialization.jsonObject(with: tool.parameters) {
                        declaration["parameters"] = Self.sanitizeSchemaForGemini(parameters)
                    }
                    return declaration
                }
            ]]
        }

        return body
    }

    /// Sanitizes a JSON schema structure to conform to Gemini API's OpenAPI subset.
    /// Gemini's FunctionDeclaration parameters and responseSchema reject unsupported fields
    /// such as `additionalProperties`, `$schema`, `$ref`, `$id`, and `$defs` with HTTP 400.
    static func sanitizeSchemaForGemini(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, val) in dict {
                if key == "additionalProperties" || key == "$schema" || key == "$id" || key == "$ref" || key == "$defs" || key == "definitions" {
                    continue
                }
                result[key] = sanitizeSchemaForGemini(val)
            }
            return result
        } else if let array = value as? [Any] {
            return array.map { sanitizeSchemaForGemini($0) }
        }
        return value
    }
}
