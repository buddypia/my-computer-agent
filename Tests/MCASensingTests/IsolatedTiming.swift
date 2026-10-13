import Foundation

/// Wall-clock bounds on work that waits for the shared cooperative pool, and resident memory, belong to the
/// whole test process: under a parallel `swift test` every other test's load lands in them (CI run
/// 38380587314: reading an invalid PID took 1.7s on a detached task). The functional checks of those
/// tests always run; the process-wide numbers are asserted only on request, as a diagnostic:
///
///     MCA_ISOLATED_TIMING=1 swift test --no-parallel --filter MCASensingTests
///
/// mcaTests has the same switch for main-thread latency.
enum IsolatedTiming {
    static let enabled = ProcessInfo.processInfo.environment["MCA_ISOLATED_TIMING"] == "1"
}
