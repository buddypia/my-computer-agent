import CoreGraphics
import Foundation
import ImageIO
import MCASensing
import Testing

@Suite("Window decoration fingerprint")
struct WindowDecorationFingerprintTests {
    // Real SCK frames of the same owned material. Read-only AX metadata
    // identifies only the standard buttons and title in image coordinates.
    private let decorations = [
        CGRect(x: 8, y: 8, width: 16, height: 16),
        CGRect(x: 31, y: 8, width: 16, height: 16),
        CGRect(x: 54, y: 8, width: 16, height: 16),
        CGRect(x: 82, y: 8, width: 166, height: 16),
    ]

    private func frame(_ name: String) throws -> CGImage {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "png", subdirectory: "WindowFocus"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("Focus decoration does not claim unchanged material twice")
    func focusOnlyChange() throws {
        let active = try frame("selected-active")
        let background = try frame("selected-background")
        #expect(FrameFingerprint.compute(active) != FrameFingerprint.compute(background))
        let first = try #require(FrameFingerprint.compute(active, masking: decorations))
        let second = try #require(FrameFingerprint.compute(background, masking: decorations))
        #expect(first == second)
    }

    @Test("Visual content below the decorations still changes the fingerprint")
    func visualContentChange() throws {
        let active = try frame("selected-active")
        let context = try #require(CGContext(
            data: nil, width: active.width, height: active.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(active, in: CGRect(x: 0, y: 0, width: active.width, height: active.height))
        // A graph changes in the blank lower half; no title or text is edited.
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 400, y: 60, width: 150, height: 100))
        let changed = try #require(context.makeImage())
        #expect(FrameFingerprint.compute(active, masking: decorations)
            != FrameFingerprint.compute(changed, masking: decorations))
    }

    @Test("Malformed or out-of-image decoration bounds preserve the raw frame",
          arguments: [CGRect(x: -1, y: 8, width: 16, height: 16),
                      CGRect(x: 0, y: 0, width: 800, height: 500),
                      CGRect(x: CGFloat.nan, y: 0, width: 16, height: 16)])
    func invalidBounds(_ bounds: CGRect) throws {
        let active = try frame("selected-active")
        #expect(FrameFingerprint.compute(active, masking: [bounds])
            == FrameFingerprint.compute(active))
    }
}
