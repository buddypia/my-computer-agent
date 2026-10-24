import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

/// Serves a fixed picture, so no test captures the real screen.
struct FixedScreenshotProvider: ScreenshotProviding {
    let screenshot: ComputerScreenshot

    func captureMainDisplay() async throws -> ComputerScreenshot { screenshot }
}

struct FailingScreenshotProvider: ScreenshotProviding {
    func captureMainDisplay() async throws -> ComputerScreenshot {
        throw ScreenCapturer.CaptureError.permissionDenied
    }
}

@Suite("Computer use: screenshot space")
struct ComputerScreenshotTests {
    /// A 1568-point display delivered at half size.
    private let shrunk = ComputerScreenshot(
        jpeg: Data([0xFF, 0xD8]), width: 784, height: 441,
        displayPoints: CGSize(width: 1568, height: 882))

    private func tool(
        screenshot: ComputerScreenshot? = nil,
        synthesizer: DryRunEventSynthesizer = DryRunEventSynthesizer(),
        space: ComputerScreenSpace = ComputerScreenSpace(),
        trustsCallerApproval: Bool = true
    ) -> ComputerActionTool {
        ComputerActionTool(
            synthesizer: synthesizer, approver: AutoApproveToolApprover(),
            screenshots: FixedScreenshotProvider(screenshot: screenshot ?? shrunk),
            screenSpace: space, trustsCallerApproval: trustsCallerApproval)
    }

    @Test("pixelsPerPoint is delivered width over display points; summary states both sizes")
    func scaleAndSummary() {
        #expect(shrunk.pixelsPerPoint == 0.5)
        #expect(shrunk.summary.contains("784x441"))
        #expect(shrunk.summary.contains("1568x882 points"))
        #expect(shrunk.summary.contains("0.500 px per point"))

        let native = ComputerScreenshot(
            jpeg: Data(), width: 1440, height: 900, displayPoints: CGSize(width: 1440, height: 900))
        #expect(native.pixelsPerPoint == 1)
        // A zero-width display must not produce a NaN factor.
        #expect(ComputerScreenshot(jpeg: Data(), width: 10, height: 10, displayPoints: .zero).pixelsPerPoint == 1)
    }

    @Test("the screen space starts as identity and round-trips through an adopted screenshot")
    func screenSpaceMapping() {
        let space = ComputerScreenSpace()
        #expect(space.screenPoint(fromImage: CGPoint(x: 10, y: 20)) == CGPoint(x: 10, y: 20))

        space.adopt(shrunk)
        #expect(space.screenPoint(fromImage: CGPoint(x: 100, y: 50)) == CGPoint(x: 200, y: 100))
        #expect(space.imagePoint(fromScreen: CGPoint(x: 200, y: 100)) == CGPoint(x: 100, y: 50))
    }

    @Test("an unusable screenshot does not change the mapping")
    func degenerateScreenshotIsIgnored() {
        let space = ComputerScreenSpace()
        space.adopt(shrunk)
        space.adopt(ComputerScreenshot(jpeg: Data(), width: 0, height: 0, displayPoints: CGSize(width: 100, height: 100)))
        #expect(space.pixelsPerPoint == 0.5)
    }

    @Test("clicks land on the screen point behind the screenshot pixel the model named")
    func clicksAreMappedBackToScreenPoints() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer: synthesizer)
        _ = try await tool.captureScreenshot()

        let result = try await tool.invoke(arguments: Data(#"{"action":"left_click","coordinate":[100,50]}"#.utf8))
        #expect(result.hasPrefix("Left clicked"))
        _ = try await tool.invoke(arguments: Data(#"{"action":"left_click_drag","start_coordinate":[10,10],"coordinate":[30,40]}"#.utf8))
        _ = try await tool.invoke(arguments: Data(#"{"action":"mouse_move","coordinate":[1,2]}"#.utf8))
        #expect(synthesizer.recordedActions == [
            "click(at: (200, 100), button: left, clickCount: 1)",
            "drag(from: (20, 20), to: (60, 80))",
            "mouseMove(to: (2, 4))",
        ])
    }

    @Test("without a screenshot coordinates are raw screen points, as before")
    func noScreenshotMeansIdentity() async throws {
        let synthesizer = DryRunEventSynthesizer()
        _ = try await tool(synthesizer: synthesizer)
            .invoke(arguments: Data(#"{"action":"left_click","coordinate":[100,50]}"#.utf8))
        #expect(synthesizer.recordedActions == ["click(at: (100, 50), button: left, clickCount: 1)"])
    }

    @Test("cursor_position is reported in screenshot pixels")
    func cursorPositionIsInImageSpace() async throws {
        let tool = tool()   // the recording synthesizer's cursor is at (100, 100)
        _ = try await tool.captureScreenshot()
        let result = try await tool.invoke(arguments: Data(#"{"action":"cursor_position"}"#.utf8))
        #expect(result == "Current cursor position: [50, 50].")
    }

    @Test("a coordinate that overflows once mapped is refused, not clamped")
    func mappedCoordinateOverflowIsRefused() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer: synthesizer)
        _ = try await tool.captureScreenshot()
        // 2e9 px is in range as an image coordinate but 4e9 points is not an Int32.
        let result = try await tool.invoke(arguments: Data(#"{"action":"mouse_move","coordinate":[2000000000,0]}"#.utf8))
        #expect(result.hasPrefix("Error:"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("a failed capture leaves the mapping alone and surfaces the error")
    func failedCapture() async throws {
        let space = ComputerScreenSpace()
        let tool = ComputerActionTool(
            synthesizer: DryRunEventSynthesizer(), screenshots: FailingScreenshotProvider(), screenSpace: space)
        await #expect(throws: ScreenCapturer.CaptureError.self) { _ = try await tool.captureScreenshot() }
        #expect(space.pixelsPerPoint == 1)
    }
}

@Suite("Computer use: caller-approved pointer actions")
struct ComputerCallerApprovalTests {
    @Test("pointer actions stay refused without a session unless the caller already approved")
    func failClosedByDefault() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = ComputerActionTool(synthesizer: synthesizer)
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await tool.invoke(arguments: Data(#"{"action":"left_click","coordinate":[1,1]}"#.utf8))
        }
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("a caller that approved the call replaces the missing session")
    func callerApprovalReplacesMissingSession() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = ComputerActionTool(synthesizer: synthesizer, trustsCallerApproval: true)
        _ = try await tool.invoke(arguments: Data(#"{"action":"double_click","coordinate":[7,9]}"#.utf8))
        #expect(synthesizer.recordedActions == ["click(at: (7, 9), button: left, clickCount: 2)"])
    }

    @Test("caller approval never overrides a session that exists")
    func sessionStillWins() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = ComputerActionTool(synthesizer: synthesizer, trustsCallerApproval: true)
        // A session with no selected window: the shared gate refuses before anything is sent.
        let session = ActionAuthorization(goal: "g", requestApproval: { _ in .approved })
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ActionAuthorization.withSession(session) {
                try await tool.invoke(arguments: Data(#"{"action":"left_click","coordinate":[1,1]}"#.utf8))
            }
        }
        #expect(synthesizer.recordedActions.isEmpty)
    }
}

@Suite("Computer use: wait and screenshot actions")
struct ComputerWaitTests {
    private func tool(_ synthesizer: DryRunEventSynthesizer = DryRunEventSynthesizer()) -> ComputerActionTool {
        ComputerActionTool(synthesizer: synthesizer)   // default approver and no session: nothing may be sent
    }

    @Test("wait needs no approval, sends nothing and reports the time waited")
    func waitIsHarmless() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let result = try await tool(synthesizer).invoke(arguments: Data(#"{"action":"wait","duration":0}"#.utf8))
        #expect(result == "Waited 0.0 seconds.")
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("wait rejects a duration that is not a non-negative number", arguments: [
        #"{"action":"wait","duration":-1}"#,
        #"{"action":"wait","duration":"soon"}"#,
        #"{"action":"wait","duration":true}"#,
    ])
    func waitValidatesDuration(payload: String) async throws {
        let result = try await tool().invoke(arguments: Data(payload.utf8))
        #expect(result.hasPrefix("Error: 'duration'"))
    }

    @Test("the longest wait is capped")
    func waitCap() {
        #expect(ComputerActionTool.maximumWaitSeconds == 10)
    }

    @Test("screenshot through invoke explains that the image needs an MCP client")
    func screenshotThroughInvoke() async throws {
        let result = try await tool().invoke(arguments: Data(#"{"action":"screenshot"}"#.utf8))
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("image"))
    }

    @Test("the in-app definition does not offer screenshot")
    func definitionUnchanged() throws {
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: ComputerActionTool().definition.parameters) as? [String: Any])
        let action = try #require((parsed["properties"] as? [String: Any])?["action"] as? [String: Any])
        let actions = try #require(action["enum"] as? [String])
        #expect(!actions.contains("screenshot"))
    }
}

@Suite("Computer use: allow-list approver")
struct AllowListToolApproverTests {
    private func request(_ tool: String) -> ToolApprovalRequest {
        ToolApprovalRequest(toolName: tool, title: "t", detail: "d")
    }

    @Test("named tools are approved and every other tool gets the fallback's answer")
    func allowsOnlyTheNamedTools() async {
        let approver = AllowListToolApprover(
            allowing: ["computer"], otherwise: DenyAllToolApprover(reason: "outside the list"))
        #expect(await approver.decide(request("computer")) == .approved)
        #expect(await approver.decide(request("run_applescript")) == .denied(reason: "outside the list"))
        #expect(await approver.decide(request("a_tool_added_later")) == .denied(reason: "outside the list"))
    }

    @Test("an empty list defers everything")
    func emptyList() async {
        let approver = AllowListToolApprover(allowing: [], otherwise: AutoApproveToolApprover())
        #expect(await approver.decide(request("anything")) == .approved)
    }
}
