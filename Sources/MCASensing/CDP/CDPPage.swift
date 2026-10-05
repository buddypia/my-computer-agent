import Foundation
import MCACore
import OSLog

/// One attached page target, driven over the DevTools protocol.
///
/// Covers what the agent actually needs: the hybrid accessibility snapshot, deterministic
/// element actions resolved by backend node id, navigation with a settle
/// wait, and a few readers. Everything goes through `send`, so a fake
/// `CDPTransport` can exercise it in tests.
public actor CDPPage {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "CDPPage")

    public let client: CDPClient
    public let targetID: String
    public let sessionID: String

    /// Frame ordinals are assigned on first sight and kept for the life of
    /// the page so an id like `1-42` means the same frame across snapshots.
    private var frameOrdinals: [String: Int] = [:]
    private var domainsEnabled = false

    public init(client: CDPClient, targetID: String, sessionID: String) {
        self.client = client
        self.targetID = targetID
        self.sessionID = sessionID
    }

    // MARK: - Session plumbing

    @discardableResult
    public func send(_ method: String, _ params: JSONValue = .object([:]), timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await client.send(method, params: params, sessionID: sessionID, timeout: timeout)
    }

    /// Best-effort domain enabling. Each is independent; a browser that
    /// rejects one (a `chrome://` page has no Accessibility domain) still
    /// serves the rest.
    public func enableDomains() async {
        guard !domainsEnabled else { return }
        for domain in ["Page.enable", "DOM.enable", "Runtime.enable", "Accessibility.enable", "Network.enable"] {
            _ = try? await send(domain)
        }
        domainsEnabled = true
    }

    // MARK: - Page state

    public struct PageState: Sendable, Equatable {
        public var url: String
        public var title: String
        public var readyState: String
    }

    public func state() async throws -> PageState {
        let result = try await evaluate(PageScripts.pageState)
        return PageState(
            url: result["url"].stringValue ?? "",
            title: result["title"].stringValue ?? "",
            readyState: result["readyState"].stringValue ?? "")
    }

    /// Evaluates an expression in the main world and returns its JSON value.
    public func evaluate(_ expression: String, awaitPromise: Bool = false) async throws -> JSONValue {
        let result = try await send("Runtime.evaluate", .object([
            "expression": .string(expression),
            "returnByValue": true,
            "awaitPromise": .bool(awaitPromise),
        ]))
        if case .object(let details) = result["exceptionDetails"] {
            let text = details["exception"]?["description"].stringValue ?? details["text"]?.stringValue ?? "evaluation failed"
            throw BrowserError.protocolError(text)
        }
        return result["result"]["value"]
    }

    public func documentText() async throws -> String {
        try await evaluate(PageScripts.documentText).stringValue ?? ""
    }

    /// PNG of the viewport.
    public func screenshot() async throws -> Data {
        let result = try await send("Page.captureScreenshot", .object(["format": "png"]), timeout: 15)
        guard let base64 = result["data"].stringValue, let data = Data(base64Encoded: base64) else {
            throw BrowserError.protocolError("captureScreenshot returned no image data")
        }
        return data
    }

    // MARK: - Navigation

    public func navigate(to url: String, waitUntil: BrowserLoadState = .domcontentloaded, timeout: TimeInterval = 15) async throws {
        await enableDomains()
        try await awaitingNavigation(timeout: timeout) {
            let result = try await send("Page.navigate", .object(["url": .string(url)]))
            if let errorText = result["errorText"].stringValue, !errorText.isEmpty {
                throw BrowserError.navigationFailed("\(errorText) (\(url))")
            }
        }
        try await waitForLoadState(waitUntil, timeout: timeout)
    }

    public func reload(waitUntil: BrowserLoadState = .domcontentloaded, timeout: TimeInterval = 15) async throws {
        await enableDomains()
        try await awaitingNavigation(timeout: timeout) { try await send("Page.reload") }
        try await waitForLoadState(waitUntil, timeout: timeout)
    }

    /// Moves through session history. Returns false when there is nowhere to go.
    public func navigateHistory(delta: Int, timeout: TimeInterval = 15) async throws -> Bool {
        await enableDomains()
        let history = try await send("Page.getNavigationHistory")
        guard let current = history["currentIndex"].intValue, let entries = history["entries"].arrayValue else { return false }
        let target = current + delta
        guard entries.indices.contains(target), let entryID = entries[target]["id"].intValue else { return false }
        try await awaitingNavigation(timeout: timeout) {
            try await send("Page.navigateToHistoryEntry", .object(["entryId": .number(Double(entryID))]))
        }
        try await waitForLoadState(.domcontentloaded, timeout: timeout)
        return true
    }

    /// Runs `trigger` and then waits until the main frame has actually
    /// navigated (`Page.frameNavigated` or, for same-document moves,
    /// `Page.navigatedWithinDocument`). Without this, a readyState poll right
    /// after `Page.navigate` sees the *old* document already "complete" and
    /// returns before the new page exists. The listener is installed before
    /// the trigger because the event can arrive ahead of the command's reply.
    private func awaitingNavigation(timeout: TimeInterval, _ trigger: () async throws -> Void) async throws {
        let box = ContinuationBox()
        let sessionID = self.sessionID
        let tokens = await [
            client.on("Page.frameNavigated", sessionID: sessionID) { params in
                guard params["frame"]["parentId"].stringValue == nil else { return }
                box.resume(with: .success(params))
            },
            client.on("Page.navigatedWithinDocument", sessionID: sessionID) { params in
                box.resume(with: .success(params))
            },
        ]
        defer { Task { for token in tokens { await client.off(token) } } }

        try await trigger()

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.resume(with: .failure(BrowserError.timeout("navigation did not commit within \(Int(timeout))s")))
        }
        defer { timeoutTask.cancel() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            box.store(continuation)
        }
    }

    /// Polls `document.readyState` until it reaches `state`; `networkidle`
    /// additionally waits for the Network domain to go quiet.
    public func waitForLoadState(_ state: BrowserLoadState, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let wanted: Set<String> = state == .domcontentloaded ? ["interactive", "complete"] : ["complete"]
        while Date() < deadline {
            if let ready = try? await evaluate("document.readyState").stringValue, wanted.contains(ready) {
                if state == .networkidle {
                    await waitForNetworkQuiet(budget: max(0.5, deadline.timeIntervalSinceNow))
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BrowserError.timeout("page load (\(state.rawValue))")
    }

    /// DOM-settle rule: resolve once no request has been in
    /// flight for 500 ms, ignoring WebSocket/EventSource streams, treating a
    /// request older than two seconds as stalled, and giving up at `budget`.
    public func waitForNetworkQuiet(budget: TimeInterval = 5) async {
        await enableDomains()
        let tracker = InflightTracker()
        let tokens = await [
            client.on("Network.requestWillBeSent", sessionID: sessionID) { params in
                let type = params["type"].stringValue ?? ""
                guard type != "WebSocket", type != "EventSource", let id = params["requestId"].stringValue else { return }
                tracker.start(id)
            },
            client.on("Network.loadingFinished", sessionID: sessionID) { params in
                if let id = params["requestId"].stringValue { tracker.finish(id) }
            },
            client.on("Network.loadingFailed", sessionID: sessionID) { params in
                if let id = params["requestId"].stringValue { tracker.finish(id) }
            },
            client.on("Network.requestServedFromCache", sessionID: sessionID) { params in
                if let id = params["requestId"].stringValue { tracker.finish(id) }
            },
        ]
        defer { Task { for token in tokens { await client.off(token) } } }

        let deadline = Date().addingTimeInterval(budget)
        var quietSince: Date? = Date()
        while Date() < deadline {
            tracker.sweepStalled(olderThan: 2)
            if tracker.count == 0 {
                if quietSince == nil { quietSince = Date() }
                if Date().timeIntervalSince(quietSince!) >= 0.5 { return }
            } else {
                quietSince = nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log.debug("DOM settle timeout reached with \(tracker.count) requests pending")
    }

    // MARK: - Snapshot

    public struct Snapshot: Sendable, Equatable {
        public var outline: String
        public var refs: [String: BrowserElementRef]
    }

    /// Captures the hybrid accessibility + DOM snapshot.
    ///
    /// Flow (same-process frames only):
    /// 1. `DOM.getDocument(pierce)` once, indexed by backend node id: absolute
    ///    XPath, tag name, scrollability, owning document, iframe → content doc.
    /// 2. Walk `Page.getFrameTree`; for each frame, fetch its AX tree and
    ///    build an outline whose ids are `ordinal-backendNodeId`.
    /// 3. Nest each child outline under its host iframe's line and prefix its
    ///    XPaths with the iframe's absolute path.
    public func snapshot(includeFrames: Bool = true) async throws -> Snapshot {
        await enableDomains()
        let dom = try await buildDOMIndex()
        let frameTree = try await send("Page.getFrameTree")
        let mainFrameID = frameTree["frameTree"]["frame"]["id"].stringValue ?? "main"
        var frames: [(id: String, parent: String?)] = []
        func walk(_ node: JSONValue, parent: String?) {
            guard let id = node["frame"]["id"].stringValue else { return }
            frames.append((id, parent))
            for child in node["childFrames"].arrayValue ?? [] { walk(child, parent: id) }
        }
        walk(frameTree["frameTree"], parent: nil)
        if !includeFrames { frames = frames.filter { $0.id == mainFrameID } }

        var outlines: [String: String] = [:]
        var subtrees: [String: String] = [:]
        var refs: [String: BrowserElementRef] = [:]
        var absolutePrefix: [String: String] = [mainFrameID: ""]

        for frame in frames {
            let frameOrdinal = ordinal(for: frame.id, isMain: frame.id == mainFrameID)

            // Which document does this frame own inside the shared DOM index?
            var docRoot = dom.rootBackendID
            var hostEncodedID: String?
            if let parent = frame.parent {
                guard let owner = try? await send("DOM.getFrameOwner", .object(["frameId": .string(frame.id)])),
                      let ownerBackend = owner["backendNodeId"].intValue
                else { continue } // out-of-process frame: not reachable from this session
                guard let contentRoot = dom.contentDocumentRoot[ownerBackend] else { continue }
                docRoot = contentRoot
                let parentOrdinal = ordinal(for: parent, isMain: parent == mainFrameID)
                hostEncodedID = "\(parentOrdinal)-\(ownerBackend)"
                let parentPrefix = absolutePrefix[parent] ?? ""
                let ownerPath = dom.absoluteXPath[ownerBackend] ?? ""
                absolutePrefix[frame.id] = XPath.prefix(parentPrefix.isEmpty ? "/" : parentPrefix, with: ownerPath)
            }

            let axNodes: [JSONValue]
            do {
                let params: JSONValue = frame.id == mainFrameID ? .object([:]) : .object(["frameId": .string(frame.id)])
                axNodes = try await send("Accessibility.getFullAXTree", params, timeout: 20)["nodes"].arrayValue ?? []
            } catch {
                if frame.id == mainFrameID { throw error }
                continue
            }

            let baseAbsolute = dom.absoluteXPath[docRoot] ?? "/"
            var outlineNodes: [OutlineNode] = []
            var urlByEncoded: [String: String] = [:]
            outlineNodes.reserveCapacity(axNodes.count)
            for ax in axNodes {
                guard let nodeID = ax["nodeId"].stringValue else { continue }
                let backend = ax["backendDOMNodeId"].intValue
                // Skip nodes that belong to another document in the same session.
                if let backend, let owningDoc = dom.documentRoot[backend], owningDoc != docRoot { continue }
                let encoded = backend.map { "\(frameOrdinal)-\($0)" }
                let properties = ax["properties"].arrayValue ?? []
                func property(_ name: String) -> JSONValue? {
                    properties.first { $0["name"].stringValue == name }?["value"]["value"]
                }
                if let encoded, let url = property("url")?.stringValue?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
                    urlByEncoded[encoded] = url
                }
                outlineNodes.append(OutlineNode(
                    nodeID: nodeID,
                    parentID: ax["parentId"].stringValue,
                    childIDs: (ax["childIds"].arrayValue ?? []).compactMap(\.stringValue),
                    role: ax["role"]["value"].stringValue ?? "",
                    name: ax["name"]["value"].stringValue,
                    description: ax["description"]["value"].stringValue,
                    value: ax["value"]["value"].stringValue,
                    selected: property("selected")?.boolValue,
                    checked: property("checked")?.boolValue,
                    encodedID: encoded,
                    tagName: backend.flatMap { dom.tagName[$0] },
                    isScrollable: backend.map { dom.scrollable.contains($0) } ?? false))
            }

            let tree = AccessibilityOutline.buildTree(outlineNodes)
            let outline = AccessibilityOutline.render(tree)
            outlines[frame.id] = outline
            if let hostEncodedID { subtrees[hostEncodedID] = outline }

            let prefix = absolutePrefix[frame.id] ?? ""
            for node in flatten(tree) {
                guard let encoded = node.encodedID, let backend = Int(encoded.split(separator: "-").last ?? "") else { continue }
                var xpath: String?
                if let absolute = dom.absoluteXPath[backend] {
                    let relative = XPath.relativize(base: baseAbsolute, absolute: absolute)
                    xpath = prefix.isEmpty ? relative : XPath.prefix(prefix, with: relative)
                }
                refs[encoded] = BrowserElementRef(
                    id: encoded, role: node.role, name: node.name, frameOrdinal: frameOrdinal,
                    backendNodeID: backend, xpath: xpath, url: urlByEncoded[encoded])
            }
        }

        let root = outlines[mainFrameID] ?? ""
        let combined = AccessibilityOutline.injectSubtrees(root, subtrees: subtrees)
        return Snapshot(outline: combined, refs: refs)
    }

    private func ordinal(for frameID: String, isMain: Bool) -> Int {
        if isMain { return 0 }
        if let existing = frameOrdinals[frameID] { return existing }
        let next = (frameOrdinals.values.max() ?? 0) + 1
        frameOrdinals[frameID] = next
        return next
    }

    private func flatten(_ roots: [OutlineTreeNode]) -> [OutlineTreeNode] {
        var out: [OutlineTreeNode] = []
        func walk(_ node: OutlineTreeNode) {
            out.append(node)
            node.children.forEach(walk)
        }
        roots.forEach(walk)
        return out
    }

    // MARK: DOM index

    struct DOMIndex {
        var rootBackendID: Int
        var absoluteXPath: [Int: String] = [:]
        var tagName: [Int: String] = [:]
        var scrollable: Set<Int> = []
        /// backend id → backend id of the document that contains it.
        var documentRoot: [Int: Int] = [:]
        /// iframe backend id → its content document's backend id.
        var contentDocumentRoot: [Int: Int] = [:]
    }

    /// `DOM.getDocument` once, then a DFS building the maps. Deep trees can
    /// overflow DevTools' encoder ("CBOR: stack limit exceeded"), so the
    /// depth is reduced on that specific failure.
    func buildDOMIndex() async throws -> DOMIndex {
        var root: JSONValue?
        var lastError: Error?
        for depth in [-1, 64, 16] {
            do {
                root = try await send("DOM.getDocument", .object(["depth": .number(Double(depth)), "pierce": true]), timeout: 30)["root"]
                break
            } catch let error as CDPError where error.message.contains("stack limit") {
                lastError = error
                continue
            }
        }
        guard let root else { throw lastError ?? BrowserError.protocolError("DOM.getDocument failed") }
        guard let rootBackend = root["backendNodeId"].intValue else {
            throw BrowserError.protocolError("DOM.getDocument returned no backendNodeId")
        }

        var index = DOMIndex(rootBackendID: rootBackend)
        struct Entry { let node: JSONValue; let xpath: String; let docRoot: Int }
        var stack = [Entry(node: root, xpath: "/", docRoot: rootBackend)]
        while let entry = stack.popLast() {
            let node = entry.node
            if let backend = node["backendNodeId"].intValue {
                index.absoluteXPath[backend] = entry.xpath.isEmpty ? "/" : entry.xpath
                index.tagName[backend] = Self.enrichedTagName(node)
                if node["isScrollable"].boolValue == true { index.scrollable.insert(backend) }
                index.documentRoot[backend] = entry.docRoot
            }
            let children = node["children"].arrayValue ?? []
            if !children.isEmpty {
                let segments = XPath.childSegments(children)
                for (child, segment) in zip(children, segments).reversed() {
                    stack.append(Entry(node: child, xpath: XPath.join(entry.xpath, segment), docRoot: entry.docRoot))
                }
            }
            for shadow in node["shadowRoots"].arrayValue ?? [] {
                stack.append(Entry(node: shadow, xpath: XPath.join(entry.xpath, "//"), docRoot: entry.docRoot))
            }
            let content = node["contentDocument"]
            if let contentBackend = content["backendNodeId"].intValue, let backend = node["backendNodeId"].intValue {
                index.contentDocumentRoot[backend] = contentBackend
                stack.append(Entry(node: content, xpath: entry.xpath, docRoot: contentBackend))
            }
        }
        return index
    }

    static func enrichedTagName(_ node: JSONValue) -> String {
        let tag = (node["nodeName"].stringValue ?? "").lowercased()
        guard tag == "input", let attributes = node["attributes"].arrayValue else { return tag }
        var iterator = attributes.makeIterator()
        while let name = iterator.next()?.stringValue, let value = iterator.next()?.stringValue {
            if name == "type" { return "input, \(value.lowercased())" }
        }
        return tag
    }

    // MARK: - Element resolution

    /// A live handle. Always released by the action that took it.
    struct Handle {
        let objectID: String
    }

    func resolve(_ ref: BrowserElementRef) async throws -> Handle {
        guard let backend = ref.backendNodeID else {
            throw BrowserError.elementNotInteractable("ref \(ref.id) has no DOM node")
        }
        do {
            let result = try await send("DOM.resolveNode", .object(["backendNodeId": .number(Double(backend))]))
            guard let objectID = result["object"]["objectId"].stringValue else {
                throw BrowserError.elementNotInteractable("ref \(ref.id) no longer exists on the page")
            }
            return Handle(objectID: objectID)
        } catch let error as CDPError {
            throw BrowserError.elementNotInteractable("ref \(ref.id) could not be resolved (\(error.message)) — the page may have changed; take a new snapshot")
        }
    }

    func release(_ handle: Handle) async {
        _ = try? await send("Runtime.releaseObject", .object(["objectId": .string(handle.objectID)]))
    }

    func callFunction(on handle: Handle, _ declaration: String, arguments: [JSONValue] = [], awaitPromise: Bool = false) async throws -> JSONValue {
        let result = try await send("Runtime.callFunctionOn", .object([
            "objectId": .string(handle.objectID),
            "functionDeclaration": .string(declaration),
            "arguments": .array(arguments.map { .object(["value": $0]) }),
            "returnByValue": true,
            "awaitPromise": .bool(awaitPromise),
        ]))
        if case .object(let details) = result["exceptionDetails"] {
            let text = details["exception"]?["description"].stringValue ?? details["text"]?.stringValue ?? "script threw"
            throw BrowserError.protocolError(text)
        }
        return result["result"]["value"]
    }

    /// Scrolls the element into view and returns the centre of its content
    /// box in viewport CSS pixels.
    func centroid(of handle: Handle) async throws -> CGPoint {
        _ = try? await send("DOM.scrollIntoViewIfNeeded", .object(["objectId": .string(handle.objectID)]))
        let box = try await send("DOM.getBoxModel", .object(["objectId": .string(handle.objectID)]))
        guard let quad = box["model"]["content"].arrayValue?.compactMap(\.doubleValue), quad.count >= 8 else {
            throw BrowserError.elementNotInteractable("element has no box model (hidden or detached)")
        }
        let cx = (quad[0] + quad[2] + quad[4] + quad[6]) / 4
        let cy = (quad[1] + quad[3] + quad[5] + quad[7]) / 4
        return CGPoint(x: cx.rounded(), y: cy.rounded())
    }

    // MARK: - Actions

    public func click(_ ref: BrowserElementRef, button: String = "left", clickCount: Int = 1) async throws {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        let point = try await centroid(of: handle)
        try await dispatchClick(at: point, button: button, clickCount: clickCount)
    }

    public func dispatchClick(at point: CGPoint, button: String = "left", clickCount: Int = 1) async throws {
        let x = JSONValue.number(point.x), y = JSONValue.number(point.y)
        try await send("Input.dispatchMouseEvent", .object(["type": "mouseMoved", "x": x, "y": y, "button": "none"]))
        for count in 1...max(1, clickCount) {
            let n = JSONValue.number(Double(count))
            try await send("Input.dispatchMouseEvent", .object(["type": "mousePressed", "x": x, "y": y, "button": .string(button), "clickCount": n]))
            try await send("Input.dispatchMouseEvent", .object(["type": "mouseReleased", "x": x, "y": y, "button": .string(button), "clickCount": n]))
        }
    }

    public func hover(_ ref: BrowserElementRef) async throws {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        let point = try await centroid(of: handle)
        try await send("Input.dispatchMouseEvent", .object(["type": "mouseMoved", "x": .number(point.x), "y": .number(point.y), "button": "none"]))
    }

    /// Playwright-style fill: native setter for value-typed inputs, otherwise
    /// focus + select-all + `Input.insertText` so frameworks see real input.
    public func fill(_ ref: BrowserElementRef, value: String) async throws {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        let result = try await callFunction(on: handle, PageScripts.fillElementValue, arguments: [.string(value)])
        switch result["status"].stringValue {
        case "done":
            return
        case "needsinput":
            let text = result["value"].stringValue ?? value
            let prepared = (try? await callFunction(on: handle, PageScripts.prepareElementForTyping).boolValue) ?? false
            if !prepared {
                try await callFunction(on: handle, PageScripts.focusElement)
            }
            if text.isEmpty {
                for event in [CDPKeyMap.keyDown("Backspace", held: []), CDPKeyMap.keyUp("Backspace", held: [])] {
                    try await send("Input.dispatchKeyEvent", .object(event.params))
                }
            } else {
                try await send("Input.insertText", .object(["text": .string(text)]))
            }
        case "error":
            throw BrowserError.elementNotInteractable("fill failed: \(result["reason"].stringValue ?? "unknown")")
        default:
            try await type(ref, text: value)
        }
    }

    /// Focuses the element and inserts text without clearing it.
    public func type(_ ref: BrowserElementRef, text: String) async throws {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        try await callFunction(on: handle, PageScripts.focusElement)
        try await send("Input.insertText", .object(["text": .string(text)]))
    }

    /// Inserts text into whatever is focused.
    public func insertText(_ text: String) async throws {
        try await send("Input.insertText", .object(["text": .string(text)]))
    }

    /// Presses a key or chord such as `Enter`, `Cmd+A`, `Shift+Tab`.
    public func press(_ chord: String) async throws {
        for event in CDPKeyMap.events(forChord: chord) {
            try await send("Input.dispatchKeyEvent", .object(event.params))
        }
    }

    public func scrollTo(_ ref: BrowserElementRef, percent: String) async throws {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        try await callFunction(on: handle, PageScripts.scrollElementToPercent, arguments: [.string(percent)])
    }

    /// Scrolls the element (or the document when nil) by one viewport.
    public func scrollChunk(_ ref: BrowserElementRef?, direction: Int) async throws {
        let handle: Handle
        if let ref {
            handle = try await resolve(ref)
        } else {
            let doc = try await send("DOM.getDocument", .object(["depth": 1]))
            guard let rootID = doc["root"]["backendNodeId"].intValue else { throw BrowserError.protocolError("no document") }
            let html = try await send("DOM.querySelector", .object(["nodeId": doc["root"]["nodeId"], "selector": "html"]))
            let target = html["nodeId"].intValue.map { JSONValue.object(["nodeId": .number(Double($0))]) }
                ?? .object(["backendNodeId": .number(Double(rootID))])
            let resolved = try await send("DOM.resolveNode", target)
            guard let objectID = resolved["object"]["objectId"].stringValue else { throw BrowserError.protocolError("cannot resolve <html>") }
            handle = Handle(objectID: objectID)
        }
        defer { Task { await self.release(handle) } }
        try await callFunction(on: handle, PageScripts.scrollByChunk, arguments: [.number(Double(direction))], awaitPromise: true)
    }

    public func selectOption(_ ref: BrowserElementRef, values: [String]) async throws -> [String] {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        let result = try await callFunction(on: handle, PageScripts.selectElementOptions, arguments: [.array(values.map(JSONValue.string))])
        let selected = (result.arrayValue ?? []).compactMap(\.stringValue)
        guard !selected.isEmpty else {
            throw BrowserError.elementNotInteractable("no option matched \(values) on ref \(ref.id) (is it a <select>?)")
        }
        return selected
    }

    public func dragAndDrop(from source: BrowserElementRef, to target: BrowserElementRef, steps: Int = 10) async throws {
        let sourceHandle = try await resolve(source)
        let targetHandle = try await resolve(target)
        defer { Task { await self.release(sourceHandle); await self.release(targetHandle) } }
        let start = try await centroid(of: sourceHandle)
        let end = try await centroid(of: targetHandle)
        try await send("Input.dispatchMouseEvent", .object(["type": "mouseMoved", "x": .number(start.x), "y": .number(start.y), "button": "none"]))
        try await send("Input.dispatchMouseEvent", .object(["type": "mousePressed", "x": .number(start.x), "y": .number(start.y), "button": "left", "buttons": 1, "clickCount": 1]))
        for step in 1...max(1, steps) {
            let t = Double(step) / Double(max(1, steps))
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            try await send("Input.dispatchMouseEvent", .object(["type": "mouseMoved", "x": .number(x), "y": .number(y), "button": "left", "buttons": 1]))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try await send("Input.dispatchMouseEvent", .object(["type": "mouseReleased", "x": .number(end.x), "y": .number(end.y), "button": "left", "buttons": 1, "clickCount": 1]))
    }

    public func isVisible(_ ref: BrowserElementRef) async throws -> Bool {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        return try await callFunction(on: handle, PageScripts.isElementVisible).boolValue ?? false
    }

    public func innerText(_ ref: BrowserElementRef) async throws -> String {
        let handle = try await resolve(ref)
        defer { Task { await self.release(handle) } }
        return try await callFunction(on: handle, PageScripts.readInnerText).stringValue ?? ""
    }

    /// Waits until a CSS selector matches (and is visible) or `text` appears
    /// in the document.
    public func waitFor(selector: String? = nil, text: String? = nil, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let selector {
                let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let expression = """
                    (() => { const el = document.querySelector("\(escaped)"); if (!el) return false;
                      const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; })()
                    """
                if (try? await evaluate(expression).boolValue) == true { return }
            } else if let text {
                let body = (try? await documentText()) ?? ""
                if body.localizedCaseInsensitiveContains(text) { return }
            } else {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BrowserError.timeout(selector.map { "selector \($0)" } ?? text.map { "text \"\($0)\"" } ?? "condition")
    }
}

/// Counts in-flight network requests for the settle wait. Class so the event
/// closures can mutate it from the client actor.
final class InflightTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String: Date] = [:]

    func start(_ id: String) { lock.lock(); started[id] = Date(); lock.unlock() }
    func finish(_ id: String) { lock.lock(); started.removeValue(forKey: id); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return started.count }
    func sweepStalled(olderThan seconds: TimeInterval) {
        lock.lock()
        let now = Date()
        started = started.filter { now.timeIntervalSince($0.value) <= seconds }
        lock.unlock()
    }
}

/// XPath fragments the DOM index produces.
public enum XPath {
    /// Per-sibling steps: `div[2]`, `text()[1]`, `*[name()='svg:path'][1]`.
    public static func childSegments(_ children: [JSONValue]) -> [String] {
        var counters: [String: Int] = [:]
        return children.map { child in
            let tag = (child["nodeName"].stringValue ?? "").lowercased()
            let type = child["nodeType"].intValue ?? 1
            let key = "\(type):\(tag)"
            let index = (counters[key] ?? 0) + 1
            counters[key] = index
            switch type {
            case 3: return "text()[\(index)]"
            case 8: return "comment()[\(index)]"
            default: return tag.contains(":") ? "*[name()='\(tag)'][\(index)]" : "\(tag)[\(index)]"
            }
        }
    }

    public static func join(_ base: String, _ step: String) -> String {
        if step == "//" {
            if base.isEmpty || base == "/" { return "//" }
            return base.hasSuffix("/") ? "\(base)/" : "\(base)//"
        }
        if base.isEmpty || base == "/" { return step.isEmpty ? "/" : "/\(step)" }
        if base.hasSuffix("//") { return "\(base)\(step)" }
        if step.isEmpty { return base }
        return "\(base)/\(step)"
    }

    public static func normalize(_ xpath: String) -> String {
        var s = xpath.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("xpath=") { s = String(s.dropFirst(6)) }
        if !s.hasPrefix("/") { s = "/" + s }
        if s.count > 1, s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Prefixes a frame-relative path with the absolute path of its iframe.
    public static func prefix(_ parentAbsolute: String, with child: String) -> String {
        let p = parentAbsolute == "/" ? "" : (parentAbsolute.hasSuffix("/") ? String(parentAbsolute.dropLast()) : parentAbsolute)
        if child.isEmpty || child == "/" { return p.isEmpty ? "/" : p }
        if child.hasPrefix("//") { return p.isEmpty ? "//\(child.dropFirst(2))" : "\(p)//\(child.dropFirst(2))" }
        let c = child.hasPrefix("/") ? String(child.dropFirst()) : child
        return p.isEmpty ? "/\(c)" : "\(p)/\(c)"
    }

    public static func relativize(base: String, absolute: String) -> String {
        let b = normalize(base), a = normalize(absolute)
        if a == b { return "/" }
        if a.hasPrefix(b) {
            let tail = String(a.dropFirst(b.count))
            if tail.isEmpty { return "/" }
            return tail.hasPrefix("/") ? tail : "/\(tail)"
        }
        return a
    }
}
