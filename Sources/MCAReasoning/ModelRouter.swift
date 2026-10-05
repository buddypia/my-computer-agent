import Foundation
import MCACore
import OSLog

/// Where API keys come from.
///
/// Reading the environment first and the encrypted store second means a
/// developer can export a key for a quick run, while the shipped app keeps
/// credentials out of the config file and off disk in plaintext.
public struct CredentialStore: Sendable {
    /// Where a provider's key came from. The distinction is not cosmetic: only
    /// a keychain item can be removed from inside the app, so offering a
    /// "Remove" button for an environment variable would be a button that does
    /// nothing.
    public enum Source: Sendable, Equatable {
        case override
        case environment(variable: String)
        case keychain
    }

    private let overrides: [String: String]
    /// Injected rather than read from `ProcessInfo` at each call site, so a
    /// test can describe an environment without mutating the process's own —
    /// which leaks into every test running in parallel with it.
    private let environment: [String: String]
    /// Injected for the same reason, and for a sharper one: the keychain is
    /// shared by the whole machine, so a default-constructed store makes a test
    /// pass or fail depending on whether the developer running it happens to
    /// have a real key installed.
    private let secrets: SecretStore

    public init(
        overrides: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: SecretStore = .shared
    ) {
        self.overrides = overrides
        self.environment = environment
        self.secrets = secrets
    }

    public static func environmentVariables(for provider: String) -> [String] {
        switch provider {
        case "gemini": return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case "anthropic": return ["ANTHROPIC_API_KEY"]
        case "openai-compatible": return ["OPENAI_API_KEY"]
        case "typesafe": return ["TYPESAFE_API_KEY"]
        default: return []
        }
    }

    public func key(for provider: String) -> String? {
        if let value = overrides[provider], !value.isEmpty { return value }
        if let variable = environmentVariable(for: provider) { return environment[variable] }
        return secrets.read(account: provider)
    }

    public func source(for provider: String) -> Source? {
        if let value = overrides[provider], !value.isEmpty { return .override }
        if let variable = environmentVariable(for: provider) {
            return .environment(variable: variable)
        }
        return secrets.read(account: provider) != nil ? .keychain : nil
    }

    private func environmentVariable(for provider: String) -> String? {
        Self.environmentVariables(for: provider).first { variable in
            environment[variable].map { !$0.isEmpty } ?? false
        }
    }

    public func availableProviders() -> [String] {
        ["gemini", "anthropic", "openai-compatible", "typesafe"].filter { key(for: $0) != nil }
    }
}

/// Resolves an `AgentTask` to a concrete executor, and fails over on retryable
/// errors.
///
/// Routing lives here rather than at call sites for two reasons: the price of a
/// model changes (Gemini 3.8 Flash doubles on 2027-01-01) and preview model IDs
/// get retired, so both belong in configuration; and the triage-gate pattern
/// only works if *every* call declares its tier.
public struct ModelRouter: Sendable {
    public typealias CustomResolver = @Sendable (ModelRef) throws -> (any LanguageModelExecuting)?

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Router")
    private let policy: RoutingPolicy
    private let credentials: CredentialStore
    private let ollamaHost: URL
    private let customResolver: CustomResolver?

    public init(
        policy: RoutingPolicy,
        credentials: CredentialStore,
        ollamaHost: URL = URL(string: "http://127.0.0.1:11434/v1")!,
        customResolver: CustomResolver? = nil
    ) {
        self.policy = policy
        self.credentials = credentials
        self.ollamaHost = ollamaHost
        self.customResolver = customResolver
    }

    public func executor(for reference: ModelRef) throws -> any LanguageModelExecuting {
        if let custom = try customResolver?(reference) {
            return custom
        }
        switch reference.provider {
        case "apple":
            return AppleOnDeviceExecutor()

        case "gemini":
            guard let key = credentials.key(for: "gemini") else {
                throw LanguageModelError.missingCredentials(provider: "gemini")
            }
            return GeminiExecutor(model: reference.model, apiKey: key)

        case "anthropic":
            guard let key = credentials.key(for: "anthropic") else {
                throw LanguageModelError.missingCredentials(provider: "anthropic")
            }
            return AnthropicExecutor(model: reference.model, apiKey: key)

        case "ollama":
            return OpenAICompatibleExecutor.ollama(model: reference.model, host: ollamaHost)

        case "openai-compatible":
            return OpenAICompatibleExecutor(
                model: reference.model,
                apiKey: credentials.key(for: "openai-compatible"))

        default:
            throw LanguageModelError.transport("Unknown provider '\(reference.provider)'")
        }
    }

    /// The ordered list of models to try for a task: the primary route, then
    /// its fallbacks.
    public func chain(for task: AgentTask) -> [ModelRef] {
        var chain: [ModelRef] = []
        if let primary = policy.routes[task] { chain.append(primary) }
        chain.append(contentsOf: policy.fallbacks[task] ?? [])
        return chain
    }

    /// Why `reference` cannot run at all, if it cannot.
    ///
    /// Checked before the chain is entered rather than discovered by letting
    /// the request fail, because both reasons here are settled facts rather
    /// than luck: Apple Intelligence is switched off, or the provider has no
    /// key. Attempting anyway looks identical in the log to a transient
    /// network fault, and `triage` is attempted every five seconds — enough to
    /// report the same permanent condition as an error 17,000 times a day.
    public func unavailableReason(for reference: ModelRef) -> String? {
        if (try? customResolver?(reference)) != nil {
            return nil
        }
        switch reference.provider {
        case "apple":
            return AppleOnDeviceExecutor.unavailableReason

        case "gemini", "anthropic", "openai-compatible":
            guard credentials.key(for: reference.provider) == nil else { return nil }
            return "no \(reference.provider) API key (mca auth set \(reference.provider))"

        case "ollama":
            // Keyless and local. Whether the server is up is a per-request
            // fact, so it stays a retryable failure rather than a hard block.
            return nil

        default:
            return "unknown provider '\(reference.provider)'"
        }
    }

    /// The chain with routes that cannot run at all removed.
    public func usableChain(for task: AgentTask) -> [ModelRef] {
        chain(for: task).filter { unavailableReason(for: $0) == nil }
    }

    /// Why `task` has no model that can run it, if it has none.
    ///
    /// `nil` means at least one route is usable. Callers on a timer use this to
    /// stop paying their cadence for a route that cannot succeed, and to tell
    /// the user which switch to flick.
    public func blockedReason(for task: AgentTask) -> String? {
        let candidates = chain(for: task)
        guard candidates.isEmpty || usableChain(for: task).isEmpty else { return nil }
        guard !candidates.isEmpty else {
            return "no model configured for '\(task.rawValue)'"
        }
        let reasons = candidates.map { reference in
            "\(reference.provider)/\(reference.model): "
                + (unavailableReason(for: reference) ?? "unavailable")
        }
        return reasons.joined(separator: "; ")
    }

    /// Runs `task` against the first executor in the chain that works.
    ///
    /// Only retryable errors advance the chain — a bad API key or a malformed
    /// request will fail identically on the next provider, so failing fast is
    /// more useful than burning three round trips.
    public func run(
        task: AgentTask,
        transcript: [TranscriptEntry],
        tools: [ToolDefinition] = [],
        temperature: Double? = nil,
        responseSchema: Data? = nil,
        streamingInto channel: GenerationChannel? = nil
    ) async throws -> CompletedResponse {
        // Filtered, not merely ordered: a route with no key and an on-device
        // model that is switched off are excluded here so they never reach the
        // loop below, which would otherwise log each of them as a failure on
        // every single call.
        let candidates = usableChain(for: task)
        guard !candidates.isEmpty else {
            throw LanguageModelError.transport(
                blockedReason(for: task) ?? "No model configured for task '\(task.rawValue)'")
        }

        var lastError: Error = LanguageModelError.transport("No candidate ran")

        for reference in candidates {
            let executor: any LanguageModelExecuting
            do {
                executor = try self.executor(for: reference)
            } catch {
                lastError = error
                continue
            }

            // Never send a vision request to a model that cannot see; that
            // produces a confidently wrong answer rather than an error.
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

            let request = GenerationRequest(
                transcript: transcript,
                tools: tools,
                options: GenerationOptions(
                    temperature: temperature,
                    maximumResponseTokens: policy.maxOutputTokens[task],
                    reasoningLevel: reference.reasoningLevel,
                    responseSchema: responseSchema))

            do {
                let collector = ResponseCollector()
                let combined = GenerationChannel { event in
                    collector.handle(event)
                    channel?.send(event)
                }
                try await executor.respond(to: request, streamingInto: combined)
                return collector.result()
            } catch let error as LanguageModelError where error.isRetryable {
                log.warning("""
                    \(executor.identifier, privacy: .public) failed \
                    (\(error.description, privacy: .public)); trying next in chain
                    """)
                lastError = error
                continue
            } catch let urlError as URLError {
                let wrapped = LanguageModelError.transport(urlError.localizedDescription)
                log.warning("""
                    \(executor.identifier, privacy: .public) failed with network error \
                    (\(urlError.localizedDescription, privacy: .public)); trying next in chain
                    """)
                lastError = wrapped
                continue
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain || nsError.domain == "kCFErrorDomainCFNetwork" {
                    let wrapped = LanguageModelError.transport(nsError.localizedDescription)
                    log.warning("""
                        \(executor.identifier, privacy: .public) failed with network error \
                        (\(nsError.localizedDescription, privacy: .public)); trying next in chain
                        """)
                    lastError = wrapped
                    continue
                }
                throw error
            }
        }
        throw lastError
    }
}

// Credential storage lives in `SecretStore.swift`: keys are sealed with HPKE to
// a Secure Enclave key before they reach the keychain, so no call site here can
// write one in the clear.
