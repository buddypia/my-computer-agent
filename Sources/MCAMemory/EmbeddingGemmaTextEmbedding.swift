import Foundation
import MCACore
import os
import OSLog

/// Text embedding model powered by a local EmbeddingGemma 2 inference engine.
///
/// Produces 256-dimensional Matryoshka Representation Learning (MRL) embeddings
/// with L2 normalization, saving 66.7% memory and vector storage while maintaining
/// over 99% retrieval quality.
///
/// Plugs into `SQLiteContextStore` for hybrid FTS5 + Semantic RRF retrieval.
public struct EmbeddingGemmaTextEmbedding: TextEmbedding, Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // Circuit breaker state to prevent cascading 5s write stalls when daemon is down
    private static let consecutiveFailures = OSAllocatedUnfairLock(initialState: 0)
    private static let lastFailureTimestamp = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private static let cooldownSeconds: TimeInterval = 2.0

    private let log = Logger(subsystem: "com.buddypia.mca", category: "EmbeddingGemmaTextEmbedding")
    public let dimension: Int
    public let model: String?
    public var modelIdentifier: String? { model }
    public let endpoint: URL
    private let transport: Transport

    public init(
        dimension: Int = 256,
        model: String? = nil,
        endpoint: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: @escaping Transport = { try await Self.defaultSession.data(for: $0) }
    ) {
        self.dimension = dimension
        let rawModel = model ?? environment["MCA_EMBEDDING_GEMMA_MODEL"]
        self.model = rawModel.map { AgentConfiguration.sanitizeEmbeddingGemmaModel($0) }
        self.transport = transport

        let resolvedUrl: URL
        if let endpoint {
            resolvedUrl = endpoint
        } else if let envUrl = environment["MCA_EMBEDDING_GEMMA_EMBED_URL"], let url = URL(string: envUrl) {
            resolvedUrl = url
        } else if let envBase = environment["MCA_EMBEDDING_GEMMA_URL"] ?? environment["EG2_URL"], let base = URL(string: envBase) {
            var comp = URLComponents(url: base, resolvingAgainstBaseURL: true)
            if comp?.path.isEmpty == true || comp?.path == "/" {
                comp?.path = "/v1/embed"
            }
            resolvedUrl = comp?.url ?? URL(string: "http://127.0.0.1:38765/v1/embed")!
        } else {
            resolvedUrl = URL(string: "http://127.0.0.1:38765/v1/embed")!
        }

        // SSRF Guard: enforce loopback or HTTPS to prevent leaking sensitive screen/voice transcripts
        let allowInsecureRemote = environment["MCA_ALLOW_INSECURE_REMOTE_EMBEDDING"] == "1"
        if Self.isSafeEndpoint(resolvedUrl, allowInsecureRemote: allowInsecureRemote) {
            self.endpoint = resolvedUrl
        } else {
            self.endpoint = URL(string: "http://127.0.0.1:38765/v1/embed")!
        }
    }

    private static func isSafeEndpoint(_ url: URL, allowInsecureRemote: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if scheme == "https" || allowInsecureRemote { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
    }

    public func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cost & Quality Guard: skip empty or trivial strings lacking meaningful alphanumeric tokens
        guard trimmed.count >= 2,
              trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }

        // Circuit Breaker: fast-fail if daemon is unreachable to preserve memory write throughput
        let isCoolingDown = Self.lastFailureTimestamp.withLock { last -> Bool in
            Date().timeIntervalSince(last) < Self.cooldownSeconds
        }
        if isCoolingDown && Self.consecutiveFailures.withLock({ $0 >= 3 }) {
            return nil
        }

        // Limit maximum character window to prevent excessive context
        let clipped = String(trimmed.prefix(4000))

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 4.0

        var payload: [String: Any] = [
            "text": clipped,
            "dim": dimension
        ]
        if let model {
            payload["model"] = model
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        urlRequest.httpBody = bodyData

        do {
            let (data, response) = try await transport(urlRequest)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                recordFailure()
                return nil
            }
            struct EmbedResponse: Decodable {
                let dim: Int
                let vector: [Float]
            }
            let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
            guard decoded.vector.count == dimension else {
                log.warning("Embedding dimension mismatch: expected \(self.dimension), got \(decoded.vector.count)")
                return nil
            }
            recordSuccess()
            return VectorMath.normalized(decoded.vector)
        } catch {
            recordFailure()
            log.debug("EmbeddingGemma text embedding failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func recordSuccess() {
        Self.consecutiveFailures.withLock { $0 = 0 }
    }

    private func recordFailure() {
        Self.lastFailureTimestamp.withLock { $0 = Date() }
        Self.consecutiveFailures.withLock { $0 += 1 }
    }
}
