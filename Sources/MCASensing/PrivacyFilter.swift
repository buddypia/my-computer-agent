import Foundation
import MCACore

/// Enforces zero-trust privacy and PII redaction before screen data is sent to AI models.
public struct PrivacyFilter: Sendable {
    /// The same exclusion policy follows an answer through native and browser
    /// tools. It is task-scoped, so concurrent answers do not share settings.
    @TaskLocal public static var configuration = AgentConfiguration()

    public static func isWindowExcluded(bundleID: String?, windowTitle: String) -> Bool {
        configuration.isExcluded(bundleID: bundleID, windowTitle: windowTitle)
            || PrivacyFilter().isApplicationBlocked(bundleID: bundleID)
    }
    /// Bundle IDs of applications whose window contents must NEVER be sent to external models.
    public static let blockedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.lastpass.LastPass",
        "com.keepassx.keepassxc",
        "org.keepassxc.keepassxc",
    ]

    /// Roles that are inherently sensitive and must be redacted.
    public static let blockedRoles: Set<String> = [
        "AXSecureTextField",
    ]

    public init() {}

    /// Checks whether the application is blocked from automation inspection.
    public func isApplicationBlocked(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // Compared lowercased on both sides: the list carries mixed-case IDs
        // (`com.lastpass.LastPass`), which a lowercased lookup never matches.
        return Self.blockedBundleIDs.contains { $0.lowercased() == bundleID.lowercased() }
    }

    /// A browser snapshot with secrets masked in everything the model reads:
    /// the outline, the URL (tokens travel in query strings) and the title.
    public func redact(_ snapshot: BrowserSnapshot) -> BrowserSnapshot {
        var copy = snapshot
        copy.url = redactSensitiveText(snapshot.url)
        copy.title = redactSensitiveText(snapshot.title)
        copy.outline = redactSensitiveText(snapshot.outline)
        return copy
    }

    /// Redacts sensitive patterns (API keys, tokens, card numbers) from text. Email addresses are not redacted.
    public func redactSensitiveText(_ input: String) -> String {
        var text = input

        // Redact potential API keys and tokens (e.g. apikey_..., Bearer ..., ghp_...)
        let keyPattern = #"(?i)(api[_-]?key|bearer|token|secret)[=:\s]+[A-Za-z0-9_\-]{16,}"#
        if let regex = try? NSRegularExpression(pattern: keyPattern) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1=[REDACTED]"
            )
        }

        // Redact standalone API tokens without explicit key prefix (e.g. sk-..., ghp_..., AKIA...)
        let standaloneTokenPattern = #"\b(?:sk-[A-Za-z0-9_\-]{20,}|ghp_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16})\b"#
        if let regex = try? NSRegularExpression(pattern: standaloneTokenPattern) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "[REDACTED_SECRET]"
            )
        }

        // Redact potential credit card numbers (13-19 digits)
        let ccPattern = #"\b(?:\d{4}[ -]?){3}\d{4}\b"#
        if let regex = try? NSRegularExpression(pattern: ccPattern) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "[REDACTED_CC]"
            )
        }

        return text
    }

    /// Filters and redacts a list of UI element candidates.
    public func sanitizeCandidates(_ candidates: [UIElementCandidate]) -> [UIElementCandidate] {
        candidates.compactMap { candidate in
            // Drop secure fields
            if Self.blockedRoles.contains(candidate.role) {
                return nil
            }

            let cleanLabel = redactSensitiveText(candidate.label)
            let cleanValue = candidate.value.map { redactSensitiveText($0) }

            var sanitized = candidate
            sanitized.label = cleanLabel
            sanitized.value = cleanValue
            return sanitized
        }
    }
}
