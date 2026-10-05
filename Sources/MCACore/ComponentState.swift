import Foundation

/// The health of one subsystem.
///
/// This type exists because of a specific failure in the previous
/// implementation: the voice pipeline threw at startup, was swallowed by a
/// blanket `except`, fell into a do-nothing sleep loop, and kept reporting
/// `"active"` to the UI. There is deliberately no way to spell "fine" without
/// the subsystem actually running, and no way to spell "broken" without
/// carrying the reason.
public enum ComponentState: Sendable, Equatable {
    /// Coming up. Distinct from `.disabled` because "still starting" and
    /// "switched off" look identical to the user but mean opposite things —
    /// one will resolve on its own, the other never will.
    case starting
    /// Doing its job.
    case running
    /// Alive but not delivering full function. `reason` is shown to the user.
    case degraded(reason: String)
    /// Not running. `message` is shown to the user.
    case failed(message: String)
    /// Deliberately switched off by configuration.
    case disabled

    public var isHealthy: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether this is worth putting in front of the user. A component still
    /// coming up is not a problem yet.
    public var isProblem: Bool {
        switch self {
        case .degraded, .failed: return true
        case .running, .disabled, .starting: return false
        }
    }

    /// Short label for the CLI, which is English-only.
    public var displayText: String {
        switch self {
        case .starting: return "starting…"
        case .running: return "OK"
        case .degraded(let reason): return "DEGRADED: \(reason)"
        case .failed(let message): return "FAILED: \(message)"
        case .disabled: return "OFF"
        }
    }

    /// The same label for the GUI, in the user's language.
    ///
    /// Only the state word is translated. `reason` and `message` carry text
    /// from macOS, from a provider, or from a `Error` description — translating
    /// those would mean paraphrasing an error the user may need to search for
    /// verbatim.
    @MainActor
    public var localizedDisplayText: String {
        switch self {
        case .starting: return localized("starting…", "起動中…", "시작 중…")
        case .running: return localized("OK", "正常", "정상")
        case .degraded(let reason):
            return localized("DEGRADED: ", "機能低下: ", "기능 저하: ") + reason
        case .failed(let message): return localized("FAILED: ", "停止: ", "중지: ") + message
        case .disabled: return localized("OFF", "オフ", "꺼짐")
        }
    }
}

public enum ComponentID: String, Sendable, CaseIterable, Codable {
    case screenCapture
    case accessibility
    case microphone
    case systemAudioTap
    case transcription
    case memory
    case reasoning
    case realtimeVoice
    case mcpServer

    /// What to call this subsystem in the GUI. The raw case name leaks into a
    /// health banner otherwise, and "systemAudioTap" is not a sentence anyone
    /// outside this repository can read.
    @MainActor
    public var displayName: String {
        switch self {
        case .screenCapture: return localized("Screen capture", "画面キャプチャ", "화면 캡처")
        case .accessibility: return localized("Accessibility", "アクセシビリティ", "손쉬운 사용")
        case .microphone: return localized("Microphone", "マイク", "마이크")
        case .systemAudioTap: return localized("System audio", "システム音声", "시스템 사운드")
        case .transcription: return localized("Transcription", "文字起こし", "문자 변환")
        case .memory: return localized("Memory", "メモリ", "메모리")
        case .reasoning: return localized("Reasoning", "推論", "추론")
        case .realtimeVoice: return localized("Live voice", "リアルタイム音声", "실시간 음성")
        case .mcpServer: return localized("MCP server", "MCP サーバー", "MCP 서버")
        }
    }

    /// Which tab in the Settings window can configure or remediate this subsystem.
    public var settingsTab: SettingsTab {
        switch self {
        case .screenCapture, .accessibility, .microphone, .systemAudioTap:
            return .permissions
        case .reasoning, .realtimeVoice, .transcription:
            return .models
        case .memory, .mcpServer:
            return .general
        }
    }
}

/// Aggregated health of the whole agent. Rendered verbatim in the HUD so a
/// broken subsystem is always visible rather than silently absent.
public struct HealthReport: Sendable, Equatable {
    public var states: [ComponentID: ComponentState]

    public init(states: [ComponentID: ComponentState] = [:]) {
        self.states = states
    }

    public subscript(id: ComponentID) -> ComponentState {
        get { states[id] ?? .disabled }
        set { states[id] = newValue }
    }

    /// Components the user should know about: degraded or failed only.
    public var problems: [(ComponentID, ComponentState)] {
        states
            .filter { $0.value.isProblem }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    public var allHealthy: Bool { problems.isEmpty }
}

/// Observable, actor-isolated health registry shared across subsystems.
public actor HealthRegistry {
    private var report = HealthReport()
    private var observers: [UUID: @Sendable (HealthReport) -> Void] = [:]

    public init() {}

    public func set(_ id: ComponentID, _ state: ComponentState) {
        guard report[id] != state else { return }
        report[id] = state
        let snapshot = report
        for observe in observers.values { observe(snapshot) }
    }

    public func current() -> HealthReport { report }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (HealthReport) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(report)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }
}
