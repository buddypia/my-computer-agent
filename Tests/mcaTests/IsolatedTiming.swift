import Foundation

/// Main-thread latency, watchdog hangs, wall-clock bounds on the shared pool and resident memory belong
/// to the whole test process. Under the parallel `swift test` every other test's load lands in them (CI
/// run 38265466985: a 7.68s main-thread stall, sampled as other tests' window layout). The functional
/// checks of those tests always run; the process-wide numbers are asserted behind this switch, inside a
/// test named `…Isolated`, and `Scripts/gate.sh` enforces them in its G2 isolated stage — those tests
/// alone, one at a time, with `MCA_ISOLATED_TIMING=1`.
///
/// Every test target that uses it keeps an identical copy (checked by IsolatedTimingConventionTests).
enum IsolatedTiming {
    static let enabled = ProcessInfo.processInfo.environment["MCA_ISOLATED_TIMING"] == "1"
}
