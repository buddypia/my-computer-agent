import AppKit
import ApplicationServices
import Foundation
import MCACore
import OSLog

/// Browser driver over macOS Accessibility: any browser, no DevTools flag,
/// reduced fidelity. It produces the same `[ref] role: name` outline as the
/// DevTools driver by walking the `AXWebArea` subtree of the browser's
/// focused window, so the model's workflow does not change when this is the
/// driver underneath — only the set of actions that can be performed
/// precisely (no JavaScript, no dropdown option selection, approximate
/// scrolling).
public actor AXBrowserDriver: BrowserDriving {
    public nonisolated let kind: BrowserDriverKind = .accessibility

    /// Bundle ids recognised as browsers, in preference order when several run.
    public static let browserBundleIDs: [String] = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.apple.Safari",
        "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
    ]

    private let log = Logger(subsystem: "com.buddypia.mca", category: "AXBrowserDriver")
    private let synthesizer = EventSynthesizer()
    private let privacyFilter = PrivacyFilter()
    private let maxElements: Int
    private let maxDepth: Int

    private var app: NSRunningApplication?
    private var scopedWindowID: UInt32?
    /// Elements behind the refs of the latest snapshot.
    private var elements: [String: AXUIElement] = [:]
    /// Bounds for elements, including OCR fallback elements.
    private var elementBounds: [String: CGRect] = [:]

    /// Provider for fallback visual snapshot (e.g. via OCR) when AX tree has no nodes.
    public typealias OCRSnapshotProvider = @Sendable (_ pid: pid_t, _ options: BrowserSnapshotOptions) async throws -> BrowserSnapshot?
    /// Provider for fallback page text (e.g. via OCR) when AX tree yields little or no text.
    public typealias OCRTextProvider = @Sendable (_ pid: pid_t) async throws -> String?

    private let ocrSnapshotProvider: OCRSnapshotProvider?
    private let ocrTextProvider: OCRTextProvider?
    /// The user's window exclusion list, applied to the screenshot this driver takes.
    private let isWindowExcluded: ScreenCapturer.WindowExclusion?

    public init(
        maxElements: Int = 4000,
        maxDepth: Int = 60,
        ocrSnapshotProvider: OCRSnapshotProvider? = nil,
        ocrTextProvider: OCRTextProvider? = nil,
        isWindowExcluded: ScreenCapturer.WindowExclusion? = nil
    ) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.ocrSnapshotProvider = ocrSnapshotProvider
        self.ocrTextProvider = ocrTextProvider
        self.isWindowExcluded = isWindowExcluded
    }

    // MARK: - Connection

    public func scope(to window: PinnedWindow) async throws {
        guard AXIsProcessTrusted(), let pid = window.processID,
              let selected = NSRunningApplication(processIdentifier: pid),
              selected.bundleIdentifier == window.bundleID,
              Self.browserBundleIDs.contains(selected.bundleIdentifier ?? "") else {
            throw BrowserError.notConnected("the selected browser process is unavailable or inaccessible")
        }
        guard !privacyFilter.isApplicationBlocked(bundleID: selected.bundleIdentifier) else {
            throw BrowserError.blocked(window.appName)
        }
        app = selected
        scopedWindowID = window.id
        _ = try focusedWindow()
    }

    public func connect() async throws {
        guard AXIsProcessTrusted() else {
            throw BrowserError.notConnected("Accessibility permission is not granted to this app (System Settings › Privacy & Security › Accessibility)")
        }
        if let app, !app.isTerminated { return }
        let running = NSWorkspace.shared.runningApplications
        let front = NSWorkspace.shared.frontmostApplication
        if let front, let id = front.bundleIdentifier, Self.browserBundleIDs.contains(id) {
            app = front
        } else {
            app = Self.browserBundleIDs.lazy
                .compactMap { id in running.first { $0.bundleIdentifier == id } }
                .first
        }
        guard let app else {
            throw BrowserError.notConnected("no supported browser is running (Chrome, Edge, Brave, Arc, Safari, Firefox)")
        }
        if privacyFilter.isApplicationBlocked(bundleID: app.bundleIdentifier) {
            throw BrowserError.blocked(app.localizedName ?? "browser")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXAttributes.enableEnhancedAccessibility(app: axApp)
        log.info("Using \(app.localizedName ?? "browser", privacy: .public) via Accessibility")
    }

    public func describeConnection() async -> String {
        guard let app else { return "not connected" }
        return "\(app.localizedName ?? "browser") via macOS Accessibility (reduced fidelity; start Chrome with --remote-debugging-port for full control)"
    }

    /// Refuses a window or page the user's exclusion list covers. The window
    /// title and the page URL are both matched, as `CDPBrowserDriver` does.
    nonisolated func checkReadable(bundleID: String?, title: String, url: String) throws {
        guard let isWindowExcluded else { return }
        if isWindowExcluded(bundleID, title) || (!url.isEmpty && isWindowExcluded(bundleID, url)) {
            throw BrowserError.blocked("this window")
        }
    }

    /// Every path that hands the focused window's content to the model goes
    /// through here, so the exclusion list covers more than screenshots.
    private func requireReadable() throws {
        let app = try requireApp()
        let page = (try? readCurrentPage()) ?? (url: "", title: "")
        try checkReadable(bundleID: app.bundleIdentifier, title: page.title, url: page.url)
    }

    private func requireApp() throws -> NSRunningApplication {
        guard let app, !app.isTerminated else { throw BrowserError.notConnected("browser is no longer running") }
        return app
    }

    private func focusedWindow() throws -> AXUIElement {
        let app = try requireApp()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXAttributes.enableEnhancedAccessibility(app: axApp)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.elements(axApp, kAXWindowsAttribute)?.first else {
            throw BrowserError.notConnected("the browser has no window")
        }
        AXAttributes.enableEnhancedAccessibility(app: axApp, window: window)
        if let scopedWindowID {
            guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw BrowserError.notConnected("selected browser window metadata is unavailable")
            }
            let owned = entries.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
            guard let entry = owned.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == scopedWindowID }),
                  let expectedBounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: expectedBounds as CFDictionary),
                  let title = entry[kCGWindowName as String] as? String else {
                throw BrowserError.notConnected("selected browser window identity is unavailable")
            }
            let identities = owned.map { item -> (title: String?, bounds: CGRect?) in
                let bounds = (item[kCGWindowBounds as String] as? [String: Any])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                return (item[kCGWindowName as String] as? String ?? title, bounds)
            }
            let axWindows = AX.elements(axApp, kAXWindowsAttribute) ?? []
            let axIdentities = axWindows.map { (title: AX.string($0, kAXTitleAttribute), bounds: AX.frame($0)) }
            guard let cgIndex = AccessibilityInspector.uniqueWindowIndex(identities, title: title, bounds: frame),
                  (owned[cgIndex][kCGWindowNumber as String] as? NSNumber)?.uint32Value == scopedWindowID,
                  let axIndex = AccessibilityInspector.uniqueWindowIndex(axIdentities, title: title, bounds: frame),
                  CFEqual(axWindows[axIndex], window) else {
                throw BrowserError.notConnected("the focused browser window is not uniquely the selected window")
            }
        }
        return window
    }

    private func webArea() throws -> AXUIElement {
        let window = try focusedWindow()
        guard let area = AX.findWebArea(in: window) else {
            throw BrowserError.notConnected("no web content in the focused browser window")
        }
        return area
    }

    // MARK: - Snapshot

    public func snapshot(options: BrowserSnapshotOptions) async throws -> BrowserSnapshot {
        try await connect()
        if scopedWindowID != nil { _ = try focusedWindow() }
        let app = try requireApp()
        try requireReadable()
        let page = try readCurrentPage()
        guard !PrivacyFilter.isWindowExcluded(bundleID: app.bundleIdentifier, windowTitle: page.title) else {
            throw BrowserError.notConnected("Current browser window is excluded from inspection")
        }

        // 1. Try Accessibility tree walk first
        if let area = try? webArea() {
            var nodes: [OutlineNode] = []
            var byID: [String: AXUIElement] = [:]
            var urls: [String: String] = [:]
            var bounds: [String: CGRect] = [:]
            var counter = 0
            walk(area, parentID: nil, depth: 0, counter: &counter, nodes: &nodes, elements: &byID, urls: &urls, bounds: &bounds)

            // If the tree returned actionable nodes (> 1 node, not just an empty root wrapper)
            if nodes.count > 1 {
                let tree = AccessibilityOutline.buildTree(nodes)
                let outline = AccessibilityOutline.trim(AccessibilityOutline.render(tree), options: options)

                var refs: [String: BrowserElementRef] = [:]
                elements.removeAll()
                elementBounds.removeAll()
                for id in AccessibilityOutline.renderedIDs(tree) {
                    guard let element = byID[id], let node = nodes.first(where: { $0.encodedID == id }) else { continue }
                    elements[id] = element
                    if let b = bounds[id] { elementBounds[id] = b }
                    refs[id] = BrowserElementRef(
                        id: id, role: AccessibilityOutline.decorateRole(of: node), name: node.name,
                        frameOrdinal: 0, url: urls[id], bounds: bounds[id])
                }
                return privacyFilter.redact(BrowserSnapshot(driver: .accessibility, url: page.url, title: page.title, outline: outline, refs: refs))
            }
        }

        // 2. Fallback to OCR snapshot if AX tree was unavailable or empty
        if let ocrSnapshotProvider,
           let fallbackSnapshot = try await ocrSnapshotProvider(app.processIdentifier, options) {
            elements.removeAll()
            elementBounds.removeAll()
            for (id, ref) in fallbackSnapshot.refs {
                if let b = ref.bounds { elementBounds[id] = b }
            }
            let url = fallbackSnapshot.url.isEmpty ? page.url : fallbackSnapshot.url
            let title = fallbackSnapshot.title.isEmpty ? page.title : fallbackSnapshot.title
            return privacyFilter.redact(BrowserSnapshot(
                driver: .accessibility,
                url: url,
                title: title,
                outline: fallbackSnapshot.outline,
                refs: fallbackSnapshot.refs
            ))
        }

        // 3. If no OCR fallback was configured or succeeded, throw standard missing content error
        _ = try webArea()
        throw BrowserError.notConnected("no web content found in browser window")
    }

    private func walk(
        _ element: AXUIElement, parentID: String?, depth: Int, counter: inout Int,
        nodes: inout [OutlineNode], elements: inout [String: AXUIElement],
        urls: inout [String: String], bounds: inout [String: CGRect]
    ) {
        guard depth < maxDepth, counter < maxElements else { return }
        let axRole = AX.string(element, kAXRoleAttribute) ?? ""
        let subrole = AX.string(element, kAXSubroleAttribute)
        let id = "0-\(counter)"
        counter += 1

        let role = Self.webRole(axRole: axRole, subrole: subrole)
        let isSecure = axRole == "AXSecureTextField"
        var name = AX.string(element, kAXTitleAttribute)
        if name?.isEmpty != false { name = AX.string(element, kAXDescriptionAttribute) }
        if name?.isEmpty != false, role == "StaticText" || role == "heading" || role == "link" {
            name = AX.string(element, kAXValueAttribute)
        }
        if name?.isEmpty != false, let label = AX.string(element, "AXPlaceholderValue") { name = label }
        let value = isSecure ? nil : AX.string(element, kAXValueAttribute)
        let children = AX.elements(element, kAXChildrenAttribute) ?? []

        nodes.append(OutlineNode(
            nodeID: id, parentID: parentID, childIDs: [], role: role,
            name: name.map(AccessibilityOutline.cleanText),
            value: role == "textbox" || role == "combobox" || role == "searchbox" ? value : nil,
            selected: AX.bool(element, kAXSelectedAttribute),
            checked: role == "checkbox" || role == "radio" ? (AX.number(element, kAXValueAttribute).map { $0 != 0 }) : nil,
            encodedID: id,
            isScrollable: axRole == kAXScrollAreaRole))
        elements[id] = element
        if let url = AX.url(element) { urls[id] = url }
        if let frame = AX.frame(element) { bounds[id] = frame }

        // Child ids must match the ids the recursive walk assigns, so fill them
        // in after the children have been numbered.
        var assigned: [String] = []
        for child in children {
            guard counter < maxElements else { break }
            assigned.append("0-\(counter)")
            walk(child, parentID: id, depth: depth + 1, counter: &counter, nodes: &nodes, elements: &elements, urls: &urls, bounds: &bounds)
        }
        if let index = nodes.firstIndex(where: { $0.nodeID == id }) {
            nodes[index].childIDs = assigned
        }
    }

    /// Maps AppKit accessibility roles onto the ARIA-ish names the DevTools
    /// outline uses, so prompts and heuristics see one vocabulary.
    static func webRole(axRole: String, subrole: String?) -> String {
        switch axRole {
        case kAXButtonRole: return "button"
        case "AXLink": return "link"
        case kAXStaticTextRole: return "StaticText"
        case kAXTextFieldRole: return subrole == "AXSearchField" ? "searchbox" : "textbox"
        case kAXTextAreaRole: return "textbox"
        case "AXSecureTextField": return "textbox"
        case kAXCheckBoxRole: return subrole == "AXToggle" || subrole == "AXSwitch" ? "switch" : "checkbox"
        case kAXRadioButtonRole: return "radio"
        case kAXPopUpButtonRole: return "combobox"
        case kAXComboBoxRole: return "combobox"
        case kAXMenuButtonRole: return "button"
        case kAXImageRole: return "image"
        case kAXHeadingRole: return "heading"
        case kAXListRole: return "list"
        case kAXTableRole: return "table"
        case kAXRowRole: return "row"
        case kAXCellRole: return "cell"
        case kAXColumnRole: return "column"
        case kAXOutlineRole: return "tree"
        case kAXMenuRole: return "menu"
        case kAXMenuItemRole: return "menuitem"
        case kAXTabGroupRole: return "tablist"
        case kAXRadioGroupRole: return "radiogroup"
        case kAXSliderRole: return "slider"
        case kAXProgressIndicatorRole: return "progressbar"
        case kAXScrollAreaRole: return "generic"
        case "AXWebArea": return "WebArea"
        case kAXGroupRole:
            switch subrole {
            case "AXLandmarkNavigation": return "navigation"
            case "AXLandmarkMain": return "main"
            case "AXLandmarkBanner": return "banner"
            case "AXLandmarkContentInfo": return "contentinfo"
            case "AXLandmarkSearch": return "search"
            case "AXLandmarkComplementary": return "complementary"
            case "AXApplicationDialog", "AXDialog": return "dialog"
            case "AXDocumentArticle": return "article"
            default: return "generic"
            }
        case "AXTab": return "tab"
        case "AXList": return "list"
        default:
            if axRole.hasPrefix("AX") { return String(axRole.dropFirst(2)).lowercased() }
            return axRole.isEmpty ? "generic" : axRole
        }
    }

    // MARK: - Actions

    public func perform(_ action: BrowserAction, ref: BrowserElementRef?, target: BrowserElementRef?) async throws -> String {
        try requireReadable()
        try Task.checkCancellation()
        if scopedWindowID != nil { _ = try focusedWindow() }
        let app = try requireApp()
        func centerForRef(_ r: BrowserElementRef) throws -> CGPoint {
            if let elem = elements[r.id], let frame = AX.frame(elem), frame.width > 0, frame.height > 0 {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            if let frame = elementBounds[r.id] ?? r.bounds, frame.width > 0, frame.height > 0 {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            throw BrowserError.elementNotInteractable("[\(r.id)] has no on-screen geometry")
        }
        let label = ref.map { "[\($0.id)] \($0.role)\($0.name.map { ": \($0.prefix(60))" } ?? "")" } ?? "page"
        app.activate()

        switch action.method {
        case .click:
            guard let ref else { throw BrowserError.elementNotInteractable("click needs an element ref") }
            let button = action.arguments.first?.lowercased() ?? "left"
            if let elem = elements[ref.id], button == "left", AXUIElementPerformAction(elem, kAXPressAction as CFString) == .success {
                return "Clicked \(label) (accessibility press)"
            }
            let center = try centerForRef(ref)
            try synthesizer.click(at: center, button: button == "right" ? .right : (button == "middle" ? .middle : .left))
            return "Clicked \(label)"
        case .doubleClick:
            guard let ref else { throw BrowserError.elementNotInteractable("doubleClick needs an element ref") }
            let center = try centerForRef(ref)
            try synthesizer.click(at: center, clickCount: 2)
            return "Double-clicked \(label)"
        case .hover:
            guard let ref else { throw BrowserError.elementNotInteractable("hover needs an element ref") }
            let center = try centerForRef(ref)
            try synthesizer.mouseMove(to: center)
            return "Hovered \(label)"
        case .fill:
            guard let ref else { throw BrowserError.elementNotInteractable("fill needs an element ref") }
            let value = action.arguments.first ?? ""
            if let elem = elements[ref.id] {
                _ = AXUIElementSetAttributeValue(elem, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, value as CFString) == .success,
                   AX.string(elem, kAXValueAttribute) == value {
                    return "Filled \(label) with \"\(value)\""
                }
            }
            let center = try centerForRef(ref)
            try synthesizer.click(at: center)
            try synthesizer.pressKey("cmd+a")
            try synthesizer.typeText(value)
            return "Filled \(label) with \"\(value)\" (typed)"
        case .type:
            let value = action.arguments.first ?? ""
            if let ref {
                if let elem = elements[ref.id] {
                    _ = AXUIElementSetAttributeValue(elem, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    if AX.bool(elem, kAXFocusedAttribute) != true {
                        if let center = try? centerForRef(ref) {
                            try synthesizer.click(at: center)
                        }
                    }
                } else if let center = try? centerForRef(ref) {
                    try synthesizer.click(at: center)
                }
            }
            try synthesizer.typeText(value)
            return "Typed \"\(value)\" into \(label)"
        case .press:
            let key = action.arguments.first ?? "Enter"
            try synthesizer.pressKey(Self.chord(fromDevTools: key))
            return "Pressed \(key)"
        case .scrollTo:
            let percent = Self.percent(action.arguments.first)
            // No scroll model behind AX; approximate with wheel events.
            let lines = Int32(((percent / 100) * 2 - 1) * 200)
            let center: CGPoint
            if let ref {
                center = try centerForRef(ref)
            } else {
                let frame = (try? webArea()).flatMap { AX.frame($0) } ?? CGRect(x: 200, y: 200, width: 400, height: 400)
                center = CGPoint(x: frame.midX, y: frame.midY)
            }
            try synthesizer.scroll(deltaY: -lines, at: center, targetPID: app.processIdentifier)
            return "Scrolled \(label) towards \(Int(percent))% (approximate under Accessibility)"
        case .nextChunk, .prevChunk:
            let point: CGPoint
            if let ref {
                point = try centerForRef(ref)
            } else {
                let frame = (try? webArea()).flatMap { AX.frame($0) } ?? CGRect(x: 200, y: 200, width: 400, height: 400)
                point = CGPoint(x: frame.midX, y: frame.midY)
            }
            let delta: Int32 = action.method == .nextChunk ? -40 : 40
            try synthesizer.scroll(deltaY: delta, at: point, targetPID: app.processIdentifier)
            return "Scrolled \(label) \(action.method == .nextChunk ? "down" : "up") one chunk"
        case .selectOptionFromDropdown:
            guard let ref, let elem = elements[ref.id] else {
                throw BrowserError.unsupportedAction("selecting dropdown options needs an AX element ref")
            }
            let wanted = action.arguments.first ?? ""
            if AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, wanted as CFString) == .success {
                return "Selected \"\(wanted)\" on \(label)"
            }
            throw BrowserError.unsupportedAction("selecting dropdown options needs the DevTools driver; click the dropdown, take a snapshot, then click the option")
        case .dragAndDrop:
            guard let ref else { throw BrowserError.elementNotInteractable("dragAndDrop needs an element ref") }
            guard let target else { throw BrowserError.elementNotInteractable("dragAndDrop needs a target ref") }
            let fromCenter = try centerForRef(ref)
            let toCenter = try centerForRef(target)
            try synthesizer.drag(from: fromCenter, to: toCenter)
            return "Dragged \(label) onto [\(target.id)]"
        }
    }

    /// DevTools-style chords (`Meta+KeyA`, `Control+Enter`) → the synthesizer's
    /// `cmd+a` vocabulary.
    static func chord(fromDevTools key: String) -> String {
        key.split(separator: "+").map { part -> String in
            let token = part.trimmingCharacters(in: .whitespaces)
            switch token.lowercased() {
            case "meta", "cmd", "command", "super": return "cmd"
            case "control", "ctrl": return "ctrl"
            case "alt", "option", "opt": return "alt"
            case "shift": return "shift"
            case "arrowleft": return "left"
            case "arrowright": return "right"
            case "arrowup": return "up"
            case "arrowdown": return "down"
            default:
                if token.hasPrefix("Key"), token.count == 4 { return String(token.dropFirst(3)).lowercased() }
                if token.hasPrefix("Digit"), token.count == 6 { return String(token.dropFirst(5)) }
                return token.lowercased()
            }
        }.joined(separator: "+")
    }

    static func percent(_ raw: String?) -> Double {
        let digits = (raw ?? "0").filter { $0.isNumber || $0 == "." }
        return min(100, max(0, Double(digits) ?? 0))
    }

    // MARK: - Navigation

    public func navigate(to url: String, waitUntil: BrowserLoadState) async throws {
        let target = try BrowserURLPolicy.validate(url)
        guard scopedWindowID == nil, EventSynthesizer.expectedTargetWindowID == nil else {
            throw BrowserError.unsupportedAction("opening a URL cannot be confined to the selected window with Accessibility")
        }
        try Task.checkCancellation()
        try await connect()
        let app = try requireApp()
        try await open(target, in: app)
        try await waitForLoad(timeout: 15)
    }

    private func open(_ target: URL, in app: NSRunningApplication) async throws {
        guard let bundleURL = app.bundleURL else {
            throw BrowserError.navigationFailed("invalid URL \(target.absoluteString)")
        }
        // Opening through the workspace lands in a new tab of the running
        // browser — the user's current tab is left alone.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            try Task.checkCancellation()
            _ = try await NSWorkspace.shared.open([target], withApplicationAt: bundleURL, configuration: configuration)
        } catch {
            throw BrowserError.navigationFailed(error.localizedDescription)
        }
    }

    public func goBack() async throws -> Bool {
        try requireApp().activate()
        try synthesizer.pressKey("cmd+[")
        try await waitForLoad(timeout: 10)
        return true
    }

    public func goForward() async throws -> Bool {
        try requireApp().activate()
        try synthesizer.pressKey("cmd+]")
        try await waitForLoad(timeout: 10)
        return true
    }

    public func reload() async throws {
        try requireApp().activate()
        try synthesizer.pressKey("cmd+r")
        try await waitForLoad(timeout: 15)
    }

    public func wait(for condition: BrowserWaitCondition, timeout: TimeInterval) async throws {
        if case .milliseconds = condition {} else { try requireReadable() }
        switch condition {
        case .load: try await waitForLoad(timeout: timeout)
        case .selector: throw BrowserError.unsupportedAction("waiting for a CSS selector needs the DevTools driver; use 'text' instead")
        case .text(let text):
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if (try? readPageText())?.localizedCaseInsensitiveContains(text) == true { return }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            throw BrowserError.timeout("text \"\(text)\" did not appear within \(Int(timeout))s")
        case .milliseconds(let ms): try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        }
    }

    /// Safari and Chromium expose `AXLoaded`/`AXLoadingProgress` on the web
    /// area; when neither exists a short settle delay is the best available.
    private func waitForLoad(timeout: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let area = try? webArea() else {
                try await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            if let loaded = AX.bool(area, "AXLoaded") {
                if loaded { return }
            } else if let progress = AX.number(area, "AXLoadingProgress") {
                if progress >= 1 { return }
            } else {
                try await Task.sleep(nanoseconds: 800_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw BrowserError.timeout("page did not finish loading within \(Int(timeout))s")
    }

    // MARK: - Readers

    private func readCurrentPage() throws -> (url: String, title: String) {
        let window = try focusedWindow()
        let title = AX.string(window, kAXTitleAttribute) ?? ""
        let url = (try? webArea()).flatMap { AX.url($0) } ?? (try? webArea()).flatMap { AX.string($0, "AXDocument") } ?? ""
        return (url, title)
    }

    public func currentPage() async throws -> (url: String, title: String) {
        try await connect()
        try requireReadable()
        return try readCurrentPage()
    }

    private func readPageText() throws -> String {
        let app = try requireApp()
        return AccessibilityReader(maxElements: maxElements, maxDepth: maxDepth, maxCharacters: 60_000)
            .readWindow(pid: app.processIdentifier)?.text ?? ""
    }

    public func pageText() async throws -> String {
        try await connect()
        try requireReadable()
        let text = (try? readPageText()) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50 {
            return privacyFilter.redactSensitiveText(text)
        }
        if let ocrTextProvider, let app {
            if let ocr = try await ocrTextProvider(app.processIdentifier), !ocr.isEmpty {
                return privacyFilter.redactSensitiveText(ocr)
            }
        }
        return privacyFilter.redactSensitiveText(text)
    }

    public func screenshotPNG() async throws -> Data {
        let app = try requireApp()
        let image = try await ScreenCapturer().captureFocusedWindow(
            pid: app.processIdentifier, excluding: isWindowExcluded)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw BrowserError.protocolError("could not encode screenshot")
        }
        return data
    }

    public func evaluate(_ expression: String) async throws -> String {
        throw BrowserError.unsupportedAction("JavaScript evaluation needs the DevTools driver (start Chrome with --remote-debugging-port)")
    }

    // MARK: - Tabs (windows, under Accessibility)

    public func tabs() async throws -> [BrowserTab] {
        try await connect()
        let app = try requireApp()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let focused = AX.element(axApp, kAXFocusedWindowAttribute)
        let windows = AX.elements(axApp, kAXWindowsAttribute) ?? []
        let selected = scopedWindowID == nil ? nil : try focusedWindow()
        var result: [BrowserTab] = []
        for (index, window) in windows.enumerated() {
            guard selected.map({ CFEqual($0, window) }) ?? true else { continue }
            let (title, url) = AX.windowInfo(window)
            let isActive = focused.map { CFEqual($0, window) } ?? false
            let hidden = (try? checkReadable(bundleID: app.bundleIdentifier, title: title, url: url)) == nil
            result.append(BrowserTab(id: "window-\(index)", url: hidden ? "[excluded]" : url,
                title: hidden ? "[excluded]" : title, isActive: isActive))
        }
        return result
    }

    public func openTab(url: String) async throws -> BrowserTab {
        let target = try BrowserURLPolicy.validate(url, allowBlank: true)
        try await connect()
        try await open(target, in: try requireApp())
        try await waitForLoad(timeout: 15)
        let page = try readCurrentPage()
        return BrowserTab(id: "window-focused", url: page.url, title: page.title, isActive: true)
    }

    public func switchTab(id: String) async throws {
        guard scopedWindowID == nil else {
            throw BrowserError.unsupportedAction("switching away from the selected window is refused")
        }
        try Task.checkCancellation()
        try await connect()
        let app = try requireApp()
        guard let index = Int(id.replacingOccurrences(of: "window-", with: "")) else {
            throw BrowserError.protocolError("unknown tab id \(id)")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = AX.elements(axApp, kAXWindowsAttribute) ?? []
        guard windows.indices.contains(index) else { throw BrowserError.protocolError("no window \(id)") }
        let (title, url) = AX.windowInfo(windows[index])
        try checkReadable(bundleID: app.bundleIdentifier, title: title, url: url)
        try Task.checkCancellation()
        _ = AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
        app.activate()
    }

    public func closeTab(id: String) async throws {
        throw BrowserError.unsupportedAction("closing tabs is only supported with the DevTools driver")
    }
}

// MARK: - AX helpers

enum AX {
    static func windowInfo(_ window: AXUIElement) -> (title: String, url: String) {
        var visited = 0
        let pageURL = find(in: window, role: "AXWebArea", depth: 0, visited: &visited).flatMap { url($0) } ?? ""
        return (string(window, kAXTitleAttribute) ?? "", pageURL)
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return (value as! CFArray) as? [AXUIElement]
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! CFString) as String }
        if CFGetTypeID(value) == CFAttributedStringGetTypeID() { return (value as! CFAttributedString as NSAttributedString).string }
        if CFGetTypeID(value) == CFNumberGetTypeID() { return "\((value as! CFNumber) as NSNumber)" }
        if CFGetTypeID(value) == CFURLGetTypeID() { return ((value as! CFURL) as URL).absoluteString }
        return nil
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func number(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() { return ((value as! CFNumber) as NSNumber).doubleValue }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? 1 : 0 }
        return nil
    }

    static func url(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return ((value as! CFURL) as URL).absoluteString }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! CFString) as String }
        return nil
    }

    /// Screen frame in Quartz (top-left origin) coordinates.
    static func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func find(in element: AXUIElement, role: String, depth: Int, visited: inout Int) -> AXUIElement? {
        guard depth < 30, visited < 3000 else { return nil }
        visited += 1
        if string(element, kAXRoleAttribute) == role { return element }
        for child in elements(element, kAXChildrenAttribute) ?? [] {
            if let found = find(in: child, role: role, depth: depth + 1, visited: &visited) { return found }
        }
        return nil
    }

    static func findFirstMatching(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth < 30, visited < 3000 else { return nil }
        visited += 1
        if predicate(element) { return element }
        for child in elements(element, kAXChildrenAttribute) ?? [] {
            if let found = findFirstMatching(in: child, depth: depth + 1, visited: &visited, predicate: predicate) {
                return found
            }
        }
        return nil
    }

    static func findWebArea(in element: AXUIElement) -> AXUIElement? {
        var visited = 0
        if let direct = find(in: element, role: "AXWebArea", depth: 0, visited: &visited) {
            return direct
        }
        visited = 0
        if let doc = findFirstMatching(in: element, depth: 0, visited: &visited, predicate: { elem in
            let role = string(elem, kAXRoleAttribute) ?? ""
            let subrole = string(elem, kAXSubroleAttribute) ?? ""
            return role == "AXWebArea" ||
                   ((role == kAXScrollAreaRole || role == kAXGroupRole) &&
                    (subrole == "AXDocument" || subrole == "AXDocumentArticle" || subrole == "AXDocumentWeb"))
        }) {
            return doc
        }
        visited = 0
        if let scroll = find(in: element, role: kAXScrollAreaRole, depth: 0, visited: &visited) {
            return scroll
        }
        return nil
    }
}
