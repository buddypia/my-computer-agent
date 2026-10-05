import Foundation
import MCACore
import MCAReasoning
import MCASensing
import MCP
import Testing

@testable import MCAInterop

final class McpRecordingApprover: ToolApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolApprovalRequest] = []

    static func denying() -> McpRecordingApprover { McpRecordingApprover() }

    var requests: [ToolApprovalRequest] {
        lock.withLock { recorded }
    }

    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        lock.withLock { recorded.append(request) }
        return .denied(reason: "test denies")
    }
}

/// Stands in for a browser tool: records whether its body ran.
private final class StubBrowserTool: AgentTool, @unchecked Sendable {
    let definition: ToolDefinition
    private let lock = NSLock()
    private var runs = 0

    init(_ name: String) {
        definition = ToolDefinition(name: name, description: "stub", parameters: Data("{}".utf8))
    }

    var invocations: Int { lock.withLock { runs } }

    func invoke(arguments: Data) async throws -> String {
        lock.withLock { runs += 1 }
        return "ran"
    }
}

@Suite("MCP browser tool approval")
struct ContextMCPServerBrowserApprovalTests {
    private func json(_ object: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("browser tools that act on the page are denied by default and do not run", arguments: [
        ("browser_navigate", ["url": "https://example.com"]),
        ("browser_element", ["action": "click", "ref": "0-1"]),
        ("browser_element", ["action": "fill", "ref": "0-1", "value": "x"]),
        ("browser_element", ["action": "type", "value": "x"]),
        ("browser_act", ["instruction": "click the buy button"]),
        ("browser_tabs", ["action": "new", "url": "https://example.com"]),
        ("browser_tabs", ["action": "switch", "id": "A"]),
        ("browser_tabs", ["action": "close", "id": "A"]),
    ])
    func actingBrowserToolsDefaultDeny(name: String, arguments: [String: String]) async throws {
        let tool = StubBrowserTool(name)
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: json(arguments), approver: ContextMCPServer.defaultApprover)
        #expect(result.contains("was NOT run"), "\(name): \(result)")
        #expect(result.contains("mcpAllowDangerousTools"))
        #expect(tool.invocations == 0)
    }

    @Test("the approver sees the browser request")
    func approverSeesRequest() async throws {
        let approver = McpRecordingApprover.denying()
        _ = try await ContextMCPServer.invokeExtraTool(
            StubBrowserTool("browser_navigate"), arguments: json(["url": "https://example.com"]),
            approver: approver)
        #expect(approver.requests.first?.toolName == "browser_navigate")
        #expect(approver.requests.first?.detail.contains("example.com") == true)
    }

    @Test("an opted-in approver lets browser actions run")
    func optIn() async throws {
        let tool = StubBrowserTool("browser_act")
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: json(["instruction": "click"]), approver: AutoApproveToolApprover())
        #expect(result == "ran")
        #expect(tool.invocations == 1)
    }

    @Test("reading tools and listing tabs never ask", arguments: [
        ("browser_snapshot", [String: String]()),
        ("browser_read", [:]),
        ("browser_observe", ["instruction": "find links"]),
        ("browser_extract", ["instruction": "title"]),
        ("browser_wait", ["for": "load"]),
        ("browser_tabs", ["action": "list"]),
        ("browser_tabs", [:]),
    ])
    func readingToolsDoNotAsk(name: String, arguments: [String: String]) async throws {
        let approver = McpRecordingApprover.denying()
        let tool = StubBrowserTool(name)
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: json(arguments), approver: approver)
        #expect(result == "ran")
        #expect(approver.requests.isEmpty)
    }
}

/// A driver that does nothing, so the real browser tools can be built and
/// called without a browser.
private actor InertBrowserDriver: BrowserDriving {
    nonisolated let kind: BrowserDriverKind = .devtools

    func connect() async throws {}
    func describeConnection() async -> String { "inert" }
    func snapshot(options: BrowserSnapshotOptions) async throws -> BrowserSnapshot {
        BrowserSnapshot(driver: .devtools, url: "https://example.test/", title: "Inert", outline: "", refs: [:])
    }
    func perform(_ action: BrowserAction, ref: BrowserElementRef?, target: BrowserElementRef?) async throws -> String { "did" }
    func navigate(to url: String, waitUntil: BrowserLoadState) async throws {}
    func goBack() async throws -> Bool { false }
    func goForward() async throws -> Bool { false }
    func reload() async throws {}
    func wait(for condition: BrowserWaitCondition, timeout: TimeInterval) async throws {}
    func currentPage() async throws -> (url: String, title: String) { ("https://example.test/", "Inert") }
    func pageText() async throws -> String { "text" }
    func screenshotPNG() async throws -> Data { Data([0x89, 0x50]) }
    func tabs() async throws -> [BrowserTab] { [] }
    func openTab(url: String) async throws -> BrowserTab { BrowserTab(id: "t", url: url, title: "", isActive: true) }
    func switchTab(id: String) async throws {}
    func closeTab(id: String) async throws {}
    func evaluate(_ expression: String) async throws -> String { "evaluated" }
}

@Suite("MCP browser tool gating fails closed")
struct ContextMCPServerBrowserGatingTests {
    /// The only extra tools that may run under default-deny. Adding a name here
    /// is a statement that the tool cannot act on a page or write a file: this
    /// list is deliberately duplicated in the test, so widening it in the
    /// source alone fails.
    private static let expectedReadOnly: Set<String> = [
        "browser_snapshot", "browser_observe", "browser_extract", "browser_wait",
        "browser_read", "browser_tabs",
    ]

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func realTools() -> [any AgentTool] {
        BrowserToolkit.tools(
            session: BrowserSession(drivers: [InertBrowserDriver()], inference: nil),
            approver: DenyAllToolApprover())
    }

    @Test("the read-only allowlist is exactly the reviewed set")
    func allowlistIsReviewed() {
        #expect(ContextMCPServer.readOnlyExtraTools == Self.expectedReadOnly)
    }

    @Test("every tool in the real browser toolkit is either allowlisted read-only or gated")
    func everyRealToolIsAllowlistedOrGated() async throws {
        let tools = realTools()
        #expect(!tools.isEmpty)
        for tool in tools {
            let name = tool.definition.name
            let approver = McpRecordingApprover.denying()
            // Empty arguments: the least a client can send. A tool that is not
            // read-only must be stopped before it looks at them.
            _ = try await ContextMCPServer.invokeExtraTool(tool, arguments: json([:]), approver: approver)
            if Self.expectedReadOnly.contains(name) {
                #expect(approver.requests.isEmpty, "\(name) is allowlisted but asked")
            } else {
                #expect(approver.requests.count == 1, "\(name) is neither allowlisted nor gated")
            }
        }
        // And nothing in the allowlist has gone stale.
        let names = Set(tools.map(\.definition.name))
        #expect(Self.expectedReadOnly.isSubset(of: names))
    }

    @Test("a tool nobody has classified is gated, not run")
    func unknownToolIsGated() async throws {
        let tool = StubBrowserTool("browser_future_tool")
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: json(["anything": "x"]), approver: ContextMCPServer.defaultApprover)
        #expect(result.contains("was NOT run"))
        #expect(tool.invocations == 0)
    }

    @Test("browser_evaluate and browser_element are gated under default-deny, whatever the arguments")
    func evaluateAndElementGated() async throws {
        for name in ["browser_evaluate", "browser_element"] {
            let tool = StubBrowserTool(name)
            let result = try await ContextMCPServer.invokeExtraTool(
                tool, arguments: json([:]), approver: ContextMCPServer.defaultApprover)
            #expect(result.contains("was NOT run"), "\(name)")
            #expect(tool.invocations == 0)
        }
    }

    @Test("browser_read is read-only only without a path", arguments: [
        (#"{"what":"screenshot","path":"~/Desktop/x.png"}"#, true),
        (#"{"what":"screenshot","path":""}"#, true),
        (#"{"what":"screenshot","path":7}"#, true),
        (#"{"what":"screenshot"}"#, false),
        (#"{"what":"text"}"#, false),
        ("{}", false),
    ])
    func browserReadPathIsGated(arguments: String, gated: Bool) async throws {
        let approver = McpRecordingApprover.denying()
        let tool = StubBrowserTool("browser_read")
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: Data(arguments.utf8), approver: approver)
        if gated {
            #expect(result.contains("was NOT run"))
            #expect(tool.invocations == 0)
        } else {
            #expect(result == "ran")
            #expect(approver.requests.isEmpty)
        }
    }

    @Test("browser_tabs is read-only only for the list action", arguments: [
        (#"{"action":"list"}"#, false),
        ("{}", false),
        (#"{"action":"new"}"#, true),
        (#"{"action":"close","id":"A"}"#, true),
        (#"{"action":"bogus"}"#, true),
        (#"{"action":3}"#, true),
    ])
    func browserTabsActionIsGated(arguments: String, gated: Bool) async throws {
        let approver = McpRecordingApprover.denying()
        let tool = StubBrowserTool("browser_tabs")
        let result = try await ContextMCPServer.invokeExtraTool(
            tool, arguments: Data(arguments.utf8), approver: approver)
        #expect((result != "ran") == gated)
        #expect(approver.requests.isEmpty == !gated)
    }

    @Test("a CallTool request is rerouted through the gate")
    func callToolReroute() async throws {
        let acting = StubBrowserTool("browser_act")
        let unlisted = StubBrowserTool("browser_future_tool")
        let reading = StubBrowserTool("browser_snapshot")
        let server = ContextMCPServer(
            store: MockContextStore(), extraTools: [acting, unlisted, reading],
            approver: ContextMCPServer.defaultApprover)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        func text(_ name: String) async throws -> String {
            let result = try await client.callTool(name: name, arguments: [:])
            guard case .text(let text, _, _) = result.content.first else { return "" }
            return text
        }
        let actingText = try await text("browser_act")
        let unlistedText = try await text("browser_future_tool")
        let readingText = try await text("browser_snapshot")

        await client.disconnect()
        await server.stop()

        #expect(actingText.contains("was NOT run"))
        #expect(unlistedText.contains("was NOT run"))
        #expect(readingText == "ran")
        #expect(acting.invocations == 0)
        #expect(unlisted.invocations == 0)
        #expect(reading.invocations == 1)
    }
}

@Suite("MCP dangerous tool approval")
struct ContextMCPServerApprovalTests {
    private let store = MockContextStore()

    private func marker() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-mcp-\(UUID().uuidString)").path
    }

    @Test("run_applescript is denied by default and does not execute")
    func appleScriptDefaultDeny() async throws {
        let path = marker()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ContextMCPServer.dispatch(
            name: "run_applescript",
            arguments: ["script": .string("do shell script \"touch \(path)\"")],
            store: store)
        #expect(result.contains("was NOT run"))
        #expect(result.contains("mcpAllowDangerousTools"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("run_applescript runs when the approver allows it")
    func appleScriptOptIn() async throws {
        let result = try await ContextMCPServer.dispatch(
            name: "run_applescript",
            arguments: ["script": .string("return 6 * 7")],
            store: store,
            approver: AutoApproveToolApprover())
        #expect(result == "42")
    }

    @Test("every tool that acts on the machine is denied by default", arguments: [
        ("computer", ["action": Value.string("key"), "text": .string("cmd+q")]),
        ("click_element", ["element_text": .string("OK")]),
        ("typesafe_act", ["goal": .string("click OK")]),
        ("autonomous_act", ["goal": .string("delete everything")]),
    ])
    func actingToolsDefaultDeny(name: String, arguments: [String: Value]) async throws {
        let result = try await ContextMCPServer.dispatch(name: name, arguments: arguments, store: store)
        #expect(result.contains("was NOT run"), "\(name): \(result)")
    }

    @Test("a denying approver is asked, and sees the request")
    func approverIsConsulted() async throws {
        let approver = McpRecordingApprover.denying()
        _ = try await ContextMCPServer.dispatch(
            name: "autonomous_act", arguments: ["goal": .string("open settings")],
            store: store, approver: approver)
        #expect(approver.requests.first?.toolName == "autonomous_act")
        #expect(approver.requests.first?.detail == "open settings")
    }

    @Test("autonomous_act in dry-run mode needs no approval")
    func dryRunNeedsNoApproval() async throws {
        let approver = McpRecordingApprover.denying()
        _ = try await ContextMCPServer.dispatch(
            name: "autonomous_act",
            arguments: ["goal": .string("look around"), "dry_run": .bool(true)],
            store: store,
            coordinatorFactory: { config, _ in
                TwoTierAutonomousLoopCoordinator(
                    planner: MockSystem2Planner(subgoals: [], shouldFail: false),
                    synthesizer: DryRunEventSynthesizer(),
                    config: config)
            },
            approver: approver)
        #expect(approver.requests.isEmpty)
    }

    @Test("read-only tools never ask")
    func readOnlyToolsDoNotAsk() async throws {
        let approver = McpRecordingApprover.denying()
        let result = try await ContextMCPServer.dispatch(
            name: "recent_activity", arguments: [:], store: store, approver: approver)
        #expect(!result.contains("was NOT run"))
        #expect(approver.requests.isEmpty)
    }
}
