import ApplicationServices
@testable import MCASensing
import Testing

@Suite("AXPressOutcome")
struct AXPressOutcomeTests {
    @Test("only a missing action allows the pointer fallback")
    func onlyUnsupportedFallsBack() {
        #expect(AXPressOutcome(.actionUnsupported) == .unsupported)
        #expect(AXPressOutcome(.notImplemented) == .unsupported)
    }

    @Test("success is delivered")
    func successIsDelivered() {
        #expect(AXPressOutcome(.success) == .delivered)
    }

    @Test("a failure the app may already have acted on is uncertain, not a reason to click again",
          arguments: [AXError.failure, .cannotComplete, .noValue, .attributeUnsupported, .notEnoughPrecision])
    func ambiguousFailuresAreUncertain(_ code: AXError) {
        guard case .uncertain = AXPressOutcome(code) else {
            Issue.record("\(code.rawValue) must not be treated as safe to fall back")
            return
        }
    }

    @Test("refusals that never reached the app are not delivered",
          arguments: [AXError.invalidUIElement, .illegalArgument])
    func refusalsAreNotDelivered(_ code: AXError) {
        guard case .notDelivered = AXPressOutcome(code) else {
            Issue.record("\(code.rawValue) should be reported as not delivered")
            return
        }
    }

    @Test("disabled Accessibility access is a permission problem, not a stale page")
    func apiDisabledIsPermission() {
        #expect(AXPressOutcome(.apiDisabled) == .permissionDenied)
    }

    @Test("a multi-event input that stops part-way is partial, but cancellation stays cancellation")
    func stoppedInput() {
        let changed = EventSynthesizer.stopped(after: 2, of: 5, by: EventSynthesizer.SynthesizerError.targetChanged)
        guard case EventSynthesizer.SynthesizerError.partialInput(let sent, let total, _) = changed else {
            Issue.record("expected partialInput, got \(changed)")
            return
        }
        #expect(sent == 2 && total == 5)
        #expect(EventSynthesizer.stopped(after: 2, of: 5, by: CancellationError()) is CancellationError)
        guard case EventSynthesizer.SynthesizerError.targetChanged =
                EventSynthesizer.stopped(after: 0, of: 5, by: EventSynthesizer.SynthesizerError.targetChanged) else {
            Issue.record("nothing sent must keep the original error")
            return
        }
    }

    @Test("an element that cannot be read does not claim to lack AXPress")
    func unreadableActionListIsUnknown() {
        let detached = AXUIElementCreateApplication(-1)
        #expect(AX.advertises(detached, action: kAXPressAction) == nil)
    }
}
