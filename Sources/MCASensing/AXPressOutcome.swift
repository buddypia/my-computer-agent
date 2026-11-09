import ApplicationServices

/// What the return code of `AXUIElementPerformAction` proves about whether the
/// action reached the app.
///
/// Only "this element has no such action" proves nothing was sent, so only that
/// case may fall back to another input path. Any other failure can come back
/// after the app already acted on the press (a busy app answers
/// `cannotComplete` once the messaging timeout expires), and a pointer click on
/// top of it would press the control twice.
enum AXPressOutcome: Equatable, Sendable {
    case delivered
    /// The element does not implement the action; nothing was sent.
    case unsupported
    /// The action was refused before reaching the app; retrying with fresh refs is safe.
    case notDelivered(String)
    /// The app may have acted on it; observe before deciding to retry.
    case uncertain(String)

    init(_ result: AXError) {
        switch result {
        case .success: self = .delivered
        case .actionUnsupported, .notImplemented: self = .unsupported
        case .invalidUIElement: self = .notDelivered("the element no longer exists")
        case .apiDisabled: self = .notDelivered("Accessibility access is disabled")
        case .illegalArgument: self = .notDelivered("the press was rejected as invalid")
        case .cannotComplete: self = .uncertain("the app did not respond in time")
        default: self = .uncertain("the press failed (AXError \(result.rawValue))")
        }
    }
}
