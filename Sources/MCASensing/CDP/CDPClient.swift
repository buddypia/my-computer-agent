import Foundation
import MCACore
import OSLog

/// A Chrome DevTools Protocol error returned by the browser.
public struct CDPError: Error, Sendable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var method: String

    public var description: String { "\(method) failed (\(code)): \(message)" }
}

/// Where the connection went. Surfaced to drivers so they can reconnect.
public enum CDPConnectionState: Sendable, Equatable {
    case connecting
    case open
    case closed(reason: String)
}

/// The transport a `CDPClient` speaks over. Real connections use a
/// `URLSessionWebSocketTask`; tests use an in-memory fake.
public protocol CDPTransport: Sendable {
    func send(_ text: String) async throws
    /// Blocks until the next text frame arrives, or throws when closed.
    func receive() async throws -> String
    func close() async
}

/// JSON-RPC multiplexer over one DevTools WebSocket.
///
/// Uses one browser-level connection,
/// flattened target sessions addressed by `sessionId`, in-flight commands
/// tracked by id, and events fanned out to registered listeners. The client
/// does not interpret any protocol domain — that is the page's job.
public actor CDPClient {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "CDP")

    private let transport: any CDPTransport
    private var nextID = 1
    /// `MCA_CDP_TRACE=1` prints every frame to stderr, truncated.
    nonisolated static let trace = ProcessInfo.processInfo.environment["MCA_CDP_TRACE"] == "1"
    private var inflight: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var inflightMethods: [Int: String] = [:]
    private var listeners: [UUID: EventListener] = [:]
    private var receiveTask: Task<Void, Never>?
    public private(set) var state: CDPConnectionState = .connecting
    /// Default per-command timeout. Long enough for a slow `DOM.getDocument`
    /// on a heavy page, short enough that a wedged browser does not hang a turn.
    public var commandTimeout: TimeInterval = 30

    private struct EventListener {
        let sessionID: String?
        let method: String
        let handler: @Sendable (JSONValue) -> Void
    }

    public init(transport: any CDPTransport) {
        self.transport = transport
    }

    /// Opens a DevTools WebSocket and starts the receive loop.
    public static func connect(to url: URL) async throws -> CDPClient {
        let transport = try await WebSocketTransport.open(url)
        let client = CDPClient(transport: transport)
        await client.start()
        return client
    }

    public func start() {
        state = .open
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func close() async {
        receiveTask?.cancel()
        await transport.close()
        finish(reason: "closed by client")
    }

    // MARK: - Commands

    /// Sends one command and awaits its result. `sessionID` routes to an
    /// attached target; nil addresses the browser itself.
    @discardableResult
    public func send(_ method: String, params: JSONValue = .object([:]), sessionID: String? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard case .open = state else {
            throw BrowserError.notConnected("DevTools connection is \(stateDescription)")
        }
        let id = nextID
        nextID += 1

        var message: [String: JSONValue] = [
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        let data = try JSONValue.object(message).encoded()
        let text = String(decoding: data, as: UTF8.self)

        if Self.trace { FileHandle.standardError.write(Data("cdp → \(text.prefix(400))\n".utf8)) }
        let effectiveTimeout = timeout ?? commandTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
            await self?.fail(id: id, error: BrowserError.timeout("\(method) (\(Int(effectiveTimeout))s)"))
        }
        defer { timeoutTask.cancel() }

        let transport = self.transport
        return try await withCheckedThrowingContinuation { continuation in
            register(id: id, method: method, continuation: continuation)
            Task { [weak self] in
                do { try await transport.send(text) } catch {
                    await self?.fail(id: id, error: error)
                }
            }
        }
    }

    private func register(id: Int, method: String, continuation: CheckedContinuation<JSONValue, Error>) {
        inflight[id] = continuation
        inflightMethods[id] = method
    }

    private func fail(id: Int, error: Error) {
        guard let continuation = inflight.removeValue(forKey: id) else { return }
        inflightMethods.removeValue(forKey: id)
        continuation.resume(throwing: error)
    }

    // MARK: - Events

    /// Registers a handler for `method` events. A nil `sessionID` receives the
    /// event from every session, which is what browser-level listeners want.
    @discardableResult
    public func on(_ method: String, sessionID: String? = nil, handler: @escaping @Sendable (JSONValue) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = EventListener(sessionID: sessionID, method: method, handler: handler)
        return id
    }

    public func off(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    /// Waits for the next matching event. `predicate` can narrow it (for
    /// example to a specific frame id).
    public func waitFor(_ method: String, sessionID: String? = nil, timeout: TimeInterval, where predicate: @escaping @Sendable (JSONValue) -> Bool = { _ in true }) async throws -> JSONValue {
        let box = ContinuationBox()
        let token = on(method, sessionID: sessionID) { params in
            guard predicate(params) else { return }
            box.resume(with: .success(params))
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.resume(with: .failure(BrowserError.timeout("event \(method)")))
        }
        defer {
            off(token)
            timeoutTask.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            box.store(continuation)
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while !Task.isCancelled {
            let text: String
            do {
                text = try await transport.receive()
            } catch {
                finish(reason: error.localizedDescription)
                return
            }
            if Self.trace { FileHandle.standardError.write(Data("cdp ← \(text.prefix(400))\n".utf8)) }
            guard let data = text.data(using: .utf8), let message = try? JSONValue(data: data) else {
                log.debug("Dropping unparseable DevTools frame")
                continue
            }
            dispatch(message)
        }
    }

    private func dispatch(_ message: JSONValue) {
        if let id = message["id"].intValue {
            guard let continuation = inflight.removeValue(forKey: id) else { return }
            let method = inflightMethods.removeValue(forKey: id) ?? "?"
            if case .object(let error) = message["error"] {
                let cdpError = CDPError(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "unknown error",
                    method: method)
                continuation.resume(throwing: cdpError)
            } else {
                continuation.resume(returning: message["result"])
            }
            return
        }

        guard let method = message["method"].stringValue else { return }
        let sessionID = message["sessionId"].stringValue
        let params = message["params"]
        for listener in listeners.values where listener.method == method {
            if let wanted = listener.sessionID, wanted != sessionID { continue }
            listener.handler(params)
        }
    }

    private func finish(reason: String) {
        if case .closed = state { return }
        state = .closed(reason: reason)
        let pending = inflight
        inflight.removeAll()
        inflightMethods.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: BrowserError.notConnected("DevTools connection closed: \(reason)"))
        }
        log.info("DevTools connection closed: \(reason, privacy: .public)")
    }

    private var stateDescription: String {
        switch state {
        case .connecting: return "still connecting"
        case .open: return "open"
        case .closed(let reason): return "closed (\(reason))"
        }
    }
}

/// A continuation that can be resumed at most once from any context.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var pending: Result<JSONValue, Error>?

    func store(_ continuation: CheckedContinuation<JSONValue, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<JSONValue, Error>) {
        lock.lock()
        guard let continuation else {
            if pending == nil { pending = result }
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

/// `URLSessionWebSocketTask` behind the `CDPTransport` protocol.
public final class WebSocketTransport: CDPTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    private init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    public static func open(_ url: URL) async throws -> WebSocketTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        // Accessibility and DOM trees for a heavy page exceed the 1 MiB default.
        task.maximumMessageSize = 256 * 1024 * 1024
        task.resume()
        let transport = WebSocketTransport(task: task, session: session)
        // Sending a ping proves the handshake finished; `resume()` alone does
        // not fail for an unreachable endpoint until the first receive.
        try await transport.ping()
        return transport
    }

    private func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: BrowserError.notConnected(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
