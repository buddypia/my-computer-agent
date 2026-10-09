import AppKit
import ApplicationServices
import Foundation
import MCACore
import OSLog

/// Inspects the frontmost application window's Accessibility hierarchy,
/// extracting actionable UI element candidates with precise screen coordinates.
///
/// Performance Optimization:
/// - Batches attribute queries via `AXUIElementCopyMultipleAttributeValues`,
///   reducing Mach message IPC calls from 5-6 calls per element to 1 call.
/// - Performs window bounds clipping to discard off-screen / scrolled elements,
///   pruning off-screen sub-trees and guaranteeing that candidates are visible
///   and clickable within the active window viewport (< 40ms inspection latency).
public struct AccessibilityInspector: Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "AccessibilityInspector")
    private let privacyFilter: PrivacyFilter

    /// Fallback candidate provider (e.g. OCR) when Accessibility hierarchy yields no candidates.
    public typealias CandidateFallbackProvider = @Sendable (_ pid: pid_t, _ windowBounds: CGRect?) async -> [UIElementCandidate]

    private let fallbackProvider: CandidateFallbackProvider?
    private let targetWindow: PinnedWindow?
    private let requiresWindowScope: Bool

    public enum SnapshotError: LocalizedError, Sendable {
        case selectedWindowUnavailable
        case selectedWindowExcluded
        case selectedWindowFocusFailed
        public var errorDescription: String? {
            switch self {
            case .selectedWindowUnavailable: return "The selected window could not be identified; no other window was inspected."
            case .selectedWindowExcluded: return "The selected window is excluded from screen inspection."
            case .selectedWindowFocusFailed: return "Focus could not be restored to the selected window; no input was sent."
            }
        }
    }

    /// Maximum number of actionable candidates returned to prevent token explosion.
    public let maxCandidates: Int

    /// How long one AX query may block. The system default is about 6s, and a
    /// busy app (Firefox scrolling a heavy page) answers every query at that
    /// limit, so an 800-node walk could block for over an hour.
    static let messagingTimeout: Float = 0.5
    /// Wall-clock budget for one tree walk; past it the walk returns what it has.
    static let traversalBudget: Duration = .seconds(3)

    public init(
        maxCandidates: Int = 25,
        privacyFilter: PrivacyFilter = PrivacyFilter(),
        fallbackProvider: CandidateFallbackProvider? = nil,
        targetWindow: PinnedWindow? = nil,
        requiresWindowScope: Bool = false
    ) {
        self.maxCandidates = min(max(maxCandidates, 0), 100)
        Self.boundQueries
        self.privacyFilter = privacyFilter
        self.fallbackProvider = fallbackProvider
        self.targetWindow = targetWindow
        self.requiresWindowScope = requiresWindowScope
    }

    /// Primary actionable roles that an AI agent commonly interacts with.
    public static let actionableRoles: Set<String> = [
        "AXButton",
        "AXTextField",
        "AXTextArea",
        "AXPopUpButton",
        "AXMenuItem",
        "AXMenuButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXTab",
        "AXLink",
        "AXComboBox",
        "AXSearchField",
        "AXCell",
        "AXRow",
        "AXScrollArea", // Required for R2 scroll targeting
        "AXSlider",     // Interactive control
        "AXHeading",    // Headings and section titles
    ]

    /// Roles whose children are geometrically strictly contained within the element.
    /// When an element of these roles has valid bounds that lie completely outside
    /// the window frame, neither the element nor its sub-tree can be visible on screen.
    public static let subTreePruningRoles: Set<String> = [
        "AXRow",
        "AXCell",
        "AXListItem",
        "AXStaticText",
        "AXButton",
        "AXTextField",
        "AXTextArea",
        "AXCheckBox",
        "AXRadioButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXMenuButton",
        "AXTab",
        "AXLink",
        "AXComboBox",
        "AXSearchField",
    ]

    /// Resolves the frontmost application belonging to an external process,
    /// inspecting the true window z-order when MCA's own window is in front.
    public static func frontmostExternalApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            return front
        }

        // True z-order resolution: look through on-screen windows from top to bottom
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for winInfo in windowList {
                guard let layer = winInfo[kCGWindowLayer as String] as? Int, layer == 0,
                      let ownerPID = winInfo[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID != ownPID,
                      let app = NSRunningApplication(processIdentifier: ownerPID),
                      app.activationPolicy == .regular,
                      !app.isTerminated,
                      !app.isHidden
                else { continue }
                return app
            }
        }

        // Secondary fallback to running applications list
        return NSWorkspace.shared.runningApplications.first { candidate in
            candidate.processIdentifier != ownPID &&
            candidate.activationPolicy == .regular &&
            !candidate.isTerminated &&
            !candidate.isHidden
        }
    }

    /// Resolves the on-screen window bounding box for a process from Quartz Window Server.
    public static func resolveWindowBoundsFromWindowList(pid: pid_t) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for winInfo in windowList {
            guard let ownerPID = winInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = winInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = winInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return bounds
        }
        return nil
    }

    /// Validates that a rectangle has finite, non-NaN coordinates and strictly positive dimensions exceeding `minDimension`.
    public static func isValidCoordinateRect(_ rect: CGRect, minDimension: CGFloat = 0) -> Bool {
        guard !rect.isNull,
              !rect.isEmpty,
              !rect.isInfinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.size.width > minDimension,
              rect.size.height > minDimension else {
            return false
        }
        return true
    }

    /// Clips element bounds to the visible window frame.
    /// Returns nil if the element is completely outside the window or if the visible area is negligible (< 3x3 pt),
    /// or if coordinates are malformed (NaN, Infinite, negative, or degenerate).
    public static func clipBoundsToWindow(_ bounds: CGRect, windowBounds: CGRect?) -> CGRect? {
        guard isValidCoordinateRect(bounds, minDimension: 2) else {
            return nil
        }

        guard let windowBounds else {
            return bounds
        }

        guard isValidCoordinateRect(windowBounds, minDimension: 0) else {
            return nil
        }

        let intersection = bounds.intersection(windowBounds)
        guard isValidCoordinateRect(intersection, minDimension: 2) else {
            return nil
        }

        return intersection
    }

    /// Inspects the active/focused window of the frontmost application.
    /// If `targetPID` is provided, inspects that application instead of the frontmost.
    public func inspectFocusedWindow(targetPID: pid_t? = nil) -> [UIElementCandidate] {
        // Selected-window inspection requires asynchronous fresh identity validation.
        guard targetWindow == nil, !requiresWindowScope else { return [] }
        guard AXIsProcessTrusted() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let targetApp: NSRunningApplication?
        if let targetPID {
            guard targetPID != ownPID else {
                log.info("Target PID is own application; skipping in-process inspection.")
                return []
            }
            targetApp = NSRunningApplication(processIdentifier: targetPID)
        } else {
            targetApp = Self.frontmostExternalApplication()
        }

        guard let frontApp = targetApp, frontApp.processIdentifier != ownPID else { return [] }

        // Enforce privacy blocklist
        if privacyFilter.isApplicationBlocked(bundleID: frontApp.bundleIdentifier) {
            log.warning("App \(frontApp.bundleIdentifier ?? "unknown") is in privacy blocklist; skipping inspection.")
            return []
        }

        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXAttributes.enableEnhancedAccessibility(app: axApp)

        guard let window = copyElement(axApp, kAXFocusedWindowAttribute)
            ?? (copyElementArray(axApp, kAXWindowsAttribute)?.first) else {
            return []
        }
        guard !PrivacyFilter.isWindowExcluded(bundleID: frontApp.bundleIdentifier,
                                               windowTitle: copyString(window, kAXTitleAttribute) ?? "") else { return [] }
        AXAttributes.enableEnhancedAccessibility(app: axApp, window: window)

        // Resolve window frame for viewport clipping
        let windowBounds = getElementBounds(window) ?? Self.resolveWindowBoundsFromWindowList(pid: pid)

        return candidates(in: window, bounds: windowBounds)
    }

    private func candidates(in window: AXUIElement, bounds windowBounds: CGRect?) -> [UIElementCandidate] {
        var candidates: [UIElementCandidate] = []
        var visitedCount = 0
        let started = ContinuousClock.now
        let deadline = started + Self.traversalBudget

        traverseTree(
            element: window,
            windowBounds: windowBounds,
            depth: 0,
            deadline: deadline,
            visited: &visitedCount,
            into: &candidates
        )
        let elapsed = ContinuousClock.now - started
        if elapsed > .seconds(1) {
            log.info("AX walk took \(elapsed.components.seconds, privacy: .public)s over \(visitedCount, privacy: .public) nodes (\(candidates.count, privacy: .public) candidates)")
        }

        // Sanitize sensitive info and cap to maxCandidates
        let sanitized = privacyFilter.sanitizeCandidates(candidates)
        if sanitized.count > maxCandidates {
            return Array(sanitized.prefix(maxCandidates))
        }
        return sanitized
    }

    /// Asynchronously inspects the active/focused window, falling back to OCR candidates
    /// when the Accessibility tree yields no actionable elements (e.g. Firefox/canvas).
    public func inspectFocusedWindowAsync(targetPID: pid_t? = nil) async -> [UIElementCandidate] {
        guard !requiresWindowScope || targetWindow != nil else { return [] }
        if let selected = targetWindow {
            guard targetPID == nil || targetPID == selected.processID else { return [] }
            return (try? await captureSnapshot(of: selected))?.visibleCandidates ?? []
        }
        let axCandidates = inspectFocusedWindow(targetPID: targetPID)
        if !axCandidates.isEmpty {
            return axCandidates
        }

        guard let fallbackProvider else { return [] }
        let targetApp: NSRunningApplication?
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let targetPID {
            guard targetPID != ownPID else { return [] }
            targetApp = NSRunningApplication(processIdentifier: targetPID)
        } else {
            targetApp = Self.frontmostExternalApplication()
        }

        guard let frontApp = targetApp, frontApp.processIdentifier != ownPID else { return [] }
        if privacyFilter.isApplicationBlocked(bundleID: frontApp.bundleIdentifier) { return [] }

        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        let window = copyElement(axApp, kAXFocusedWindowAttribute)
            ?? (copyElementArray(axApp, kAXWindowsAttribute)?.first)
        guard let window,
              !PrivacyFilter.isWindowExcluded(bundleID: frontApp.bundleIdentifier,
                                               windowTitle: copyString(window, kAXTitleAttribute) ?? "") else { return [] }
        let windowBounds = getElementBounds(window) ?? Self.resolveWindowBoundsFromWindowList(pid: pid)

        let ocrCandidates = await fallbackProvider(pid, windowBounds)
        let sanitized = privacyFilter.sanitizeCandidates(ocrCandidates)
        if sanitized.count > maxCandidates {
            return Array(sanitized.prefix(maxCandidates))
        }
        return sanitized
    }

    // MARK: - Batched Attribute Extraction

    struct BatchedElementInfo {
        let role: String
        let label: String
        let value: String?
        let rawBounds: CGRect?
    }

    private func extractBatchedElementInfo(_ element: AXUIElement) -> BatchedElementInfo {
        let batchedAttributes: [CFString] = [
            kAXRoleAttribute as CFString,         // index 0
            kAXTitleAttribute as CFString,        // index 1
            kAXDescriptionAttribute as CFString,  // index 2
            kAXValueAttribute as CFString,        // index 3
            kAXPositionAttribute as CFString,     // index 4
            kAXSizeAttribute as CFString,         // index 5
        ]

        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            batchedAttributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &valuesRef
        )

        if err == .success, let values = valuesRef as? [AnyObject], values.count >= 6 {
            let role = Self.extractString(from: values[0]) ?? ""
            let title = Self.extractString(from: values[1]) ?? ""
            let desc = Self.extractString(from: values[2]) ?? ""
            let val = Self.extractString(from: values[3])

            // Determine label matching legacy precedence: title -> description -> value
            var label = ""
            for candidate in [title, desc, val ?? ""] {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    label = trimmed
                    break
                }
            }

            // Extract bounds from position (index 4) and size (index 5)
            var origin = CGPoint.zero
            var size = CGSize.zero
            var hasOrigin = false
            var hasSize = false

            let posVal = values[4]
            if CFGetTypeID(posVal) == AXValueGetTypeID(), AXValueGetType(posVal as! AXValue) == .cgPoint {
                hasOrigin = AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
            }

            let sizeVal = values[5]
            if CFGetTypeID(sizeVal) == AXValueGetTypeID(), AXValueGetType(sizeVal as! AXValue) == .cgSize {
                hasSize = AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            }

            let rawBounds: CGRect? = (hasOrigin && hasSize) ? CGRect(origin: origin, size: size) : nil
            return BatchedElementInfo(role: role, label: label, value: val, rawBounds: rawBounds)
        }

        // Fallback to legacy single-attribute queries if batch call is unsupported or fails
        let role = copyString(element, kAXRoleAttribute) ?? ""
        let label = getElementLabel(element)
        let val = copyString(element, kAXValueAttribute)
        let bounds = getElementBounds(element)
        return BatchedElementInfo(role: role, label: label, value: val, rawBounds: bounds)
    }

    public static func extractString(from value: AnyObject?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        if typeID == CFAttributedStringGetTypeID() {
            return (value as! CFAttributedString as NSAttributedString).string
        }
        if typeID == AXValueGetTypeID() {
            // When an attribute query fails, it returns an AXValue of type kAXValueAXErrorType
            return nil
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    // MARK: - Tree Traversal

    private func traverseTree(
        element: AXUIElement,
        windowBounds: CGRect?,
        depth: Int,
        deadline: ContinuousClock.Instant,
        visited: inout Int,
        into output: inout [UIElementCandidate]
    ) {
        guard depth < 16, visited < 800, output.count < (maxCandidates * 2),
              ContinuousClock.now < deadline, !Task.isCancelled else { return }
        visited += 1

        let info = extractBatchedElementInfo(element)

        // Skip secure text fields immediately (zero-trust privacy)
        if info.role == "AXSecureTextField" { return }

        // Window bounds clipping:
        // If raw bounds exist, clip to window bounds. If clipped bounds is nil (offscreen), discard.
        let clippedBounds = info.rawBounds.flatMap { Self.clipBoundsToWindow($0, windowBounds: windowBounds) }

        // Subtree pruning:
        // If the element is an off-screen leaf/row container with valid geometry, prune its children as well
        if let rawBounds = info.rawBounds,
           Self.isValidCoordinateRect(rawBounds, minDimension: 0),
           clippedBounds == nil,
           Self.subTreePruningRoles.contains(info.role) {
            return
        }

        // If the element has valid bounds and either an actionable role or non-empty text, record it
        let isActionable = Self.actionableRoles.contains(info.role)
        if let bounds = clippedBounds, bounds.width > 2 && bounds.height > 2 {
            if isActionable || (!info.label.isEmpty && info.label.count > 1) {
                let id = "elem_\(output.count + 1)"
                let candidate = UIElementCandidate(
                    id: id,
                    role: info.role,
                    label: info.label.isEmpty ? info.role : info.label,
                    value: info.value,
                    bounds: bounds,
                    isActionable: isActionable
                )
                output.append(candidate)
            }
        }

        // Recurse into children
        guard let children = copyElementArray(element, kAXChildrenAttribute) else { return }
        for child in children {
            traverseTree(
                element: child,
                windowBounds: windowBounds,
                depth: depth + 1,
                deadline: deadline,
                visited: &visited,
                into: &output
            )
            if output.count >= (maxCandidates * 2) { return }
        }
    }

    // MARK: - Helpers (Fallback and Legacy)

    /// Sets the process-wide AX timeout once. Per-object timeouts set later
    /// (`windowDecorationRects` uses 50ms) still override it for that object.
    static let boundQueries: Void = {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    private func getElementLabel(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let str = copyString(element, attr), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private func getElementBounds(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            return (value as! CFAttributedString as NSAttributedString).string
        }
        return nil
    }

    private func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return (value as! CFArray) as? [AXUIElement]
    }
}

// MARK: - UIStateProviding Protocol

/// Abstraction for capturing point-in-time desktop/window state snapshots.
/// In production, implemented by AccessibilityInspector.
/// In testing, implemented by MockUIStateProvider yielding scripted UIStateSnapshots.
public protocol UIStateProviding: Sendable {
    func captureSnapshot() async throws -> UIStateSnapshot
}

/// Convenience alias for testing interoperability.
public typealias UIStateInspecting = UIStateProviding

extension AccessibilityInspector: UIStateProviding {
    public func captureSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        if requiresWindowScope && targetWindow == nil { throw SnapshotError.selectedWindowUnavailable }
        if let targetWindow { return try await captureSnapshot(of: targetWindow) }
        guard AXIsProcessTrusted() else {
            return UIStateSnapshot(visibleCandidates: [], timestamp: Date())
        }
        let frontApp = Self.frontmostExternalApplication()
        let pid = frontApp?.processIdentifier
        let appName = frontApp?.localizedName
        let bundleId = frontApp?.bundleIdentifier

        let axApp = pid.map { AXUIElementCreateApplication($0) }
        let window = axApp.flatMap { copyElement($0, kAXFocusedWindowAttribute) ?? copyElementArray($0, kAXWindowsAttribute)?.first }
        let windowTitle = window.flatMap { copyString($0, kAXTitleAttribute) }
        guard !PrivacyFilter.isWindowExcluded(bundleID: bundleId, windowTitle: windowTitle ?? "") else {
            throw SnapshotError.selectedWindowExcluded
        }

        var focusedId: String? = nil
        var focusedRole: String? = nil
        var focusedBounds: CGRect? = nil
        if let axApp, let focusedElem = copyElement(axApp, kAXFocusedUIElementAttribute) {
            focusedRole = copyString(focusedElem, kAXRoleAttribute)
            focusedBounds = getElementBounds(focusedElem)
            focusedId = copyString(focusedElem, kAXIdentifierAttribute)
        }

        let candidates = await inspectFocusedWindowAsync(targetPID: pid)
        return UIStateSnapshot(
            windowTitle: windowTitle,
            appBundleId: bundleId,
            appName: appName,
            focusedElementId: focusedId,
            focusedElementRole: focusedRole,
            focusedElementBounds: focusedBounds,
            visibleCandidates: candidates,
            timestamp: Date(),
            candidateLimit: maxCandidates
        )
    }

    /// Resolves a Quartz window to exactly one AX window; focused/first-window
    /// fallbacks are deliberately absent from selected-window observations.
    static func uniqueWindowIndex(_ windows: [(title: String?, bounds: CGRect?)], title: String, bounds: CGRect) -> Int? {
        guard isValidCoordinateRect(bounds) else { return nil }
        let matches = windows.indices.filter { windows[$0].title == title && windows[$0].bounds == bounds }
        return matches.count == 1 ? matches.first : nil
    }

    private func selectedWindowInfo(_ target: PinnedWindow, pid: pid_t) throws -> (title: String, bounds: CGRect) {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let entry = entries.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id
                      && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                      && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }),
              let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              Self.isValidCoordinateRect(bounds) else { throw SnapshotError.selectedWindowUnavailable }
        let title = entry[kCGWindowName as String] as? String ?? target.windowTitle
        let owned = entries.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        let identities = owned.map { item -> (title: String?, bounds: CGRect?) in
            let frame = (item[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            // An unnamed overlapping window cannot be distinguished safely.
            return (item[kCGWindowName as String] as? String ?? title, frame)
        }
        guard let index = Self.uniqueWindowIndex(identities, title: title, bounds: bounds),
              (owned[index][kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id else {
            throw SnapshotError.selectedWindowUnavailable
        }
        return (title, bounds)
    }

    /// Read-only, exact-window metadata for focus decoration. No focused-window
    /// fallback or accessibility enhancement is used. Missing/stale metadata
    /// keeps the full picture in the fingerprint.
    public func windowDecorationRects(of target: PinnedWindow,
                                      in capture: ScreenCapturer.WindowCapture) -> [CGRect] {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        func prepare(_ element: AXUIElement) -> Bool {
            !Task.isCancelled && ContinuousClock.now < deadline
                && AXUIElementSetMessagingTimeout(element, 0.05) == .success
        }
        guard !Task.isCancelled, AXIsProcessTrusted(), let pid = target.processID, capture.processID == pid,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              target.bundleID == nil || app.bundleIdentifier == target.bundleID,
              !privacyFilter.isApplicationBlocked(bundleID: app.bundleIdentifier),
              !PrivacyFilter.isWindowExcluded(bundleID: app.bundleIdentifier, windowTitle: capture.windowTitle),
              let before = try? selectedWindowInfo(target, pid: pid),
              before.title == capture.windowTitle, before.bounds == capture.frame else { return [] }

        let axApp = AXUIElementCreateApplication(pid)
        guard prepare(axApp),
              let windows = copyElementArray(axApp, kAXWindowsAttribute) else { return [] }
        var identities: [(title: String?, bounds: CGRect?)] = []
        for window in windows {
            // Timeouts apply to the exact AX object, not its descendants.
            guard prepare(window) else { return [] }
            let title = copyString(window, kAXTitleAttribute)
            guard prepare(window) else { return [] }
            identities.append((title, getElementBounds(window)))
        }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return [] }
        guard let index = Self.uniqueWindowIndex(identities, title: before.title, bounds: before.bounds) else { return [] }
        let window = windows[index]
        var rects: [CGRect] = []
        for attribute in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
            guard prepare(window), let button = copyElement(window, attribute), prepare(button),
                  copyString(button, kAXRoleAttribute) == kAXButtonRole,
                  let rect = getElementBounds(button), Self.isValidCoordinateRect(rect),
                  before.bounds.contains(rect), rect.width <= 32, rect.height <= 32,
                  rect.maxY <= before.bounds.minY + 64 else { return [] }
            rects.append(rect)
        }
        // A title must sit in the same narrow row as the standard buttons.
        // Never mask a toolbar, tab strip or arbitrary content near the top.
        guard prepare(window) else { return [] }
        if let title = copyElement(window, kAXTitleUIElementAttribute) {
            guard prepare(title), copyString(title, kAXRoleAttribute) == kAXStaticTextRole,
                  let rect = getElementBounds(title), Self.isValidCoordinateRect(rect),
                  before.bounds.contains(rect), rect.height <= 32,
                  let row = rects.first, rect.minY >= row.minY, rect.maxY <= row.maxY else { return [] }
            rects.append(rect)
        }
        guard prepare(window), let after = try? selectedWindowInfo(target, pid: pid), !app.isTerminated,
              before.title == after.title, before.bounds == after.bounds,
              copyString(window, kAXTitleAttribute) == before.title,
              getElementBounds(window) == before.bounds,
              ContinuousClock.now < deadline, !Task.isCancelled else { return [] }

        let scaleX = CGFloat(capture.image.width) / before.bounds.width
        let scaleY = CGFloat(capture.image.height) / before.bounds.height
        return rects.map {
            CGRect(x: ($0.minX - before.bounds.minX) * scaleX,
                   y: ($0.minY - before.bounds.minY) * scaleY,
                   width: $0.width * scaleX, height: $0.height * scaleY)
        }
    }

    private func captureSnapshot(of target: PinnedWindow) async throws -> UIStateSnapshot {
        guard !PrivacyFilter.isWindowExcluded(bundleID: target.bundleID, windowTitle: target.windowTitle) else {
            throw SnapshotError.selectedWindowExcluded
        }
        guard let pid = target.processID, pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              target.bundleID == nil || app.bundleIdentifier == target.bundleID,
              !privacyFilter.isApplicationBlocked(bundleID: app.bundleIdentifier) else {
            throw SnapshotError.selectedWindowUnavailable
        }
        let before = try selectedWindowInfo(target, pid: pid)
        guard !PrivacyFilter.isWindowExcluded(bundleID: app.bundleIdentifier, windowTitle: before.title) else {
            throw SnapshotError.selectedWindowExcluded
        }
        var observed: [UIElementCandidate] = []
        var focusedId: String?, focusedRole: String?
        var focusedBounds: CGRect?
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            AXAttributes.enableEnhancedAccessibility(app: axApp)
            let windows = copyElementArray(axApp, kAXWindowsAttribute) ?? []
            let identities = windows.map { (title: copyString($0, kAXTitleAttribute), bounds: getElementBounds($0)) }
            guard let index = Self.uniqueWindowIndex(identities, title: before.title, bounds: before.bounds) else {
                throw SnapshotError.selectedWindowUnavailable
            }
            let window = windows[index]
            AXAttributes.enableEnhancedAccessibility(app: axApp, window: window)
            observed = candidates(in: window, bounds: before.bounds)
            if let focusedWindow = copyElement(axApp, kAXFocusedWindowAttribute), CFEqual(focusedWindow, window),
               let focused = copyElement(axApp, kAXFocusedUIElementAttribute) {
                focusedId = copyString(focused, kAXIdentifierAttribute)
                focusedRole = copyString(focused, kAXRoleAttribute)
                focusedBounds = getElementBounds(focused)
            }
        }
        if observed.isEmpty, let fallbackProvider {
            observed = privacyFilter.sanitizeCandidates(await fallbackProvider(pid, before.bounds))
        }
        try Task.checkCancellation()
        let after = try selectedWindowInfo(target, pid: pid)
        guard !app.isTerminated, before.title == after.title, before.bounds == after.bounds else { throw SnapshotError.selectedWindowUnavailable }
        return UIStateSnapshot(windowTitle: before.title, appBundleId: app.bundleIdentifier, appName: app.localizedName,
            focusedElementId: focusedId, focusedElementRole: focusedRole, focusedElementBounds: focusedBounds,
            visibleCandidates: Array(observed.prefix(maxCandidates)), timestamp: Date(), candidateLimit: maxCandidates)
    }

    /// Called by the approval UI after that window's exact operation is approved.
    /// Raising a resolved window avoids returning focus to an unrelated last app.
    @MainActor public func focusTargetWindow() throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), let targetWindow, let pid = targetWindow.processID,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              targetWindow.bundleID == nil || app.bundleIdentifier == targetWindow.bundleID,
              !privacyFilter.isApplicationBlocked(bundleID: app.bundleIdentifier) else {
            throw SnapshotError.selectedWindowUnavailable
        }
        let before = try selectedWindowInfo(targetWindow, pid: pid)
        let axApp = AXUIElementCreateApplication(pid)
        let windows = copyElementArray(axApp, kAXWindowsAttribute) ?? []
        let identities = windows.map { (title: copyString($0, kAXTitleAttribute), bounds: getElementBounds($0)) }
        guard let index = Self.uniqueWindowIndex(identities, title: before.title, bounds: before.bounds) else {
            throw SnapshotError.selectedWindowUnavailable
        }
        let after = try selectedWindowInfo(targetWindow, pid: pid)
        guard !app.isTerminated, before.title == after.title, before.bounds == after.bounds else {
            throw SnapshotError.selectedWindowUnavailable
        }
        try Task.checkCancellation()
        guard AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString) == .success else {
            throw SnapshotError.selectedWindowFocusFailed
        }
        try Task.checkCancellation()
        // The approval app explicitly hands activation to this validated target.
        NSApp.yieldActivation(to: app)
        try Task.checkCancellation()
        guard app.activate(options: []) else { throw SnapshotError.selectedWindowFocusFailed }
    }
}
