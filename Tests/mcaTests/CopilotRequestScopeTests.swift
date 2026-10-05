import MCACore
@testable import mca
import Testing

@Suite("Copilot request target resolution")
@MainActor
struct CopilotRequestScopeTests {
    let display = WatchTarget.display(PinnedDisplay(id: 42, name: "Shared monitor", width: 1920, height: 1080))
    let local = PinnedWindow(id: 81, appName: "Local fixture", windowTitle: "Unrelated", processID: 123)

    @Test("Implicit HUD and explicit display targets retain the selected display", arguments: [false, true])
    func displayScope(explicit: Bool) async {
        var calls = 0
        let result = await Copilot.resolveRequestTarget(target: explicit ? display : nil, hudTarget: display) {
            calls += 1
            return local
        }
        #expect(calls == 0)
        #expect(result.window == nil)
        #expect(result.subject == display)
    }

    @Test("Pinned window never consults the foreground resolver", arguments: [false, true])
    func windowScope(explicit: Bool) async {
        var calls = 0
        let result = await Copilot.resolveRequestTarget(target: explicit ? .pinned(local) : nil,
            hudTarget: explicit ? display : .pinned(local)) {
            calls += 1
            return nil
        }
        #expect(calls == 0)
        #expect(result.window == local)
        #expect(result.subject == .pinned(local))
    }

    @Test("Focused resolution uses one resolver result and retains unavailable scope")
    func focusedScope() async {
        var calls = 0
        let available = await Copilot.resolveRequestTarget(target: .focused, hudTarget: display) {
            calls += 1
            return local
        }
        #expect(calls == 1)
        #expect(available.window == local)
        #expect(available.subject == .pinned(local))
        let unavailable = await Copilot.resolveRequestTarget(target: nil, hudTarget: .focused) { nil }
        #expect(unavailable.window == nil)
        #expect(unavailable.subject == .focused)
    }
}
