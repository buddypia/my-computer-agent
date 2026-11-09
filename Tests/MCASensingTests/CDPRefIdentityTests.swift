import Foundation
import Testing
@testable import MCACore
@testable import MCASensing

/// A DOM node kept alive by a page that reuses it for other content must not be acted
/// on under the ref of what it showed in the snapshot.
@Suite("CDP ref identity")
struct CDPRefIdentityTests {
    /// A page with a button "Reply" (`0-10`) and a `<select>` "Size" (`0-11`). After the
    /// snapshot, the browser describes node 10 with `buttonNow` (nil: refuses to describe it).
    private func snapshotted(buttonNow: String?) async throws -> (CDPPage, FakeTransport, [String: BrowserElementRef]) {
        let transport = FakeTransport { message in
            let id = message["id"] as? Int ?? -1
            let params = message["params"] as? [String: Any] ?? [:]
            let result: String
            switch message["method"] as? String {
            case "DOM.getDocument":
                result = ##"{"root":{"nodeId":1,"backendNodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"backendNodeId":2,"nodeType":1,"nodeName":"HTML","children":[{"nodeId":3,"backendNodeId":3,"nodeType":1,"nodeName":"BODY","children":[{"nodeId":10,"backendNodeId":10,"nodeType":1,"nodeName":"BUTTON"},{"nodeId":11,"backendNodeId":11,"nodeType":1,"nodeName":"SELECT"}]}]}]}}"##
            case "Page.getFrameTree":
                result = #"{"frameTree":{"frame":{"id":"main"}}}"#
            case "Accessibility.getFullAXTree":
                result = #"{"nodes":[{"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":"Page"},"backendDOMNodeId":1,"childIds":["10","11"]},{"nodeId":"10","parentId":"1","role":{"value":"button"},"name":{"value":"Reply"},"backendDOMNodeId":10,"childIds":[]},{"nodeId":"11","parentId":"1","role":{"value":"combobox"},"name":{"value":"Size"},"backendDOMNodeId":11,"childIds":[]}]}"#
            case "Accessibility.getPartialAXTree":
                let backend = params["backendNodeId"] as? Int
                if backend == 11 {
                    result = #"{"nodes":[{"nodeId":"11","role":{"value":"combobox"},"name":{"value":"Size"},"backendDOMNodeId":11}]}"#
                } else if let buttonNow {
                    result = #"{"nodes":[{"nodeId":"10","role":{"value":"button"},"name":{"value":"\#(buttonNow)"},"backendDOMNodeId":10}]}"#
                } else {
                    return [#"{"id":\#(id),"error":{"code":-32000,"message":"No node with given id found"}}"#]
                }
            case "DOM.resolveNode":
                result = #"{"object":{"objectId":"obj-\#(params["backendNodeId"] as? Int ?? 0)"}}"#
            case "DOM.getBoxModel":
                result = #"{"model":{"content":[0,0,10,0,10,10,0,10]}}"#
            case "Runtime.callFunctionOn":
                result = #"{"result":{"value":["M"]}}"#
            default:
                result = "{}"
            }
            return [#"{"id":\#(id),"result":\#(result)}"#]
        }
        let client = CDPClient(transport: transport)
        await client.start()
        let page = CDPPage(client: client, targetID: "t", sessionID: "s")
        let snapshot = try await page.snapshot()
        return (page, transport, snapshot.refs)
    }

    private func act(_ action: String, on page: CDPPage, _ refs: [String: BrowserElementRef]) async throws {
        let button = try #require(refs["0-10"]), select = try #require(refs["0-11"])
        switch action {
        case "click": try await page.click(button)
        case "hover": try await page.hover(button)
        case "fill": try await page.fill(button, value: "x")
        case "type": try await page.type(button, text: "x")
        case "scrollTo": try await page.scrollTo(button, percent: "50%")
        case "nextChunk": try await page.scrollChunk(button, direction: 1)
        case "selectOption": _ = try await page.selectOption(button, values: ["M"])
        case "drag": try await page.dragAndDrop(from: select, to: button)
        default: Issue.record("unknown action \(action)")
        }
    }

    @Test("an element that now shows another name is a stale ref, and nothing reaches the page",
          arguments: ["click", "hover", "fill", "type", "scrollTo", "nextChunk", "selectOption", "drag"])
    func changedIdentityIsStale(_ action: String) async throws {
        let (page, transport, refs) = try await snapshotted(buttonNow: "Delete")
        do {
            try await act(action, on: page, refs)
            Issue.record("\(action) must not act on a node that now shows \"Delete\"")
        } catch BrowserError.staleRef(let id, let available) {
            #expect(id == "0-10" && available == 3)
        }
        let delivered = await transport.sentMethods.filter { $0.hasPrefix("Input.") || $0 == "Runtime.callFunctionOn" }
        #expect(delivered.isEmpty)
    }

    @Test("the check runs after the node is scrolled into view and before the first input event")
    func checkedAfterScrollingBeforeInput() async throws {
        let (page, transport, refs) = try await snapshotted(buttonNow: "Reply")
        try await act("click", on: page, refs)
        let methods = await transport.sentMethods
        let scrolled = try #require(methods.firstIndex(of: "DOM.scrollIntoViewIfNeeded"))
        let checked = try #require(methods.firstIndex(of: "Accessibility.getPartialAXTree"))
        let pressed = try #require(methods.firstIndex { $0.hasPrefix("Input.") })
        #expect(scrolled < checked && checked < pressed)
    }

    @Test("the recorded role is the browser's, not the outline's relabelled one")
    func relabelledRoleStillMatches() async throws {
        let (page, _, refs) = try await snapshotted(buttonNow: "Reply")
        #expect(refs["0-11"]?.role == "select")
        #expect(try await page.selectOption(try #require(refs["0-11"]), values: ["M"]) == ["M"])
    }

    @Test("a node the browser will not describe is left to the checks that follow")
    func undescribedNodeProceeds() async throws {
        let (page, transport, refs) = try await snapshotted(buttonNow: nil)
        try await act("click", on: page, refs)
        #expect(await transport.sentMethods.contains { $0.hasPrefix("Input.") })
    }
}
