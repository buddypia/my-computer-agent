import AppKit
import Foundation
import MCACore
import MCAPerception
import MCAPresentation
import MCAReasoning
import SwiftUI

/// The settings window.
///
/// Everything here used to be reachable only from a terminal, and two of those
/// paths could not work at all:
///
/// - `mca auth set gemini` writes the key from a *different* binary than the one
///   that reads it, so the keychain item ends up owned by whatever shell ran it.
/// - `mca setup` raises permission prompts from a terminal-launched process, and
///   macOS attributes those grants to the terminal rather than to this app.
///
/// Both are fixed by the same move: do it from inside the running, signed app.
/// Shortcuts are here for a different reason — `RegisterEventHotKey` hands a
/// chord to whichever application asked first and reports nothing to the user,
/// so a fixed chord list is a feature that silently stops working.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    /// `tab` is optional so that merely reopening the window leaves the user
    /// where they were; only a command that means a specific page — the
    /// Permissions menu item — names one.
    func show(tab: SettingsTab? = nil) {
        if let tab { model.selectedTab = tab }
        model.refresh()

        if let window {
            window.title = Self.title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.setup.start()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = Self.title
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 520)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // The app runs with `.accessory` policy, so it is never frontmost by
        // default. Without this the window opens behind whatever the user is
        // working in and looks like nothing happened.
        NSApp.activate(ignoringOtherApps: true)
        model.setup.start()
    }

    /// The window title is AppKit's, not SwiftUI's, so it does not redraw itself
    /// when the language changes — the one string in this window that has to be
    /// pushed rather than observed.
    func languageChanged() {
        window?.title = Self.title
    }

    private static var title: String {
        localized("My Computer Agent — Settings", "My Computer Agent — 設定",
            "My Computer Agent — 설정")
    }

    /// Stops the permission poll when the window goes away. It exists to make a
    /// System Settings toggle feel acknowledged; with no window open it is a
    /// timer probing TCC every two seconds for nobody.
    func windowWillClose(_ notification: Notification) {
        model.setup.stop()
    }
}


/// State behind the settings window.
///
/// Holds no policy of its own: every change is pushed straight into the object
/// that owns it — `HUDPanel` for placement, `HotKeyCenter` for shortcuts, the
/// keychain for credentials — so the window cannot drift out of step with the
/// running app.
@MainActor
@Observable
final class SettingsModel {
    let hudState: HUDState
    let hotKeys: HotKeyCenter
    let setup = SetupModel()
    let localization = Localization.shared

    @ObservationIgnored private let hud: HUDPanel
    @ObservationIgnored private let configuration: AgentConfiguration
    /// Called after a credential changes so the composition root can rebuild
    /// the router and the agent. Adding a key has to recover routing without a
    /// relaunch, or the window is just a nicer way to edit a dead config.
    @ObservationIgnored private let onCredentialsChanged: () -> Void
    /// Called when the listening switch moves, so the composition root can open
    /// or close the capture devices. Persisting it is the root's job too — this
    /// model holds a copy of the configuration, not the file.
    @ObservationIgnored private let onAlwaysListeningChanged: (Bool) -> Void
    @ObservationIgnored private let onVoiceCaptionChanged: (Bool) -> Void
    @ObservationIgnored private let onTranscriptionEngineChanged: (TranscriptionEngine) -> Void
    @ObservationIgnored private let onEmbeddingGemmaModelChanged: (String) -> Void

    var selectedTab: SettingsTab = .general
    var alwaysListening: Bool
    var transcriptionEngine: TranscriptionEngine
    var embeddingGemmaModel: String

    /// Text typed into each provider's field. Never populated from the
    /// keychain: a stored secret is not re-displayed, only replaced or removed.
    var draftKeys: [String: String] = [:]
    /// Why the last save for a provider failed, if it did.
    var saveErrors: [String: String] = [:]
    var keySources: [String: CredentialStore.Source] = [:]
    var routes: [RouteStatus] = []
    var onDeviceReason: String?
    /// Whether the on-device failure is a switch the user can flick. Backs
    /// the "open System Settings" button — hidden for an ineligible device
    /// where it would do nothing.
    var onDeviceCanEnable = false
    var isCapturable: Bool
    /// How stored keys are protected on this Mac. Shown because the hardware
    /// and software cases are not equally strong.
    var protection: SecretStore.Protection = .secureEnclave

    struct RouteStatus: Identifiable {
        var id: String { task }
        var task: String
        var chain: [(name: String, usable: Bool)]
        var blockedReason: String?
    }

    static let providers: [(id: String, title: String, hint: LocalizedText)] = [
        (
            "gemini", "Google Gemini",
            (
                "Primary route for triage, answers and vision.",
                "トリアージ・回答・画像理解の主経路です。",
                "분류·답변·이미지 이해의 주 경로입니다."
            )
        ),
        (
            "anthropic", "Anthropic",
            ("Fallback for answers.", "回答のフォールバックです。", "답변의 대체 경로입니다.")
        ),
        (
            "openai-compatible", "OpenAI-compatible",
            (
                "Fallback for answers. Also used for Ollama-style endpoints.",
                "回答のフォールバック。Ollama 形式のエンドポイントにも使います。",
                "답변의 대체 경로. Ollama 형식 엔드포인트에도 사용합니다."
            )
        ),
        (
            "typesafe", "TypeSafe AI (Jev)",
            (
                "System One model for low-latency desktop automation and GUI grounding.",
                "超高速デスクトップ自動化・UI判定用の System One (Jev) モデルです。",
                "초저지연 데스크톱 자동화 및 UI 판정용 System One (Jev) 모델입니다."
            )
        ),
    ]

    struct EmbeddingGemmaOption: Identifiable {
        let id: String
        let title: LocalizedText
        let detail: LocalizedText
    }

    static let embeddingGemmaOptions: [EmbeddingGemmaOption] = [
        EmbeddingGemmaOption(
            id: "google/embeddinggemma-2-740m",
            title: (
                "740M (Multimodal) — Recommended",
                "740M（マルチモーダル）— 推奨",
                "740M (멀티모달) — 권장"
            ),
            detail: (
                "Full multimodal support (Text, Image, Audio) with 256d MRL embeddings.",
                "テキスト・画像・音声を網羅する完全マルチモーダル対応（256d MRL）。",
                "텍스트·이미지·음성을 모두 지원하는 완전 멀티모달 대응 (256d MRL)."
            )
        ),
        EmbeddingGemmaOption(
            id: "google/embeddinggemma-2-440m",
            title: (
                "440M (Lightweight Multimodal)",
                "440M（軽量マルチモーダル）",
                "440M (경량 멀티모달)"
            ),
            detail: (
                "Balanced multimodal model for machines with lower unified memory.",
                "ユニファイドメモリの消費を抑えたバランス型マルチモーダルモデルです。",
                "통합 메모리 사용량을 줄인 밸런스형 멀티모달 모델입니다."
            )
        ),
        EmbeddingGemmaOption(
            id: "google/embeddinggemma-2-270m",
            title: (
                "270M (Ultra-fast Text Only)",
                "270M（超高速テキスト専用）",
                "270M (초고속 텍스트 전용)"
            ),
            detail: (
                "Minimal resource usage, text-only embeddings without image/audio capability.",
                "最小限のリソースで動作するテキスト専用モデル。画像や音声は非対応です。",
                "최소한의 리소스로 동작하는 텍스트 전용 모델입니다. 이미지·음성은 미지원."
            )
        ),
    ]

    init(
        hudState: HUDState,
        hud: HUDPanel,
        hotKeys: HotKeyCenter,
        configuration: AgentConfiguration,
        transcriptionEngine: TranscriptionEngine = .gemini,
        onCredentialsChanged: @escaping () -> Void,
        onAlwaysListeningChanged: @escaping (Bool) -> Void,
        onVoiceCaptionChanged: @escaping (Bool) -> Void,
        onTranscriptionEngineChanged: @escaping (TranscriptionEngine) -> Void = { _ in },
        onEmbeddingGemmaModelChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.hudState = hudState
        self.hud = hud
        self.hotKeys = hotKeys
        self.configuration = configuration
        self.transcriptionEngine = transcriptionEngine
        self.onCredentialsChanged = onCredentialsChanged
        self.onAlwaysListeningChanged = onAlwaysListeningChanged
        self.onVoiceCaptionChanged = onVoiceCaptionChanged
        self.onTranscriptionEngineChanged = onTranscriptionEngineChanged
        self.onEmbeddingGemmaModelChanged = onEmbeddingGemmaModelChanged
        self.isCapturable = hud.isCapturable
        self.alwaysListening = configuration.alwaysListening
        self.embeddingGemmaModel = configuration.embeddingGemmaModel
        refresh()
    }

    // MARK: - EmbeddingGemma 2

    func setEmbeddingGemmaModel(_ model: String) {
        embeddingGemmaModel = model
        onEmbeddingGemmaModelChanged(model)
    }

    // MARK: - Audio

    func setAlwaysListening(_ enabled: Bool) {
        alwaysListening = enabled
        onAlwaysListeningChanged(enabled)
    }

    func setTranscriptionEngine(_ engine: TranscriptionEngine) {
        transcriptionEngine = engine
        onTranscriptionEngineChanged(engine)
    }

    /// Read straight from the shared state rather than copied, so the switch
    /// still reflects a change made from the menu bar while this window is open.
    var showsVoiceCaption: Bool { hudState.showsVoiceCaption }

    func setVoiceCaption(_ enabled: Bool) { onVoiceCaptionChanged(enabled) }

    // MARK: - Speech language

    /// Whether the language the transcriber is about to be asked for can be
    /// recognised on this Mac. `nil` while the probe is still running.
    var speechAvailability: SpeechAnalyzerTranscriber.LocaleAvailability?
    @ObservationIgnored private var speechProbe: Task<Void, Never>?

    func setSpeechLanguage(_ preference: SpeechLanguagePreference) {
        localization.speechPreference = preference
        refreshSpeechAvailability()
    }

    /// Asks the OS whether the resolved locale has a model, and whether it is
    /// already on disk.
    ///
    /// Re-run rather than cached because both halves move underneath us: the
    /// resolved locale changes with either language setting, and a model that
    /// was merely downloadable a minute ago is installed once a session has run.
    /// The probe is cancelled and replaced so that flicking through the picker
    /// cannot land an older answer on top of a newer one.
    func refreshSpeechAvailability() {
        speechProbe?.cancel()
        speechAvailability = nil
        let locale = localization.speechLocale
        speechProbe = Task { [weak self] in
            let availability = await SpeechAnalyzerTranscriber.availability(of: locale)
            guard !Task.isCancelled else { return }
            self?.speechAvailability = availability
        }
    }

    // MARK: - Overlay

    func setAlwaysVisible(_ visible: Bool) { hud.setAlwaysVisible(visible) }
    func setFloating(_ floating: Bool) { hud.setFloating(floating) }
    func setClickThrough(_ enabled: Bool) { hud.setClickThrough(enabled) }
    func setCollapsed(_ collapsed: Bool) { hud.setCollapsed(collapsed) }
    func move(to corner: HUDCorner) { hud.move(to: corner) }

    func setCapturable(_ enabled: Bool) {
        hud.setCapturable(enabled)
        isCapturable = enabled
    }

    // MARK: - Credentials

    func saveKey(for provider: String) {
        let value = (draftKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            // Written from this process, so the keychain item's access control
            // ends up owned by the app that has to read it back. The value is
            // sealed to this Mac's Secure Enclave before it gets there.
            try SecretStore.shared.write(account: provider, value: value)
        } catch {
            // Shown rather than swallowed: a failed save used to look exactly
            // like a successful one, and the user found out later as a route
            // that would not run.
            saveErrors[provider] = "\(error)"
            return
        }
        saveErrors[provider] = nil
        draftKeys[provider] = ""
        credentialsChanged()
    }

    func removeKey(for provider: String) {
        SecretStore.shared.delete(account: provider)
        saveErrors[provider] = nil
        credentialsChanged()
    }

    private func credentialsChanged() {
        onCredentialsChanged()
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        refreshSpeechAvailability()
        let credentials = CredentialStore()
        keySources = Dictionary(uniqueKeysWithValues: Self.providers.compactMap { provider in
            credentials.source(for: provider.id).map { (provider.id, $0) }
        })
        onDeviceReason = AppleOnDeviceExecutor.unavailableReason
        onDeviceCanEnable = AppleOnDeviceExecutor.canBeEnabledInSettings
        protection = SecretStore.shared.protection()

        let router = ModelRouter(policy: configuration.routing, credentials: credentials)
        routes = AgentTask.allCases.map { task in
            RouteStatus(
                task: task.rawValue,
                chain: router.chain(for: task).map { reference in
                    (
                        name: "\(reference.provider)/\(reference.model)",
                        usable: router.unavailableReason(for: reference) == nil
                    )
                },
                blockedReason: router.blockedReason(for: task))
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralSettings(model: model)
                .tabItem { Label(localized("General", "一般", "일반"), systemImage: "gearshape") }
                .tag(SettingsTab.general)

            OverlaySettings(model: model)
                .tabItem {
                    Label(
                        localized("Panel", "パネル", "패널"),
                        systemImage: "macwindow.on.rectangle")
                }
                .tag(SettingsTab.overlay)

            ShortcutSettings(model: model)
                .tabItem {
                    Label(localized("Shortcuts", "ショートカット", "단축키"), systemImage: "keyboard")
                }
                .tag(SettingsTab.shortcuts)

            ModelSettings(model: model)
                .tabItem {
                    Label(localized("Models & Keys", "モデルとキー", "모델과 키"), systemImage: "brain")
                }
                .tag(SettingsTab.models)

            ScrollView { SetupView(model: model.setup).padding(24) }
                .tabItem {
                    Label(localized("Permissions", "アクセス権限", "접근 권한"), systemImage: "lock.shield")
                }
                .tag(SettingsTab.permissions)
        }
        .padding(14)
    }
}

// MARK: - General tab

/// Where the language and the listening switch live.
///
/// Two language controls, in one section. The interface setting drives the two
/// things a user expects to move together — what this window says and what the
/// agent writes back — while speech gets its own, because reading the app in one
/// language and dictating in another is ordinary and a single control would make
/// one of the two wrong with no way to say so. They sit next to each other
/// rather than in separate tabs so the relationship between them, and the fact
/// that speech defaults to following the interface, is visible at a glance.
private struct GeneralSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(localized("Voice", "音声での会話", "음성 대화")) {
                    // Described, not chosen. Each mode has its own button on
                    // every surface, so a picker here would be a second answer
                    // to a question the buttons already answer — and the one
                    // most likely to be out of date, since it is the surface a
                    // user looks at least often. What is left is the part a
                    // button cannot carry: which of the two sends your voice
                    // off this Mac.
                    ForEach(VoiceMode.allCases, id: \.rawValue) { mode in
                        VoiceModeNote(mode: mode)
                    }

                    Text(localized(
                        "⌃⌥V starts whichever of the two you used last, and ends it.",
                        "⌃⌥V は、最後に使ったほうを始めます。もう一度押すと終了します。",
                        "⌃⌥V 는 마지막에 사용한 쪽을 시작하고, 다시 누르면 종료합니다."))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsToggle(
                        localized(
                            "Show what you said in large type",
                            "話した内容を大きな文字で表示",
                            "말한 내용을 큰 글자로 표시"),
                        detail: localized(
                            """
                            While a voice session is running, what the microphone heard is drawn \
                            across the bottom of the screen you are working on, sized to that \
                            display. It takes no clicks and never appears in a screenshot. \
                            Off, the same text is only in the panel and the chat window.
                            """,
                            """
                            音声セッション中、マイクが聞き取った内容を、作業中の画面の下部に\
                            そのディスプレイの大きさに合わせた文字で表示します。クリックは\
                            素通りし、スクリーンショットにも写りません。オフにすると、同じ\
                            内容はパネルとチャットウインドウにだけ表示されます。
                            """,
                            """
                            음성 세션 중에는 마이크가 들은 내용을 작업 중인 화면 아래쪽에 그 디스플레이 \
                            크기에 맞춘 글자로 표시합니다. 클릭은 그대로 통과하고 스크린샷에도 찍히지 \
                            않습니다. 끄면 같은 내용이 패널과 채팅 윈도우에만 표시됩니다.
                            """),
                        binding: Binding(
                            get: { model.showsVoiceCaption },
                            set: { model.setVoiceCaption($0) }))
                }

                SettingsSection(localized("Audio", "音声の取り込み", "오디오 입력")) {
                    SettingsToggle(
                        localized("Listen continuously", "常にマイクで聞き取る", "항상 마이크로 듣기"),
                        detail: localized(
                            """
                            Off by default. With this off the microphone opens only while a voice \
                            conversation is running (⌃⌥V) and closes as soon as it ends — no \
                            recording indicator in between, and nothing holding the device away \
                            from your other apps. On, the microphone and system audio are captured \
                            and transcribed for as long as the agent runs, which is what lets it \
                            advise on a meeting you never asked it about.
                            """,
                            """
                            既定はオフです。オフのあいだ、マイクは音声で会話しているとき（⌃⌥V）だけ\
                            開き、終わればすぐ閉じます。その間は録音インジケータも出ず、他のアプリの\
                            マイク利用も妨げません。オンにすると、エージェントが動いているあいだ\
                            マイクとシステム音声を取り込み続けて文字起こしします。頼まなくても会議の\
                            内容に助言できるのは、このモードのときだけです。
                            """,
                            """
                            기본값은 꺼짐입니다. 꺼져 있는 동안 마이크는 음성 대화 중(⌃⌥V)에만 열리고 \
                            끝나면 곧바로 닫힙니다. 그 사이에는 녹음 표시등도 뜨지 않고 다른 앱의 마이크 \
                            사용도 막지 않습니다. 켜면 에이전트가 동작하는 동안 마이크와 시스템 사운드를 \
                            계속 받아 문자로 변환합니다. 부탁하지 않아도 회의 내용에 조언할 수 있는 것은 \
                            이 모드일 때뿐입니다.
                            """),
                        binding: Binding(
                            get: { model.alwaysListening },
                            set: { model.setAlwaysListening($0) }))

                    Text(localized(
                        """
                        Applies immediately and is remembered across launches. Turning it on may \
                        raise a microphone prompt, and macOS may need to download a speech model \
                        the first time.
                        """,
                        """
                        すぐに反映され、次回以降の起動でも保持されます。オンにするとマイクの許可を\
                        求められることがあり、初回は macOS が音声モデルをダウンロードする場合が\
                        あります。
                        """,
                        """
                        즉시 반영되며 다음 실행에서도 유지됩니다. 켜면 마이크 권한을 물어볼 수 있고, \
                        처음에는 macOS가 음성 모델을 다운로드하기도 합니다.
                        """))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(localized("Language", "言語", "언어")) {
                    Picker(
                        localized("Interface", "表示", "화면 표시"),
                        selection: Binding(
                            get: { model.localization.preference },
                            set: { model.localization.preference = $0 })
                    ) {
                        ForEach(LanguagePreference.allCases, id: \.self) { preference in
                            Text(localized(preference.title)).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(localized(
                        """
                        Applies immediately, to both this interface and the language the agent \
                        writes its answers and advice cards in.
                        """,
                        """
                        すぐに反映され、この画面の表示と、エージェントが回答やアドバイスカードを書く\
                        言語の両方に適用されます。
                        """,
                        """
                        즉시 반영되며 이 화면의 표시와 에이전트가 답변·조언 카드를 쓰는 언어에 \
                        모두 적용됩니다.
                        """))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SpeechLanguagePicker(model: model)

                    // Said plainly rather than left to be discovered: an error
                    // string that stays English in an otherwise Japanese window
                    // looks like a bug unless it is called out as a choice.
                    Text(localized(
                        """
                        Error text from macOS and from model providers is shown as it arrives, in \
                        whatever language it was written — paraphrasing a message you may need to \
                        search for verbatim would help nobody. The `mca` command line is English only.
                        """,
                        """
                        macOS やモデルプロバイダから返るエラー文は、そのままの言語で表示します。\
                        そのまま検索したい文言を意訳しても役に立たないためです。`mca` コマンドライン\
                        は英語のみです。
                        """,
                        """
                        macOS와 모델 제공자가 보내는 오류 문구는 쓰인 언어 그대로 표시합니다. \
                        그대로 검색해야 할 문장을 의역하면 아무에게도 도움이 되지 않기 때문입니다. \
                        `mca` 명령줄은 영어만 지원합니다.
                        """))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }
}

/// Which language the microphone is transcribed as, and what that resolves to.
///
/// The resolved line is the load-bearing part. "Automatic" is the default and
/// cannot mean "work out what is being spoken" — `SpeechTranscriber` takes one
/// locale and does no language identification — so it means "follow the
/// interface language", and the only way for that to be honest is to say which
/// language it came out as, right under the control. Without it, someone whose
/// Mac is in English and who dictates in Korean gets plausible-looking nonsense
/// with nothing on screen to explain it.
private struct SpeechLanguagePicker: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                localized("Engine", "認識エンジン", "인식 엔진"),
                selection: Binding(
                    get: { model.transcriptionEngine },
                    set: { model.setTranscriptionEngine($0) })
            ) {
                Text(localized("Gemini Flash (Cloud / High Accuracy)", "Gemini Flash (クラウド・高精度)", "Gemini Flash (클라우드·고정밀)")).tag(TranscriptionEngine.gemini)
                Text(localized("macOS (On-Device / Private)", "macOS (オンデバイス・完全ローカル)", "macOS (온디바이스·완전 로컬)")).tag(TranscriptionEngine.apple)
            }
            .pickerStyle(.segmented)

            if model.transcriptionEngine == .gemini {
                note(
                    localized(
                        "Uses Gemini Flash multimodal AI for accurate transcription, eliminating homophone errors and verbal fillers.",
                        "Gemini Flash による高精度認識を使用します。文脈に応じて同音異義語の誤変換や不要なフィラーを自動補正します。",
                        "Gemini Flash 고정밀 인식을 사용합니다. 문맥에 맞게 동음이의어 오타와 불필요한 추임새를 자동으로 보정합니다."),
                    symbol: "sparkles",
                    tint: .blue)
            } else {
                availabilityNote
            }

            Divider()

            Picker(
                localized("Speech Language", "話す言語", "말하는 언어"),
                selection: Binding(
                    get: { model.localization.speechPreference },
                    set: { model.setSpeechLanguage($0) })
            ) {
                ForEach(SpeechLanguagePreference.allCases, id: \.self) { preference in
                    Text(localized(preference.title)).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Label {
                Text(resolved).font(.system(size: 11, weight: .medium))
            } icon: {
                Image(systemName: "waveform").font(.system(size: 10))
            }
            .foregroundStyle(.primary)

            Text(localized(
                """
                Automatic follows the interface language above — macOS transcribes against one \
                language at a time and does not detect which one you are speaking, so the app \
                names the one it chose rather than guessing on your behalf. Pick a language here \
                when you read the app in one and dictate in another.
                """,
                """
                「自動」は上の表示言語に従います。macOS の音声認識は一度に 1 つの言語しか扱えず、\
                話している言語を判別する機能はありません。そのため推測はせず、選ばれた言語を\
                明示します。表示と話す言語が違うときは、ここで直接選んでください。
                """,
                """
                ‘자동’은 위의 화면 표시 언어를 따릅니다. macOS 음성 인식은 한 번에 한 가지 언어만 \
                다루며 어떤 언어로 말하는지 감지하지 못합니다. 그래서 추측하지 않고 선택된 언어를 \
                명시합니다. 읽는 언어와 말하는 언어가 다르면 여기서 직접 고르세요.
                """))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(localized(
                """
                Changing this restarts transcription, so the first few seconds after a change are \
                not captured.
                """,
                """
                切り替えると文字起こしが再起動するため、変更直後の数秒は記録されません。
                """,
                """
                이 설정을 바꾸면 문자 변환이 다시 시작되므로 변경 직후 몇 초는 기록되지 않습니다.
                """))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `Automatic → 한국어 (ko-KR)`, or just the language when it was pinned —
    /// an arrow from a choice to itself reads as a bug.
    private var resolved: String {
        let description = model.localization.speechLocaleDescription
        guard model.localization.speechPreference == .automatic else { return description }
        return "\(localized(SpeechLanguagePreference.automatic.title)) → \(description)"
    }

    @ViewBuilder
    private var availabilityNote: some View {
        switch model.speechAvailability {
        case .installed:
            note(
                localized(
                    "The speech model for this language is installed.",
                    "この言語の音声モデルはインストール済みです。",
                    "이 언어의 음성 모델이 설치되어 있습니다."),
                symbol: "checkmark.circle.fill",
                tint: .green)
        case .downloadable:
            note(
                localized(
                    """
                    macOS has not downloaded this language's speech model yet. It is fetched the \
                    first time you dictate, which can take a while on a slow connection.
                    """,
                    """
                    この言語の音声モデルはまだダウンロードされていません。初回の音声入力時に取得され、\
                    回線が遅いと時間がかかることがあります。
                    """,
                    """
                    이 언어의 음성 모델은 아직 내려받지 않았습니다. 처음 음성 입력을 할 때 받아오며, \
                    회선이 느리면 시간이 걸릴 수 있습니다.
                    """),
                symbol: "arrow.down.circle.fill",
                tint: .orange)
        case .unsupported:
            note(
                localized(
                    """
                    This Mac cannot transcribe this language on device. Dictation will not start; \
                    Live conversation still works, because it listens on the server.
                    """,
                    """
                    この Mac では、この言語をオンデバイスで文字起こしできません。音声入力は開始\
                    できませんが、サーバー側で聞き取る「リアルタイム会話」は使えます。
                    """,
                    """
                    이 Mac에서는 이 언어를 온디바이스로 변환할 수 없습니다. 음성 입력은 시작되지 \
                    않지만, 서버에서 듣는 ‘실시간 대화’는 사용할 수 있습니다.
                    """),
                symbol: "exclamationmark.triangle.fill",
                tint: .red)
        case nil:
            note(
                localized("Checking…", "確認しています…", "확인 중…"),
                symbol: "ellipsis.circle",
                tint: .secondary)
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Overlay tab

private struct OverlaySettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(localized("Window", "ウインドウ", "윈도우")) {
                    SettingsToggle(
                        localized(
                            "Show the panel on the desktop",
                            "デスクトップにパネルを表示する",
                            "데스크탑에 패널 표시"),
                        detail: localized(
                            """
                            Off, the agent lives in the menu bar: click ✨ for the same panel, and \
                            it closes again when you click away. On, the panel sits on the desktop \
                            and stays there until you close it.
                            """,
                            """
                            オフのとき、エージェントはメニューバーに常駐します。✨ をクリックすると\
                            同じパネルが開き、他をクリックすると閉じます。オンにすると、パネルは\
                            デスクトップに置かれ、閉じるまでそのまま残ります。
                            """,
                            """
                            끄면 에이전트는 메뉴 막대에 머무릅니다. ✨ 를 클릭하면 같은 패널이 열리고 \
                            다른 곳을 클릭하면 닫힙니다. 켜면 패널이 데스크탑에 놓이고 닫을 때까지 \
                            그대로 남습니다.
                            """),
                        binding: Binding(
                            get: { model.hudState.isAlwaysVisible },
                            set: { model.setAlwaysVisible($0) }))

                    // Everything below only describes a window that may not
                    // exist, so it is dimmed rather than silently inert.
                    Group {
                        // Distinct from the switch above, and the two used to be
                        // easy to read as the same promise: that one decides
                        // whether the panel is on the desktop at all, this one
                        // decides whether other windows are allowed over it.
                        SettingsToggle(
                            localized(
                                "Keep it in front of other windows",
                                "常に最前面に表示する",
                                "항상 맨 앞에 표시"),
                            detail: localized(
                                """
                                On, the panel stays in front on every Space and over full-screen \
                                apps. Off, it behaves like an ordinary window and whatever you are \
                                working in covers it.
                                """,
                                """
                                オンのとき、パネルはすべての Space と全画面表示のアプリの前に出た\
                                ままになります。オフにすると普通のウインドウと同じで、作業中の\
                                ウインドウの後ろに隠れます。
                                """,
                                """
                                켜면 패널이 모든 Space와 전체 화면 앱 앞에 계속 나옵니다. 끄면 일반 윈도우와 \
                                같아져서 작업 중인 윈도우 뒤로 가려집니다.
                                """),
                            binding: Binding(
                                get: { model.hudState.isFloating },
                                set: { model.setFloating($0) }))
                        SettingsToggle(
                            localized("Collapse to a bar", "細いバーにたたむ", "얇은 바로 접기"),
                            detail: localized(
                                "Shrinks the panel to a thin title bar without closing it.",
                                "パネルを閉じずに、細いタイトルバーだけの表示にします。",
                                "패널을 닫지 않고 얇은 제목 표시줄만 남깁니다."),
                            binding: Binding(
                                get: { model.hudState.isCollapsed },
                                set: { model.setCollapsed($0) }))
                        SettingsToggle(
                            localized("Let clicks pass through", "クリックを背面に通す",
                                "클릭을 뒤로 통과시키기"),
                            detail: localized(
                                """
                                On, every click on the panel goes to the app behind it — its \
                                buttons and its question field included. Use it when you only want \
                                to read the panel; leave it off to click the panel at all.
                                """,
                                """
                                オンのとき、パネルへのクリックはボタンや質問欄も含めてすべて背面の\
                                アプリに届きます。読むだけで十分なときに使ってください。パネルを\
                                操作したい場合はオフのままにします。
                                """,
                                """
                                켜면 패널 클릭이 버튼과 질문 입력란까지 포함해 모두 뒤쪽 앱으로 전달됩니다. \
                                읽기만 하면 될 때 사용하고, 패널을 조작하려면 꺼 두세요.
                                """),
                            binding: Binding(
                                get: { model.hudState.isClickThrough },
                                set: { model.setClickThrough($0) }))
                    }
                    .disabled(!model.hudState.isAlwaysVisible)
                }

                SettingsSection(localized("Position", "表示位置", "표시 위치")) {
                    Picker(localized("Corner", "隅", "모서리"), selection: Binding(
                        get: { model.hudState.corner },
                        set: { model.move(to: $0) }
                    )) {
                        ForEach(HUDCorner.allCases, id: \.self) { corner in
                            Text(corner.title).tag(corner)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(localized(
                        "Dragging the panel with click-through off overrides this, and the dragged position is what gets remembered.",
                        "クリックが素通りしない状態でパネルをドラッグすると、この設定より優先され、ドラッグ先の位置を覚えます。",
                        "클릭이 통과하지 않는 상태에서 패널을 드래그하면 이 설정보다 우선하며, 드래그한 위치를 기억합니다."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .disabled(!model.hudState.isAlwaysVisible)

                SettingsSection(localized("Privacy", "プライバシー", "개인정보 보호")) {
                    SettingsToggle(
                        localized(
                            "Let the panel appear in screenshots",
                            "スクリーンショットにパネルを写す",
                            "스크린샷에 패널이 찍히도록 허용"),
                        detail: localized(
                            """
                            Off by default. The agent reads the screen, so a capturable panel can \
                            read its own last answer back and feed it into the next prompt. Turn it \
                            on when you need to screenshot a problem — an invisible window is \
                            impossible to report a bug about.
                            """,
                            """
                            既定はオフです。エージェントは画面を読むため、写り込むパネルは自分の直前の\
                            回答を読み取って次のプロンプトに混ぜてしまいます。不具合をスクリーン\
                            ショットで報告したいときだけオンにしてください。写らないウインドウは\
                            バグ報告のしようがありません。
                            """,
                            """
                            기본값은 꺼짐입니다. 에이전트는 화면을 읽기 때문에, 찍히는 패널은 자기 직전 \
                            답변을 다시 읽어 다음 프롬프트에 섞어 버립니다. 문제를 스크린샷으로 알리고 \
                            싶을 때만 켜세요. 찍히지 않는 윈도우는 버그로 신고할 방법이 없습니다.
                            """),
                        binding: Binding(
                            get: { model.isCapturable },
                            set: { model.setCapturable($0) }))
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Shortcuts tab

private struct ShortcutSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localized(
                    """
                    These are claimed system-wide. macOS gives a chord to whichever app registers \
                    it first and tells nobody, so a shortcut that stops working is almost always a \
                    collision — rebind it here.
                    """,
                    """
                    これらはシステム全体で確保されます。macOS はキーの組み合わせを最初に登録した\
                    アプリに与え、誰にも知らせません。効かなくなったショートカットはほぼ必ず衝突が\
                    原因なので、ここで割り当て直してください。
                    """,
                    """
                    이 단축키들은 시스템 전체에서 선점됩니다. macOS는 키 조합을 먼저 등록한 앱에 \
                    주고 아무에게도 알리지 않으므로, 작동을 멈춘 단축키는 거의 항상 충돌입니다. \
                    여기서 다시 지정하세요.
                    """))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action, model: model)
                }

                HStack {
                    Spacer()
                    Button(localized("Restore Defaults", "デフォルトに戻す", "기본값으로 되돌리기")) {
                        model.hotKeys.resetAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(20)
        }
    }
}

private struct ShortcutRow: View {
    let action: HotKeyAction
    @Bindable var model: SettingsModel

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    private var problem: HotKeyProblem? { model.hotKeys.problems[action] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 13, weight: .semibold))
                    Text(action.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)

                Button(action: toggleRecording) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)

                Button {
                    stopRecording()
                    model.hotKeys.rebind(action, to: nil)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(localized("Clear this shortcut", "このショートカットを消す", "이 단축키 지우기"))
                .disabled(model.hotKeys.chord(for: action) == nil)

                Button {
                    stopRecording()
                    model.hotKeys.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(localized("Restore the default", "デフォルトに戻す", "기본값으로 되돌리기"))
            }

            if let rejection {
                message(rejection, tint: .orange)
            } else if let problem {
                message(problem.displayText, tint: problem.isFault ? .red : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return localized("Press keys…", "キーを押す…", "키를 누르세요…") }
        return model.hotKeys.chord(for: action)?.displayString
            ?? localized("None", "なし", "없음")
    }

    private func message(_ text: String, tint: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(tint)
    }

    // MARK: Recording

    /// Captures the next chord with a local event monitor rather than a custom
    /// first-responder view. The monitor swallows the event, which is what stops
    /// the settings window from also acting on ⌘W or ⌘Q while recording.
    private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        rejection = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels rather than binding, matching every other shortcut
        // recorder on the platform.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .option, .control]) {
            stopRecording()
            return
        }

        guard let chord = GlobalHotKey.Chord.from(event: event) else {
            rejection = localized(
                "Add ⌘, ⌥ or ⌃ — a bare key would be taken from every other app.",
                "⌘ / ⌥ / ⌃ のいずれかを足してください。修飾なしのキーは他のすべてのアプリから奪ってしまいます。",
                "⌘ / ⌥ / ⌃ 중 하나를 더하세요. 조합키 없는 키는 다른 모든 앱에서 빼앗게 됩니다.")
            return
        }
        if let reserved = chord.reservedReason {
            rejection = reserved
            return
        }
        if let owner = model.hotKeys.owner(of: chord, excluding: action) {
            rejection = localized(
                "\(chord.displayString) is already used by “\(owner.title)”.",
                "\(chord.displayString) はすでに「\(owner.title)」が使っています。",
                "\(chord.displayString) 은(는) 이미 ‘\(owner.title)’ 이(가) 사용 중입니다.")
            return
        }
        stopRecording()
        model.hotKeys.rebind(action, to: chord)
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Models tab

private struct ModelSettings: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.keySources.isEmpty {
                    CalloutBox(tint: .red, symbol: "key.slash") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized(
                                "No API key — the agent cannot answer anything",
                                "API キーがありません。エージェントは何も回答できません",
                                "API 키가 없습니다. 에이전트는 아무것도 답할 수 없습니다"))
                                .font(.system(size: 12, weight: .semibold))
                            Text(localized(
                                """
                                Every cloud route below is blocked, so proactive watching is paused \
                                and asking a question fails. Add a Gemini key to bring both back; \
                                it is stored in your login keychain, not in a config file.
                                """,
                                """
                                下のクラウド経路はすべて塞がっているため、能動的な監視は停止し、\
                                質問しても失敗します。Gemini のキーを追加すれば両方が復帰します。\
                                キーは設定ファイルではなくログインキーチェーンに保存されます。
                                """,
                                """
                                아래 클라우드 경로가 모두 막혀 있어 능동적인 관찰은 멈추고 질문해도 실패합니다. \
                                Gemini 키를 추가하면 둘 다 복구됩니다. 키는 설정 파일이 아니라 로그인 키체인에 \
                                저장됩니다.
                                """))
                                .font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsSection(localized("API keys", "API キー", "API 키")) {
                    StorageProtectionNote(protection: model.protection)
                    ForEach(SettingsModel.providers, id: \.id) { provider in
                        ProviderRow(provider: provider, model: model)
                    }
                }

                SettingsSection(localized("On-device", "オンデバイス", "온디바이스")) {
                    if let reason = model.onDeviceReason {
                        Label(
                            localized(
                                "Apple on-device model unavailable: ",
                                "Apple のオンデバイスモデルが使えません: ",
                                "Apple 온디바이스 모델을 쓸 수 없습니다: ") + reason,
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(localized(
                            """
                            Triage runs every few seconds. Without the on-device gate it falls back \
                            to a cloud model, which is what turns a free constant path into a \
                            metered one.
                            """,
                            """
                            トリアージは数秒ごとに走ります。オンデバイスの関門がないとクラウドモデルに\
                            フォールバックし、無料で回り続けていた経路が従量課金になります。
                            """,
                            """
                            분류는 몇 초마다 실행됩니다. 온디바이스 관문이 없으면 클라우드 모델로 넘어가고, \
                            무료로 돌던 경로가 종량 과금으로 바뀝니다.
                            """))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.onDeviceCanEnable {
                            Button(localized(
                                "Open Apple Intelligence Settings",
                                "Apple Intelligence の設定を開く",
                                "Apple Intelligence 설정 열기")
                            ) {
                                model.setup.open(AppleOnDeviceExecutor.systemSettingsURL)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Label(
                            localized(
                                "Apple Intelligence available — triage runs free and local",
                                "Apple Intelligence が利用可能です。トリアージは無料かつローカルで動きます",
                                "Apple Intelligence 사용 가능 — 분류는 무료로 로컬에서 실행됩니다"),
                            systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }

                SettingsSection(localized(
                    "EmbeddingGemma 2 (Local)",
                    "EmbeddingGemma 2（ローカル）",
                    "EmbeddingGemma 2 (로컬)"
                )) {
                    Picker(
                        localized("Model", "モデル", "모델"),
                        selection: Binding(
                            get: { model.embeddingGemmaModel },
                            set: { model.setEmbeddingGemmaModel($0) }
                        )
                    ) {
                        ForEach(SettingsModel.embeddingGemmaOptions) { option in
                            Text(localized(option.title)).tag(option.id)
                        }
                    }

                    if let selected = SettingsModel.embeddingGemmaOptions.first(where: { $0.id == model.embeddingGemmaModel }) {
                        Text(localized(selected.detail))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Label(
                        localized(
                            "Used for 30-50ms System One GUI grounding and local semantic memory search (256d MRL vectors).",
                            "30-50msの超高速 System One GUI 判定およびローカルメモリのベクトル検索（256d MRL）に使用されます。",
                            "30-50ms 초고속 System One GUI 판정 및 로컬 메모리 벡터 검색(256d MRL)에 사용됩니다."
                        ),
                        systemImage: "bolt.badge.clock.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(localized("Routing", "ルーティング", "라우팅")) {
                    ForEach(model.routes) { route in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(route.task)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(width: 110, alignment: .leading)
                                ForEach(Array(route.chain.enumerated()), id: \.offset) { index, entry in
                                    if index > 0 {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(entry.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(entry.usable ? .primary : .secondary)
                                        .strikethrough(!entry.usable)
                                }
                                Spacer(minLength: 0)
                            }
                            if let reason = route.blockedReason {
                                Text(reason)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                    .padding(.leading, 116)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text(localized(
                        """
                        Model IDs and token budgets live in \
                        ~/Library/Application Support/MyComputerAgent/config.json, not in the binary.
                        """,
                        """
                        モデル ID とトークン上限はバイナリではなく \
                        ~/Library/Application Support/MyComputerAgent/config.json にあります。
                        """,
                        """
                        모델 ID와 토큰 상한은 바이너리가 아니라 \
                        ~/Library/Application Support/MyComputerAgent/config.json 에 있습니다.
                        """))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }
}

/// One line saying how the keys below are protected.
///
/// Without it the two cases are indistinguishable, and they are not equally
/// strong: hardware-bound versus login-password-bound is exactly the sort of
/// difference a user deciding whether to paste a production key wants to know.
private struct StorageProtectionNote: View {
    let protection: SecretStore.Protection

    var body: some View {
        switch protection {
        case .secureEnclave:
            Label(
                localized(
                    """
                    Keys are sealed with HPKE to a P-256 key that only exists inside this Mac's \
                    Secure Enclave, then stored in your login keychain. The stored bytes are \
                    useless on any other machine.
                    """,
                    """
                    キーは、この Mac の Secure Enclave の中にしか存在しない P-256 鍵に対して HPKE で\
                    封をしたうえで、ログインキーチェーンに保存されます。保存されたバイト列は他の\
                    マシンでは無意味です。
                    """,
                    """
                    키는 이 Mac의 Secure Enclave 안에만 존재하는 P-256 키에 HPKE로 봉인한 뒤 \
                    로그인 키체인에 저장됩니다. 저장된 바이트는 다른 기기에서는 아무 의미가 없습니다.
                    """),
                systemImage: "lock.shield.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)

        case .softwareKey(let reason):
            Label(
                localized(
                    """
                    Keys are encrypted, but to a software key rather than the Secure Enclave \
                    (\(reason)) — protection is only as strong as your login password.
                    """,
                    """
                    キーは暗号化されていますが、Secure Enclave ではなくソフトウェア鍵に対してです\
                    (\(reason))。保護の強さはログインパスワードと同程度になります。
                    """,
                    """
                    키는 암호화되어 있지만 Secure Enclave가 아니라 소프트웨어 키에 대해서입니다 \
                    (\(reason)). 보호 강도는 로그인 암호와 같은 수준입니다.
                    """),
                systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderRow: View {
    let provider: (id: String, title: String, hint: LocalizedText)
    @Bindable var model: SettingsModel

    private var source: CredentialStore.Source? { model.keySources[provider.id] }

    private var statusText: String {
        switch source {
        case .keychain: return localized("In your keychain", "キーチェーンに保存済み", "키체인에 저장됨")
        case .environment(let variable): return localized("From $\(variable)", "$\(variable) から取得", "$\(variable) 에서 가져옴")
        case .override: return localized("Overridden", "上書きされています", "덮어써져 있습니다")
        case nil: return localized("No key", "キーなし", "키 없음")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.title).font(.system(size: 12, weight: .semibold))
                Label(
                    statusText,
                    systemImage: source == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(source == nil ? Color.secondary : Color.green)
                Spacer()
                // Only a keychain item is ours to delete. An environment
                // variable is set outside the app, so a Remove button here
                // would be a button that does nothing.
                if source == .keychain {
                    Button(localized("Remove", "削除", "삭제")) { model.removeKey(for: provider.id) }
                        .controlSize(.small)
                }
            }

            Text(localized(provider.hint)).font(.system(size: 10)).foregroundStyle(.secondary)

            if case .environment(let variable) = source {
                Text(localized(
                    """
                    $\(variable) wins over anything stored here, and it is only visible to \
                    processes that inherit it — a key that works from your shell may be missing \
                    when macOS launches the app at login.
                    """,
                    """
                    $\(variable) はここに保存されたものより優先され、それを継承したプロセスからしか\
                    見えません。シェルからは動くキーでも、ログイン時に macOS がアプリを起動した\
                    ときには存在しないことがあります。
                    """,
                    """
                    $\(variable) 는 여기에 저장된 값보다 우선하며, 그것을 물려받은 프로세스에서만 \
                    보입니다. 셸에서는 되는 키라도 로그인 시 macOS가 앱을 실행할 때는 없을 수 \
                    있습니다.
                    """))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SecureField(
                    source == nil
                        ? localized("Paste the API key…", "API キーを貼り付け…",
                            "API 키 붙여넣기…")
                        : localized("Replace the stored key…", "保存済みのキーを置き換え…",
                            "저장된 키 교체…"),
                    text: Binding(
                        get: { model.draftKeys[provider.id] ?? "" },
                        set: { model.draftKeys[provider.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { model.saveKey(for: provider.id) }

                Button(localized("Save", "保存", "저장")) { model.saveKey(for: provider.id) }
                    .controlSize(.small)
                    .disabled((model.draftKeys[provider.id] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let failure = model.saveErrors[provider.id] {
                Label(
                    localized("Could not save: ", "保存できませんでした: ", "저장하지 못했습니다: ") + failure,
                    systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Shared chrome

/// A switch with the sentence that says what it costs to be wrong about it.
///
/// The detail line is not decoration: every switch in this window trades one
/// thing for another — a device held open, a window that covers your work, a
/// panel the agent can read back to itself — and a bare label states neither
/// side of the trade.
private struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var value: Bool

    init(_ title: String, detail: String, binding: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._value = binding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $value)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One voice mode, as its button wears it: the same glyph, the same name, and
/// the sentence that says what leaves this Mac when you press it.
private struct VoiceModeNote: View {
    let mode: VoiceMode

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.system(size: 12, weight: .medium))
                Text(mode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
