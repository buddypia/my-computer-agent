import Foundation
import MCACore
import MCAReasoning
import MCASensing

/// `mca browser …` — the browser workflow as a CLI, for
/// coding agents (Claude Code, Codex) and for smoke-testing the drivers
/// without a language model in the loop.
///
/// Every invocation is a fresh process, so the agent's tab id is persisted in
/// a small state file and re-claimed on start; refs survive across invocations
/// because they are DevTools backend node ids, which are stable for as long
/// as the node exists in the page.
enum BrowserCommand {
    static let usage = """
        Usage: mca browser <command> [args]

          navigate <url>                 open URL in the agent's own tab (never the user's)
          snapshot [--filter T] [--max-depth N]
                                         accessibility outline with refs: [0-142] button: Sign in
          click <ref> [right|middle]     deterministic click by ref
          dblclick <ref>                 double click
          hover <ref>
          fill <ref> <text>              clear the field and set its value
          type [<ref>] <text>            append text (focused element when ref omitted)
          press <key>                    Enter, Tab, Escape, Meta+KeyA, Control+Enter …
          select <ref> <option>          choose a <select> option by label or value
          scroll <ref> <percent>         scroll the element/page to N%
          next [ref] | prev [ref]        scroll one viewport
          drag <ref> <target-ref>
          act "<instruction>"            one atomic action in natural language (needs a model)
                                         (--task classify|answer|hardReasoning picks the model tier)
          observe ["<instruction>"]      find elements without acting (needs a model)
          extract "<instruction>"        pull structured data from the page (needs a model)
          text | url | title             read the page
          tabs                           list tabs (* = agent's tab)
          tab new [url] | tab switch <id> | tab close <id>
          wait load|text|selector|ms <value>
          eval "<javascript>"
          screenshot [path]
          back | forward | reload
        """

    private static var stateURL: URL {
        AgentConfiguration.defaultSupportDirectory.appending(path: "browser-cli.json")
    }

    private struct State: Codable {
        var targetID: String?
    }

    static func run(_ arguments: [String]) async {
        guard let command = arguments.first, command != "help", command != "-h", command != "--help" else {
            print(usage)
            exit(arguments.isEmpty ? 2 : 0)
        }
        var rest = Array(arguments.dropFirst())
        var configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
        if let flag = rest.firstIndex(of: "--task"), flag + 1 < rest.count {
            guard let task = AgentTask(rawValue: rest[flag + 1]) else {
                print("Unknown --task '\(rest[flag + 1])'. One of: \(AgentTask.allCases.map(\.rawValue).joined(separator: ", "))")
                exit(2)
            }
            configuration.browser.inferenceTask = task
            rest.removeSubrange(flag...(flag + 1))
        }
        let router = ModelRouter(policy: configuration.routing, credentials: CredentialStore())
        // `mca browser` runs the one action the user typed.
        let session = BrowserToolkit.makeSession(
            router: router, settings: configuration.browser, privacy: configuration,
            keystrokeApprover: AutoApproveToolApprover())
        // `mca browser evaluate "…"` is the user typing the expression
        // themselves, so there is no model to guard against.
        let tools = Dictionary(uniqueKeysWithValues: BrowserToolkit.tools(session: session, approver: AutoApproveToolApprover()).map { ($0.definition.name, $0) })

        func call(_ tool: String, _ args: [String: Any]) async -> String {
            guard let instance = tools[tool] else { return "Error: no tool \(tool)" }
            do {
                let data = try JSONSerialization.data(withJSONObject: args)
                return try await instance.invoke(arguments: data)
            } catch {
                return "Error: \(error)"
            }
        }

        // Re-claim the tab from the previous invocation, if it still exists.
        await reclaimTab(session: session)

        // Ref-addressed commands need the ref table; a fresh process has none.
        // Backend node ids are stable, so a silent snapshot rebuilds it.
        let refCommands: Set<String> = ["click", "dblclick", "hover", "fill", "type", "select", "scroll", "next", "prev", "drag"]
        if refCommands.contains(command), let first = rest.first, looksLikeRef(first) {
            _ = try? await session.snapshot(options: BrowserSnapshotOptions(maxCharacters: 1))
        }

        let output: String
        switch command {
        case "navigate", "goto", "open":
            guard let url = rest.first else { print("Usage: mca browser navigate <url>"); exit(2) }
            output = await call("browser_navigate", ["url": url, "wait_until": rest.dropFirst().first ?? "domcontentloaded"])
        case "back", "forward", "reload":
            output = await call("browser_navigate", ["action": command])
        case "snapshot":
            var args: [String: Any] = [:]
            var iterator = rest.makeIterator()
            while let flag = iterator.next() {
                switch flag {
                case "--filter", "-f": if let value = iterator.next() { args["filter"] = value }
                case "--max-depth", "-d": if let value = iterator.next(), let depth = Int(value) { args["max_depth"] = depth }
                case "--no-frames": args["include_frames"] = false
                default: args["filter"] = flag
                }
            }
            output = await call("browser_snapshot", args)
        case "click":
            guard let ref = rest.first else { print("Usage: mca browser click <ref>"); exit(2) }
            var args: [String: Any] = ["action": "click", "ref": ref]
            if let button = rest.dropFirst().first { args["value"] = button }
            output = await call("browser_element", args)
        case "dblclick":
            guard let ref = rest.first else { print("Usage: mca browser dblclick <ref>"); exit(2) }
            output = await call("browser_element", ["action": "double_click", "ref": ref])
        case "hover":
            guard let ref = rest.first else { print("Usage: mca browser hover <ref>"); exit(2) }
            output = await call("browser_element", ["action": "hover", "ref": ref])
        case "fill", "select", "scroll":
            guard rest.count >= 2 else { print("Usage: mca browser \(command) <ref> <value>"); exit(2) }
            let action = command == "scroll" ? "scroll_to" : command
            output = await call("browser_element", ["action": action, "ref": rest[0], "value": rest.dropFirst().joined(separator: " ")])
        case "type":
            guard !rest.isEmpty else { print("Usage: mca browser type [<ref>] <text>"); exit(2) }
            if looksLikeRef(rest[0]), rest.count >= 2 {
                output = await call("browser_element", ["action": "type", "ref": rest[0], "value": rest.dropFirst().joined(separator: " ")])
            } else {
                output = await call("browser_element", ["action": "type", "value": rest.joined(separator: " ")])
            }
        case "press", "key":
            guard let key = rest.first else { print("Usage: mca browser press <key>"); exit(2) }
            output = await call("browser_element", ["action": "press", "value": key])
        case "next", "prev":
            var args: [String: Any] = ["action": command == "next" ? "next_chunk" : "prev_chunk"]
            if let ref = rest.first { args["ref"] = ref }
            output = await call("browser_element", args)
        case "drag":
            guard rest.count == 2 else { print("Usage: mca browser drag <ref> <target-ref>"); exit(2) }
            output = await call("browser_element", ["action": "drag_and_drop", "ref": rest[0], "target_ref": rest[1]])
        case "act":
            output = await call("browser_act", ["instruction": rest.joined(separator: " ")])
        case "observe":
            output = await call("browser_observe", rest.isEmpty ? [:] : ["instruction": rest.joined(separator: " ")])
        case "extract":
            output = await call("browser_extract", ["instruction": rest.joined(separator: " ")])
        case "text", "url", "title":
            output = await call("browser_read", ["what": command])
        case "screenshot":
            var args: [String: Any] = ["what": "screenshot"]
            if let path = rest.first { args["path"] = path }
            output = await call("browser_read", args)
        case "tabs":
            output = await call("browser_tabs", ["action": "list"])
        case "tab":
            guard let sub = rest.first else { print("Usage: mca browser tab new|switch|close …"); exit(2) }
            var args: [String: Any] = ["action": sub]
            if sub == "new", let url = rest.dropFirst().first { args["url"] = url }
            if sub == "switch" || sub == "close", let id = rest.dropFirst().first { args["id"] = id }
            output = await call("browser_tabs", args)
        case "wait":
            guard let kind = rest.first else { print("Usage: mca browser wait load|text|selector|ms <value>"); exit(2) }
            output = await call("browser_wait", ["for": kind, "value": rest.dropFirst().joined(separator: " ")])
        case "eval", "evaluate", "js":
            output = await call("browser_evaluate", ["expression": rest.joined(separator: " ")])
        default:
            FileHandle.standardError.write(Data("Unknown browser command '\(command)'\n\n".utf8))
            print(usage)
            exit(2)
        }

        print(output)
        await persistTab(session: session)
        if output.hasPrefix("Error:") { exit(1) }
    }

    private static func looksLikeRef(_ text: String) -> Bool {
        let normalized = BrowserSession.normalizeRef(text)
        let parts = normalized.split(separator: "-")
        return parts.count == 2 && parts.allSatisfy { Int($0) != nil }
    }

    private static func reclaimTab(session: BrowserSession) async {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              let targetID = state.targetID,
              let driver = try? await session.driver() else { return }
        if let tabs = try? await driver.tabs(), tabs.contains(where: { $0.id == targetID }) {
            try? await driver.switchTab(id: targetID)
        }
    }

    private static func persistTab(session: BrowserSession) async {
        guard let driver = try? await session.driver(), let tabs = try? await driver.tabs() else { return }
        let state = State(targetID: tabs.first(where: \.isActive)?.id)
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL) }
    }
}
