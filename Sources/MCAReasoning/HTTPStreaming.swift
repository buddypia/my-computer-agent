import Foundation

/// Shared HTTP + Server-Sent Events plumbing for the cloud executors.
///
/// All three cloud providers stream over SSE with slightly different framing,
/// so the transport is factored out and each executor only implements its own
/// payload encoding and event decoding.
enum HTTPStreaming {
    /// A URLSession configured for long-lived streaming responses.
    ///
    /// The default 60 s resource timeout would abort a long generation
    /// mid-stream, so it is raised; the *request* timeout stays short because
    /// that one only covers time-to-first-byte.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "MyComputerAgent/1.0"]
        return URLSession(configuration: configuration)
    }()

    /// The active session. Internal so tests can inject mock transports.
    nonisolated(unsafe) static var session: URLSession = defaultSession

    /// Determines whether an error represents a dropped or transient transport failure
    /// that is safe to retry before headers or body bytes have arrived.
    static func isTransientConnectionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost,
                 .cannotConnectToHost,
                 .timedOut,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable,
                 .cannotFindHost:
                return true
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorCannotFindHost:
                return true
            default:
                break
            }
        }
        if nsError.domain == "kCFErrorDomainCFNetwork" && nsError.code == -1005 {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ECONNRESET, EPIPE, ENOTCONN, ETIMEDOUT, ECONNREFUSED:
                return true
            default:
                break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransientConnectionError(underlying)
        }
        return false
    }

    /// Executes `session.bytes(for: request)` with automatic retry for transient connection failures.
    ///
    /// When URLSession reuses an idle persistent connection that was closed by the remote
    /// server (e.g. Google's keep-alive timeout), CFNetwork will not automatically retry
    /// POST requests and immediately throws `NSURLErrorNetworkConnectionLost (-1005)`.
    /// Retrying once or twice on a fresh connection succeeds transparently.
    static func bytesWithRetry(
        for request: URLRequest,
        maxRetries: Int = 2
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var attempts = 0
        while true {
            do {
                return try await session.bytes(for: request)
            } catch {
                attempts += 1
                if attempts <= maxRetries && isTransientConnectionError(error) {
                    let delayMs = UInt64(attempts * 150) * 1_000_000
                    try? await Task.sleep(nanoseconds: delayMs)
                    continue
                }
                throw error
            }
        }
    }

    /// Streams `data:` payloads from an SSE endpoint.
    ///
    /// Yields the raw JSON string of each event, one event per element.
    /// `[DONE]` sentinels are swallowed here so executors do not each
    /// reimplement that check.
    static func sseLines(for request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await bytesWithRetry(for: request)
        } catch let error as LanguageModelError {
            throw error
        } catch is CancellationError {
            throw LanguageModelError.cancelled
        } catch {
            throw LanguageModelError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Drain the body so the error carries the provider's message
            // rather than just a bare status code.
            var body = ""
            do {
                for try await line in bytes.lines {
                    body += line
                    if body.count > 4000 { break }
                }
            } catch {
                // If draining fails, still report the HTTP status code
            }
            throw LanguageModelError.http(status: http.statusCode, body: body)
        }

        return events(from: bytes)
    }

    /// Splits an SSE body into one payload per event.
    ///
    /// Generic over the byte source, and separated from the request above, so
    /// the framing can be tested against a recorded body instead of only ever
    /// being exercised against a live provider.
    ///
    /// The framing is done by hand rather than with `bytes.lines`. That was the
    /// original implementation and it is silently wrong here:
    /// `AsyncLineSequence` drops empty lines, and an empty line is exactly what
    /// terminates an SSE event. Every event in a response therefore arrived
    /// glued to the next one — `{...}{...}` — which is not valid JSON, so each
    /// executor's `parseJSONObject` returned nil and skipped it. A model reply
    /// that spanned more than one chunk came back as no reply at all: the HUD
    /// showed "Thinking" and then quietly reverted.
    static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<String, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // An SSE event may carry its payload across several `data:`
                    // lines. Per the spec they are joined with a newline, which
                    // for the JSON these providers send is insignificant
                    // whitespace either way.
                    var payloads: [String] = []
                    var line: [UInt8] = []
                    var done = false

                    func endOfEvent() {
                        defer { payloads.removeAll() }
                        guard !payloads.isEmpty else { return }
                        continuation.yield(payloads.joined(separator: "\n"))
                    }

                    /// Handles one complete line. Returns false at `[DONE]`.
                    func endOfLine() -> Bool {
                        defer { line.removeAll(keepingCapacity: true) }
                        // Providers terminate with CRLF; the CR is not content.
                        var bytes = line
                        if bytes.last == Self.carriageReturn { bytes.removeLast() }
                        guard !bytes.isEmpty else {
                            endOfEvent()
                            return true
                        }

                        let text = String(decoding: bytes, as: UTF8.self)
                        // `event:`, `id:`, `retry:` and `:` comments carry no
                        // payload for any provider here.
                        guard text.hasPrefix("data:") else { return true }

                        var payload = text.dropFirst(5)
                        // Exactly one optional space after the colon is
                        // separator; anything further belongs to the payload.
                        if payload.first == " " { payload = payload.dropFirst() }
                        if payload == "[DONE]" { return false }
                        payloads.append(String(payload))
                        return true
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard byte != Self.newline else {
                            if !endOfLine() { done = true; break }
                            continue
                        }
                        line.append(byte)
                    }

                    // A body that ends without its final blank line still has an
                    // event in hand; dropping it would lose the last chunk.
                    if !done {
                        if !line.isEmpty { _ = endOfLine() }
                        endOfEvent()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LanguageModelError.cancelled)
                } catch {
                    continuation.finish(throwing: LanguageModelError.transport(
                        error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// Non-streaming POST returning the whole body.
    static func post(_ request: URLRequest, maxRetries: Int = 2) async throws -> Data {
        var attempts = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LanguageModelError.transport("Non-HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw LanguageModelError.http(
                        status: http.statusCode,
                        body: String(data: data, encoding: .utf8) ?? "")
                }
                return data
            } catch let error as LanguageModelError {
                throw error
            } catch is CancellationError {
                throw LanguageModelError.cancelled
            } catch {
                attempts += 1
                if attempts <= maxRetries && isTransientConnectionError(error) {
                    let delayMs = UInt64(attempts * 150) * 1_000_000
                    try? await Task.sleep(nanoseconds: delayMs)
                    continue
                }
                throw LanguageModelError.transport(error.localizedDescription)
            }
        }
    }
}

/// Small helpers for walking provider JSON without declaring a Codable type per
/// provider per response shape.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let value = self[key] as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double, value.isFinite { return Int(exactly: value) }
        return nil
    }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
}

func parseJSONObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
