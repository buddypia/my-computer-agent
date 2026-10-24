import CoreGraphics
import Foundation
import MCASensing

/// What a model that drives the desktop by looking at it is handed: the main
/// display (or a region of it) as an image, plus the numbers needed to turn a
/// pixel it points at back into a screen point.
public struct ComputerScreenshot: Sendable, Equatable {
    public let jpeg: Data
    /// Pixel size of ``jpeg``, which is what the model sees and points into.
    public let width: Int
    public let height: Int
    /// Size of the main display in screen points, the unit of the mouse events.
    public let displayPoints: CGSize
    /// For a zoom: the part of the display shown, in screen points. `nil` for a full screenshot.
    public let region: CGRect?

    public init(jpeg: Data, width: Int, height: Int, displayPoints: CGSize, region: CGRect? = nil) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.displayPoints = displayPoints
        self.region = region
    }

    /// Image pixels per screen point of a *full* screenshot: 1 unless the display
    /// exceeded the size budget and the picture was shrunk. A zoom does not define
    /// the coordinate space, so it never feeds ``ComputerScreenSpace``.
    public var pixelsPerPoint: Double {
        guard displayPoints.width > 0 else { return 1 }
        return Double(width) / displayPoints.width
    }

    /// The text that travels with the image, so a model that cannot measure a
    /// picture still knows which coordinate space it is working in.
    public var summary: String {
        if let region {
            return "Zoom on region [\(Int(region.minX)), \(Int(region.minY)), \(Int(region.maxX)), \(Int(region.maxY))] pt "
                + "of the display (\(width)x\(height) px). Coordinates stay in the pixel space of the latest "
                + "full screenshot, not of this image."
        }
        let scale = String(format: "%.3f", pixelsPerPoint)
        return "Screenshot of the main display: \(width)x\(height) px "
            + "(display is \(Int(displayPoints.width))x\(Int(displayPoints.height)) points, "
            + "\(scale) px per point). Pass coordinates to this tool in the pixel space of the "
            + "latest screenshot, origin at its top-left."
    }
}

/// How large a screenshot may be before a model's image input would shrink it itself —
/// which would move every coordinate the model reads off it.
public struct ScreenshotBudget: Sendable, Equatable {
    /// The limits every Claude vision model accepts: 1,568 px on the long edge and
    /// about 1.15 megapixels. (Newer models accept more; see the environment overrides.)
    public static let standard = ScreenshotBudget(maximumLongEdge: 1568, maximumPixels: 1_150_000)

    public let maximumLongEdge: Int
    public let maximumPixels: Int

    public init(maximumLongEdge: Int, maximumPixels: Int) {
        self.maximumLongEdge = maximumLongEdge
        self.maximumPixels = maximumPixels
    }

    /// `MCA_SCREENSHOT_MAX_LONG_EDGE` and `MCA_SCREENSHOT_MAX_PIXELS` raise or lower the
    /// budget for a client whose model takes larger images (for example 2576 and 3_750_000).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ScreenshotBudget {
        func value(_ key: String, default fallback: Int) -> Int {
            guard let text = environment[key], let number = Int(text), number >= 64 else { return fallback }
            return number
        }
        return ScreenshotBudget(
            maximumLongEdge: value("MCA_SCREENSHOT_MAX_LONG_EDGE", default: standard.maximumLongEdge),
            maximumPixels: value("MCA_SCREENSHOT_MAX_PIXELS", default: standard.maximumPixels))
    }

    /// The factor to shrink a `width` x `height` display by: the smaller of what the edge
    /// limit and the pixel budget each demand, never above 1 (a picture is not enlarged).
    public func scale(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let longEdge = Double(max(width, height))
        let totalPixels = Double(width) * Double(height)
        return min(1, Double(maximumLongEdge) / longEdge, (Double(maximumPixels) / totalPixels).squareRoot())
    }

    /// The pixel size a display of `width` x `height` points is delivered at.
    public func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let factor = scale(width: width, height: height)
        // Rounded down, as the reference implementations do, so the budget is never exceeded.
        return (max(Int(Double(width) * factor), 1), max(Int(Double(height) * factor), 1))
    }
}

/// Source of ``ComputerScreenshot``s. A protocol so tests (and any other
/// capture backend) need not touch the real screen.
public protocol ScreenshotProviding: Sendable {
    func captureMainDisplay() async throws -> ComputerScreenshot
    /// The part of the main display inside `region` (screen points), at full resolution,
    /// fitted to the screenshot budget.
    func captureRegion(_ region: CGRect) async throws -> ComputerScreenshot
}

public extension ScreenshotProviding {
    func captureRegion(_ region: CGRect) async throws -> ComputerScreenshot {
        throw ScreenshotError.unavailable("Zoom is not supported by this screenshot source.")
    }
}

/// Captures the main display through ScreenCaptureKit.
///
/// The main display, because it is the one whose top-left is the origin of
/// every mouse coordinate. The privacy exclusions (password managers and the
/// user's own list) apply as for every other capture in the process.
public struct DisplayScreenshotProvider: ScreenshotProviding {
    private let budget: ScreenshotBudget

    public init(budget: ScreenshotBudget = .fromEnvironment()) {
        self.budget = budget
    }

    public func captureMainDisplay() async throws -> ComputerScreenshot {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        // One point per pixel is all a shrunk picture can show, so capture at that.
        let image = try await ScreenCapturer(scale: 1).captureDisplay(displayID: displayID)
        let target = budget.size(width: Int(bounds.width), height: Int(bounds.height))
        guard let encoded = ImageEncoder.encodedJPEG(image, width: target.width, height: target.height, quality: 0.8)
        else { throw ScreenshotError.encodingFailed }
        return ComputerScreenshot(
            jpeg: encoded.data, width: encoded.width, height: encoded.height, displayPoints: bounds.size)
    }

    public func captureRegion(_ region: CGRect) async throws -> ComputerScreenshot {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let wanted = region.standardized.intersection(CGRect(origin: .zero, size: bounds.size))
        guard !wanted.isNull, wanted.width >= 1, wanted.height >= 1 else {
            throw ScreenshotError.unavailable("The zoom region is outside the display.")
        }
        // Native pixels (a Retina display has more than one per point): that is the detail zoom is for.
        // `CGDisplayPixelsWide` reports the scaled mode's size, i.e. points, so ask the mode itself.
        let nativeWidth = CGDisplayCopyDisplayMode(displayID).map { Double($0.pixelWidth) } ?? bounds.width
        let pixelsPerPoint = max(1, nativeWidth / bounds.width)
        let image = try await ScreenCapturer(scale: pixelsPerPoint).captureDisplay(displayID: displayID)
        let factor = Double(image.width) / bounds.width
        let pixelRect = CGRect(
            x: wanted.minX * factor, y: wanted.minY * factor,
            width: wanted.width * factor, height: wanted.height * factor).integral
        guard let cropped = ScreenCapturer.crop(image: image, to: pixelRect) else {
            throw ScreenshotError.encodingFailed
        }
        let target = budget.size(width: cropped.width, height: cropped.height)
        guard let encoded = ImageEncoder.encodedJPEG(cropped, width: target.width, height: target.height, quality: 0.8)
        else { throw ScreenshotError.encodingFailed }
        return ComputerScreenshot(
            jpeg: encoded.data, width: encoded.width, height: encoded.height,
            displayPoints: bounds.size, region: wanted)
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

    /// Remembers the mapping of a full screenshot just handed to the model. A zoom is
    /// ignored: coordinates stay in the space of the last full screenshot.
    public func adopt(_ screenshot: ComputerScreenshot) {
        guard screenshot.region == nil else { return }
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
