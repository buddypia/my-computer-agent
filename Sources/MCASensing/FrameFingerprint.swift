import CoreGraphics
import CryptoKit
import Foundation

/// Identity of a captured frame: same picture, same string.
///
/// The picture detects changes to diagrams and other content that an
/// accessibility text tree cannot describe. It does so before OCR or model
/// requests. Callers may normalize exact, independently identified window
/// decoration rectangles without changing the image sent for observation.
///
/// Deliberately lossy, in two steps:
///
/// 1. **Downscale to a `gridSize` square.** Averaging forty-odd pixels into one
///    is what makes a blinking cursor, a scrolling progress spinner and an
///    anti-aliased glyph stop being changes. Aspect ratio is discarded on
///    purpose: a resized window is not new content, and a fingerprint that
///    changed on every drag would spend a request each time.
/// 2. **Quantise to `levels` brightness steps.** Removes the last of the
///    compression and rendering noise that survives the downscale.
///
/// What is left is hashed rather than kept, because the caller only ever asks
/// "is this the same as last time" — and `ScreenWatchPolicy` compares
/// fingerprints as opaque strings, so nothing downstream has to change to accept
/// one of these in place of a window title and a text hash.
///
/// The residual failure is a value sitting exactly on a quantisation boundary,
/// which can flip between two frames that look identical. That costs one extra
/// look, bounded by the watch interval — the same worst case the text path
/// already has. The opposite error would be worse and does not happen here:
/// anything large enough for a user to notice survives both steps.
public enum FrameFingerprint {
    /// Returns `nil` only when the image cannot be redrawn at all, which the
    /// caller must treat as "unknown", not as "unchanged" — the whole point is
    /// to not skip a screen we failed to look at.
    public static func compute(_ image: CGImage, gridSize: Int = 32, levels: Int = 8,
                               masking: [CGRect] = []) -> String? {
        guard gridSize > 0, levels > 1,
              let samples = grayscale(normalized(image, masking: masking), size: gridSize)
        else { return nil }

        // Integer arithmetic: `value * levels / 256` puts 0…255 into 0…levels-1
        // with no floating point and no rounding surprises at the top of the
        // range.
        var quantised = Data(capacity: samples.count)
        for sample in samples {
            quantised.append(UInt8(Int(sample) * levels / 256))
        }

        let digest = SHA256.hash(data: quantised)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Rectangles use image pixels with a top-left origin. Invalid metadata
    /// falls back to the complete image so content is never hidden by it.
    private static func normalized(_ image: CGImage, masking: [CGRect]) -> CGImage {
        guard !masking.isEmpty, masking.allSatisfy({ rect in
            rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
                && rect.minX >= 0 && rect.minY >= 0
                && rect.maxX <= CGFloat(image.width) && rect.maxY <= CGFloat(image.height)
        }), let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(gray: 0, alpha: 1)
        for rect in masking {
            context.fill(CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY,
                                width: rect.width, height: rect.height))
        }
        return context.makeImage() ?? image
    }

    /// Redraws `image` as a `size`×`size` block of 8-bit grey.
    private static func grayscale(_ image: CGImage, size: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }

            // High interpolation, unlike `ImageEncoder`'s downscale: there the
            // output is read by a model and medium is indistinguishable, here it
            // *is* the measurement, and a cheaper filter samples rather than
            // averages — which puts the blinking cursor back.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drawn ? pixels : nil
    }
}
