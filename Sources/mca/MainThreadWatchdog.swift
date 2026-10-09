import Foundation
import os
import OSLog

/// Logs when the main thread stops answering.
///
/// A hung main thread logs nothing at all, so without this a frozen chat looks
/// the same in the log as a model that is still thinking.
final class MainThreadWatchdog: Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "MainThread")
    private let queue = DispatchQueue(label: "com.buddypia.mca.main-thread-watchdog", qos: .utility)
    private let targetQueue: DispatchQueue
    private let timeoutSeconds: Int
    private let pollIntervalSeconds: Int
    private let onHang: (@Sendable (Int) -> Void)?
    private let onRecovered: (@Sendable (UInt64) -> Void)?
    private let isRunning = OSAllocatedUnfairLock(initialState: false)

    init(
        targetQueue: DispatchQueue = .main,
        timeoutSeconds: Int = 2,
        pollIntervalSeconds: Int = 1,
        onHang: (@Sendable (Int) -> Void)? = nil,
        onRecovered: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.targetQueue = targetQueue
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.onHang = onHang
        self.onRecovered = onRecovered
    }

    func start() {
        let shouldStart = isRunning.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in
            self?.check()
        }
    }

    func stop() {
        isRunning.withLock { $0 = false }
    }

    private func check() {
        guard isRunning.withLock({ $0 }) else { return }
        let sent = DispatchTime.now()
        let answered = DispatchSemaphore(value: 0)
        targetQueue.async { answered.signal() }
        if answered.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            log.error("Main thread has not responded for \(self.timeoutSeconds, privacy: .public) s")
            onHang?(timeoutSeconds)
            var elapsedSeconds = timeoutSeconds
            // Poll in 5-second increments so the watchdog thread is not indefinitely blocked,
            // continuing to log periodic warnings while the thread remains unresponsive.
            while answered.wait(timeout: .now() + .seconds(5)) == .timedOut {
                guard isRunning.withLock({ $0 }) else { return }
                elapsedSeconds += 5
                log.error("Main thread still not responding (\(elapsedSeconds, privacy: .public) s elapsed)")
                onHang?(elapsedSeconds)
            }
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000
            log.error("Main thread responded again after \(milliseconds, privacy: .public) ms")
            onRecovered?(milliseconds)
        }
        queue.asyncAfter(deadline: .now() + .seconds(pollIntervalSeconds)) { [weak self] in
            guard let self, self.isRunning.withLock({ $0 }) else { return }
            self.check()
        }
    }
}
