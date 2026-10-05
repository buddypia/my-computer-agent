import CoreGraphics
import Foundation

/// Origin source of an observed UI element candidate.
public enum ElementSource: String, Codable, Sendable {
    case accessibility
    case ocr
}

/// A structured UI element candidate observed on screen for computer automation.
public struct UIElementCandidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: String
    public var label: String
    public var value: String?
    public var bounds: CGRect
    public var isActionable: Bool
    public var source: ElementSource

    public init(
        id: String,
        role: String,
        label: String,
        value: String? = nil,
        bounds: CGRect,
        isActionable: Bool = true,
        source: ElementSource = .accessibility
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.bounds = bounds
        self.isActionable = isActionable
        self.source = source
    }

    public init(
        id: String,
        role: String,
        title: String,
        value: String? = nil,
        bounds: CGRect,
        isActionable: Bool = true,
        source: ElementSource = .accessibility
    ) {
        self.id = id
        self.role = role
        self.label = title
        self.value = value
        self.bounds = bounds
        self.isActionable = isActionable
        self.source = source
    }

    /// Center point of the element in global screen coordinates.
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Title alias for specifications referencing `title`.
    public var title: String {
        label
    }

    // MARK: - Codable Custom Decoding for Robust Backwards Compatibility
    private enum CodingKeys: String, CodingKey {
        case id, role, label, title, value, bounds, isActionable, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.role = try container.decode(String.self, forKey: .role)
        let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? ""
        self.label = decodedLabel
        self.value = try container.decodeIfPresent(String.self, forKey: .value)
        self.bounds = try container.decode(CGRect.self, forKey: .bounds)
        self.isActionable = try container.decodeIfPresent(Bool.self, forKey: .isActionable) ?? true
        self.source = try container.decodeIfPresent(ElementSource.self, forKey: .source) ?? .accessibility
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(label, forKey: .label)
        try container.encode(label, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(bounds, forKey: .bounds)
        try container.encode(isActionable, forKey: .isActionable)
        try container.encode(source, forKey: .source)
    }
}

