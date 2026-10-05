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
