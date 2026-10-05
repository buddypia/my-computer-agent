import ApplicationServices
import Foundation

/// Helpers for configuring macOS Accessibility attributes on external applications.
public enum AXAttributes {
    /// Enables enhanced accessibility on an application and optionally its focused window.
    ///
    /// Browsers (Firefox, Chromium, Chrome, Edge, Brave, Arc) and Electron applications
    /// conditionally build and expose their internal web/DOM accessibility trees only when
    /// assistive technology explicitly requests it via `AXEnhancedUserInterface` and `AXManualAccessibility`.
    /// Without these attributes set to true, Firefox and Chromium only expose top-level `AXGroup` wrappers.
    @discardableResult
    public static func enableEnhancedAccessibility(app: AXUIElement, window: AXUIElement? = nil) -> Bool {
        var success = true
        let enhancedRes = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if enhancedRes != .success && enhancedRes != .cannotComplete {
            success = false
        }
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let window {
            _ = AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(window, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return success
    }
}
