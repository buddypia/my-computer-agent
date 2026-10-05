import AppKit
import Foundation
import MCACore
import Observation

/// Something the user can trigger from anywhere in the system.
///
/// The action, not the chord, is what the rest of the app binds to. That
/// separation is the whole point of this file: a hard-coded chord cannot be
/// changed when it collides with another app, and a global hot key collision is
/// not a rare event — ⌥⌘Space is claimed by several launchers, and
/// `RegisterEventHotKey` gives it to whoever asked first with no error the user
/// ever sees.
public enum HotKeyAction: String, CaseIterable, Sendable, Codable {
    case ask
    case toggleVisibility
    case toggleCollapse
    case toggleClickThrough
    case toggleVoice
    case pinWatch

    @MainActor
    public var title: String {
        switch self {
        case .pinWatch:
            return localized("Watch This Window", "このウインドウを見張る", "이 윈도우 지켜보기")
        case .ask: return localized("Ask a Question", "質問する", "질문하기")
        case .toggleVisibility: return localized("Show / Hide the Panel", "パネルの表示 / 非表示", "패널 보기 / 가리기")
        case .toggleCollapse: return localized("Collapse / Restore the Panel", "パネルをたたむ / 戻す", "패널 접기 / 되돌리기")
        case .toggleClickThrough:
            return localized("Let Clicks Pass Through", "クリックを背面に通す", "클릭을 뒤로 통과시키기")
        case .toggleVoice:
            return localized("Start / End a Conversation", "音声での会話の開始 / 終了",
                "음성 대화 시작 / 종료")
        }
    }

    /// One word for a single-line summary, where the full title would not fit.
    @MainActor
    public var shortLabel: String {
        switch self {
        case .ask: return localized("ask", "質問", "질문")
        case .toggleVisibility: return localized("panel", "パネル", "패널")
        case .toggleCollapse: return localized("collapse", "たたむ", "접기")
        case .toggleClickThrough: return localized("click-through", "クリック透過", "클릭 통과")
        case .toggleVoice: return localized("voice", "音声", "음성")
        case .pinWatch: return localized("watch this", "これを見張る", "이것 지켜보기")
        }
    }

    @MainActor
    public var detail: String {
        switch self {
        case .ask:
            return localized(
                "Opens the chat window with the cursor already in the field.",
                "チャットウインドウを開き、入力欄にカーソルを置きます。",
                "채팅 윈도우를 열고 입력란에 커서를 놓습니다.")
        case .toggleVisibility:
            return localized(
                "Takes the panel off the desktop. The agent keeps watching.",
                "パネルをデスクトップから消します。監視は続きます。",
                "패널을 데스크탑에서 치웁니다. 관찰은 계속됩니다.")
        case .toggleCollapse:
            return localized(
                "Shrinks the panel to a thin bar, or puts it back.",
                "パネルを細いバーに縮めます。もう一度押すと元に戻ります。",
                "패널을 얇은 바로 줄이거나 원래대로 되돌립니다.")
        case .toggleClickThrough:
            return localized(
                "When on, clicks pass through to the app behind.",
                "オンにすると、クリックは背面のアプリに素通りします。",
                "켜면 클릭이 뒤쪽 앱으로 그대로 통과합니다.")
        case .toggleVoice:
            return localized(
                "Starts or ends a spoken conversation with the agent.",
                "音声での会話を始めたり終えたりします。",
                "에이전트와의 음성 대화를 시작하거나 끝냅니다.")
        case .pinWatch:
            return localized("""
                Keeps the agent on the window in front — a build, a deploy, a \
                long job — even after you go and work somewhere else. Press \
                again to let it go.
                """, """
                前面のウインドウ（ビルド、デプロイ、時間のかかる処理など）に見守りを固定します。\
                ほかのウインドウで作業しても対象は変わりません。もう一度押すと解除します。
                """, """
                앞쪽 윈도우(빌드, 배포, 오래 걸리는 작업 등)에 지켜보기를 고정합니다. \
                다른 곳에서 작업해도 대상은 바뀌지 않습니다. 다시 누르면 해제됩니다.
                """)
        }
    }

    public var defaultChord: GlobalHotKey.Chord {
        switch self {
        case .ask: return .ask
        case .toggleVisibility: return .toggleVisibility
        case .toggleCollapse: return .toggleCollapse
        case .toggleClickThrough: return .toggleClickThrough
        case .toggleVoice: return .toggleVoice
        case .pinWatch: return .pinWatch
        }
    }
}

/// Why an action currently has no working shortcut.
public enum HotKeyProblem: Sendable, Equatable {
    /// Another application owns the chord; `RegisterEventHotKey` refused it.
    case takenByAnotherApp
    /// Two of our own actions were bound to the same chord.
    case duplicate(of: HotKeyAction)
    /// The user cleared the shortcut. Not an error — the menu bar still works.
    case unassigned
    /// The chord is one macOS reserves for text editing. Refused rather than
    /// registered, because a global claim on ⌘V takes paste from every app.
    case reserved(reason: String)

    @MainActor
    public var displayText: String {
        switch self {
        case .takenByAnotherApp:
            return localized(
                "Already used by another app — pick a different chord",
                "他のアプリが使用中です。別のキーを選んでください",
                "다른 앱이 사용 중입니다. 다른 키를 선택하세요")
        case .duplicate(let other):
            return localized("Same as “\(other.title)”", "「\(other.title)」と重複しています",
                "‘\(other.title)’과(와) 중복됩니다")
        case .unassigned:
            return localized(
                "No shortcut — use the ✨ menu bar item",
                "ショートカットなし。✨ メニューバー項目を使ってください",
                "단축키 없음. ✨ 메뉴 막대 항목을 사용하세요")
        case .reserved(let reason):
            return reason
        }
    }

    /// `unassigned` is a choice, not a fault, so it must not be painted red.
    public var isFault: Bool { self != .unassigned }
}

/// Owns every global shortcut: what it is bound to, whether that binding took,
/// and what it runs.
///
/// Bindings live in `UserDefaults` rather than `config.json` for the same reason
/// the overlay's placement does — the user changes them by pressing keys in a
/// settings window, not by editing a file, and losing them on the next launch
/// would make the whole feature pointless.
@MainActor
@Observable
public final class HotKeyCenter {
    /// Chord currently assigned to each action. `nil` means deliberately
    /// unassigned; the menu bar item still exposes the command.
    public private(set) var bindings: [HotKeyAction: GlobalHotKey.Chord] = [:]
    /// Actions whose shortcut is not working, and why. Surfaced in Settings so
    /// a collision is something the user can see and fix rather than a
    /// mysteriously dead key combination.
    public private(set) var problems: [HotKeyAction: HotKeyProblem] = [:]

    @ObservationIgnored private var handlers: [HotKeyAction: () -> Void] = [:]
    @ObservationIgnored private var hotKeys = GlobalHotKey()
    @ObservationIgnored private let defaults: UserDefaults

    private static func key(for action: HotKeyAction) -> String { "hotkey.\(action.rawValue)" }
    /// Written when the user clears a shortcut, so "cleared" is distinguishable
    /// from "never set" and does not silently come back as the default.
    private static func clearedKey(for action: HotKeyAction) -> String {
        "hotkey.\(action.rawValue).cleared"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Binding

    public func setHandler(_ action: HotKeyAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Assigns a new chord and re-registers everything.
    ///
    /// Re-registers the whole set rather than just this one because Carbon has
    /// no way to release a single chord by value, and because a rebinding can
    /// resolve a *different* action's duplicate at the same time.
    public func rebind(_ action: HotKeyAction, to chord: GlobalHotKey.Chord?) {
        if let chord {
            bindings[action] = chord
            defaults.set(try? JSONEncoder().encode(chord), forKey: Self.key(for: action))
            defaults.set(false, forKey: Self.clearedKey(for: action))
        } else {
            bindings[action] = nil
            defaults.removeObject(forKey: Self.key(for: action))
            defaults.set(true, forKey: Self.clearedKey(for: action))
        }
        apply()
    }

    public func reset(_ action: HotKeyAction) {
        rebind(action, to: action.defaultChord)
    }

    public func resetAll() {
        for action in HotKeyAction.allCases {
            bindings[action] = action.defaultChord
            defaults.removeObject(forKey: Self.key(for: action))
            defaults.set(false, forKey: Self.clearedKey(for: action))
        }
        apply()
    }

    public func chord(for action: HotKeyAction) -> GlobalHotKey.Chord? { bindings[action] }

    /// One line listing the shortcuts that actually work right now. Empty when
    /// none do, so callers can say "use the menu bar" instead of printing a row
    /// of chords that do nothing.
    public var summary: String {
        HotKeyAction.allCases.compactMap { action in
            guard let chord = bindings[action], problems[action]?.isFault != true else {
                return nil
            }
            return "\(chord.displayString) \(action.shortLabel)"
        }.joined(separator: " · ")
    }

    /// Which action already owns `chord`, ignoring `excluding`. Lets the
    /// recorder refuse a duplicate before it is committed rather than
    /// registering it and reporting the failure afterwards.
    public func owner(of chord: GlobalHotKey.Chord, excluding action: HotKeyAction?)
        -> HotKeyAction?
    {
        bindings.first { key, value in
            key != action && value.keyCode == chord.keyCode && value.modifiers == chord.modifiers
        }?.key
    }

    // MARK: - Registration

    /// Drops every claim and re-registers the current bindings, recording which
    /// ones macOS refused.
    public func apply() {
        hotKeys.unregisterAll()
        var found: [HotKeyAction: HotKeyProblem] = [:]
        // Keyed on the chord's *identity to macOS* — key code and modifiers
        // only. The display label is not part of what `RegisterEventHotKey`
        // matches, so two bindings that differ only in label still collide.
        var claimed: [UInt64: HotKeyAction] = [:]

        // Iterated in declaration order, so which action wins a collision is
        // stable across launches rather than dictionary-ordering roulette.
        for action in HotKeyAction.allCases {
            guard let chord = bindings[action] else {
                found[action] = .unassigned
                continue
            }
            // Checked here rather than only where a chord is recorded, because
            // a binding saved before this rule existed is loaded straight from
            // `UserDefaults` and would otherwise still be claimed.
            if let reason = chord.reservedReason {
                found[action] = .reserved(reason: reason)
                continue
            }

            let identity = UInt64(chord.keyCode) << 32 | UInt64(chord.modifiers)
            if let existing = claimed[identity] {
                found[action] = .duplicate(of: existing)
                continue
            }
            // Claimed before the result is known, so a second action on the
            // same chord is reported as the duplicate it is even when macOS
            // refused the first one. Otherwise the two failures compound into a
            // misleading "another app owns it" on a collision we caused.
            claimed[identity] = action

            let registered = hotKeys.register(chord) { [weak self] in
                self?.handlers[action]?()
            }
            if !registered { found[action] = .takenByAnotherApp }
        }
        problems = found
    }

    public func unregisterAll() {
        hotKeys.unregisterAll()
    }

    // MARK: - Persistence

    private func load() {
        for action in HotKeyAction.allCases {
            if defaults.bool(forKey: Self.clearedKey(for: action)) {
                continue
            }
            if let data = defaults.data(forKey: Self.key(for: action)),
               let chord = try? JSONDecoder().decode(GlobalHotKey.Chord.self, from: data) {
                bindings[action] = chord
            } else {
                bindings[action] = action.defaultChord
            }
        }
    }
}
