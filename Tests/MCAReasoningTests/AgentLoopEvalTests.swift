import CoreGraphics
import Foundation
import MCACore
import MCAMemory
import MCASensing
@testable import MCAReasoning
import Testing

/// Task-completion eval for the architectures in `docs/architecture/single-agent-loop.md`.
///
/// Every task runs on a simulated desktop (screens of AX elements, state, transitions),
/// under three variants that differ only in where the work is planned:
///
/// - `handoff`: today's `.autonomousLoop` route — the request goes to the two-tier loop
///   and the user sees its final message, nothing else.
/// - `folded`: `Agent.answer` plans for itself with single-step tools only.
/// - `tool`: `folded` plus `run_desktop_task` (the loop called as a tool).
///
/// A run passes when the final state matches, the answer contains what the task asks
/// to be told, and no forbidden element was clicked. System 1 is the deterministic
/// offline engine in every variant, so the variants differ only in the model's role.
///
/// Measured only with `MCA_AGENT_EVAL=1` (it calls the answer model: Gemini, key from
/// `GEMINI_API_KEY`). Without it, the test checks that the task file is well-formed.
@Suite("AgentLoopEval")
struct AgentLoopEvalTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Evals/agent-loop")

    // MARK: - Task file

    struct EvalTask: Decodable {
        var id: String
        var source: String
        var request: String
        var app: AppSpec
        var expect: Expect
    }

    struct AppSpec: Decodable {
        var name: String
        var start: String
        var state: [String: String]
        var screens: [String: [ElementSpec]]
        var onEnter: [String: Effect]?
        var onScroll: [String: Effect]?
    }

    struct ElementSpec: Decodable {
        var id: String
        var role: String
        var label: String
        var value: String?
        var go: String?
        var set: [String: String]?
        var field: String?
    }

    struct Effect: Decodable {
        var go: String?
        var set: [String: String]?
    }

    struct Expect: Decodable {
        /// `_screen` names the screen the run must end on.
        var state: [String: String]
        var answerContains: [String]?
        var forbidClick: [String]?
    }

    static func loadTasks() throws -> [EvalTask] {
        let text = try String(contentsOf: directory.appendingPathComponent("tasks.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.isEmpty }.map {
            try JSONDecoder().decode(EvalTask.self, from: Data($0.utf8))
        }
    }

    // MARK: - Simulated desktop

    /// One app window: what `inspect_ui_elements` sees and what a click or keystroke changes.
    final class SimulatedDesktop: UIStateProviding, EventSynthesizing, @unchecked Sendable {
        let app: AppSpec
        private let lock = NSLock()
        private var screen: String
        private var state: [String: String]
        private var focusedField: String?
        private var clickLog: [String] = []

        init(app: AppSpec) {
            self.app = app
            self.screen = app.start
            self.state = app.state
        }

        var isSimulation: Bool { true }
        var isTrusted: Bool { true }

        var finalState: [String: String] { lock.withLock { state.merging(["_screen": screen]) { $1 } } }
        var clicks: [String] { lock.withLock { clickLog } }

        private func render(_ text: String) -> String {
            state.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }

        private func frame(_ index: Int) -> CGRect {
            CGRect(x: 100, y: 80 + 44 * index, width: 240, height: 32)
        }

        private func elements() -> [ElementSpec] { app.screens[screen] ?? [] }

        private func apply(_ effect: Effect) {
            for (key, value) in effect.set ?? [:] { state[key] = value }
            if let go = effect.go { screen = go; focusedField = nil }
        }

        func captureSnapshot() async throws -> UIStateSnapshot {
            lock.withLock {
                let candidates = elements().enumerated().map { index, element in
                    UIElementCandidate(
                        id: element.id, role: element.role, label: render(element.label),
                        value: element.field.map { state[$0] ?? "" } ?? element.value.map(render),
                        bounds: frame(index), isActionable: element.role != "AXStaticText")
                }
                let focused = elements().first { $0.field != nil && $0.field == focusedField }?.id
                let fingerprint = ([screen] + state.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
                    .joined(separator: "|")
                return UIStateSnapshot(
                    windowTitle: app.name, appBundleId: "eval.\(app.name)", appName: app.name,
                    focusedElementId: focused, visibleCandidates: candidates, timestamp: Date(),
                    frameHash: String(fingerprint.hashValue))
            }
        }

        func click(at point: CGPoint?, button: MouseButton, clickCount: Int) throws {
            lock.withLock {
                guard let point,
                      let (index, element) = elements().enumerated().first(where: { frame($0.offset).contains(point) })
                else { clickLog.append("(miss)"); return }
                _ = index
                clickLog.append(element.id)
                if let field = element.field { focusedField = field }
                apply(Effect(go: element.go, set: element.set))
            }
        }

        func typeText(_ text: String) throws {
            lock.withLock {
                guard let field = focusedField else { return }
                state[field] = (state[field] ?? "") + text
            }
        }

        func pressKey(_ key: String) throws {
            lock.withLock {
                guard ["return", "enter"].contains(key.lowercased()), let effect = app.onEnter?[screen] else { return }
                apply(effect)
            }
        }

        func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint?, targetPID: pid_t?) throws {
            lock.withLock {
                guard let effect = app.onScroll?[screen] else { return }
                apply(effect)
            }
        }

        func cursorPosition() throws -> CGPoint { .zero }
        func mouseMove(to point: CGPoint) throws {}
        func drag(from start: CGPoint, to end: CGPoint) throws {}
        func releaseAllHeldEvents() {}
    }

    // MARK: - Variants

    enum Variant: String, CaseIterable, Codable { case handoff, folded, tool }

    actor CallLog {
        private(set) var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    struct Recording: AgentTool {
        let base: any AgentTool
        let log: CallLog
        var definition: ToolDefinition { base.definition }
        var timeout: Duration? { base.timeout }
        func invoke(arguments: Data) async throws -> String {
            await log.add(base.definition.name)
            return try await base.invoke(arguments: arguments)
        }
    }

    struct Offline: Error {}

    struct RunResult: Codable {
        var task: String
        var variant: Variant
        var run: Int
        var passed: Bool
        var failures: [String]
        var state: [String: String]
        var answer: String
        var tools: [String]
        var clicks: [String]
        var seconds: Double
    }

    static func grade(_ task: EvalTask, state: [String: String], answer: String, clicks: [String]) -> [String] {
        var failures: [String] = []
        for (key, value) in task.expect.state where state[key] != value {
            failures.append("state \(key)=\(state[key] ?? "nil"), expected \(value)")
        }
        for needle in task.expect.answerContains ?? [] where !answer.localizedCaseInsensitiveContains(needle) {
            failures.append("answer lacks \"\(needle)\"")
        }
        for id in task.expect.forbidClick ?? [] where clicks.contains(id) {
            failures.append("clicked forbidden \(id)")
        }
        return failures
    }

    static func run(_ task: EvalTask, variant: Variant, number: Int, router: ModelRouter) async throws -> RunResult {
        let desktop = SimulatedDesktop(app: task.app)
        // The deterministic offline System 1, as SystemOneEval measures it.
        let engine = TypeSafeDecisionEngine(customEvaluator: { _ in throw Offline() })
        let planner = DefaultSubgoalPlanner(modelExecutor: router.usableChain(for: .answer).first.flatMap { try? router.executor(for: $0) })
        let makeCoordinator: @Sendable (AutonomousLoopConfig) -> TwoTierAutonomousLoopCoordinator = { config in
            TwoTierAutonomousLoopCoordinator(
                planner: planner, decisionEngine: engine, synthesizer: desktop, snapshotProvider: desktop,
                config: config, keystrokeApprover: AutoApproveToolApprover())
        }
        let log = CallLog()
        let started = Date()
        let answer: String

        switch variant {
        case .handoff:
            // `Copilot.executeAutonomousGoal`'s config, without the settling delay a simulation does not need.
            let config = AutonomousLoopConfig(
                maxTotalSteps: 20, defaultSubgoalMaxSteps: 10, confidenceThreshold: 0.80, settlingDelayMs: 0,
                identicalActionThreshold: 3, unchangedStateThreshold: 3)
            answer = await AutonomousActOutput.run(makeCoordinator(config), goal: task.request).summary
        case .folded, .tool:
            var tools: [any AgentTool] = [
                InspectUIElementsTool(inspectorProvider: { _ in desktop }),
                ClickElementTool(synthesizer: desktop, inspectorProvider: { _ in desktop }, trustsCallerApproval: true),
                TypeSafeActTool(
                    inspectorProvider: { _ in desktop }, engineProvider: { engine }, synthesizer: desktop,
                    approver: AutoApproveToolApprover(), frontmostApp: { task.app.name }),
            ]
            if variant == .tool {
                tools.append(RunDesktopTaskTool { config in
                    var config = config
                    config.settlingDelayMs = 0
                    return makeCoordinator(config)
                })
            }
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-loop-eval-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: storeURL) }
            let agent = Agent(
                router: router, store: try SQLiteContextStore(url: storeURL),
                tools: ToolRegistry(tools: tools.map { Recording(base: $0, log: log) }), health: HealthRegistry(),
                language: .japanese)
            do {
                answer = try await agent.answer(
                    task.request,
                    isAutonomousAction: true,
                    triage: ComputerActionTriage(needsComputerAction: true, confidence: 0.9, intentCategory: "gui_interaction"))
            } catch {
                answer = "(error: \(error))"
            }
        }

        let state = desktop.finalState
        let clicks = desktop.clicks
        let failures = grade(task, state: state, answer: answer, clicks: clicks)
        return RunResult(
            task: task.id, variant: variant, run: number, passed: failures.isEmpty, failures: failures,
            state: state, answer: String(answer.prefix(400)), tools: await log.names, clicks: clicks,
            seconds: Date().timeIntervalSince(started))
    }

    // MARK: - Test

    @Test("tasks decode and every expectation is reachable in its app")
    func evaluate() async throws {
        let tasks = try Self.loadTasks()
        #expect(tasks.count >= 10)
        #expect(Set(tasks.map(\.id)).count == tasks.count, "duplicate task ids")
        for task in tasks {
            let screens = Set(task.app.screens.keys)
            #expect(screens.contains(task.app.start), "\(task.id): unknown start screen")
            let targets = task.app.screens.values.flatMap { $0.compactMap(\.go) }
                + (task.app.onEnter ?? [:]).values.compactMap(\.go) + (task.app.onScroll ?? [:]).values.compactMap(\.go)
            #expect(targets.allSatisfy(screens.contains), "\(task.id): transition to an unknown screen")
            if let screen = task.expect.state["_screen"] { #expect(screens.contains(screen), "\(task.id): unknown _screen") }
        }

        let environment = ProcessInfo.processInfo.environment
        guard environment["MCA_AGENT_EVAL"] == "1", let key = environment["GEMINI_API_KEY"], !key.isEmpty else { return }

        let router = ModelRouter(
            policy: RoutingPolicy(routes: [.answer: RoutingPolicy.default.routes[.answer]!],
                maxOutputTokens: RoutingPolicy.default.maxOutputTokens),
            credentials: CredentialStore(overrides: ["gemini": key], environment: [:]))
        let runs = Int(environment["MCA_AGENT_EVAL_RUNS"] ?? "") ?? 2
        let only = environment["MCA_AGENT_EVAL_VARIANTS"].map { Set($0.split(separator: ",").compactMap { Variant(rawValue: String($0)) }) }
            ?? Set(Variant.allCases)

        var results: [RunResult] = []
        for task in tasks {
            for variant in Variant.allCases where only.contains(variant) {
                for number in 1...runs {
                    let result = try await Self.run(task, variant: variant, number: number, router: router)
                    print("AgentLoopEval \(task.id) \(variant.rawValue)#\(number) \(result.passed ? "PASS" : "FAIL") "
                        + "\(String(format: "%.1f", result.seconds))s tools=\(result.tools) \(result.failures)")
                    results.append(result)
                }
            }
        }
        for variant in Variant.allCases where only.contains(variant) {
            let mine = results.filter { $0.variant == variant }
            let seconds = mine.map(\.seconds).reduce(0, +) / Double(max(mine.count, 1))
            print("AgentLoopEval SUMMARY \(variant.rawValue): \(mine.filter(\.passed).count)/\(mine.count) passed, "
                + "mean \(String(format: "%.1f", seconds))s")
        }
        if let path = environment["MCA_EVAL_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(results).write(to: URL(fileURLWithPath: path))
        }
    }
}
