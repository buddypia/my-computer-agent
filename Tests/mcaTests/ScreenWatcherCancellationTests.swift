import Foundation
import MCACore
import MCAMemory
import MCAPerception
import MCAPresentation
import MCAReasoning
import MCASensing
@testable import mca
import Testing

private actor EmptyWatchStore: ContextStoring {
    func append(_ observation: DesktopObservation) {}
    func search(_ query: ContextQuery) -> [ScoredObservation] { [] }
    func recent(seconds: TimeInterval, limit: Int) -> [DesktopObservation] { [] }
    func purge(olderThan days: Int) -> Int { 0 }
    func count() -> Int { 0 }
}

@Suite("Screen watch action cancellation")
@MainActor
struct ScreenWatcherCancellationTests {
    @Test("Stop cancels a queued advice action before it can start another task")
    func stopQueuedAction() async throws {
        let state = HUDState(), store = EmptyWatchStore()
        let router = ModelRouter(policy: .default, credentials: CredentialStore(environment: [:]))
        let agent = Agent(router: router, store: store, tools: ToolRegistry(), health: HealthRegistry())
        let watcher = ScreenWatcher(state: state, agent: agent, store: store, router: router,
            capturer: ScreenCapturer(), recognizer: TextRecognizer(), reader: AccessibilityReader(),
            configuration: AgentConfiguration())
        var dispatched = false
        watcher.onRequestedAction = { _, _ in dispatched = true }
        state.onExecuteAction?("Click Delete", nil)
        watcher.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!dispatched)
    }
}
