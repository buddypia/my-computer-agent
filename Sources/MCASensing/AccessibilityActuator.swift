import AppKit
import ApplicationServices
import Foundation
import MCACore
import OSLog

/// Interacts directly with UI elements in other applications via macOS Accessibility APIs.
public struct AccessibilityActuator: Sendable {
    public enum ActuatorError: LocalizedError, Sendable {
        case accessibilityPermissionDenied
        case applicationNotFound(String)
        case applicationBlocked(String)
        case elementNotFound(query: String)
        case actionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionDenied:
                return """
                    Accessibility permission is not granted. \
                    Please grant Accessibility permission in: \
                    System Settings ▸ Privacy & Security ▸ Accessibility
                    """
            case .applicationNotFound(let name):
                return "Application '\(name)' is not running or could not be found."
            case .applicationBlocked(let name):
                return "Application '\(name)' is in the privacy blocklist and cannot be automated."
            case .elementNotFound(let query):
                return "No matching UI element found for query: '\(query)'."
            case .actionFailed(let reason):
                return "Failed to perform accessibility action: \(reason)"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "AccessibilityActuator")
    private let synthesizer = EventSynthesizer()
    private let privacyFilter: PrivacyFilter

    public init(privacyFilter: PrivacyFilter = PrivacyFilter()) {
        self.privacyFilter = privacyFilter
    }

    /// Searches for a UI element matching title/label and optional role in the target application
    /// (or frontmost app if not specified), and clicks it.
    public func clickElement(
        appName: String? = nil,
        titleOrLabel: String,
        role: String? = nil
    ) throws -> String {
        guard AXIsProcessTrusted() else {
            throw ActuatorError.accessibilityPermissionDenied
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let targetApp: NSRunningApplication
        if let appName, !appName.isEmpty {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier != ownPID &&
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                throw ActuatorError.applicationNotFound(appName)
            }
            targetApp = app
        } else {
            if let front = AccessibilityInspector.frontmostExternalApplication() {
                targetApp = front
            } else {
                throw ActuatorError.applicationNotFound("frontmost application")
            }
        }

        if privacyFilter.isApplicationBlocked(bundleID: targetApp.bundleIdentifier) {
            log.warning("App \(targetApp.bundleIdentifier ?? targetApp.localizedName ?? "unknown") is in privacy blocklist; denying automation.")
            throw ActuatorError.applicationBlocked(targetApp.localizedName ?? targetApp.bundleIdentifier ?? "Application")
        }

        let pid = targetApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var foundElement: AXUIElement?
        var visited = 0
        searchElement(
            in: axApp,
            titleOrLabel: titleOrLabel,
            role: role,
            depth: 0,
            visited: &visited,
            found: &foundElement
        )

        guard let element = foundElement else {
            throw ActuatorError.elementNotFound(query: "\(titleOrLabel) in \(targetApp.localizedName ?? "App")")
        }

        // Try direct AXPressAction first
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressResult == .success {
            return "Successfully pressed '\(titleOrLabel)' in \(targetApp.localizedName ?? "App") via Accessibility action."
        }

        // Fallback: calculate element center point and synthesize mouse click
        if let point = getElementCenter(element) {
            try synthesizer.click(at: point, button: .left, clickCount: 1)
            return "Clicked '\(titleOrLabel)' in \(targetApp.localizedName ?? "App") at coordinate (\(Int(point.x)), \(Int(point.y)))."
        }

        throw ActuatorError.actionFailed("Element found but could not execute action or determine coordinates.")
    }

    // MARK: - Tree search

    private func searchElement(
        in element: AXUIElement,
        titleOrLabel: String,
        role: String?,
        depth: Int = 0,
        visited: inout Int,
        found: inout AXUIElement?
    ) {
        guard found == nil, visited < 1000, depth < 20 else { return }
        visited += 1

        let elementRole = copyString(element, kAXRoleAttribute) ?? ""
        if let role, !role.isEmpty {
            if !elementRole.localizedCaseInsensitiveContains(role) {
                // Keep looking in children even if this node doesn't match role
            }
        }

        // Check if this node matches label / title / description / value
        let matchesQuery = checkMatch(element: element, target: titleOrLabel)
        let matchesRole = (role == nil || role?.isEmpty == true) || elementRole.localizedCaseInsensitiveContains(role!)

        if matchesQuery && matchesRole {
            found = element
            return
        }

        // Recurse into children
        guard let children = copyElementArray(element, kAXChildrenAttribute) else { return }
        for child in children {
            searchElement(in: child, titleOrLabel: titleOrLabel, role: role, depth: depth + 1, visited: &visited, found: &found)
            if found != nil { return }
        }
    }

    private func checkMatch(element: AXUIElement, target: String) -> Bool {
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        for attr in attributes {
            if let str = copyString(element, attr),
               str.localizedCaseInsensitiveContains(target) {
                return true
            }
        }
        return false
    }

    private func getElementCenter(_ element: AXUIElement) -> CGPoint? {
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

        return CGPoint(x: origin.x + size.width / 2.0, y: origin.y + size.height / 2.0)
    }

    // MARK: - AX accessors

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
