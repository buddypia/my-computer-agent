import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("run_desktop_task: the two-tier loop called as an agent tool")
struct RunDesktopTaskToolTests {
    private actor ConfigRecorder {
        private(set) var configs: [AutonomousLoopConfig] = []
        func record(_ config: AutonomousLoopConfig) { configs.append(config) }
    }

    private func snapshot(_ title: String, _ candidates: [UIElementCandidate]) -> UIStateSnapshot {
        UIStateSnapshot(
            windowTitle: title, appBundleId: "com.apple.Safari", appName: "Safari",
            focusedElementId: nil, visibleCandidates: candidates, timestamp: Date(),
            frameHash: "hash_\(title)")
    }

    private func arguments(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("Runs the loop and returns the shared JSON result to the calling agent")
    func returnsSharedResult() async throws {
        let next = UIElementCandidate(id: "btn_next", role: "AXButton", label: "Next",
            bounds: CGRect(x: 200, y: 200, width: 80, height: 30))
        let synthesizer = MockEventSynthesizer()
        let recorder = ConfigRecorder()
        let tool = RunDesktopTaskTool { config in
            await recorder.record(config)
            return TwoTierAutonomousLoopCoordinator(
                planner: MockPlanningLLM.staticPlan(subgoals: [
                    Subgoal(id: "sg", description: "Click Next", expectedOutcome: "Page 2", maxSteps: 3)
                ]),
                decisionEngine: TypeSafeDecisionEngine(client: MockTypeSafeEvaluator.scripted(
                    targetChoice: "btn_next", actionChoice: "click")),
                synthesizer: synthesizer,
                inspector: MockUIInspector(snapshots: [
                    snapshot("Page 1", [next]), snapshot("Page 2 - Complete", []),
                ]),
                config: .testing)
        }

        let result = try await tool.invoke(arguments: arguments(["goal": "Go to page 2", "max_steps": 99]))
        let output = try JSONDecoder().decode(AutonomousActOutput.self, from: Data(result.utf8))

        #expect(output.isSuccess)
        #expect(output.totalSteps == 1)
        #expect(synthesizer.recordedEvents.count == 1)
        let config = try #require(await recorder.configs.first)
        #expect(config.maxTotalSteps == 40)
        #expect(config.maxDurationSeconds == RunDesktopTaskTool.maxDurationSeconds)
        #expect(Duration.seconds(config.maxDurationSeconds) < ToolRegistry.defaultTimeout)
    }

    @Test("Without an approval session the loop's click gate holds, and the refusal comes back as a result")
    func gateRefusalIsAResult() async throws {
        let delete = UIElementCandidate(id: "delete", role: "AXButton", label: "Delete",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30))
        let synthesizer = MockEventSynthesizer(isSimulation: false)
        let tool = RunDesktopTaskTool { config in
            TwoTierAutonomousLoopCoordinator(
                planner: MockPlanningLLM.staticPlan(subgoals: [
                    Subgoal(description: "Click Delete", expectedOutcome: "Document removed", maxSteps: 2)
                ]),
                decisionEngine: TypeSafeDecisionEngine(client: MockTypeSafeEvaluator.stepSequence([
                    (target: "delete", action: "click", confidence: 0.99, text: nil as String?, isCompleted: 0.0)
                ])),
                synthesizer: synthesizer,
                inspector: MockUIInspector(snapshots: [snapshot("Document", [delete])]),
                config: .testing)
        }

        let result = try await tool.invoke(arguments: arguments(["goal": "Delete document"]))
        let output = try JSONDecoder().decode(AutonomousActOutput.self, from: Data(result.utf8))

        #expect(!output.isSuccess)
        #expect(output.summary.contains("approval_required"))
        #expect(!synthesizer.recordedEvents.contains { event in
            if case .releaseAllHeldEvents = event { return false }
            return true
        })
    }

    @Test("A missing goal or a gone owner is reported without running anything")
    func refusesWithoutRunning() async throws {
        let recorder = ConfigRecorder()
        let tool = RunDesktopTaskTool { config in
            await recorder.record(config)
            return nil
        }

        #expect(try await tool.invoke(arguments: arguments(["goal": "  "])).hasPrefix("Error:"))
        #expect(await recorder.configs.isEmpty)
        #expect(try await tool.invoke(arguments: arguments(["goal": "Open Settings"])) == "Error: desktop automation is unavailable.")
    }
}
