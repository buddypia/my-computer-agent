import Foundation

/// Structured result of one run of the two-tier loop, as a tool returns it.
///
/// One schema for every caller of the loop — the built-in agent's
/// `run_desktop_task` and the MCP `autonomous_act` — so a caller that reads
/// one can read the other.
public struct AutonomousActOutput: Codable, Sendable, Equatable {
    /// Whether the autonomous goal was successfully accomplished.
    public let isSuccess: Bool

    /// Total number of micro-action steps executed by System 1.
    public let totalSteps: Int

    /// Number of subgoals fully accomplished and verified.
    public let subgoalsCompleted: Int

    /// Total number of subgoals decomposed by System 2.
    public let totalSubgoals: Int

    /// Human- and machine-readable execution summary.
    public let summary: String

    /// Total elapsed execution duration in seconds.
    public let durationSeconds: Double

    /// Machine-parseable termination identifier.
    public let terminationReason: String?

    public init(
        isSuccess: Bool,
        totalSteps: Int,
        subgoalsCompleted: Int,
        totalSubgoals: Int,
        summary: String,
        durationSeconds: Double,
        terminationReason: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.totalSteps = totalSteps
        self.subgoalsCompleted = subgoalsCompleted
        self.totalSubgoals = totalSubgoals
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.terminationReason = terminationReason
    }

    public init(summary: ExecutionSummary) {
        self.isSuccess = summary.isSuccess
        self.totalSteps = summary.totalSteps
        self.subgoalsCompleted = summary.subgoalsCompleted
        self.totalSubgoals = summary.totalSubgoals
        self.summary = summary.finalMessage.isEmpty
            ? (summary.isSuccess ? "Goal completed successfully." : "Autonomous execution ended.")
            : summary.finalMessage
        self.durationSeconds = summary.durationSeconds
        self.terminationReason = summary.terminationReason.isEmpty
            ? (summary.isSuccess ? "completed" : "terminated")
            : summary.terminationReason
    }

    /// Runs `coordinator` to the end and reports how it ended. A loop that
    /// stops early is a result the caller reasons about, not an error it has
    /// to catch.
    public static func run(
        _ coordinator: TwoTierAutonomousLoopCoordinator,
        goal: String,
        cancellationToken: CancellationToken = CancellationToken()
    ) async -> AutonomousActOutput {
        do {
            let summary = try await withTaskCancellationHandler {
                try await coordinator.execute(goal: goal, cancellationToken: cancellationToken)
            } onCancel: {
                cancellationToken.cancel()
            }
            return AutonomousActOutput(summary: summary)
        } catch let error as LoopExecutionError {
            return AutonomousActOutput(
                isSuccess: false, totalSteps: 0, subgoalsCompleted: 0, totalSubgoals: 0,
                summary: "Autonomous loop execution ended with error: \(error.localizedDescription)",
                durationSeconds: 0.0, terminationReason: "\(error)")
        } catch {
            return AutonomousActOutput(
                isSuccess: false, totalSteps: 0, subgoalsCompleted: 0, totalSubgoals: 0,
                summary: "Execution failed: \(error.localizedDescription)",
                durationSeconds: 0.0, terminationReason: "executionFailed")
        }
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Every field is a plain string, number or bool, so encoding cannot fail.
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// The two-tier loop (System 2 plan, System 1 steps) called as a tool.
///
/// The "subagent called as a tool" stage of folding the loop into the main agent
/// loop (`docs/architecture/single-agent-loop.md`). On `Evals/agent-loop` it lost to
/// the agent planning with single-step tools — it inherits System 1's slips and
/// reports them as success — so the app does not register it. It stays as the
/// eval's `tool` variant, to re-measure when the model or System 1 changes.
///
/// Gates are the loop's own: clicks need the caller's `ActionAuthorization`
/// session, keystrokes the `ToolApproving` the factory passes in.
public struct RunDesktopTaskTool: AgentTool {
    /// Builds a coordinator for one run, or `nil` when its owner is gone.
    /// Async so an owner on the main actor can read its current engine.
    public typealias CoordinatorFactory = @Sendable (AutonomousLoopConfig) async -> TwoTierAutonomousLoopCoordinator?

    /// Leaves the agent time to answer within `ToolRegistry.defaultTimeout`
    /// instead of being cut off mid-step by the registry.
    static let maxDurationSeconds = 80

    private let makeCoordinator: CoordinatorFactory

    public init(makeCoordinator: @escaping CoordinatorFactory) {
        self.makeCoordinator = makeCoordinator
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "run_desktop_task",
            description: """
                Hands a multi-step GUI task in the frontmost app (open a menu, click through a dialog, \
                fill several fields, page through a list) to an on-device planner that clicks and types \
                step by step, and returns JSON: isSuccess, totalSteps, subgoalsCompleted, totalSubgoals, \
                summary, terminationReason. Use it when the task takes several actions on the same \
                screen; for a single action use `typesafe_act` or `click_element`, and for web pages the \
                `browser_*` tools. isSuccess is the planner's own judgement — check the screen with \
                `inspect_ui_elements` or `read_current_screen` before telling the user it worked.
                """,
            parameters: Data("""
                {
                  "type": "object",
                  "properties": {
                    "goal": {
                      "type": "string",
                      "description": "The outcome to reach, stated concretely (e.g. 'Turn on Dark Mode in System Settings > Appearance')."
                    },
                    "max_steps": {
                      "type": "integer",
                      "description": "Upper bound on actions, 1-40 (default 20)."
                    }
                  },
                  "required": ["goal"]
                }
                """.utf8))
    }

    public func invoke(arguments: Data) async throws -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        guard let goal = parsed.string("goal")?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
            return "Error: 'goal' parameter is required."
        }
        let maxSteps = min(max(parsed.int("max_steps") ?? 20, 1), 40)
        let config = AutonomousLoopConfig(
            maxTotalSteps: maxSteps,
            defaultSubgoalMaxSteps: min(maxSteps, 10),
            confidenceThreshold: 0.80,
            settlingDelayMs: 100,
            identicalActionThreshold: 3,
            unchangedStateThreshold: 3,
            maxDurationSeconds: Self.maxDurationSeconds
        )
        guard let coordinator = await makeCoordinator(config) else {
            return "Error: desktop automation is unavailable."
        }
        return await AutonomousActOutput.run(coordinator, goal: goal).json
    }
}
