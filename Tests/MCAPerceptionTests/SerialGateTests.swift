import CoreGraphics
import Foundation
import os
import Testing

@testable import MCAPerception

@Suite("SerialGate")
struct SerialGateTests {
    private struct Boom: Error {}

    @Test("runs one call at a time, and a throwing call still lets the next one in")
    func oneAtATime() async throws {
        let gate = SerialGate()
        let active = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))

        let finished = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        try await gate.run {
                            active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                            try await Task.sleep(for: .milliseconds(5))
                            active.withLock { $0.now -= 1 }
                            if index.isMultiple(of: 2) { throw Boom() }
                        }
                    } catch is Boom {
                    } catch {
                        Issue.record(error)
                    }
                    return true
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        #expect(finished == 20)
        #expect(active.withLock { $0.peak } == 1)
    }

    @Test("TextRecognizer waits for the Vision gate instead of running alongside another recognition")
    func recognizerUsesTheGate() async throws {
        let recognizer = TextRecognizer()
        let image = try #require(Self.blankImage())
        // Warm the model so an unserialised recognition would finish well inside the wait below.
        _ = try await recognizer.recognizeText(in: image)

        let (acquired, acquiredSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await TextRecognizer.visionGate.run {
                acquiredSignal.yield()
                for await _ in release { break }
            }
        }
        for await _ in acquired { break }

        let done = OSAllocatedUnfairLock(initialState: false)
        let recognition = Task {
            _ = try await recognizer.recognizeText(in: image)
            done.withLock { $0 = true }
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!done.withLock { $0 }, "recognition ran while another held the Vision gate")

        releaseSignal.yield()
        try await holder.value
        try await recognition.value
        #expect(done.withLock { $0 })
    }

    private static func blankImage() -> CGImage? {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context?.makeImage()
    }
}
