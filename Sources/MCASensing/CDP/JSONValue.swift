import Foundation

/// A `Sendable` JSON document.
///
/// The DevTools protocol is untyped JSON both ways, and `[String: Any]` cannot
/// cross an actor boundary under strict concurrency. This enum is the smallest
/// thing that can: it round-trips through `JSONSerialization` at the edges and
/// stays a plain value in between.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Construction

    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber wraps both booleans and numbers. The check has to be on
            // the *original* object: re-boxing a Swift Bool as CFTypeRef
            // always yields a CFBoolean, so `bool as CFTypeRef` proves nothing.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let int as Int:
            self = .number(Double(int))
        case let double as Double:
            self = .number(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }

    public init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self.init(any: object)
    }

    /// Back to Foundation types for `JSONSerialization`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys])
    }

    // MARK: Accessors

    public subscript(key: String) -> JSONValue {
        if case .object(let values) = self { return values[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let values) = self, values.indices.contains(index) { return values[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var doubleValue: Double? { if case .number(let value) = self { return value } else { return nil } }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let values) = self { return values } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let values) = self { return values } else { return nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
