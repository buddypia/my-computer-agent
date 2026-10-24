import CoreGraphics
import Foundation
import MCASensing

/// What a model that drives the desktop by looking at it is handed: the main
/// display as an image, plus the one number needed to turn a pixel it points at
/// back into a screen point.
public struct ComputerScreenshot: Sendable, Equatable {
    public let jpeg: Data
    /// Pixel size of ``jpeg``, which is what the model sees and points into.
    public let width: Int
    public let height: Int
    /// Size of the main display in screen points, the unit of the mouse events.
    public let displayPoints: CGSize

    public init(jpeg: Data, width: Int, height: Int, displayPoints: CGSize) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.displayPoints = displayPoints
    }

    /// Image pixels per screen point: 1 unless the display was wider than the
    /// size cap and the picture was shrunk.
    public var pixelsPerPoint: Double {
        guard displayPoints.width > 0 else { return 1 }
        return Double(width) / displayPoints.width
    }

    /// The text that travels with the image, so a model that cannot measure a
    /// picture still knows which coordinate space it is working in.
    public var summary: String {
        let scale = String(format: "%.3f", pixelsPerPoint)
        return "Screenshot of the main display: \(width)x\(height) px "
            + "(display is \(Int(displayPoints.width))x\(Int(displayPoints.height)) points, "
            + "\(scale) px per point). Pass coordinates to this tool in the pixel space of the "
            + "latest screenshot, origin at its top-left."
    }
}

/// Source of ``ComputerScreenshot``s. A protocol so tests (and any other
/// capture backend) need not touch the real screen.
public protocol ScreenshotProviding: Sendable {
    func captureMainDisplay() async throws -> ComputerScreenshot
}

/// Captures the main display through ScreenCaptureKit.
///
/// The main display, because it is the one whose top-left is the origin of
/// every mouse coordinate. The privacy exclusions (password managers and the
/// user's own list) apply as for every other capture in the process.
public struct DisplayScreenshotProvider: ScreenshotProviding {
    /// Longest edge of the delivered picture. A model's image input is resized
    /// to about this on arrival, so a larger picture is paid for and then
    /// shrunk anyway, and the shrink would move every coordinate the model
    /// reads off it. Shrinking here keeps the mapping known.
    public static let defaultMaximumDimension = 1568

    private let maximumDimension: Int
    private let capturer: ScreenCapturer

    public init(maximumDimension: Int = defaultMaximumDimension, capturer: ScreenCapturer = ScreenCapturer()) {
        self.maximumDimension = maximumDimension
        self.capturer = capturer
    }

    public func captureMainDisplay() async throws -> ComputerScreenshot {
        let displayID = CGMainDisplayID()
        let image = try await capturer.captureDisplay(displayID: displayID)
        let bounds = CGDisplayBounds(displayID)
        guard let encoded = ImageEncoder.encodedJPEG(
            image, maximumDimension: maximumDimension, quality: 0.8)
        else { throw ScreenshotError.encodingFailed }
        return ComputerScreenshot(
            jpeg: encoded.data, width: encoded.width, height: encoded.height, displayPoints: bounds.size)
    }
}

public enum ScreenshotError: LocalizedError, Sendable {
    case encodingFailed
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The screen could not be encoded as an image."
        case .unavailable(let reason): return reason
        }
    }
}

/// How the pixels of the latest screenshot relate to screen points.
///
/// Mouse events are in points; the model points at pixels of the picture it
/// last saw. They are the same unless that picture was shrunk, so this holds the
/// factor and the tool applies it to every coordinate it receives. Starts at 1,
/// which leaves a caller that never takes a screenshot working in raw points.
public final class ComputerScreenSpace: @unchecked Sendable {
    public static let shared = ComputerScreenSpace()

    private let lock = NSLock()
    private var scale = 1.0

    public init() {}

    public var pixelsPerPoint: Double { lock.withLock { scale } }

    /// Remembers the mapping of a screenshot just handed to the model.
    public func adopt(_ screenshot: ComputerScreenshot) {
        let factor = screenshot.pixelsPerPoint
        guard factor.isFinite, factor > 0 else { return }
        lock.withLock { scale = factor }
    }

    /// A point in the latest screenshot's pixels → the screen point to act on.
    public func screenPoint(fromImage point: CGPoint) -> CGPoint {
        let factor = pixelsPerPoint
        return CGPoint(x: point.x / factor, y: point.y / factor)
    }

    /// A screen point → the pixel of the latest screenshot it falls on.
    public func imagePoint(fromScreen point: CGPoint) -> CGPoint {
        let factor = pixelsPerPoint
        return CGPoint(x: point.x * factor, y: point.y * factor)
    }
}
