import Foundation
import MCACore
import Testing

@testable import MCAReasoning

/// Mock URLProtocol to simulate network drops, retries, and streaming SSE responses.
final class MockHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let handler = Self.requestHandler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            do {
                let (response, data) = try handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        requestCount = 0
    }
}

@Suite("HTTPStreaming resiliency & retry", .serialized)
struct HTTPStreamingTests {
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Transient connection error classifier detects lost connections")
    func classifiesTransientErrors() {
        // -1005 NSURLErrorNetworkConnectionLost
        let lostURLError = URLError(.networkConnectionLost)
        #expect(HTTPStreaming.isTransientConnectionError(lostURLError))

        let lostNSError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        #expect(HTTPStreaming.isTransientConnectionError(lostNSError))

        // Underlying CFNetwork -1005
        let cfNetworkError = NSError(
            domain: "kCFErrorDomainCFNetwork",
            code: -1005,
            userInfo: nil
        )
        #expect(HTTPStreaming.isTransientConnectionError(cfNetworkError))

        let wrappedError = NSError(
            domain: "CustomDomain",
            code: 999,
            userInfo: [NSUnderlyingErrorKey: lostURLError]
        )
        #expect(HTTPStreaming.isTransientConnectionError(wrappedError))

        // Other transient connection errors
        #expect(HTTPStreaming.isTransientConnectionError(URLError(.cannotConnectToHost)))
        #expect(HTTPStreaming.isTransientConnectionError(URLError(.timedOut)))
        #expect(HTTPStreaming.isTransientConnectionError(URLError(.dnsLookupFailed)))
        #expect(HTTPStreaming.isTransientConnectionError(URLError(.notConnectedToInternet)))

        // Non-transient errors
        #expect(!HTTPStreaming.isTransientConnectionError(URLError(.badURL)))
        #expect(!HTTPStreaming.isTransientConnectionError(URLError(.userAuthenticationRequired)))
        #expect(!HTTPStreaming.isTransientConnectionError(LanguageModelError.cancelled))
    }

    @Test("sseLines transparently retries on connection lost (-1005) and succeeds")
    func retriesAndSucceedsOnConnectionLost() async throws {
        MockHTTPProtocol.reset()
        defer {
            MockHTTPProtocol.reset()
            HTTPStreaming.session = HTTPStreaming.defaultSession
        }

        let mockSession = makeMockSession()
        HTTPStreaming.session = mockSession

        // First request fails with -1005 (stale connection in pool dropped)
        // Second request succeeds with SSE data
        MockHTTPProtocol.requestHandler = { request in
            if MockHTTPProtocol.requestCount == 1 {
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNetworkConnectionLost,
                    userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
                )
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let sseData = "data: {\"text\":\"Hello\"}\n\n".data(using: .utf8)!
            return (response, sseData)
        }

        let request = URLRequest(url: URL(string: "https://example.com/sse")!)
        var events: [String] = []
        for try await event in try await HTTPStreaming.sseLines(for: request) {
            events.append(event)
        }

        #expect(MockHTTPProtocol.requestCount == 2)
        #expect(events == ["{\"text\":\"Hello\"}"])
    }

    @Test("sseLines converts unrecoverable network errors to LanguageModelError.transport")
    func convertsNetworkErrorsToTransportError() async {
        MockHTTPProtocol.reset()
        defer {
            MockHTTPProtocol.reset()
            HTTPStreaming.session = HTTPStreaming.defaultSession
        }

        let mockSession = makeMockSession()
        HTTPStreaming.session = mockSession

        // Always fail with -1005
        MockHTTPProtocol.requestHandler = { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
            )
        }

        let request = URLRequest(url: URL(string: "https://example.com/sse")!)

        do {
            _ = try await HTTPStreaming.sseLines(for: request)
            Issue.record("Expected sseLines to throw LanguageModelError.transport")
        } catch let error as LanguageModelError {
            if case .transport(let message) = error {
                #expect(message.contains("The network connection was lost"))
            } else {
                Issue.record("Expected .transport, got \(error)")
            }
        } catch {
            Issue.record("Expected LanguageModelError, got \(error)")
        }
    }
}
