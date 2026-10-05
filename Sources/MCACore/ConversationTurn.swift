import Foundation

/// A single turn in a multi-turn conversation between user and agent.
public struct ConversationTurn: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    public var timestamp: Date

    public init(role: Role, text: String, timestamp: Date = Date()) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
