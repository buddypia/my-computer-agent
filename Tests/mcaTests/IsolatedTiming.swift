import Foundation

/// Main-thread latency, watchdog hangs and resident memory belong to the whole test process. Under a
/// parallel `swift test` every other test's work lands in them: in CI run 38265466985 three suites tripped
/// together, one on a 7.68s main-thread stall while its own work ran off the main thread. The functional
/// checks of those tests always run; the process-wide numbers are asserted only on request:
///
///     MCA_ISOLATED_TIMING=1 swift test --no-parallel --filter StressTests
///
/// That run is a diagnostic, not a CI guard: a cold process (first window, first OCR) can still stall.
enum IsolatedTiming {
    static let enabled = ProcessInfo.processInfo.environment["MCA_ISOLATED_TIMING"] == "1"
}
