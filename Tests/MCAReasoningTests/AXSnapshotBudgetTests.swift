@testable import MCAReasoning
@testable import MCASensing
import Testing

@Suite("AX snapshot budget")
struct AXSnapshotBudgetTests {
    @Test("A snapshot of a busy app fits well inside one tool call's time limit")
    func snapshotFitsToolTimeout() {
        // Before/after snapshots around an approval, each a bounded walk plus
        // one node's worst case (batched read failing into ~8 single queries).
        let perNode = Duration.milliseconds(Int(AccessibilityInspector.messagingTimeout * 1000) * 8)
        let snapshot = AccessibilityInspector.traversalBudget + perNode
        #expect(snapshot * 2 < ToolRegistry.defaultTimeout / 4)
        // Below the ~6s system default, which is what made an 800-node walk unbounded.
        #expect(AccessibilityInspector.messagingTimeout <= 1)
    }
}
