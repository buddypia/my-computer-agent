import Foundation
import MCACore
@testable import MCAMemory
import Testing

private final class Calls<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func http(_ status: Int, _ body: String) -> (Data, URLResponse) {
    let url = URL(string: "http://127.0.0.1:8765/v1/embed")!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Suite("EmbeddingGemma text embedding")
struct EmbeddingGemmaTextEmbeddingTests {
    @Test("embeds text into 256d normalized vector")
    func embedsText() async throws {
        let sent = Calls<URLRequest>()
        // Mock a 256-element vector
        let mockVector = (0..<256).map { Float($0) / 256.0 }
        let responseJson = """
        {
          "dim": 256,
          "vector": \(mockVector)
        }
        """

        let embedder = EmbeddingGemmaTextEmbedding(dimension: 256) { request in
            sent.append(request)
            return http(200, responseJson)
        }

        let vector = await embedder.embed("test query about shipping")
        let result = try #require(vector)
        #expect(result.count == 256)

        // Verify L2 normalization: sum of squares is ~1.0
        let sumSquares = result.reduce(0) { $0 + $1 * $1 }
        #expect(abs(sumSquares - 1.0) < 0.001)

        let req = try #require(sent.all.first)
        #expect(req.url?.absoluteString == "http://127.0.0.1:8765/v1/embed")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("empty or whitespace string returns nil without network call")
    func emptyStringReturnsNil() async {
        let sent = Calls<URLRequest>()
        let embedder = EmbeddingGemmaTextEmbedding { req in
            sent.append(req)
            return http(200, "{}")
        }

        let emptyResult = await embedder.embed("")
        #expect(emptyResult == nil)

        let whitespaceResult = await embedder.embed("   \n\t  ")
        #expect(whitespaceResult == nil)

        #expect(sent.all.isEmpty)
    }

    @Test("server error returns nil gracefully for fallback to lexical search")
    func serverErrorReturnsNil() async {
        let embedder = EmbeddingGemmaTextEmbedding { _ in
            http(500, "Server Error")
        }
        let result = await embedder.embed("search text")
        #expect(result == nil)
    }

    @Test("dimension mismatch returns nil")
    func dimensionMismatchReturnsNil() async {
        // Return 128 elements when 256 is expected
        let shortVector = (0..<128).map { Float($0) }
        let responseJson = """
        {
          "dim": 128,
          "vector": \(shortVector)
        }
        """
        let embedder = EmbeddingGemmaTextEmbedding(dimension: 256) { _ in
            http(200, responseJson)
        }
        let result = await embedder.embed("search text")
        #expect(result == nil)
    }
}
