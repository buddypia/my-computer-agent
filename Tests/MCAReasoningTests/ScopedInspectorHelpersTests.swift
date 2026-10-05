import Foundation
import MCACore
import MCASensing
import Testing

@Suite("Pinned inspector public helper scope")
struct ScopedInspectorHelpersTests {
    private actor Calls { var count = 0; func add() { count += 1 } }
    @Test("Invalid selected identity never reaches an unrelated foreground fallback")
    func invalidSelectedIdentity() async {
        let calls = Calls()
        let selected = PinnedWindow(id: UInt32.max, appName: "Owned fixture", windowTitle: "Missing",
            processID: ProcessInfo.processInfo.processIdentifier)
        let inspector = AccessibilityInspector(fallbackProvider: { _, _ in await calls.add(); return [] },
            targetWindow: selected, requiresWindowScope: true)
        #expect(inspector.inspectFocusedWindow().isEmpty)
        #expect(await inspector.inspectFocusedWindowAsync().isEmpty)
        #expect(await inspector.inspectFocusedWindowAsync(targetPID: 1).isEmpty)
        #expect(await calls.count == 0)
    }
}
