import AppKit
import ApplicationServices
import Foundation
import MCACore
import OSLog

/// Reads text out of the frontmost window's accessibility tree.
///
/// This is the Tier-1 screen reader and it is strictly better than OCR when it
/// works: the strings are the app's own, so there is no recognition error, no
/// image to encode, and no GPU cost. OCR (`ScreenCapturer`) is the fallback for
/// canvas-drawn UI that exposes no tree.
public struct AccessibilityReader: Sendable {
    public struct Snapshot: Sendable {
        public var bundleID: String?
        public var appName: String
        public var windowTitle: String
        public var text: String
        /// Number of AX elements visited. A very low count on a text-heavy app
        /// is the signal to fall back to OCR.
        public var elementCount: Int
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Accessibility")

    /// Hard caps so a pathological tree (a huge table view) cannot stall the
    /// sampler or blow up memory.
    private let maxElements: Int
    private let maxDepth: Int
    private let maxCharacters: Int

    public init(maxElements: Int = 1500, maxDepth: Int = 24, maxCharacters: Int = 12_000) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.maxCharacters = maxCharacters
    }

    /// Whether the Accessibility TCC permission has been granted.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility permission if not already granted. The system
    /// only shows this dialog once per binary; afterwards the user must go to
    /// System Settings.
    @discardableResult
    public static func requestTrust() -> Bool {
        // The imported `kAXTrustedCheckOptionPrompt` is a mutable global and so
        // is not concurrency-safe to touch; its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Reads a window for a specific process by PID.
    public func readWindow(pid: pid_t) -> Snapshot? {
        // Never inspect own process in-process on background threads:
        // SwiftUI ViewRendererHost asserts main thread for accessibility node evaluation,
        // which triggers _dispatch_assert_queue_fail (SIGTRAP) if invoked from concurrency pools.
        if pid == ProcessInfo.processInfo.processIdentifier {
            log.info("Target PID is own application; skipping in-process accessibility inspection.")
            let app = NSRunningApplication(processIdentifier: pid)
            return Snapshot(
                bundleID: app?.bundleIdentifier,
                appName: app?.localizedName ?? "My Computer Agent",
                windowTitle: "",
                text: "",
                elementCount: 0
            )
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        AXAttributes.enableEnhancedAccessibility(app: axApp)

        guard let window = copyElement(axApp, kAXFocusedWindowAttribute)
            ?? (copyElementArray(axApp, kAXWindowsAttribute)?.first) else {
            return Snapshot(
                bundleID: app.bundleIdentifier,
                appName: app.localizedName ?? "Unknown",
                windowTitle: "",
                text: "",
                elementCount: 0)
        }
        AXAttributes.enableEnhancedAccessibility(app: axApp, window: window)

        let title = copyString(window, kAXTitleAttribute) ?? ""

        var collected = ""
        var visited = 0
        collectText(from: window, depth: 0, visited: &visited, into: &collected)

        return Snapshot(
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "Unknown",
            windowTitle: title,
            text: collected.trimmingCharacters(in: .whitespacesAndNewlines),
            elementCount: visited)
    }

    /// Reads the currently focused window. Returns `nil` when there is no
    /// frontmost app or the app exposes nothing readable.
    public func readFocusedWindow() -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return readWindow(pid: app.processIdentifier)
    }

    // MARK: - Tree walk

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        visited: inout Int,
        into output: inout String
    ) {
        guard depth < maxDepth,
              visited < maxElements,
              output.count < maxCharacters
        else { return }

        visited += 1

        let role = copyString(element, kAXRoleAttribute) ?? ""

        // Never read password fields. This is the AX-tree half of the
        // zero-trust rule; the other half is the bundle-ID exclusion applied
        // before we even get here.
        if role == "AXSecureTextField" { return }

        // Prefer the value, then visible text, then the accessible label.
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", "AXDocument"] {
            if let string = copyString(element, attribute), !string.isEmpty {
                // Skip single characters and pure whitespace — button glyphs
                // and layout spacers add noise without meaning.
                if string.count > 1 {
                    output += string
                    output += "\n"
                }
                break
            }
        }

        guard let children = copyElementArray(element, kAXChildrenAttribute) else { return }
        for child in children {
            collectText(from: child, depth: depth + 1, visited: &visited, into: &output)
            if visited >= maxElements || output.count >= maxCharacters { return }
        }
    }

    // MARK: - AX accessors

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value,
               CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value
        else { return nil }
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
               CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }
        return (value as! CFArray) as? [AXUIElement]
    }
}
