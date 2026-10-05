import AppKit
import CoreGraphics
import Foundation
import MCACore
import Testing
import Vision

@testable import MCAPerception

@Suite("TextRecognizer Vision OCR & Bounding Box Extraction")
struct TextRecognizerTests {
    let testWindowFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

    @Test("Converts full frame normalized Vision coordinates to target Quartz rect")
    func fullFrameConversion() {
        let visionRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: testWindowFrame)
        #expect(abs(quartz.origin.x - 100) < 0.001)
        #expect(abs(quartz.origin.y - 200) < 0.001)
        #expect(abs(quartz.width - 800) < 0.001)
        #expect(abs(quartz.height - 600) < 0.001)
    }

    @Test("Converts Vision top-left (high Y) to Quartz top-left (low Y)")
    func topLeftConversion() {
        // In Vision, high Y is near the top of the image
        // Y = 0.8, height = 0.15 -> top edge is 0.95, bottom edge is 0.8
        // In Quartz, distance from top = 1.0 - 0.8 - 0.15 = 0.05
        let visionRect = CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.15)
        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: testWindowFrame)

        let expectedX = 100.0 + (0.1 * 800.0) // 180.0
        let expectedY = 200.0 + (0.05 * 600.0) // 230.0
        let expectedW = 0.4 * 800.0 // 320.0
        let expectedH = 0.15 * 600.0 // 90.0

        #expect(abs(quartz.origin.x - expectedX) < 0.001)
        #expect(abs(quartz.origin.y - expectedY) < 0.001)
        #expect(abs(quartz.width - expectedW) < 0.001)
        #expect(abs(quartz.height - expectedH) < 0.001)
    }

    @Test("Converts Vision bottom-left (low Y) to Quartz bottom-left (high Y)")
    func bottomLeftConversion() {
        // In Vision, Y = 0.0 is the bottom of the image
        // Y = 0.0, height = 0.1 -> in Quartz, distance from top = 1.0 - 0.0 - 0.1 = 0.9
        let visionRect = CGRect(x: 0.05, y: 0.0, width: 0.5, height: 0.1)
        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: testWindowFrame)

        let expectedX = 100.0 + (0.05 * 800.0) // 140.0
        let expectedY = 200.0 + (0.9 * 600.0) // 740.0
        let expectedW = 0.5 * 800.0 // 400.0
        let expectedH = 0.1 * 600.0 // 60.0

        #expect(abs(quartz.origin.x - expectedX) < 0.001)
        #expect(abs(quartz.origin.y - expectedY) < 0.001)
        #expect(abs(quartz.width - expectedW) < 0.001)
        #expect(abs(quartz.height - expectedH) < 0.001)
    }

    @Test("Handles negative window origin coordinates (secondary display)")
    func negativeWindowOriginConversion() {
        let secondaryDisplayFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visionRect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        let quartz = TextRecognizer.convertVisionRectToQuartz(visionRect, within: secondaryDisplayFrame)

        // normY = 1.0 - 0.5 - 0.2 = 0.3
        let expectedX = -1920.0 + (0.5 * 1920.0) // -960.0
        let expectedY = 0.0 + (0.3 * 1080.0) // 324.0

        #expect(abs(quartz.origin.x - expectedX) < 0.001)
        #expect(abs(quartz.origin.y - expectedY) < 0.001)
    }

    @Test("Creates UIElementCandidate with correct properties and center calculation")
    func candidateCreationProperties() {
        let visionRect = CGRect(x: 0.2, y: 0.5, width: 0.4, height: 0.2)
        guard let candidate = TextRecognizer.makeCandidate(
            text: "Click Me",
            visionRect: visionRect,
            index: 1,
            targetRect: testWindowFrame,
            role: "staticText"
        ) else {
            Issue.record("Candidate creation returned nil")
            return
        }

        #expect(candidate.id == "ocr_1")
        #expect(candidate.role == "staticText")
        #expect(candidate.label == "Click Me")
        #expect(candidate.value == nil)
        #expect(candidate.isActionable == true)
        #expect(candidate.source == .ocr)

        // normY = 1.0 - 0.5 - 0.2 = 0.3
        // bounds = (100 + 160, 200 + 180, 320, 120) = (260, 380, 320, 120)
        #expect(abs(candidate.bounds.origin.x - 260.0) < 0.001)
        #expect(abs(candidate.bounds.origin.y - 380.0) < 0.001)
        #expect(abs(candidate.bounds.width - 320.0) < 0.001)
        #expect(abs(candidate.bounds.height - 120.0) < 0.001)

        // Center = (260 + 160, 380 + 60) = (420, 440)
        #expect(abs(candidate.center.x - 420.0) < 0.001)
        #expect(abs(candidate.center.y - 440.0) < 0.001)
    }

    @Test("Prunes whitespace-only strings and degenerate bounding boxes")
    func candidatePruning() {
        let validRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)

        #expect(TextRecognizer.makeCandidate(text: "", visionRect: validRect, index: 1, targetRect: testWindowFrame) == nil)
        #expect(TextRecognizer.makeCandidate(text: "   \n\t  ", visionRect: validRect, index: 1, targetRect: testWindowFrame) == nil)

        let zeroWidth = CGRect(x: 0.1, y: 0.1, width: 0.0, height: 0.2)
        #expect(TextRecognizer.makeCandidate(text: "Text", visionRect: zeroWidth, index: 1, targetRect: testWindowFrame) == nil)

        let zeroHeight = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.0)
        #expect(TextRecognizer.makeCandidate(text: "Text", visionRect: zeroHeight, index: 1, targetRect: testWindowFrame) == nil)
    }

    @Test("Filters out OCR candidates overlapping Accessibility elements")
    func deduplicationWithAX() {
        let axCandidate = UIElementCandidate(
            id: "elem_1",
            role: "AXButton",
            label: "Confirm Order",
            bounds: CGRect(x: 200, y: 300, width: 200, height: 50),
            isActionable: true,
            source: .accessibility
        )

        // OCR candidate inside AX button (e.g. 90% overlap)
        let ocrInside = UIElementCandidate(
            id: "ocr_1",
            role: "staticText",
            label: "Confirm Order",
            bounds: CGRect(x: 220, y: 310, width: 160, height: 30),
            isActionable: true,
            source: .ocr
        )

        // OCR candidate in a non-accessible canvas area (no overlap)
        let ocrCanvas = UIElementCandidate(
            id: "ocr_2",
            role: "staticText",
            label: "Canvas Node A",
            bounds: CGRect(x: 500, y: 100, width: 150, height: 40),
            isActionable: true,
            source: .ocr
        )

        let filtered = TextRecognizer.filterOverlappingCandidates(
            ocrCandidates: [ocrInside, ocrCanvas],
            against: [axCandidate],
            overlapThreshold: 0.60
        )

        #expect(filtered.count == 1)
        #expect(filtered.first?.id == "ocr_2")
        #expect(filtered.first?.label == "Canvas Node A")
    }

    @Test("End-to-end OCR recognition on synthetically rendered image")
    func endToEndImageRecognition() async throws {
        let imgWidth = 400
        let imgHeight = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create CGContext")
            return
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

        let attrStr = NSAttributedString(
            string: "Login Button",
            attributes: [
                .font: NSFont.systemFont(ofSize: 28),
                .foregroundColor: NSColor.black
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else {
            Issue.record("Failed to create CGImage")
            return
        }

        let recognizer = TextRecognizer()
        let windowFrame = CGRect(x: 50, y: 100, width: 400, height: 200)

        let candidates = try await recognizer.recognizeCandidates(
            in: image,
            windowFrame: windowFrame
        )

        #expect(!candidates.isEmpty)
        let match = candidates.first { $0.label.contains("Login") || $0.label.contains("Button") }
        #expect(match != nil)
        if let match {
            #expect(match.source == .ocr)
            #expect(match.id.starts(with: "ocr_"))
            #expect(match.bounds.origin.x >= 50)
            #expect(match.bounds.origin.y >= 100)
            #expect(match.bounds.width > 0)
            #expect(match.bounds.height > 0)
        }

        let text = try await recognizer.recognizeText(in: image)
        #expect(text.contains("Login") || text.contains("Button"))
    }

    // MARK: - Reading Order & Line Band Quantization Tests

    @Test("Quantized line band calculation and finite clamping")
    func quantizedLineBandCalculation() {
        #expect(TextRecognizer.lineBand(for: 0.0) == 0)
        #expect(TextRecognizer.lineBand(for: 1.0) == 100)
        #expect(TextRecognizer.lineBand(for: 0.50) == 50)
        #expect(TextRecognizer.lineBand(for: 0.504) == 50)
        #expect(TextRecognizer.lineBand(for: 0.506) == 51)
        #expect(TextRecognizer.lineBand(for: -0.1) == -10)
        #expect(TextRecognizer.lineBand(for: 1.5) == 150)
        // Non-finite values safely map to 0 without crashing
        #expect(TextRecognizer.lineBand(for: .nan) == 0)
        #expect(TextRecognizer.lineBand(for: .infinity) == 0)
        #expect(TextRecognizer.lineBand(for: -.infinity) == 0)
    }

    @Test("Reading order strict weak ordering axioms (irreflexive, asymmetric, transitive)")
    func readingOrderStrictWeakOrderingAxioms() {
        let r1 = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05)
        let r2 = CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.05)
        let r3 = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05)

        // Irreflexivity: !comp(x, x)
        #expect(!TextRecognizer.isOrderedBefore(rectA: r1, rectB: r1))
        #expect(!TextRecognizer.isOrderedBefore(rectA: r2, rectB: r2))
        #expect(!TextRecognizer.isOrderedBefore(rectA: r3, rectB: r3))

        // Asymmetry: comp(a, b) => !comp(b, a)
        #expect(TextRecognizer.isOrderedBefore(rectA: r1, rectB: r2))
        #expect(!TextRecognizer.isOrderedBefore(rectA: r2, rectB: r1))

        #expect(TextRecognizer.isOrderedBefore(rectA: r2, rectB: r3))
        #expect(!TextRecognizer.isOrderedBefore(rectA: r3, rectB: r2))

        // Transitivity: comp(r1, r2) && comp(r2, r3) => comp(r1, r3)
        #expect(TextRecognizer.isOrderedBefore(rectA: r1, rectB: r3))
    }

    @Test("Remediates sorting comparison cycle A < B < C < A")
    func sortingCycleRemediated() {
        // Point A: midY = 0.500, minX = 0.10
        let rectA = CGRect(x: 0.10, y: 0.480, width: 0.05, height: 0.04)
        // Point B: midY = 0.507, minX = 0.20
        let rectB = CGRect(x: 0.20, y: 0.487, width: 0.05, height: 0.04)
        // Point C: midY = 0.514, minX = 0.30
        let rectC = CGRect(x: 0.30, y: 0.494, width: 0.05, height: 0.04)

        let aLessThanB = TextRecognizer.isOrderedBefore(rectA: rectA, rectB: rectB)
        let bLessThanC = TextRecognizer.isOrderedBefore(rectA: rectB, rectB: rectC)
        let cLessThanA = TextRecognizer.isOrderedBefore(rectA: rectC, rectB: rectA)

        // The old comparator caused aLessThanB && bLessThanC && cLessThanA == true (cycle).
        // With quantized line bands (band 50 for A, band 51 for B and C):
        // B (band 51, x 0.20) < C (band 51, x 0.30) < A (band 50, x 0.10).
        #expect(aLessThanB == false)
        #expect(bLessThanC == true)
        #expect(cLessThanA == true)
        #expect(!(aLessThanB && bLessThanC && cLessThanA))
    }

    @Test("Multi-element 3x3 grid reading order matches top-to-bottom, left-to-right")
    func multiElementGridReadingOrder() {
        let r11 = CGRect(x: 0.1, y: 0.78, width: 0.1, height: 0.04)
        let r12 = CGRect(x: 0.4, y: 0.78, width: 0.1, height: 0.04)
        let r13 = CGRect(x: 0.7, y: 0.78, width: 0.1, height: 0.04)

        let r21 = CGRect(x: 0.1, y: 0.48, width: 0.1, height: 0.04)
        let r22 = CGRect(x: 0.4, y: 0.48, width: 0.1, height: 0.04)
        let r23 = CGRect(x: 0.7, y: 0.48, width: 0.1, height: 0.04)

        let r31 = CGRect(x: 0.1, y: 0.18, width: 0.1, height: 0.04)
        let r32 = CGRect(x: 0.4, y: 0.18, width: 0.1, height: 0.04)
        let r33 = CGRect(x: 0.7, y: 0.18, width: 0.1, height: 0.04)

        let expected = [r11, r12, r13, r21, r22, r23, r31, r32, r33]
        let shuffled = expected.reversed()
        let sorted = shuffled.sorted { TextRecognizer.isOrderedBefore(rectA: $0, rectB: $1) }

        #expect(sorted == expected)
    }
}
