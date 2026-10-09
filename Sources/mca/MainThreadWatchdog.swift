import Foundation
import OSLog

/// Logs when the main thread stops answering.
///
/// A hung main thread logs nothing at all, so without this a frozen chat looks
/// the same in the log as a model that is still thinking.
final class MainThreadWatchdog: Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "MainThread")
    private let queue = DispatchQueue(label: "com.buddypia.mca.main-thread-watchdog", qos: .utility)

    func start() {
        queue.async { self.check() }
    }

    private func check() {
        let sent = DispatchTime.now()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { answered.signal() }
        if answered.wait(timeout: .now() + .seconds(2)) == .timedOut {
            log.error("Main thread has not responded for 2 s")
            answered.wait()
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
            log.error("Main thread responded again after \(milliseconds, privacy: .public) ms")
        }
        queue.asyncAfter(deadline: .now() + 1) { self.check() }
    }
}
