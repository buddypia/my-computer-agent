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
    let pressError: Error
    let clickError: Error?
    init(failOn: Int = .max, typeError: Error? = nil,
         pressError: Error = EventSynthesizer.SynthesizerError.targetChanged, clickError: Error? = nil) {
        self.failOn = failOn; self.typeError = typeError; self.pressError = pressError; self.clickError = clickError
    }
    var pressCount: Int { lock.withLock { presses } }
    var isTrusted: Bool { true }
    func cursorPosition() throws -> CGPoint { .zero }
    func mouseMove(to point: CGPoint) throws {}
    func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws { if let clickError { throw clickError } }
    func drag(from start: CGPoint, to end: CGPoint) throws { throw EventSynthesizer.SynthesizerError.targetChanged }
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws {}
    func typeText(_ text: String) throws { if let typeError { throw typeError } }
    func pressKey(_ key: String) throws {
        let n = lock.withLock { presses += 1; return presses }
        if n == failOn { throw pressError }
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
        #expect(result.contains("Input target changed") && result.contains("after 2 of 5 inputs were sent"))
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
        let error = EventSynthesizer.SynthesizerError.partialInput(sent: 2, total: 5, reason: "Input target changed.")
        let result = try await run(FailingKeys(typeError: error), #"{"action":"type","text":"hello"}"#)
        #expect(result.contains("after 2 of 5 inputs were sent"))
        #expect(result.contains("delivery: partial"))
    }

    @Test("a drag that fails part-way is uncertain, never safe")
    func dragIsUncertain() async throws {
        let result = try await run(FailingKeys(), #"{"action":"left_click_drag","start_coordinate":[1,1],"coordinate":[5,5]}"#)
        #expect(result.contains("delivery: uncertain") && result.contains("retry: unsafe"))
    }

    @Test("a click refused at the target check was not delivered, though the pointer may have moved")
    func clickNotDelivered() {
        let note = ComputerActionTool.deliveryNote(for: EventSynthesizer.SynthesizerError.targetChanged, action: "left_click")
        #expect(note == "delivery: not_delivered (the pointer may have moved); retry: safe")
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
        #expect(ComputerActionTool.deliveryNote(for: error, action: "left_click").hasPrefix("delivery: not_delivered"))
    }

    /// A drag validates its end point and permission again after the button went down.
    @Test("no error of a drag or held input is reported as safe",
          arguments: ["left_click_drag", "left_mouse_down", "left_mouse_up", "hold_key"])
    func multiEventNeverSafe(_ action: String) {
        for error in [EventSynthesizer.SynthesizerError.coordinateOutOfBounds(x: 9999, y: 9999), .accessibilityPermissionDenied, .targetChanged] {
            #expect(ComputerActionTool.deliveryNote(for: error, action: action).hasPrefix("delivery: uncertain"))
        }
    }

    @Test("a cancelled key repeat is thrown as a cancellation, not reported as a partial input")
    func cancelledRepeatIsNotPartial() async throws {
        let synthesizer = FailingKeys(failOn: 3, pressError: CancellationError())
        await #expect(throws: CancellationError.self) {
            _ = try await run(synthesizer, #"{"action":"key","text":"Down","repeat":5}"#)
        }
        #expect(synthesizer.pressCount == 3)
    }

    @Test("a cancelled click is thrown, not returned as text, so the registry ends the action session")
    func cancelledClickIsThrown() async throws {
        let synthesizer = FailingKeys(clickError: CancellationError())
        await #expect(throws: CancellationError.self) {
            _ = try await run(synthesizer, #"{"action":"left_click","coordinate":[10,10]}"#)
        }
    }
}
