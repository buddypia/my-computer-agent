import Foundation
import MCACore
import OSLog

/// How the DevTools driver finds its browser.
public struct CDPBrowserSettings: Sendable, Equatable {
    public var host: String
    /// Probed in order when attaching. First one answering wins.
    public var ports: [Int]
    /// When no running browser exposes DevTools, start a separate Chrome with
    /// its own profile on `launchPort`. Off by default: a second browser
    /// window appearing unasked is a side effect the user should opt into.
    public var launchIfMissing: Bool
    public var launchPort: Int
    public var launchProfileDirectory: URL

    public init(
        host: String = "127.0.0.1",
        ports: [Int] = ChromeDevToolsEndpoint.defaultPorts,
        launchIfMissing: Bool = false,
        launchPort: Int = 9222,
        launchProfileDirectory: URL? = nil
    ) {
        self.host = host
        self.ports = ports
        self.launchIfMissing = launchIfMissing
        self.launchPort = launchPort
        self.launchProfileDirectory = launchProfileDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MyComputerAgent/chrome-profile", directoryHint: .isDirectory)
    }
}

/// Drives a Chromium browser through DevTools: one browser connection,
/// flattened sessions per tab, and the hybrid snapshot from `CDPPage`.
///
/// Tab policy: the driver never navigates a tab it did not open. The first
/// `navigate` opens a fresh tab and that tab becomes the agent's; the user's
/// own tabs are only touched after an explicit `switchTab`. That keeps the
/// user's logged-in session available (the reason to attach at all) without
/// hijacking what they were reading.
public actor CDPBrowserDriver: BrowserDriving {
    public nonisolated let kind: BrowserDriverKind = .devtools

    /// Decides from a page's URL and title whether the user's privacy settings
    /// exclude it. The accessibility driver is gated by the frontmost *app*; a
    /// DevTools page has no app of its own to key on, so the page is the unit.
    public typealias PageExclusion = @Sendable (_ url: String, _ title: String) -> Bool

    private let log = Logger(subsystem: "com.buddypia.mca", category: "CDPBrowserDriver")
    private let settings: CDPBrowserSettings
    private let privacyFilter = PrivacyFilter()
    private let isPageExcluded: PageExclusion

    private var endpoint: ChromeDevToolsEndpoint?
    private var browserName = ""
    private var client: CDPClient?
    private var pages: [String: CDPPage] = [:]
    private var activeTargetID: String?
    /// Tabs this process opened. Only these are navigated implicitly.
    private var ownedTargetIDs: Set<String> = []

    public init(
        settings: CDPBrowserSettings = CDPBrowserSettings(),
        isPageExcluded: @escaping PageExclusion = { _, _ in false }
    ) {
        self.settings = settings
        self.isPageExcluded = isPageExcluded
    }

    // MARK: - Connection

    /// Test seam: adopts an already-open client (and optionally an endpoint and
    /// the agent's active tab) so the exclusion paths run without a browser.
    func attachForTesting(client: CDPClient, endpoint: ChromeDevToolsEndpoint?, activeTargetID: String?) async {
        self.client = client
        self.endpoint = endpoint
        self.activeTargetID = activeTargetID
        if let activeTargetID {
            pages[activeTargetID] = CDPPage(client: client, targetID: activeTargetID, sessionID: "session-\(activeTargetID)")
        }
    }

    var activeTabID: String? { activeTargetID }

    public func connect() async throws {
        if let client, case .open = await client.state { return }
        client = nil
        pages.removeAll()

        var discovered = await ChromeDevToolsEndpoint.discover(host: settings.host, ports: settings.ports)
        if discovered == nil, settings.launchIfMissing {
            log.info("No DevTools endpoint found; launching a dedicated Chrome on port \(self.settings.launchPort)")
            try ChromeDevToolsEndpoint.launchChrome(port: settings.launchPort, userDataDirectory: settings.launchProfileDirectory)
            let endpoint = ChromeDevToolsEndpoint(host: settings.host, port: settings.launchPort)
            let version = try await endpoint.waitUntilReady()
            discovered = (endpoint, version)
        }
        guard let (endpoint, version) = discovered else {
            throw BrowserError.notConnected("""
                no Chromium browser is exposing DevTools on port(s) \(settings.ports.map(String.init).joined(separator: ", ")). \
                Start Chrome with --remote-debugging-port=\(settings.ports.first ?? 9222), \
                or enable browser.launchIfMissing in config.json to let the agent start its own profile.
                """)
        }
        self.endpoint = endpoint
        self.browserName = version.browser
        let client = try await CDPClient.connect(to: version.webSocketDebuggerURL)
        self.client = client

        // Drop pages whose targets go away so a closed tab is not reused.
        await client.on("Target.detachedFromTarget") { [weak self] params in
            guard let targetID = params["targetId"].stringValue else { return }
            Task { await self?.forget(targetID: targetID) }
        }
        await client.on("Target.targetDestroyed") { [weak self] params in
            guard let targetID = params["targetId"].stringValue else { return }
            Task { await self?.forget(targetID: targetID) }
        }
        _ = try? await client.send("Target.setDiscoverTargets", params: .object(["discover": true]))
        log.info("Attached to \(version.browser, privacy: .public) on port \(endpoint.port)")
    }

    private func forget(targetID: String) {
        pages.removeValue(forKey: targetID)
        ownedTargetIDs.remove(targetID)
        if activeTargetID == targetID { activeTargetID = nil }
    }

    public func describeConnection() async -> String {
        guard let endpoint else { return "not connected" }
        return "\(browserName) via DevTools on \(endpoint.host):\(endpoint.port)"
    }

    private func requireClient() throws -> (CDPClient, ChromeDevToolsEndpoint) {
        guard let client, let endpoint else { throw BrowserError.notConnected("call connect() first") }
        return (client, endpoint)
    }

    /// Attaches (once) to a target and returns its page.
    private func page(for targetID: String) async throws -> CDPPage {
        if let existing = pages[targetID] { return existing }
        let (client, _) = try requireClient()
        let attached = try await client.send("Target.attachToTarget", params: .object([
            "targetId": .string(targetID),
            "flatten": true,
        ]))
        guard let sessionID = attached["sessionId"].stringValue else {
            throw BrowserError.protocolError("attachToTarget returned no sessionId")
        }
        let page = CDPPage(client: client, targetID: targetID, sessionID: sessionID)
        await page.enableDomains()
        pages[targetID] = page
        return page
    }

    /// The page actions apply to. Opens a blank tab when the agent has none
    /// yet; when the agent *had* one and it is gone (closed by the user, or
    /// the browser restarted), that is reported rather than silently replaced
    /// — otherwise a stale ref lands on an empty page and the error the model
    /// sees ("unknown ref") points it the wrong way.
    private func activePage() async throws -> CDPPage {
        try await connect()
        if let activeTargetID {
            if let existing = pages[activeTargetID] { return existing }
            if let attached = try? await page(for: activeTargetID) { return attached }
            forget(targetID: activeTargetID)
            throw BrowserError.navigationFailed("the agent's browser tab was closed or is no longer reachable; use browser_navigate (or browser_tabs switch) to get a page again")
        }
        let tab = try await openTabUnchecked(url: "about:blank")
        return try await page(for: tab.id)
    }

    /// The page, once the privacy settings have agreed it may be read. Every
    /// path that hands page content to the model goes through here.
    private func readablePage() async throws -> (page: CDPPage, url: String, title: String) {
        let page = try await activePage()
        let state = try await page.state()
        guard !isPageExcluded(state.url, state.title) else { throw BrowserError.blocked("this page") }
        return (page, state.url, state.title)
    }

    // MARK: - Snapshot

    public func snapshot(options: BrowserSnapshotOptions) async throws -> BrowserSnapshot {
        let (page, url, title) = try await readablePage()
        let captured = try await page.snapshot(includeFrames: options.includeFrames)
        let outline = AccessibilityOutline.trim(captured.outline, options: options)
        return privacyFilter.redact(BrowserSnapshot(driver: .devtools, url: url, title: title, outline: outline, refs: captured.refs))
    }

    // MARK: - Actions

    public func perform(_ action: BrowserAction, ref: BrowserElementRef?, target: BrowserElementRef?) async throws -> String {
        let (page, _, _) = try await readablePage()
        func element() throws -> BrowserElementRef {
            guard let ref else { throw BrowserError.elementNotInteractable("\(action.method.rawValue) needs an element ref") }
            return ref
        }
        let label = ref.map { describe($0) } ?? "page"
        let message: String
        switch action.method {
        case .click:
            let button = action.arguments.first.flatMap { ["left", "right", "middle"].contains($0.lowercased()) ? $0.lowercased() : nil } ?? "left"
            try await page.click(try element(), button: button)
            message = "Clicked \(label)"
            await page.waitForNetworkQuiet(budget: 2)
        case .doubleClick:
            try await page.click(try element(), clickCount: 2)
            message = "Double-clicked \(label)"
        case .hover:
            try await page.hover(try element())
            message = "Hovered \(label)"
        case .fill:
            let value = action.arguments.first ?? ""
            try await page.fill(try element(), value: value)
            message = "Filled \(label) with \"\(value)\""
        case .type:
            let value = action.arguments.first ?? ""
            if let ref {
                try await page.type(ref, text: value)
            } else {
                try await page.insertText(value)
            }
            message = "Typed \"\(value)\" into \(label)"
        case .press:
            let key = action.arguments.first ?? "Enter"
            try await page.press(key)
            message = "Pressed \(key)"
            await page.waitForNetworkQuiet(budget: 2)
        case .scrollTo:
            let percent = action.arguments.first ?? "0%"
            try await page.scrollTo(try element(), percent: percent)
            message = "Scrolled \(label) to \(percent)"
        case .nextChunk:
            try await page.scrollChunk(ref, direction: 1)
            message = "Scrolled \(label) down one viewport"
        case .prevChunk:
            try await page.scrollChunk(ref, direction: -1)
            message = "Scrolled \(label) up one viewport"
        case .selectOptionFromDropdown:
            let selected = try await page.selectOption(try element(), values: action.arguments)
            message = "Selected \(selected) on \(label)"
            await page.waitForNetworkQuiet(budget: 2)
        case .dragAndDrop:
            guard let target else { throw BrowserError.elementNotInteractable("dragAndDrop needs a target ref") }
            try await page.dragAndDrop(from: try element(), to: target)
            message = "Dragged \(label) onto \(describe(target))"
        }
        return message
    }

    private func describe(_ ref: BrowserElementRef) -> String {
        var text = "[\(ref.id)] \(ref.role)"
        if let name = ref.name, !name.isEmpty { text += ": \(name.prefix(60))" }
        return text
    }

    // MARK: - Navigation

    public func navigate(to url: String, waitUntil: BrowserLoadState) async throws {
        let url = try BrowserURLPolicy.validate(url).absoluteString
        try await connect()
        // Navigate the agent's own tab; never the one the user is reading.
        if let activeTargetID, ownedTargetIDs.contains(activeTargetID), let page = try? await page(for: activeTargetID) {
            try await page.navigate(to: url, waitUntil: waitUntil)
            await page.waitForNetworkQuiet(budget: 3)
            return
        }
        let tab = try await openTabUnchecked(url: url)
        let page = try await page(for: tab.id)
        try await page.waitForLoadState(waitUntil, timeout: 15)
        await page.waitForNetworkQuiet(budget: 3)
    }

    public func goBack() async throws -> Bool {
        try await activePage().navigateHistory(delta: -1)
    }

    public func goForward() async throws -> Bool {
        try await activePage().navigateHistory(delta: 1)
    }

    public func reload() async throws {
        try await activePage().reload()
    }

    public func wait(for condition: BrowserWaitCondition, timeout: TimeInterval) async throws {
        let (page, _, _) = try await readablePage()
        switch condition {
        case .load(let state): try await page.waitForLoadState(state, timeout: timeout)
        case .selector(let selector): try await page.waitFor(selector: selector, timeout: timeout)
        case .text(let text): try await page.waitFor(text: text, timeout: timeout)
        case .milliseconds(let ms): try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        }
    }

    // MARK: - Readers

    public func currentPage() async throws -> (url: String, title: String) {
        let (_, url, title) = try await readablePage()
        return (privacyFilter.redactSensitiveText(url), privacyFilter.redactSensitiveText(title))
    }

    public func pageText() async throws -> String {
        let (page, _, _) = try await readablePage()
        return privacyFilter.redactSensitiveText(try await page.documentText())
    }

    public func screenshotPNG() async throws -> Data {
        try await readablePage().page.screenshot()
    }

    public func evaluate(_ expression: String) async throws -> String {
        let value = try await readablePage().page.evaluate(expression, awaitPromise: true)
        let text: String
        switch value {
        case .string(let string): text = string
        case .null: return "undefined"
        default: text = String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)
        }
        return privacyFilter.redactSensitiveText(text)
    }

    // MARK: - Tabs

    public func tabs() async throws -> [BrowserTab] {
        try await connect()
        let (_, endpoint) = try requireClient()
        return try await endpoint.pages().map { target in
            // An excluded tab is still listed (the model may need its id to
            // avoid it) but what it says is not.
            let hidden = isPageExcluded(target.url, target.title)
            return BrowserTab(
                id: target.id,
                url: hidden ? "[excluded]" : privacyFilter.redactSensitiveText(target.url),
                title: hidden ? "[excluded]" : privacyFilter.redactSensitiveText(target.title),
                isActive: target.id == activeTargetID)
        }
    }

    public func openTab(url: String) async throws -> BrowserTab {
        try await openTabUnchecked(url: try BrowserURLPolicy.validate(url, allowBlank: true).absoluteString)
    }

    /// `openTab` after the URL has been vetted — and for the blank tab the
    /// driver opens for itself, which no caller chose.
    private func openTabUnchecked(url: String) async throws -> BrowserTab {
        try await connect()
        let (_, endpoint) = try requireClient()
        let target = try await endpoint.newPage(url: url)
        ownedTargetIDs.insert(target.id)
        activeTargetID = target.id
        _ = try await page(for: target.id)
        return BrowserTab(id: target.id, url: target.url, title: target.title, isActive: true)
    }

    /// Takes over an existing tab. From here on `navigate` reuses it, which is
    /// what the user asked for by naming it.
    public func switchTab(id: String) async throws {
        try await connect()
        let (_, endpoint) = try requireClient()
        guard let target = try await endpoint.pages().first(where: { $0.id == id }) else {
            throw BrowserError.protocolError("no tab with id \(id)")
        }
        // Adopting a tab is how the agent starts acting on it, so an excluded
        // one is refused up front, and again on its live state (the listing
        // can be a navigation behind).
        guard !isPageExcluded(target.url, target.title) else { throw BrowserError.blocked("this page") }
        let adopted = try await page(for: id)
        let live = try await adopted.state()
        guard !isPageExcluded(live.url, live.title) else { throw BrowserError.blocked("this page") }
        activeTargetID = id
        ownedTargetIDs.insert(id)
        try? await endpoint.activate(targetID: id)
    }

    public func closeTab(id: String) async throws {
        try await connect()
        let (_, endpoint) = try requireClient()
        // Same ownership rule as `navigate`: only tabs the agent opened or
        // was explicitly switched into. Anything else may be the user's
        // half-written email or a live call — closing it is not ours to do.
        guard ownedTargetIDs.contains(id) else {
            throw BrowserError.blocked("tab \(id) is not the agent's; only tabs opened by the agent (or claimed with switch) can be closed")
        }
        // Closing the last tab closes the browser — refuse, as the CLI does.
        let all = try await endpoint.pages()
        guard all.count > 1 else { throw BrowserError.protocolError("refusing to close the last tab") }
        try await endpoint.close(targetID: id)
        forget(targetID: id)
    }
}
