import Foundation

/// A paired target and role being watched.
///
/// Ties a subject (a pinned window, a pinned display, or the focused window)
/// to a specific objective (a `WatchRole`), allowing multiple screens to be watched
/// in parallel with different instructions and schedules.
public struct WatchItem: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var targetKey: String
    public var targetName: String
    public var role: WatchRole
    public var isEnabled: Bool
    /// Optional user prompt override that replaces or extends the role's system prompt.
    public var customPromptOverride: String?
    /// Individual interval override, or nil to follow the role's default.
    public var intervalOverride: TimeInterval?

    public init(
        id: UUID = UUID(),
        targetKey: String,
        targetName: String,
        role: WatchRole = .general,
        isEnabled: Bool = true,
        customPromptOverride: String? = nil,
        intervalOverride: TimeInterval? = nil
    ) {
        self.id = id
        self.targetKey = targetKey
        self.targetName = targetName
        self.role = role
        self.isEnabled = isEnabled
        self.customPromptOverride = customPromptOverride
        self.intervalOverride = intervalOverride
    }

    /// Convenience initialiser directly from a `WatchTarget`.
    public init(
        target: WatchTarget,
        role: WatchRole = .general,
        isEnabled: Bool = true,
        customPromptOverride: String? = nil,
        intervalOverride: TimeInterval? = nil
    ) {
        self.init(
            id: UUID(),
            targetKey: target.key,
            targetName: target.subjectName ?? (target == .focused ? "Focused window" : "Display"),
            role: role,
            isEnabled: isEnabled,
            customPromptOverride: customPromptOverride,
            intervalOverride: intervalOverride
        )
    }

    /// The effective interval to use when scheduling looks for this item.
    public var effectiveInterval: TimeInterval {
        intervalOverride ?? role.defaultInterval
    }

    /// The effective prompt to give the model for this item.
    public var effectivePrompt: String {
        if let customPromptOverride, !customPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customPromptOverride
        }
        return role.systemPrompt
    }

    /// The effective on-demand task prompt to give the model for this item.
    public var effectiveTaskPrompt: String {
        if let customPromptOverride, !customPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customPromptOverride
        }
        return role.effectiveTaskPrompt
    }
}
