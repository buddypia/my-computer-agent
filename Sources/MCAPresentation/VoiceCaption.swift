import AppKit
import MCACore
import OSLog
import SwiftUI

/// How big the spoken-word caption is drawn, for a given screen.
///
/// Derived from the display rather than fixed, because the caption exists to be
/// read from wherever the user is sitting and a point size that works on a 13"
/// laptop is a whisper on a 32" display two feet further away. The clamps are
/// what stop the proportion from becoming absurd at either end: an external 6K
/// panel would otherwise get 140-point text, and a small window-managed display
/// would get something illegible.
public struct VoiceCaptionMetrics: Sendable, Equatable {
    /// Point size of the transcript itself.
    public var fontSize: Double
    /// Window width. The caption is a band across the screen, not a box in a
    /// corner — it is read at a glance, not aimed at.
    public var width: Double
    /// Window height. The band is bottom-aligned inside it, so a one-word
    /// utterance and a long sentence both grow upward from the same baseline
    /// instead of the window jumping around as the user speaks.
    public var height: Double
    /// Gap between the caption and the bottom of the usable screen.
    public var bottomInset: Double

    /// How many lines of transcript are drawn before the rest is dropped.
    ///
    /// Three, at every size: the caption is for confirming that what you said
    /// was heard correctly, and by the fourth line it has become a transcript
    /// window sitting on top of the user's work.
    public static let lineLimit = 3

    public init(fontSize: Double, width: Double, height: Double, bottomInset: Double) {
        self.fontSize = fontSize
        self.width = width
        self.height = height
        self.bottomInset = bottomInset
    }

    /// Metrics for a screen of this size, in points.
    public static func forScreen(width: Double, height: Double) -> VoiceCaptionMetrics {
        let safeWidth = max(width, 320)
        let safeHeight = max(height, 240)

        return VoiceCaptionMetrics(
            fontSize: clamp(safeHeight * 0.042, minimum: 22, maximum: 76),
            width: clamp(safeWidth * 0.72, minimum: 300, maximum: 1500),
            height: clamp(safeHeight * 0.30, minimum: 140, maximum: 420),
            bottomInset: clamp(safeHeight * 0.07, minimum: 28, maximum: 160))
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

/// The caption itself: what the microphone is hearing, in the largest type the
/// screen justifies.
struct VoiceCaptionView: View {
    @Bindable var state: HUDState
    var metrics: VoiceCaptionMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: metrics.fontSize * 0.28) {
                header

                transcript
                    .font(.system(
                        size: metrics.fontSize,
                        weight: .semibold,
                        design: .rounded))
                    // Shrinks before it truncates: hearing your own words back
                    // is the whole point, and a sentence cut off at "how do I
                    // rena…" proves nothing about whether it was heard right.
                    .minimumScaleFactor(0.55)
                    .lineLimit(VoiceCaptionMetrics.lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
            .padding(.horizontal, metrics.fontSize * 0.7)
            .padding(.vertical, metrics.fontSize * 0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(
                    cornerRadius: metrics.fontSize * 0.45, style: .continuous)
                shape
                    .fill(.ultraThinMaterial)
                    // Material alone is not enough over a bright desktop or a
                    // white document, which is most of them.
                    .overlay { shape.fill(.black.opacity(0.45)) }
                    .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var header: some View {
        HStack(spacing: metrics.fontSize * 0.24) {
            Image(systemName: state.voicePhase == .connecting ? "ellipsis" : "mic.fill")
                .font(.system(size: metrics.fontSize * 0.4, weight: .bold))
                .foregroundStyle(state.voicePhase == .live ? .cyan : .secondary)

            Text(state.voiceMode.shortTitle)
                .font(.system(size: metrics.fontSize * 0.36, weight: .semibold))
                .foregroundStyle(.secondary)

            // Which language the words are being recognised as. On the caption
            // rather than only in Settings because this is where the evidence
            // of a wrong choice shows up: transcripts that come out as
            // plausible nonsense look exactly like a bad microphone until you
            // can see the recogniser was listening for the wrong language.
            if state.voiceMode == .dictation {
                Text(Localization.shared.speechLocaleDescription)
                    .font(.system(size: metrics.fontSize * 0.32, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if !state.voiceSearchQueries.isEmpty {
                Label(
                    state.voiceSearchQueries.joined(separator: " · "),
                    systemImage: "globe")
                    .font(.system(size: metrics.fontSize * 0.34, weight: .medium))
                    .foregroundStyle(.mint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text(hint)
                .font(.system(size: metrics.fontSize * 0.32))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// The words themselves: settled text at full strength, the engine's
    /// current guess behind it at half.
    ///
    /// One `Text` rather than two views so the sentence wraps as a sentence —
    /// laid out side by side, the guess would start on its own line and the
    /// caption would jump every time the engine settled a clause.
    private var transcript: Text {
        guard !state.voiceTranscript.isEmpty else {
            return Text(placeholder).foregroundStyle(.secondary)
        }
        return Text("\(Text(state.voiceTranscriptSettled).foregroundStyle(.primary))\(Text(state.voiceTranscriptPending).foregroundStyle(.secondary))")
    }

    /// What to draw when nothing has been heard yet.
    ///
    /// Different per mode because the two are waiting for different things: the
    /// live session is already connected and listening, while dictation has
    /// nothing to send until the user stops talking.
    private var placeholder: String {
        if state.voicePhase == .connecting {
            return localized("Connecting…", "接続しています…", "연결 중…")
        }
        return switch state.voiceMode {
        case .realtime:
            localized("Listening — go ahead.", "聞いています。話しかけてください。",
                "듣고 있습니다. 말씀하세요.")
        case .dictation:
            localized("Listening — speak your question.", "聞いています。質問を話してください。",
                "듣고 있습니다. 질문을 말씀하세요.")
        }
    }

    private var hint: String {
        switch state.voiceMode {
        case .realtime:
            return localized("⌃⌥V to end", "⌃⌥V で終了", "⌃⌥V로 종료")
        case .dictation:
            return state.isStreaming
                ? localized("Answering — keep talking", "回答中 — 話し続けて構いません",
                    "답변 중 — 계속 말씀하셔도 됩니다")
                : localized("Pause to send", "話し終えると送信", "말을 마치면 전송")
        }
    }
}

/// The window the caption lives in.
///
/// A separate window rather than a bigger font inside the HUD, because the two
/// have opposite jobs. The panel is a place to read what the agent said, put
/// somewhere it does not cover anything; the caption is a live readout of what
/// the microphone is hearing, and it is only useful if it is impossible to miss
/// — which means the middle-bottom of whichever screen is being worked on, in
/// type sized for the room.
///
/// It takes no clicks (`ignoresMouseEvents`), never appears in a capture
/// (`sharingType = .none`, so the agent's own OCR path cannot read the user's
/// words back to it), and exists only while a voice session does.
@MainActor
public final class VoiceCaptionPanel: NSObject {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "Caption")
    private let state: HUDState
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    public init(state: HUDState) {
        self.state = state
        super.init()
    }

    /// Begins mirroring the voice session. Nothing is built until a session
    /// actually starts.
    public func start() {
        track()
        // A display being plugged in, unplugged or rearranged moves the screen
        // the caption was placed against. Without this it stays at coordinates
        // that may no longer be on any screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    public func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Internals

    /// Shows and hides the caption in step with the session, so no call site has
    /// to remember to do it. `onChange` fires before the mutation lands, hence
    /// the hop.
    private func track() {
        withObservationTracking {
            _ = state.voicePhase
            _ = state.showsVoiceCaption
            _ = state.isChatOpen
        } onChange: { [weak self] in
            // `track` re-arms and then applies, so the mutation is read after
            // it has landed rather than before.
            Task { @MainActor in self?.track() }
        }
        apply()
    }

    private func apply() {
        // When the chat window is open, voice transcripts are already rendered
        // in ChatView's composer banner (`voiceHeard`). Displaying the floating
        // caption panel concurrently would duplicate the input on screen.
        let wanted = state.showsVoiceCaption && state.voicePhase != .off && !state.isChatOpen
        if wanted {
            let panel = makePanelIfNeeded()
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Above the ordinary floating level: this is a readout of what is being
        // said right now, and the one window it must not end up behind is the
        // agent's own chat window, which floats.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Never captured, for the same reason as the panel: the screen watch
        // photographs the front window, and reading the user's own spoken words
        // back in as "what is on screen" is a feedback loop.
        panel.sharingType = .none

        let hosting = NSHostingView(rootView: makeView(metrics: metrics(for: targetScreen())))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        log.debug("Caption panel created")
        return panel
    }

    private func makeView(metrics: VoiceCaptionMetrics) -> VoiceCaptionView {
        VoiceCaptionView(state: state, metrics: metrics)
    }

    /// Places the caption across the bottom of the screen being worked on, at
    /// the size that screen justifies.
    private func reposition() {
        guard let panel, let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        let metrics = metrics(for: screen)

        panel.setFrame(
            NSRect(
                x: visible.midX - metrics.width / 2,
                y: visible.minY + metrics.bottomInset,
                width: metrics.width,
                height: metrics.height),
            display: true,
            animate: false)

        // The metrics are a value the view was built with, so a screen change
        // has to hand it the new ones.
        (panel.contentView as? NSHostingView<VoiceCaptionView>)?.rootView =
            makeView(metrics: metrics)
    }

    private func metrics(for screen: NSScreen?) -> VoiceCaptionMetrics {
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return VoiceCaptionMetrics.forScreen(
            width: Double(frame.width), height: Double(frame.height))
    }

    /// The display the pointer is on — the one being worked on. `NSScreen.main`
    /// is whichever has the menu bar, which on a two-monitor Mac is routinely
    /// not the same thing, and a caption on the other display is a caption that
    /// did not appear.
    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }
}
