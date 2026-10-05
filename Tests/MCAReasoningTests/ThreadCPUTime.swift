import Foundation

/// CPU time this thread spent in `body`, in milliseconds. Unlike wall-clock time it does
/// not grow when other processes compete for the cores, so a budget measured with it
/// catches an algorithmic slowdown without failing on a loaded machine.
func threadCPUMilliseconds(_ body: () -> Void) -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
}
