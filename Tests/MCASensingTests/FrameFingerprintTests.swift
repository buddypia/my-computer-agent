import CoreGraphics
import Foundation
import Testing

@testable import MCASensing

/// A pinned window is watched through its picture alone, so this is where the
/// feature's cost lives: too sensitive and an idle window bills a vision request
/// every interval for a blinking cursor, too blunt and a build that finished ten
/// minutes ago is still "unchanged".
@Suite("Frame fingerprint")
struct FrameFingerprintTests {
    /// A solid grey square, optionally with one pixel painted a different shade.
    private func image(
        width: Int = 400,
        height: Int = 300,
        level: Double,
        speck: CGPoint? = nil
    ) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: level, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let speck {
            context.setFillColor(gray: 1 - level, alpha: 1)
            context.fill(CGRect(x: speck.x, y: speck.y, width: 1, height: 1))
        }
        return context.makeImage()!
    }

    /// Two halves, split either down the middle or across it.
    private func split(vertical: Bool) -> CGImage {
        let context = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(vertical
            ? CGRect(x: 200, y: 0, width: 200, height: 300)
            : CGRect(x: 0, y: 150, width: 400, height: 150))
        return context.makeImage()!
    }

    @Test("the same frame twice is the same fingerprint")
    func stableAcrossIdenticalFrames() {
        let first = FrameFingerprint.compute(image(level: 0.5))
        let second = FrameFingerprint.compute(image(level: 0.5))

        #expect(first != nil)
        #expect(first == second)
    }

    /// The gate that decides whether this feature is affordable. A caret
    /// blinking in a terminal must not read as the terminal having changed —
    /// otherwise a window nobody is touching bills a request every interval,
    /// all afternoon.
    @Test("a single changed pixel does not count as a change")
    func onePixelIsNoise() {
        let quiet = FrameFingerprint.compute(image(level: 0.5))
        let blinking = FrameFingerprint.compute(
            image(level: 0.5, speck: CGPoint(x: 120, y: 80)))

        #expect(quiet == blinking)
    }

    /// The opposite failure, and the worse one: a watch that cannot see a build
    /// finish is not a cheap watch, it is a broken one.
    @Test("half the window changing is a change")
    func realChangeIsDetected() {
        let before = FrameFingerprint.compute(image(level: 0))
        let after = FrameFingerprint.compute(split(vertical: true))

        #expect(before != after)
    }

    /// Same amount of black and white, arranged differently. Catches a
    /// fingerprint that has collapsed into an average brightness — which would
    /// call every screen with the same amount of text on it identical.
    @Test("layout is part of the fingerprint, not just brightness")
    func layoutMatters() {
        #expect(FrameFingerprint.compute(split(vertical: true))
            != FrameFingerprint.compute(split(vertical: false)))
    }

    /// Brightnesses one step apart in an 8-bit encoding land in the same
    /// quantisation bucket. This is what absorbs JPEG-ish rendering drift and
    /// the sub-pixel shimmer of anti-aliased text.
    @Test("a brightness difference too small to see is quantised away")
    func quantisationAbsorbsDrift() {
        #expect(FrameFingerprint.compute(image(level: 0.5))
            == FrameFingerprint.compute(image(level: 0.502)))
    }

    /// Resizing a window is not new content. Without this, dragging a window
    /// edge would spend a request.
    @Test("the same content at another size is the same fingerprint")
    func sizeIndependent() {
        let small = FrameFingerprint.compute(image(width: 400, height: 300, level: 0.25))
        let large = FrameFingerprint.compute(image(width: 1200, height: 900, level: 0.25))

        #expect(small == large)
    }

    /// `nil` is "unknown", and the caller must not read it as "unchanged".
    /// Returning a constant here instead would silently freeze the watch.
    @Test("a degenerate grid is refused rather than answered")
    func refusesDegenerateParameters() {
        let frame = image(level: 0.5)

        #expect(FrameFingerprint.compute(frame, gridSize: 0) == nil)
        #expect(FrameFingerprint.compute(frame, levels: 1) == nil)
    }
}
