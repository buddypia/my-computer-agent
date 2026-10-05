import AppKit
import Foundation
import MCACore
import MCAReasoning

/// A modal alert that shows the exact thing about to happen.
///
/// The first button is the default (it answers Return) and is always the
/// refusal: an agent that can be steered by on-screen text must not be one
/// stray keypress away from running what it was steered to.
@MainActor
enum ConfirmationAlert {
    /// - Returns: the index into `buttons` that was clicked.
    static func present(
        title: String,
        message: String,
        detail: String,
        buttons: [String]
    ) -> Int {
        // The alert has to take focus to be answered, and an approved keystroke
        // must still land in the app it was approved for, not in this one.
        let previous = NSWorkspace.shared.frontmostApplication
        defer { restoreFocus(to: previous) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = detail
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        alert.accessoryView = scroll

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? index : 0
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

/// Approver for the app: asks the user in a modal alert.
struct AlertToolApprover: ToolApproving {
    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        let approved = await MainActor.run {
            ConfirmationAlert.present(
                title: request.title,
                message: [
                    localized(
                        "The assistant wants to do the following. Check it before allowing.",
                        "アシスタントが次の操作を実行しようとしています。内容を確認してください。",
                        "어시스턴트가 다음 작업을 실행하려고 합니다. 내용을 확인하세요."),
                    request.warning,
                ].compactMap { $0 }.joined(separator: "\n"),
                detail: request.detail,
                buttons: [
                    localized("Don't Allow", "許可しない", "허용 안 함"),
                    localized("Allow", "許可", "허용"),
                ]) == 1
        }
        return approved ? .approved : .denied(reason: "the user declined")
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
