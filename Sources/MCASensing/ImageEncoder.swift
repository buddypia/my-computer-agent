import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a captured frame into bytes a vision model will accept.
///
/// JPEG rather than PNG, and downscaled before encoding. A full-screen PNG at
/// half resolution is several megabytes, and every one of those bytes is
/// base64-encoded into the request body and billed as image tokens. The
/// providers all resize to their own tile grid on arrival — roughly 768px on the
/// long edge — so anything above `maximumDimension` is paid for and then thrown
/// away.
public enum ImageEncoder {
    /// Encodes `image` as JPEG, scaled so its longest edge is at most
    /// `maximumDimension`.
    ///
    /// Returns `nil` rather than throwing: the caller's fallback is to send the
    /// text it already has, and an encoding failure is not a different situation
    /// from having no screenshot.
    public static func jpeg(
        _ image: CGImage,
        maximumDimension: Int = 1400,
        quality: Double = 0.7
    ) -> Data? {
        let source = downscale(image, maximumDimension: maximumDimension) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, source, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Redraws the image no larger than `maximumDimension` on its longest edge.
    /// `nil` means it was already small enough, or the context could not be made.
    private static func downscale(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumDimension, longest > 0 else { return nil }

        let factor = Double(maximumDimension) / Double(longest)
        let width = max(Int(Double(image.width) * factor), 1)
        let height = max(Int(Double(image.height) * factor), 1)

        // A fixed 8-bit sRGB context rather than the source's own colour space:
        // a captured frame can come back in a wide-gamut or 16-bit format that
        // `CGContext` refuses to draw into, and the difference is invisible to a
        // model reading text off a screenshot.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
