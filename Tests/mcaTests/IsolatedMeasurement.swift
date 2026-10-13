import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// For a test whose assertion measures the whole test process — main-thread
    /// latency, the watchdog, resident memory, wall-clock bounds. In the parallel
    /// run that is the neighbours' work as much as the subject's, and on a slow
    /// runner it fails for them. Skipped there; `Scripts/gate.sh` runs these alone,
    /// one at a time, by the `…Isolated` suffix the function name must carry.
    static var isolatedMeasurement: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["MCA_ISOLATED_TESTS"] == "1",
            "measures the whole process; runs alone in the gate's isolated pass")
    }
}
