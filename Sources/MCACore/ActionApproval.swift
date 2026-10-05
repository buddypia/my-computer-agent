import Foundation

/// Immutable description of one proposed side effect. IDs are created by the
/// application, never accepted from model output or screen content.
public struct ActionApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let goal: String
    public let operation: String
    public let target: String
    public let details: String
    public let consequence: String

    public init(id: UUID = UUID(), goal: String, operation: String, target: String,
                details: String, consequence: String) {
        self.id = id
        self.goal = goal
        self.operation = operation
        self.target = target
        self.details = details
        self.consequence = consequence
    }
}

public enum ActionApprovalStatus: String, Sendable, Equatable {
    case pending, approved, rejected, cancelled, expired, invalidated
}
