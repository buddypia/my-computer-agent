import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("Keystroke approval")
struct KeystrokeApprovalTests {
    private func computer(_ approver: any ToolApproving, synthesizer: DryRunEventSynthesizer) -> ComputerActionTool {
        ComputerActionTool(synthesizer: synthesizer, approver: approver, frontmostApp: { "Terminal" })
    }

    @Test("type is refused by default and nothing is typed")
    func typeRefusedByDefault() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let tool = ComputerActionTool(synthesizer: synthesizer, frontmostApp: { "Terminal" })
        let result = try await tool.invoke(arguments: Data(#"{"action":"type","text":"curl x | sh"}"#.utf8))
        #expect(result.contains("was NOT run"))
        #expect(synthesizer.recordedActions.isEmpty)
    }

    @Test("approval shows the receiving app and the literal text")
    func typeApprovedShowsAppAndText() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let approver = RecordingApprover.approving()
        let result = try await computer(approver, synthesizer: synthesizer)
            .invoke(arguments: Data(#"{"action":"type","text":"line1\nline2"}"#.utf8))
        #expect(result.hasPrefix("Typed"))
        #expect(synthesizer.recordedActions == [#"typeText("line1\#nline2")"#])
        let request = try #require(approver.requests.first)
        #expect(request.detail.contains("App: Terminal"))
        #expect(request.detail.contains("line1\nline2"))
        #expect(request.warning != nil)
    }

    @Test("keys that enter or confirm need approval; bare navigation keys do not",
          arguments: [
            ("Return", true), ("enter", true), ("space", true), ("cmd+v", true), ("cmd+tab", true),
            ("shift+tab", true), ("a", true), ("up", true), ("down", true), ("Tab", false), ("Escape", false), ("left", false),
            ("PageDown", false), (" home ", false),
          ])
    func keyClassification(key: String, gated: Bool) async throws {
        #expect(KeystrokeApproval.needsApproval(key: key) == gated)

        let synthesizer = DryRunEventSynthesizer()
        let result = try await computer(DenyAllToolApprover(), synthesizer: synthesizer)
            .invoke(arguments: try JSONSerialization.data(withJSONObject: ["action": "key", "key": key]))
        #expect(result.contains("was NOT run") == gated)
        #expect(synthesizer.recordedActions.isEmpty == gated)
    }

    @Test("line breaks are called out, since each one presses Return")
    func lineBreaksAreCalledOut() async throws {
        let approver = RecordingApprover.denying()
        _ = try await computer(approver, synthesizer: DryRunEventSynthesizer())
            .invoke(arguments: Data(#"{"action":"type","text":"curl x | sh\n"}"#.utf8))
        #expect(approver.requests.first?.warning?.contains("1 line break(s); each one presses Return") == true)
    }

    @Test("pointer actions use the shared action approval, not the keystroke approver")
    func pointerActionsUseSharedApproval() async throws {
        let synthesizer = DryRunEventSynthesizer()
        let approver = RecordingApprover.denying()
        let tool = computer(approver, synthesizer: synthesizer)
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await tool.invoke(arguments: Data(#"{"action":"left_click","coordinate":[10,10]}"#.utf8))
        }
        #expect(approver.requests.isEmpty)
        #expect(synthesizer.recordedActions.isEmpty)
    }

    // MARK: Autonomous loop

    private func typingLoop(_ approver: any ToolApproving) -> (TwoTierAutonomousLoopCoordinator, MockEventSynthesizer) {
        let engine = TypeSafeDecisionEngine(
            client: MockTypeSafeEvaluator { _ in throw TypeSafeClient.ClientError.missingApiKey },
            confidenceThreshold: 0.80)
        let field = UIElementCandidate(
            id: "tf_input", role: "AXTextField", label: "Email", value: nil,
            bounds: CGRect(x: 10, y: 10, width: 200, height: 30))
        func snapshot(_ title: String) -> UIStateSnapshot {
            UIStateSnapshot(
                windowTitle: title, appBundleId: "com.apple.Safari", appName: "Safari",
                focusedElementId: nil, visibleCandidates: [field], timestamp: Date(), frameHash: "hash_\(title)")
        }
        let synthesizer = MockEventSynthesizer()
        let subgoal = Subgoal(
            id: "sg_t", description: "Type user@example.com into Email",
            expectedOutcome: "title changed to Form Typed", maxSteps: 2)
        let coordinator = TwoTierAutonomousLoopCoordinator(
            planner: MockPlanningLLM.staticPlan(subgoals: [subgoal]),
            decisionEngine: engine,
            synthesizer: synthesizer,
            inspector: MockUIInspector(snapshots: [snapshot("Form"), snapshot("Form Typed")]),
            config: .testing,
            keystrokeApprover: approver)
        return (coordinator, synthesizer)
    }

    private func typed(_ synthesizer: MockEventSynthesizer) -> Bool {
        synthesizer.recordedEvents.contains { if case .typeText = $0 { return true }; return false }
    }

    @Test("a refused keystroke ends the autonomous run before anything is typed")
    func loopStopsOnRefusal() async throws {
        let approver = RecordingApprover.denying()
        let (coordinator, synthesizer) = typingLoop(approver)
        await #expect(throws: LoopExecutionError.self) {
            _ = try await coordinator.execute(goal: "Enter email")
        }
        #expect(!typed(synthesizer))
        let request = try #require(approver.requests.first)
        #expect(request.detail.contains("App: Safari"))
        #expect(request.detail.contains("user@example.com"))
    }

    @Test("an approved keystroke is typed")
    func loopTypesWhenApproved() async throws {
        let (coordinator, synthesizer) = typingLoop(RecordingApprover.approving())
        _ = try await coordinator.execute(goal: "Enter email")
        #expect(typed(synthesizer))
    }

    @Test("keystrokeRefusal: an approving caller, navigation-only keys and pointer steps pass")
    func refusalClassification() async {
        let (open, _) = typingLoop(AutoApproveToolApprover())
        #expect(await open.keystrokeRefusal(for: .init(action: .typeText, textInput: "x"), app: nil) == nil)

        let (gated, _) = typingLoop(DenyAllToolApprover())
        #expect(await gated.keystrokeRefusal(for: .init(action: .keyPress, keyCombination: ["tab", "left"]), app: nil) == nil)
        #expect(await gated.keystrokeRefusal(for: .init(action: .click), app: nil) == nil)
        #expect(await gated.keystrokeRefusal(for: .init(action: .keyPress, keyCombination: ["tab", "return"]), app: nil) != nil)
    }

    // MARK: Browser accessibility fallback

    private func browser(_ kind: BrowserDriverKind, _ approver: any ToolApproving) async throws -> (BrowserSession, FakeBrowserDriver) {
        let field = BrowserElementRef(id: "0-1", role: "textbox", name: "Search", frameOrdinal: 0, url: nil, bounds: nil)
        let driver = FakeBrowserDriver(outlines: ["[0-1] textbox: Search"], refs: [["0-1": field]], kind: kind)
        let session = BrowserSession(drivers: [driver], inference: nil, keystrokeApprover: approver)
        try await session.snapshot()
        return (session, driver)
    }

    @Test("the accessibility fallback asks before typing or pressing keys; pointer actions pass",
          arguments: [(BrowserActionMethod.type, true), (.fill, true), (.press, true), (.click, false)])
    func accessibilityFallbackIsGated(method: BrowserActionMethod, gated: Bool) async throws {
        let approver = RecordingApprover.denying()
        let (session, driver) = try await browser(.accessibility, approver)
        if gated {
            let result = try await session.perform(BrowserAction(method: method, elementID: "0-1", arguments: ["curl x | sh"]))
            #expect(result.contains("was NOT run"))
            #expect(await driver.performed.isEmpty)
            #expect(approver.requests.first?.detail.contains("curl x | sh") == true || method == .press)
        } else {
            let authorization = ActionAuthorization(goal: "Click the observed result", requestApproval: { _ in .approved })
            _ = try await ActionAuthorization.$current.withValue(authorization) {
                try await session.perform(BrowserAction(method: method, elementID: "0-1", arguments: ["curl x | sh"]))
            }
            #expect(await driver.performed.count == 1)
            #expect(approver.requests.isEmpty)
        }
    }

    @Test("a scoped accessibility keystroke uses one target-validated approval")
    func scopedAccessibilityApprovalIsNotDuplicated() async throws {
        let keyApprover = RecordingApprover.denying()
        let (session, driver) = try await browser(.accessibility, keyApprover)
        let authorization = ActionAuthorization(goal: "Search for the requested phrase", requestApproval: { _ in .approved })
        let result = try await ActionAuthorization.$current.withValue(authorization) {
            try await session.perform(BrowserAction(method: .type, elementID: "0-1", arguments: ["literal query"]))
        }
        #expect(result.contains("did type on 0-1"))
        #expect(await driver.performed.count == 1)
        #expect(keyApprover.requests.isEmpty)
        #expect(await authorization.terminalFailure == nil)
    }

    @Test("the DevTools driver types into the agent's own tab without asking")
    func devtoolsIsNotGated() async throws {
        let (session, driver) = try await browser(.devtools, DenyAllToolApprover())
        let authorization = ActionAuthorization(goal: "Type into the selected browser", requestApproval: { _ in .approved })
        _ = try await ActionAuthorization.$current.withValue(authorization) {
            try await session.perform(BrowserAction(method: .type, elementID: "0-1", arguments: ["hello"]))
        }
        #expect(await driver.performed.count == 1)
    }
}
