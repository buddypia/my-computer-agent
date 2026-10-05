import AppKit
import Foundation
import MCACore
import OSLog

/// Finds a Chromium browser exposing the DevTools HTTP endpoint and talks to
/// its `/json/*` surface (target listing, tab creation, activation).
///
/// This is the "attach to the user's running Chrome" mode. Attaching keeps the user's cookies and logins,
/// which is the whole point of driving the browser they already use. Launching
/// a fresh profile is offered as an explicit fallback only.
public struct ChromeDevToolsEndpoint: Sendable {
    public struct Target: Sendable, Equatable {
        public var id: String
        public var type: String
        public var title: String
        public var url: String
        public var webSocketDebuggerURL: URL?
    }

    public struct Version: Sendable, Equatable {
        public var browser: String
        public var protocolVersion: String
        public var webSocketDebuggerURL: URL
    }

    public var host: String
    public var port: Int
    public var requestTimeout: TimeInterval

    private var base: URL { URL(string: "http://\(host):\(port)")! }

    public init(host: String = "127.0.0.1", port: Int, requestTimeout: TimeInterval = 2) {
        self.host = host
        self.port = port
        self.requestTimeout = requestTimeout
    }

    /// Ports probed, in order, when no endpoint is configured. 9222 is the
    /// DevTools default; 9333 is what this project's own tooling uses.
    public static let defaultPorts = [9222, 9333]

    /// The first configured port that answers `/json/version`.
    public static func discover(host: String = "127.0.0.1", ports: [Int] = defaultPorts) async -> (ChromeDevToolsEndpoint, Version)? {
        for port in ports {
            let endpoint = ChromeDevToolsEndpoint(host: host, port: port)
            if let version = try? await endpoint.version() {
                return (endpoint, version)
            }
        }
        return nil
    }

    public func version() async throws -> Version {
        let json = try await get("/json/version")
        guard let ws = json["webSocketDebuggerUrl"].stringValue, let url = URL(string: ws) else {
            throw BrowserError.notConnected("\(base.absoluteString) did not return a webSocketDebuggerUrl")
        }
        try Self.validateWebSocketURL(url, endpointHost: host)
        return Version(
            browser: json["Browser"].stringValue ?? "unknown",
            protocolVersion: json["Protocol-Version"].stringValue ?? "",
            webSocketDebuggerURL: url)
    }

    /// Refuses a `webSocketDebuggerUrl` that points anywhere but where we asked.
    ///
    /// The URL comes from the endpoint's own JSON, so whatever answered on the
    /// port decides where the full-control DevTools socket is opened. Anything
    /// other than this machine (or the host the user configured on purpose)
    /// would hand the agent's CDP traffic — page contents, typed text — to a
    /// third party.
    static func validateWebSocketURL(_ url: URL, endpointHost: String) throws {
        let allowedHosts = Self.loopbackHosts.union([Self.normalizedHost(endpointHost)])
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              let host = url.host.map(Self.normalizedHost), allowedHosts.contains(host)
        else {
            throw BrowserError.notConnected(
                "DevTools endpoint advertised a WebSocket URL outside this machine (\(url.host ?? "no host")); refusing to connect")
        }
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// The only Origin Chrome is told to accept on the DevTools socket. Our own
    /// client sends none, which Chrome accepts regardless; the flag exists so a
    /// *web page* cannot open the socket (it would carry its own Origin), and
    /// `*` would let any page the user visits do exactly that.
    static func allowedOrigin(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// Page targets only — DevTools also lists workers, extensions and iframes.
    public func pages() async throws -> [Target] {
        let json = try await get("/json/list")
        return (json.arrayValue ?? []).compactMap { entry in
            guard entry["type"].stringValue == "page", let id = entry["id"].stringValue else { return nil }
            return Target(
                id: id,
                type: "page",
                title: entry["title"].stringValue ?? "",
                url: entry["url"].stringValue ?? "",
                webSocketDebuggerURL: entry["webSocketDebuggerUrl"].stringValue.flatMap(URL.init(string:)))
        }
    }

    /// Opens a new tab. Chrome requires PUT here since M92.
    public func newPage(url: String) async throws -> Target {
        var components = URLComponents(url: base.appending(path: "/json/new"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.timeoutInterval = requestTimeout
        let json = try await perform(request)
        guard let id = json["id"].stringValue else {
            throw BrowserError.protocolError("/json/new returned no target id")
        }
        return Target(
            id: id, type: "page",
            title: json["title"].stringValue ?? "",
            url: json["url"].stringValue ?? url,
            webSocketDebuggerURL: json["webSocketDebuggerUrl"].stringValue.flatMap(URL.init(string:)))
    }

    public func activate(targetID: String) async throws {
        _ = try await getText("/json/activate/\(targetID)")
    }

    public func close(targetID: String) async throws {
        _ = try await getText("/json/close/\(targetID)")
    }

    // MARK: - Launching

    /// Starts a separate Chrome with remote debugging on `port`, using its own
    /// profile directory so it never touches the user's default profile.
    ///
    /// Only called when the caller opted in: a second Chrome window appearing
    /// unasked is exactly the kind of side effect an assistant should not
    /// produce on its own.
    public static func launchChrome(port: Int, userDataDirectory: URL, executable: URL? = nil, startURL: String = "about:blank") throws {
        let candidates = [
            executable,
            URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            URL(fileURLWithPath: "/Applications/Chromium.app/Contents/MacOS/Chromium"),
            URL(fileURLWithPath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
            URL(fileURLWithPath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
            URL(fileURLWithPath: "/Applications/Arc.app/Contents/MacOS/Arc"),
        ].compactMap { $0 }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BrowserError.notConnected("No Chromium-based browser found in /Applications")
        }
        try FileManager.default.createDirectory(at: userDataDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-backgrounding-occluded-windows",
            "--remote-allow-origins=\(Self.allowedOrigin(port: port))",
            startURL,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Waits until `/json/version` answers, or gives up.
    public func waitUntilReady(timeout: TimeInterval = 10) async throws -> Version {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = BrowserError.notConnected("DevTools endpoint not reachable")
        while Date() < deadline {
            do { return try await version() } catch { lastError = error }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError
    }

    // MARK: - HTTP

    private func get(_ path: String) async throws -> JSONValue {
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = requestTimeout
        return try await perform(request)
    }

    private func getText(_ path: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = requestTimeout
        let (data, _) = try await Self.session.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BrowserError.protocolError("\(request.url?.path ?? "?") returned HTTP \(http.statusCode)")
        }
        return try JSONValue(data: data)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
