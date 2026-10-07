import Foundation
import MCACore
@testable import MCAReasoning
import Testing

private final class Calls<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func http(_ status: Int, _ body: String) -> (Data, URLResponse) {
    let url = URL(string: "http://127.0.0.1:8765/v1/evaluate")!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private let okBody = """
{
  "model": "google/embeddinggemma-2",
  "answers": {
    "action_type": {
      "type": "choice",
      "choice": "click",
      "confidence": 0.92,
      "probabilities": { "click": 0.92, "type": 0.08 }
    },
    "is_completed": {
      "type": "noul",
      "noul": 0.05
    }
  }
}
"""

@Suite("EmbeddingGemma local client")
struct EmbeddingGemmaClientTests {
    @Test("posts to local evaluation endpoint and decodes answers")
    func postsAndDecodes() async throws {
        let sent = Calls<URLRequest>()
        let client = EmbeddingGemmaClient(
            endpoint: URL(string: "http://127.0.0.1:8765/v1/evaluate")!
        ) { request in
            sent.append(request)
            return http(200, okBody)
        }

        let req = TypeSafeClient.EvaluationRequest(
            state: .dictionary(["user_goal": .string("Click button")]),
            questions: [
                "action_type": .init(type: "choice", instructions: "What action?"),
                "is_completed": .init(type: "noul", instructions: "Is it completed?")
            ]
        )

        let response = try await client.evaluate(request: req)
        #expect(response.model == "google/embeddinggemma-2")
        #expect(response.answers["action_type"]?.choice == "click")
        #expect(response.answers["action_type"]?.confidence == 0.92)
        #expect(response.answers["is_completed"]?.noul == 0.05)

        let r = try #require(sent.all.first)
        #expect(r.url?.absoluteString == "http://127.0.0.1:8765/v1/evaluate")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("checks health endpoint to determine availability")
    func checksHealthEndpoint() async {
        let healthyClient = EmbeddingGemmaClient { request in
            let url = URL(string: "http://127.0.0.1:8765/health")!
            return (Data(#"{"status":"ok"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let isHealthy = await healthyClient.isAvailable()
        #expect(isHealthy == true)

        let unhealthyClient = EmbeddingGemmaClient { request in
            let url = URL(string: "http://127.0.0.1:8765/health")!
            return (Data(#"{"status":"error"}"#.utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let isUnhealthy = await unhealthyClient.isAvailable()
        #expect(isUnhealthy == false)
    }

    @Test("isConfigured detects MCA_SYSTEM_ONE and MCA_EMBEDDING_GEMMA_URL")
    func detectsConfiguration() {
        #expect(EmbeddingGemmaClient(environment: ["MCA_SYSTEM_ONE": "local"]).isConfigured)
        #expect(EmbeddingGemmaClient(environment: ["MCA_SYSTEM_ONE": "gemma"]).isConfigured)
        #expect(EmbeddingGemmaClient(environment: ["MCA_SYSTEM_ONE": "embeddinggemma"]).isConfigured)
        #expect(EmbeddingGemmaClient(environment: ["MCA_SYSTEM_ONE": "embeddinggemma2"]).isConfigured)
        #expect(EmbeddingGemmaClient(environment: ["MCA_EMBEDDING_GEMMA_URL": "http://localhost:8765"]).isConfigured)
        #expect(!EmbeddingGemmaClient(environment: [:]).isConfigured)
        #expect(!EmbeddingGemmaClient(environment: ["MCA_SYSTEM_ONE": "offline"]).isConfigured)
    }

    @Test("SystemOneBackend resolves EmbeddingGemmaClient when configured")
    func systemOneBackendResolvesGemma() {
        let clientLocal = SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "local"])
        #expect(clientLocal is EmbeddingGemmaClient)

        let clientGemma = SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "gemma"])
        #expect(clientGemma is EmbeddingGemmaClient)

        let clientExplicitUrl = SystemOneBackend.resolve(environment: ["MCA_EMBEDDING_GEMMA_URL": "http://127.0.0.1:8765/v1/evaluate"])
        #expect(clientExplicitUrl is EmbeddingGemmaClient)
    }

    @Test("server error throws ClientError.httpError")
    func serverErrorThrows() async {
        let client = EmbeddingGemmaClient { _ in
            http(500, "Internal Server Error")
        }
        let req = TypeSafeClient.EvaluationRequest(
            state: .string(""),
            questions: [:]
        )
        await #expect(throws: EmbeddingGemmaClient.ClientError.self) {
            try await client.evaluate(request: req)
        }
    }
}
