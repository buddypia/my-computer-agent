import AppKit
import Foundation
import MCACore
import MCAPerception
import MCASensing

// The browser tool surface: a
// structured snapshot with refs, deterministic ref-addressed actions, and the
// three model-backed primitives (act / observe / extract). Every tool shares
// one `BrowserSession`, so refs from `browser_snapshot` are what
// `browser_element` resolves.

/// Formats any error the way the model can act on.
func browserErrorMessage(_ error: Error) async -> String {
    if error is ActionAuthorizationError || error is CancellationError { await ActionAuthorization.current?.abort(error) }
    if let browserError = error as? BrowserError { return "Error: \(browserError.description)" }
    if let cdpError = error as? CDPError { return "Error: \(cdpError.description)" }
    if let modelError = error as? LanguageModelError { return "Error: \(modelError.description)" }
    return "Error: \(error.localizedDescription)"
}

private func snapshotHeader(_ snapshot: BrowserSnapshot) -> String {
    "URL: \(snapshot.url)\nTitle: \(snapshot.title)\nRefs: \(snapshot.refs.count) (valid until the next snapshot)\n\n"
}

// MARK: - browser_navigate

public struct BrowserNavigateTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_navigate",
            description: """
                Open a URL in the agent's own browser tab (attached to the user's running Chrome, so their logins \
                are available; never navigates the tab the user is reading). Also handles back, forward and reload. \
                Returns the final URL and title. Call browser_snapshot afterwards to see the page.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "url": {"type": "string", "description": "Absolute URL to open (https://…). Required for action 'goto'."},
                    "action": {"type": "string", "enum": ["goto", "back", "forward", "reload"], "description": "Defaults to 'goto'."},
                    "wait_until": {"type": "string", "enum": ["domcontentloaded", "load", "networkidle"], "description": "Load state to wait for (default domcontentloaded)."}
                  }
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let action = parsed.string("action") ?? "goto"
        do {
            if !["back", "forward", "reload"].contains(action) { try await session.validateNavigationScope() }
            try await session.authorizeCurrentPage(operation: action, details: String(decoding: arguments, as: UTF8.self))
            try Task.checkCancellation()
            let driver = try await session.driver()
            switch action {
            case "back":
                guard try await driver.goBack() else { return "No previous page in history." }
            case "forward":
                guard try await driver.goForward() else { return "No next page in history." }
            case "reload":
                try await driver.reload()
            default:
                guard var url = parsed.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                    return "Error: 'url' parameter is required for action 'goto'."
                }
                if !url.contains("://") { url = "https://\(url)" }
                let state = BrowserLoadState(rawValue: parsed.string("wait_until") ?? "") ?? .domcontentloaded
                try await driver.navigate(to: url, waitUntil: state)
            }
            let page = try await session.currentPage()
            return "Now at \(page.url) — \"\(page.title)\" (\(await session.describeConnection())). Take browser_snapshot to see the page and get refs."
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_snapshot

public struct BrowserSnapshotTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_snapshot",
            description: """
                Read the current browser page as a hybrid accessibility tree: one line per element, \
                `[ref] role: name`, e.g. `[0-142] button: Sign in`. Prefer this over screenshots — it is \
                structured, fast and returns refs that browser_element can act on precisely. Refs are \
                refreshed on every snapshot: after a click, form submit, navigation or re-render, take a new \
                snapshot before using a ref again. Use `filter` or `max_depth` on large pages.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "filter": {"type": "string", "description": "Keep only lines containing this text (or a /regex/) plus their ancestors."},
                    "max_depth": {"type": "integer", "description": "Drop lines nested deeper than this."},
                    "include_frames": {"type": "boolean", "description": "Include iframe contents (default true)."}
                  }
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let options = BrowserSnapshotOptions(
            filter: parsed.string("filter"),
            maxDepth: parsed.int("max_depth"),
            includeFrames: (parsed["include_frames"] as? Bool) ?? true)
        do {
            let snapshot = try await session.snapshot(options: options)
            let body = snapshot.outline.isEmpty ? "(the page exposes no accessible content yet — wait or reload)" : snapshot.outline
            return snapshotHeader(snapshot) + body
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_element

public struct BrowserElementTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_element",
            description: """
                Deterministic action on an element by its snapshot ref (e.g. "0-142"). Actions: click, \
                double_click, hover, fill (clear + set a field's value), type (append text to a field, or to \
                the focused element when ref is omitted), press (a key or chord such as Enter, Tab, Cmd+A — \
                ref optional), select (choose <select> option by label/value), scroll_to (percent of the \
                element's or page's scroll range), next_chunk / prev_chunk (scroll one viewport; ref optional \
                = page), drag_and_drop (ref → target_ref). Take a new browser_snapshot after the action.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "action": {"type": "string", "enum": ["click", "double_click", "hover", "fill", "type", "press", "select", "scroll_to", "next_chunk", "prev_chunk", "drag_and_drop"]},
                    "ref": {"type": "string", "description": "Element ref from the latest browser_snapshot, e.g. \\"0-142\\"."},
                    "value": {"type": "string", "description": "Text for fill/type, option label for select, key or chord for press, percent (e.g. \\"50%\\") for scroll_to, or 'right'/'middle' for a non-left click."},
                    "target_ref": {"type": "string", "description": "Drop target ref for drag_and_drop."},
                    "variables": {"type": "object", "description": "Optional map for %name% placeholders in value, so secrets can be passed without appearing in the instruction."}
                  },
                  "required": ["action"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let actionName = parsed.string("action") else { return "Error: 'action' parameter is required." }
        let ref = parsed.string("ref")
        let value = parsed.string("value") ?? parsed.string("text") ?? parsed.string("key")
        let variables = (parsed["variables"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]

        let method: BrowserActionMethod
        var args: [String] = []
        switch actionName {
        case "click": method = .click; if let value { args = [value] }
        case "double_click", "doubleClick": method = .doubleClick
        case "hover": method = .hover
        case "fill":
            guard let value else { return "Error: 'value' is required for fill." }
            method = .fill; args = [value]
        case "type":
            guard let value else { return "Error: 'value' is required for type." }
            method = .type; args = [value]
        case "press":
            guard let value else { return "Error: 'value' (key or chord) is required for press." }
            method = .press; args = [value]
        case "select", "selectOptionFromDropdown":
            guard let value else { return "Error: 'value' (option label or value) is required for select." }
            method = .selectOptionFromDropdown; args = [value]
        case "scroll_to", "scrollTo": method = .scrollTo; args = [value ?? "0%"]
        case "next_chunk", "nextChunk": method = .nextChunk
        case "prev_chunk", "prevChunk": method = .prevChunk
        case "drag_and_drop", "dragAndDrop":
            guard let target = parsed.string("target_ref") else { return "Error: 'target_ref' is required for drag_and_drop." }
            method = .dragAndDrop; args = [target]
        default:
            return "Error: unsupported action '\(actionName)'."
        }
        if method.requiresElement, ref == nil {
            return "Error: 'ref' is required for \(actionName). Take browser_snapshot to get refs."
        }

        do {
            let message = try await session.perform(BrowserAction(method: method, elementID: ref, arguments: args), variables: variables)
            return "\(message). Take browser_snapshot to see the result."
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_act

public struct BrowserActTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_act",
            description: """
                Perform ONE atomic browser action described in natural language, e.g. "click the sign in \
                button", "type 'Tokyo' into the search box", "select 'Japan' from the country dropdown", \
                "scroll to the bottom", "press Enter". The page is observed automatically, the best element \
                is chosen, the action runs deterministically, and it self-heals if the page changed. Do not \
                combine several steps in one instruction. Use browser_navigate for URLs.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "instruction": {"type": "string", "description": "One atomic action in natural language."},
                    "variables": {"type": "object", "description": "Optional map of %name% placeholders the instruction may reference, e.g. {\\"password\\": \\"…\\"}; values never reach the model."}
                  },
                  "required": ["instruction"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let instruction = parsed.string("instruction")?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else {
            return "Error: 'instruction' parameter is required."
        }
        let variables = (parsed["variables"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        do {
            let outcome = try await session.act(instruction: instruction, variables: variables)
            var lines = [outcome.success ? "Done: \(outcome.message)" : "Not done: \(outcome.message)"]
            if outcome.selfHealed { lines.append("(The page had changed; the element was re-located before acting.)") }
            for action in outcome.actions {
                lines.append("- \(action.method.rawValue) [\(action.elementID ?? "-")] \(action.description)\(action.arguments.isEmpty ? "" : " args=\(action.arguments)")")
            }
            if outcome.success { lines.append("Take browser_snapshot to verify the new page state.") }
            return lines.joined(separator: "\n")
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_observe

public struct BrowserObserveTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_observe",
            description: """
                Find elements on the current page that match a description, without acting. Returns refs with \
                a suggested method and arguments, ready for browser_element. Use it to plan when several \
                elements might match, or to locate inputs so credentials can be filled deterministically.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "instruction": {"type": "string", "description": "What to look for, e.g. \\"the email and password inputs\\". Omit to list all interactive elements."}
                  }
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        do {
            let elements = try await session.observe(instruction: parsed.string("instruction"))
            guard !elements.isEmpty else { return "No matching elements found. Take browser_snapshot to see the page." }
            return elements.map { element in
                "[\(element.elementID)] \(element.description) → \(element.method.rawValue)\(element.arguments.isEmpty ? "" : " \(element.arguments)")"
            }.joined(separator: "\n")
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_extract

public struct BrowserExtractTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_extract",
            description: """
                Extract structured data from the current page, e.g. "every product name and price in the \
                results table". Optionally pass a JSON Schema (object) for the shape you want; otherwise a \
                free-form `data` field is returned. Extracts from the accessibility tree, so it works on \
                content the user can see.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "instruction": {"type": "string", "description": "What to extract."},
                    "schema": {"type": "object", "description": "Optional JSON Schema of type object describing the result."}
                  },
                  "required": ["instruction"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let instruction = parsed.string("instruction"), !instruction.isEmpty else {
            return "Error: 'instruction' parameter is required."
        }
        var schema: Data?
        if let object = parsed["schema"] as? [String: Any], object["type"] as? String == "object" {
            schema = try? JSONSerialization.data(withJSONObject: object)
        }
        do {
            return try await session.extract(instruction: instruction, schema: schema)
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_read

public struct BrowserReadTool: AgentTool {
    private let session: BrowserSession
    private let approver: any ToolApproving
    private let home: URL

    public init(
        session: BrowserSession,
        approver: any ToolApproving = DenyAllToolApprover(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.session = session
        self.approver = approver
        self.home = home
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_read",
            description: """
                Read plain facts from the current browser page: 'url', 'title', 'text' (visible text of the \
                whole page, capped), or 'screenshot' (saves a PNG and returns its path — only when layout or \
                images matter; prefer browser_snapshot). A screenshot to a path of your choosing needs the \
                user's approval and cannot target shell, SSH or system files; omit the path to use a temporary file.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "what": {"type": "string", "enum": ["url", "title", "text", "screenshot"]},
                    "max_characters": {"type": "integer", "description": "Cap for 'text' (default 8000)."},
                    "path": {"type": "string", "description": "Output path for 'screenshot' (default: a temporary file)."}
                  },
                  "required": ["what"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let what = parsed.string("what") ?? "text"
        do {
            let driver = try await session.driver()
            switch what {
            case "url": return try await session.currentPage().url
            case "title": return try await session.currentPage().title
            case "screenshot":
                let requested = parsed.string("path")
                let path = requested.map { NSString(string: $0).expandingTildeInPath }
                    ?? FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString).png").path
                var outsideHome = false
                if let requested {
                    switch FileWritePolicy.evaluate(path: requested, home: home) {
                    case .denied(let reason):
                        return "Error: writing '\(path)' is not allowed: \(reason). Tell the user instead of trying another path."
                    case .needsApproval(let outside): outsideHome = outside
                    }
                }
                let parents: GuardedFileWriter.ParentCreation?
                let existingDestination: GuardedFileWriter.Destination?
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) {
                    parents = nil
                    existingDestination = try GuardedFileWriter.Destination(path)
                } else {
                    parents = try GuardedFileWriter.ParentCreation(path)
                    existingDestination = nil
                }
                let original = try existingDestination.flatMap { try GuardedFileWriter.snapshot($0) }
                let data = try await driver.screenshotPNG()
                _ = try await session.currentPage()
                if original != nil || requested != nil {
                    if ActionAuthorization.current != nil {
                        try await ActionAuthorization.requireApproval(
                            operation: original == nil ? "Create screenshot file" : "Overwrite screenshot",
                            target: existingDestination?.path ?? path, details: "PNG image (\(data.count) bytes)",
                            revalidate: {
                                if let destination = existingDestination {
                                    guard destination.isCurrent() else { return false }
                                    return try GuardedFileWriter.snapshot(destination) == original
                                }
                                return parents?.isCurrent() == true
                            })
                    } else if let refusal = await approver.gate(ToolApprovalRequest(
                        toolName: definition.name, title: "Save a browser screenshot to a file",
                        detail: "Path: \(ApprovalText.visible(path))",
                        warning: outsideHome ? "This path is outside your home folder." : nil)) { return refusal }
                }
                try Task.checkCancellation()
                if let requested {
                    guard case .needsApproval = FileWritePolicy.evaluate(path: requested, home: home) else {
                        throw ActionAuthorizationError.staleTarget
                    }
                }
                let destination: GuardedFileWriter.Destination
                if let existingDestination { destination = existingDestination }
                else if let parents { destination = try parents.create() }
                else { throw ActionAuthorizationError.staleTarget }
                try GuardedFileWriter.write(data, to: destination, append: false, expected: original)
                return "Saved screenshot (\(data.count) bytes) to \(path)"
            default:
                let cap = max(500, min(parsed.int("max_characters") ?? 8000, 60_000))
                let text = try await driver.pageText()
                let page = try await session.currentPage()
                let trimmed = text.count > cap ? String(text.prefix(cap)) + "\n… (\(text.count - cap) more characters)" : text
                return "URL: \(page.url)\nTitle: \(page.title)\n\n\(trimmed)"
            }
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_tabs

public struct BrowserTabsTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_tabs",
            description: """
                List, open, switch to, or close browser tabs. 'switch' makes an existing tab (for example one \
                the user already has open and is logged into) the agent's active tab. 'close' only closes \
                tabs the agent opened itself (or explicitly switched into), and never the last tab; the \
                user's other tabs cannot be closed.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "action": {"type": "string", "enum": ["list", "new", "switch", "close"]},
                    "id": {"type": "string", "description": "Tab id from 'list' for switch/close."},
                    "url": {"type": "string", "description": "URL for 'new' (default about:blank)."}
                  },
                  "required": ["action"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let action = parsed.string("action") ?? "list"
        do {
            let driver = try await session.driver()
            switch action {
            case "new":
                try await session.validateNavigationScope()
                try await session.authorizeCurrentPage(operation: "Open tab", details: String(decoding: arguments, as: UTF8.self))
                try Task.checkCancellation()
                let tab = try await driver.openTab(url: parsed.string("url") ?? "about:blank")
                return "Opened tab \(tab.id): \(tab.url)"
            case "switch":
                guard let id = parsed.string("id") else { return "Error: 'id' is required for switch." }
                try await session.switchTab(id: id)
                let page = try await session.currentPage()
                return "Switched to tab \(id): \(page.url) — \"\(page.title)\". Take browser_snapshot next."
            case "close":
                guard let id = parsed.string("id") else { return "Error: 'id' is required for close." }
                guard try await driver.tabs().first(where: \.isActive)?.id == id else {
                    return "Error: only the observed active tab can be approved for closing."
                }
                try await session.authorizeCurrentPage(operation: "Close tab", details: "Tab ID: \(id)")
                try Task.checkCancellation()
                try await driver.closeTab(id: id)
                return "Closed tab \(id)."
            default:
                let tabs = try await session.tabs()
                guard !tabs.isEmpty else { return "No tabs open." }
                return tabs.map { "\($0.isActive ? "* " : "  ")\($0.id)  \($0.title.isEmpty ? "(untitled)" : $0.title)  \($0.url)" }.joined(separator: "\n")
            }
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_wait

public struct BrowserWaitTool: AgentTool {
    private let session: BrowserSession
    public init(session: BrowserSession) { self.session = session }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_wait",
            description: """
                Wait for the page: 'load' (domcontentloaded / load / networkidle), 'selector' (a CSS selector \
                becomes visible), 'text' (text appears on the page), or 'ms' (a fixed delay). Use after an \
                action that triggers loading, before the next snapshot.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "for": {"type": "string", "enum": ["load", "selector", "text", "ms"]},
                    "value": {"type": "string", "description": "Load state, CSS selector, text, or milliseconds."},
                    "timeout_ms": {"type": "integer", "description": "Give up after this many ms (default 15000)."}
                  },
                  "required": ["for"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let kind = parsed.string("for") ?? "load"
        let value = parsed.string("value") ?? ""
        let timeout = Double(min(max(parsed.int("timeout_ms") ?? 15_000, 100), 120_000)) / 1000
        let condition: BrowserWaitCondition
        switch kind {
        case "selector":
            guard !value.isEmpty else { return "Error: 'value' (CSS selector) is required." }
            condition = .selector(value)
        case "text":
            guard !value.isEmpty else { return "Error: 'value' (text) is required." }
            condition = .text(value)
        case "ms":
            condition = .milliseconds(min(Int(value) ?? 1000, 30_000))
        default:
            condition = .load(BrowserLoadState(rawValue: value) ?? .load)
        }
        do {
            try await session.driver().wait(for: condition, timeout: timeout)
            return "Wait satisfied (\(kind)\(value.isEmpty ? "" : " \(value)")). Take browser_snapshot next."
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

// MARK: - browser_evaluate

/// Arbitrary JavaScript in the user's logged-in browser can read any page and
/// act as the user, so the expression goes through `approver` first.
public struct BrowserEvaluateTool: AgentTool {
    private let session: BrowserSession
    private let approver: any ToolApproving

    public init(session: BrowserSession, approver: any ToolApproving = DenyAllToolApprover()) {
        self.session = session
        self.approver = approver
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "browser_evaluate",
            description: """
                Run a JavaScript expression in the current page and return its result as text (DevTools \
                driver only). For reading values the snapshot does not show, e.g. `document.title`, \
                `location.href`, or `JSON.stringify([...document.querySelectorAll('a')].map(a => a.href))`.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "expression": {"type": "string", "description": "JavaScript expression. A returned promise is awaited."}
                  },
                  "required": ["expression"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let expression = parsed.string("expression"), !expression.isEmpty else {
            return "Error: 'expression' parameter is required."
        }
        if ActionAuthorization.current == nil, let refusal = await approver.gate(ToolApprovalRequest(
            toolName: definition.name,
            title: "Run JavaScript in the browser",
            detail: ApprovalText.visible(expression, keepingLineBreaks: true),
            warning: "This runs inside your logged-in browser page.")) {
            return refusal
        }
        do {
            if ActionAuthorization.current != nil {
                try await session.authorizeCurrentPage(operation: "Evaluate JavaScript", details: expression)
            }
            try Task.checkCancellation()
            let result = try await session.driver().evaluate(expression)
            _ = try await session.currentPage()
            return result.count > 20_000 ? String(result.prefix(20_000)) + "\n… (truncated)" : result
        } catch {
            return await browserErrorMessage(error)
        }
    }
}

/// Everything the agent needs, in one call, so the two composition roots
/// (`main.swift` and `Copilot.swift`) cannot drift.
public enum BrowserToolkit {
    public static func tools(
        session: BrowserSession,
        approver: any ToolApproving = DenyAllToolApprover()
    ) -> [any AgentTool] {
        [
            BrowserNavigateTool(session: session),
            BrowserSnapshotTool(session: session),
            BrowserElementTool(session: session),
            BrowserActTool(session: session),
            BrowserObserveTool(session: session),
            BrowserExtractTool(session: session),
            BrowserReadTool(session: session, approver: approver),
            BrowserTabsTool(session: session),
            BrowserWaitTool(session: session),
            BrowserEvaluateTool(session: session, approver: approver),
        ]
    }

    /// The default session: DevTools first, macOS Accessibility as fallback.
    ///
    /// `privacy` is the exclusion list pages are checked against: a DevTools
    /// page matching it (by title or URL) is never read, the way a window
    /// matching it is never captured.
    public static func makeSession(
        router: ModelRouter?, settings: BrowserAutomationSettings, privacy: AgentConfiguration,
        keystrokeApprover: any ToolApproving = DenyAllToolApprover()
    ) -> BrowserSession {
        let cdp = CDPBrowserDriver(
            settings: CDPBrowserSettings(
                host: settings.devtoolsHost,
                ports: settings.devtoolsPorts,
                launchIfMissing: settings.launchIfMissing,
                launchPort: settings.launchPort),
            isPageExcluded: { url, title in
                privacy.isExcluded(bundleID: nil, windowTitle: title)
                    || privacy.isExcluded(bundleID: nil, windowTitle: url)
            })
        let isWindowExcluded: ScreenCapturer.WindowExclusion = { bundleID, title in
            privacy.isExcluded(bundleID: bundleID, windowTitle: title)
        }
        var drivers: [any BrowserDriving] = [cdp]
        if settings.accessibilityFallback {
            let capturer = ScreenCapturer()
            let recognizer = TextRecognizer()
            let axDriver = AXBrowserDriver(
                ocrSnapshotProvider: { pid, options in
                    do {
                        let image = try await capturer.captureFocusedWindow(pid: pid, excluding: isWindowExcluded)
                        let windowBounds = AccessibilityInspector.resolveWindowBoundsFromWindowList(pid: pid)
                        let candidates = try await recognizer.recognizeCandidates(in: image, windowFrame: windowBounds)
                        guard !candidates.isEmpty else { return nil }

                        var refs: [String: BrowserElementRef] = [:]
                        var outlineLines: [String] = []

                        for (idx, cand) in candidates.enumerated() {
                            let id = "ocr-\(idx + 1)"
                            let ref = BrowserElementRef(
                                id: id,
                                role: cand.role,
                                name: cand.label,
                                frameOrdinal: 0,
                                url: nil,
                                bounds: cand.bounds
                            )
                            refs[id] = ref
                            outlineLines.append("[\(id)] \(cand.role): \(cand.label)")
                        }

                        let front = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
                        let title = front?.localizedName ?? "Browser"

                        return BrowserSnapshot(
                            driver: .accessibility,
                            url: "",
                            title: title,
                            outline: outlineLines.joined(separator: "\n"),
                            refs: refs
                        )
                    } catch {
                        return nil
                    }
                },
                ocrTextProvider: { pid in
                    do {
                        let image = try await capturer.captureFocusedWindow(pid: pid, excluding: isWindowExcluded)
                        return try await recognizer.recognizeText(in: image)
                    } catch {
                        return nil
                    }
                },
                isWindowExcluded: isWindowExcluded
            )
            drivers.append(axDriver)
        }
        let inference = router.map { BrowserInference(router: $0, task: settings.inferenceTask, userInstructions: settings.instructions ?? "") }
        return BrowserSession(drivers: drivers, inference: inference, keystrokeApprover: keystrokeApprover)
    }
}
