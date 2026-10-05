import Foundation
import MCACore
import MCAMemory
import Testing
@testable import MCAReasoning

private actor ScopedReaderStore: ContextStoring {
    var reads = 0
    func append(_ observation: DesktopObservation) async throws {}
    func search(_ query: ContextQuery) async throws -> [ScoredObservation] { [] }
    func recent(seconds: TimeInterval, limit: Int) async throws -> [DesktopObservation] {
        reads += 1
        return [.screen(ScreenObservation(appName: "Unrelated fixture", windowTitle: "Other screen",
            text: "STORE_SENTINEL", source: .accessibility, trigger: .focusChanged))]
    }
    func purge(olderThan days: Int) async throws -> Int { 0 }
    func count() async throws -> Int { 0 }
}
private actor ReaderCalls { var count = 0; func add() { count += 1 } }
@Suite("Scoped current-screen reader")
struct ScopedScreenReaderTests {
    @Test("A display-bound session cannot read unrelated live or stored context", arguments: [false, true])
    func missingWindow(_ returnsText: Bool) async throws {
        let store = ScopedReaderStore(), calls = ReaderCalls()
        let tool = CurrentScreenTool(store: store, liveReader: {
            await calls.add()
            return returnsText ? "LIVE_SENTINEL" : nil
        })
        let session = ActionAuthorization(goal: "Read selected display", requestApproval: { _ in .rejected },
            targetWindow: nil, requiresWindowScope: true)
        let result = try await ActionAuthorization.withSession(session) { try await tool.invoke(arguments: Data()) }
        #expect(result.contains("Error: selected window"))
        #expect(!result.contains("SENTINEL"))
        #expect(await calls.count == 0)
        #expect(await store.reads == 0)
    }
}
