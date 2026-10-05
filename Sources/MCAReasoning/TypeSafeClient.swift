import Foundation
import MCACore
import OSLog

/// Abstract protocol for TypeSafe System One model evaluation.
public protocol TypeSafeEvaluating: Sendable {
    func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse
    /// Whether `EvaluationRequest.images` is read. Callers skip the screenshot otherwise.
    var acceptsImages: Bool { get }
}

extension TypeSafeEvaluating {
    public var acceptsImages: Bool { false }
}

/// Client for TypeSafe AI System One API (Jev model).
public struct TypeSafeClient: Sendable, TypeSafeEvaluating {
    public enum ClientError: LocalizedError, Sendable {
        case missingApiKey
        case invalidUrl
        case httpError(status: Int, message: String)
        case decodingError(String)

        public var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "TypeSafe API key is missing. Please set TYPESAFE_API_KEY in environment or SecretStore."
            case .invalidUrl:
                return "Invalid TypeSafe API endpoint URL."
            case .httpError(let status, let message):
                return "TypeSafe API returned HTTP \(status): \(message)"
            case .decodingError(let detail):
                return "Failed to decode TypeSafe API response: \(detail)"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "TypeSafeClient")
    public let endpoint: URL
    private let apiKey: String?

    public init(
        endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        apiKey: String? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
            ?? SecretStore.shared.read(account: "typesafe")
    }

    /// Whether an API key is currently available for TypeSafe Jev.
    public var hasKey: Bool {
        apiKey != nil && !(apiKey?.isEmpty ?? true)
    }

    // MARK: - API Execution

    public struct EvaluationRequest: Codable, Sendable {
        public var state: AnyCodableValue
        public var model: String
        public var questions: [String: QuestionPayload]
        /// JPEG/PNG data URLs placed before the state. Only sent when set (Clef extension).
        public var images: [String]?

        public init(state: AnyCodableValue, model: String = "jev-latest", questions: [String: QuestionPayload], images: [String]? = nil) {
            self.state = state
            self.model = model
            self.questions = questions
            self.images = images
        }
    }

    public struct QuestionPayload: Codable, Sendable {
        public var type: String
        public var instructions: String
        public var criteria: [String: String]?

        public init(type: String, instructions: String, criteria: [String: String]? = nil) {
            self.type = type
            self.instructions = instructions
            self.criteria = criteria
        }
    }

    public struct EvaluationResponse: Codable, Sendable {
        public var model: String
        public var answers: [String: AnswerPayload]
        public var usage: UsagePayload?
    }

    public struct AnswerPayload: Codable, Sendable {
        public var type: String
        public var choice: String?
        public var confidence: Float?
        public var probabilities: [String: Float]?
        public var noul: Float?
        public var score: Float?
    }

    public struct UsagePayload: Codable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// Evaluates state against typed questions.
    public func evaluate(request: EvaluationRequest) async throws -> EvaluationResponse {
        guard let key = apiKey, !key.isEmpty else {
            throw ClientError.missingApiKey
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: 0, message: "Non-HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.httpError(status: httpResponse.statusCode, message: errorText)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(EvaluationResponse.self, from: data)
        } catch {
            throw ClientError.decodingError(error.localizedDescription)
        }
    }
}

// MARK: - AnyCodableValue Helper

public enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) { self = .string(x); return }
        if let x = try? container.decode(Double.self) { self = .number(x); return }
        if let x = try? container.decode(Bool.self) { self = .bool(x); return }
        if let x = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(x); return }
        if let x = try? container.decode([AnyCodableValue].self) { self = .array(x); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported value"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .dictionary(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
