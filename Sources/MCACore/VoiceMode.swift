import Foundation

/// Which of the two ways of talking to the agent a voice button starts.
///
/// Two modes rather than one because the single realtime session was answering
/// two different questions with the same machinery, and doing one of them badly.
/// A live socket is the right shape for "talk to me" — it endpoints, barges in
/// and speaks back — and the wrong shape for "I have a question but I would
/// rather say it than type it": that one wants the same model, the same tools
/// and the same written answer the chat already produces, with speech only
/// replacing the keyboard.
///
/// The distinction is also a cost and a privacy one, and the user is the only
/// one who can weigh it. Realtime streams raw microphone audio to Google for as
/// long as the session is open; dictation transcribes on device and sends the
/// resulting text, which is a fraction of the bytes and none of the voice.
///
/// This is no longer a setting the user picks before pressing a button. Each
/// mode has its own control on every surface, so the mode *is* the button. A
/// picker in front of a single button made the common case — start talking —
/// two decisions deep, and left the interface claiming a mode while the user was
/// looking for a microphone.
public enum VoiceMode: String, CaseIterable, Codable, Sendable {
    /// A live, bidirectional conversation with Gemini, with web search on the
    /// far side so it can answer about things that happened after training.
    case realtime
    /// Speech transcribed on device, then answered by the ordinary chat model —
    /// tools, screen context, streamed text and all.
    case dictation

    @MainActor
    public var title: String {
        switch self {
        case .realtime:
            return localized("Live conversation", "リアルタイム会話", "실시간 대화")
        case .dictation:
            return localized("Dictation", "音声入力", "음성 입력")
        }
    }

    /// One or two words, for a button or a status line where the full title
    /// would not fit.
    @MainActor
    public var shortTitle: String {
        switch self {
        case .realtime: return localized("Live", "会話", "대화")
        case .dictation: return localized("Dictate", "音声入力", "음성 입력")
        }
    }

    /// The glyph the mode's button wears while nothing is running.
    ///
    /// Dictation gets the bare microphone every other application on the
    /// platform uses for exactly this — speech becoming text — because a
    /// familiar icon needs no label and no explanation. Realtime deliberately
    /// does *not* get a microphone: it is not dictation with extra steps, and
    /// two microphones side by side would say the two buttons differ in degree
    /// when they differ in kind. The waveform is the same mark this app already
    /// uses everywhere a live session is running.
    public var symbol: String {
        switch self {
        case .realtime: return "waveform"
        case .dictation: return "mic"
        }
    }

    /// The glyph while this mode is the one running. Filled, so a session that
    /// is up is legible from the icon alone rather than only from the tint.
    public var activeSymbol: String {
        switch self {
        case .realtime: return "waveform.circle.fill"
        case .dictation: return "mic.fill"
        }
    }

    /// Menu wording for starting this mode. A menu item is read as a sentence
    /// and has room for the verb the icon leaves implicit.
    @MainActor
    public var startCommandTitle: String {
        switch self {
        case .realtime:
            return localized("Start a Live Conversation", "リアルタイム会話を始める", "실시간 대화 시작")
        case .dictation:
            return localized("Start Dictation", "音声入力を始める", "음성 입력 시작")
        }
    }

    /// Menu wording for ending this mode, shown in place of the start title
    /// while it is running.
    @MainActor
    public var stopCommandTitle: String {
        switch self {
        case .realtime:
            return localized("End the Live Conversation", "リアルタイム会話を終える", "실시간 대화 종료")
        case .dictation:
            return localized("Stop Dictation", "音声入力を終える", "음성 입력 종료")
        }
    }

    @MainActor
    public var detail: String {
        switch self {
        case .realtime:
            return localized(
                """
                Gemini hears you and speaks back over one connection, and searches the web \
                when it needs something current. Interrupt it any time. Your microphone audio \
                is streamed to Google for as long as the conversation is open.
                """,
                """
                Gemini が一つの接続で音声を聞き、音声で答えます。最新の情報が必要なときは\
                その場で Web を検索します。話しかけて割り込むこともできます。会話中は\
                マイクの音声が Google に送られ続けます。
                """,
                """
                Gemini가 하나의 연결로 음성을 듣고 음성으로 답합니다. 최신 정보가 필요할 때는 \
                그 자리에서 웹을 검색합니다. 말을 걸어 끼어들 수도 있습니다. 대화 중에는 \
                마이크 음성이 Google로 계속 전송됩니다.
                """)
        case .dictation:
            return localized(
                """
                What you say is transcribed on this Mac, and the answer comes from the same \
                chat model as a typed question — with your screen context and its tools. \
                No audio leaves the machine; only the text does.
                """,
                """
                話した内容はこの Mac の中で文字にして、あとは打ち込んだ質問とまったく同じ\
                チャットモデルが答えます。画面の文脈もツールもそのまま使えます。\
                音声は外に出ず、文字だけが送られます。
                """,
                """
                말한 내용은 이 Mac 안에서 문자로 바뀌고, 그다음은 타이핑한 질문과 완전히 같은 \
                채팅 모델이 답합니다. 화면 맥락도 도구도 그대로 쓸 수 있습니다. \
                음성은 밖으로 나가지 않고 문자만 전송됩니다.
                """)
        }
    }

    /// Tooltip for the mode's button: what it does, then how to get out of it.
    ///
    /// The second sentence is not decoration. These buttons toggle, and a
    /// control that starts something without saying how it stops is how a
    /// microphone ends up open longer than its owner meant.
    @MainActor
    public var buttonHelp: String {
        detail + "\n\n" + localized(
            "Press again to end.", "もう一度押すと終了します。", "다시 누르면 종료합니다.")
    }
}
