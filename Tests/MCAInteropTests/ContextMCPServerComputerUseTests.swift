import CoreGraphics
import Foundation
import MCACore
import MCAReasoning
import MCASensing
import MCP
import Testing

@testable import MCAInterop

private struct FixedScreenshots: ScreenshotProviding {
    let screenshot: ComputerScreenshot
    func captureMainDisplay() async throws -> ComputerScreenshot { screenshot }
    func captureRegion(_ region: CGRect) async throws -> ComputerScreenshot {
        ComputerScreenshot(
            jpeg: Data([0xFF, 0xD8, 0x09]), width: 200, height: 100,
            displayPoints: screenshot.displayPoints, region: region)
    }
}

private struct BrokenScreenshots: ScreenshotProviding {
    func captureMainDisplay() async throws -> ComputerScreenshot {
        throw ScreenCapturer.CaptureError.permissionDenied
    }
}

/// `computer` as the MCP server drives it, over a recording synthesizer and a fixed picture.
@Suite("MCP computer use")
struct ContextMCPServerComputerUseTests {
    private let store = MockContextStore()
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])

    private func computer(
        synthesizer: DryRunEventSynthesizer = DryRunEventSynthesizer(),
        displayPoints: CGSize = CGSize(width: 1000, height: 500),
        width: Int = 500
    ) -> ComputerActionTool {
        ComputerActionTool(
            synthesizer: synthesizer, approver: AutoApproveToolApprover(),
            screenshots: FixedScreenshots(screenshot: ComputerScreenshot(
                jpeg: jpeg, width: width, height: width / 2, displayPoints: displayPoints)),
            screenSpace: ComputerScreenSpace(), trustsCallerApproval: true)
    }

    private func allowListed() -> any ToolApproving {
        AllowListToolApprover(
            allowing: ContextMCPServer.computerUseTools, otherwise: ContextMCPServer.defaultApprover)
    }

    private func text(_ content: [MCP.Tool.Content]) -> String {
        content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }.joined(separator: "\n")
    }

    @Test("screenshot returns the image and the coordinate-space note")
    func screenshotReturnsImage() async throws {
        let content = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("screenshot")], store: store,
            approver: AutoApproveToolApprover(), computerTool: computer())

        #expect(content.count == 2)
        guard case .image(let data, let mimeType, _, _) = content[0] else {
            Issue.record("first content item is not an image: \(content)")
            return
        }
        #expect(mimeType == "image/jpeg")
        #expect(Data(base64Encoded: data) == jpeg)
        #expect(text(content).contains("500x250 px"))
        #expect(text(content).contains("1000x500 points"))
    }

    @Test("screenshot is refused by default and no capture happens")
    func screenshotDefaultDeny() async throws {
        let content = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("screenshot")], store: store,
            computerTool: ComputerActionTool(screenshots: BrokenScreenshots()))
        #expect(content.count == 1)
        #expect(text(content).contains("was NOT run"))
        // A capture would have thrown permissionDenied instead of reaching the refusal text.
        #expect(!text(content).contains("Screenshot failed"))
    }

    @Test("a capture failure reaches the client as an error that names the cause")
    func screenshotFailure() async throws {
        let failing = ComputerActionTool(
            screenshots: BrokenScreenshots(), screenSpace: ComputerScreenSpace(), trustsCallerApproval: true)
        await #expect(throws: ScreenshotError.self) {
            _ = try await ContextMCPServer.dispatchContent(
                name: "computer", arguments: ["action": .string("screenshot")], store: store,
                approver: AutoApproveToolApprover(), computerTool: failing)
        }
    }

    @Test("a screenshot sets the space in which the next click is read")
    func clickAfterScreenshotIsMapped() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = computer(synthesizer: synthesizer)   // 500 px wide picture of a 1000-point display
        _ = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("screenshot")], store: store,
            approver: AutoApproveToolApprover(), computerTool: tool)
        let result = try await ContextMCPServer.dispatch(
            name: "computer",
            arguments: ["action": .string("left_click"), "coordinate": .array([.int(100), .int(40)])],
            store: store, approver: AutoApproveToolApprover(), computerTool: tool)
        #expect(result.hasPrefix("Left clicked"))
        #expect(synthesizer.recordedActions == ["click(at: (200, 80), button: left, clickCount: 1)"])
    }

    @Test("--computer-use lets the screen and the mouse and keyboard through")
    func computerUseAllowsComputer() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = computer(synthesizer: synthesizer)
        let click = try await ContextMCPServer.dispatch(
            name: "computer",
            arguments: ["action": .string("left_click"), "coordinate": .array([.int(10), .int(10)])],
            store: store, approver: allowListed(), computerTool: tool)
        let typed = try await ContextMCPServer.dispatch(
            name: "computer", arguments: ["action": .string("type"), "text": .string("hello")],
            store: store, approver: allowListed(), computerTool: tool)
        #expect(click.hasPrefix("Left clicked"), "\(click)")
        #expect(typed == "Typed 5 characters.")
        #expect(synthesizer.recordedActions.count == 2)

        let shot = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("screenshot")], store: store,
            approver: allowListed(), computerTool: tool)
        #expect(shot.count == 2)
    }

    @Test("--computer-use does not let anything else act", arguments: [
        ("run_applescript", ["script": Value.string("return 1")]),
        ("click_element", ["element_text": .string("OK")]),
        ("typesafe_act", ["goal": .string("click OK")]),
        ("autonomous_act", ["goal": .string("delete everything")]),
    ])
    func computerUseAllowsNothingElse(name: String, arguments: [String: Value]) async throws {
        let result = try await ContextMCPServer.dispatch(
            name: name, arguments: arguments, store: store, approver: allowListed(),
            computerTool: computer())
        #expect(result.contains("was NOT run"), "\(name): \(result)")
    }

    @Test("without an opt-in the computer tool still sends nothing")
    func defaultStillDenies() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let result = try await ContextMCPServer.dispatch(
            name: "computer",
            arguments: ["action": .string("left_click"), "coordinate": .array([.int(1), .int(1)])],
            store: store, computerTool: computer(synthesizer: synthesizer))
        #expect(result.contains("was NOT run"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("wait is served through the same gate")
    func waitThroughGate() async throws {
        let denied = try await ContextMCPServer.dispatch(
            name: "computer", arguments: ["action": .string("wait"), "duration": .int(0)],
            store: store, computerTool: computer())
        #expect(denied.contains("was NOT run"))
        let allowed = try await ContextMCPServer.dispatch(
            name: "computer", arguments: ["action": .string("wait"), "duration": .int(0)],
            store: store, approver: allowListed(), computerTool: computer())
        #expect(allowed == "Waited 0.0 seconds.")
    }

    @Test("the published schema lists the standard actions, with an enum and the standard parameters")
    func schemaAdvertisesStandardActions() {
        let computer = ContextMCPServer.toolDefinitions.first { $0.name == "computer" }
        guard case .object(let schema) = computer?.inputSchema,
              case .object(let props) = schema["properties"],
              case .object(let action) = props["action"],
              case .string(let description) = action["description"],
              case .array(let enumValues) = action["enum"]
        else {
            Issue.record("Expected computer tool schema properties")
            return
        }
        for name in ["screenshot", "zoom", "left_mouse_down", "left_mouse_up", "hold_key", "wait", "scroll"] {
            #expect(description.contains(name), "\(name) missing from the action description")
            #expect(enumValues.contains(.string(name)), "\(name) missing from the action enum")
        }
        for parameter in ["duration", "region", "scroll_direction", "scroll_amount", "repeat", "text", "coordinate", "start_coordinate"] {
            #expect(props[parameter] != nil, "\(parameter) missing from the schema")
        }
        #expect(computer?.description?.contains("screenshot") == true)
    }

    @Test("every published action is one the tool implements")
    func publishedActionsAreImplemented() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = computer(synthesizer: synthesizer)
        for action in ContextMCPServer.computerActions {
            let result = try await tool.invoke(arguments: Data(#"{"action":"\#(action)"}"#.utf8))
            #expect(!result.contains("Unsupported action"), "\(action): \(result)")
        }
    }

    @Test("zoom returns the region as an image and says it is not a new coordinate space")
    func zoomReturnsImage() async throws {
        let content = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("zoom"), "region": .array([.int(0), .int(0), .int(100), .int(50)])],
            store: store, approver: AutoApproveToolApprover(), computerTool: computer())
        guard case .image(let data, let mimeType, _, _) = content.first else {
            Issue.record("zoom did not return an image: \(content)")
            return
        }
        #expect(mimeType == "image/jpeg")
        #expect(Data(base64Encoded: data) == Data([0xFF, 0xD8, 0x09]))
        #expect(text(content).contains("Zoom on region"))
        #expect(text(content).contains("full screenshot"))
    }

    @Test("zoom is refused by default like a screenshot")
    func zoomDefaultDeny() async throws {
        let content = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("zoom"), "region": .array([.int(0), .int(0), .int(9), .int(9)])],
            store: store, computerTool: computer())
        #expect(text(content).contains("was NOT run"))
    }

    @Test("failures are flagged isError, results are not")
    func errorFlag() {
        #expect(ContextMCPServer.reportsError([.text(text: "Error: approval_required: x", annotations: nil, _meta: nil)]))
        #expect(!ContextMCPServer.reportsError([.text(text: "Left clicked at (1, 2).", annotations: nil, _meta: nil)]))
        #expect(!ContextMCPServer.reportsError([.image(data: "AA==", mimeType: "image/jpeg", annotations: nil, _meta: nil)]))
        #expect(!ContextMCPServer.reportsError([]))
    }

    @Test("a click lands on the element inspect_ui_elements reported, whatever the scale")
    func inspectThenClick() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = computer(synthesizer: synthesizer)   // 500 px picture of a 1000-point display: 0.5
        _ = try await ContextMCPServer.dispatchContent(
            name: "computer", arguments: ["action": .string("screenshot")], store: store,
            approver: AutoApproveToolApprover(), computerTool: tool)
        let element = UIElementCandidate(id: "b", role: "AXButton", label: "Go", bounds: CGRect(x: 600, y: 300, width: 100, height: 50))
        let inspected = try await InspectUIElementsTool(candidateProvider: { _ in [element] }, screenSpace: tool.coordinateSpace)
            .invoke(arguments: Data("{}".utf8))
        let center = try #require(
            try JSONDecoder().decode([UIElementCandidate].self, from: Data(inspected.utf8)).first?.center)
        _ = try await ContextMCPServer.dispatch(
            name: "computer",
            arguments: ["action": .string("left_click"), "coordinate": .array([.double(center.x), .double(center.y)])],
            store: store, approver: AutoApproveToolApprover(), computerTool: tool)
        #expect(synthesizer.recordedActions == ["click(at: (650, 325), button: left, clickCount: 1)"])
    }

    @Test("computer-use opt-in names only the computer tool")
    func computerUseToolSet() {
        #expect(ContextMCPServer.computerUseTools == ["computer"])
    }
}
