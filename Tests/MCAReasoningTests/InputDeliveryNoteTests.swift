import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

/// Fails the n-th key press with a changed target; every other input succeeds.
private final class FailingKeys: EventSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var presses = 0
    let failOn: Int
    let typeError: Error?
    init(failOn: Int = .max, typeError: Error? = nil) { self.failOn = failOn; self.typeError = typeError }
    var pressCount: Int { lock.withLock { presses } }
    var isTrusted: Bool { true }
    func cursorPosition() throws -> CGPoint { .zero }
    func mouseMove(to point: CGPoint) throws {}
    func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws {}
    func drag(from start: CGPoint, to end: CGPoint) throws { throw EventSynthesizer.SynthesizerError.targetChanged }
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws {}
    func typeText(_ text: String) throws { if let typeError { throw typeError } }
    func pressKey(_ key: String) throws {
        let n = lock.withLock { presses += 1; return presses }
        if n == failOn { throw EventSynthesizer.SynthesizerError.targetChanged }
    }
    func releaseAllHeldEvents() {}
}

@Suite("Input delivery note")
struct InputDeliveryNoteTests {
    private func run(_ synthesizer: FailingKeys, _ json: String) async throws -> String {
        let tool = ComputerActionTool(synthesizer: synthesizer, approver: AutoApproveToolApprover(),
                                      screenSpace: ComputerScreenSpace(), trustsCallerApproval: true)
        return try await tool.invoke(arguments: Data(json.utf8))
    }

    @Test("a repeated key stopped part-way reports how many presses went out and that a retry is unsafe")
    func partialKeyRepeat() async throws {
        let synthesizer = FailingKeys(failOn: 3)
        let result = try await run(synthesizer, #"{"action":"key","text":"Down","repeat":5}"#)
        #expect(result.contains("after 2 of 5 inputs were sent"))
        #expect(result.contains("delivery: partial") && result.contains("retry: unsafe"))
        #expect(synthesizer.pressCount == 3)
    }

    @Test("a key refused before the first press was not delivered and is safe to retry")
    func firstKeyRefused() async throws {
        let result = try await run(FailingKeys(failOn: 1), #"{"action":"key","text":"Down","repeat":5}"#)
        #expect(result.contains("delivery: not_delivered; retry: safe"))
    }

    @Test("partial typing reports partial delivery")
    func partialTyping() async throws {
        let error = EventSynthesizer.SynthesizerError.partialInput(sent: 2, total: 5)
        let result = try await run(FailingKeys(typeError: error), #"{"action":"type","text":"hello"}"#)
        #expect(result.contains("after 2 of 5 inputs were sent"))
        #expect(result.contains("delivery: partial"))
    }

    @Test("a drag that fails part-way is uncertain, never safe")
    func dragIsUncertain() async throws {
        let result = try await run(FailingKeys(), #"{"action":"left_click_drag","start_coordinate":[1,1],"coordinate":[5,5]}"#)
        #expect(result.contains("delivery: uncertain") && result.contains("retry: unsafe"))
    }

    @Test("errors the synthesizer did not raise are unknown, never safe")
    func unknownIsUnsafe() {
        struct Other: Error {}
        let note = ComputerActionTool.deliveryNote(for: Other(), action: "left_click")
        #expect(note.hasPrefix("delivery: unknown") && note.contains("retry: unsafe"))
        #expect(ComputerActionTool.deliveryNote(for: CancellationError(), action: "type").contains("retry: unsafe"))
    }

    @Test("validation failures before any event are not delivered",
          arguments: [EventSynthesizer.SynthesizerError.accessibilityPermissionDenied, .coordinateOutOfBounds(x: -1, y: -1),
                      .unknownKey("nope"), .inputTooLong(6000), .unsupported("x")])
    func validationIsNotDelivered(_ error: EventSynthesizer.SynthesizerError) {
        #expect(ComputerActionTool.deliveryNote(for: error, action: "left_click_drag").hasPrefix("delivery: not_delivered"))
    }
}
