import AppKit
import MCACore
import SwiftUI

/// One turn of the conversation, drawn the same way wherever it appears.
///
/// Shared by all three surfaces — the chat window, the desktop panel and the
/// menu bar popover — because they are three views of one thread and looking
/// like three different applications was the bug. Only the text size changes:
/// the popover is 380 points wide and reads at a glance, the chat window is read
/// properly.
public struct MessageBubble: View {
    private let message: ChatMessage
    private let textSize: CGFloat
    private let isSelected: Bool
    private let onAction: ((String, String) -> Void)?
    private let onApproval: ((UUID, Bool) -> Void)?

    public init(
        _ message: ChatMessage,
        textSize: CGFloat = 13,
        isSelected: Bool = false,
        onAction: ((String, String) -> Void)? = nil,
        onApproval: ((UUID, Bool) -> Void)? = nil
    ) {
        self.message = message
        self.textSize = textSize
        self.isSelected = isSelected
        self.onAction = onAction
        self.onApproval = onApproval
    }

    public var body: some View {
        if message.role == .user {
            fromTheUser
        } else {
            fromTheAgent
        }
    }

    /// Right-aligned and left as typed. The user's own words are not a document
    /// to render — turning their `*` into emphasis would rewrite what they said
    /// back at them.
    private var fromTheUser: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(.system(size: textSize))
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay { selectionOutline }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var fromTheAgent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let badge = message.badge {
                HStack(spacing: 4) {
                    if let symbol = message.badgeSymbol {
                        Image(systemName: symbol).font(.system(size: textSize - 4))
                    }
                    Text(badge)
                        .font(.system(size: textSize - 3, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(message.timestamp, style: .time)
                        .font(.system(size: textSize - 4))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(message.tint)
            }
            if message.showsTitleLine, let title = message.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: textSize - 1, weight: .semibold))
                    .textSelection(.enabled)
            }
            if let request = message.approval {
                // Approval payloads must show every byte; Markdown can hide table cells,
                // links and comment delimiters. Execution retains the original request.
                Text(verbatim: ApprovalText.visible(request.details, keepingLineBreaks: true))
                    .font(.system(size: textSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: ApprovalText.visible(request.goal)).font(.system(size: textSize - 1, weight: .medium))
                    Text(verbatim: ApprovalText.visible(request.operation))
                    Text(verbatim: ApprovalText.visible(request.target)).textSelection(.enabled)
                    Text(verbatim: ApprovalText.visible(request.consequence)).foregroundStyle(.secondary)
                    if message.approvalStatus == .pending {
                        HStack {
                            Button(localized("Approve this operation", "この操作を承認", "이 작업 승인")) {
                                // A held shortcut must not resolve a newly displayed operation.
                                if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
                                onApproval?(request.id, true)
                            }
                            .keyboardShortcut("a", modifiers: [.command, .shift])
                            .help(localized("Approve this operation (⇧⌘A)", "この操作を承認（⇧⌘A）", "이 작업 승인 (⇧⌘A)"))
                            Button(localized("Reject", "拒否", "거부")) {
                                if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
                                onApproval?(request.id, false)
                            }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                            .help(localized("Reject this operation (⇧⌘R)", "この操作を拒否（⇧⌘R）", "이 작업 거부 (⇧⌘R)"))
                        }
                        .disabled(onApproval == nil)
                    } else {
                        Text(approvalStatusText).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: textSize - 1))
                .padding(.top, 5)
            } else {
                MarkdownText(message.text, size: textSize)
            }

            if let actionTitle = message.actionTitle, let payload = message.actionPayload {
                // The button label is the model's wording; the payload is what
                // actually gets typed. Showing both keeps a friendly label from
                // hiding a different command.
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Will type:", "入力される内容:", "입력될 내용:"))
                        .font(.system(size: textSize - 3))
                        .foregroundStyle(.secondary)
                    Text(payload)
                        .font(.system(size: textSize - 2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .padding(.top, 4)
                HStack {
                    Button {
                        onAction?(payload, actionTitle)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: textSize - 3))
                            Text(actionTitle)
                                .font(.system(size: textSize - 2, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay { selectionOutline }
        .overlay(alignment: .leading) {
            // The stripe says at a glance which turns the user did not ask for.
            // An answer needs no marking: it is the default thing in a thread.
            if message.role != .assistant {
                Rectangle()
                    .fill(message.tint)
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
    }

    private var approvalStatusText: String {
        switch message.approvalStatus {
        case .approved: return localized("Approved", "承認済み", "승인됨")
        case .rejected: return localized("Rejected", "拒否しました", "거부됨")
        case .expired: return localized("Expired", "期限切れ", "만료됨")
        case .invalidated: return localized("Target changed", "対象が変わったため無効", "대상이 변경되어 무효")
        default: return localized("Cancelled", "停止しました", "취소됨")
        }
    }

    /// An outline rather than a tinted background: the bubbles are already
    /// tinted by role, and a second colour over the top makes an error look like
    /// a normal answer at a glance.
    @ViewBuilder private var selectionOutline: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
        }
    }
}

/// The answer while it is still arriving.
///
/// Shaped like the bubble it becomes, so the reply does not visibly reflow the
/// moment it completes.
public struct ThinkingBubble: View {
    private let text: String
    private let textSize: CGFloat

    public init(_ text: String, textSize: CGFloat = 13) {
        self.text = text
        self.textSize = textSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(localized("Thinking", "考えています", "생각 중"))
                    .font(.system(size: textSize - 2, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: textSize))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11))
    }
}
