import Foundation
import MCACore
import Network
import Testing

@testable import MCASensing

/// The user's window exclusion list must gate every path that hands browser
/// content to the model, not only screenshots.
@Suite("Accessibility driver honours the exclusion list")
struct AXBrowserReadExclusionTests {
    private func driver(excluding needle: String) -> AXBrowserDriver {
        AXBrowserDriver(isWindowExcluded: { _, title in title.contains(needle) })
    }

    @Test("a window whose title matches is refused")
    func refusesExcludedTitle() {
        let driver = driver(excluding: "Bank")
        #expect(throws: BrowserError.self) {
            try driver.checkReadable(bundleID: "com.google.Chrome", title: "My Bank - Accounts", url: "https://example.com")
        }
    }

    @Test("a page whose URL matches is refused")
    func refusesExcludedURL() {
        let driver = driver(excluding: "bank.example")
        #expect(throws: BrowserError.self) {
            try driver.checkReadable(bundleID: "com.google.Chrome", title: "Accounts", url: "https://bank.example/home")
        }
    }

    @Test("the refusal is BrowserError.blocked")
    func refusalIsBlocked() {
        let driver = driver(excluding: "Bank")
        do {
            try driver.checkReadable(bundleID: nil, title: "Bank", url: "")
            Issue.record("expected a refusal")
        } catch let error as BrowserError {
            if case .blocked = error {} else { Issue.record("expected blocked, got \(error)") }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an unrelated window and no exclusion list are both readable")
    func allowsOthers() throws {
        try driver(excluding: "Bank").checkReadable(bundleID: "com.apple.Safari", title: "News", url: "https://example.com")
        try AXBrowserDriver().checkReadable(bundleID: "com.apple.Safari", title: "Bank", url: "")
    }
}

@Suite("DevTools driver honours the exclusion list on every path")
struct CDPBrowserExclusionTests {
    /// Answers `Runtime.evaluate` with a fixed page state; everything else with `{}`.
    private func fakeClient(url: String, title: String) async -> (CDPClient, FakeTransport) {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            if message["method"] as? String == "Runtime.evaluate" {
                return [#"{"id":\#(id),"result":{"result":{"value":{"url":"\#(url)","title":"\#(title)","readyState":"complete"}}}}"#]
            }
            return [#"{"id":\#(id),"result":{}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        return (client, transport)
    }

    private func excludedDriver(
        client: CDPClient, endpoint: ChromeDevToolsEndpoint? = nil, activeTab: String? = "tab-1"
    ) async -> CDPBrowserDriver {
        let driver = CDPBrowserDriver(isPageExcluded: { url, title in
            title.contains("Secret") || url.contains("secret.example")
        })
        await driver.attachForTesting(client: client, endpoint: endpoint, activeTargetID: activeTab)
        return driver
    }

    @Test("perform refuses on an excluded page before sending any input")
    func performRefuses() async throws {
        let (client, transport) = await fakeClient(url: "https://secret.example/", title: "Secret")
        let driver = await excludedDriver(client: client)
        await #expect(throws: BrowserError.self) {
            _ = try await driver.perform(BrowserAction(method: .press, arguments: ["Enter"]), ref: nil, target: nil)
        }
        #expect(await !transport.sentMethods.contains { $0.hasPrefix("Input.") })
    }

    @Test("wait for text refuses on an excluded page instead of polling its content")
    func waitRefuses() async throws {
        let (client, transport) = await fakeClient(url: "https://secret.example/", title: "Secret")
        let driver = await excludedDriver(client: client)
        await #expect(throws: BrowserError.self) {
            try await driver.wait(for: .text("hello"), timeout: 1)
        }
        // Only the page-state probe may have run, never a document read.
        let sent = await transport.sent
        #expect(!sent.contains { $0.contains("innerText") || $0.contains("hello") })
    }

    @Test("switchTab refuses to adopt an excluded tab")
    func switchTabRefuses() async throws {
        let (client, transport) = await fakeClient(url: "https://ok.example/", title: "Fine")
        let server = try await TabListServer.start(
            #"[{"id":"tab-secret","type":"page","title":"Secret inbox","url":"https://secret.example/"}]"#)
        defer { server.stop() }
        let driver = await excludedDriver(
            client: client, endpoint: ChromeDevToolsEndpoint(host: "127.0.0.1", port: server.port), activeTab: nil)
        await #expect(throws: BrowserError.self) {
            try await driver.switchTab(id: "tab-secret")
        }
        #expect(await !transport.sentMethods.contains("Target.attachToTarget"))
        #expect(await driver.activeTabID == nil)
    }
}

/// One-shot local HTTP server answering every request with a fixed JSON body,
/// standing in for the DevTools `/json/list` endpoint.
private final class TabListServer: @unchecked Sendable {
    private let listener: NWListener
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(_ body: String) async throws -> TabListServer {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let payload = Data(body.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        let port = try #require(listener.port?.rawValue)
        return TabListServer(listener: listener, port: Int(port))
    }

    func stop() { listener.cancel() }
}
