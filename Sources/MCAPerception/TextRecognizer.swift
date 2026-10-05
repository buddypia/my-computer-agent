import CoreGraphics
import Foundation
import MCACore
import OSLog
import Vision

/// Tier-2 screen reading: OCR for windows that expose no usable accessibility
/// tree (canvas-drawn editors, remote desktops, games, video).
///
/// Runs entirely on-device through Vision. Sending screenshots to a vision LLM
/// just to read text would cost roughly a thousand times more per frame and add
/// network latency, for worse results on UI text.
public struct TextRecognizer: Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "OCR")
    private let languages: [Locale.Language]

    public init(languages: [String] = ["en-US", "ja-JP"]) {
        self.languages = languages.map { Locale.Language(identifier: $0) }
    }

    // MARK: - Coordinate Conversion (Pure Geometry)

    /// Converts a normalized Vision bounding box (origin bottom-left, range 0...1)
    /// to Quartz display coordinates (origin top-left) mapped within `targetRect`.
    ///
    /// - Parameters:
    ///   - visionRect: Normalized bounding box where (0,0) is bottom-left and (1,1) is top-right.
    ///   - targetRect: Global Quartz display or window rectangle where (0,0) is top-left.
    /// - Returns: Bounding box in Quartz screen coordinates.
    public static func convertVisionRectToQuartz(
        _ visionRect: CGRect,
        within targetRect: CGRect
    ) -> CGRect {
        // Invert Y: in Vision, y=0 is bottom; in Quartz, y=0 is top.
        // The top edge of the Vision box is at (visionRect.origin.y + visionRect.size.height) from bottom.
        // Therefore, distance from the top of the image in normalized space is:
        // 1.0 - visionRect.origin.y - visionRect.size.height.
        let normX = visionRect.origin.x
        let normY = 1.0 - visionRect.origin.y - visionRect.size.height
        let normW = visionRect.size.width
        let normH = visionRect.size.height

        let screenX = targetRect.origin.x + (normX * targetRect.size.width)
        let screenY = targetRect.origin.y + (normY * targetRect.size.height)
        let screenW = normW * targetRect.size.width
        let screenH = normH * targetRect.size.height

        return CGRect(x: screenX, y: screenY, width: screenW, height: screenH)
    }

    // MARK: - Candidate Factory

    /// Creates a single `UIElementCandidate` from recognized text and a Vision bounding box.
    ///
    /// - Parameters:
    ///   - text: The recognized text string.
    ///   - visionRect: Normalized Vision bounding box (bottom-left origin).
    ///   - index: 1-based index used for generating unique IDs (e.g. `ocr_1`).
    ///   - targetRect: Target Quartz rectangle (window frame or screen rect).
    ///   - role: Accessibility-compatible role string (default `"staticText"`).
    /// - Returns: A `UIElementCandidate` with `.source = .ocr`, or `nil` if text or bounds are empty.
    public static func makeCandidate(
        text: String,
        visionRect: CGRect,
        index: Int,
        targetRect: CGRect,
        role: String = "staticText"
    ) -> UIElementCandidate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject invalid, degenerate, negative, NaN, or infinite dimensions in input rects
        guard targetRect.size.width > 0 && targetRect.size.height > 0 else { return nil }
        guard visionRect.size.width > 0 && visionRect.size.height > 0 else { return nil }
        guard !targetRect.isNull && !targetRect.isEmpty && !visionRect.isNull && !visionRect.isEmpty else { return nil }
        guard targetRect.origin.x.isFinite && targetRect.origin.y.isFinite &&
              targetRect.size.width.isFinite && targetRect.size.height.isFinite &&
              visionRect.origin.x.isFinite && visionRect.origin.y.isFinite &&
              visionRect.size.width.isFinite && visionRect.size.height.isFinite else { return nil }

        let quartzBounds = convertVisionRectToQuartz(visionRect, within: targetRect)
        guard quartzBounds.size.width > 0 && quartzBounds.size.height > 0 else { return nil }
        guard !quartzBounds.isNull && !quartzBounds.isEmpty else { return nil }
        guard quartzBounds.origin.x.isFinite && quartzBounds.origin.y.isFinite &&
              quartzBounds.size.width.isFinite && quartzBounds.size.height.isFinite else { return nil }

        return UIElementCandidate(
            id: "ocr_\(index)",
            role: role,
            label: trimmed,
            value: nil,
            bounds: quartzBounds,
            isActionable: true,
            source: .ocr
        )
    }

    // MARK: - Reading Order & Line Band Quantization

    /// Number of vertical line bands across normalized Vision height [0, 1].
    /// A value of 100 partitions the screen into 1% vertical bands (~10pt on a 1000pt display),
    /// matching standard UI line heights and establishing a strict weak ordering.
    public static let defaultLineBandCount: Double = 100.0

    /// Computes the quantized line band index for a normalized Vision Y coordinate.
    /// In Vision normalized coordinates, Y=1.0 is top and Y=0.0 is bottom.
    /// Clamps to [-1000, 1000] and safely handles non-finite (NaN / Infinity) values.
    public static func lineBand(for midY: CGFloat, bandCount: Double = defaultLineBandCount) -> Int {
        guard midY.isFinite else { return 0 }
        let clamped = max(-1000.0, min(1000.0, Double(midY)))
        return Int((clamped * bandCount).rounded())
    }

    /// Compares two Vision bounding boxes in natural reading order (top-to-bottom, left-to-right)
    /// using quantized line bands to mathematically guarantee a strict weak ordering.
    public static func isOrderedBefore(
        rectA: CGRect,
        rectB: CGRect,
        bandCount: Double = defaultLineBandCount
    ) -> Bool {
        let bandA = lineBand(for: rectA.midY, bandCount: bandCount)
        let bandB = lineBand(for: rectB.midY, bandCount: bandCount)
        if bandA != bandB {
            // Higher Vision Y is closer to the top of the display (descending Y order)
            return bandA > bandB
        }
        let ax = rectA.minX
        let bx = rectB.minX
        let safeAX = ax.isFinite ? ax : 0.0
        let safeBX = bx.isFinite ? bx : 0.0
        if safeAX != safeBX {
            // Earlier in reading order is closer to the left (ascending X order)
            return safeAX < safeBX
        }
        let ay = rectA.midY
        let by = rectB.midY
        let safeAY = ay.isFinite ? ay : 0.0
        let safeBY = by.isFinite ? by : 0.0
        return safeAY > safeBY
    }

    /// Extracts structured `[UIElementCandidate]` from Swift-native `RecognizedTextObservation` items,
    /// sorted in reading order (top-to-bottom, left-to-right) via quantized line bands.
    public static func extractCandidates(
        from observations: [RecognizedTextObservation],
        targetRect: CGRect,
        role: String = "staticText"
    ) -> [UIElementCandidate] {
        let sorted = observations.sorted { a, b in
            isOrderedBefore(rectA: a.boundingBox.cgRect, rectB: b.boundingBox.cgRect)
        }

        var candidates: [UIElementCandidate] = []
        candidates.reserveCapacity(sorted.count)

        for (index, obs) in sorted.enumerated() {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let candidate = makeCandidate(
                text: text,
                visionRect: obs.boundingBox.cgRect,
                index: index + 1,
                targetRect: targetRect,
                role: role
            ) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    /// Extracts structured `[UIElementCandidate]` from classic `VNRecognizedTextObservation` items.
    public static func extractCandidates(
        from observations: [VNRecognizedTextObservation],
        targetRect: CGRect,
        role: String = "staticText"
    ) -> [UIElementCandidate] {
        let sorted = observations.sorted { a, b in
            isOrderedBefore(rectA: a.boundingBox, rectB: b.boundingBox)
        }

        var candidates: [UIElementCandidate] = []
        candidates.reserveCapacity(sorted.count)

        for (index, obs) in sorted.enumerated() {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let candidate = makeCandidate(
                text: text,
                visionRect: obs.boundingBox,
                index: index + 1,
                targetRect: targetRect,
                role: role
            ) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    // MARK: - Candidate Deduplication & Filtering

    /// Filters out OCR candidates that overlap an existing Accessibility candidate by more than `overlapThreshold` (IoMin).
    /// True IoMin is defined as `intersectionArea / min(ocrArea, axArea)`.
    /// This prevents duplicate prompts and confusion in hybrid interfaces.
    public static func filterOverlappingCandidates(
        ocrCandidates: [UIElementCandidate],
        against axCandidates: [UIElementCandidate],
        overlapThreshold: Double = 0.60
    ) -> [UIElementCandidate] {
        guard !axCandidates.isEmpty else { return ocrCandidates }

        return ocrCandidates.filter { ocr in
            let ocrArea = ocr.bounds.width * ocr.bounds.height
            guard ocrArea > 0 else { return false }

            for ax in axCandidates {
                let axArea = ax.bounds.width * ax.bounds.height
                guard axArea > 0 else { continue }

                let inter = ocr.bounds.intersection(ax.bounds)
                guard !inter.isNull && !inter.isEmpty else { continue }
                let interArea = inter.width * inter.height
                guard interArea > 0 else { continue }

                let minArea = min(ocrArea, axArea)
                if (interArea / minArea) >= overlapThreshold {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Public Recognition APIs

    /// Recognizes text in the given image and returns structured UI element candidates
    /// with bounding boxes and centers mapped to Quartz screen coordinates.
    ///
    /// - Parameters:
    ///   - image: The captured frame or window image.
    ///   - windowFrame: Optional target rectangle in Quartz display coordinates (e.g. `window.frame`).
    ///                  Defaults to the full pixel dimensions of `image`.
    ///   - recognitionLevel: Vision recognition speed/accuracy trade-off (`.accurate` or `.fast`).
    /// - Returns: An ordered array of `UIElementCandidate` instances tagged with `.source = .ocr`.
    public func recognizeCandidates(
        in image: CGImage,
        windowFrame: CGRect? = nil,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    ) async throws -> [UIElementCandidate] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let observations = try await request.perform(on: image)
        let targetRect = windowFrame ?? CGRect(
            x: 0,
            y: 0,
            width: Double(image.width),
            height: Double(image.height)
        )

        return Self.extractCandidates(from: observations, targetRect: targetRect)
    }

    /// Recognised text in reading order, joined by newlines.
    /// Preserved for backward compatibility with existing screen watchers and tools.
    public func recognizeText(in image: CGImage) async throws -> String {
        let candidates = try await recognizeCandidates(in: image)
        return candidates.map(\.label).joined(separator: "\n")
    }
}

