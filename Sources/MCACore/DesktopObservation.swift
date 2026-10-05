import Foundation

/// Which audio path an utterance arrived on.
///
/// With dual-channel capture this *is* the primary speaker separation: the
/// microphone is the local user, the process tap is everyone else. Finer
/// diarization within `.systemAudio` is a separate concern (`SpeakerDiarizing`).
public enum AudioChannel: String, Codable, Sendable, CaseIterable {
    /// Local microphone, echo-cancelled by VoiceProcessingIO.
    case microphone
    /// System output captured via a CoreAudio process tap.
    case systemAudio
}

/// How a piece of screen text was obtained.
///
/// Accessibility text is authoritative — it is the app's own string, not a
/// guess. OCR is the fallback for canvas-drawn UI.
public enum ScreenTextSource: String, Codable, Sendable {
    case accessibility
    case ocr
}

/// A single structured observation of the user's desktop.
///
/// Observations are immutable value types so they can cross actor boundaries
/// without copying concerns.
public enum DesktopObservation: Codable, Sendable, Equatable {
    case screen(ScreenObservation)
    case audio(AudioObservation)

    public var timestamp: Date {
        switch self {
        case .screen(let s): return s.timestamp
        case .audio(let a): return a.timestamp
        }
    }
}

public struct ScreenObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    /// Bundle identifier of the frontmost app, when resolvable.
    public var bundleID: String?
    public var appName: String
    public var windowTitle: String
    public var text: String
    public var source: ScreenTextSource
    /// What caused this capture. Useful for debugging the event-driven trigger.
    public var trigger: CaptureTrigger

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bundleID: String? = nil,
        appName: String,
        windowTitle: String,
        text: String,
        source: ScreenTextSource,
        trigger: CaptureTrigger = .unknown
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.source = source
        self.trigger = trigger
    }
}

/// Why the screen was sampled.
///
/// Nothing here polls at a frame rate. Every case but `watch` is an OS event;
/// `watch` is the periodic look the user explicitly asked for by pinning a
/// subject, at the interval they chose.
public enum CaptureTrigger: String, Codable, Sendable {
    case focusChanged
    case windowTitleChanged
    case typingPaused
    case scrollSettled
    case valueChanged
    case manual
    /// A look taken by the pinned screen watch rather than by the user moving
    /// around their desktop. The subject is deliberately *not* what is in front,
    /// so an observation carrying this is the one thing in the store that
    /// describes something the user may not be able to see.
    case watch
    case unknown
}

public struct AudioObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var channel: AudioChannel
    /// Stable-within-session speaker label. `nil` when diarization is off.
    public var speakerID: String?
    public var text: String
    /// `false` while the transcriber is still revising this hypothesis.
    public var isFinal: Bool
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        channel: AudioChannel,
        speakerID: String? = nil,
        text: String,
        isFinal: Bool = true,
        duration: TimeInterval = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.channel = channel
        self.speakerID = speakerID
        self.text = text
        self.isFinal = isFinal
        self.duration = duration
    }
}
