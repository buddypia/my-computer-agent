import CoreGraphics
import Foundation
import os
import Testing

@testable import MCASensing

@Suite("FrameFingerprint Stress and Empirical Adversarial Suite")
struct FrameFingerprintStressTests {

    /// Generates synthetic RGB test image with configurable dimensions and content.
    private func createTestImage(
        width: Int,
        height: Int,
        pattern: ImagePattern
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

        switch pattern {
        case .solid(let gray):
            context.setFillColor(gray: gray, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        case .gradient:
            for y in 0..<height {
                let v = CGFloat(y) / CGFloat(max(1, height))
                context.setFillColor(red: v, green: 1.0 - v, blue: 0.5, alpha: 1.0)
                context.fill(CGRect(x: 0, y: y, width: width, height: 1))
            }

        case .stripes(let stripeHeight):
            for y in stride(from: 0, to: height, by: stripeHeight * 2) {
                context.setFillColor(gray: 0.0, alpha: 1.0)
                context.fill(CGRect(x: 0, y: y, width: width, height: min(stripeHeight, height - y)))
                let nextY = y + stripeHeight
                if nextY < height {
                    context.setFillColor(gray: 1.0, alpha: 1.0)
                    context.fill(CGRect(x: 0, y: nextY, width: width, height: min(stripeHeight, height - nextY)))
                }
            }

        case .checkerboard(let cellSize):
            for y in stride(from: 0, to: height, by: cellSize) {
                for x in stride(from: 0, to: width, by: cellSize) {
                    let isWhite = ((x / cellSize) + (y / cellSize)) % 2 == 0
                    context.setFillColor(gray: isWhite ? 1.0 : 0.0, alpha: 1.0)
                    context.fill(CGRect(x: x, y: y, width: min(cellSize, width - x), height: min(cellSize, height - y)))
                }
            }
        }

        return context.makeImage()!
    }

    private enum ImagePattern {
        case solid(CGFloat)
        case gradient
        case stripes(Int)
        case checkerboard(Int)
    }

    // MARK: - 1. Oracle Verification: computeAsync matches synchronous compute

    @Test("computeAsync produces identical digest to synchronous compute across diverse patterns")
    func computeAsyncOracleEquivalence() async {
        let patterns: [ImagePattern] = [
            .solid(0.0),
            .solid(0.33),
            .solid(0.5),
            .solid(1.0),
            .gradient,
            .stripes(4),
            .stripes(32),
            .checkerboard(8),
            .checkerboard(64)
        ]

        for (idx, pattern) in patterns.enumerated() {
            let img = createTestImage(width: 320, height: 240, pattern: pattern)
            let masks = (idx % 2 == 0) ? [CGRect(x: 10, y: 10, width: 50, height: 50)] : []

            let syncResult = FrameFingerprint.compute(img, gridSize: 32, levels: 8, masking: masks)
            let asyncResult = await FrameFingerprint.computeAsync(img, gridSize: 32, levels: 8, masking: masks)

            #expect(syncResult != nil, "Pattern \(pattern) sync should succeed")
            #expect(asyncResult != nil, "Pattern \(pattern) async should succeed")
            #expect(syncResult == asyncResult, "computeAsync must exactly match compute for pattern \(pattern)")
        }
    }

    // MARK: - 2. High Concurrency Burst & Thread Pool Starvation Check

    @Test("High-concurrency burst of 50 computeAsync tasks does not starve cooperative thread pool")
    func concurrencyBurstNoStarvationIsolated() async throws {
        // High-resolution images simulating 2K Retina display screenshots
        let image = createTestImage(width: 2048, height: 1280, pattern: .checkerboard(16))

        let startTime = ContinuousClock.now
        let taskCount = 50

        // Probe task measuring whether the thread pool remains cooperative and non-starving
        let probeRunning = OSAllocatedUnfairLock(initialState: true)
        let maxProbeLatency = OSAllocatedUnfairLock(initialState: Duration.zero)

        let probeTask = Task.detached(priority: .userInitiated) {
            var lastTick = ContinuousClock.now
            while probeRunning.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(20))
                let now = ContinuousClock.now
                let elapsed = now - lastTick
                lastTick = now
                maxProbeLatency.withLock { currentMax in
                    if elapsed > currentMax {
                        currentMax = elapsed
                    }
                }
            }
        }

        // Run 50 concurrent computeAsync tasks
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    await FrameFingerprint.computeAsync(image, gridSize: 32, levels: 8)
                }
            }

            var completed = 0
            for await result in group {
                #expect(result != nil)
                completed += 1
            }
            #expect(completed == taskCount)
        }

        probeRunning.withLock { $0 = false }
        _ = await probeTask.value

        _ = startTime
        let worstProbeLatency = maxProbeLatency.withLock { $0 }

        // Assert probe was not starved for > 800ms in isolated mode (15s ceiling under parallel load)
        let maxLatency: Duration = IsolatedTiming.enabled ? .milliseconds(800) : .seconds(15)
        #expect(worstProbeLatency < maxLatency, "Cooperative probe suffered excessive latency: \(worstProbeLatency)")
    }

    // MARK: - 3. Memory Footprint Stability Under Repetitive Load

    @Test("Repetitive computeAsync calls with 4K frames do not leak memory")
    func repetitiveExecutionMemoryStabilityIsolated() async throws {
        let image = createTestImage(width: 2560, height: 1600, pattern: .gradient)

        // Helper to query resident memory in MB
        func getResidentMemoryMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if kerr == KERN_SUCCESS {
                return Double(info.resident_size) / (1024.0 * 1024.0)
            }
            return 0.0
        }

        let initialMem = getResidentMemoryMB()

        // Execute 100 sequential downscales
        for _ in 0..<100 {
            _ = await FrameFingerprint.computeAsync(image, gridSize: 32, levels: 8)
        }

        let finalMem = getResidentMemoryMB()
        let memGrowth = finalMem - initialMem

        // Allow reasonable runtime growth but ensure no runaway buffer leak (< 150MB isolated, < 500MB parallel)
        let maxGrowthMB = IsolatedTiming.enabled ? 150.0 : 500.0
        #expect(memGrowth < maxGrowthMB, "Memory grew excessively: \(memGrowth) MB (initial: \(initialMem), final: \(finalMem))")
    }

    // MARK: - 4. Extreme Dimensional and Masking Boundary Cases

    @Test("Extreme aspect ratios and degenerate dimensions")
    func extremeDimensions() async {
        // 1x1 minimal image
        let singlePixel = createTestImage(width: 1, height: 1, pattern: .solid(0.5))
        let singleRes = await FrameFingerprint.computeAsync(singlePixel)
        #expect(singleRes != nil)

        // Ultra-wide 2000x1
        let ultraWide = createTestImage(width: 2000, height: 1, pattern: .solid(0.8))
        let wideRes = await FrameFingerprint.computeAsync(ultraWide)
        #expect(wideRes != nil)

        // Ultra-tall 1x2000
        let ultraTall = createTestImage(width: 1, height: 2000, pattern: .solid(0.2))
        let tallRes = await FrameFingerprint.computeAsync(ultraTall)
        #expect(tallRes != nil)
    }

    @Test("Adversarial masking coordinates are handled safely without crashing")
    func adversarialMasking() async {
        let img = createTestImage(width: 400, height: 300, pattern: .checkerboard(16))

        // 1. Negative origins
        let negMask = [CGRect(x: -10, y: -10, width: 50, height: 50)]
        let negRes = await FrameFingerprint.computeAsync(img, masking: negMask)
        #expect(negRes != nil)

        // 2. Out of bounds mask
        let oobMask = [CGRect(x: 350, y: 250, width: 200, height: 200)]
        let oobRes = await FrameFingerprint.computeAsync(img, masking: oobMask)
        #expect(oobRes != nil)

        // 3. Infinite / NaN coordinates
        let infMask = [CGRect(x: CGFloat.infinity, y: 0, width: 50, height: 50)]
        let infRes = await FrameFingerprint.computeAsync(img, masking: infMask)
        #expect(infRes != nil)

        let nanMask = [CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50)]
        let nanRes = await FrameFingerprint.computeAsync(img, masking: nanMask)
        #expect(nanRes != nil)

        // 4. Overlapping valid masks covering entire image
        let fullMask = [CGRect(x: 0, y: 0, width: 400, height: 300)]
        let fullRes = await FrameFingerprint.computeAsync(img, masking: fullMask)
        #expect(fullRes != nil)
    }

    @Test("Degenerate gridSize and levels parameters reject gracefully")
    func degenerateParameters() async {
        let img = createTestImage(width: 100, height: 100, pattern: .solid(0.5))

        #expect(await FrameFingerprint.computeAsync(img, gridSize: 0) == nil)
        #expect(await FrameFingerprint.computeAsync(img, gridSize: -1) == nil)
        #expect(await FrameFingerprint.computeAsync(img, levels: 1) == nil)
        #expect(await FrameFingerprint.computeAsync(img, levels: 0) == nil)
        #expect(await FrameFingerprint.computeAsync(img, levels: -5) == nil)
    }
}
