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
        encodedJPEG(image, maximumDimension: maximumDimension, quality: quality)?.data
    }

    /// JPEG bytes together with the pixel size actually delivered.
    ///
    /// A caller that lets a model point at the picture (computer use) has to map
    /// the model's pixel coordinates back onto the screen, so it needs the size
    /// after scaling, not the size it asked for.
    public struct EncodedImage: Sendable {
        public let data: Data
        public let width: Int
        public let height: Int
    }

    public static func encodedJPEG(
        _ image: CGImage,
        maximumDimension: Int = 1400,
        quality: Double = 0.7
    ) -> EncodedImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumDimension, longest > 0 else { return encode(image, quality: quality) }
        let factor = Double(maximumDimension) / Double(longest)
        return encodedJPEG(
            image, width: max(Int(Double(image.width) * factor), 1),
            height: max(Int(Double(image.height) * factor), 1), quality: quality)
    }

    /// Like ``encodedJPEG(_:maximumDimension:quality:)`` but to an exact pixel size, for a
    /// caller that has already decided how large the picture must be (computer use fits a
    /// pixel budget as well as an edge limit).
    public static func encodedJPEG(_ image: CGImage, width: Int, height: Int, quality: Double = 0.7) -> EncodedImage? {
        guard width > 0, height > 0 else { return nil }
        guard width != image.width || height != image.height else { return encode(image, quality: quality) }
        return encode(resized(image, width: width, height: height) ?? image, quality: quality)
    }

    private static func encode(_ source: CGImage, quality: Double) -> EncodedImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, source, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return EncodedImage(data: data as Data, width: source.width, height: source.height)
    }

    /// Redraws the image at the given size; `nil` if the context could not be made.
    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
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
