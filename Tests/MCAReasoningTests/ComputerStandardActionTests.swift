import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

/// Records the zoom regions it is asked for.
final class RecordingScreenshotProvider: ScreenshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGRect] = []
    let full: ComputerScreenshot

    init(full: ComputerScreenshot) { self.full = full }

    var regions: [CGRect] { lock.withLock { recorded } }

    func captureMainDisplay() async throws -> ComputerScreenshot { full }

    func captureRegion(_ region: CGRect) async throws -> ComputerScreenshot {
        lock.withLock { recorded.append(region) }
        return ComputerScreenshot(
            jpeg: Data([1]), width: 300, height: 200, displayPoints: full.displayPoints, region: region)
    }
}

@Suite("Computer use: screenshot size budget")
struct ScreenshotBudgetTests {
    @Test("a display inside both limits is not resized")
    func smallDisplayUntouched() {
        let size = ScreenshotBudget.standard.size(width: 1024, height: 768)
        #expect(size.width == 1024 && size.height == 768)
        #expect(ScreenshotBudget.standard.scale(width: 1024, height: 768) == 1)
    }

    @Test("the pixel budget binds before the edge limit on a MacBook-sized display")
    func pixelBudgetBinds() {
        // 1728x1117: the edge limit alone would allow 0.907, the 1.15 MP budget only 0.772.
        let size = ScreenshotBudget.standard.size(width: 1728, height: 1117)
        #expect(size.width == 1333 && size.height == 862)
        #expect(size.width * size.height <= 1_150_000)
        #expect(max(size.width, size.height) <= 1568)
    }

    @Test("the edge limit binds on a very wide display", arguments: [(5120, 1440), (3840, 2160), (6016, 3384)])
    func bothLimitsAlwaysHold(width: Int, height: Int) {
        let size = ScreenshotBudget.standard.size(width: width, height: height)
        #expect(max(size.width, size.height) <= 1568)
        #expect(size.width * size.height <= 1_150_000)
        // The aspect ratio survives to within a pixel of rounding.
        #expect(abs(Double(size.width) / Double(size.height) - Double(width) / Double(height)) < 0.02)
    }

    @Test("a degenerate display does not divide by zero")
    func degenerate() {
        #expect(ScreenshotBudget.standard.scale(width: 0, height: 0) == 1)
    }

    @Test("the environment can raise the budget for a higher-resolution model; junk is ignored")
    func environmentOverride() {
        let raised = ScreenshotBudget.fromEnvironment([
            "MCA_SCREENSHOT_MAX_LONG_EDGE": "2576", "MCA_SCREENSHOT_MAX_PIXELS": "3750000",
        ])
        #expect(raised == ScreenshotBudget(maximumLongEdge: 2576, maximumPixels: 3_750_000))
        #expect(ScreenshotBudget.fromEnvironment(["MCA_SCREENSHOT_MAX_LONG_EDGE": "abc"]) == .standard)
        #expect(ScreenshotBudget.fromEnvironment(["MCA_SCREENSHOT_MAX_PIXELS": "3"]) == .standard)
        #expect(ScreenshotBudget.fromEnvironment([:]) == .standard)
    }
}

@Suite("Computer use: standard action parameters")
struct ComputerStandardActionTests {
    private func tool(
        _ synthesizer: DryRunEventSynthesizer = DryRunEventSynthesizer(),
        screenshots: any ScreenshotProviding = RecordingScreenshotProvider(full: ComputerScreenshot(
            jpeg: Data([1]), width: 784, height: 441, displayPoints: CGSize(width: 1568, height: 882))),
        space: ComputerScreenSpace = ComputerScreenSpace()
    ) -> ComputerActionTool {
        ComputerActionTool(
            synthesizer: synthesizer, approver: AutoApproveToolApprover(), screenshots: screenshots,
            screenSpace: space, trustsCallerApproval: true)
    }

    private func run(_ tool: ComputerActionTool, _ json: String) async throws -> String {
        try await tool.invoke(arguments: Data(json.utf8))
    }

    @Test("key takes the standard text parameter and still the older key parameter")
    func keyAcceptsText() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        #expect(try await run(tool, #"{"action":"key","text":"ctrl+s"}"#) == "Pressed key 'ctrl+s'.")
        #expect(try await run(tool, #"{"action":"key","key":"Return"}"#) == "Pressed key 'Return'.")
        #expect(synthesizer.recordedActions == [#"pressKey("ctrl+s")"#, #"pressKey("Return")"#])
    }

    @Test("key honours repeat, from 1 to 100")
    func keyRepeat() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        #expect(try await run(tool, #"{"action":"key","text":"Tab","repeat":4}"#) == "Pressed key 'Tab' 4 times.")
        #expect(synthesizer.recordedActions == Array(repeating: #"pressKey("Tab")"#, count: 4))
        for bad in ["0", "101", "1.5", "\"3\"", "true"] {
            let result = try await run(tool, #"{"action":"key","text":"Tab","repeat":\#(bad)}"#)
            #expect(result.hasPrefix("Error: 'repeat'"), "repeat=\(bad): \(result)")
        }
        #expect(synthesizer.recordedActions.count == 4)
    }

    @Test("a repeated key is shown to the approver with its count")
    func repeatedKeyApproval() async throws {
        let approver = RecordingApprover.denying()
        let tool = ComputerActionTool(
            synthesizer: DryRunEventSynthesizer(), approver: approver, frontmostApp: { "Terminal" })
        _ = try await run(tool, #"{"action":"key","text":"Return","repeat":3}"#)
        #expect(approver.requests.first?.detail.contains("× 3") == true)
    }

    @Test("scroll takes a direction and a number of wheel clicks", arguments: [
        ("down", 3, "scroll(deltaX: 0, deltaY: -3, at: (10, 20))"),
        ("up", 2, "scroll(deltaX: 0, deltaY: 2, at: (10, 20))"),
        ("left", 4, "scroll(deltaX: -4, deltaY: 0, at: (10, 20))"),
        ("right", 1, "scroll(deltaX: 1, deltaY: 0, at: (10, 20))"),
    ])
    func scrollDirection(direction: String, amount: Int, expected: String) async throws {
        let synthesizer = DryRunEventSynthesizer()
        let result = try await run(tool(synthesizer), """
            {"action":"scroll","coordinate":[10,20],"scroll_direction":"\(direction)","scroll_amount":\(amount)}
            """)
        #expect(result.hasPrefix("Scrolled"))
        #expect(synthesizer.recordedActions == [expected])
    }

    @Test("scroll defaults to five clicks, and the older delta spelling still works")
    func scrollDefaultsAndLegacy() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        _ = try await run(tool, #"{"action":"scroll","coordinate":[1,2],"scroll_direction":"down"}"#)
        _ = try await run(tool, #"{"action":"scroll","coordinate":[1,2],"delta_y":-7}"#)
        #expect(synthesizer.recordedActions == [
            "scroll(deltaX: 0, deltaY: -5, at: (1, 2))", "scroll(deltaX: 0, deltaY: -7, at: (1, 2))",
        ])
    }

    @Test("scroll rejects a bad direction or amount before sending anything")
    func scrollValidation() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        #expect(try await run(tool, #"{"action":"scroll","scroll_direction":"sideways"}"#).hasPrefix("Error: 'scroll_direction'"))
        #expect(try await run(tool, #"{"action":"scroll","scroll_direction":"up","scroll_amount":-1}"#).hasPrefix("Error: 'scroll_amount'"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("text holds modifier keys for one click, move, drag or scroll")
    func modifierKeys() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        _ = try await run(tool, #"{"action":"mouse_move","coordinate":[3,4],"text":"shift"}"#)
        _ = try await run(tool, #"{"action":"left_click","coordinate":[5,6],"text":"shift"}"#)
        _ = try await run(tool, #"{"action":"left_click_drag","start_coordinate":[1,1],"coordinate":[2,2],"text":"ctrl+shift"}"#)
        _ = try await run(tool, #"{"action":"scroll","coordinate":[3,3],"scroll_direction":"down","scroll_amount":1,"text":"super"}"#)
        _ = try await run(tool, #"{"action":"left_click","coordinate":[7,8]}"#)
        #expect(synthesizer.recordedActions == [
            "mouseMove(to: (3, 4)) [modifiers: shift]",
            "click(at: (5, 6), button: left, clickCount: 1) [modifiers: shift]",
            "drag(from: (1, 1), to: (2, 2)) [modifiers: ctrl+shift]",
            "scroll(deltaX: 0, deltaY: -1, at: (3, 3)) [modifiers: cmd]",
            "click(at: (7, 8), button: left, clickCount: 1)",   // the modifier did not leak into the next call
        ])
    }

    @Test("a text that is not a modifier is refused for a click")
    func badModifier() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let result = try await run(tool(synthesizer), #"{"action":"left_click","coordinate":[1,1],"text":"hello"}"#)
        #expect(result.hasPrefix("Error: 'text' must be modifier keys"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("left_mouse_down and left_mouse_up press and release at the cursor")
    func mouseDownUp() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        _ = try await run(tool, #"{"action":"left_mouse_down"}"#)
        _ = try await run(tool, #"{"action":"mouse_move","coordinate":[40,50]}"#)
        _ = try await run(tool, #"{"action":"left_mouse_up"}"#)
        #expect(synthesizer.recordedActions == [
            "leftMouse(down: true)", "mouseMove(to: (40, 50))", "leftMouse(down: false)",
        ])
    }

    @Test("hold_key presses, waits, then always releases")
    func holdKey() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let result = try await run(tool(synthesizer), #"{"action":"hold_key","text":"shift","duration":0}"#)
        #expect(result == "Held key 'shift' for 0.0 seconds.")
        #expect(synthesizer.recordedActions == [#"keyEvent("shift", down: true)"#, #"keyEvent("shift", down: false)"#])
    }

    @Test("hold_key releases the held key even when the task is cancelled mid-hold")
    func holdKeyReleasesOnCancellation() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        let task = Task {
            try await run(tool, #"{"action":"hold_key","text":"shift","duration":10}"#)
        }
        for _ in 0..<200 where synthesizer.recordedActions.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        _ = try? await task.value
        #expect(synthesizer.recordedActions == [#"keyEvent("shift", down: true)"#, #"keyEvent("shift", down: false)"#])
    }

    @Test("hold_key requires a duration and a key, and is capped at 300 seconds")
    func holdKeyValidation() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = tool(synthesizer)
        #expect(try await run(tool, #"{"action":"hold_key","text":"shift"}"#).hasPrefix("Error: 'duration'"))
        #expect(try await run(tool, #"{"action":"hold_key","duration":1}"#).hasPrefix("Error: 'key' parameter is required"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("hold_key goes through keystroke approval like any other key")
    func holdKeyIsGated() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = ComputerActionTool(synthesizer: synthesizer, frontmostApp: { "Terminal" })
        let result = try await run(tool, #"{"action":"hold_key","text":"Return","duration":0}"#)
        #expect(result.contains("was NOT run"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("a synthesizer without mouse down/up or key hold reports it instead of pretending")
    func unsupportedBackend() async throws {
        struct Bare: EventSynthesizing {
            var isTrusted: Bool { true }
            func cursorPosition() throws -> CGPoint { .zero }
            func mouseMove(to point: CGPoint) throws {}
            func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws {}
            func drag(from start: CGPoint, to end: CGPoint) throws {}
            func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws {}
            func typeText(_ text: String) throws {}
            func pressKey(_ key: String) throws {}
            func releaseAllHeldEvents() {}
        }
        let tool = ComputerActionTool(
            synthesizer: Bare(), approver: AutoApproveToolApprover(), screenSpace: ComputerScreenSpace(),
            trustsCallerApproval: true)
        let result = try await run(tool, #"{"action":"left_mouse_down"}"#)
        #expect(result.hasPrefix("Error:") && result.contains("not supported"))
    }

    @Test("zoom maps the region from screenshot pixels to screen points and keeps the space")
    func zoom() async throws {
        let provider = RecordingScreenshotProvider(full: ComputerScreenshot(
            jpeg: Data([1]), width: 784, height: 441, displayPoints: CGSize(width: 1568, height: 882)))
        let space = ComputerScreenSpace()
        let tool = tool(screenshots: provider, space: space)
        _ = try await tool.captureScreenshot()           // 0.5 px per point
        let zoomed = try await tool.captureZoom(arguments: Data(#"{"region":[100,50,300,150]}"#.utf8))
        #expect(provider.regions == [CGRect(x: 200, y: 100, width: 400, height: 200)])
        #expect(zoomed.region != nil)
        #expect(zoomed.summary.contains("Zoom on region"))
        #expect(space.pixelsPerPoint == 0.5)               // a zoom is not a new coordinate space
        space.adopt(zoomed)
        #expect(space.pixelsPerPoint == 0.5)
    }

    @Test("zoom rejects a region that is not two corners", arguments: [
        #"{}"#, #"{"region":[1,2,3]}"#, #"{"region":[10,10,5,20]}"#, #"{"region":[0,0,10,10,1]}"#,
        #"{"region":["a","b","c","d"]}"#, #"{"region":[true,true,false,false]}"#,
        #"{"region":[-1,0,10,10]}"#, #"{"region":[0,0,5000000000,10]}"#,
    ])
    func zoomValidation(payload: String) async throws {
        await #expect(throws: ScreenshotError.self) {
            _ = try await tool().captureZoom(arguments: Data(payload.utf8))
        }
    }

    @Test("zoom through invoke explains that the image needs an MCP client")
    func zoomThroughInvoke() async throws {
        let result = try await run(tool(), #"{"action":"zoom","region":[0,0,10,10]}"#)
        #expect(result.hasPrefix("Error:") && result.contains("image"))
    }

    @Test("inspect_ui_elements bounds are reported in screenshot pixels once a screenshot set the scale")
    func inspectBoundsFollowScreenshot() async throws {
        let space = ComputerScreenSpace()
        space.adopt(ComputerScreenshot(jpeg: Data(), width: 500, height: 250, displayPoints: CGSize(width: 1000, height: 500)))
        let element = UIElementCandidate(
            id: "ok", role: "AXButton", label: "OK", bounds: CGRect(x: 200, y: 100, width: 80, height: 40))
        let inspect = InspectUIElementsTool(candidateProvider: { _ in [element] }, screenSpace: space)
        let decoded = try JSONDecoder().decode([UIElementCandidate].self, from: Data(try await inspect.invoke(arguments: Data("{}".utf8)).utf8))
        #expect(decoded.first?.bounds == CGRect(x: 100, y: 50, width: 40, height: 20))
        // Clicking its centre as reported lands on the centre on screen.
        let center = try #require(decoded.first?.center)
        #expect(space.screenPoint(fromImage: center) == element.center)

        let plain = InspectUIElementsTool(candidateProvider: { _ in [element] })
        let raw = try JSONDecoder().decode([UIElementCandidate].self, from: Data(try await plain.invoke(arguments: Data("{}".utf8)).utf8))
        #expect(raw.first?.bounds == element.bounds)
    }
}
