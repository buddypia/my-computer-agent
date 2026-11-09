import Foundation
import Testing
@testable import MCACore
@testable import MCASensing

/// A gesture that fails after some of its events went out must say so, because the
/// browser session retries other failures with a different method.
@Suite("CDP gesture delivery")
struct CDPGestureTests {
    /// A page whose browser rejects the `failOn`-th input event and acknowledges the rest.
    private func page(failOn: Int) async -> (CDPPage, FakeTransport) {
        let counter = Counter()
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            if (message["method"] as? String)?.hasPrefix("Input.") == true, counter.next() == failOn {
                return [#"{"id":\#(id),"error":{"code":-32000,"message":"rejected"}}"#]
            }
            return [#"{"id":\#(id),"result":{}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        return (CDPPage(client: client, targetID: "t", sessionID: "s"), transport)
    }

    @Test("a click rejected after its first event reports possible delivery")
    func midClickIsUncertain() async throws {
        let (page, _) = await page(failOn: 3)
        do {
            try await page.dispatchClick(at: CGPoint(x: 5, y: 5))
            Issue.record("expected an error")
        } catch BrowserError.deliveryUncertain(let detail) {
            #expect(detail.contains("click stopped after 2 input events"))
        }
    }

    @Test("a chord rejected on its first event stays a plain error, so another method may try")
    func firstEventRejectedIsPlain() async throws {
        let (page, transport) = await page(failOn: 1)
        await #expect(throws: CDPError.self) { try await page.press("Cmd+A") }
        #expect(await transport.sentMethods == ["Input.dispatchKeyEvent"])
    }

    @Test("a chord rejected part-way reports possible delivery")
    func midChordIsUncertain() async throws {
        let (page, _) = await page(failOn: 2)
        do {
            try await page.press("Cmd+A")
            Issue.record("expected an error")
        } catch BrowserError.deliveryUncertain(let detail) {
            #expect(detail.contains("key Cmd+A stopped after 1 input events"))
        }
    }

    /// A page whose browser never answers input events, so they stay in flight.
    private func silentPage() async -> (CDPPage, CDPClient, FakeTransport) {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            return (message["method"] as? String)?.hasPrefix("Input.") == true ? [] : [#"{"id":\#(id),"result":{}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        return (CDPPage(client: client, targetID: "t", sessionID: "s"), client, transport)
    }

    @Test("the connection closing while the first event is in flight reports possible delivery")
    func closedInFlightIsUncertain() async throws {
        let (page, _, transport) = await silentPage()
        let typing = Task { try await page.insertText("hello") }
        for _ in 0..<2_000 where await transport.sentMethods.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        await transport.close()
        do {
            try await typing.value
            Issue.record("expected an error")
        } catch BrowserError.deliveryUncertain(let detail) {
            #expect(detail.contains("typing stopped after 0 input events"))
        }
    }

    @Test("a connection already closed refuses the event as a plain error")
    func closedBeforeSendIsPlain() async throws {
        let (page, client, transport) = await silentPage()
        await transport.close()
        for _ in 0..<2_000 where await client.state == .open {
            try await Task.sleep(for: .milliseconds(1))
        }
        do {
            try await page.insertText("hello")
            Issue.record("expected an error")
        } catch BrowserError.notConnected {
        }
        #expect(await transport.sentMethods.isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
