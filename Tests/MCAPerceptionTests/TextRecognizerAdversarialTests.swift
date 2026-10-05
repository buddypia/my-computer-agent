import AppKit
import CoreGraphics
import Foundation
import MCACore
import Testing
import Vision

@testable import MCAPerception

@Suite("TextRecognizer Adversarial Challenge Suite")
struct TextRecognizerAdversarialTests {

    // MARK: - 1. Extreme Window Origins & Multi-Display Setups

    @Test("Extreme window origin: Multi-display far left and top-left negative coordinates")
    func extremeNegativeDisplayCoordinates() {
        let farLeftDisplay = CGRect(x: -3840, y: -1080, width: 3840, height: 2160)
        let visionRect = CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.1)

        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: farLeftDisplay)

        let expectedX = -3840.0 + (0.25 * 3840.0) // -2880.0
        let expectedY = -1080.0 + (0.15 * 2160.0) // -756.0
        let expectedW = 0.5 * 3840.0 // 1920.0
        let expectedH = 0.1 * 2160.0 // 216.0

        #expect(abs(quartz.origin.x - expectedX) < 1e-5)
        #expect(abs(quartz.origin.y - expectedY) < 1e-5)
        #expect(abs(quartz.width - expectedW) < 1e-5)
        #expect(abs(quartz.height - expectedH) < 1e-5)
    }

    @Test("Extreme window origin: Far right multi-display beyond 10,000 pt")
    func extremePositiveDisplayCoordinates() {
        let farRightDisplay = CGRect(x: 10240, y: 4320, width: 2560, height: 1440)
        let visionRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: farRightDisplay)

        let expectedX = 10240.0 + (0.1 * 2560.0) // 10496.0
        let expectedY = 4320.0 + (0.4 * 1440.0) // 4896.0
        let expectedW = 0.3 * 2560.0 // 768.0
        let expectedH = 0.4 * 1440.0 // 576.0

        #expect(abs(quartz.origin.x - expectedX) < 1e-5)
        #expect(abs(quartz.origin.y - expectedY) < 1e-5)
        #expect(abs(quartz.width - expectedW) < 1e-5)
        #expect(abs(quartz.height - expectedH) < 1e-5)
    }

    // MARK: - 2. Inverted Coordinate Transformations at Boundaries

    @Test("Boundary: Exact 0.0 and 1.0 full-span coordinates")
    func exactBoundaryCoordinates() {
        let window = CGRect(x: 500, y: 300, width: 1000, height: 800)

        // 1. Full frame (0, 0, 1, 1)
        let fullFrame = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let quartzFull = TextRecognizer.convertVisionRectToQuartz(fullFrame, within: window)
        #expect(quartzFull.origin.x == 500.0)
        #expect(quartzFull.origin.y == 300.0)
        #expect(quartzFull.width == 1000.0)
        #expect(quartzFull.height == 800.0)

        // 2. Exactly at top edge: y + height = 1.0
        let topEdge = CGRect(x: 0.0, y: 0.95, width: 1.0, height: 0.05)
        let quartzTop = TextRecognizer.convertVisionRectToQuartz(topEdge, within: window)
        #expect(abs(quartzTop.origin.y - 300.0) < 1e-9)
        #expect(abs(quartzTop.height - 40.0) < 1e-9)

        // 3. Exactly at bottom edge: y = 0.0
        let bottomEdge = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.05)
        let quartzBottom = TextRecognizer.convertVisionRectToQuartz(bottomEdge, within: window)
        #expect(abs(quartzBottom.origin.y - 1060.0) < 1e-9)
        #expect(abs(quartzBottom.maxY - 1100.0) < 1e-9)
    }

    @Test("Sub-pixel fractions and tiny bounding boxes near 1e-6")
    func subPixelPrecision() {
        let window = CGRect(x: 100, y: 100, width: 1920, height: 1080)
        let tinyVisionRect = CGRect(x: 0.000001, y: 0.999998, width: 0.000002, height: 0.000002)

        let quartz = TextRecognizer.convertVisionRectToQuartz(tinyVisionRect, within: window)
        #expect(abs(quartz.origin.y - 100.0) < 1e-6)
        #expect(quartz.width > 0)
        #expect(quartz.height > 0)

        let candidate = TextRecognizer.makeCandidate(
            text: "tiny",
            visionRect: tinyVisionRect,
            index: 1,
            targetRect: window
        )
        #expect(candidate != nil)
        #expect(candidate?.bounds.width ?? 0 > 0)
    }

    // MARK: - 3. Zero and Negative Window Sizes Vulnerability

    @Test("Zero targetRect window sizes correctly rejected")
    func zeroWindowSizesRejected() {
        let visionRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2)

        let zeroW = CGRect(x: 100, y: 100, width: 0, height: 600)
        #expect(TextRecognizer.makeCandidate(text: "Test", visionRect: visionRect, index: 1, targetRect: zeroW) == nil)

        let zeroH = CGRect(x: 100, y: 100, width: 800, height: 0)
        #expect(TextRecognizer.makeCandidate(text: "Test", visionRect: visionRect, index: 1, targetRect: zeroH) == nil)

        let zeroAll = CGRect(x: 100, y: 100, width: 0, height: 0)
        #expect(TextRecognizer.makeCandidate(text: "Test", visionRect: visionRect, index: 1, targetRect: zeroAll) == nil)
    }

    @Test("Remediated: Negative window size or visionRect safely rejected (returns nil)")
    func negativeWindowSizeVulnerability() {
        let visionRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2)
        let negW = CGRect(x: 100, y: 100, width: -800, height: 600)

        let candidate = TextRecognizer.makeCandidate(text: "Test", visionRect: visionRect, index: 1, targetRect: negW)
        #expect(candidate == nil)

        // Similarly with negative visionRect dimensions:
        let negVisionRect = CGRect(x: 0.5, y: 0.5, width: -0.2, height: 0.2)
        let candidateVision = TextRecognizer.makeCandidate(text: "Test", visionRect: negVisionRect, index: 1, targetRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(candidateVision == nil)
    }

    // MARK: - 4. Overlap Deduplication Adversarial Scenarios & IoMin Failure

    @Test("Remediated: True IoMin deduplication succeeds when AX element is smaller than OCR candidate")
    func overlapIoMinDeduplicationSuccess() {
        // SCENARIO: An AX button (e.g. 40x40) located at center (200, 200).
        // Vision OCR recognizes the button with padding or card bounds (100x100) at center (200, 200).
        // The AX element is 100% physically contained within the OCR candidate.
        let axCandidate = UIElementCandidate(
            id: "ax_1",
            role: "AXButton",
            label: "Search",
            bounds: CGRect(x: 180, y: 180, width: 40, height: 40),
            isActionable: true,
            source: .accessibility
        )
        #expect(axCandidate.center == CGPoint(x: 200, y: 200))
        let axArea = axCandidate.bounds.width * axCandidate.bounds.height // 1600

        let ocrCandidate = UIElementCandidate(
            id: "ocr_1",
            role: "staticText",
            label: "Search",
            bounds: CGRect(x: 150, y: 150, width: 100, height: 100),
            isActionable: true,
            source: .ocr
        )
        #expect(ocrCandidate.center == CGPoint(x: 200, y: 200))
        let ocrArea = ocrCandidate.bounds.width * ocrCandidate.bounds.height // 10000

        let intersection = ocrCandidate.bounds.intersection(axCandidate.bounds)
        let interArea = intersection.width * intersection.height // 1600

        // Mathematical IoMin:
        let trueIoMin = interArea / min(ocrArea, axArea)
        #expect(trueIoMin == 1.0) // 100% overlap according to IoMin!

        // Run remediated implementation with true IoMin:
        let filtered = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [ocrCandidate],
            against: [axCandidate],
            overlapThreshold: 0.60
        )

        #expect(filtered.isEmpty)
    }

    @Test("Overlap Deduplication: Exact bounds match (100% overlap) is filtered")
    func overlapExactBoundsMatch() {
        let axCandidate = UIElementCandidate(
            id: "ax_1",
            role: "AXButton",
            label: "OK",
            bounds: CGRect(x: 100, y: 100, width: 100, height: 40),
            isActionable: true,
            source: .accessibility
        )

        let ocrCandidate = UIElementCandidate(
            id: "ocr_1",
            role: "staticText",
            label: "OK",
            bounds: CGRect(x: 100, y: 100, width: 100, height: 40),
            isActionable: true,
            source: .ocr
        )

        let filtered = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [ocrCandidate],
            against: [axCandidate],
            overlapThreshold: 0.60
        )

        #expect(filtered.isEmpty)
    }

    @Test("Overlap Deduplication: OCR candidate smaller than AX candidate is filtered")
    func overlapOCRInsideAX() {
        let axCandidate = UIElementCandidate(
            id: "ax_1",
            role: "AXButton",
            label: "Submit Form",
            bounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            isActionable: true,
            source: .accessibility
        )

        let ocrCandidate = UIElementCandidate(
            id: "ocr_1",
            role: "staticText",
            label: "Submit",
            bounds: CGRect(x: 160, y: 135, width: 80, height: 30),
            isActionable: true,
            source: .ocr
        )

        let filtered = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [ocrCandidate],
            against: [axCandidate],
            overlapThreshold: 0.60
        )

        #expect(filtered.isEmpty)
    }

    @Test("Overlap Deduplication: Handling empty candidate arrays and zero-area bounds")
    func overlapEmptyAndZeroArea() {
        let axCandidate = UIElementCandidate(
            id: "ax_1",
            role: "AXButton",
            label: "Zero",
            bounds: CGRect(x: 100, y: 100, width: 0, height: 0),
            isActionable: true,
            source: .accessibility
        )

        let ocrCandidate = UIElementCandidate(
            id: "ocr_1",
            role: "staticText",
            label: "Valid",
            bounds: CGRect(x: 100, y: 100, width: 50, height: 50),
            isActionable: true,
            source: .ocr
        )

        let filtered = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [ocrCandidate],
            against: [axCandidate],
            overlapThreshold: 0.60
        )
        #expect(filtered.count == 1)

        let zeroOcr = UIElementCandidate(
            id: "ocr_zero",
            role: "staticText",
            label: "Zero OCR",
            bounds: CGRect(x: 100, y: 100, width: 0, height: 20),
            isActionable: true,
            source: .ocr
        )
        let filteredZero = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [zeroOcr],
            against: [axCandidate],
            overlapThreshold: 0.60
        )
        #expect(filteredZero.isEmpty)
    }

    // MARK: - 5. Sorting Transitivity / Strict Weak Ordering Challenge

    @Test("REMEDIATED: Quantized line band comparator eliminates comparison cycle A < B < C < A")
    func sortingComparisonCycleVulnerabilityRemediated() {
        let rectA = CGRect(x: 0.10, y: 0.480, width: 0.05, height: 0.04)
        let rectB = CGRect(x: 0.20, y: 0.487, width: 0.05, height: 0.04)
        let rectC = CGRect(x: 0.30, y: 0.494, width: 0.05, height: 0.04)

        let aLessThanB = TextRecognizer.isOrderedBefore(rectA: rectA, rectB: rectB)
        let bLessThanC = TextRecognizer.isOrderedBefore(rectA: rectB, rectB: rectC)
        let cLessThanA = TextRecognizer.isOrderedBefore(rectA: rectC, rectB: rectA)

        // Strict weak ordering guarantees NO cycle:
        #expect(aLessThanB == false)
        #expect(bLessThanC == true)
        #expect(cLessThanA == true)
        #expect(!(aLessThanB && bLessThanC && cLessThanA))

        // Sorts deterministically without traps:
        let list = [rectA, rectB, rectC].sorted { TextRecognizer.isOrderedBefore(rectA: $0, rectB: $1) }
        #expect(list == [rectB, rectC, rectA])
    }
}
