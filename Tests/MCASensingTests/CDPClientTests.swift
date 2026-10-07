import Foundation
import Testing
@testable import MCACore
@testable import MCASensing

/// In-memory transport: the test scripts what the "browser" answers.
actor FakeTransport: CDPTransport {
    private var inbound: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private(set) var sent: [String] = []
    /// Called for every sent frame; returns frames to push back.
    private let responder: (@Sendable ([String: Any]) -> [String])?
    private var closed = false

    init(responder: (@Sendable ([String: Any]) -> [String])? = nil) {
        self.responder = responder
    }

    func send(_ text: String) async throws {
        sent.append(text)
        guard let responder, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for frame in responder(object) { push(frame) }
    }

    func push(_ text: String) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: text)
            return
        }
        inbound.append(text)
    }

    func receive() async throws -> String {
        if closed { throw BrowserError.notConnected("closed") }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: BrowserError.notConnected("closed")) }
    }

    var sentMethods: [String] {
        sent.compactMap { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["method"] as? String
        }
    }
}

@Suite("CDPClient multiplexing")
struct CDPClientTests {
    @Test("responses are matched to requests by id and results returned")
    func requestResponse() async throws {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            return [#"{"id":\#(id),"result":{"ok":true,"n":3}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        let result = try await client.send("Target.getTargets")
        #expect(result["ok"].boolValue == true)
        #expect(result["n"].intValue == 3)
        #expect(await transport.sentMethods == ["Target.getTargets"])
    }

    @Test("integer ids are not mistaken for booleans (NSNumber bridging)")
    func integerIDsDecode() throws {
        let message = try JSONValue(data: Data(#"{"id":1,"result":{"flag":true,"count":0}}"#.utf8))
        #expect(message["id"].intValue == 1)
        #expect(message["result"]["flag"].boolValue == true)
        #expect(message["result"]["count"].intValue == 0)
        if case .bool = message["id"] { Issue.record("id decoded as bool") }
        if case .number = message["result"]["flag"] { Issue.record("flag decoded as number") }
    }

    @Test("protocol errors surface as CDPError with the method name")
    func protocolError() async {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            return [#"{"id":\#(id),"error":{"code":-32000,"message":"No node with given id found"}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        do {
            _ = try await client.send("DOM.resolveNode", params: .object(["backendNodeId": 9]))
            Issue.record("expected an error")
        } catch let error as CDPError {
            #expect(error.method == "DOM.resolveNode")
            #expect(error.message.contains("No node"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("events reach listeners, filtered by session")
    func events() async throws {
        let transport = FakeTransport()
        let client = CDPClient(transport: transport)
        await client.start()
        let box = ContinuationBox()
        await client.on("Page.loadEventFired", sessionID: "S1") { params in box.resume(with: .success(params)) }
        await transport.push(#"{"method":"Page.loadEventFired","sessionId":"S2","params":{"timestamp":1}}"#)
        await transport.push(#"{"method":"Page.loadEventFired","sessionId":"S1","params":{"timestamp":2}}"#)
        let params = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            box.store(continuation)
        }
        #expect(params["timestamp"].intValue == 2)
    }

    @Test("a command that is never answered times out with the method name")
    func timeout() async {
        let transport = FakeTransport()
        let client = CDPClient(transport: transport)
        await client.start()
        do {
            _ = try await client.send("Runtime.evaluate", timeout: 0.05)
            Issue.record("expected timeout")
        } catch let error as BrowserError {
            #expect(error.description.contains("Runtime.evaluate"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("session ids are attached to routed commands")
    func sessionRouting() async throws {
        let transport = FakeTransport { message in [#"{"id":\#(message["id"] as? Int ?? 0),"result":{}}"#] }
        let client = CDPClient(transport: transport)
        await client.start()
        _ = try await client.send("Page.enable", sessionID: "S9")
        #expect(await transport.sent.first?.contains(#""sessionId":"S9""#) == true)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips through Foundation without changing number kinds")
    func roundTrip() throws {
        let value: JSONValue = .object(["a": 1, "b": true, "c": "x", "d": .array([.null, 2.5])])
        let data = try value.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""a":1"#))
        #expect(text.contains(#""b":true"#))
        let back = try JSONValue(data: data)
        #expect(back == value)
    }
}

@Suite("CDPKeyMap (key handling)")
struct CDPKeyMapTests {
    @Test("aliases normalise to DevTools names")
    func normalize() {
        #expect(CDPKeyMap.normalize("enter") == "Enter")
        #expect(CDPKeyMap.normalize("Return") == "Enter")
        #expect(CDPKeyMap.normalize("cmd") == "Meta")
        #expect(CDPKeyMap.normalize("esc") == "Escape")
        #expect(CDPKeyMap.normalize("a") == "a")
    }

    @Test("a chord holds modifiers around the main key")
    func chordEvents() {
        let events = CDPKeyMap.events(forChord: "Meta+KeyA")
        // Modifiers and modified letters go down as rawKeyDown (no text).
        #expect(events.map(\.type) == ["rawKeyDown", "rawKeyDown", "keyUp", "keyUp"])
        #expect(events[0].params["key"]?.stringValue == "Meta")
        #expect(events[1].params["modifiers"]?.intValue == 4)
        #expect(events[1].params["key"]?.stringValue == "a")
        // Cmd+A on a Mac must carry the editing command or the field ignores it.
        #expect(events[1].params["commands"]?.arrayValue?.first?.stringValue == "selectAll")
    }

    @Test("printable keys carry text so inputs receive the character")
    func printable() {
        let events = CDPKeyMap.events(forChord: "x")
        #expect(events.first?.params["text"]?.stringValue == "x")
        let enter = CDPKeyMap.events(forChord: "Enter")
        #expect(enter.first?.params["windowsVirtualKeyCode"]?.intValue == 13)
        #expect(enter.first?.params["text"]?.stringValue == "\r")
    }
}

@Suite("XPath helpers")
struct XPathTests {
    @Test("prefix and relativize are inverses across iframe boundaries")
    func prefixRelativize() {
        let host = "/html[1]/body[1]/iframe[1]"
        let inner = "/html[1]/body[1]/a[2]"
        let joined = XPath.prefix(host, with: inner)
        #expect(joined == "/html[1]/body[1]/iframe[1]/html[1]/body[1]/a[2]")
        #expect(XPath.relativize(base: "/html[1]/body[1]/iframe[1]", absolute: joined) == inner)
    }

    @Test("child segments are 1-based per tag")
    func segments() {
        let children: [JSONValue] = [
            .object(["nodeType": 1, "nodeName": "DIV"]),
            .object(["nodeType": 1, "nodeName": "A"]),
            .object(["nodeType": 3, "nodeName": "#text"]),
            .object(["nodeType": 1, "nodeName": "DIV"]),
        ]
        #expect(XPath.childSegments(children) == ["div[1]", "a[1]", "text()[1]", "div[2]"])
    }
}

@Suite("AXBrowserDriver pure mappings")
struct AXBrowserDriverMappingTests {
    @Test("AppKit roles map onto the DevTools vocabulary")
    func roles() {
        #expect(AXBrowserDriver.webRole(axRole: "AXButton", subrole: nil) == "button")
        #expect(AXBrowserDriver.webRole(axRole: "AXLink", subrole: nil) == "link")
        #expect(AXBrowserDriver.webRole(axRole: "AXTextField", subrole: "AXSearchField") == "searchbox")
        #expect(AXBrowserDriver.webRole(axRole: "AXGroup", subrole: "AXLandmarkMain") == "main")
        #expect(AXBrowserDriver.webRole(axRole: "AXGroup", subrole: nil) == "generic")
    }

    @Test("DevTools chords translate to the synthesizer's spelling")
    func chords() {
        #expect(AXBrowserDriver.chord(fromDevTools: "Meta+KeyA") == "cmd+a")
        #expect(AXBrowserDriver.chord(fromDevTools: "Control+Enter") == "ctrl+enter")
        #expect(AXBrowserDriver.chord(fromDevTools: "ArrowDown") == "down")
        #expect(AXBrowserDriver.percent("75%") == 75)
        #expect(AXBrowserDriver.percent(nil) == 0)
    }
}

@Suite("CDPPage callFunction")
struct CDPPageCallFunctionTests {
    @Test("callFunction returns value and allows discarding result without warning")
    func callFunctionDiscardableResult() async throws {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            return [#"{"id":\#(id),"result":{"result":{"type":"number","value":42}}}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        let page = CDPPage(client: client, targetID: "T1", sessionID: "S1")
        let handle = CDPPage.Handle(objectID: "obj-1")
        // Discarding the result of callFunction should compile and run cleanly
        try await page.callFunction(on: handle, "function() { return 42; }")
        let value = try await page.callFunction(on: handle, "function() { return 42; }")
        #expect(value.intValue == 42)
    }
}

