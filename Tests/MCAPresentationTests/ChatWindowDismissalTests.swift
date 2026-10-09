import AppKit
import MCACore
import Testing

@testable import MCAPresentation

@Suite("Chat window dismissal", .serialized)
@MainActor
struct ChatWindowDismissalTests {
    @Test("closing chat removes its Quartz surface before desktop input resumes")
    func closeRemovesInputObstruction() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }
        chat.present()
        // Quartz lists a new surface asynchronously, later still under the
        // loaded parallel suite: wait for it (up to 5 s), not for a fixed time.
        var shown: Int?
        for _ in 0..<100 where shown.map({ !surfaceIsVisible($0) }) ?? true {
            try await Task.sleep(for: .milliseconds(50))
            shown = NSApp.windows.first { $0.isVisible && $0.delegate === chat }?.windowNumber
        }
        let number = try #require(shown)
        #expect(surfaceIsVisible(number))

        let removed = await chat.closeAndWaitForSurfaceRemoval()
        let remainingSurfaces = visibleSurfaceNames(number)
        #expect(removed, "ChatWindow did not confirm removal from Quartz")
        #expect(remainingSurfaces.isEmpty, "Quartz still lists matching surfaces: \(remainingSurfaces)")
        #expect(!chat.isOpen)
        #expect(!state.isChatOpen)
    }

    @Test("an approval brings the chat forward without a caret in the input field")
    func approvalDoesNotFocusInput() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }
        // Opened by the user first, so the field holds the caret when it closes.
        chat.present()
        try await Task.sleep(for: .milliseconds(300))
        chat.close()

        chat.presentForApproval()
        let approval = Task { await state.requestApproval(ActionApprovalRequest(
            goal: "g", operation: "Desktop: scroll", target: "t", details: "d", consequence: "c")) }
        // Long enough for SwiftUI to re-apply focus if it were going to.
        try await Task.sleep(for: .milliseconds(300))
        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        #expect(chat.isOpen)
        #expect(!(window.firstResponder is NSTextView), "the input field took the caret under an approval")
        state.cancelPendingApprovals()
        #expect(await approval.value == .cancelled)
    }

    @Test("an approval that first creates the chat window does not focus the input field")
    func approvalOnFreshWindowDoesNotFocusInput() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }
        chat.presentForApproval()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        // `onAppear` runs on a later pass; give it every chance to take the caret.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            #expect(!(window.firstResponder is NSTextView), "the input field took the caret under an approval")
        }
    }

    @Test("a user-opened chat still puts the caret in the input field")
    func presentFocusesInput() async throws {
        _ = NSApplication.shared
        let state = HUDState()
        let chat = ChatWindow(state: state)
        defer { chat.destroy() }
        chat.present()
        let window = try #require(NSApp.windows.first { $0.delegate === chat })
        var focused = false
        for _ in 0..<40 where !focused {
            try await Task.sleep(for: .milliseconds(50))
            focused = window.firstResponder is NSTextView
        }
        #expect(focused)
    }

    private func surfaceIsVisible(_ number: Int) -> Bool {
        !visibleSurfaceNames(number).isEmpty
    }

    private func visibleSurfaceNames(_ number: Int) -> [String] {
        let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid(),
                  (entry[kCGWindowNumber as String] as? NSNumber)?.intValue == number else { return nil }
            return entry[kCGWindowName as String] as? String ?? "<unnamed>"
        }
    }
}
