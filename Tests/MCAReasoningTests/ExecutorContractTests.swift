import Foundation
import MCACore
import Testing

@testable import MCAReasoning

/// The behavioural contract every `LanguageModelExecuting` must satisfy.
///
/// This is the answer to the previous implementation's central testing failure:
/// its suite validated fakes against fakes, so all thirteen tests passed while
/// the real pipeline was dead. Here the *same* assertions run against the
/// scripted executor and — when credentials are present — against the live
/// providers. A fake that diverges from the real thing fails the same test the
/// real thing does.
enum ExecutorContract {
    static func verify(
        _ executor: any LanguageModelExecuting,
        supportsTools: Bool = true
    ) async throws {
        try await emitsTextThenFinishes(executor)
        try await reportsUsage(executor)
        try await emitsMetadataFirst(executor)
        if supportsTools && executor.capabilities.contains(.toolCalling) {
            try await honoursToolDefinitions(executor)
        }
    }

    /// Every run ends with exactly one `.finished`, and text arrives before it.
    static func emitsTextThenFinishes(_ executor: any LanguageModelExecuting) async throws {
        let request = GenerationRequest(
            transcript: [
                .instructions("Reply with exactly the word: acknowledged"),
                .prompt(Prompt(text: "Say it.")),
            ],
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 32))

        let recorder = EventRecorder()
        try await executor.respond(
            to: request, streamingInto: GenerationChannel { recorder.append($0) })
        let events = recorder.events

        let finishedCount = events.filter {
            if case .finished = $0 { return true }
            return false
        }.count
        #expect(finishedCount == 1, "\(executor.identifier): expected exactly one .finished")

        guard case .finished = events.last else {
            Issue.record("\(executor.identifier): .finished must be the last event")
            return
        }

        let text = events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }.joined()
        #expect(!text.isEmpty, "\(executor.identifier): produced no text")
    }

    /// Usage is reported even when the numbers are zero, so cost accounting
    /// never has to special-case a provider.
    static func reportsUsage(_ executor: any LanguageModelExecuting) async throws {
        let recorder = EventRecorder()
        try await executor.respond(
            to: GenerationRequest(transcript: [.prompt(Prompt(text: "Hello."))]),
            streamingInto: GenerationChannel { recorder.append($0) })

        let hasUsage = recorder.events.contains {
            if case .usage = $0 { return true }
            return false
        }
        #expect(hasUsage, "\(executor.identifier): never reported usage")
    }

    /// Metadata identifies which model actually ran — needed because the router
    /// may have failed over to a different provider than requested.
    static func emitsMetadataFirst(_ executor: any LanguageModelExecuting) async throws {
        let recorder = EventRecorder()
        try await executor.respond(
            to: GenerationRequest(transcript: [.prompt(Prompt(text: "Hello."))]),
            streamingInto: GenerationChannel { recorder.append($0) })

        guard case .metadata(let metadata)? = recorder.events.first else {
            Issue.record("\(executor.identifier): first event must be .metadata")
            return
        }
        #expect(metadata["modelID"] != nil, "\(executor.identifier): metadata lacks modelID")
    }

    /// A declared tool must be reachable; the model may or may not choose it,
    /// but the request must not be rejected for containing one.
    static func honoursToolDefinitions(_ executor: any LanguageModelExecuting) async throws {
        let request = GenerationRequest(
            transcript: [
                .instructions("Use the echo tool to repeat the user's word."),
                .prompt(Prompt(text: "Echo the word 'ping'.")),
            ],
            tools: [ToolDefinition(
                name: "echo",
                description: "Repeats a word back.",
                parameters: Data("""
                    {"type":"object","properties":{"word":{"type":"string"}},"required":["word"]}
                    """.utf8))],
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 128))

        let recorder = EventRecorder()
        try await executor.respond(
            to: request, streamingInto: GenerationChannel { recorder.append($0) })

        // Not asserting the model *called* the tool — that is model behaviour,
        // not executor behaviour. Asserting the request round-tripped.
        #expect(recorder.events.contains {
            if case .finished = $0 { return true }
            return false
        })
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GenerationEvent] = []

    func append(_ event: GenerationEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A deterministic executor for testing everything above the provider layer.
///
/// Holds itself to the same contract as a real one, which is the point: if this
/// diverges, the tests that use it stop meaning anything.
struct ScriptedExecutor: LanguageModelExecuting {
    let identifier: String
    let capabilities: ModelCapabilities

    var text: String = "acknowledged"
    var toolCalls: [ToolCall] = []
    var failure: (any Error)?
    /// Records every call so failover tests can prove which executor ran.
    let callLog: CallLog

    init(
        identifier: String = "scripted/test",
        capabilities: ModelCapabilities = [.toolCalling, .guidedGeneration, .streaming, .vision],
        text: String = "acknowledged",
        toolCalls: [ToolCall] = [],
        failure: LanguageModelError? = nil,
        callLog: CallLog = CallLog()
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.text = text
        self.toolCalls = toolCalls
        self.failure = failure
        self.callLog = callLog
    }

    init(
        identifier: String = "scripted/test",
        capabilities: ModelCapabilities = [.toolCalling, .guidedGeneration, .streaming, .vision],
        text: String = "acknowledged",
        toolCalls: [ToolCall] = [],
        generalFailure: any Error,
        callLog: CallLog = CallLog()
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.text = text
        self.toolCalls = toolCalls
        self.failure = generalFailure
        self.callLog = callLog
    }

    func respond(
        to request: GenerationRequest,
        streamingInto channel: GenerationChannel
    ) async throws {
        callLog.record(identifier)

        channel.send(.metadata(["modelID": identifier, "requestID": request.id.uuidString]))
        if let failure {
            channel.send(.finished(.error))
            throw failure
        }

        // Chunked, so callers that assume whole-response delivery break here
        // rather than in production.
        for chunk in text.chunked(into: 5) {
            channel.send(.text(chunk))
        }
        for call in toolCalls { channel.send(.toolCall(call)) }

        channel.send(.usage(TokenUsage(inputTokens: 10, outputTokens: text.count / 4)))
        channel.send(.finished(toolCalls.isEmpty ? .stop : .toolCalls))
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func record(_ identifier: String) {
        lock.lock()
        calls.append(identifier)
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        guard !isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }
    }
}

// MARK: - The suites

@Suite("Executor contract — scripted")
struct ScriptedExecutorContractTests {
    @Test("scripted executor satisfies the contract")
    func satisfiesContract() async throws {
        try await ExecutorContract.verify(ScriptedExecutor())
    }
}

/// The same contract, against real providers.
///
/// Skipped without credentials rather than mocked, because a mocked HTTP layer
/// would only prove that our own encoder matches our own decoder.
@Suite("Executor contract — live providers", .serialized)
struct LiveExecutorContractTests {
    @Test(
        "Gemini satisfies the contract",
        .enabled(if: ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil))
    func gemini() async throws {
        let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]!
        try await ExecutorContract.verify(
            GeminiExecutor(model: "gemini-3.8-flash", apiKey: key))
    }

    @Test(
        "Anthropic satisfies the contract",
        .enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
    func anthropic() async throws {
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
        try await ExecutorContract.verify(
            AnthropicExecutor(model: "claude-sonnet-4-5", apiKey: key))
    }

    @Test(
        "Apple on-device satisfies the contract",
        .enabled(if: AppleOnDeviceExecutor.isAvailable))
    func appleOnDevice() async throws {
        // Tools are exercised separately: the on-device model's tool support
        // works through Apple's own `Tool` protocol, not JSON schemas.
        try await ExecutorContract.verify(AppleOnDeviceExecutor(), supportsTools: false)
    }
}
