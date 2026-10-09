import AppKit
import Foundation
import MCACore
import MCAReasoning

/// Approver for the app: asks in the chat, under the question being answered.
///
/// Not a modal alert. `NSAlert.runModal()` held the main thread for as long as
/// the alert was up, so an alert that opened behind the browser or on another
/// display left the chat showing "Thinking" with nothing to answer: the stop
/// button could not run and the task deadline could not fire. In the chat the
/// request sits where the user is already looking, the stop button cancels it,
/// it expires on its own, and the deadline sees it as time spent waiting.
struct ChatToolApprover: ToolApproving {
    let present: @MainActor @Sendable (ActionApprovalRequest) async -> ActionApprovalStatus

    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await Self.ask(request, present: present)
    }

    @MainActor
    private static func ask(
        _ request: ToolApprovalRequest,
        present: @MainActor @Sendable (ActionApprovalRequest) async -> ActionApprovalStatus
    ) async -> ToolApprovalDecision {
        // Taken before the chat comes forward: an approved keystroke must still
        // land in the app it was approved for, not in this one.
        let previous = NSWorkspace.shared.frontmostApplication
        let status = await present(ActionApprovalRequest(
            goal: localized(
                "The assistant wants to do the following. Check it before allowing.",
                "アシスタントが次の操作を実行しようとしています。内容を確認してください。",
                "어시스턴트가 다음 작업을 실행하려고 합니다. 내용을 확인하세요."),
            operation: request.title,
            target: request.warning ?? request.toolName,
            details: request.detail,
            consequence: localized(
                "Approving runs exactly what is shown above.",
                "承認すると、上に表示された内容がそのまま実行されます。",
                "승인하면 위에 표시된 내용이 그대로 실행됩니다.")))
        switch status {
        case .approved:
            restoreFocus(to: previous)
            return .approved
        case .rejected:
            return .denied(reason: "the user declined")
        case .expired:
            return .denied(reason: "nobody answered the approval request in time")
        case .pending, .cancelled, .invalidated:
            return .denied(reason: "the approval request was cancelled")
        }
    }

    /// Activation is asynchronous, so wait (briefly) until it took effect.
    private static func restoreFocus(to app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else { return }
        app.activate()
        let deadline = Date().addingTimeInterval(1)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

/// Approver for `mca ask`: a y/N prompt on the terminal, and a refusal when
/// there is no terminal to ask on (piped input, launchd, CI).
struct TerminalToolApprover: ToolApproving {
    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        guard isatty(STDIN_FILENO) != 0 else {
            return .denied(reason: "stdin is not a terminal, so the user cannot be asked")
        }
        var text = "\n[approval needed] \(request.title)\n"
        if let warning = request.warning { text += "  ! \(warning)\n" }
        text += request.detail.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  | \($0)" }.joined(separator: "\n")
        text += "\nAllow? [y/N] "
        FileHandle.standardError.write(Data(text.utf8))
        let answer = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes" ? .approved : .denied(reason: "the user declined")
    }
}
