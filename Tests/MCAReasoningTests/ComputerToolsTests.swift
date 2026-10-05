import Foundation
import Testing
@testable import MCACore
@testable import MCAReasoning
@testable import MCASensing

@Suite("ComputerTools tests")
struct ComputerToolsTests {
    @Test("ComputerActionTool defines correct schema")
    func testComputerActionDefinition() {
        let tool = ComputerActionTool()
        #expect(tool.definition.name == "computer")
        #expect(!tool.definition.description.isEmpty)

        let parsed = (try? JSONSerialization.jsonObject(with: tool.definition.parameters)) as? [String: Any]
        #expect(parsed?["type"] as? String == "object")
        let properties = parsed?["properties"] as? [String: Any]
        #expect(properties?["action"] != nil)
        #expect(properties?["coordinate"] != nil)
        #expect(properties?["delta_y"] != nil)
        #expect(properties?["delta_x"] != nil)
        #expect(properties?["text"] != nil)
        #expect(properties?["key"] != nil)
    }

    @Test("ComputerActionTool executes or validates scroll action")
    func testComputerActionScroll() async throws {
        let tool = ComputerActionTool()
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await tool.invoke(arguments: Data(#"{"action": "scroll", "delta_y": -10}"#.utf8))
        }
    }

    @Test("ComputerActionTool validates required action parameter")
    func testComputerActionRequiresAction() async throws {
        let tool = ComputerActionTool()
        let result = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(result.contains("Error: 'action' parameter is required"))
    }

    @Test("ComputerActionTool rejects unsupported action")
    func testComputerActionUnsupportedAction() async throws {
        let tool = ComputerActionTool()
        let payload = """
        {"action": "unsupported_fly_away"}
        """
        let result = try await tool.invoke(arguments: Data(payload.utf8))
        #expect(result.contains("Error: Unsupported action 'unsupported_fly_away'"))
    }

    @Test("ComputerActionTool validates arguments for mouse_move, type, and key")
    func testComputerActionArgumentValidation() async throws {
        let tool = ComputerActionTool()

        let moveNoCoord = try await tool.invoke(arguments: Data(#"{"action": "mouse_move"}"#.utf8))
        #expect(moveNoCoord.contains("Error: 'coordinate' [x, y] is required"))

        let typeNoText = try await tool.invoke(arguments: Data(#"{"action": "type"}"#.utf8))
        #expect(typeNoText.contains("Error: 'text' parameter is required"))

        let keyNoKey = try await tool.invoke(arguments: Data(#"{"action": "key"}"#.utf8))
        #expect(keyNoKey.contains("Error: 'key' parameter is required"))

        let dragMissing = try await tool.invoke(arguments: Data(#"{"action": "left_click_drag", "coordinate": [10, 20]}"#.utf8))
        #expect(dragMissing.contains("Error: Both 'start_coordinate' and 'coordinate' are required"))
    }

    @Test("ClickElementTool defines correct schema and validates arguments")
    func testClickElementTool() async throws {
        let tool = ClickElementTool()
        #expect(tool.definition.name == "click_element")

        let noArg = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(noArg.contains("Error: 'element_text' parameter is required"))

        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await tool.invoke(arguments: Data(#"{"element_text": "OK", "app_name": "NonExistentApp12345"}"#.utf8))
        }
    }

    @Test("RunAppleScriptTool requires approval even for apparently harmless scripts")
    func testRunAppleScriptTool() async throws {
        let tool = RunAppleScriptTool()
        #expect(tool.definition.name == "run_applescript")

        let empty = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(empty.contains("Error: 'script' parameter is required"))

        let result = try await tool.invoke(arguments: Data(#"{"script": "return 100 + 42"}"#.utf8))
        #expect(result.contains("approval_required"))
        #expect(result.contains("'run_applescript' was NOT run"))
        #expect(result != "142")

        // A legacy opt-in cannot bypass the selected-target requirement in chat.
        let session = ActionAuthorization(goal: "Run script", requestApproval: { _ in
            Issue.record("An unscoped script must not present an approval card")
            return .approved
        })
        try await ActionAuthorization.withSession(session) {
            await #expect(throws: ActionAuthorizationError.staleTarget) {
                try await RunAppleScriptTool(approver: AutoApproveToolApprover()).invoke(
                    arguments: Data(#"{"script": "return 100 + 42"}"#.utf8))
            }
        }
    }

    @Test("InspectUIElementsTool defines correct schema and invokes inspector")
    func testInspectUIElementsTool() async throws {
        let candidate = UIElementCandidate(id: "fixture-button", role: "AXButton", label: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 40, height: 30))
        let inspector = MockUIInspector(snapshots: [UIStateSnapshot(visibleCandidates: [candidate], timestamp: .now)])
        let tool = InspectUIElementsTool(inspectorProvider: { maxCandidates in
            #expect(maxCandidates == 5)
            return inspector
        })
        #expect(tool.definition.name == "inspect_ui_elements")
        #expect(!tool.definition.description.isEmpty)

        let result = try await tool.invoke(arguments: Data(#"{"max_candidates": 5}"#.utf8))
        // Should return valid JSON array string
        #expect(result.starts(with: "[") || result.contains("["))
        let decoded = try JSONDecoder().decode([UIElementCandidate].self, from: Data(result.utf8))
        #expect(decoded == [candidate])
    }

    @Test("TypeSafeActTool defines schema and validates goal requirement")
    func testTypeSafeActTool() async throws {
        // Schema/summary validation must never inspect or actuate the live desktop.
        let inspector = MockUIInspector(snapshots: [UIStateSnapshot(visibleCandidates: [], timestamp: .now)])
        let tool = TypeSafeActTool(inspectorProvider: { _ in inspector })
        #expect(tool.definition.name == "typesafe_act")
        #expect(!tool.definition.description.isEmpty)

        let emptyResult = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(emptyResult.contains("Error: 'goal' parameter is required"))

        // Invoking with valid goal returns a structured action summary
        let result = try await tool.invoke(arguments: Data(#"{"goal": "Click Search button"}"#.utf8))
        #expect(result.contains("Action: none"))
        #expect(result.contains("Confidence: 0.00"))
    }

    @Test("TypeSafeActTool refuses an actual click decision without a presenter")
    func testTypeSafeActionRequiresApproval() async throws {
        let candidate = UIElementCandidate(id: "search", role: "button", label: "Search", value: nil,
            bounds: CGRect(x: 100, y: 100, width: 50, height: 30), isActionable: true, source: .accessibility)
        let inspector = MockUIInspector(snapshots: [UIStateSnapshot(visibleCandidates: [candidate], timestamp: .now)])
        let evaluator = MockTypeSafeEvaluator.scripted(targetChoice: "search", actionChoice: "click")
        let tool = TypeSafeActTool(inspectorProvider: { _ in inspector }, engineProvider: { TypeSafeDecisionEngine(client: evaluator) })
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await ActionAuthorization.$current.withValue(nil) {
                try await tool.invoke(arguments: Data(#"{"goal":"Click Search"}"#.utf8))
            }
        }
        #expect(evaluator.recordedRequests.count == 1)
    }

    @Test("FindFilesTool defines schema and validates query requirement")
    func testFindFilesTool() async throws {
        let tool = FindFilesTool()
        #expect(tool.definition.name == "find_files")
        #expect(!tool.definition.description.isEmpty)

        let emptyResult = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(emptyResult.contains("Error: 'query' parameter is required"))

        // Search for Package.swift in repo root
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let result = try await tool.invoke(arguments: Data(#"{"query": "Package.swift", "search_path": "\#(repoRoot)"}"#.utf8))
        #expect(result.contains("Package.swift") || result.contains("Found"))
    }

    @Test("OpenFileTool defines schema and validates parameter requirement")
    func testOpenFileTool() async throws {
        let tool = OpenFileTool()
        #expect(tool.definition.name == "open_file")
        #expect(!tool.definition.description.isEmpty)

        let emptyResult = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(emptyResult.contains("Error: 'file_path' parameter is required"))
    }

    @Test("WriteFileTool creates, overwrites, and appends text to file")
    func testWriteFileTool() async throws {
        let tool = WriteFileTool(approver: AutoApproveToolApprover())
        #expect(tool.definition.name == "write_file")

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-test-file-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        // 1. Initial write
        let creation = ActionAuthorization(goal: "Save notes", requestApproval: { _ in .approved })
        let writeResult = try await ActionAuthorization.$current.withValue(creation) {
            try await tool.invoke(arguments: Data(#"{"file_path": "\#(tempFile)", "content": "Hello MCA"}"#.utf8))
        }
        #expect(writeResult.contains("Successfully wrote"))
        let content1 = try? String(contentsOfFile: tempFile, encoding: .utf8)
        #expect(content1 == "Hello MCA")

        // 2. Append text
        let authorization = ActionAuthorization(goal: "Append test output", requestApproval: { _ in .approved })
        let appendResult = try await ActionAuthorization.$current.withValue(authorization) {
            try await tool.invoke(arguments: Data(#"{"file_path": "\#(tempFile)", "content": " - Appended", "mode": "append"}"#.utf8))
        }
        #expect(appendResult.contains("Successfully appended"))
        let content2 = try? String(contentsOfFile: tempFile, encoding: .utf8)
        #expect(content2 == "Hello MCA - Appended")
    }

    @Test("ScrollPinnedWindowTool defines correct schema and properties")
    func testScrollPinnedWindowToolSchema() {
        let tool = ScrollPinnedWindowTool()
        #expect(tool.definition.name == "scroll_pinned_window")
        #expect(!tool.definition.description.isEmpty)

        let parsed = (try? JSONSerialization.jsonObject(with: tool.definition.parameters)) as? [String: Any]
        #expect(parsed?["type"] as? String == "object")
        let properties = parsed?["properties"] as? [String: Any]
        #expect(properties?["steps"] != nil)
        #expect(properties?["delta_y"] != nil)
        #expect(properties?["delay_ms"] != nil)
        #expect(properties?["app_name"] != nil)
    }

    @Test("ScrollPageContentTool defines schema and passes app_name to collector")
    func testScrollPageContentTool() async throws {
        let tool = ScrollPageContentTool(name: "scroll_page_content", collector: { steps, deltaY, delayMs, appName in
            return "Target app: \(appName ?? "auto"), steps: \(steps)"
        })
        #expect(tool.definition.name == "scroll_page_content")
        let result = try await tool.invoke(arguments: Data(#"{"steps": 5, "app_name": "Google Chrome"}"#.utf8))
        #expect(result.contains("Target app: Google Chrome, steps: 5"))
    }

    @Test("ScrollPinnedWindowTool invokes background collector handler correctly")
    func testScrollPinnedWindowToolInvocation() async throws {
        // 1. When collector is configured
        let toolWithCollector = ScrollPinnedWindowTool(collector: { steps, deltaY, delayMs in
            return "Collected \(steps) steps with deltaY \(deltaY)"
        })
        let result = try await toolWithCollector.invoke(arguments: Data(#"{"steps": 4, "delta_y": -15}"#.utf8))
        #expect(result.contains("Collected 4 steps with deltaY -15"))

        // 2. When collector is unconfigured
        let unconfiguredTool = ScrollPinnedWindowTool()
        let unconfiguredResult = try await unconfiguredTool.invoke(arguments: Data("{}".utf8))
        #expect(unconfiguredResult.contains("Error: Background scrolling collector is not configured"))
    }

    @Test("ComputerActionTool supports background target_pid scroll")
    func testComputerActionBackgroundScroll() async throws {
        let tool = ComputerActionTool()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await tool.invoke(arguments: Data(#"{"action": "scroll", "delta_y": -5, "target_pid": \#(ownPID)}"#.utf8))
        }
    }

    @Test("InspectUIElementsTool defines schema and uses inspectorProvider")
    func testInspectUIElementsToolWithOCRFallback() async throws {
        let candidate = UIElementCandidate(
            id: "ocr_1",
            role: "button",
            label: "Search",
            value: nil,
            bounds: CGRect(x: 10, y: 10, width: 50, height: 25),
            isActionable: true,
            source: .ocr
        )

        let inspector = InspectUIElementsTool.makeDefaultInspector(maxCandidates: 15)
        #expect(inspector.maxCandidates == 15)

        let tool = InspectUIElementsTool(candidateProvider: { _ in [candidate] })

        #expect(tool.definition.name == "inspect_ui_elements")
        let res = try await tool.invoke(arguments: Data("{}".utf8))
        let decoded = try JSONDecoder().decode([UIElementCandidate].self, from: Data(res.utf8))
        #expect(decoded == [candidate])
    }

    @Test("TypeSafeActTool validates goal parameter")
    func testTypeSafeActToolValidation() async throws {
        let tool = TypeSafeActTool()
        #expect(tool.definition.name == "typesafe_act")
        let res = try await tool.invoke(arguments: Data("{}".utf8))
        #expect(res.contains("Error: 'goal' parameter is required."))
    }
}
