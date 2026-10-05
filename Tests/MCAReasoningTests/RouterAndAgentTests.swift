import Foundation
import MCACore
import MCAMemory
import Testing

@testable import MCAReasoning

extension CredentialStore {
    /// A store with nothing in it, for the tests that assert on what happens
    /// when a provider has no key.
    ///
    /// `CredentialStore()` will not do: it falls through to the login keychain,
    /// which is machine-wide. On a developer's Mac with a real Gemini key
    /// installed those tests pass or fail depending on who runs them.
    static func sealed(overrides: [String: String] = [:]) -> CredentialStore {
        CredentialStore(
            overrides: overrides,
            environment: [:],
            secrets: SecretStore(namespace: "com.buddypia.mca.tests.never-written"))
    }

    static var empty: CredentialStore { sealed() }
}

@Suite("Model router")
struct ModelRouterTests {
    static func makeRouter(
        primary: ScriptedExecutor,
        fallbacks: [ScriptedExecutor] = []
    ) -> TestRouter {
        TestRouter(primary: primary, fallbacks: fallbacks)
    }

    @Test("resolves each provider name to its executor")
    func providerResolution() throws {
        let router = ModelRouter(
            policy: .default,
            credentials: CredentialStore(overrides: [
                "gemini": "g", "anthropic": "a", "openai-compatible": "o",
            ]))

        #expect(try router.executor(for: ModelRef(provider: "apple", model: "system"))
            .identifier == "apple/system")
        #expect(try router.executor(for: ModelRef(provider: "gemini", model: "gemini-3.8-flash"))
            .identifier == "gemini/gemini-3.8-flash")
        #expect(try router.executor(for: ModelRef(provider: "anthropic", model: "claude-sonnet-4-5"))
            .identifier == "anthropic/claude-sonnet-4-5")
        #expect(try router.executor(for: ModelRef(provider: "ollama", model: "qwen3:8b"))
            .capabilities.contains(.onDevice))
    }

    @Test("unknown provider names are rejected")
    func unknownProvider() {
        let router = ModelRouter(policy: .default, credentials: CredentialStore())
        #expect(throws: LanguageModelError.self) {
            _ = try router.executor(for: ModelRef(provider: "notreal", model: "m"))
        }
    }

    @Test("the chain is primary followed by fallbacks in order")
    func chainOrder() {
        let policy = RoutingPolicy(
            routes: [.answer: ModelRef(provider: "gemini", model: "first")],
            fallbacks: [.answer: [
                ModelRef(provider: "anthropic", model: "second"),
                ModelRef(provider: "openai-compatible", model: "third"),
            ]])
        let chain = ModelRouter(policy: policy, credentials: CredentialStore()).chain(for: .answer)
        #expect(chain.map(\.model) == ["first", "second", "third"])
    }

    @Test("routes with no credentials are dropped before the chain is entered")
    func filtersUnusableRoutes() {
        let policy = RoutingPolicy(
            routes: [.triage: ModelRef(provider: "gemini", model: "keyless")],
            fallbacks: [.triage: [
                ModelRef(provider: "anthropic", model: "also-keyless"),
                ModelRef(provider: "openai-compatible", model: "has-key"),
            ]])
        let router = ModelRouter(
            policy: policy,
            credentials: .sealed(overrides: ["openai-compatible": "o"]))

        // The unfiltered chain still describes the configuration…
        #expect(router.chain(for: .triage).map(\.model)
            == ["keyless", "also-keyless", "has-key"])
        // …but only the route that can actually run is attempted, so a missing
        // key is never reported as a per-call failure.
        #expect(router.usableChain(for: .triage).map(\.model) == ["has-key"])
        #expect(router.blockedReason(for: .triage) == nil)
    }

    @Test("a task whose whole chain is unusable reports why, once")
    func reportsBlockedTask() async {
        let policy = RoutingPolicy(
            routes: [.triage: ModelRef(provider: "gemini", model: "flash")],
            fallbacks: [.triage: [ModelRef(provider: "anthropic", model: "sonnet")]])
        let router = ModelRouter(policy: policy, credentials: .empty)

        let reason = router.blockedReason(for: .triage)
        // Names every route and what each one needs — this string is what the
        // HUD and `doctor` show, so a bare "unavailable" would be useless.
        #expect(reason?.contains("gemini/flash") == true)
        #expect(reason?.contains("anthropic/sonnet") == true)
        #expect(reason?.contains("mca auth set gemini") == true)

        // And `run` fails with that same reason rather than with whatever the
        // last executor in the chain happened to throw.
        await #expect(throws: LanguageModelError.self) {
            _ = try await router.run(task: .triage, transcript: [.prompt(Prompt(text: "hi"))])
        }
    }

    @Test("a task with no configured route is reported as unconfigured")
    func reportsUnconfiguredTask() {
        let router = ModelRouter(policy: RoutingPolicy(routes: [:]), credentials: CredentialStore())
        #expect(router.blockedReason(for: .triage)?.contains("no model configured") == true)
    }

    /// The settings window offers "Remove" only for a key it can actually
    /// remove. Reporting an environment variable as stored would put a button
    /// there that silently does nothing.
    @Test("distinguishes an environment key from a stored one")
    func reportsCredentialSource() {
        let variable = CredentialStore.environmentVariables(for: "gemini").first
        #expect(variable == "GEMINI_API_KEY")

        let overridden = CredentialStore(overrides: ["gemini": "k"])
        #expect(overridden.source(for: "gemini") == .override)

        let fromEnvironment = CredentialStore(
            environment: ["ANTHROPIC_API_KEY": "from-env"])
        #expect(fromEnvironment.source(for: "anthropic") == .environment(
            variable: "ANTHROPIC_API_KEY"))
        #expect(fromEnvironment.key(for: "anthropic") == "from-env")

        // An empty variable is not a key. Exporting `GEMINI_API_KEY=` is a
        // common way to *unset* one, and treating it as present would shadow
        // the keychain item that actually works.
        #expect(CredentialStore(environment: ["GEMINI_API_KEY": ""])
            .source(for: "gemini") != .environment(variable: "GEMINI_API_KEY"))

        #expect(CredentialStore(environment: [:]).source(for: "not-a-provider") == nil)
    }

    @Test("retryable failures advance the chain")
    func failsOverOnRetryableError() async throws {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "primary",
                failure: .http(status: 503, body: "overloaded"),
                callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "backup", text: "from backup", callLog: log)])

        let response = try await router.run(transcript: [.prompt(Prompt(text: "hi"))])
        #expect(response.text == "from backup")
        #expect(log.recorded == ["primary", "backup"])
    }

    @Test("network errors such as connection lost trigger chain failover")
    func failsOverOnNetworkConnectionLost() async throws {
        let log = CallLog()
        let lostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "primary",
                generalFailure: lostError,
                callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "backup", text: "from backup", callLog: log)])

        let response = try await router.run(transcript: [.prompt(Prompt(text: "hi"))])
        #expect(response.text == "from backup")
        #expect(log.recorded == ["primary", "backup"])
    }

    @Test("real ModelRouter fails over on network connection lost")
    func realModelRouterFailsOverOnNetworkConnectionLost() async throws {
        let log = CallLog()
        let lostError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        let primary = ScriptedExecutor(identifier: "primary", generalFailure: lostError, callLog: log)
        let backup = ScriptedExecutor(identifier: "backup", text: "from backup", callLog: log)

        let policy = RoutingPolicy(
            routes: [.answer: ModelRef(provider: "primary", model: "p")],
            fallbacks: [.answer: [ModelRef(provider: "backup", model: "b")]]
        )
        let router = ModelRouter(
            policy: policy,
            credentials: CredentialStore.empty,
            customResolver: { ref in
                if ref.provider == "primary" { return primary }
                if ref.provider == "backup" { return backup }
                return nil
            }
        )

        let response = try await router.run(task: .answer, transcript: [.prompt(Prompt(text: "hi"))])
        #expect(response.text == "from backup")
        #expect(log.recorded == ["primary", "backup"])
    }

    @Test("non-retryable failures stop immediately")
    func doesNotFailOverOnClientError() async {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "primary",
                failure: .http(status: 401, body: "bad key"),
                callLog: log),
            fallbacks: [ScriptedExecutor(identifier: "backup", callLog: log)])

        // A rejected key fails identically everywhere; burning a second round
        // trip only delays the error the user needs to see.
        await #expect(throws: LanguageModelError.self) {
            _ = try await router.run(transcript: [.prompt(Prompt(text: "hi"))])
        }
        #expect(log.recorded == ["primary"])
    }

    @Test("vision requests skip models that cannot see")
    func skipsNonVisionModels() async throws {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "text-only", capabilities: [.streaming], callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "vision-capable",
                capabilities: [.streaming, .vision],
                text: "I see a terminal",
                callLog: log)])

        let response = try await router.run(transcript: [
            .prompt(Prompt(
                text: "what is this",
                images: [ImageAttachment(data: Data([1, 2]), mimeType: "image/png")]))
        ])

        // Sending an image to a text-only model does not error — it silently
        // answers without having seen anything, which is worse.
        #expect(response.text == "I see a terminal")
        #expect(log.recorded == ["vision-capable"])
    }

    @Test("tool requests skip models without tool calling")
    func skipsNonToolModels() async throws {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "no-tools", capabilities: [.streaming], callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "with-tools",
                capabilities: [.streaming, .toolCalling],
                text: "ok", callLog: log)])

        _ = try await router.run(
            transcript: [.prompt(Prompt(text: "search for something"))],
            tools: [ToolDefinition(name: "search", description: "d", parameters: Data("{}".utf8))])

        #expect(log.recorded == ["with-tools"])
    }

    @Test("hard reasoning requests skip models without reasoning capability")
    func skipsNonReasoningModels() async throws {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "fast-classifier", capabilities: [.streaming, .toolCalling], callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "deep-thinker",
                capabilities: [.streaming, .reasoning],
                text: "42", callLog: log)])

        let response = try await router.run(
            task: .hardReasoning,
            transcript: [.prompt(Prompt(text: "prove P != NP"))])

        #expect(response.text == "42")
        #expect(log.recorded == ["deep-thinker"])
    }

    @Test("thinking-level 400 error advances the failover chain")
    func thinkingErrorAdvancesChain() async throws {
        let log = CallLog()
        let router = Self.makeRouter(
            primary: ScriptedExecutor(
                identifier: "bad-thinking-model",
                failure: .http(status: 400, body: "Thinking level MINIMAL is not supported for this model"),
                callLog: log),
            fallbacks: [ScriptedExecutor(
                identifier: "fallback-model",
                text: "recovered",
                callLog: log)])

        let response = try await router.run(transcript: [.prompt(Prompt(text: "hello"))])
        #expect(response.text == "recovered")
        #expect(log.recorded == ["bad-thinking-model", "fallback-model"])
    }

    @Test("streaming reaches the caller and the collector agrees with it")
    func streamingMatchesCollected() async throws {
        let router = Self.makeRouter(primary: ScriptedExecutor(text: "streamed response text"))

        let recorder = EventRecorder()
        let response = try await router.run(
            transcript: [.prompt(Prompt(text: "hi"))],
            streamingInto: GenerationChannel { recorder.append($0) })

        let streamed = recorder.events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }.joined()

        // If these diverge, the HUD shows something different from what gets
        // stored — a class of bug that is very hard to notice by hand.
        #expect(streamed == response.text)
        #expect(response.text == "streamed response text")
    }
}

/// Wraps `ModelRouter`'s failover logic around scripted executors.
///
/// Mirrors the real `run` loop rather than reimplementing it differently, so a
/// change in one shows up as a failure here.
struct TestRouter {
    let primary: ScriptedExecutor
    let fallbacks: [ScriptedExecutor]

    func run(
        task: AgentTask = .answer,
        transcript: [TranscriptEntry],
        tools: [ToolDefinition] = [],
        streamingInto channel: GenerationChannel? = nil
    ) async throws -> CompletedResponse {
        var lastError: Error = LanguageModelError.transport("nothing ran")

        for executor in [primary] + fallbacks {
            let needsVision = transcript.contains { entry in
                if case .prompt(let prompt) = entry { return !prompt.images.isEmpty }
                return false
            }
            if needsVision && !executor.capabilities.contains(.vision) {
                lastError = LanguageModelError.unsupportedCapability("vision")
                continue
            }
            if !tools.isEmpty && !executor.capabilities.contains(.toolCalling) {
                lastError = LanguageModelError.unsupportedCapability("tool calling")
                continue
            }
            if task == .hardReasoning && !executor.capabilities.contains(.reasoning) {
                lastError = LanguageModelError.unsupportedCapability("reasoning")
                continue
            }

            let collector = ResponseCollector()
            let combined = GenerationChannel { event in
                collector.handle(event)
                channel?.send(event)
            }
            do {
                try await executor.respond(
                    to: GenerationRequest(transcript: transcript, tools: tools),
                    streamingInto: combined)
                return collector.result()
            } catch let error as LanguageModelError where error.isRetryable {
                lastError = error
                continue
            } catch let urlError as URLError {
                lastError = LanguageModelError.transport(urlError.localizedDescription)
                continue
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain || nsError.domain == "kCFErrorDomainCFNetwork" {
                    lastError = LanguageModelError.transport(nsError.localizedDescription)
                    continue
                }
                throw error
            }
        }
        throw lastError
    }
}

@Suite("Error classification")
struct ErrorClassificationTests {
    @Test("server-side and rate-limit errors are retryable")
    func retryable() {
        #expect(LanguageModelError.http(status: 500, body: "").isRetryable)
        #expect(LanguageModelError.http(status: 503, body: "").isRetryable)
        #expect(LanguageModelError.http(status: 429, body: "").isRetryable)
        #expect(LanguageModelError.transport("timeout").isRetryable)
        // A key this process does not have may exist for another provider.
        #expect(LanguageModelError.missingCredentials(provider: "gemini").isRetryable)
    }

    @Test("client errors are not retryable")
    func notRetryable() {
        #expect(!LanguageModelError.http(status: 400, body: "").isRetryable)
        #expect(!LanguageModelError.http(status: 401, body: "").isRetryable)
        #expect(!LanguageModelError.cancelled.isRetryable)
        #expect(!LanguageModelError.decoding("bad json").isRetryable)
    }

    @Test("HTTP errors keep the provider's message but bound its length")
    func errorBodyTruncated() {
        let error = LanguageModelError.http(status: 400, body: String(repeating: "x", count: 5000))
        #expect(error.description.count < 600)
    }
}

@Suite("Tool registry")
struct ToolRegistryTests {
    @Test("unknown tools return an error to the model rather than throwing")
    func unknownTool() async {
        let registry = ToolRegistry()
        let output = await registry.invoke(ToolCall(
            id: "1", name: "does_not_exist", arguments: Data("{}".utf8)))

        // The model can recover from this; a thrown error would lose the turn.
        #expect(output.content.contains("no tool named"))
        #expect(output.callID == "1")
    }

    @Test("a throwing tool reports the failure as content")
    func throwingTool() async {
        let registry = ToolRegistry(tools: [FailingTool()])
        let output = await registry.invoke(ToolCall(
            id: "2", name: "always_fails", arguments: Data("{}".utf8)))
        #expect(output.content.hasPrefix("Error:"))
    }

    @Test("definitions are stable and sorted")
    func definitionOrdering() async {
        let registry = ToolRegistry(tools: [FailingTool(), EchoTool()])
        let names = await registry.definitions().map(\.name)
        #expect(names == ["always_fails", "echo"])
    }

    @Test("search_context exposes a valid JSON Schema")
    func searchToolSchema() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-tool-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let tool = SearchContextTool(store: store)

        let schema = try JSONSerialization.jsonObject(with: tool.definition.parameters)
        let object = try #require(schema as? [String: Any])
        #expect(object["type"] as? String == "object")
        let required = try #require(object["required"] as? [String])
        #expect(required.contains("query"))
    }

    @Test("search_context reports no matches rather than an empty string")
    func searchToolEmptyResult() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-tool-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let result = try await SearchContextTool(store: store)
            .invoke(arguments: Data(#"{"query":"nothing here"}"#.utf8))

        // An empty tool result reads to the model as a malfunction; a sentence
        // telling it there were no matches is actionable.
        #expect(result.contains("No matching history"))
    }
}

struct FailingTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(name: "always_fails", description: "d", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        throw LanguageModelError.transport("deliberate failure")
    }
}

struct EchoTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(name: "echo", description: "d", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String { "echo" }
}

@Suite("Context formatting")
struct ContextFormatterTests {
    @Test("labels the microphone channel as the user")
    func speakerLabels() {
        let mine = ContextFormatter.line(for: .audio(AudioObservation(
            channel: .microphone, text: "I'll fix that")))
        let theirs = ContextFormatter.line(for: .audio(AudioObservation(
            channel: .systemAudio, text: "Sounds good")))

        #expect(mine.contains("You:"))
        #expect(theirs.contains("Other participant:"))
    }

    @Test("uses relative times so the model does not have to subtract")
    func relativeTimes() {
        #expect(ContextFormatter.relativeTime(Date()) == "just now")
        #expect(ContextFormatter.relativeTime(Date().addingTimeInterval(-300)) == "5m ago")
        #expect(ContextFormatter.relativeTime(Date().addingTimeInterval(-7200)) == "2h ago")
        #expect(ContextFormatter.relativeTime(Date().addingTimeInterval(-172_800)) == "2d ago")
    }

    @Test("collapses repeated captures of the same window")
    func deduplicatesWindows() {
        let observations: [DesktopObservation] = (0..<5).map { index in
            .screen(ScreenObservation(
                timestamp: Date().addingTimeInterval(Double(-index)),
                appName: "Xcode", windowTitle: "main.swift",
                text: "capture number \(index)", source: .accessibility))
        }
        let synthesized = ContextFormatter.synthesize(observations)

        // Five near-identical captures would otherwise crowd out the dialogue.
        #expect(synthesized.contains("capture number 0"))
        #expect(!synthesized.contains("capture number 4"))
    }

    @Test("keeps volatile transcripts out of the synthesized context")
    func excludesNonFinalAudio() {
        let synthesized = ContextFormatter.synthesize([
            .audio(AudioObservation(channel: .microphone, text: "partial gue", isFinal: false)),
            .audio(AudioObservation(channel: .microphone, text: "complete sentence", isFinal: true)),
        ])
        #expect(synthesized.contains("complete sentence"))
        #expect(!synthesized.contains("partial gue"))
    }

    @Test("respects the character budget")
    func budgetEnforced() {
        let observations: [DesktopObservation] = (0..<200).map { index in
            .audio(AudioObservation(
                channel: .systemAudio, text: String(repeating: "word ", count: 50) + "\(index)"))
        }
        #expect(ContextFormatter.synthesize(observations, maxCharacters: 1000).count <= 1000)
    }
}

@Suite("Pinned subject")
struct SubjectBlockTests {
    @Test("a question about a pinned subject says which window that is")
    func namesTheSubject() {
        let block = Agent.subjectBlock("Safari — Release notes")

        #expect(block.contains("Safari — Release notes"))
        // The ambiguous words are the ones the user actually types, so the
        // block has to claim them explicitly rather than hint at the subject.
        #expect(block.contains("\"this screen\"") || block.contains("\"the screen\""))
    }

    @Test("the model is told not to describe this app's own windows")
    func rulesOutOurOwnWindows() {
        #expect(Agent.subjectBlock("Xcode — Agent.swift").contains("own windows"))
    }

    @Test("nothing pinned adds nothing to the prompt")
    func silentWhenUnpinned() {
        // Otherwise every ordinary question would carry a paragraph about a
        // feature the user is not using.
        #expect(Agent.subjectBlock(nil).isEmpty)
        #expect(Agent.subjectBlock("").isEmpty)
    }

}

@Suite("Agent advice with actions")
struct AgentAdviseTests {
    @Test("parses action tags from model advice")
    func parsesActionTags() {
        let modelOutput = """
            承認待ちの確認
            CLIがマイグレーションの実行確認を求めています。
            [ACTION: 承認する (y) | y]
            """

        let card = Agent.parseAdviceCard(
            text: modelOutput,
            originTarget: "Terminal — zsh",
            roleId: "builtin.cli-dev"
        )

        #expect(card != nil)
        #expect(card?.title == "承認待ちの確認")
        #expect(card?.actionTitle == "承認する (y)")
        #expect(card?.actionPayload == "y")
        #expect(card?.originTarget == "Terminal — zsh")
        #expect(card?.roleId == "builtin.cli-dev")
        #expect(card?.body.contains("[ACTION:") == false)
    }

    @Test("returns nil when output is PASS or empty")
    func passesSilenceProtocol() {
        #expect(Agent.parseAdviceCard(text: "PASS") == nil)
        #expect(Agent.parseAdviceCard(text: "PASS.") == nil)
        #expect(Agent.parseAdviceCard(text: "   ") == nil)
    }
}

@Suite("CurrentScreenTool")
struct CurrentScreenToolTests {
    @Test("uses live reader when available")
    func usesLiveReader() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-screen-tool-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let tool = CurrentScreenTool(store: store, liveReader: {
            "Live screen: Xcode running on branch master"
        })

        let output = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(output == "Live screen: Xcode running on branch master")
    }

    @Test("returns clear non-retry guidance when no screen data is available")
    func returnsGuidanceWhenEmpty() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-screen-tool-empty-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let tool = CurrentScreenTool(store: store, liveReader: nil)

        let output = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(output.contains("No recent screen capture is available"))
        #expect(output.contains("Do not retry calling read_current_screen"))
    }
}

final class MockScriptedExecutor: LanguageModelExecuting, @unchecked Sendable {
    let identifier: String
    let capabilities: ModelCapabilities
    var handler: (@Sendable (GenerationRequest, GenerationChannel) throws -> Void)?

    init(
        identifier: String = "mock/test",
        capabilities: ModelCapabilities = [.toolCalling, .guidedGeneration, .streaming, .vision],
        handler: (@Sendable (GenerationRequest, GenerationChannel) throws -> Void)? = nil
    ) {
        self.identifier = identifier
        self.capabilities = capabilities
        self.handler = handler
    }

    func respond(to request: GenerationRequest, streamingInto channel: GenerationChannel) async throws {
        if let handler {
            try handler(request, channel)
        } else {
            channel.send(.text("acknowledged"))
            channel.send(.finished(.stop))
        }
    }
}

final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class TextHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""

    var text: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _text
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _text = newValue
        }
    }
}

@Suite("Agent tool loop guard")
struct AgentToolLoopTests {
    @Test("Screen history and live tool results cannot reintroduce a secret into the final model transcript", arguments: [false, true])
    func legacyHistorySecretIsRedacted(live: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteContextStore(url: url)
        let secret = "fixtureCredential0123456789"
        try await store.append(.screen(ScreenObservation(appName: "Meeting",
            windowTitle: "api_key: \(secret)", text: "api_key: \(secret)\nAgenda: quarterly review",
            source: .ocr, trigger: .watch)))
        let counter = StepCounter()
        let executor = MockScriptedExecutor { request, channel in
            let text = request.transcript.map { entry -> String in
                switch entry {
                case .instructions(let value): return value
                case .prompt(let prompt): return prompt.text
                case .toolOutput(let output): return output.content
                default: return ""
                }
            }.joined(separator: "\n")
            #expect(!text.contains(secret))
            #expect(text.contains("api_key=[REDACTED]"))
            #expect(text.contains("Agenda: quarterly review"))
            if counter.increment() == 1 {
                channel.send(.toolCall(ToolCall(id: "screen", name: "read_current_screen", arguments: Data("{}".utf8))))
                channel.send(.finished(.toolCalls))
                return
            }
            channel.send(.text("The agenda is quarterly review."))
            channel.send(.finished(.stop))
        }
        let router = ModelRouter(policy: RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")]),
            credentials: .empty, customResolver: { _ in executor })
        let reader: CurrentScreenTool.LiveReader?
        if live { reader = { "Window: api_key: \(secret)\nAgenda: quarterly review" } }
        else { reader = nil }
        let agent = Agent(router: router, store: store,
            tools: ToolRegistry(tools: [CurrentScreenTool(store: store, liveReader: reader)]), health: HealthRegistry())
        #expect(try await agent.answer("Summarize the meeting") == "The agenda is quarterly review.")
        #expect(counter.value == 2)
    }

    @Test("duplicate tool call loop is detected and broken cleanly")
    func breaksDuplicateToolLoop() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-loop-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { request, channel in
            let step = counter.increment()
            if !request.tools.isEmpty {
                // Return repetitive tool calls for read_current_screen
                let call = ToolCall(
                    id: "call_\(step)",
                    name: "read_current_screen",
                    arguments: Data("{}".utf8))
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                // Forced text fallback when tools are empty
                channel.send(.text("Screen capture is currently not accessible, but I can help you with questions."))
                channel.send(.finished(.stop))
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [
            CurrentScreenTool(store: store, liveReader: nil)
        ])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .english)

        let answer = try await agent.answer("What is on my screen?")
        #expect(answer == "Screen capture is currently not accessible, but I can help you with questions.")
        // Round 0: tool call 1
        // Round 1: duplicate tool call 2 -> triggers duplicate loop break!
        // Fallback round: tools: [] -> text output
        // Total calls should be 3, not 4 tool calls + failure!
        #expect(counter.value == 3)
    }

    @Test("answer failure explains tool error reasons when model returns empty text")
    func answerFailureExplainsToolErrors() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-failure-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { _, channel in
            let callIndex = counter.increment()
            if callIndex == 1 {
                // Round 0: model invokes unregistered tool
                let call = ToolCall(
                    id: "call-1",
                    name: "browser",
                    arguments: Data("{\"action\":\"navigate\"}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                // Round 1: model receives tool output, but returns empty text
                channel.send(.reasoning("Could not find browser window"))
                channel.send(.finished(.stop))
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer("ブラウザー操作して")
        #expect(answer.contains("回答にたどり着けませんでした。"))
        #expect(answer.contains("browser"))
        #expect(answer.contains("no tool named 'browser' is registered"))
        #expect(answer.contains("未登録"))
        #expect(answer.contains("Could not find browser window"))
    }

    @Test("answer failure includes diagnostic hint when GUI action found no matching window or element")
    func answerFailureIncludesDiagnosticHintsForActionNone() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-gui-hint-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { _, channel in
            let callIndex = counter.increment()
            if callIndex == 1 {
                let call = ToolCall(
                    id: "call-1",
                    name: "typesafe_act",
                    arguments: Data("{\"goal\":\"ブラウザーで検索\"}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                channel.send(.finished(.stop))
            }
        }

        struct MockTypesafeActTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "typesafe_act", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                "Action: none. Confidence: 0.00. Completed: false."
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [MockTypesafeActTool()])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer("ブラウザー操作して")
        #expect(answer.contains("回答にたどり着けませんでした。"))
        #expect(answer.contains("typesafe_act"))
        #expect(answer.contains("Action: none"))
        #expect(answer.contains("ブラウザなど") || answer.contains("前面に表示"))
    }

    @Test("answer self-heals when model emits empty text after screen inspection tools")
    func answerSelfHealsAfterScreenTools() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-self-heal-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { request, channel in
            let callIndex = counter.increment()
            if callIndex == 1 {
                // Round 0: run_applescript
                let call = ToolCall(
                    id: "call-as",
                    name: "run_applescript",
                    arguments: Data("{\"script\":\"tell application \\\"Google Chrome\\\" to activate\"}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else if callIndex == 2 {
                // Round 1: read_current_screen
                let call = ToolCall(
                    id: "call-screen",
                    name: "read_current_screen",
                    arguments: Data("{}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else if callIndex == 3 {
                // Round 2: model finished tools, but returned empty text!
                channel.send(.finished(.stop))
            } else {
                // Self-healing turn: forced text without tools
                #expect(request.tools.isEmpty)
                channel.send(.text("Google Chromeの『K-시네마틱 감성 대화 쇼케이스』を確認しました。どのボタンをクリックしますか？"))
                channel.send(.finished(.stop))
            }
        }

        struct MockScriptTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "run_applescript", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                "AppleScript completed successfully with no output."
            }
        }

        struct MockScreenTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "read_current_screen", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                """
                App: Google Chrome
                Window: K-시네마틱 감성 대화 쇼케이스 - Google Chrome
                Status: Live screen capture

                チャット開始ボタン / 設定 / 閉じる
                """
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [MockScriptTool(), MockScreenTool()])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer("画面操作して")
        #expect(answer.contains("Google Chromeの『K-시네마틱 감성 대화 쇼케이스』を確認しました。"))
        #expect(counter.value == 4) // call 1, 2, 3 (empty), 4 (self-healing)
    }

    @Test("answer synthesizes helpful summary when model and self-healing both return empty text")
    func answerSynthesizesSummaryWhenSelfHealingReturnsEmpty() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-synthesize-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { _, channel in
            let callIndex = counter.increment()
            if callIndex == 1 {
                // Round 0: run_applescript
                let call = ToolCall(
                    id: "call-as",
                    name: "run_applescript",
                    arguments: Data("{\"script\":\"activate\"}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else if callIndex == 2 {
                // Round 1: read_current_screen
                let call = ToolCall(
                    id: "call-screen",
                    name: "read_current_screen",
                    arguments: Data("{}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                // Round 2 and Self-healing both return empty text
                channel.send(.finished(.stop))
            }
        }

        struct MockScriptTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "run_applescript", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                "AppleScript completed successfully with no output."
            }
        }

        struct MockScreenTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "read_current_screen", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                """
                App: Google Chrome
                Window: K-시네마틱 감성 대화 쇼케이스 - Google Chrome
                Status: Live screen capture
                """
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [MockScriptTool(), MockScreenTool()])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer("画面操作して")
        #expect(answer.contains("Google Chrome"))
        #expect(answer.contains("K-시네마틱 감성 대화 쇼케이스"))
        #expect(answer.contains("画面を表示し、現在の内容を確認しました。"))
        #expect(answer.contains("具体的にどの操作を行いますか？"))
        #expect(!answer.contains("回答にたどり着けませんでした。"))
    }

    @Test("autonomous action mode executes multi-step tool workflow beyond 4 rounds")
    func testAutonomousActionExecutesMultiRoundTools() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-autonomous-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        struct MockSequentialTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "step_tool", description: "test step tool", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                let parsed = String(decoding: arguments, as: UTF8.self)
                return "Executed step with args: \(parsed)"
            }
        }

        let executor = MockScriptedExecutor { request, channel in
            let callIndex = counter.increment()
            if callIndex <= 5 {
                // Rounds 0 through 4 (5 tool calls in total)
                let call = ToolCall(
                    id: "call_\(callIndex)",
                    name: "step_tool",
                    arguments: Data("{\"step\":\(callIndex)}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                // Round 5: model completes autonomous objective
                channel.send(.text("Firefoxでの自律情報収集とタスク実行が完了しました。全5ステップの収集結果です。"))
                channel.send(.finished(.stop))
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [MockSequentialTool()])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer(
            "Firefoxを操作して5つのページから情報を収集して",
            isAutonomousAction: true
        )

        #expect(answer.contains("自律情報収集とタスク実行が完了しました"))
        #expect(counter.value == 6) // 5 tool calls + 1 final completion text
    }

    @Test("autonomous action prohibits intermediate confirmation and question inquiries in fallback summary")
    func testAutonomousActionProhibitsQuestionInquiriesInFallback() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-no-questions-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let counter = StepCounter()

        let executor = MockScriptedExecutor { request, channel in
            let callIndex = counter.increment()
            if callIndex == 1 {
                let call = ToolCall(
                    id: "call_scr",
                    name: "read_current_screen",
                    arguments: Data("{}".utf8)
                )
                channel.send(.toolCall(call))
                channel.send(.finished(.toolCalls))
            } else {
                // Return empty text to trigger fallback summary
                channel.send(.finished(.stop))
            }
        }

        struct MockScreenTool: AgentTool {
            var definition: ToolDefinition {
                ToolDefinition(name: "read_current_screen", description: "test", parameters: Data("{}".utf8))
            }
            func invoke(arguments: Data) async throws -> String {
                """
                App: Firefox
                Window: Mozilla Firefox - Search Results
                Status: Ready
                """
            }
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let tools = ToolRegistry(tools: [MockScreenTool()])

        let agent = Agent(
            router: router,
            store: store,
            tools: tools,
            health: HealthRegistry(),
            language: .japanese)

        let answer = try await agent.answer(
            "Firefoxで画面を確認して処理を進めて",
            isAutonomousAction: true
        )

        // Must NOT ask the user "具体的にどの操作を行いますか？" or "続けて行いたい操作をご指示ください"
        #expect(!answer.contains("具体的にどの操作を行いますか？"))
        #expect(!answer.contains("続けて行いたい操作をご指示ください"))
        #expect(answer.contains("内容を確認しました"))
        #expect(answer.contains("完了は確認できていません"))
    }

    @Test("answer includes prior conversation history in prompt")
    func testAnswerIncludesPriorConversationHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-history-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let capturedPrompt = TextHolder()

        let executor = MockScriptedExecutor { request, channel in
            for entry in request.transcript {
                if case .prompt(let prompt) = entry {
                    capturedPrompt.text = prompt.text
                }
            }
            channel.send(.text("スクロールを開始しました。"))
            channel.send(.finished(.stop))
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let agent = Agent(
            router: router,
            store: store,
            tools: ToolRegistry(tools: []),
            health: HealthRegistry(),
            language: .japanese)

        let history = [
            ConversationTurn(role: .user, text: "ブラウザーをスクロールしてTwitterの3K以上を探して"),
            ConversationTurn(role: .assistant, text: "次のアクションでスクロールを探すこと"),
        ]

        let answer = try await agent.answer("スクロールを実行して", history: history)
        #expect(answer == "スクロールを開始しました。")
        #expect(capturedPrompt.text.contains("# Prior Conversation History"))
        #expect(capturedPrompt.text.contains("User: ブラウザーをスクロールしてTwitterの3K以上を探して"))
        #expect(capturedPrompt.text.contains("Assistant: 次のアクションでスクロールを探すこと"))
        #expect(capturedPrompt.text.contains("スクロールを実行して"))
    }

    @Test("answer with autonomous action injects bypass directives into instructions")
    func testAnswerAutonomousActionBypassDirectives() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-agent-autonomous-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteContextStore(url: url)
        let capturedInstructions = TextHolder()

        let executor = MockScriptedExecutor { request, channel in
            for entry in request.transcript {
                if case .instructions(let text) = entry {
                    capturedInstructions.text = text
                }
            }
            channel.send(.text("自律実行計画を完了しました。"))
            channel.send(.finished(.stop))
        }

        let policy = RoutingPolicy(routes: [.answer: ModelRef(provider: "mock", model: "test")])
        let router = ModelRouter(
            policy: policy,
            credentials: .empty,
            customResolver: { _ in executor })

        let agent = Agent(
            router: router,
            store: store,
            tools: ToolRegistry(tools: []),
            health: HealthRegistry(),
            language: .japanese)

        let triage = ComputerActionTriage(
            needsComputerAction: true,
            confidence: 0.95,
            intentCategory: "browser_scroll_or_search",
            suggestedPlan: "ブラウザーをスクロールして3K以上のツイートを探索"
        )

        let answer = try await agent.answer(
            "ブラウザーをスクロールしてTwitterの3K以上を探して",
            isAutonomousAction: true,
            triage: triage
        )

        #expect(answer == "自律実行計画を完了しました。")
        #expect(capturedInstructions.text.contains("# Autonomous goal execution"))
        #expect(capturedInstructions.text.contains("Suggested triage plan"))
    }
}
