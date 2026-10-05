import Foundation
import Testing
@testable import MCACore
@testable import MCAReasoning
@testable import MCASensing

/// A scripted browser: fixed outlines per "page", records every action, and
/// can be told to fail an action once (for the self-heal path).
actor FakeBrowserDriver: BrowserDriving {
    nonisolated let kind: BrowserDriverKind

    var outlines: [String]
    var refsPerOutline: [[String: BrowserElementRef]]
    var snapshotIndex = 0
    var performed: [BrowserAction] = []
    var failNextPerform: BrowserError?
    var url = "https://example.test/"
    var connectError: BrowserError?
    var pageTitle = "Fake"
    var titleDuringRead: String?
    var listedTabs: [BrowserTab]?
    var switchedTabIDs: [String] = []
    var navigatedURLs: [String] = []
    var openedTabURLs: [String] = []
    func setTabs(_ tabs: [BrowserTab]) { listedTabs = tabs }
    func scope(to window: PinnedWindow) async throws {}
    func changeTitleDuringRead(to title: String) { titleDuringRead = title }

    init(
        outlines: [String], refs: [[String: BrowserElementRef]], connectError: BrowserError? = nil,
        kind: BrowserDriverKind = .devtools
    ) {
        self.kind = kind
        self.outlines = outlines
        self.refsPerOutline = refs
        self.connectError = connectError
    }

    func setFailNextPerform(_ error: BrowserError) { failNextPerform = error }

    func connect() async throws { if let connectError { throw connectError } }
    func describeConnection() async -> String { "fake" }

    func snapshot(options: BrowserSnapshotOptions) async throws -> BrowserSnapshot {
        let observedTitle = pageTitle
        if let titleDuringRead { pageTitle = titleDuringRead }
        let index = min(snapshotIndex, outlines.count - 1)
        snapshotIndex += 1
        return BrowserSnapshot(driver: .devtools, url: url, title: observedTitle,
                               outline: AccessibilityOutline.trim(outlines[index], options: options),
                               refs: refsPerOutline[index])
    }

    func perform(_ action: BrowserAction, ref: BrowserElementRef?, target: BrowserElementRef?) async throws -> String {
        if let failNextPerform {
            self.failNextPerform = nil
            throw failNextPerform
        }
        performed.append(action)
        return "did \(action.method.rawValue) on \(ref?.id ?? "page") \(action.arguments)"
    }

    func navigate(to url: String, waitUntil: BrowserLoadState) async throws { navigatedURLs.append(url); self.url = url }
    func goBack() async throws -> Bool { false }
    func goForward() async throws -> Bool { false }
    func reload() async throws {}
    func wait(for condition: BrowserWaitCondition, timeout: TimeInterval) async throws {}
    func currentPage() async throws -> (url: String, title: String) { (url, pageTitle) }
    func pageText() async throws -> String {
        if let titleDuringRead { pageTitle = titleDuringRead }
        return "fake text"
    }
    func screenshotPNG() async throws -> Data { Data([0x89, 0x50]) }
    func tabs() async throws -> [BrowserTab] { listedTabs ?? [BrowserTab(id: "t1", url: url, title: "Fake", isActive: true)] }
    func openTab(url: String) async throws -> BrowserTab { openedTabURLs.append(url); return BrowserTab(id: "t2", url: url, title: "", isActive: true) }
    func switchTab(id: String) async throws { switchedTabIDs.append(id) }
    func closeTab(id: String) async throws {}
    func evaluate(_ expression: String) async throws -> String { "evaluated: \(expression)" }
}

private func ref(_ id: String, _ role: String, _ name: String) -> BrowserElementRef {
    BrowserElementRef(id: id, role: role, name: name, backendNodeID: Int(id.split(separator: "-").last!))
}

private let loginOutline = """
    [0-1] RootWebArea: Login
      [0-10] textbox: Email
      [0-11] textbox: Password
      [0-12] button: Sign in
      [0-13] combobox: Country
    """
private let loginRefs: [String: BrowserElementRef] = [
    "0-1": ref("0-1", "RootWebArea", "Login"),
    "0-10": ref("0-10", "textbox", "Email"),
    "0-11": ref("0-11", "textbox", "Password"),
    "0-12": ref("0-12", "button", "Sign in"),
    "0-13": ref("0-13", "combobox", "Country"),
]
private let openDropdownOutline = loginOutline + "\n    [0-20] option: Japan\n    [0-21] option: Korea"
private let openDropdownRefs = loginRefs.merging([
    "0-20": ref("0-20", "option", "Japan"),
    "0-21": ref("0-21", "option", "Korea"),
]) { $1 }

/// Canned model: answers by matching a substring of the user prompt.
private func cannedInference(_ answers: [(contains: String, reply: String)], record: CallRecorder? = nil) -> BrowserInference {
    BrowserInference { system, user, schema in
        record?.append(user)
        for answer in answers where user.contains(answer.contains) { return answer.reply }
        return #"{"action": null, "twoStep": false}"#
    }
}

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var prompts: [String] = []
    func append(_ prompt: String) { lock.lock(); prompts.append(prompt); lock.unlock() }
}

@Suite("Browser tools — definitions")
struct BrowserToolDefinitionTests {
    @Test("every tool has a name, description and an object schema")
    func definitions() throws {
        let session = BrowserSession(drivers: [], inference: nil)
        let tools = BrowserToolkit.tools(session: session)
        #expect(tools.count == 10)
        var names = Set<String>()
        for tool in tools {
            let definition = tool.definition
            #expect(definition.name.hasPrefix("browser_"))
            #expect(!definition.description.isEmpty)
            let schema = try JSONSerialization.jsonObject(with: definition.parameters) as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            names.insert(definition.name)
        }
        #expect(names.isSuperset(of: ["browser_navigate", "browser_snapshot", "browser_element", "browser_act", "browser_observe", "browser_extract", "browser_read", "browser_tabs", "browser_wait", "browser_evaluate"]))
    }
}

@Suite("BrowserSession — refs and deterministic actions", ApprovedBrowserTestScope())
struct BrowserSessionTests {
    @Test("a ref from an older snapshot is rejected with a stale_ref error")
    func staleRef() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: nil)
        let element = BrowserElementTool(session: session)

        let before = try await element.invoke(arguments: Data(#"{"action":"click","ref":"0-12"}"#.utf8))
        #expect(before.hasPrefix("Error:"))
        #expect(before.contains("browser_snapshot"))

        _ = try await BrowserSnapshotTool(session: session).invoke(arguments: Data("{}".utf8))
        let after = try await element.invoke(arguments: Data(#"{"action":"click","ref":"[0-12]"}"#.utf8))
        #expect(after.contains("did click on 0-12"))
        let unknown = try await element.invoke(arguments: Data(#"{"action":"click","ref":"0-999"}"#.utf8))
        #expect(unknown.contains("Unknown ref '0-999'"))
    }

    @Test("snapshot output carries URL, title, and the outline")
    func snapshotFormat() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: nil)
        let text = try await BrowserSnapshotTool(session: session).invoke(arguments: Data(#"{"filter":"Sign in"}"#.utf8))
        #expect(text.hasPrefix("URL: https://example.test/"))
        #expect(text.contains("[0-12] button: Sign in"))
        #expect(!text.contains("[0-10] textbox: Email"))
    }

    @Test("variables are substituted into arguments, never into the ref")
    func variables() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: nil)
        _ = try await session.snapshot()
        let message = try await BrowserElementTool(session: session).invoke(arguments: Data(
            #"{"action":"fill","ref":"0-11","value":"%password%","variables":{"password":"hunter2"}}"#.utf8))
        #expect(message.contains("[\"hunter2\"]"))
        let performed = await driver.performed
        #expect(performed.last?.arguments == ["hunter2"])
    }

    @Test("Unverifiable keyboard focus is refused; element actions demand a ref")
    func refRequirement() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: nil)
        let tool = BrowserElementTool(session: session)
        let press = try await tool.invoke(arguments: Data(#"{"action":"press","value":"Enter"}"#.utf8))
        #expect(press.hasPrefix("Error:"))
        #expect(await driver.performed.isEmpty)
        let click = try await tool.invoke(arguments: Data(#"{"action":"click"}"#.utf8))
        #expect(click.hasPrefix("Error: 'ref' is required"))
    }

    @Test("the first driver that connects wins; failures are reported together")
    func driverSelection() async throws {
        let broken = FakeBrowserDriver(outlines: [""], refs: [[:]], connectError: .notConnected("no devtools"))
        let working = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [broken, working], inference: nil)
        let driver = try await session.driver()
        #expect(driver.kind == working.kind)

        let none = BrowserSession(drivers: [broken], inference: nil)
        let result = try await BrowserReadTool(session: none).invoke(arguments: Data(#"{"what":"url"}"#.utf8))
        #expect(result.contains("no devtools"))
    }

    @Test("natural-language tools explain themselves when no model is configured")
    func noModel() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: nil)
        let result = try await BrowserActTool(session: session).invoke(arguments: Data(#"{"instruction":"click sign in"}"#.utf8))
        #expect(result.contains("browser_element"))
    }
}

@Suite("BrowserSession — observe / act / extract pipeline", ApprovedBrowserTestScope())
struct BrowserActPipelineTests {
    @Test("act: model picks an element, the action runs by ref")
    func actHappyPath() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let inference = cannedInference([
            ("click the sign in button", #"{"action": {"elementId": "0-12", "description": "Sign in button", "method": "click", "arguments": []}, "twoStep": false}"#),
        ])
        let session = BrowserSession(drivers: [driver], inference: inference)
        let outcome = try await session.act(instruction: "click the sign in button")
        #expect(outcome.success)
        #expect(outcome.actions.map(\.elementID) == ["0-12"])
        #expect(await driver.performed.map(\.method) == [.click])
    }

    @Test("act: variables are named to the model but only substituted at execution")
    func actVariables() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let recorder = CallRecorder()
        let inference = cannedInference([
            ("type the password", #"{"action": {"elementId": "0-11", "description": "Password", "method": "fill", "arguments": ["%password%"]}, "twoStep": false}"#),
        ], record: recorder)
        let session = BrowserSession(drivers: [driver], inference: inference)
        let outcome = try await session.act(instruction: "type the password", variables: ["password": "s3cret"])
        #expect(outcome.success)
        #expect(await driver.performed.last?.arguments == ["s3cret"])
        #expect(recorder.prompts.first?.contains("%password%") == true)
        #expect(recorder.prompts.first?.contains("s3cret") == false)
    }

    @Test("act: a failing action triggers a re-snapshot and a second inference (self-heal)")
    func selfHeal() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline, loginOutline], refs: [loginRefs, loginRefs])
        await driver.setFailNextPerform(.elementNotInteractable("covered by overlay"))
        let recorder = CallRecorder()
        let inference = cannedInference([
            ("click the sign in button", #"{"action": {"elementId": "0-12", "description": "Sign in", "method": "click", "arguments": []}, "twoStep": false}"#),
            ("click Sign in", #"{"action": {"elementId": "0-12", "description": "Sign in", "method": "click", "arguments": []}, "twoStep": false}"#),
        ], record: recorder)
        let session = BrowserSession(drivers: [driver], inference: inference)
        let outcome = try await session.act(instruction: "click the sign in button")
        #expect(outcome.success)
        #expect(outcome.selfHealed)
        #expect(recorder.prompts.count == 2)
        #expect(await driver.performed.count == 1)
    }

    @Test("act: twoStep shows the model only the diff and performs the second action")
    func twoStep() async throws {
        let driver = FakeBrowserDriver(
            outlines: [loginOutline, loginOutline, openDropdownOutline, openDropdownOutline],
            refs: [loginRefs, loginRefs, openDropdownRefs, openDropdownRefs])
        let recorder = CallRecorder()
        let inference = cannedInference([
            ("step 1 of 2", #"{"action": {"elementId": "0-20", "description": "Japan option", "method": "click", "arguments": []}, "twoStep": false}"#),
            ("select Japan", #"{"action": {"elementId": "0-13", "description": "Country dropdown", "method": "click", "arguments": []}, "twoStep": true}"#),
        ], record: recorder)
        let session = BrowserSession(drivers: [driver], inference: inference)
        let outcome = try await session.act(instruction: "select Japan from the country dropdown")
        #expect(outcome.success)
        #expect(outcome.actions.map(\.elementID) == ["0-13", "0-20"])
        // The second prompt must be the diff, not the whole page.
        let second = try #require(recorder.prompts.last)
        #expect(second.contains("[0-20] option: Japan"))
        #expect(!second.contains("[0-10] textbox: Email"))
    }

    @Test("act: no matching element is reported, not thrown")
    func noElement() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let session = BrowserSession(drivers: [driver], inference: cannedInference([]))
        let outcome = try await session.act(instruction: "click the unicorn")
        #expect(!outcome.success)
        #expect(outcome.message.contains("No element"))
    }

    @Test("observe: invented ids are filtered out; bare ids are assumed main-frame")
    func observe() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let inference = cannedInference([
            ("Accessibility Tree", #"{"elements": [{"elementId": "12", "description": "Sign in", "method": "click", "arguments": []}, {"elementId": "0-999", "description": "ghost", "method": "click", "arguments": []}]}"#),
        ])
        let session = BrowserSession(drivers: [driver], inference: inference)
        let elements = try await session.observe(instruction: "buttons")
        #expect(elements.map(\.elementID) == ["0-12"])
    }

    @Test("extract: returns pretty JSON of the model's object")
    func extract() async throws {
        let driver = FakeBrowserDriver(outlines: [loginOutline], refs: [loginRefs])
        let inference = cannedInference([("Instruction: title", "```json\n{\"title\": \"Login\"}\n```")])
        let session = BrowserSession(drivers: [driver], inference: inference)
        let text = try await BrowserExtractTool(session: session).invoke(arguments: Data(#"{"instruction":"title"}"#.utf8))
        #expect(text.contains("\"title\" : \"Login\""))
    }
}

@Suite("BrowserInference parsing")
struct BrowserInferenceParsingTests {
    @Test("JSON is found inside prose and code fences")
    func parseObject() {
        #expect(BrowserInference.parseObject("Sure: {\"a\": 1}")?["a"] as? Int == 1)
        #expect(BrowserInference.parseObject("```json\n{\"a\": 2}\n```")?["a"] as? Int == 2)
        #expect(BrowserInference.parseObject("nothing here") == nil)
    }

    @Test("lenient method names map onto the enum")
    func lenientMethods() {
        #expect(BrowserActionMethod.lenient("double_click") == .doubleClick)
        #expect(BrowserActionMethod.lenient("scroll") == .scrollTo)
        #expect(BrowserActionMethod.lenient("selectOption") == .selectOptionFromDropdown)
        #expect(BrowserActionMethod.lenient("teleport") == nil)
    }

    @Test("ref normalisation accepts the spellings models produce")
    func normalizeRef() {
        #expect(BrowserSession.normalizeRef("@0-5") == "0-5")
        #expect(BrowserSession.normalizeRef("[0-5]") == "0-5")
        #expect(BrowserSession.normalizeRef("ref=0-5") == "0-5")
        #expect(BrowserSession.normalizeRef(" 0-5 ") == "0-5")
    }

    @Test("act and tool schemas use the Gemini-compatible subset (no $ref, no additionalProperties)")
    func schemaCompatibility() throws {
        var schemas = [
            BrowserInference.actSchema,
            BrowserInference.observationSchema,
            BrowserInference.freeformExtractSchema,
        ]
        let tools = BrowserToolkit.tools(session: BrowserSession(drivers: [], inference: nil))
        for tool in tools {
            schemas.append(tool.definition.parameters)
        }
        for schema in schemas {
            let text = String(decoding: schema, as: UTF8.self)
            #expect(!text.contains("$ref"))
            #expect(!text.contains("additionalProperties"))
            #expect(try JSONSerialization.jsonObject(with: schema) is [String: Any])
        }
    }
}
