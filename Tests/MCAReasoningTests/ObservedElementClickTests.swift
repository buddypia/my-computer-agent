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

    private func scopedSession(observed: UIStateSnapshot?) async -> ActionAuthorization {
        let session = ActionAuthorization(goal: "fixture", requestApproval: { _ in .approved },
            targetWindow: PinnedWindow(id: 1, appName: "Mail", windowTitle: "Inbox", bundleID: "com.apple.mail", processID: getpid()),
            requiresWindowScope: true)
        if let observed { await session.recordNativeObservation(observed) }
        return session
    }

    /// A label the model read on screen but the turn's first observation lacked (or no
    /// observation at all) used to raise `staleTarget`, which ended the session; every retry
    /// of the request then ended with the same error.
    @Test("A missing or ambiguous label is returned to the model without ending the session",
          arguments: [["Reply"], ["Send", "Send"]])
    func lookupFailureKeepsSession(labels: [String]) async throws {
        let now = UIStateSnapshot(appBundleId: "com.apple.mail", appName: "Mail",
            visibleCandidates: labels.enumerated().map { candidate("e\($0.offset)", label: $0.element) }, timestamp: .now)
        let synthesizer = DryRunEventSynthesizer()
        let tool = ClickElementTool(synthesizer: synthesizer, inspectorProvider: { _ in FixedSnapshotProvider(snapshot: now) })
        let session = await scopedSession(observed: nil)
        let result = try await ActionAuthorization.withSession(session) {
            try await tool.invoke(arguments: Data(#"{"element_text":"Send"}"#.utf8))
        }
        #expect(result.hasPrefix("Error:") && result.contains("nothing was clicked"))
        #expect(synthesizer.recordedActions.isEmpty)
        #expect(await session.terminalFailure == nil)
        #expect(await session.nativeObservation?.visibleCandidates == now.visibleCandidates)
    }

    @Test("The refusal names close labels so the next call can use an exact one")
    func lookupRefusalNamesSimilarLabels() {
        let snapshot = UIStateSnapshot(visibleCandidates: [candidate("a", label: "Send now"), candidate("b", label: "Archive")], timestamp: .now)
        let refusal = ClickElementTool.lookupRefusal(snapshot, text: "send", role: nil)
        #expect(refusal.contains("'Send now'") && !refusal.contains("Archive"))
        #expect(ClickElementTool.lookupRefusal(UIStateSnapshot(visibleCandidates: [candidate("a", label: "Send"), candidate("b", label: "Send")], timestamp: .now),
                                               text: "Send", role: nil).contains("2 elements"))
    }

    @Test("Without a selected window the click is still refused as a stale target")
    func noSelectedWindowStillRefused() async {
        let tool = ClickElementTool(synthesizer: DryRunEventSynthesizer(),
            inspectorProvider: { _ in FixedSnapshotProvider(snapshot: UIStateSnapshot(visibleCandidates: [], timestamp: .now)) })
        let session = ActionAuthorization(goal: "fixture", requestApproval: { _ in .approved }, requiresWindowScope: true)
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ActionAuthorization.withSession(session) {
                _ = try await tool.invoke(arguments: Data(#"{"element_text":"Send"}"#.utf8))
            }
        }
    }

    private func partial(_ candidates: [UIElementCandidate], limit: Int? = 25, complete: Bool? = false) -> UIStateSnapshot {
        UIStateSnapshot(visibleCandidates: candidates, timestamp: .now, candidateLimit: limit, observationComplete: complete)
    }

    /// `candidates` padded with other elements up to `limit`, as a list cut at its cap is.
    private func full(_ candidates: [UIElementCandidate], to limit: Int = 25) -> [UIElementCandidate] {
        candidates + (candidates.count..<limit).map { candidate("fill_\($0)", label: "Item \($0)") }
    }

    @Test("A twin past the cut of a partial observation makes the target ambiguous")
    func partialObservationTwinIsRefused() async {
        let observed = partial(full([candidate("elem_3", label: "Reply")]))
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
        let observed = partial(full([candidate("elem_3", label: "Reply")]))
        let wider = partial([candidate("elem_3", label: "Reply"), candidate("elem_41", label: "Forward")], limit: 100)
        let probe = RecountProbe()
        try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                 inspectorProvider: probe.provider(wider))
        #expect(probe.requested == [ClickElementTool.recountLimit])
    }

    @Test("A target that vanished from the wider observation is refused")
    func partialObservationTargetGone() async {
        let observed = partial(full([candidate("elem_3", label: "Reply")]))
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                     inspectorProvider: RecountProbe().provider(partial([], limit: 100)))
        }
    }

    @Test("Complete, unreported and already-wide observations are not observed again",
          arguments: [(Bool?.some(true), Int?.some(25)), (nil, 25), (false, 100)])
    func noRecountWhenNotNeeded(complete: Bool?, limit: Int?) async throws {
        let observed = partial(full([candidate("elem_3", label: "Reply")], to: limit ?? 25), limit: limit, complete: complete)
        let probe = RecountProbe()
        try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                 inspectorProvider: probe.provider(partial([])))
        #expect(probe.requested.isEmpty)
    }

    @Test("A partial list shorter than its cap stopped at a limit a wider cap does not move, so it is not observed again")
    func partialBelowCapIsNotObservedAgain() async throws {
        let observed = partial([candidate("elem_3", label: "Reply")])
        let probe = RecountProbe()
        try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                 inspectorProvider: probe.provider(partial([])))
        #expect(probe.requested.isEmpty)
    }

    @Test("A partial observation without a reported cap is still observed again")
    func partialWithoutCapIsObservedAgain() async {
        let observed = partial([candidate("elem_3", label: "Reply")], limit: nil)
        let wider = partial([candidate("elem_3", label: "Reply"), candidate("elem_41", label: "Reply")], limit: 100)
        let probe = RecountProbe()
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ClickElementTool.confirmUnique(in: observed, text: "Reply", role: nil,
                                                     inspectorProvider: probe.provider(wider))
        }
        #expect(probe.requested == [ClickElementTool.recountLimit])
    }

    @Test("Observation completeness survives encoding, and older snapshots decode as unknown")
    func completenessCodable() throws {
        let encoded = try JSONEncoder().encode(partial([], complete: false))
        #expect(try JSONDecoder().decode(UIStateSnapshot.self, from: encoded).observationComplete == false)
        let legacy = Data(#"{"visibleCandidates":[],"timestamp":0}"#.utf8)
        #expect(try JSONDecoder().decode(UIStateSnapshot.self, from: legacy).observationComplete == nil)
    }

    @Test("A disabled element is refused without input; an unreadable state is not treated as disabled",
          arguments: [(Bool?.some(false), false), (nil, true), (true, true)])
    func disabledElementIsRefused(enabled: Bool?, clicks: Bool) async throws {
        var button = candidate("send", label: "Send")
        button.isEnabled = enabled
        let snapshot = UIStateSnapshot(appName: "Mail", visibleCandidates: [button], timestamp: .now)
        let synthesizer = DryRunEventSynthesizer()
        let tool = ClickElementTool(synthesizer: synthesizer,
                                    inspectorProvider: { _ in FixedSnapshotProvider(snapshot: snapshot) },
                                    trustsCallerApproval: true)
        let result = try await tool.invoke(arguments: Data(#"{"element_text":"Send"}"#.utf8))
        if clicks {
            #expect(result.hasPrefix("Clicked observed element"))
            #expect(synthesizer.recordedActions.count == 1)
        } else {
            #expect(result.hasPrefix("Error:") && result.contains("disabled"))
            #expect(synthesizer.recordedActions.isEmpty)
        }
    }

    @Test("The enabled state survives encoding, and older candidates decode as unknown")
    func enabledCodable() throws {
        var button = candidate("send", label: "Send")
        button.isEnabled = false
        let decoded = try JSONDecoder().decode(UIElementCandidate.self, from: JSONEncoder().encode(button))
        #expect(decoded.isEnabled == false)
        let legacy = Data(#"{"id":"a","role":"AXButton","label":"OK","bounds":[[0,0],[10,10]]}"#.utf8)
        #expect(try JSONDecoder().decode(UIElementCandidate.self, from: legacy).isEnabled == nil)
    }

    @Test("An enabled-state flip alone changes the candidates fingerprint")
    func enabledFlipChangesHash() {
        var button = candidate("send", label: "Send")
        button.isEnabled = false
        let before = UIStateSnapshot(visibleCandidates: [button], timestamp: .now)
        button.isEnabled = true
        let after = UIStateSnapshot(visibleCandidates: [button], timestamp: .now)
        #expect(before.candidatesHash != after.candidatesHash)
    }
}
