import CoreGraphics
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Observed element click binding")
struct ObservedElementClickTests {
    private func candidate(_ id: String, label: String) -> UIElementCandidate {
        UIElementCandidate(id: id, role: "AXButton", label: label, bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
    }
    @Test("Only a unique actionable element in the observed window resolves")
    func uniqueObservedElement() throws {
        let selected = candidate("observed", label: "Delete")
        let snapshot = UIStateSnapshot(visibleCandidates: [selected], timestamp: .now)
        #expect(try ClickElementTool.observedCandidate(snapshot, text: "Delete", role: "button") == selected)
        #expect(throws: ActionAuthorizationError.staleTarget) {
            try ClickElementTool.observedCandidate(snapshot, text: "Del", role: nil)
        }
        let ambiguous = UIStateSnapshot(visibleCandidates: [selected, candidate("other", label: "Delete")], timestamp: .now)
        #expect(throws: ActionAuthorizationError.staleTarget) {
            try ClickElementTool.observedCandidate(ambiguous, text: "Delete", role: nil)
        }
    }
    private func observedSnapshot(focused: Bool) -> UIStateSnapshot {
        UIStateSnapshot(windowTitle: "Selected", appBundleId: "fixture.selected",
            focusedElementId: focused ? "input" : nil, focusedElementRole: focused ? "AXTextField" : nil,
            focusedElementBounds: focused ? CGRect(x: 10, y: 70, width: 100, height: 30) : nil,
            visibleCandidates: [candidate("delete", label: "Delete")], timestamp: .now)
    }

    @Test("Approved coordinate operations tolerate selected-window focus restoration", arguments:
        ["Click element", "click", "left_click", "right_click", "double_click", "triple_click", "middle_click", "left_click_drag", "scroll", "mouse_move"])
    func selectedWindowFocusRestoration(operation: String) {
        #expect(DesktopActionAuthorization.matchesObservation(observedSnapshot(focused: false),
            observedSnapshot(focused: true), operation: operation))
    }

    @Test("Keyboard and unknown operations retain focused-element binding", arguments: ["type", "key", "Run AppleScript", "Open file or handler"])
    func focusedOperationsRejectChangedFocus(operation: String) {
        let before = observedSnapshot(focused: true)
        #expect(!DesktopActionAuthorization.matchesObservation(before, observedSnapshot(focused: false), operation: operation))
        var changed = before
        changed.focusedElementId = "other"
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = before
        changed.focusedElementRole = "AXButton"
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = before
        changed.focusedElementBounds = CGRect(x: 20, y: 70, width: 100, height: 30)
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
    }

    @Test("Restored focus never permits a changed window or candidate", arguments: ["click", "scroll", "Click element"])
    func coordinateOperationsRejectChangedObservation(operation: String) {
        let before = observedSnapshot(focused: false)
        let restored = observedSnapshot(focused: true)
        var changed = restored
        changed.appBundleId = "fixture.other"
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = restored
        changed.windowTitle = "Other window"
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = restored
        changed.visibleCandidates = [candidate("delete", label: "Different action")]
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = restored
        changed.visibleCandidates = []
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
    }

}
