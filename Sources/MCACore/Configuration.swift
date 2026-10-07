import Foundation

/// The speech recognition engine to use for audio transcription.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    /// On-device transcription using Apple's SpeechAnalyzer (macOS 26+). Completely local and private.
    case apple
    /// High-accuracy cloud transcription and intent recognition using Google Gemini Flash.
    case gemini

    public var title: String {
        switch self {
        case .apple:
            return "macOS (On-Device)"
        case .gemini:
            return "Gemini Flash (Cloud)"
        }
    }
}

/// Where a model lives and which adapter can talk to it.
public struct ModelRef: Codable, Sendable, Hashable {
    public var provider: String   // "gemini" | "anthropic" | "openai-compatible" | "apple"
    public var model: String      // e.g. "gemini-3.8-flash"
    /// Optional per-route override of thinking depth. Gemini 3.x maps
    /// `minimal` to `low` (Gemini 3 rejects minimal), Anthropic maps to 0 / no thinking,
    /// and other providers map as close as they can or drop if unsupported.
    public var reasoningLevel: ReasoningLevel?

    public init(provider: String, model: String, reasoningLevel: ReasoningLevel? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningLevel = reasoningLevel
    }
}

public enum ReasoningLevel: String, Codable, Sendable, Comparable {
    case minimal, low, medium, high

    private var rank: Int {
        switch self {
        case .minimal: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The unit of routing. Every LLM call in the app declares which task it is,
/// and the policy — not the call site — decides which model runs it.
public enum AgentTask: String, Codable, Sendable, CaseIterable {
    /// Tier 1. On-device gate: "is this worth interrupting the user about?"
    case triage
    /// Tier 2. Cheap classification / short summarisation.
    case classify
    /// Tier 3. The workhorse: answering, tool use, vision.
    case answer
    /// Tier 3. Screen understanding with images attached.
    case vision
    /// Tier 4. Long-context or hard reasoning, on explicit request only.
    case hardReasoning
}

/// Model IDs and prices are deliberately *not* compiled in. Gemini 3.8 Flash
/// doubles in price on 2027-01-01 and preview model IDs get retired; both
/// should be a config edit, not a code change.
public struct RoutingPolicy: Codable, Sendable {
    public var routes: [AgentTask: ModelRef]
    public var fallbacks: [AgentTask: [ModelRef]]
    /// Hard ceiling on output tokens per task, to bound cost of a runaway loop.
    public var maxOutputTokens: [AgentTask: Int]

    public init(
        routes: [AgentTask: ModelRef],
        fallbacks: [AgentTask: [ModelRef]] = [:],
        maxOutputTokens: [AgentTask: Int] = [:]
    ) {
        self.routes = routes
        self.fallbacks = fallbacks
        self.maxOutputTokens = maxOutputTokens
    }

    /// Current defaults as of 2026-09. See docs/architecture_v2_design_proposals.md §3.
    public static let `default` = RoutingPolicy(
        routes: [
            .triage: ModelRef(provider: "apple", model: "system"),
            .classify: ModelRef(provider: "gemini", model: "gemini-3.8-flash", reasoningLevel: .minimal),
            .answer: ModelRef(provider: "gemini", model: "gemini-3.8-flash", reasoningLevel: .low),
            .vision: ModelRef(provider: "gemini", model: "gemini-3.8-flash", reasoningLevel: .low),
            .hardReasoning: ModelRef(provider: "gemini", model: "gemini-3.8-flash", reasoningLevel: .high),
        ],
        // One Gemini model across every cloud tier. The cheaper Flash Lite is
        // deliberately not used: two model IDs meant two sets of quota,
        // capability and deprecation dates to track for a saving that the
        // triage gate already makes irrelevant — the on-device gate is what
        // keeps the constant path free, not the price of the fallback. Cost is
        // held down by `reasoningLevel` and `maxOutputTokens` instead.
        fallbacks: [
            .triage: [
                ModelRef(provider: "gemini", model: "gemini-3.8-flash", reasoningLevel: .minimal),
            ],
            .answer: [
                ModelRef(provider: "anthropic", model: "claude-sonnet-4-5"),
                ModelRef(provider: "openai-compatible", model: "gpt-5.1"),
            ],
            .vision: [
                ModelRef(provider: "anthropic", model: "claude-sonnet-4-5"),
                ModelRef(provider: "openai-compatible", model: "gpt-5.1"),
            ],
        ],
        maxOutputTokens: [
            .triage: 256,
            .classify: 512,
            .answer: 4096,
            .vision: 4096,
            .hardReasoning: 16384,
        ]
    )
}

/// How the agent reaches a browser: attach to the user's running Chrome first (their logins
/// are the point), and only launch a private profile when asked to.
public struct BrowserAutomationSettings: Codable, Sendable, Equatable {
    /// Whether browser tools are registered at all.
    public var enabled: Bool
    public var devtoolsHost: String
    /// DevTools ports probed in order; the first that answers wins.
    public var devtoolsPorts: [Int]
    /// Start a dedicated Chrome (own profile, `launchPort`) when nothing is
    /// listening. Off by default: a second browser window appearing unasked
    /// is a side effect the user should opt into.
    public var launchIfMissing: Bool
    public var launchPort: Int
    /// Fall back to macOS Accessibility on the frontmost browser window when
    /// no DevTools endpoint is reachable.
    public var accessibilityFallback: Bool
    /// Extra guidance appended to the act/observe/extract prompts, e.g. site
    /// conventions the user cares about.
    public var instructions: String?
    /// Which routing tier answers observe / act / extract. These are
    /// structured-output calls over a page outline; a low-reasoning tier is
    /// usually enough and much faster than the answering tier.
    public var inferenceTask: AgentTask

    public init(
        enabled: Bool = true,
        devtoolsHost: String = "127.0.0.1",
        devtoolsPorts: [Int] = [9222, 9333],
        launchIfMissing: Bool = false,
        launchPort: Int = 9222,
        accessibilityFallback: Bool = true,
        instructions: String? = nil,
        inferenceTask: AgentTask = .answer
    ) {
        self.enabled = enabled
        self.devtoolsHost = devtoolsHost
        self.devtoolsPorts = devtoolsPorts
        self.launchIfMissing = launchIfMissing
        self.launchPort = launchPort
        self.accessibilityFallback = accessibilityFallback
        self.instructions = instructions
        self.inferenceTask = inferenceTask
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BrowserAutomationSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        devtoolsHost = try container.decodeIfPresent(String.self, forKey: .devtoolsHost) ?? fallback.devtoolsHost
        devtoolsPorts = try container.decodeIfPresent([Int].self, forKey: .devtoolsPorts) ?? fallback.devtoolsPorts
        launchIfMissing = try container.decodeIfPresent(Bool.self, forKey: .launchIfMissing) ?? fallback.launchIfMissing
        launchPort = try container.decodeIfPresent(Int.self, forKey: .launchPort) ?? fallback.launchPort
        accessibilityFallback = try container.decodeIfPresent(Bool.self, forKey: .accessibilityFallback) ?? fallback.accessibilityFallback
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        inferenceTask = try container.decodeIfPresent(AgentTask.self, forKey: .inferenceTask) ?? fallback.inferenceTask
    }
}

public struct AgentConfiguration: Codable, Sendable {
    public var routing: RoutingPolicy

    /// Minimum gap between two proactive interruptions, regardless of how many
    /// interesting things happen. Cognitive-load guard (REQ-9).
    public var minSecondsBetweenProactiveAlerts: Double
    /// How long after typing stops before we sample the screen.
    public var typingPauseSeconds: Double
    /// Retention for raw observations.
    public var retentionDays: Int

    public var proactiveEnabled: Bool
    /// Whether the microphone and the system-audio tap stay open for the life
    /// of the process.
    ///
    /// Off by default, and the default is the point. An always-open microphone
    /// costs a permanent recording indicator, a device other apps cannot take
    /// exclusive use of, and a transcript of every room the Mac is in — paid
    /// continuously, in exchange for a capability that is only occasionally
    /// wanted. With this off, capture is opened when a voice conversation
    /// starts and closed when it ends.
    public var alwaysListening: Bool
    public var transcriptionEngine: TranscriptionEngine
    public var mcpServerEnabled: Bool
    /// Lets MCP clients run the tools that act on this Mac (`run_applescript`,
    /// `computer`, `click_element`, `typesafe_act`, live `autonomous_act`, and
    /// the browser tools that evaluate JavaScript or write files) with no
    /// approval prompt, because a stdio server has no UI to ask in.
    ///
    /// Off by default: the MCP caller is itself a model reading untrusted
    /// content, so "the client asked" is not the same as "the user agreed".
    public var mcpAllowDangerousTools: Bool

    /// Apps never captured, by bundle ID prefix. Enforced *before* anything is
    /// written to disk (REQ-10 zero-trust pre-capture exclusion).
    public var excludedBundleIDs: [String]
    /// Window titles matching any of these (case-insensitive) are dropped.
    public var excludedWindowPatterns: [String]

    public var databaseURL: URL

    /// Model used for local EmbeddingGemma 2 System One evaluations and memory embeddings.
    public var embeddingGemmaModel: String

    /// Browser automation (snapshot / act / extract tools).
    public var browser: BrowserAutomationSettings

    public init(
        routing: RoutingPolicy = .default,
        minSecondsBetweenProactiveAlerts: Double = 60,
        typingPauseSeconds: Double = 1.5,
        retentionDays: Int = 30,
        proactiveEnabled: Bool = true,
        alwaysListening: Bool = false,
        transcriptionEngine: TranscriptionEngine = .gemini,
        mcpServerEnabled: Bool = true,
        mcpAllowDangerousTools: Bool = false,
        excludedBundleIDs: [String] = AgentConfiguration.defaultExcludedBundleIDs,
        excludedWindowPatterns: [String] = AgentConfiguration.defaultExcludedWindowPatterns,
        databaseURL: URL? = nil,
        embeddingGemmaModel: String = AgentConfiguration.defaultEmbeddingGemmaModel,
        browser: BrowserAutomationSettings = BrowserAutomationSettings()
    ) {
        self.routing = routing
        self.minSecondsBetweenProactiveAlerts = minSecondsBetweenProactiveAlerts
        self.typingPauseSeconds = typingPauseSeconds
        self.retentionDays = retentionDays
        self.proactiveEnabled = proactiveEnabled
        self.alwaysListening = alwaysListening
        self.transcriptionEngine = transcriptionEngine
        self.mcpServerEnabled = mcpServerEnabled
        self.mcpAllowDangerousTools = mcpAllowDangerousTools
        self.excludedBundleIDs = excludedBundleIDs
        self.excludedWindowPatterns = excludedWindowPatterns
        self.databaseURL = databaseURL ?? AgentConfiguration.defaultDatabaseURL
        self.embeddingGemmaModel = embeddingGemmaModel
        self.browser = browser
    }

    /// Decoded key by key, falling back to the default for anything absent.
    ///
    /// The synthesised initialiser requires *every* key to be present, so
    /// adding one field to this struct would make every config.json written
    /// before it fail to decode — and `load`'s callers turn a decode failure
    /// into a silent revert to defaults, discarding the user's whole file to
    /// recover one missing setting. `alwaysListening` is the first field to be
    /// added since anyone could have saved a file, which is what made this
    /// worth fixing rather than noting.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AgentConfiguration()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? `default`
        }

        routing = try value(.routing, fallback.routing)
        minSecondsBetweenProactiveAlerts = try value(
            .minSecondsBetweenProactiveAlerts, fallback.minSecondsBetweenProactiveAlerts)
        typingPauseSeconds = try value(.typingPauseSeconds, fallback.typingPauseSeconds)
        retentionDays = try value(.retentionDays, fallback.retentionDays)
        proactiveEnabled = try value(.proactiveEnabled, fallback.proactiveEnabled)
        alwaysListening = try value(.alwaysListening, fallback.alwaysListening)
        transcriptionEngine = try value(.transcriptionEngine, fallback.transcriptionEngine)
        mcpServerEnabled = try value(.mcpServerEnabled, fallback.mcpServerEnabled)
        mcpAllowDangerousTools = try value(.mcpAllowDangerousTools, fallback.mcpAllowDangerousTools)
        excludedBundleIDs = try value(.excludedBundleIDs, fallback.excludedBundleIDs)
        excludedWindowPatterns = try value(
            .excludedWindowPatterns, fallback.excludedWindowPatterns)
        databaseURL = try value(.databaseURL, fallback.databaseURL)
        embeddingGemmaModel = try value(.embeddingGemmaModel, fallback.embeddingGemmaModel)
        browser = try value(.browser, fallback.browser)
    }

    public static let defaultEmbeddingGemmaModel: String = "google/embeddinggemma-2-740m"

    public static let defaultExcludedBundleIDs: [String] = [
        "com.agilebits.onepassword",
        "com.1password",
        "com.bitwarden",
        "com.apple.keychainaccess",
        "com.lastpass",
        "com.dashlane",
        "com.apple.Passwords",
    ]

    public static let defaultExcludedWindowPatterns: [String] = [
        "private browsing",
        "incognito",
        "シークレット",
        "password",
        "パスワード",
        "sign in",
        "2fa",
        "one-time code",
    ]

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MyComputerAgent", directoryHint: .isDirectory)
    }

    public static var defaultDatabaseURL: URL {
        defaultSupportDirectory.appending(path: "context.sqlite3")
    }

    public static var defaultConfigURL: URL {
        defaultSupportDirectory.appending(path: "config.json")
    }

    /// Loads config from disk, falling back to defaults. Never throws on a
    /// missing file — a fresh install should just work.
    public static func load(from url: URL? = nil) throws -> AgentConfiguration {
        let url = url ?? defaultConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentConfiguration()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentConfiguration.self, from: data)
    }

    public func save(to url: URL? = nil) throws {
        let url = url ?? Self.defaultConfigURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The pre-capture privacy gate. Called before an observation is built, so
    /// excluded content never reaches memory or disk.
    public func isExcluded(bundleID: String?, windowTitle: String) -> Bool {
        if let bundleID {
            let lower = bundleID.lowercased()
            if excludedBundleIDs.contains(where: { lower.hasPrefix($0.lowercased()) }) {
                return true
            }
        }
        let title = windowTitle.lowercased()
        return excludedWindowPatterns.contains { title.contains($0.lowercased()) }
    }
}

/// The tabs in the Settings window.
public enum SettingsTab: String, Sendable, Hashable, CaseIterable {
    case general
    case overlay
    case shortcuts
    case models
    case permissions
}

