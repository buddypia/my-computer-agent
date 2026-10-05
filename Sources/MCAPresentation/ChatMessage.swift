import Foundation
import MCACore
import SwiftUI

/// One turn of the conversation.
///
/// Everything the user and the agent say ends up here, in order — including the
/// app's own notices, which used to live in a second list of their own. One
/// timeline is what lets the panel, the popover and the chat window show the
/// same thing: two surfaces built over two lists disagreed about what had
/// happened, which from the outside is indistinguishable from a bug.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable {
        case user
        case assistant
        /// The agent speaking without being asked, from watching the screen.
        /// Distinguished from `.assistant` so the user can always tell which of
        /// the two happened — an answer they asked for, or an interruption.
        case watch
        /// A failure worth reading. Kept in the thread rather than shown as an
        /// alert so the conversation still records what went wrong and when.
        case failure
        /// The app itself talking about itself: a session that started, a key
        /// that is missing, a shortcut another application owns. Not the agent,
        /// which is why it is not `.assistant`.
        case notice
    }

    public var id: UUID
    /// Optional headline. The watch and the notices set one — an answer to a
    /// question the user just typed does not need a title restating it.
    public var title: String?
    public var text: String
    public var role: Role
    /// How loud a notice is. Carries the colour and the glyph, and is `nil`
    /// wherever the role already decides both.
    public var severity: HUDCard.Severity?
    public var timestamp: Date

    /// Name or title of the screen/window this turn originated from.
    public var originTarget: String?
    /// Identifier of the WatchRole.
    public var roleId: String?
    /// Display name of the WatchRole (e.g. "ミーティング支援", "AI CLI開発監視").
    public var roleName: String?
    /// Symbol or emoji icon of the WatchRole.
    public var roleIcon: String?
    /// Optional action title for quick interaction in HUD (e.g. "承認 (y を送信)").
    public var actionTitle: String?
    /// Optional action payload (e.g. keystroke or command to execute).
    public var actionPayload: String?
    public var approval: ActionApprovalRequest?
    public var approvalStatus: ActionApprovalStatus?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        title: String? = nil,
        severity: HUDCard.Severity? = nil,
        timestamp: Date = Date(),
        originTarget: String? = nil,
        roleId: String? = nil,
        roleName: String? = nil,
        roleIcon: String? = nil,
        actionTitle: String? = nil,
        actionPayload: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.title = title
        self.severity = severity
        self.timestamp = timestamp
        self.originTarget = originTarget
        self.roleId = roleId
        self.roleName = roleName
        self.roleIcon = roleIcon
        self.actionTitle = actionTitle
        self.actionPayload = actionPayload
    }

    /// Converts this ChatMessage into a ConversationTurn if it represents a dialog turn (user or assistant).
    public func toConversationTurn() -> ConversationTurn? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        switch role {
        case .user:
            return ConversationTurn(role: .user, text: cleanText, timestamp: timestamp)
        case .assistant, .watch:
            return ConversationTurn(role: .assistant, text: cleanText, timestamp: timestamp)
        case .failure, .notice:
            return nil
        }
    }
}

/// How far along the periodic screen watch is.
///
/// Three states rather than a boolean for the same reason `VoicePhase` has
/// three: a request in flight takes seconds, and collapsing that into "on" makes
/// a watch that is silently failing look identical to one that is quietly
/// deciding there is nothing to say.
public enum ScreenWatchPhase: Sendable, Equatable {
    case off
    case watching
    case looking
}

/// How often the watch samples the screen.
///
/// Presets rather than a free number: the interval trades money and interruption
/// against freshness, and neither end of a text field is a choice anyone can
/// make well. Fifteen seconds is for actively working through something with the
/// agent looking over your shoulder; two minutes is for leaving it on all day.
public enum ScreenWatchInterval: Int, CaseIterable, Sendable, Codable {
    case quick = 15
    case normal = 45
    case relaxed = 120

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    @MainActor
    public var title: String {
        switch self {
        case .quick: return localized("Every 15s", "15秒ごと", "15초마다")
        case .normal: return localized("Every 45s", "45秒ごと", "45초마다")
        case .relaxed: return localized("Every 2min", "2分ごと", "2분마다")
        }
    }
}

extension ChatMessage {
    /// The one colour that marks this turn: the stripe down its edge, the badge
    /// above it, and the tick when it is selected.
    var tint: Color {
        switch role {
        case .user: return .accentColor
        case .assistant: return .cyan
        case .watch: return .mint
        case .failure: return .orange
        case .notice: return (severity ?? .info).tint
        }
    }

    /// The tinted line above the body, naming what kind of turn this is.
    ///
    /// A notice puts its own headline here rather than on a line of its own:
    /// "お知らせ" above "音声を使うにはキーが必要です" is a label restating that a
    /// label follows, and the headline is the part worth reading.
    @MainActor
    var badge: String? {
        switch role {
        case .user, .assistant: return nil
        case .watch:
            if let roleName, let originTarget {
                return "\(roleName) — \(originTarget)"
            } else if let roleName {
                return roleName
            } else if let originTarget {
                return "\(localized("From", "対象", "대상")): \(originTarget)"
            }
            return localized("From your screen", "画面を見て", "화면을 보고")
        case .failure: return localized("Failed", "失敗", "실패")
        case .notice:
            if let title, !title.isEmpty { return title }
            return localized("Notice", "お知らせ", "알림")
        }
    }

    var badgeSymbol: String? {
        switch role {
        case .user, .assistant: return nil
        case .watch:
            return roleIcon ?? "eye.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .notice: return (severity ?? .info).symbol
        }
    }

    /// Whether `title` is drawn on a line of its own. A notice has already spent
    /// it on the badge.
    var showsTitleLine: Bool { role != .notice }
}
