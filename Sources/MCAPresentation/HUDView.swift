import MCACore
import SwiftUI

/// Where a `HUDView` is being rendered.
///
/// The two surfaces need different chrome, and hard-coding the panel's would
/// put dead controls in the popover: collapsing to a pill and hiding the window
/// are both meaningless for a popover that closes when you click away, and the
/// popover already draws its own background.
public enum HUDChrome: Sendable {
    /// The window on the desktop.
    case panel
    /// The menu bar popover.
    case popover
}

/// The panel's contents.
///
/// Designed to be legible over arbitrary desktop backgrounds — hence the
/// material backing rather than a flat colour — and to stay quiet: no
/// animations that pull the eye, nothing that moves unless the agent has
/// something to say.
public struct HUDView: View {
    @Bindable var state: HUDState
    var chrome: HUDChrome
    var onSubmit: ((String) -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    /// A press on one of the voice buttons. Starts that mode, or ends it if it
    /// is the one already running.
    var onVoice: ((VoiceMode) -> Void)?
    var onToggleFloating: (() -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onExplainScreen: (() -> Void)?
    var onSnipScreen: (() -> Void)?
    var onOpenChat: (() -> Void)?
    /// Opens the grid of windows and displays the agent could be pointed at.
    var onChooseScreen: (() -> Void)?
    /// Pins the window in front or unpins the current pinned window.
    var onTogglePin: (() -> Void)?
    /// Starts or stops continuous screen observation and proactive advice.
    var onToggleWatch: (() -> Void)?
    var onClearChat: (() -> Void)?
    var onOpenSettingsTab: ((SettingsTab) -> Void)?
    var onToggleClickThrough: (() -> Void)?

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    /// Which bubble the pointer is over, for its delete button.
    @State private var hovered: UUID?
    /// Whether the "start a new conversation" confirmation strip is shown.
    @State private var showNewConversationConfirm = false

    /// Anchor the thread scrolls to. A constant id rather than the last
    /// message's, so the view still follows a streaming answer — which is one
    /// growing string, not a new element.
    private let bottomAnchor = "hud.bottom"

    public init(
        state: HUDState,
        chrome: HUDChrome = .panel,
        onSubmit: ((String) -> Void)? = nil,
        onToggleCollapsed: (() -> Void)? = nil,
        onHide: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onQuit: (() -> Void)? = nil,
        onVoice: ((VoiceMode) -> Void)? = nil,
        onToggleFloating: (() -> Void)? = nil,
        onToggleVisibility: (() -> Void)? = nil,
        onExplainScreen: (() -> Void)? = nil,
        onSnipScreen: (() -> Void)? = nil,
        onOpenChat: (() -> Void)? = nil,
        onChooseScreen: (() -> Void)? = nil,
        onTogglePin: (() -> Void)? = nil,
        onToggleWatch: (() -> Void)? = nil,
        onClearChat: (() -> Void)? = nil,
        onOpenSettingsTab: ((SettingsTab) -> Void)? = nil,
        onToggleClickThrough: (() -> Void)? = nil
    ) {
        self.state = state
        self.chrome = chrome
        self.onSubmit = onSubmit
        self.onToggleCollapsed = onToggleCollapsed
        self.onHide = onHide
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onVoice = onVoice
        self.onToggleFloating = onToggleFloating
        self.onToggleVisibility = onToggleVisibility
        self.onExplainScreen = onExplainScreen
        self.onSnipScreen = onSnipScreen
        self.onOpenChat = onOpenChat
        self.onChooseScreen = onChooseScreen
        self.onTogglePin = onTogglePin
        self.onToggleWatch = onToggleWatch
        self.onClearChat = onClearChat
        self.onOpenSettingsTab = onOpenSettingsTab
        self.onToggleClickThrough = onToggleClickThrough
    }

    /// Collapsing is a window operation. In a popover there is no window to
    /// shrink, so the pill would be a control that appears to do nothing.
    private var isCollapsed: Bool { chrome == .panel && state.isCollapsed }

    public var body: some View {
        Group {
            if isCollapsed {
                collapsed
            } else {
                expanded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if chrome == .panel {
                ZStack {
                    RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                    RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: isCollapsed ? 11 : 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
            }
        }
        .onChange(of: state.messages.isEmpty) {
            if state.messages.isEmpty { showNewConversationConfirm = false }
        }
    }

    // MARK: - Sections

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if showNewConversationConfirm {
                confirmStrip
            }

            if chrome == .panel && state.isClickThrough {
                clickThroughBanner
            }

            if chrome == .popover && state.isClickThrough {
                popoverClickThroughBanner
            }

            // The menu bar and the hot keys already expose these, but both are
            // a click away — this row is the thing the user presses without
            // aiming.
            if chrome == .popover || !state.isClickThrough {
                quickActions
                voiceStatus
            }

            if !state.problems.isEmpty {
                problemBanner
            }

            thread

            // Hidden only where it would not work: with click-through on, the
            // window takes no mouse events at all, so the field could not be
            // focused by clicking it.
            if chrome == .popover || !state.isClickThrough {
                inputField
            }

            // The app runs `.accessory`: no Dock icon, no app menu. The
            // right-click menu has Quit, but the popover is what a left click
            // opens — without its own Quit it looks like the app cannot be
            // stopped from here.
            if chrome == .popover {
                popoverFooter
            }
        }
        .padding(14)
    }

    /// Prompts to start fresh with a new conversation.
    private var confirmStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            Text(localized(
                "Start a new conversation?",
                "新しい会話しますか？",
                "새 대화를 시작할까요?"))
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                showNewConversationConfirm = false
            } label: {
                Text(localized("No", "いいえ", "아니요"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                showNewConversationConfirm = false
                if let onClearChat {
                    onClearChat()
                } else {
                    state.clearChat()
                }
            } label: {
                Text(localized("Yes", "はい", "예"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The collapsed pill: enough to show the agent is alive and to get the
    /// panel back, and nothing else.
    private var collapsed: some View {
        HStack(spacing: 7) {
            statusDot

            Text("Copilot")
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            if state.liveSessionActive || state.isListening {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                    .foregroundStyle(state.liveSessionActive ? .cyan : .secondary)
            }

            if state.isClickThrough {
                Image(systemName: "cursorarrow.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(localized(
                        "Click-through active (⌥⌘X)",
                        "クリック透過中 (⌥⌘X)",
                        "클릭 통과 중 (⌥⌘X)"))
            }

            Spacer(minLength: 4)

            chromeButton(
                "chevron.down",
                help: localized("Expand", "元の大きさに戻す", "원래 크기로"),
                action: onToggleCollapsed)
            chromeButton(
                "xmark",
                help: localized("Close the panel (⌥⌘H)", "パネルを閉じる (⌥⌘H)", "패널 닫기 (⌥⌘H)"),
                action: onHide)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private var statusDot: some View {
        Circle()
            .fill(state.problems.isEmpty ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
            .help(state.problems.isEmpty
                ? localized("All systems normal", "正常に動作中", "정상 작동 중")
                : state.problems.map { "\($0.0.displayName): \($0.1.localizedDisplayText)" }.joined(separator: "\n"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot

            Text("Copilot")
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            if state.liveSessionActive {
                Label(localized("Voice", "会話中", "대화 중"), systemImage: "waveform")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan)
            } else if state.isListening {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            targetSelector

            let canClear = !state.messages.isEmpty || state.isStreaming
            chromeButton(
                "trash",
                help: localized("Start a new conversation", "新しい会話", "새 대화"),
                name: localized("Start a new conversation", "新しい会話", "새 대화"),
                tint: showNewConversationConfirm ? Color.orange : nil,
                action: {
                    guard canClear else { return }
                    showNewConversationConfirm.toggle()
                })
                .disabled(!canClear)
                .opacity(canClear ? 1.0 : 0.35)

            // An icon rather than the words it used to be along the bottom.
            // This is a window control — the same kind of thing as the pin and
            // the close box on the panel — and spelling it out put a sentence
            // where every other surface has a glyph. Tinted rather than swapped
            // for a second symbol, so the two states are one shape with the
            // panel either on the desktop or not.
            if chrome == .popover {
                chromeButton(
                    "macwindow",
                    help: state.isAlwaysVisible
                        ? localized(
                            "Take the panel off the desktop (⌥⌘H)",
                            "パネルをデスクトップから片づけます (⌥⌘H)",
                            "패널을 데스크탑에서 치웁니다 (⌥⌘H)")
                        : localized(
                            """
                            Put the panel on the desktop, where it stays until you close it (⌥⌘H)
                            """,
                            """
                            パネルをデスクトップに出し、閉じるまで表示したままにします (⌥⌘H)
                            """,
                            """
                            패널을 데스크탑에 놓고, 닫을 때까지 그대로 표시합니다 (⌥⌘H)
                            """),
                    name: state.isAlwaysVisible
                        ? localized("Hide panel", "パネルを隠す", "패널 가리기")
                        : localized("Show panel", "パネルを出す", "패널 표시"),
                    tint: state.isAlwaysVisible ? Color.accentColor : nil,
                    action: onToggleVisibility)
            }

            if chrome == .panel {
                // Only shown when it is on: click-through is now the exception,
                // and a permanent icon for the normal state is noise.
                if state.isClickThrough {
                    Image(systemName: "cursorarrow.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(localized(
                            "Clicks are passing through to the app behind (⌥⌘X)",
                            "クリックが素通り中 — 押しても背面のアプリに届きます (⌥⌘X)",
                            "클릭이 통과 중 — 눌러도 뒤쪽 앱으로 전달됩니다 (⌥⌘X)"))
                }

                // "Keep in front" as an icon rather than a labelled button.
                // Uses layered windows icon to distinguish from window pinning.
                chromeButton(
                    state.isFloating ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                    help: localized(
                        """
                        Keep the panel in front of other windows. Off, it behaves like an \
                        ordinary window and whatever you are working in covers it.
                        """,
                        """
                        パネルを他のウインドウより前に出したままにします。\
                        オフにすると普通のウインドウと同じで、作業中のウインドウの後ろに隠れます。
                        """,
                        """
                        패널을 다른 윈도우보다 앞에 두고 유지합니다. 끄면 일반 윈도우와 같아져서 \
                        작업 중인 윈도우 뒤로 가려집니다.
                        """),
                    name: localized("Keep panel in front", "パネルを最前面に保つ", "패널을 맨 앞에 유지"),
                    tint: state.isFloating ? Color.accentColor : nil,
                    action: onToggleFloating)

                // Both live behind click-through, so they are a convenience
                // rather than the way out: the menu bar item and the hot keys
                // work whether or not the panel accepts a click.
                chromeButton(
                    "minus",
                    help: localized("Collapse to a bar", "細いバーにたたむ", "얇은 바로 접기"),
                    action: onToggleCollapsed)
                chromeButton(
                    "xmark",
                    help: localized("Close the panel (⌥⌘H)", "パネルを閉じる (⌥⌘H)",
                        "패널 닫기 (⌥⌘H)"),
                    action: onHide)
            }
        }
    }

    /// The target being watched, with a button to pick another and a pin to hold it.
    private var targetSelector: some View {
        HStack(spacing: 4) {
            Button {
                onChooseScreen?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.watchTarget.isPinned ? Color.accentColor : Color.secondary)
                    Text(targetDisplayName)
                        .font(.system(size: 10, weight: state.watchTarget.isPinned ? .medium : .regular))
                        .foregroundStyle(state.watchTarget.isPinned ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(screenPickerHelp)

            chromeButton(
                state.watchTarget.isPinned ? "pin.fill" : "pin",
                help: pinButtonHelp,
                name: localized("Pin window", "ウインドウ固定", "윈도우 고정"),
                tint: state.watchTarget.isPinned ? Color.accentColor : nil,
                action: onTogglePin)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(state.watchTarget.isPinned ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    state.watchTarget.isPinned ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.08),
                    lineWidth: 0.5)
        )
    }

    private var pinButtonHelp: String {
        guard let subject = state.watchTarget.subjectName else {
            return localized(
                """
                Pin the window in front to keep watching it (⌥⌘W)
                """,
                """
                前面のウインドウを見守り固定します (⌥⌘W)
                """,
                """
                앞쪽 윈도우를 고정하여 계속 지켜봅니다 (⌥⌘W)
                """)
        }
        return localized(
            "Watching \(subject). Click to unpin (⌥⌘W)",
            "\(subject) を固定中。クリックで固定を解除します (⌥⌘W)",
            "\(subject) 고정 중. 클릭하여 고정 해제 (⌥⌘W)")
    }

    private var targetDisplayName: String {
        if let subject = state.watchTarget.subjectName, !subject.isEmpty {
            return subject
        }
        if !state.focusedApp.isEmpty && state.focusedApp != "—" {
            return state.focusedApp
        }
        return localized("Screen", "画面", "화면")
    }

    // MARK: - Quick actions

    /// One-tap buttons for the things that would otherwise need a menu or a
    /// remembered chord.
    ///
    /// All four are conversations rather than window management. The window
    /// controls that used to sit here — put the panel on the desktop, keep it in
    /// front — moved to the header pin and the popover footer: they are settings
    /// someone changes once, and they were taking the row's width from the
    /// buttons that get pressed all day.
    ///
    /// The two voice buttons are icons without labels, which is what buys the
    /// room for a fourth control in a 380-point popover. A bare microphone is
    /// the one glyph in this row that needs no word next to it, and the pair
    /// replaces what used to be one button plus a mode menu underneath it.
    private var quickActions: some View {
        HStack(spacing: 6) {
            voiceButton(.dictation)
            voiceButton(.realtime)

            // The one that opens a real conversation, in a window you can type
            // into properly, rather than the single line at the bottom of a
            // popover that closes the moment you click away.
            quickButton(
                symbol: "bubble.left.and.text.bubble.right.fill",
                title: localized("Chat", "チャット", "채팅"),
                active: state.isChatOpen,
                help: localized(
                    """
                    Open the chat window. Everything the agent says lands there, \
                    including what it notices on its own (⌥Space)
                    """,
                    """
                    チャットウインドウを開きます。エージェントの発言は、\
                    自分で気づいたことも含めてすべてここに届きます (⌥Space)
                    """,
                    """
                    채팅 윈도우를 엽니다. 에이전트가 하는 말은 스스로 알아챈 것까지 \
                    모두 그곳으로 옵니다 (⌥Space)
                    """),
                action: onOpenChat)

            // One-shot: inspect screen right now
            quickButton(
                symbol: "sparkles",
                title: localized("Explain", "画面を説明", "화面 설명"),
                active: false,
                help: localized(
                    "Look at the screen right now and explain it, in the chat (one-shot)",
                    "いま画面に映っているものを見て、チャットで1回説明します",
                    "지금 화면에 보이는 것을 살펴보고 채팅으로 1회 설명합니다"),
                action: onExplainScreen)
                .disabled(state.isStreaming)

            // One-shot: drag to select region and explain
            quickButton(
                symbol: "crop",
                title: localized("Snip", "範囲指定", "영역 선택"),
                active: false,
                help: localized(
                    "Drag to select a part of your screen and explain it",
                    "画面の一部をドラッグして選択し、説明させます",
                    "화면 일부를 드래그하여 선택하고 설명합니다"),
                action: onSnipScreen)
                .disabled(state.isStreaming)

            // Continuous: start/stop background observation and proactive advice
            quickButton(
                symbol: state.watchPhase == .off ? "eye.slash" : "eye.fill",
                title: watchButtonTitle,
                active: state.watchPhase != .off,
                help: localized(
                    "Keep watching the screen and give proactive advice (continuous)",
                    "画面を見守り続け、気づいたことを継続して助言します",
                    "화면을 계속 지켜보고 조언을 지속 제공합니다"),
                action: onToggleWatch)
        }
    }

    private var watchButtonTitle: String {
        switch state.watchPhase {
        case .off: return localized("Watch", "見守り", "지켜보기")
        case .watching: return localized("Watching", "見守り中", "보는 중")
        case .looking: return localized("Looking…", "確認中…", "확인 중…")
        }
    }

    private var screenPickerHelp: String {
        guard let subject = state.watchTarget.subjectName else {
            return localized(
                """
                Pick the window or the display the agent looks at, from previews \
                of each. Now: whatever window is in front.
                """,
                """
                エージェントに見せるウインドウやディスプレイを、プレビューを見ながら選びます。\
                いまは前面のウインドウを追いかけています。
                """,
                """
                에이전트에게 보여줄 윈도우나 디스플레이를 미리보기를 보며 고릅니다. \
                지금은 앞쪽 윈도우를 따라가고 있습니다.
                """)
        }
        return localized(
            "Now watching \(subject). Click to choose something else.",
            "いま見張っているのは \(subject) です。クリックで選び直せます。",
            "지금 지켜보는 대상: \(subject). 누르면 다시 고를 수 있습니다.")
    }

    /// One mode's button: starts it, or ends it when it is the one running.
    ///
    /// Silent while the other mode is live rather than disabled. Pressing it
    /// then means "switch to this instead", which is what someone who reaches
    /// for the other button mid-session is asking for; a greyed-out control
    /// would make them stop, end the session and start again.
    ///
    /// The label appears only once something is happening. Off, the icon carries
    /// it; running, the word is the exit — and "終了" next to a lit microphone is
    /// the one thing that has to be readable without hovering.
    private func voiceButton(_ mode: VoiceMode) -> some View {
        let isCurrent = state.voiceMode == mode && state.voicePhase != .off
        return quickButton(
            symbol: isCurrent ? mode.activeSymbol : mode.symbol,
            title: isCurrent ? voicePhaseTitle : mode.shortTitle,
            name: mode.title,
            active: isCurrent,
            tint: mode == .realtime ? .cyan : nil,
            help: mode.title + "\n\n" + mode.buttonHelp,
            action: { onVoice?(mode) })
    }

    private var voicePhaseTitle: String {
        switch state.voicePhase {
        case .off: return ""
        case .connecting: return localized("Connecting…", "接続中…", "연결 중…")
        case .live: return localized("End", "終了", "종료")
        }
    }

    /// What the live session is hearing.
    ///
    /// Shown while a session is up because "connected but deaf" and "working"
    /// look identical from here otherwise, and the user's own words coming back
    /// are the only local evidence the microphone is reaching the model.
    @ViewBuilder private var voiceStatus: some View {
        if state.voicePhase != .off {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .padding(.top, 1)
                    Text(voiceStatusText)
                        .font(.system(size: 10))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)

                // What the model looked up, when it looked something up. A
                // spoken answer otherwise gives no account of where it came
                // from, and "I read this somewhere" and "I checked just now"
                // are not the same claim.
                if !state.voiceSearchQueries.isEmpty {
                    Label(
                        state.voiceSearchQueries.joined(separator: " · "),
                        systemImage: "globe")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.mint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var voiceStatusText: String {
        if !state.voiceTranscript.isEmpty { return state.voiceTranscript }
        if state.voicePhase == .connecting {
            return localized("Connecting…", "接続しています…", "연결 중…")
        }
        return switch state.voiceMode {
        case .realtime:
            localized("Listening — go ahead.", "聞いています。話しかけてください。",
                "듣고 있습니다. 말씀하세요.")
        case .dictation:
            localized(
                "Listening — pause when you're done and it goes to the chat.",
                "聞いています。話し終えるとチャットに送られます。",
                "듣고 있습니다. 말을 마치면 채팅으로 전송됩니다.")
        }
    }

    /// A labelled button, or an unlabelled one when `title` is empty. `name` is
    /// what it is called either way: an icon with no text beside it is silence
    /// to VoiceOver unless something spells the name out.
    private func quickButton(
        symbol: String,
        title: String?,
        name: String? = nil,
        active: Bool,
        tint: Color? = nil,
        help: String,
        action: (() -> Void)?
    ) -> some View {
        Button { action?() } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint != nil && active ? tint! : (active ? Color.accentColor : Color.secondary))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint != nil && active ? tint! : (active ? Color.primary : Color.secondary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? (tint ?? Color.accentColor).opacity(0.22) : Color.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(name ?? title ?? "")
    }

    private func chromeButton(
        _ symbol: String,
        help: String,
        name: String? = nil,
        tint: Color? = nil,
        action: (() -> Void)?
    ) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(name ?? help)
    }

    /// Failures are shown, never swallowed. A subsystem that is down is more
    /// important than anything the agent has to say.
    private var clickThroughBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(localized(
                "Click-through active (⌥⌘X to unlock)",
                "クリック透過中 (⌥⌘X で解除)",
                "클릭 통과 중 (⌥⌘X 로 해제)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.15))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                }
        }
    }

    private var popoverClickThroughBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized(
                    "Click-through active on panel",
                    "パネルがクリック透過中です",
                    "패널이 클릭 통과 상태입니다"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(localized(
                    "Mouse clicks pass through to apps behind (⌥⌘X)",
                    "クリックは背面のアプリに届きます (⌥⌘X)",
                    "클릭이 뒤쪽 앱으로 전달됩니다 (⌥⌘X)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onToggleClickThrough?()
            } label: {
                Text(localized("Unlock", "解除", "해제"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                }
        }
    }

    /// Failures are shown, never swallowed. A subsystem that is down is more
    /// important than anything the agent has to say.
    private var problemBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.problems, id: \.0) { id, componentState in
                Button {
                    onOpenSettingsTab?(id.settingsTab)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("\(id.displayName): \(componentState.localizedDisplayText)")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 9))
                            .opacity(0.8)
                    }
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized(
                    "Click to open settings for \(id.displayName)",
                    "クリックして\(id.displayName)の設定を開く",
                    "클릭하여 \(id.displayName) 설정 열기"))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Thread

    /// The conversation, in the same bubbles the chat window draws.
    ///
    /// It used to be a ring of six cards over a separate list, which is how this
    /// surface and the chat window ended up telling two different stories about
    /// one session — the panel showing a card the chat did not have, the chat
    /// holding a question the panel had already pushed out.
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.messages.isEmpty && !state.isStreaming {
                        emptyState
                    }
                    ForEach(state.messages) { message in
                        row(message)
                    }
                    if state.isStreaming {
                        ThinkingBubble(state.streamingText, textSize: 12)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            // Both triggers are needed: a new message and a growing answer are
            // different changes, and following only the first leaves a long
            // streamed reply running off the bottom.
            // When messages change, animate smoothly. During streaming, scroll
            // immediately without animation to prevent NSScrollView layout
            // recursion loops (_NSDetectedLayoutRecursion) from overlapping animations.
            .onChange(of: state.messages.count) { scrollToBottom(proxy, animated: true) }
            .onChange(of: state.streamingText) { scrollToBottom(proxy, animated: false) }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    /// One turn, and the way to be done with it.
    ///
    /// The ✕ appears under the pointer rather than sitting on every bubble. This
    /// is a panel someone glances at over their work, and a permanent close
    /// button on every turn turns a quiet corner of the screen into a column of
    /// controls — the opposite of the point. The chat window, which is read
    /// rather than glanced at, keeps its always-visible one.
    private func row(_ message: ChatMessage) -> some View {
        MessageBubble(message, textSize: 12, onApproval: { id, approved in
            state.resolveApproval(id, status: approved ? .approved : .rejected)
        })
            .overlay(alignment: .topTrailing) {
                deleteButton(message)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hovered = message.id
                } else if hovered == message.id {
                    hovered = nil
                }
            }
            .contextMenu {
                // The menu way to the same act. With click-through on, the panel
                // takes no mouse events at all and the ✕ cannot be reached — but the
                // popover's copy of this turn still can.
                Button(localized("Delete this message", "このメッセージを消す", "이 메시지 지우기")) {
                    state.removeMessage(message.id)
                }
            }
    }

    private func deleteButton(_ message: ChatMessage) -> some View {
        Button { state.removeMessage(message.id) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white.opacity(0.9), Color.secondary.opacity(0.8))
                // Padding is hit area, not spacing: an 11-point target on a
                // floating panel is a miss waiting to happen.
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(3)
        .opacity(hovered == message.id ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(localized("Delete this message", "このメッセージを消す", "이 메시지 지우기"))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized(
                "Nothing to show yet.", "まだ表示するものはありません。",
                "아직 표시할 것이 없습니다."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(state.shortcutHint.isEmpty
                 ? localized(
                    "Everything is under the ✨ menu bar item.",
                    "操作はメニューバーの ✨ からできます。",
                    "모든 조작은 메뉴 막대의 ✨ 에서 할 수 있습니다.")
                 : state.shortcutHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var inputField: some View {
        HStack(spacing: 6) {
            TextField(
                localized(
                    "Ask about what you're seeing…", "画面について質問…",
                    "화면에 대해 질문…"),
                text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($inputFocused)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || state.isStreaming)
            .help(localized("Send message (Return)", "送信 (Return)", "전송 (Return)"))
            .accessibilityLabel(localized("Send message", "送信", "전송"))
        }
        .padding(9)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
        .onAppear { inputFocused = true }
    }

    /// The panel toggle is not here any more — it is the `macwindow` icon in the
    /// header, next to the window controls it belongs with. What is left is the
    /// two things that are not about this window at all.
    private var popoverFooter: some View {
        HStack(spacing: 12) {
            Button(localized("Settings…", "設定…", "설정…")) { onOpenSettings?() }
                .help(localized("Open Settings", "設定を開く", "설정 열기"))
            Spacer(minLength: 8)
            Button(localized("New conversation", "新しい会話", "새 대화")) {
                showNewConversationConfirm = true
            }
            .disabled(state.messages.isEmpty && !state.isStreaming)
            .help(localized("Start a new conversation", "新しい会話を始める", "새 대화 시작"))
            Spacer(minLength: 8)
            Button(localized("Quit Copilot", "Copilot を終了", "Copilot 종료")) { onQuit?() }
                .help(localized("Quit Copilot", "Copilot を終了", "Copilot 종료"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func submit() {
        guard !state.isStreaming else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        showNewConversationConfirm = false
        draft = ""
        onSubmit?(question)
    }
}
