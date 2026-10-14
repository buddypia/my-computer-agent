import CoreGraphics
import Foundation
import MCACore
import MCAMemory
import MCAPerception
import MCAPresentation
import MCAReasoning
import MCASensing
@testable import mca
import os
import Testing

private actor MockWatchStore: ContextStoring {
    func append(_ observation: DesktopObservation) {}
    func search(_ query: ContextQuery) -> [ScoredObservation] { [] }
    func recent(seconds: TimeInterval, limit: Int) -> [DesktopObservation] { [] }
    func purge(olderThan days: Int) -> Int { 0 }
    func count() -> Int { 0 }
}

@Suite("ScreenWatcher & Watchdog Empirical Stress Tests", .serialized)
struct ScreenWatcherWatchdogStressTests {

    @Test("MainThreadWatchdog is never triggered during ScreenWatcher.tick() cycles")
    @MainActor
    func testScreenWatcherTickDoesNotTriggerWatchdogIsolated() async throws {
        let state = HUDState()
        let store = MockWatchStore()
        let router = ModelRouter(policy: .default, credentials: CredentialStore(environment: [:]))
        let agent = Agent(router: router, store: store, tools: ToolRegistry(), health: HealthRegistry())
        let reader = AccessibilityReader(traversalBudget: 0.2)
        let watcher = ScreenWatcher(
            state: state,
            agent: agent,
            store: store,
            router: router,
            capturer: ScreenCapturer(),
            recognizer: TextRecognizer(),
            reader: reader,
            configuration: AgentConfiguration()
        )

        let hangTriggered = OSAllocatedUnfairLock(initialState: false)
        let watchdog = MainThreadWatchdog(
            targetQueue: .main,
            timeoutSeconds: 2,
            pollIntervalSeconds: 1,
            onHang: { _ in
                hangTriggered.withLock { $0 = true }
            }
        )

        watchdog.start()
        defer { watchdog.stop() }

        state.watchPhase = .watching

        // Execute multiple tick cycles on MainActor
        for _ in 0..<5 {
            await watcher.tick()
            try await Task.sleep(for: .milliseconds(20))
        }

        let didHang = hangTriggered.withLock { $0 }
        if IsolatedTiming.enabled {
            #expect(!didHang, "ScreenWatcher.tick() blocked the main thread and tripped MainThreadWatchdog!")
        }
    }

    @Test("Main actor remains responsive while tick is executing")
    @MainActor
    func testMainActorResponsivenessDuringTickIsolated() async throws {
        let state = HUDState()
        let store = MockWatchStore()
        let router = ModelRouter(policy: .default, credentials: CredentialStore(environment: [:]))
        let agent = Agent(router: router, store: store, tools: ToolRegistry(), health: HealthRegistry())
        let watcher = ScreenWatcher(
            state: state,
            agent: agent,
            store: store,
            router: router,
            capturer: ScreenCapturer(),
            recognizer: TextRecognizer(),
            reader: AccessibilityReader(traversalBudget: 0.5),
            configuration: AgentConfiguration()
        )

        state.watchPhase = .watching

        // Concurrently run tick while measuring main actor responsiveness
        let tickTask = Task { @MainActor in
            await watcher.tick()
        }

        // Check if an immediate main actor closure runs promptly
        let start = DispatchTime.now()
        let closureRan = await MainActor.run {
            state.watchPhase = .watching
            return true
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        #expect(closureRan)
        let maxElapsedMs = IsolatedTiming.enabled ? 1000.0 : 15_000.0
        #expect(elapsedMs < maxElapsedMs, "MainActor execution was delayed by \(elapsedMs)ms during ScreenWatcher tick")

        await tickTask.value
    }

    @Test("FrameFingerprint.computeAsync parallel stress with large frames")
    func testFrameFingerprintParallelStress() async {
        // Generate a 4K test pattern
        let width = 3840
        let height = 2160
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(gray: 0.4, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let testImage = context.makeImage()!

        await withTaskGroup(of: String?.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let mask = CGRect(x: 100 * i, y: 100, width: 200, height: 100)
                    return await FrameFingerprint.computeAsync(testImage, masking: [mask])
                }
            }

            var count = 0
            for await fp in group {
                #expect(fp != nil)
                #expect(fp?.count == 64)
                count += 1
            }
            #expect(count == 20)
        }
    }
}
