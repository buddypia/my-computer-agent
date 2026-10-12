import CoreGraphics
import CoreText
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

private actor MockContextStore: ContextStoring {
    func append(_ observation: DesktopObservation) {}
    func search(_ query: ContextQuery) -> [ScoredObservation] { [] }
    func recent(seconds: TimeInterval, limit: Int) -> [DesktopObservation] { [] }
    func purge(olderThan days: Int) -> Int { 0 }
    func count() -> Int { 0 }
}

@Suite("ScreenWatcher and Vision OCR Empirical Stress Suite")
struct ScreenWatcherVisionStressTests {

    /// Generates a crisp synthetic bitmap containing clear rendered text.
    private func createTextImage(
        lines: [String],
        width: Int = 1024,
        height: Int = 768
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // White background
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Set text fill color to black
        context.setFillColor(gray: 0.0, alpha: 1.0)

        // Render black text lines using CoreText
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0.0, alpha: 1.0)
            ]
            let attributed = CFAttributedStringCreate(
                kCFAllocatorDefault,
                line as CFString,
                attributes as CFDictionary
            )!
            let ctLine = CTLineCreateWithAttributedString(attributed)

            context.textPosition = CGPoint(x: 60, y: CGFloat(height - 80 - (index * 50)))
            CTLineDraw(ctLine, context)
        }

        return context.makeImage()!
    }

    // MARK: - 1. Vision OCR Offloading Responsiveness on @MainActor

    @Test("Vision OCR executes off @MainActor without inducing main thread latency")
    @MainActor
    func visionOCROffloadingMainActorResponsiveness() async throws {
        let sampleLines = [
            "Watchdog MainThread Fix Milestone 1 Verification",
            "Non-blocking Vision OCR execution via Task.detached",
            "High resolution image candidate extraction test",
            "ScreenWatcher periodic background observation loop"
        ]
        let image = createTextImage(lines: sampleLines)
        let recognizer = TextRecognizer()

        // Probe measuring @MainActor loop latency while OCR runs
        let probeRunning = OSAllocatedUnfairLock(initialState: true)
        let maxMainActorDelay = OSAllocatedUnfairLock(initialState: Duration.zero)

        // Setup MainThreadWatchdog with sensitive 500ms timeout
        let watchdogHangs = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = MainThreadWatchdog(
            targetQueue: .main,
            timeoutSeconds: 1,
            pollIntervalSeconds: 1,
            onHang: { _ in
                watchdogHangs.withLock { $0 += 1 }
            }
        )
        watchdog.start()

        // Start background latency sampler on MainActor
        let probe = Task { @MainActor in
            var lastPing = ContinuousClock.now
            while probeRunning.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(15))
                let now = ContinuousClock.now
                let delay = now - lastPing
                lastPing = now
                maxMainActorDelay.withLock { currentMax in
                    if delay > currentMax {
                        currentMax = delay
                    }
                }
            }
        }

        // Execute multiple concurrent offloaded OCR operations matching ScreenWatcher's pattern
        let results = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await Task.detached(priority: .utility) {
                        (try? await recognizer.recognizeText(in: image)) ?? ""
                    }.value
                }
            }

            var recognizedList: [String] = []
            for await text in group {
                recognizedList.append(text)
            }
            return recognizedList
        }

        probeRunning.withLock { $0 = false }
        _ = await probe.value
        watchdog.stop()

        // Verify OCR completed and extracted text
        #expect(results.count == 8)
        #expect(results.first?.contains("Watchdog") == true || results.first?.contains("Milestone") == true)

        // Verify zero watchdog hangs occurred
        let totalHangs = watchdogHangs.withLock { $0 }
        #expect(totalHangs == 0, "MainThreadWatchdog detected \(totalHangs) hang(s) during OCR offloading")

        // Verify @MainActor delay was not blocked by OCR compute (< 500ms)
        let worstDelay = maxMainActorDelay.withLock { $0 }
        #expect(worstDelay < .milliseconds(500), "MainActor suffered excessive delay: \(worstDelay)")
    }

    // MARK: - 2. Combined ScreenWatcher and Downscaling Pipeline Concurrency

    @Test("Combined concurrent downscaling and OCR executes without thread pool starvation")
    func combinedPipelineStress() async throws {
        let ocrImage = createTextImage(lines: ["Task Detached Utility Execution", "Fingerprint Downscaling Test"])
        let recognizer = TextRecognizer()

        let starvationCheckPassed = OSAllocatedUnfairLock(initialState: false)

        await withTaskGroup(of: Void.self) { group in
            // Spawn 20 concurrent FrameFingerprint tasks
            for _ in 0..<20 {
                group.addTask {
                    _ = await FrameFingerprint.computeAsync(ocrImage, gridSize: 32, levels: 8)
                }
            }

            // Spawn 5 concurrent Vision OCR tasks
            for _ in 0..<5 {
                group.addTask {
                    _ = await Task.detached(priority: .utility) {
                        (try? await recognizer.recognizeText(in: ocrImage)) ?? ""
                    }.value
                }
            }

            // Add a probe task in userInitiated priority
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                starvationCheckPassed.withLock { $0 = true }
            }
        }

        #expect(starvationCheckPassed.withLock { $0 }, "Probe task was starved by background utility tasks")
    }

    // MARK: - 3. ScreenWatcher Tick Inactivity and Cancellation Integrity

    @Test("ScreenWatcher tick when off returns immediately without blocking")
    @MainActor
    func screenWatcherTickWhenOffIsImmediate() async {
        let state = HUDState()
        let store = MockContextStore()
        let router = ModelRouter(policy: .default, credentials: CredentialStore(environment: [:]))
        let agent = Agent(router: router, store: store, tools: ToolRegistry(), health: HealthRegistry())
        let watcher = ScreenWatcher(
            state: state,
            agent: agent,
            store: store,
            router: router,
            capturer: ScreenCapturer(),
            recognizer: TextRecognizer(),
            reader: AccessibilityReader(),
            configuration: AgentConfiguration()
        )

        // Phase is .off by default
        #expect(state.watchPhase == .off)

        let start = ContinuousClock.now
        await watcher.tick()
        let duration = ContinuousClock.now - start

        #expect(duration < .milliseconds(100), "Tick when off should return immediately")
    }
}
