import Foundation
import MCACore
import OSLog

/// System One client backed by a local EmbeddingGemma 2 inference engine.
///
/// Communicates with the local EmbeddingGemma daemon (by default at `http://127.0.0.1:8765`),
/// providing 100% offline, zero-cost, sub-50ms System One decision evaluation via
/// cosine similarity over Matryoshka representations.
///
/// Designed after `clef-doom` (`clef_doom/embedding.py`) and `decision_maker_local.py`.
public struct EmbeddingGemmaClient: Sendable, TypeSafeEvaluating {
    public enum ClientError: LocalizedError, Sendable {
        case serverUnavailable(String)
        case httpError(status: Int, message: String)
        case decodingError(String)
        case invalidEndpoint

        public var errorDescription: String? {
            switch self {
            case .serverUnavailable(let detail):
                return "EmbeddingGemma 2 local server unavailable: \(detail)"
            case .httpError(let status, let message):
                return "EmbeddingGemma 2 server returned HTTP \(status): \(message)"
            case .decodingError(let detail):
                return "Failed to decode EmbeddingGemma 2 response: \(detail)"
            case .invalidEndpoint:
                return "Invalid EmbeddingGemma 2 endpoint URL"
            }
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let log = Logger(subsystem: "com.buddypia.mca", category: "EmbeddingGemmaClient")
    public let endpoint: URL
    private let transport: Transport
    private let environment: [String: String]

    public init(
        endpoint: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.environment = environment
        self.transport = transport

        if let endpoint {
            self.endpoint = endpoint
        } else if let envUrl = environment["MCA_EMBEDDING_GEMMA_URL"], let url = URL(string: envUrl) {
            self.endpoint = url
        } else {
            self.endpoint = URL(string: "http://127.0.0.1:8765/v1/evaluate")!
        }
    }

    /// Whether this backend was explicitly requested via environment variables.
    public var isConfigured: Bool {
        if environment["MCA_EMBEDDING_GEMMA_URL"] != nil { return true }
        if let backend = environment["MCA_SYSTEM_ONE"]?.lowercased() {
            return backend == "embeddinggemma" || backend == "embeddinggemma2" || backend == "gemma" || backend == "local"
        }
        return false
    }

    /// Checks if the local EmbeddingGemma 2 daemon is responding on `/health`.
    public func isAvailable(timeout: TimeInterval = 0.5) async -> Bool {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            return false
        }
        components.path = "/health"
        guard let healthUrl = components.url else { return false }

        var request = URLRequest(url: healthUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await transport(request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - TypeSafeEvaluating

    public var acceptsImages: Bool { false }

    public func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local inference is fast, but grant a reasonable timeout window
        urlRequest.timeoutInterval = 10.0

        let encoder = JSONEncoder()
        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw ClientError.decodingError("Failed to encode EvaluationRequest: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch {
            log.warning("EmbeddingGemma local evaluate failed: \(error.localizedDescription)")
            throw ClientError.serverUnavailable(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.serverUnavailable("Non-HTTP response received")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(decoding: data.prefix(500), as: UTF8.self)
            throw ClientError.httpError(status: httpResponse.statusCode, message: errorText)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(TypeSafeClient.EvaluationResponse.self, from: data)
        } catch {
            log.error("Failed to decode EmbeddingGemma response: \(error.localizedDescription)")
            throw ClientError.decodingError(error.localizedDescription)
        }
    }
}
