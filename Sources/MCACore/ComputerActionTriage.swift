import CoreGraphics
import Foundation

/// Structured triage judgment on whether a user goal requires desktop/browser manipulation.
/// Produced by TypeSafe Jev System One model or fast local heuristics.
public struct ComputerActionTriage: Sendable, Equatable, Codable {
    public var needsComputerAction: Bool
    public var confidence: Float
    /// Intent category: "browser_scroll", "browser_search", "gui_interaction", "screen_inspection", "pure_qa", etc.
    public var intentCategory: String
    /// Concise execution plan suggested for the reasoning model (e.g. Gemini).
    public var suggestedPlan: String?

    public init(
        needsComputerAction: Bool,
        confidence: Float = 1.0,
        intentCategory: String = "pure_qa",
        suggestedPlan: String? = nil
    ) {
        self.needsComputerAction = needsComputerAction
        self.confidence = confidence
        self.intentCategory = intentCategory
        self.suggestedPlan = suggestedPlan
    }

    public static let conversational = ComputerActionTriage(
        needsComputerAction: false,
        confidence: 1.0,
        intentCategory: "pure_qa",
        suggestedPlan: nil
    )
}

/// The decision produced by the System One (TypeSafe Jev) decision engine or autonomous coordinator.
public struct ComputerActionDecision: Codable, Sendable, Equatable {
    public enum ActionType: String, Codable, Sendable, CaseIterable, Equatable {
        case click = "click"
        case doubleClick = "double_click"
        case rightClick = "right_click"
        case typeText = "type"
        case keyPress = "key"
        case scroll = "scroll"
        case wait = "wait"
        case none = "none"

        public init?(rawValue: String) {
            switch rawValue.lowercased() {
            case "click":
                self = .click
            case "double_click", "doubleclick":
                self = .doubleClick
            case "right_click", "rightclick":
                self = .rightClick
            case "type", "typetext", "type_text":
                self = .typeText
            case "key", "keypress", "key_press":
                self = .keyPress
            case "scroll":
                self = .scroll
            case "wait":
                self = .wait
            case "none":
                self = .none
            default:
                return nil
            }
        }
    }

    public var targetElementId: String?
    public var action: ActionType
    public var confidence: Float
    public var isCompleted: Bool
    public var targetCenter: CGPoint?
    public var textInput: String?
    public var keyCombination: [String]?
    public var scrollDelta: CGVector?
    public var reasoning: String?

    /// Canonical Quartz coordinate point where action is focused.
    /// Aliased directly to `targetCenter` for backward compatibility.
    public var coordinates: CGPoint? {
        get { targetCenter }
        set { targetCenter = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case targetElementId
        case action
        case confidence
        case isCompleted
        case targetCenter
        case coordinates
        case textInput
        case keyCombination
        case scrollDelta
        case reasoning
    }

    public init(
        targetElementId: String? = nil,
        action: ActionType,
        confidence: Float = 1.0,
        isCompleted: Bool = false,
        targetCenter: CGPoint? = nil,
        coordinates: CGPoint? = nil,
        textInput: String? = nil,
        keyCombination: [String]? = nil,
        scrollDelta: CGVector? = nil,
        reasoning: String? = nil
    ) {
        self.targetElementId = targetElementId
        self.action = action
        self.confidence = confidence
        self.isCompleted = isCompleted
        self.targetCenter = coordinates ?? targetCenter
        self.textInput = textInput
        self.keyCombination = keyCombination
        self.scrollDelta = scrollDelta
        self.reasoning = reasoning
    }


    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(ActionType.self, forKey: .action)
        self.targetElementId = try container.decodeIfPresent(String.self, forKey: .targetElementId)
        self.confidence = try container.decodeIfPresent(Float.self, forKey: .confidence) ?? 1.0
        self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        self.targetCenter = try container.decodeIfPresent(CGPoint.self, forKey: .coordinates)
            ?? container.decodeIfPresent(CGPoint.self, forKey: .targetCenter)
        self.textInput = try container.decodeIfPresent(String.self, forKey: .textInput)
        self.keyCombination = try container.decodeIfPresent([String].self, forKey: .keyCombination)
        self.scrollDelta = try container.decodeIfPresent(CGVector.self, forKey: .scrollDelta)
        self.reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(targetElementId, forKey: .targetElementId)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(targetCenter, forKey: .targetCenter)
        try container.encodeIfPresent(targetCenter, forKey: .coordinates)
        try container.encodeIfPresent(textInput, forKey: .textInput)
        try container.encodeIfPresent(keyCombination, forKey: .keyCombination)
        try container.encodeIfPresent(scrollDelta, forKey: .scrollDelta)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
    }
}

