import Foundation
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

    private let log = Logger(subsystem: "com.buddypia.mca", category: "EmbeddingGemmaTextEmbedding")
    public let dimension: Int
    public let endpoint: URL
    private let transport: Transport

    public init(
        dimension: Int = 256,
        endpoint: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.dimension = dimension
        self.transport = transport

        if let endpoint {
            self.endpoint = endpoint
        } else if let envUrl = environment["MCA_EMBEDDING_GEMMA_EMBED_URL"], let url = URL(string: envUrl) {
            self.endpoint = url
        } else if let envBase = environment["MCA_EMBEDDING_GEMMA_URL"], let base = URL(string: envBase) {
            var comp = URLComponents(url: base, resolvingAgainstBaseURL: true)
            comp?.path = "/v1/embed"
            self.endpoint = comp?.url ?? URL(string: "http://127.0.0.1:8765/v1/embed")!
        } else {
            self.endpoint = URL(string: "http://127.0.0.1:8765/v1/embed")!
        }
    }

    public func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Limit maximum character window to prevent excessive context
        let clipped = String(trimmed.prefix(4000))

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 5.0

        let payload: [String: Any] = [
            "text": clipped,
            "dim": dimension
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        urlRequest.httpBody = bodyData

        do {
            let (data, response) = try await transport(urlRequest)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
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
            return VectorMath.normalized(decoded.vector)
        } catch {
            log.debug("EmbeddingGemma text embedding failed: \(error.localizedDescription)")
            return nil
        }
    }
}
