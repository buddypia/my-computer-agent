import AppKit
import Foundation
import MCACore
import MCAInterop
import MCAMemory
import MCAPresentation
import MCAReasoning
import MCASensing

/// Entry point and CLI.
///
/// `run` is the real application: an accessory-policy NSApplication with a
/// floating overlay. The other subcommands exist so each layer can be exercised
/// on its own — the previous implementation's central failure was that nothing
/// below the UI was ever run against reality.

// Global flags are only recognized before the subcommand, so subcommand-local
// flags that share a spelling (`browser -d <depth>`) are left untouched.
var arguments = Array(CommandLine.arguments.dropFirst())
while let first = arguments.first, first == "--debug" || first == "-d" {
    setenv("MCA_DEBUG", "1", 1)
    arguments.removeFirst()
}
let command = arguments.first ?? "run"
let rest = Array(arguments.dropFirst())

// The user's exclusion list for every screen capture this process makes, so a
// capture path that is never handed the configuration (the System One
// screenshot, the MCP tools' accessibility fallbacks) still honours it.
installProcessWideCaptureExclusion()

// Every branch here is synchronous, and that is load-bearing rather than
// stylistic. A single `await` anywhere in top-level code makes Swift compile
// *all* of it as an async main running inside a Task on the main actor. That
// starves `NSApplication.run()`, which needs to own the main thread outright:
// the process stays alive, the run loop never turns, and
// `applicationDidFinishLaunching` is never delivered — the app appears to
// launch and then silently does nothing. Async commands are therefore bridged
// through `runBlocking`.
switch command {
case "run":
    MainActor.assumeIsolated { runApp() }
case "doctor":
    runBlocking { await runDoctor() }
case "mcp":
    runBlocking { await runMCPServer() }
case "ask":
    runBlocking { await runAsk(question: rest.joined(separator: " ")) }
case "act":
    runBlocking { await ActCommand.run(rest) }
case "browser":
    runBlocking { await BrowserCommand.run(rest) }
case "search":
    runBlocking { await runSearch(query: rest.joined(separator: " ")) }
case "auth":
    runAuth(rest)
case "listen":
    runBlocking { await runListen(seconds: Double(rest.first ?? "20") ?? 20) }
case "capture":
    runBlocking { await CaptureHarness.run(waitSeconds: Double(rest.first ?? "0") ?? 0) }
case "setup":
    MainActor.assumeIsolated { runSetup() }
case "reset-permissions":
    runResetPermissions()
case "-h", "--help", "help":
    printUsage()
default:
    FileHandle.standardError.write(Data("Unknown command '\(command)'\n\n".utf8))
    printUsage()
    exit(2)
}

/// Runs async work from synchronous top-level code and waits for it.
func runBlocking(_ body: @escaping @Sendable () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await body()
        semaphore.signal()
    }
    semaphore.wait()
}

// MARK: - Commands

/// Holds the delegate for the process lifetime.
///
/// `NSApplication.delegate` is a **weak** reference. Assigning a local
/// `let` to it lets ARC release the delegate immediately after the assignment,
/// after which the property is nil and `applicationDidFinishLaunching` is never
/// delivered — the app blocks in `run()` looking exactly like a hang.
private final class DelegateBox: @unchecked Sendable {
    static let shared = DelegateBox()
    var delegate: AppDelegate?
}

func installProcessWideCaptureExclusion() {
    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
    ScreenCapturer.processWideExclusion = { bundleID, title in
        configuration.isExcluded(bundleID: bundleID, windowTitle: title)
    }
}

@MainActor
func runApp() {
    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()

    let application = NSApplication.shared
    let copilot = Copilot(configuration: configuration)

    DelegateBox.shared.delegate = AppDelegate(copilot: copilot)
    application.delegate = DelegateBox.shared.delegate
    application.setActivationPolicy(.accessory)

    // Blocks until termination. AXObserver and the Carbon hot keys both need
    // this run loop, so nothing else may own the main thread.
    application.run()
}

func runDoctor() async {
    print("my-computer-agent — diagnostics\n")

    let status = await Permissions.check()
    print(Permissions.describe(status))
    print("")

    if !status.allGranted {
        print(Permissions.instructions(status))
        print("")
    }

    print("Models")
    if let reason = AppleOnDeviceExecutor.unavailableReason {
        print("  ✗ on-device gate: \(reason)")
        print("    Triage will fall back to a cloud model, raising running cost.")
    } else {
        print("  ✓ on-device gate available (Apple Intelligence)")
    }
    let credentials = CredentialStore()
    let providers = credentials.availableProviders()
    if providers.isEmpty {
        print("  ✗ no cloud provider keys found")
        print("    Set one with: mca auth set gemini")
    } else {
        for provider in providers { print("  ✓ \(provider) key present") }
    }
    print("")

    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
    print("Storage")
    do {
        let store = try SQLiteContextStore(url: configuration.databaseURL)
        let count = try await store.count()
        print("  ✓ \(configuration.databaseURL.path)")
        print("  ✓ \(count) observations stored")
    } catch {
        print("  ✗ \(error)")
    }
    print("")

    // The whole chain, not just the primary, and marked with what can actually
    // run. Printing only the primary hid the case this section exists to
    // catch: a route whose model is unreachable and whose fallbacks are too,
    // which leaves the task silently dead rather than merely slower.
    print("Routing")
    let router = ModelRouter(policy: configuration.routing, credentials: credentials)
    var blocked: [(AgentTask, String)] = []
    for task in AgentTask.allCases {
        let chain = router.chain(for: task)
        let rendered = chain.isEmpty
            ? "unset"
            : chain.map { reference in
                let name = "\(reference.provider)/\(reference.model)"
                return router.unavailableReason(for: reference) == nil ? name : "\(name) ✗"
            }.joined(separator: " → ")
        let name = task.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        print("  \(name) → \(rendered)")
        if let reason = router.blockedReason(for: task) { blocked.append((task, reason)) }
    }

    guard !blocked.isEmpty else { return }
    print("")
    print("  ✗ marks a route that cannot run at all. These tasks have none left:")
    for (task, reason) in blocked {
        print("      \(task.rawValue): \(reason)")
    }
}

func runMCPServer() async {
    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
    do {
        let store = try SQLiteContextStore(url: configuration.databaseURL)
        // A stdio server has nobody to ask, so tools that act on the machine
        // are refused unless the user has opted in in config.json.
        let approver: any ToolApproving = configuration.mcpAllowDangerousTools
            ? AutoApproveToolApprover()
            : ContextMCPServer.defaultApprover
        var extraTools: [any AgentTool] = []
        if configuration.browser.enabled {
            let router = ModelRouter(policy: configuration.routing, credentials: CredentialStore())
            // The MCP server approves each acting call as a whole.
            let session = BrowserToolkit.makeSession(
                router: router, settings: configuration.browser, privacy: configuration,
                keystrokeApprover: AutoApproveToolApprover())
            extraTools = BrowserToolkit.tools(session: session, approver: approver)
        }
        let server = ContextMCPServer(store: store, extraTools: extraTools, approver: approver)
        try await server.start()
        await server.waitUntilCompleted()
    } catch {
        FileHandle.standardError.write(Data("MCP server failed: \(error)\n".utf8))
        exit(1)
    }
}

func runAsk(question: String) async {
    guard !question.isEmpty else {
        print("Usage: mca ask \"your question\"")
        exit(2)
    }

    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
    do {
        let store = try SQLiteContextStore(url: configuration.databaseURL)
        let router = ModelRouter(policy: configuration.routing, credentials: CredentialStore())
        // y/N on the terminal; refuses when stdin is not one.
        let approver = TerminalToolApprover()
        let tools = ToolRegistry(tools: [
            SearchContextTool(store: store, expander: QueryExpander(router: router)),
            CurrentScreenTool(store: store),
            ScrollPinnedWindowTool(),
            ComputerActionTool(approver: approver),
            ClickElementTool(),
            RunAppleScriptTool(approver: approver),
            InspectUIElementsTool(),
            TypeSafeActTool(engineProvider: { .live() }, approver: approver),
            FindFilesTool(),
            OpenFileTool(approver: approver),
            WriteFileTool(approver: approver),
        ] + (configuration.browser.enabled
            ? BrowserToolkit.tools(
                session: BrowserToolkit.makeSession(
                    router: router, settings: configuration.browser, privacy: configuration, keystrokeApprover: approver),
                approver: approver)
            : []))
        let agent = Agent(
            router: router, store: store, tools: tools, health: HealthRegistry())

        // Printed from the return value when nothing streamed, not only from the
        // token callback: a provider that answers without streaming still has to
        // print something, or this command exits 0 having said nothing at all.
        let streamed = Counter()
        let answer = try await agent.answer(question) { token in
            streamed.add(token.count)
            FileHandle.standardOutput.write(Data(token.utf8))
        }
        print(streamed.value == 0 ? answer : "")
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

/// Thread-safe tally, because the token callback is `@Sendable` and runs
/// wherever the executor's stream is being decoded.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add(_ amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        count += amount
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

func runSearch(query: String) async {
    guard !query.isEmpty else {
        print("Usage: mca search \"terms\"")
        exit(2)
    }

    let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
    do {
        let store = try SQLiteContextStore(url: configuration.databaseURL)
        let router = ModelRouter(policy: configuration.routing, credentials: CredentialStore())
        let expanded = ExpandedSearch(store: store, expander: QueryExpander(router: router))
        let results = try await expanded.search(ContextQuery(text: query, limit: 20))
        guard !results.isEmpty else {
            print("No matches for '\(query)'.")
            return
        }
        for result in results {
            print(ContextFormatter.line(for: result.observation))
        }
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

func runAuth(_ arguments: [String]) {
    guard arguments.count >= 2, arguments[0] == "set" else {
        print("""
            Usage:
              mca auth set <gemini|anthropic|openai-compatible|typesafe>
              mca auth delete <provider>

            The key is read from stdin so it never lands in shell history.
            """)
        exit(2)
    }

    let provider = arguments[1]
    if arguments[0] == "delete" {
        SecretStore.shared.delete(account: provider)
        print("Removed key for \(provider).")
        return
    }

    print("Paste the API key for \(provider) and press return:")
    guard let key = readLine(strippingNewline: true), !key.isEmpty else {
        print("No key entered.")
        exit(1)
    }
    do {
        try SecretStore.shared.write(account: provider, value: key)
    } catch {
        FileHandle.standardError.write(Data("Could not store the key: \(error)\n".utf8))
        exit(1)
    }

    let how = switch SecretStore.shared.protection() {
    case .secureEnclave:
        "sealed to this Mac's Secure Enclave and stored in the login keychain"
    case .softwareKey(let reason):
        "encrypted with a software key (\(reason)) and stored in the login keychain"
    }

    // The item's keychain ACL belongs to whichever binary created it. This one
    // is the CLI, so the app reads it back as a *different* application and
    // macOS interposes an "allow access?" dialog — easy to miss from a
    // background agent, and indistinguishable from "no key".
    print("""
        Stored: \(how).

        Note: macOS will ask the app for permission the first time it reads
        this item, because the CLI created it. To skip that, add the key in
        ✨ ▸ Settings ▸ Models & Keys instead — the app then owns the item.
        """)
}

/// Opens the visual setup walkthrough.
///
/// A window rather than console output, because the permissions cannot be
/// granted from a terminal at all: TCC attributes a grant to whichever process
/// is "responsible", and for a terminal-launched binary that is the terminal.
/// The walkthrough runs inside the app bundle so the prompts land on the app.
@MainActor
func runSetup() {
    let application = NSApplication.shared
    let controller = SetupWindowController()
    SetupBox.shared.controller = controller

    application.setActivationPolicy(.regular)
    AppMenu.install()
    application.delegate = nil
    controller.show()
    application.activate(ignoringOtherApps: true)
    application.run()
}

private final class SetupBox: @unchecked Sendable {
    static let shared = SetupBox()
    var controller: SetupWindowController?
}

/// Clears this app's TCC grants.
///
/// Needed when the app was ad-hoc signed: the stale grant keeps the toggle
/// visible in System Settings while no longer matching the rebuilt binary, so
/// the switch looks ON and the permission still fails. Resetting removes the
/// row and lets macOS prompt cleanly again.
func runResetPermissions() {
    let bundleID = "com.buddypia.mca"
    let services = ["Microphone", "ScreenCapture", "Accessibility", "SpeechRecognition"]

    for service in services {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        print("  \(process.terminationStatus == 0 ? "✓" : "·") reset \(service)")
    }
    print("""

        Done. Relaunch the app to be prompted again:
            open /Applications/MyComputerAgent.app  (or your build path)
        """)
}

/// Runs capture and transcription only, printing what it hears.
///
/// This is the acceptance check for the riskiest layer: it proves the process
/// tap, the echo canceller and the transcriber actually work together on real
/// hardware, without any of the agent above them.
func runListen(seconds: Double) async {
    let harness = ListenHarness()
    await harness.run(seconds: seconds)
}

func printUsage() {
    print("""
        my-computer-agent — a local, multimodal desktop copilot

        Usage: mca <command>

          run       Start the copilot and its menu bar item (default)
          doctor    Check permissions, models, storage and routing
          listen    Capture and transcribe for N seconds, printing both channels
          capture   Read the focused window once and print what was extracted
          setup     Open the guided permission walkthrough
                    (prefer ✨ ▸ Permissions from the running app: a prompt
                     raised from a terminal is granted to the terminal)
          reset-permissions
                    Clear this app's TCC grants so macOS prompts again
          ask       Ask a one-shot question with current desktop context
          act       Execute desktop actions (--goal, --autonomous, --dry-run)
          browser   Drive a browser: navigate, snapshot (refs), click/fill/press, act/extract
          search    Search recorded history
          mcp       Serve recorded context over MCP on stdio
          auth      Store a provider API key in the keychain

        Global Options:
          --debug, -d   Enable verbose diagnostic logging (also via MCA_DEBUG=1)

        The agent lives in the ✨ menu bar item. Left click opens its panel;
        right click opens the commands. Nothing sits on top of your work unless
        you turn on "Show the Panel on the Desktop".

        The microphone is not opened at launch. It comes up for a voice
        conversation (⌃⌥V) and closes when the conversation ends. To capture
        and transcribe continuously instead, turn on "Listen continuously" in
        ✨ ▸ Settings ▸ General ▸ Audio.

        Default hot keys while running:
          ⌥Space   ask a question      ⌥⌘X  let clicks pass through
          ⌥⌘H      panel on/off        ⌥⌘J  collapse/restore the panel
          ⌃⌥V      talk to the agent

        All five are rebindable in ✨ ▸ Settings ▸ Shortcuts, which is also
        where a chord another app already owns is reported — macOS gives a
        chord to whoever registered it first and tells nobody.

        The ✨ menu bar item does the same, plus keeping the panel in front of
        other windows, moving it to another corner, API keys, permissions and
        quitting. Every one of those choices persists across launches.
        """)
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let copilot: Copilot

    init(copilot: Copilot) {
        self.copilot = copilot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Permission prompts are raised alongside startup, never in front of
        // it. `AVCaptureDevice.requestAccess` does not return until the user
        // answers the dialog, so awaiting it here would hold every other
        // subsystem hostage to a microphone prompt — including screen capture,
        // which may already be granted. Each subsystem reports its own state
        // into the health registry instead, and the HUD shows what is missing.
        Task.detached {
            let status = await Permissions.check()
            guard !status.allGranted else { return }
            FileHandle.standardError.write(Data((Permissions.describe(status) + "\n").utf8))
            await Permissions.request()
        }

        Task { @MainActor in
            await copilot.start()
            // stderr, not stdout: stdout is fully buffered when redirected to a
            // file, so a `print` here is lost when the process is killed rather
            // than exiting cleanly — which is how a background agent usually ends.
            FileHandle.standardError.write(Data(await copilot.startupReport().utf8))
        }
    }

    /// Opening the app again brings up Settings.
    ///
    /// `LSUIElement` means there is no Dock icon and no window to restore, so
    /// without this a second launch does nothing at all — the user double
    /// clicks the app, sees no response, and has no way to tell it is already
    /// running. Settings is the right destination: someone reopening the app is
    /// looking for its controls.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        copilot.openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous wait: the process is going away and the audio taps must
        // be torn down before it does, or CoreAudio leaks the aggregate device.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await copilot.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }
}
