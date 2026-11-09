import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import MCASensing
import Testing

private struct FixedSnapshotProvider: UIStateProviding {
    let snapshot: UIStateSnapshot
    func captureSnapshot() async throws -> UIStateSnapshot { snapshot }
}

/// Records the candidate cap each wider observation was requested with.
private final class RecountProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var limits: [Int] = []
    var requested: [Int] { lock.withLock { limits } }
    func provider(_ snapshot: UIStateSnapshot) -> @Sendable (Int) -> any UIStateProviding {
        { limit in
            self.lock.withLock { self.limits.append(limit) }
            return FixedSnapshotProvider(snapshot: snapshot)
        }
    }
}

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
        ["Click element", "click", "left_click", "right_click", "double_click", "triple_click", "middle_click", "left_click_drag", "left_mouse_down", "left_mouse_up", "scroll", "mouse_move", "Click and type", "Click and press key"])
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

    @Test("Restored focus never permits a changed app or candidate", arguments: ["click", "scroll", "Click element"])
    func coordinateOperationsRejectChangedObservation(operation: String) {
        let before = observedSnapshot(focused: false)
        let restored = observedSnapshot(focused: true)
        var changed = restored
        changed.appBundleId = "fixture.other"
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = restored
        changed.visibleCandidates = [candidate("delete", label: "Different action")]
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
        changed = restored
        changed.visibleCandidates = []
        #expect(!DesktopActionAuthorization.matchesObservation(before, changed, operation: operation))
    }

    /// A browser window's title follows its tab ("Home / X" → "(1) Home / X"). Which window it
    /// is gets settled by window ID; a title change alone must not refuse the selected window.
    @Test("A title change alone is not a changed observation", arguments: ["click", "scroll", "Click element", "type"])
    func titleChangeIsNotIdentity(operation: String) {
        let before = observedSnapshot(focused: true)
        var retitled = before
        retitled.windowTitle = "(1) Selected"
        #expect(DesktopActionAuthorization.matchesObservation(before, retitled, operation: operation))
        retitled.visibleCandidates = [candidate("delete", label: "Different action")]
        #expect(!DesktopActionAuthorization.matchesObservation(before, retitled, operation: operation))
    }

    @Test("Caller-approved ClickElementTool inspects and clicks a unique element, and verifies app_name")
    func callerApprovedClickElement() async throws {
        let selected = candidate("ok-btn", label: "OK")
        let snapshot = UIStateSnapshot(
            windowTitle: "Dialog", appBundleId: "com.apple.Notes", appName: "Notes",
            visibleCandidates: [selected], timestamp: .now)
        let synthesizer = DryRunEventSynthesizer()
        let tool = ClickElementTool(
            synthesizer: synthesizer,
            inspectorProvider: { _ in FixedSnapshotProvider(snapshot: snapshot) },
            trustsCallerApproval: true)
        let result = try await tool.invoke(arguments: Data(#"{"element_text":"OK","role":"button","app_name":"Notes"}"#.utf8))
        #expect(result == "Clicked observed element 'OK' (ok-btn).")
        #expect(synthesizer.recordedActions == ["click(at: (25, 40), button: left, clickCount: 1)"])

        await #expect(throws: ActionAuthorizationError.staleTarget) {
            _ = try await tool.invoke(arguments: Data(#"{"element_text":"OK","app_name":"Safari"}"#.utf8))
        }
        let unapproved = ClickElementTool(
            synthesizer: synthesizer,
            inspectorProvider: { _ in FixedSnapshotProvider(snapshot: snapshot) },
            trustsCallerApproval: false)
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            _ = try await unapproved.invoke(arguments: Data(#"{"element_text":"OK"}"#.utf8))
        }
    }

    private func partial(_ candidates: [UIElementCandidate], limit: Int? = 25, complete: Bool? = false) -> UIStateSnapshot {
        UIStateSnapshot(visibleCandidates: candidates, timestamp: .now, candidateLimit: limit, observationComplete: complete)
    }

    @Test("A twin past the cut of a partial observation makes the target ambiguous")
    func partialObservationTwinIsRefused() async {
        let observed = partial([candidate("elem_3", label: "Reply")])
        let wider = partial([candidate("elem_3", label: "Reply"), candidate("elem_41", label: "Reply")], limit: 100)
        let probe = RecountProbe()
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                     inspectorProvider: probe.provider(wider))
        }
        #expect(probe.requested == [ClickElementTool.recountLimit])
    }

    @Test("A partial observation passes when the wider one also finds exactly one")
    func partialObservationConfirmedUnique() async throws {
        let observed = partial([candidate("elem_3", label: "Reply")])
        let wider = partial([candidate("elem_3", label: "Reply"), candidate("elem_41", label: "Forward")], limit: 100)
        let probe = RecountProbe()
        try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                 inspectorProvider: probe.provider(wider))
        #expect(probe.requested == [ClickElementTool.recountLimit])
    }

    @Test("A target that vanished from the wider observation is refused")
    func partialObservationTargetGone() async {
        let observed = partial([candidate("elem_3", label: "Reply")])
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                     inspectorProvider: RecountProbe().provider(partial([], limit: 100)))
        }
    }

    @Test("Complete, unreported and already-wide observations are not observed again",
          arguments: [(Bool?.some(true), Int?.some(25)), (nil, 25), (false, 100)])
    func noRecountWhenNotNeeded(complete: Bool?, limit: Int?) async throws {
        let observed = partial([candidate("elem_3", label: "Reply")], limit: limit, complete: complete)
        let probe = RecountProbe()
        try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                 inspectorProvider: probe.provider(partial([])))
        #expect(probe.requested.isEmpty)
    }

    @Test("Observation completeness survives encoding, and older snapshots decode as unknown")
    func completenessCodable() throws {
        let encoded = try JSONEncoder().encode(partial([], complete: false))
        #expect(try JSONDecoder().decode(UIStateSnapshot.self, from: encoded).observationComplete == false)
        let legacy = Data(#"{"visibleCandidates":[],"timestamp":0}"#.utf8)
        #expect(try JSONDecoder().decode(UIStateSnapshot.self, from: legacy).observationComplete == nil)
    }
}
