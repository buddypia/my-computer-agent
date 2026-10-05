import Foundation
import MCACore

/// Where a chat request goes once it has been triaged.
///
/// Extracted from `Copilot` so the routing rule is a pure function that both the
/// app and the System One eval (`Evals/system-one`) exercise. An eval that graded
/// a re-implementation of this rule would drift from what users actually get.
public enum RequestRoute: String, Sendable, Codable, CaseIterable {
    /// The actuator loop drives the GUI and produces no conversational answer.
    case autonomousLoop = "loop"
    /// `Agent.answer` with a screenshot and computer-use tools enabled.
    case agentWithComputer = "agent_action"
    /// `Agent.answer` with a screenshot, but no computer action requested.
    case agentWithScreen = "agent_screen"
    /// `Agent.answer` with text only. Nothing leaves the machine but the question.
    case agentChat = "agent_chat"

    /// The goal after an explicit `/act ` or `/goal ` prefix, or `nil` when there is none.
    /// This is what gets triaged and run in place of the raw question.
    public static func explicitGoal(in question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/act ", "/goal "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// - Parameters:
    ///   - question: The raw user text, including any `/act ` or `/goal ` prefix.
    ///   - triage: The System One triage of the question (or of its explicit goal).
    public static func decide(question: String, triage: ComputerActionTriage) -> RequestRoute {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExplicitAutonomous = trimmed.hasPrefix("/act ") || trimmed.hasPrefix("/goal ")

        // Informational questions, summaries, extractions, or list requests (e.g. "Xでビューが5K以上のTweetをまとめて教えて")
        // must be synthesized into an answer by Agent.answer using background tools (e.g. scroll_page_content),
        // rather than bypassed into the pure actuator loop which produces no conversational response.
        let isInformational = ScreenIntent.isInformationalRequest(question)
        let runsLoop = isExplicitAutonomous || (
            !isInformational &&
            triage.needsComputerAction &&
            triage.confidence >= 0.80 &&
            (triage.intentCategory == "gui_interaction" || triage.intentCategory == "browser_scroll_or_search")
        )

        if runsLoop { return .autonomousLoop }
        if triage.needsComputerAction { return .agentWithComputer }
        if ScreenIntent.isScreenQuestion(question) { return .agentWithScreen }
        return .agentChat
    }
}
