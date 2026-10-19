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
    }

    /// GitHub's macOS runners ship with Spotlight indexing off, so `mdfind` finds nothing there
    /// and the search runs into its timeout. The CI environment sets `CI=true`.
    @Test(
        "FindFilesTool finds Package.swift through Spotlight",
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "Spotlight is not indexed on CI runners")
    )
    func testFindFilesToolSpotlightSearch() async throws {
        let tool = FindFilesTool()
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

    @Test("TypeSafeActTool executes click-then-type, double-click, right-click, and scroll")
    func testTypeSafeActToolExecutesAllActionKinds() async throws {
        let searchBox = UIElementCandidate(
            id: "search_input",
            role: "AXTextField",
            label: "Search",
            value: nil,
            bounds: CGRect(x: 100, y: 200, width: 200, height: 40),
            isActionable: true,
            source: .accessibility
        )
        let scrollArea = UIElementCandidate(
            id: "scroll_main",
            role: "AXScrollArea",
            label: "Main Content",
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isActionable: true,
            source: .accessibility
        )
        let snapshot = UIStateSnapshot(visibleCandidates: [searchBox, scrollArea], timestamp: .now)
        let synthesizer = MockEventSynthesizer(isSimulation: true)

        // 1. Type text into searchBox: should click target center (200, 220) first, then type text
        let typeEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "search_input",
            actionChoice: "type",
            textInput: "hello world"
        )
        let typeTool = TypeSafeActTool(
            inspectorProvider: { _ in MockUIInspector(snapshots: [snapshot]) },
            engineProvider: { TypeSafeDecisionEngine(client: typeEvaluator) },
            synthesizer: synthesizer,
            approver: AutoApproveToolApprover()
        )
        let typeResult = try await ActionAuthorization.$current.withValue(nil) {
            try await typeTool.invoke(arguments: Data(#"{"goal": "Type hello world into Search"}"#.utf8))
        }
        #expect(typeResult.contains("typed 'hello world'"))
        #expect(synthesizer.recordedEvents == [
            .click(point: CGPoint(x: 200, y: 220), button: .left, clickCount: 1),
            .typeText("hello world")
        ])

        // 2. Scroll action: should scroll at scroll container center (400, 300)
        synthesizer.reset()
        let scrollEvaluator = MockTypeSafeEvaluator.scripted(
            targetChoice: "scroll_main",
            actionChoice: "scroll"
        )
        let scrollTool = TypeSafeActTool(
            inspectorProvider: { _ in MockUIInspector(snapshots: [snapshot]) },
            engineProvider: { TypeSafeDecisionEngine(client: scrollEvaluator) },
            synthesizer: synthesizer,
            approver: AutoApproveToolApprover()
        )
        let scrollResult = try await ActionAuthorization.$current.withValue(nil) {
            try await scrollTool.invoke(arguments: Data(#"{"goal": "Scroll down the page"}"#.utf8))
        }
        #expect(scrollResult.contains("scrolled at 400, 300"))
        #expect(synthesizer.recordedEvents == [
            .scroll(deltaX: 0, deltaY: -15, point: CGPoint(x: 400, y: 300), targetPID: nil)
        ])
    }

    @Test("ReadFileTool reads text files, supports max_characters truncation, and pairs with WriteFileTool for proofreading")
    func testReadFileToolAndProofreadRoundtrip() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-readfile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let draftURL = tempRoot.appendingPathComponent("draft.md")
        try "誤字のある文章です。確認おねがいします。".write(to: draftURL, atomically: true, encoding: .utf8)

        let readTool = ReadFileTool(home: tempRoot)
        let writeTool = WriteFileTool(approver: AutoApproveToolApprover(), home: tempRoot)

        let readOutput = try await readTool.invoke(
            arguments: Data("{\"file_path\": \"\(draftURL.path)\"}".utf8)
        )
        #expect(readOutput.contains("誤字のある文章です。確認おねがいします。"))

        // Truncation check (clamped minimum 100 chars)
        let longURL = tempRoot.appendingPathComponent("long.txt")
        try String(repeating: "あ", count: 250).write(to: longURL, atomically: true, encoding: .utf8)
        let truncatedOutput = try await readTool.invoke(
            arguments: Data("{\"file_path\": \"\(longURL.path)\", \"max_characters\": 120}".utf8)
        )
        #expect(truncatedOutput.contains("showing first 120 of 250 characters"))

        // Proofread and write back
        let revisedText = "修正済みの文章です。ご確認をお願いいたします。"
        let writeOutput = try await ActionAuthorization.$current.withValue(nil) {
            try await writeTool.invoke(
                arguments: Data("{\"file_path\": \"\(draftURL.path)\", \"content\": \"\(revisedText)\", \"mode\": \"overwrite\"}".utf8)
            )
        }
        #expect(writeOutput.contains("Successfully wrote"))

        let rereadOutput = try await readTool.invoke(
            arguments: Data("{\"file_path\": \"\(draftURL.path)\"}".utf8)
        )
        #expect(rereadOutput.contains(revisedText))
    }

    @Test("ReadFileTool refuses sensitive paths, symlinks, and binary files")
    func testReadFileToolSecurityBoundaries() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-readfile-sec-\(UUID().uuidString)")
        let sshDir = tempHome.appendingPathComponent(".ssh")
        let projectDir = tempHome.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let keyURL = sshDir.appendingPathComponent("id_ed25519")
        try "PRIVATE_KEY".write(to: keyURL, atomically: true, encoding: .utf8)

        let envURL = projectDir.appendingPathComponent(".env")
        try "SECRET_TOKEN=xyz".write(to: envURL, atomically: true, encoding: .utf8)

        let envExampleURL = projectDir.appendingPathComponent(".env.example")
        try "SECRET_TOKEN=placeholder".write(to: envExampleURL, atomically: true, encoding: .utf8)

        let normalURL = projectDir.appendingPathComponent("note.txt")
        try "safe content".write(to: normalURL, atomically: true, encoding: .utf8)

        let symlinkURL = projectDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: normalURL)

        let binaryURL = projectDir.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: binaryURL)

        let readTool = ReadFileTool(home: tempHome)

        // 1. ~/.ssh/id_ed25519 denied by FileWritePolicy
        let sshResult = try await readTool.invoke(arguments: Data("{\"file_path\": \"\(keyURL.path)\"}".utf8))
        #expect(sshResult.contains("is not allowed"))

        // 2. ~/project/.env denied by sensitiveReadReason
        let envResult = try await readTool.invoke(arguments: Data("{\"file_path\": \"\(envURL.path)\"}".utf8))
        #expect(envResult.contains("is not allowed"))

        // 3. ~/project/.env.example is allowed
        let exampleResult = try await readTool.invoke(arguments: Data("{\"file_path\": \"\(envExampleURL.path)\"}".utf8))
        #expect(exampleResult.contains("SECRET_TOKEN=placeholder"))

        // 4. Symlink is refused by GuardedFileWriter.readRegularFile (O_NOFOLLOW)
        let symlinkResult = try await readTool.invoke(arguments: Data("{\"file_path\": \"\(symlinkURL.path)\"}".utf8))
        #expect(symlinkResult.contains("could not be read safely"))

        // 5. Binary file with NUL bytes is refused
        let binaryResult = try await readTool.invoke(arguments: Data("{\"file_path\": \"\(binaryURL.path)\"}".utf8))
        #expect(binaryResult.contains("binary file"))
    }
}
