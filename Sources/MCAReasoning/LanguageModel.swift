import Foundation
import MCACore

// MARK: - Transcript

/// One entry in a conversation.
///
/// These six cases mirror the entry kinds Apple's Foundation Models framework
/// defines. That is deliberate: when macOS 27's pluggable-provider API
/// (`LanguageModel` / `LanguageModelExecutor`) becomes the deployment target,
/// migrating means conforming the executors below to Apple's protocol and
/// deleting this file — not reshaping every call site.
public enum TranscriptEntry: Sendable, Equatable {
    /// System prompt. Providers place this differently, which is the executor's
    /// problem, not the caller's.
    case instructions(String)
    case prompt(Prompt)
    case toolCalls([ToolCall])
    case toolOutput(ToolOutput)
    case response(String)
    /// Extended thinking, kept separate from the answer so it is never shown to
    /// the user or fed back as if it were content.
    case reasoning(String)
}

public struct Prompt: Sendable, Equatable {
    public var text: String
    /// PNG/JPEG data for vision requests. Screens are attached here only on the
    /// turn that needs them, never on every turn.
    public var images: [ImageAttachment]

    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}

public struct ImageAttachment: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Raw JSON object of arguments.
    public var arguments: Data
    /// Opaque provider state emitted alongside this call that has to be
    /// replayed verbatim on the next turn.
    ///
    /// Not decoration: Gemini 3 attaches a `thoughtSignature` to a tool call and
    /// rejects the following turn with HTTP 400 (`Function call is missing a
    /// thought_signature`) if it does not come back — which fails the whole
    /// answer, because a 400 is not worth retrying on another provider. Kept as
    /// an untyped bag so a provider can round-trip its own state without every
    /// other provider growing a field for it.
    public var providerState: [String: String]

    public init(
        id: String, name: String, arguments: Data,
        providerState: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerState = providerState
    }
}

public struct ToolOutput: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var content: String

    public init(callID: String, name: String, content: String) {
        self.callID = callID
        self.name = name
        self.content = content
    }
}

// MARK: - Capabilities & options

public struct ModelCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let toolCalling = ModelCapabilities(rawValue: 1 << 0)
    /// Constrained decoding against a schema.
    public static let guidedGeneration = ModelCapabilities(rawValue: 1 << 1)
    public static let reasoning = ModelCapabilities(rawValue: 1 << 2)
    public static let vision = ModelCapabilities(rawValue: 1 << 3)
    public static let streaming = ModelCapabilities(rawValue: 1 << 4)
    /// Runs without a network round trip.
    public static let onDevice = ModelCapabilities(rawValue: 1 << 5)
}

public struct GenerationOptions: Sendable {
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reasoningLevel: ReasoningLevel?
    /// JSON Schema the response must satisfy, when the model supports it.
    public var responseSchema: Data?

    public init(
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        reasoningLevel: ReasoningLevel? = nil,
        responseSchema: Data? = nil
    ) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reasoningLevel = reasoningLevel
        self.responseSchema = responseSchema
    }
}

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema for the parameters object.
    public var parameters: Data

    public init(name: String, description: String, parameters: Data) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct GenerationRequest: Sendable {
    public var id: UUID
    public var transcript: [TranscriptEntry]
    public var tools: [ToolDefinition]
    public var options: GenerationOptions

    public init(
        id: UUID = UUID(),
        transcript: [TranscriptEntry],
        tools: [ToolDefinition] = [],
        options: GenerationOptions = GenerationOptions()
    ) {
        self.id = id
        self.transcript = transcript
        self.tools = tools
        self.options = options
    }
}

// MARK: - Streaming

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int

    public init(
        inputTokens: Int = 0, cachedInputTokens: Int = 0,
        outputTokens: Int = 0, reasoningTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum FinishReason: String, Sendable {
    case stop, length, toolCalls, contentFilter, error, cancelled
}

/// Events an executor emits, in this order: metadata, usage, then any number of
/// text/reasoning/toolCall events, then exactly one `finished`.
public enum GenerationEvent: Sendable {
    case metadata([String: String])
    case usage(TokenUsage)
    case text(String)
    case reasoning(String)
    case toolCall(ToolCall)
    case finished(FinishReason)
}

/// The sink an executor writes into. Mirrors Apple's
/// `LanguageModelExecutorGenerationChannel`.
public struct GenerationChannel: Sendable {
    private let sink: @Sendable (GenerationEvent) -> Void

    public init(sink: @escaping @Sendable (GenerationEvent) -> Void) {
        self.sink = sink
    }

    public func send(_ event: GenerationEvent) { sink(event) }
}

// MARK: - The provider protocol

public enum LanguageModelError: Error, CustomStringConvertible {
    case missingCredentials(provider: String)
    case unsupportedCapability(String)
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    case cancelled

    public var description: String {
        switch self {
        case .missingCredentials(let provider):
            return "No API key configured for provider '\(provider)'"
        case .unsupportedCapability(let what):
            return "Model does not support \(what)"
        case .transport(let message):
            return "Network error: \(message)"
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(500))"
        case .decoding(let message):
            return "Could not decode provider response: \(message)"
        case .cancelled:
            return "Generation cancelled"
        }
    }

    /// Whether trying a different provider is likely to help. A 401 is not
    /// worth retrying on the same key; a 503 is worth failing over.
    public var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .http(let status, let body):
            if status >= 500 || status == 429 { return true }
            if status == 400 && (body.localizedCaseInsensitiveContains("thinking") || body.localizedCaseInsensitiveContains("reasoning")) {
                return true
            }
            return false
        case .missingCredentials: return true
        default: return false
        }
    }
}

/// Anything that can run a generation.
///
/// Every provider — cloud or on-device — implements exactly this. Call sites
/// never branch on which one they got.
public protocol LanguageModelExecuting: Sendable {
    var identifier: String { get }
    var capabilities: ModelCapabilities { get }
    func respond(to request: GenerationRequest, streamingInto channel: GenerationChannel) async throws
}

public extension LanguageModelExecuting {
    /// Convenience: collect a full response instead of streaming it.
    func complete(_ request: GenerationRequest) async throws -> CompletedResponse {
        let collector = ResponseCollector()
        let channel = GenerationChannel { event in collector.handle(event) }
        try await respond(to: request, streamingInto: channel)
        return collector.result()
    }

    /// Convenience: an `AsyncThrowingStream` over the same events.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = GenerationChannel { continuation.yield($0) }
                    try await respond(to: request, streamingInto: channel)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct CompletedResponse: Sendable {
    public var text: String
    public var reasoning: String
    public var toolCalls: [ToolCall]
    public var usage: TokenUsage
    public var finishReason: FinishReason
    public var metadata: [String: String]
}

/// Accumulates a stream into a single response. `@unchecked Sendable` because
/// all mutation happens behind its own lock.
final class ResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var reasoning = ""
    private var toolCalls: [ToolCall] = []
    private var usage = TokenUsage()
    private var finish: FinishReason = .stop
    private var metadata: [String: String] = [:]

    func handle(_ event: GenerationEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .metadata(let m): metadata.merge(m) { _, new in new }
        case .usage(let u): usage = u
        case .text(let t): text += t
        case .reasoning(let r): reasoning += r
        case .toolCall(let c): toolCalls.append(c)
        case .finished(let reason): finish = reason
        }
    }

    func result() -> CompletedResponse {
        lock.lock()
        defer { lock.unlock() }
        return CompletedResponse(
            text: text, reasoning: reasoning, toolCalls: toolCalls,
            usage: usage, finishReason: finish, metadata: metadata)
    }
}
