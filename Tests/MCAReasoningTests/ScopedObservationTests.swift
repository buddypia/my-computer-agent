import Foundation
import MCACore
import MCAReasoning
import Testing

@Suite("Selected window observation scope")
struct ScopedObservationTests {
    @Test("Missing display-local target refuses before inspecting foreground or OCR")
    func missingScope() async {
        let session = ActionAuthorization(goal: "Read selected display", requestApproval: { _ in .rejected },
            targetWindow: nil, requiresWindowScope: true)
        _ = await ActionAuthorization.withSession(session) {
            await #expect(throws: (any Error).self) {
                _ = try await InspectUIElementsTool.makeDefaultInspector().captureSnapshot()
            }
            #expect(await InspectUIElementsTool.makeDefaultInspector().inspectFocusedWindowAsync().isEmpty)
            #expect(InspectUIElementsTool.makeDefaultInspector().inspectFocusedWindow().isEmpty)
        }
    }

    @Test("An invalid selected window cannot fall back to another application", arguments: [nil, ProcessInfo.processInfo.processIdentifier])
    func invalidScopeNeverReadsForeground(pid: pid_t?) async throws {
        let target = PinnedWindow(id: UInt32.max, appName: "Selected fixture", windowTitle: "Unavailable",
                                  bundleID: "fixture.unavailable", processID: pid)
        let session = ActionAuthorization(goal: "Read selected window", requestApproval: { _ in .rejected },
                                          targetWindow: target, requiresWindowScope: true)
        _ = await ActionAuthorization.withSession(session) {
            await #expect(throws: (any Error).self) {
                _ = try await InspectUIElementsTool.makeDefaultInspector().captureSnapshot()
            }
        }
    }
}
