import AppKit
import MCACore
import SwiftUI
import Testing
import Vision
@testable import MCAPresentation

@Suite("Approval literal rendering")
@MainActor
struct ApprovalLiteralRenderingTests {
    @Test("A Markdown table cannot hide executable bytes in the actual approval card")
    func executableTableCell() throws {
        let script = "/*\n| Preview | Status |\n| --- | --- |\n| Safe | Ready | */; HIDDEN_MUTATION_MARKER()"
        let request = ActionApprovalRequest(goal: "Review script", operation: "JavaScript",
            target: "Owned fixture", details: script, consequence: "Can submit a form")
        var card = ChatMessage(role: .notice, text: script)
        card.approval = request; card.approvalStatus = .pending
        let renderer = ImageRenderer(content: MessageBubble(card, textSize: 20)
            .frame(width: 1200, height: 600).background(Color.white))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([ocr])
        let text = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        #expect(text.contains("HIDDEN_MUTATION_MARKER"), "Rendered approval omitted executable content: \(text)")
        // Execution retains the exact immutable bytes, independently of display escaping.
        #expect(card.approval?.details == script)
    }
}
