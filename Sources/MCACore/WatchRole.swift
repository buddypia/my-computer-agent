import Foundation

/// The objective or purpose assigned to a watched screen.
///
/// Rather than asking a single general question ("is there a mistake or a faster
/// way?"), assigning a role allows the agent to behave like a specialized assistant
/// for each specific window or display:
/// - A meeting window: listening and watching to suggest quick answer drafts,
///   meeting minutes, or key takeaways.
/// - A CLI/terminal window: watching autonomous AI developer tools (Claude Code, Codex CLI)
///   for prompt approvals (`[y/N]`), test failures, or completed builds, offering one-click approval actions.
/// - A design/document window: checking for UI token discrepancies or edge-case oversights.
/// - Custom user-defined roles: user-crafted system prompts with custom trigger modes.
public struct WatchRole: Sendable, Equatable, Identifiable, Codable {
    /// How the watch is triggered for this role.
    public enum TriggerKind: String, Sendable, Equatable, Codable {
        /// Periodic look when screen content changes (default).
        case screenDiff
        /// Fast look on speech turn boundary or screen slide changes (meeting assistant).
        case meetingFast
        /// Look when terminal output settles and waits for user prompt/approval.
        case cliPromptWait
    }

    public var id: String
    public var name: String
    public var icon: String
    public var systemPrompt: String
    /// Specific prompt used for on-demand task execution against the target screen.
    public var taskPrompt: String?
    public var triggerKind: TriggerKind
    public var defaultInterval: TimeInterval
    public var isBuiltin: Bool

    public init(
        id: String,
        name: String,
        icon: String,
        systemPrompt: String,
        taskPrompt: String? = nil,
        triggerKind: TriggerKind = .screenDiff,
        defaultInterval: TimeInterval = 45,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.taskPrompt = taskPrompt
        self.triggerKind = triggerKind
        self.defaultInterval = defaultInterval
        self.isBuiltin = isBuiltin
    }

    /// The prompt to send when executing an on-demand task with this role/preset.
    public var effectiveTaskPrompt: String {
        if let taskPrompt, !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return taskPrompt
        }
        return systemPrompt
    }

    /// The full request sent when the user runs this preset once against a screen.
    ///
    /// Carries only the task prompt, never the watch prompt as a system
    /// instruction: every watch prompt ends in "reply PASS when there is nothing
    /// new", and a user who clicked a preset gets that PASS back verbatim
    /// because the one-shot path has no silence gate. The closing line covers
    /// custom roles without a task prompt, whose fallback is the watch prompt.
    public func oneShotDirective(targetName: String) -> String {
        """
        # Directive: \(name)
        # Target Screen: \(targetName)

        \(effectiveTaskPrompt)

        This is an explicit one-time request from the user. Always answer with \
        the requested content based on what is visible — never reply PASS.
        """
    }
}

// MARK: - Builtin Presets

extension WatchRole {
    /// The default general-purpose advisor / explainer.
    public static let general = WatchRole(
        id: "builtin.general",
        name: "汎用アドバイス",
        icon: "sparkles",
        systemPrompt: """
            Look at the screen and decide whether there is a mistake, an error, a risk, \
            or a faster way worth telling the user right now. If there is nothing notable, reply PASS.
            """,
        taskPrompt: """
            今画面に見えている内容をわかりやすく説明し、全体像と注目すべきポイント、次に取るべきアクションを具体的に教えてください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 45,
        isBuiltin: true
    )

    /// Error and stack trace diagnosis preset.
    public static let errorDiagnosis = WatchRole(
        id: "builtin.error-diagnosis",
        name: "エラー診断",
        icon: "exclamationmark.triangle.fill",
        systemPrompt: """
            あなたは熟練のデバッグ・トラブルシューティング専門家です。
            画面に表示されているエラーログ、クラッシュログ、例外スタックトレース、またはビルド・実行時エラーを監視します。
            エラーや不具合が検知された時のみ、根本原因と具体的な修正案を提示してください。
            問題がなければ絶対に発言せず PASS とだけ返してください。
            """,
        taskPrompt: """
            この画面に表示されているエラーメッセージ、警告、例外スタックトレース、または異常動作の原因を詳細に診断してください。
            根本原因を特定し、それを解消するための具体的な修正手順やコマンド、コード修正をステップ順に提示してください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 20,
        isBuiltin: true
    )

    /// Meeting and discussion notes / summary preset.
    public static let summaryNotes = WatchRole(
        id: "builtin.summary-notes",
        name: "要約・議事録",
        icon: "doc.text.magnifyingglass",
        systemPrompt: """
            画面上の資料や議論、チャットログ、議事録の要点を整理する書記・サマライザーです。
            重要なアジェンダの決定事項や新しい要点が発生した時のみ、簡潔にサマリを報告してください。
            特に更新がなければ PASS とだけ返してください。
            """,
        taskPrompt: """
            この画面に表示されている内容（ドキュメント、スライド、議論、Webページ等）の要点を整理し、重要なポイント、決定事項、前提条件を箇条書きでわかりやすくまとめてください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 30,
        isBuiltin: true
    )

    /// Task and action items extractor preset.
    public static let actionItems = WatchRole(
        id: "builtin.action-items",
        name: "タスク・ToDo抽出",
        icon: "checklist",
        systemPrompt: """
            画面内のタスク、未完了ToDo、締め切り、アクションアイテムを監視するプロジェクトマネージャーです。
            新たなタスクやToDoが検知された時のみ報告してください。特になければ PASS と返してください。
            """,
        taskPrompt: """
            この画面の内容から、次に取り組むべき具体的なタスク、ToDo、未解決のアクションアイテムを洗い出し、優先度順に整理して箇条書きで抽出してください。担当者や期限が読み取れる場合はそれも含めてください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 30,
        isBuiltin: true
    )

    /// Code review and improvement suggestions preset.
    public static let codeReview = WatchRole(
        id: "builtin.code-review",
        name: "コードレビュー",
        icon: "curlybraces",
        systemPrompt: """
            あなたは厳格かつ親切なシニアエンジニアです。
            画面に表示されているソースコードやdiffを監視し、潜在的バグ、セキュリティ脆弱性、パフォーマンス劣化の懸念がある時のみ指摘してください。
            問題がなければ PASS とだけ返してください。
            """,
        taskPrompt: """
            この画面に表示されているコードを詳細にレビューしてください。潜在的バグ、セキュリティ上の懸念、パフォーマンス改善点、可読性向上案を、具体的な修正後コードの差分やスニペット付きで提示してください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 30,
        isBuiltin: true
    )

    /// Real-time meeting assistant: analyzes spoken audio and shared slides/faces
    /// to instantly suggest answers, key discussion points, and fact-checks.
    public static let meeting = WatchRole(
        id: "builtin.meeting",
        name: "ミーティング支援",
        icon: "person.wave.2.fill",
        systemPrompt: """
            あなたはオンライン会議の参加者を支援する最高峰の戦略補佐官（Chief of Staff）です。
            画面（共有資料・スライド・話者）と直近の会話履歴（相手の発言および自分の発言）を即座に分析し、
            ユーザーが次に発言すべき【回答案】、議論の【論点整理】、または見逃しやすい【留意点】を、会議中に一目で読める短さで提示してください。
            相手が質問している時は即座に的確な回答の骨子を提案してください。
            特に新しく助言すべきことがない、または沈黙・雑談の場合は、絶対に発言せず PASS とだけ返してください。
            """,
        taskPrompt: """
            現在の会議の状況、議論内容、共有画面の要点を整理し、ユーザーが次に発言すべき的確な回答案、論点、留意点を具体的に提示してください。
            """,
        triggerKind: .meetingFast,
        defaultInterval: 15,
        isBuiltin: true
    )

    /// Autonomous AI CLI developer monitor: watches terminal sessions (Claude Code, Codex CLI, Cursor)
    /// for prompt approvals (`[y/N]`), command failures, or long-running task completions,
    /// enabling the user to review and act from the HUD without switching focus.
    public static let cliDev = WatchRole(
        id: "builtin.cli-dev",
        name: "AI CLI開発監視",
        icon: "terminal.fill",
        systemPrompt: """
            あなたは自律型AIエージェント（Claude Code, Codex CLI等）によるCLI開発を監視するシニアエンジニアです。
            ターミナルの出力ログと画面状態を監視し、以下の状況を検知した時のみ発言してください：
            1. ユーザーの承認・入力待ち（例: `[y/N]`, `Allow`, `Continue?`, 選択メニュー）:
               何を安全に実行しようとしているかと、承認の可否判断（推奨アクション: y または n）を明示。
            2. ビルド・テスト・コマンドの失敗:
               失敗の根本原因と、即座に試すべき修正コマンドやコードを提示。
            3. 長時間ジョブの完了:
               正常終了か異常終了かの結果サマリを報告。
            自律的に処理が進行中、または問題のないログ出力中は、絶対に発言せず PASS とだけ返してください。
            """,
        taskPrompt: """
            ターミナル画面の状態を分析してください。AIエージェントやコマンドが入力・承認待ちであれば推奨アクション（y/Nなど）を提示し、エラーがあれば根本原因と解決コマンドを、処理中であれば現在の進捗状況を教えてください。
            """,
        triggerKind: .cliPromptWait,
        defaultInterval: 10,
        isBuiltin: true
    )

    /// UI and specification consistency inspector.
    public static let specCheck = WatchRole(
        id: "builtin.spec-check",
        name: "仕様・デザイン照合",
        icon: "ruler.fill",
        systemPrompt: """
            表示されているデザイン（Figma等）や仕様書（Notion, PRD等）を確認し、
            UIトークン（色・余白・文字サイズ）の不整合、未定義のエッジケース、仕様矛盾を発見した時のみ指摘してください。
            問題がなければ PASS とだけ返してください。
            """,
        taskPrompt: """
            この画面のデザインや仕様書、実装コードを確認し、UIトークン（色・余白・文字サイズ）の不整合、未考慮のエッジケース、仕様矛盾、アクセシビリティの懸念点を具体的に指摘してください。
            """,
        triggerKind: .screenDiff,
        defaultInterval: 45,
        isBuiltin: true
    )

    /// All standard built-in roles and execution presets.
    public static let allBuiltins: [WatchRole] = [
        .errorDiagnosis,
        .summaryNotes,
        .actionItems,
        .codeReview,
        .specCheck,
        .general,
        .cliDev,
        .meeting,
    ]
}
