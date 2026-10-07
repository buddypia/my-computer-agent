import AppKit
import MCACore
import SwiftUI

/// The chat window's contents.
///
/// A thread rather than the card ring the panel shows, because the two are read
/// differently: a card is glanced at and dismissed, while a conversation is
/// scrolled back through. The agent's unprompted advice lands in the same thread
/// as the answers — marked, so it is never mistaken for a reply to something the
/// user asked, but in one place, because "what has the agent told me today" is a
/// single question.
public struct ChatView: View {
    @Bindable var state: HUDState

    var onSubmit: ((String) -> Void)?
    var onToggleWatch: (() -> Void)?
    var onChooseInterval: ((ScreenWatchInterval) -> Void)?
    /// Opens the grid of windows and displays the agent could be pointed at.
    var onChooseScreen: (() -> Void)?
    var onExplainScreen: (() -> Void)?
    var onSnipScreen: (() -> Void)?
    var onExecutePreset: ((WatchRole, WatchTarget?) -> Void)?
    var onApplyRoleToWatch: ((WatchRole, WatchTarget?) -> Void)?
    /// A press on one of the voice buttons. Starts that mode, or ends it if it
    /// is the one already running.
    var onVoice: ((VoiceMode) -> Void)?
    var onClear: (() -> Void)?

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    /// Whether the "start a new conversation" confirmation strip is shown.
    @State private var showNewConversationConfirm = false
    /// Which bubble the pointer is over, for its delete button.
    @State private var hovered: UUID?

    /// Anchor the thread scrolls to. A constant id rather than the last
    /// message's, so the view still follows a streaming answer — which is one
    /// growing string, not a new element.
    private let bottomAnchor = "chat.bottom"

    public init(
        state: HUDState,
        onSubmit: ((String) -> Void)? = nil,
        onToggleWatch: (() -> Void)? = nil,
        onChooseInterval: ((ScreenWatchInterval) -> Void)? = nil,
        onChooseScreen: (() -> Void)? = nil,
        onExplainScreen: (() -> Void)? = nil,
        onSnipScreen: (() -> Void)? = nil,
        onExecutePreset: ((WatchRole, WatchTarget?) -> Void)? = nil,
        onApplyRoleToWatch: ((WatchRole, WatchTarget?) -> Void)? = nil,
        onVoice: ((VoiceMode) -> Void)? = nil,
        onClear: (() -> Void)? = nil
    ) {
        self.state = state
        self.onSubmit = onSubmit
        self.onToggleWatch = onToggleWatch
        self.onChooseInterval = onChooseInterval
        self.onChooseScreen = onChooseScreen
        self.onExplainScreen = onExplainScreen
        self.onSnipScreen = onSnipScreen
        self.onExecutePreset = onExecutePreset
        self.onApplyRoleToWatch = onApplyRoleToWatch
        self.onVoice = onVoice
        self.onClear = onClear
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            objectiveControls
            Divider()
            if showNewConversationConfirm {
                confirmStrip
                Divider()
            }
            thread
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.messages.isEmpty) {
            if state.messages.isEmpty { showNewConversationConfirm = false }
        }
    }

    private var objectiveControls: some View {
        HStack(spacing: 8) {
            TextField(localized("Screen objective", "この画面で自動的に行うこと", "화면에서 자동으로 할 작업"), text: $state.screenObjectiveText)
                .textFieldStyle(.roundedBorder)
                .disabled(state.screenObjective?.isActive == true)
            if state.screenObjective?.isActive == true {
                Button(localized("Stop objective", "目的を停止", "목표 중지")) { state.onStopObjective?() }
            } else {
                Button(localized("Start objective", "目的を開始", "목표 시작")) { state.onStartObjective?(state.screenObjectiveText) }
                    .disabled(state.screenObjectiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isStreaming)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                captureMenu
                watchButton
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                pinButton
                intervalMenu

                Spacer(minLength: 8)

                if state.isStreaming {
                    Button(localized("Stop", "停止", "중지")) {
                        state.onStopTask?()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help(localized("Stop the current task (Esc)", "現在の処理を停止（Esc）", "현재 작업 중지 (Esc)"))
                }

                if !state.problems.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(state.problems
                            .map { "\($0.0.displayName): \($0.1.localizedDisplayText)" }
                            .joined(separator: "\n"))
                }

                voiceControl

                eraseButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// One-shot "look at my screen" control.
    ///
    /// Explaining the whole screen and explaining a dragged region send an
    /// image down the same path and differ only in what is captured, so they
    /// are one control rather than two buttons side by side: a click explains
    /// the screen, the menu offers the region.
    private var captureMenu: some View {
        Menu {
            Button {
                onExplainScreen?()
            } label: {
                Label(localized("Explain the whole screen", "画面全体を説明", "화면 전체 설명"),
                      systemImage: "sparkles")
            }
            Button {
                onSnipScreen?()
            } label: {
                Label(localized("Select a region…", "範囲を選んで説明…", "영역을 선택해 설명…"),
                      systemImage: "crop")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                Text(localized("Look at screen", "画面を見る", "화면 보기"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        } primaryAction: {
            onExplainScreen?()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(localized(
            "Click to explain the whole screen once. Use the arrow to select just a region.",
            "クリックで画面全体を1回説明します。矢印から、一部だけを範囲指定することもできます。",
            "클릭하면 화면 전체를 한 번 설명합니다. 화살표로 일부 영역만 선택할 수도 있습니다."))
        .accessibilityLabel(localized("Look at screen", "画面を見る", "화면 보기"))
        .disabled(state.isStreaming)
    }

    /// Prompts to start a fresh conversation.
    private var eraseButton: some View {
        Button {
            showNewConversationConfirm = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(localized("Start a new conversation", "新しい会話", "새 대화"))
        .accessibilityLabel(localized("Start a new conversation", "新しい会話", "새 대화"))
        .disabled(state.messages.isEmpty && !state.isStreaming)
    }

    // MARK: - Erasing

    /// Asks whether to start over with a fresh conversation.
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
                if let onClear { onClear() } else { state.clearChat() }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private func copyToPasteboard(_ message: ChatMessage) {
        let text = [message.title, message.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The switch that decides whether the agent looks at the screen on its own.
    ///
    /// Labelled with what it does rather than with a state word: "Watching"
    /// tells the user the screen is being read and sent, which is the fact they
    /// need in order to turn it off before opening something private.
    private var watchButton: some View {
        Button { onToggleWatch?() } label: {
            HStack(spacing: 5) {
                Image(systemName: state.watchPhase == .off ? "eye.slash" : "eye.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(watchTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if state.watchPhase == .looking {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                state.watchPhase == .off
                    ? Color.secondary.opacity(0.12)
                    : Color.mint.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(localized(
            """
            Continuously watch your screen and provide proactive advice on mistakes, \
            errors, or improvements. Press again to stop.
            """,
            """
            画面を継続的に見守り、エラーや改善点があるときだけ助言します。もう一度押すと終了します。
            """,
            """
            화면을 지속적으로 지켜보고 오류나 개선점이 있을 때만 조언합니다. 다시 누르면 종료합니다.
            """))
    }

    private var watchTitle: String {
        switch state.watchPhase {
        case .off: return localized("Continuous Watch", "画面を見守る", "화면 지켜보기")
        case .watching: return localized("Watching", "見守り中", "보는 중")
        case .looking: return localized("Looking…", "確認中…", "확인 중…")
        }
    }

    /// Fixes the watch on one subject instead of letting it follow the focus.
    ///
    /// A pin rather than an eye, and next to the switch it modifies: this does
    /// not turn watching on or off, it changes *what* is being watched, and the
    /// two would be indistinguishable as two eye buttons side by side.
    ///
    /// Opens the picker rather than pinning outright, because there are now
    /// three kinds of answer — the focused window, a specific window, a whole
    /// display — and a button that silently picked one of them would be wrong
    /// two times in three. `⌥⌘W` is still the one-press version for the common
    /// case.
    ///
    /// The picker is its own window, shared with the panel and the menu bar,
    /// rather than the list that used to drop out of this button. Naming a
    /// window is the one thing a list of names is bad at — four Chrome windows
    /// are four identical rows — so what opens now shows a picture of each.
    private var pinButton: some View {
        let isMultiActive = !state.watchItems.isEmpty
        let isPinned = isMultiActive || state.watchTarget.isPinned

        return Button { onChooseScreen?() } label: {
            HStack(spacing: 5) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                if isMultiActive {
                    let activeCount = state.watchItems.filter(\.isEnabled).count
                    Text(localized(
                        "\(activeCount) watched",
                        "\(activeCount) 画面監視中",
                        "\(activeCount)개 화면 감시 중"))
                        .font(.system(size: 11, weight: .medium))
                } else if let subject = state.watchTarget.subjectName {
                    Text(subject)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                isPinned
                    ? Color.mint.opacity(0.22)
                    : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(pinHelp)
    }

    private var pinHelp: String {
        guard let subject = state.watchTarget.subjectName else {
            return localized("""
                Choose one window or one display to watch, from a preview of \
                each, instead of following whatever is in front. ⌥⌘W pins the \
                window you are in without opening this.
                """, """
                前面のウインドウを追いかける代わりに、プレビューを見ながら特定のウインドウか\
                ディスプレイ 1 枚を見張る対象として選びます。⌥⌘W なら、これを開かずに\
                いまのウインドウを固定します。
                """, """
                앞에 있는 것을 따라가는 대신, 미리보기를 보며 특정 윈도우나 디스플레이 한 \
                대를 지켜볼 대상으로 고릅니다. ⌥⌘W 를 누르면 이것을 열지 않고 지금 \
                윈도우를 고정합니다.
                """)
        }
        return localized(
            "Watching \(subject). Click to choose something else.",
            "\(subject) を見張っています。クリックすると対象を選び直せます。",
            "지켜보는 중: \(subject). 누르면 대상을 다시 고를 수 있습니다.")
    }

    private var intervalMenu: some View {
        Menu {
            ForEach(ScreenWatchInterval.allCases, id: \.rawValue) { interval in
                Button {
                    onChooseInterval?(interval)
                } label: {
                    if interval == state.watchInterval {
                        Label(interval.title, systemImage: "checkmark")
                    } else {
                        Text(interval.title)
                    }
                }
            }
        } label: {
            Text(state.watchInterval.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(localized("How often to look", "画面を見る間隔", "화면을 보는 간격"))
    }

    /// One voice control: starts the current mode on click, or ends it when
    /// running. The menu switches between dictation (speech-to-text) and live
    /// conversation (bidirectional speech).
    @ViewBuilder
    private var voiceControl: some View {
        let mode = state.voiceMode
        let isRunning = state.voicePhase != .off
        if isRunning {
            toolbarButton(
                symbol: mode.activeSymbol,
                title: voicePhaseTitle,
                name: mode.title,
                help: mode.title + "\n\n" + localized("Click to end", "クリックで終了", "클릭하여 종료"),
                active: true,
                action: { onVoice?(mode) })
        } else {
            Menu {
                Button {
                    onVoice?(.dictation)
                } label: {
                    Label(localized("Dictation (Speech to text)", "音声入力（文字で入力）", "음성 입력(텍스트 변환)"),
                          systemImage: "mic")
                }
                Button {
                    onVoice?(.realtime)
                } label: {
                    Label(localized("Live Conversation (Bidirectional)", "リアルタイム会話（音声対話）", "실시간 대화(음성 대화)"),
                          systemImage: "waveform")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 11, weight: .medium))
                    Text(mode.shortTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            } primaryAction: {
                onVoice?(mode)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(localized(
                "Click to start \(mode.title). Use the arrow to switch between dictation and live conversation.",
                "クリックで \(mode.title) を開始します。矢印から、音声入力とリアルタイム会話を切り替えられます。",
                "클릭하면 \(mode.title)을(를) 시작합니다. 화살표로 음성 입력과 실시간 대화를 전환할 수 있습니다."))
            .accessibilityLabel(mode.title)
        }
    }

    private var voicePhaseTitle: String {
        switch state.voicePhase {
        case .off: return ""
        case .connecting: return localized("Connecting…", "接続中…", "연결 중…")
        case .live: return localized("End", "終了", "종료")
        }
    }

    /// A labelled toolbar button, or an unlabelled one when `title` is empty.
    /// `name` is what it is called either way — an icon alone is silence to
    /// VoiceOver.
    private func toolbarButton(
        symbol: String,
        title: String?,
        name: String? = nil,
        help: String,
        active: Bool,
        action: (() -> Void)?
    ) -> some View {
        Button { action?() } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .help(help)
        .accessibilityLabel(name ?? title ?? "")
    }

    // MARK: - Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if state.messages.isEmpty && !state.isStreaming {
                        emptyState
                    }
                    ForEach(state.messages) { message in
                        row(message)
                    }
                    if state.isStreaming {
                        ThinkingBubble(state.streamingText, textSize: 13)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(14)
            }
            // Both triggers are needed: a new message and a growing answer are
            // different changes, and following only the first leaves a long
            // streamed reply running off the bottom of the window.
            // Message changes also resize resolved approval cards and remove the
            // thinking bubble. Keep both scroll paths unanimated so those layout
            // changes cannot overlap a scroll animation and stall the native UI.
            .onChange(of: state.messages.count) { scrollToBottom(proxy) }
            .onChange(of: state.streamingText) { scrollToBottom(proxy) }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    /// One turn, with everything that acts on it.
    ///
    /// The ✕ is overlaid on top of the bubble rather than placed beside it,
    /// letting the bubble span the full width of the chat view without being
    /// narrowed by a dedicated button column. It appears on hover so it does not
    /// obscure text while reading.
    private func row(_ message: ChatMessage) -> some View {
        bubble(message)
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
            .contextMenu { messageMenu(message) }
    }

    /// The ✕ on a bubble. One click, no confirmation: a single message is the
    /// one deletion small enough to be worth less than the question guarding it.
    ///
    /// Overlaid on the top-trailing corner of the bubble, appearing on hover so
    /// text stays unobstructed while reading.
    private func deleteButton(_ message: ChatMessage) -> some View {
        Button { state.removeMessage(message.id) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.secondary.opacity(0.75))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .opacity(hovered == message.id ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(localized("Delete this message", "このメッセージを消す", "이 메시지 지우기"))
    }

    @ViewBuilder private func messageMenu(_ message: ChatMessage) -> some View {
        Button(localized("Copy", "コピー", "복사")) { copyToPasteboard(message) }

        Divider()

        Button(localized("Delete this message", "このメッセージを消す", "이 메시지 지우기")) {
            state.removeMessage(message.id)
        }
        Button(localized("Delete this and everything above", "ここまでをまとめて消す", "여기까지 한꺼번에 지우기")) {
            state.removeMessages(upThrough: message.id)
        }
    }

    /// Drawn by `MessageBubble`, which the panel and the popover draw too. The
    /// three are views of one thread and had no business looking like three
    /// applications.
    private func bubble(_ message: ChatMessage) -> some View {
        MessageBubble(
            message,
            textSize: 13,
            onAction: { payload, title in
                state.onExecuteAction?(payload, message.originTarget)
            },
            onApproval: { id, approved in
                state.resolveApproval(id, status: approved ? .approved : .rejected)
            })
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized(
                "Ask about anything on your screen.",
                "画面に映っていることを何でも聞いてください。",
                "화면에 보이는 것은 무엇이든 물어보세요."))
                .font(.system(size: 13, weight: .medium))
            Text(localized(
                """
                The agent already has the text from the windows you have been in. \
                Turn on “Watch my screen” and it will look every so often on its \
                own, and say something only when it spots a mistake, an error or \
                a faster way.
                """,
                """
                これまで開いていたウインドウの文字は、すでにエージェントが持っています。\
                「画面を見て助言」をオンにすると、自分でときどき画面を見にいき、\
                間違い・エラー・もっと速いやり方を見つけたときだけ話しかけます。
                """,
                """
                지금까지 열어 둔 윈도우의 글자는 에이전트가 이미 가지고 있습니다. \
                ‘화면을 보고 조언’을 켜면 스스로 가끔 화면을 살피고, \
                틀린 곳·오류·더 빠른 방법을 발견했을 때만 말을 겁니다.
                """))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Composer

    /// What the microphone is hearing, above the field it would have been typed
    /// into.
    ///
    /// Deliberately larger than the messages around it. Everything else in this
    /// window is read at leisure; this is checked at a glance, mid-sentence,
    /// while the user is still talking and looking at something else — and the
    /// only question it has to answer is "did that come out as I said it".
    private var voiceHeard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: state.voicePhase == .connecting ? "ellipsis" : "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(state.voicePhase == .live ? .cyan : .secondary)
                Text(state.voiceMode.shortTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                // The language the words are being recognised as, for the same
                // reason the large caption carries it: a transcript in the
                // wrong language is indistinguishable from a bad microphone
                // unless the choice is visible next to the result.
                if state.voiceMode == .dictation {
                    Text(Localization.shared.speechLocaleDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !state.voiceSearchQueries.isEmpty {
                    Label(
                        state.voiceSearchQueries.joined(separator: " · "),
                        systemImage: "globe")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.mint)
                        .lineLimit(1)
                }
            }

            voiceHeardText
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Settled words at full strength, the engine's live guess behind them.
    /// Same reasoning as the large caption: the two are different claims and
    /// drawing them alike makes every revision look like a mistake.
    private var voiceHeardText: Text {
        guard !state.voiceTranscript.isEmpty else {
            return Text(voiceHeardPlaceholder).foregroundStyle(.secondary)
        }
        return Text("\(Text(state.voiceTranscriptSettled).foregroundStyle(.primary))\(Text(state.voiceTranscriptPending).foregroundStyle(.secondary))")
    }

    private var voiceHeardPlaceholder: String {
        if state.voicePhase == .connecting {
            return localized("Connecting…", "接続しています…", "연결 중…")
        }
        return switch state.voiceMode {
        case .realtime:
            localized("Listening — go ahead.", "聞いています。話しかけてください。",
                "듣고 있습니다. 말씀하세요.")
        case .dictation:
            localized(
                "Listening — pause when you're done.",
                "聞いています。話し終えると送信します。",
                "듣고 있습니다. 말을 마치면 전송합니다.")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            PresetBarView(
                state: state,
                onExecutePreset: { role, target in
                    if let onExecutePreset {
                        onExecutePreset(role, target)
                    } else {
                        state.onExecutePreset?(role, target)
                    }
                },
                onApplyRoleToWatch: { role, target in
                    if let onApplyRoleToWatch {
                        onApplyRoleToWatch(role, target)
                    } else {
                        state.onApplyRoleToWatch?(role, target)
                    }
                },
                onChooseScreen: onChooseScreen
            )

            if !state.watchStatus.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "eye")
                        .font(.system(size: 9))
                    Text(state.watchStatus)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }

            if state.voicePhase != .off {
                voiceHeard
            }

            HStack(spacing: 8) {
                TextField(
                    localized("Ask about what you're seeing…", "画面について質問…",
                        "화면에 대해 질문…"),
                    text: $draft,
                    axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit(submit)

                // Deliberately not `.keyboardShortcut(.return)`: the field's own
                // `onSubmit` already fires on Return, and binding both sends the
                // question twice.
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || state.isStreaming)
                .help(localized("Send message (Return)", "送信 (Return)", "전송 (Return)"))
                .accessibilityLabel(localized("Send message", "送信", "전송"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .onAppear { inputFocused = true }
        .onChange(of: state.chatFocusRequest) { inputFocused = true }
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
