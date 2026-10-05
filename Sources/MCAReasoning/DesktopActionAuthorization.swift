import AppKit
import Foundation
import MCACore
import MCASensing
import os

/// Raw input has no semantic guarantee of being a harmless navigation action.
/// Freeze observed window and candidates for one approval, then verify them again.
public enum DesktopActionAuthorization {
    private static let log = Logger(subsystem: "com.buddypia.mca", category: "DesktopActionAuthorization")

    public static func requireApproval(operation: String, details: String, requestedPID: pid_t? = nil, requestedApp: String? = nil, expected: UIStateSnapshot? = nil) async throws {
        guard let session = ActionAuthorization.current else { throw ActionAuthorizationError.approvalRequired }
        guard let selected = session.targetWindow else { throw stale("no window selected") }
        let before: UIStateSnapshot
        if let expected { before = expected }
        else if let observed = await session.nativeObservation { before = observed }
        else { throw stale("nothing observed yet") }
        guard let bundle = before.appBundleId, let title = before.windowTitle,
              !before.visibleCandidates.isEmpty else { throw stale("observation lacks app, title or candidates") }
        guard selected.bundleID == bundle, selected.windowTitle == title else {
            throw stale("observation is not of the selected window")
        }
        if let requestedApp, requestedApp.caseInsensitiveCompare(before.appName ?? "") != .orderedSame {
            throw stale("requested app differs from the observed one")
        }

        let inspector = InspectUIElementsTool.makeDefaultInspector(maxCandidates: before.candidateLimit ?? 25)
        guard matchesObservation(before, try await inspector.captureSnapshot(), operation: operation) else {
            throw stale("screen changed since it was observed")
        }
        guard let processID = await resolveProcess(selected: selected, bundle: bundle) else {
            throw stale("target process is not uniquely identifiable")
        }
        if let requestedPID, requestedPID != processID { throw stale("requested PID differs") }
        guard windowIDs(pid: processID, title: title) == [selected.id] else {
            throw stale("selected window is not the only window with this title")
        }

        try await ActionAuthorization.requireApproval(operation: "Desktop: " + operation,
            target: "\(before.appName ?? bundle) — \(title) (PID \(processID))", details: details,
            revalidate: {
                // Cheapest-to-change check last: the slow AX read happens first, and focus is
                // confirmed after it, immediately before control returns to the dispatch.
                let after = try await inspector.captureSnapshot()
                guard matchesObservation(before, after, operation: operation),
                      windowIDs(pid: processID, title: title) == [selected.id] else { return false }
                return await MainActor.run {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
                }
            })
    }

    static func matchesObservation(_ before: UIStateSnapshot, _ after: UIStateSnapshot, operation: String) -> Bool {
        guard before.appBundleId == after.appBundleId, before.windowTitle == after.windowTitle,
              before.visibleCandidates == after.visibleCandidates else { return false }
        // These operations use frozen coordinates, not the currently focused field.
        // The approval UI may restore focus to the selected window. Unknown and
        // keyboard-dependent operations retain strict field identity checks.
        switch operation {
        case "Click element", "click", "left_click", "right_click", "double_click", "triple_click",
             "middle_click", "left_click_drag", "scroll", "mouse_move":
            return true
        default:
            return before.focusedElementId == after.focusedElementId
                && before.focusedElementRole == after.focusedElementRole
                && before.focusedElementBounds == after.focusedElementBounds
        }
    }

    /// The pinned PID is the identity and the bundle only confirms it. Looking the bundle up and
    /// taking `.first` guessed between instances (two Chrome processes, `open -n`), refusing the
    /// right one. A window pinned without a PID stays refused, as before.
    private static func resolveProcess(selected: PinnedWindow, bundle: String) async -> pid_t? {
        guard let pid = selected.processID else { return nil }
        return await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.bundleIdentifier == bundle else { return nil }
            return pid
        }
    }

    /// Every refusal is the same error to the caller; the reason goes to the log for diagnosis.
    /// Reasons are fixed strings, so no window title or screen text reaches the log.
    private static func stale(_ reason: StaticString) -> ActionAuthorizationError {
        log.info("Desktop action refused: \(reason, privacy: .public)")
        return .staleTarget
    }

    private static func windowIDs(pid: pid_t, title: String) -> [UInt32] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  entry[kCGWindowName as String] as? String == title,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
}
