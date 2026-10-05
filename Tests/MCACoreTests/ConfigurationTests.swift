import Foundation
import Testing

@testable import MCACore

@Suite("Privacy exclusions")
struct PrivacyExclusionTests {
    let configuration = AgentConfiguration()

    @Test("excludes known credential managers by bundle ID", arguments: [
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
    ])
    func excludesPasswordManagers(bundleID: String) {
        #expect(configuration.isExcluded(bundleID: bundleID, windowTitle: "Vault"))
    }

    @Test("excludes windows whose title suggests secrets", arguments: [
        "Private Browsing — Safari",
        "New Incognito Window",
        "Sign in to your account",
        "Enter your password",
        "シークレット ウィンドウ",
    ])
    func excludesSensitiveTitles(title: String) {
        #expect(configuration.isExcluded(bundleID: "com.apple.Safari", windowTitle: title))
    }

    @Test("allows ordinary work")
    func allowsNormalWindows() {
        #expect(!configuration.isExcluded(
            bundleID: "com.microsoft.VSCode", windowTitle: "main.swift — my-project"))
        #expect(!configuration.isExcluded(
            bundleID: "com.tinyspeck.slackmacgap", windowTitle: "#engineering"))
        #expect(!configuration.isExcluded(bundleID: nil, windowTitle: "Terminal"))
    }

    @Test("matching is case-insensitive in both directions")
    func caseInsensitive() {
        #expect(configuration.isExcluded(
            bundleID: "COM.AGILEBITS.ONEPASSWORD", windowTitle: ""))
        #expect(configuration.isExcluded(
            bundleID: "com.apple.Safari", windowTitle: "PRIVATE BROWSING"))
    }
}

@Suite("Component health")
struct ComponentStateTests {
    @Test("only .running counts as healthy")
    func healthiness() {
        #expect(ComponentState.running.isHealthy)
        #expect(!ComponentState.degraded(reason: "no AEC").isHealthy)
        #expect(!ComponentState.failed(message: "boom").isHealthy)
        #expect(!ComponentState.disabled.isHealthy)
        #expect(!ComponentState.starting.isHealthy)
    }

    @Test("starting is distinct from disabled")
    func startingIsNotDisabled() {
        // They look identical to a user but mean opposite things: one resolves
        // on its own, the other never will.
        #expect(ComponentState.starting != ComponentState.disabled)
        #expect(!ComponentState.starting.isProblem)
        #expect(ComponentState.starting.displayText != ComponentState.disabled.displayText)
    }

    @Test("problems surface degraded and failed but not disabled or starting")
    func problemReporting() {
        var report = HealthReport()
        report[.microphone] = .running
        report[.systemAudioTap] = .failed(message: "unsigned binary")
        report[.realtimeVoice] = .disabled
        report[.transcription] = .degraded(reason: "model downloading")
        report[.memory] = .starting

        let problems = report.problems.map(\.0)
        #expect(problems.contains(.systemAudioTap))
        #expect(problems.contains(.transcription))
        #expect(!problems.contains(.microphone))
        #expect(!problems.contains(.realtimeVoice))
        #expect(!problems.contains(.memory))
        #expect(!report.allHealthy)
    }

    @Test("a failed component always carries its reason")
    func failureCarriesReason() {
        // The previous implementation reported "active" for a pipeline that had
        // thrown at startup. This type makes that unrepresentable.
        let state = ComponentState.failed(message: "LocalAudioTransport init failed")
        #expect(state.displayText.contains("LocalAudioTransport init failed"))
    }

    @Test("registry notifies observers only on real changes")
    func registryDeduplicates() async {
        let registry = HealthRegistry()
        let counter = Counter()

        await registry.observe { _ in counter.increment() }
        await registry.set(.memory, .running)
        await registry.set(.memory, .running)  // no change
        await registry.set(.memory, .degraded(reason: "slow"))

        // One for the initial call, one per distinct change.
        #expect(counter.value == 3)
    }

    @Test("component maps to the appropriate settings tab")
    func componentSettingsTabMapping() {
        #expect(ComponentID.screenCapture.settingsTab == .permissions)
        #expect(ComponentID.accessibility.settingsTab == .permissions)
        #expect(ComponentID.microphone.settingsTab == .permissions)
        #expect(ComponentID.systemAudioTap.settingsTab == .permissions)
        #expect(ComponentID.reasoning.settingsTab == .models)
        #expect(ComponentID.realtimeVoice.settingsTab == .models)
        #expect(ComponentID.transcription.settingsTab == .models)
        #expect(ComponentID.memory.settingsTab == .general)
        #expect(ComponentID.mcpServer.settingsTab == .general)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("Routing policy")
struct RoutingPolicyTests {
    @Test("default policy keeps triage on-device")
    func triageIsLocal() {
        // This is the decision that makes 24/7 operation affordable; if it ever
        // regresses to a cloud model the cost goes up roughly fiftyfold.
        #expect(RoutingPolicy.default.routes[.triage]?.provider == "apple")
    }

    @Test("every task has a route")
    func allTasksRouted() {
        for task in AgentTask.allCases {
            #expect(RoutingPolicy.default.routes[task] != nil, "no route for \(task)")
        }
    }

    @Test("every task has an output ceiling")
    func allTasksBounded() {
        for task in AgentTask.allCases {
            #expect(RoutingPolicy.default.maxOutputTokens[task] != nil, "no budget for \(task)")
        }
    }

    @Test("configuration survives a JSON round trip")
    func codableRoundTrip() throws {
        let original = AgentConfiguration()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: data)

        #expect(decoded.routing.routes[.answer] == original.routing.routes[.answer])
        #expect(decoded.excludedBundleIDs == original.excludedBundleIDs)
        #expect(decoded.retentionDays == original.retentionDays)
    }
}

@Suite("Capture defaults")
struct CaptureDefaultTests {
    @Test("nothing listens until asked")
    func listeningIsOptIn() {
        // The default the microphone indicator depends on. An always-open
        // device is a continuous cost — a recording indicator, a device other
        // apps cannot claim, a transcript of every room — paid for a capability
        // that is wanted occasionally, so it is opt-in.
        #expect(!AgentConfiguration().alwaysListening)
    }

    @Test("a config file missing newer keys keeps the rest of the file")
    func partialConfigDecodes() throws {
        // The failure this guards: the synthesised initialiser needs every key,
        // so one added field used to make an existing config.json throw — and
        // every call site turns a throw into a silent revert to defaults,
        // discarding the whole file to recover one setting.
        let json = """
            {"retentionDays": 7, "typingPauseSeconds": 4.0}
            """
        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self, from: Data(json.utf8))

        #expect(decoded.retentionDays == 7)
        #expect(decoded.typingPauseSeconds == 4.0)
        #expect(decoded.alwaysListening == false)
        #expect(decoded.transcriptionEngine == .gemini)
        #expect(decoded.excludedBundleIDs == AgentConfiguration.defaultExcludedBundleIDs)
        #expect(decoded.routing.routes[.triage]?.provider == "apple")
    }

    @Test("an explicit value still wins over the default")
    func explicitValueDecodes() throws {
        let json = #"{"alwaysListening": true, "transcriptionEngine": "apple"}"#
        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self, from: Data(json.utf8))
        #expect(decoded.alwaysListening)
        #expect(decoded.transcriptionEngine == .apple)
    }
}

@Suite("MCP tool approval setting")
struct MCPDangerousToolsSettingTests {
    @Test("is off by default")
    func offByDefault() {
        #expect(AgentConfiguration().mcpAllowDangerousTools == false)
    }

    @Test("a config.json written before the setting existed still loads, with it off")
    func oldConfigLoads() throws {
        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self, from: Data(#"{"retentionDays": 7}"#.utf8))
        #expect(decoded.retentionDays == 7)
        #expect(decoded.mcpAllowDangerousTools == false)
    }

    @Test("can be switched on explicitly")
    func optIn() throws {
        let decoded = try JSONDecoder().decode(
            AgentConfiguration.self, from: Data(#"{"mcpAllowDangerousTools": true}"#.utf8))
        #expect(decoded.mcpAllowDangerousTools)
    }
}
