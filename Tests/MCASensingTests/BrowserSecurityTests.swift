import Foundation
import MCACore
import Network
import Testing

@testable import MCASensing

@Suite("DevTools endpoint trust")
struct DevToolsEndpointTrustTests {
    @Test("loopback WebSocket URLs are accepted", arguments: [
        "ws://127.0.0.1:9222/devtools/browser/abc",
        "ws://localhost:9222/devtools/browser/abc",
        "ws://[::1]:9222/devtools/browser/abc",
    ])
    func acceptsLoopback(_ raw: String) throws {
        try ChromeDevToolsEndpoint.validateWebSocketURL(URL(string: raw)!, endpointHost: "127.0.0.1")
    }

    @Test("a WebSocket URL pointing off this machine is refused", arguments: [
        "ws://evil.example:9222/devtools/browser/abc",
        "ws://192.168.1.20:9222/devtools/browser/abc",
        "wss://127.0.0.1.evil.example/devtools/browser/abc",
    ])
    func refusesForeignHost(_ raw: String) {
        #expect(throws: BrowserError.self) {
            try ChromeDevToolsEndpoint.validateWebSocketURL(URL(string: raw)!, endpointHost: "127.0.0.1")
        }
    }

    @Test("only ws and wss schemes are accepted")
    func refusesOtherSchemes() {
        #expect(throws: BrowserError.self) {
            try ChromeDevToolsEndpoint.validateWebSocketURL(
                URL(string: "http://127.0.0.1:9222/devtools/browser/abc")!, endpointHost: "127.0.0.1")
        }
    }

    @Test("the host the user configured on purpose is trusted")
    func acceptsConfiguredHost() throws {
        try ChromeDevToolsEndpoint.validateWebSocketURL(
            URL(string: "ws://devbox.local:9222/devtools/browser/abc")!, endpointHost: "devbox.local")
    }

    @Test("Chrome is told to accept one origin, never a wildcard")
    func allowedOriginIsNotAWildcard() {
        let origin = ChromeDevToolsEndpoint.allowedOrigin(port: 9222)
        #expect(origin == "http://127.0.0.1:9222")
        #expect(!origin.contains("*"))
    }

    /// Chrome rejects a DevTools WebSocket upgrade only when it carries an
    /// `Origin` that is not allow-listed; one with no `Origin` passes. Narrowing
    /// `--remote-allow-origins` is therefore safe exactly as long as our own
    /// client sends none, which is what this pins down by reading the handshake
    /// it actually produces.
    @Test("our WebSocket client sends no Origin header")
    func clientSendsNoOrigin() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let request = RequestBox()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                request.set(String(decoding: data ?? Data(), as: UTF8.self))
                connection.cancel()
            }
        }
        listener.start(queue: .global())
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        let port = try #require(listener.port?.rawValue)

        let opening = Task { try await WebSocketTransport.open(URL(string: "ws://127.0.0.1:\(port)/devtools/browser/x")!) }
        for _ in 0..<100 where request.value.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        opening.cancel()
        listener.cancel()

        let handshake = request.value
        #expect(handshake.contains("Upgrade: websocket") || handshake.lowercased().contains("upgrade: websocket"))
        #expect(!handshake.lowercased().contains("\norigin:"))
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}

@Suite("Browser navigation scheme policy")
struct BrowserURLPolicyTests {
    @Test("http and https URLs are accepted, any case", arguments: [
        "https://example.com/path?q=1", "http://localhost:3000", "HTTPS://Example.com",
        "  https://example.com  ",
    ])
    func acceptsWeb(_ raw: String) throws {
        _ = try BrowserURLPolicy.validate(raw)
    }

    @Test("other schemes are refused", arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,<script>1</script>",
        "chrome://settings", "ftp://example.com", "vbscript:x", "slack://open", "about:blank",
        "https://", "not a url",
    ])
    func refusesNonWeb(_ raw: String) {
        #expect(throws: BrowserError.self) { try BrowserURLPolicy.validate(raw) }
    }

    @Test("about:blank is admitted only when asked for, and nothing else with it")
    func blankOnlyWhenAllowed() throws {
        _ = try BrowserURLPolicy.validate("about:blank", allowBlank: true)
        #expect(throws: BrowserError.self) { try BrowserURLPolicy.validate("about:config", allowBlank: true) }
        #expect(throws: BrowserError.self) { try BrowserURLPolicy.validate("file:///x", allowBlank: true) }
    }

    @Test("the DevTools driver refuses a non-web URL before it touches the browser")
    func cdpNavigateRefuses() async {
        let driver = CDPBrowserDriver()
        await #expect(throws: BrowserError.self) {
            try await driver.navigate(to: "file:///etc/passwd", waitUntil: .load)
        }
        await #expect(throws: BrowserError.self) {
            _ = try await driver.openTab(url: "javascript:alert(1)")
        }
    }

    @Test("the Accessibility driver refuses a non-web URL before it touches the browser")
    func axNavigateRefuses() async {
        let driver = AXBrowserDriver()
        do {
            try await driver.navigate(to: "file:///etc/passwd", waitUntil: .load)
            Issue.record("navigate to file:// should have been refused")
        } catch let error as BrowserError {
            guard case .navigationFailed = error else {
                Issue.record("expected navigationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("Browser text redaction")
struct BrowserRedactionTests {
    @Test("a snapshot's outline, URL and title are scrubbed")
    func redactsSnapshot() {
        // Fake credentials are assembled at run time so secret scanners do not
        // flag this fixture; the redactor still sees the full literal shapes.
        let fake = "abcdefghijklmnop"
        let secret = "sk-" + fake + "qrstuvwxyz0123"
        let urlToken = fake + "1234"
        let apiKey = fake + "1234567890"
        let snapshot = BrowserSnapshot(
            driver: .devtools,
            url: "https://example.com/cb?" + "token=" + urlToken,
            title: "Key \(secret)",
            outline: "[0-1] textbox: " + "api_key=" + apiKey + "\n[0-2] text: card 4111 2222 3333 4444",
            refs: [:])
        let clean = PrivacyFilter().redact(snapshot)
        #expect(!clean.url.contains(urlToken))
        #expect(!clean.title.contains(secret))
        #expect(!clean.outline.contains(apiKey))
        #expect(!clean.outline.contains("4111 2222 3333 4444"))
        #expect(clean.outline.contains("[0-1] textbox"))
    }

    @Test("the password-manager list matches regardless of case")
    func blockedBundleIDsCaseInsensitive() {
        let filter = PrivacyFilter()
        #expect(filter.isApplicationBlocked(bundleID: "com.lastpass.LastPass"))
        #expect(filter.isApplicationBlocked(bundleID: "COM.LASTPASS.LASTPASS"))
    }
}

// Serialized: `processWideExclusion` is process-global, and a test that sets it
// would otherwise change what a sibling test's `isRefused` sees.
@Suite("Screen capture exclusions", .serialized)
struct ScreenCaptureExclusionTests {
    @Test("password managers are refused even when the caller passes no list")
    func alwaysRefusesPasswordManagers() {
        #expect(ScreenCapturer.isRefused(
            bundleID: "com.1password.1password", windowTitle: "Vault") { _, _ in false })
        #expect(!ScreenCapturer.isRefused(
            bundleID: "com.apple.Safari", windowTitle: "News") { _, _ in false })
    }

    @Test("the process-wide user list applies to a caller that passes none")
    func processWideListApplies() {
        let marker = "mca-test-\(UUID().uuidString)"
        let before = ScreenCapturer.processWideExclusion
        defer { ScreenCapturer.processWideExclusion = before }

        #expect(!ScreenCapturer.isRefused(
            bundleID: "com.example.app", windowTitle: marker) { _, _ in false })
        ScreenCapturer.processWideExclusion = { _, title in title == marker }
        #expect(ScreenCapturer.isRefused(
            bundleID: "com.example.app", windowTitle: marker) { _, _ in false })
        #expect(!ScreenCapturer.isRefused(
            bundleID: "com.example.app", windowTitle: "other") { _, _ in false })
    }

    @Test("the caller's own list is honoured on top")
    func honoursCallerList() {
        #expect(ScreenCapturer.isRefused(
            bundleID: "com.apple.Safari", windowTitle: "Private Browsing") { _, title in
                title.contains("Private")
            })
    }
}
