import Foundation

public struct TimedOutError: Error, CustomStringConvertible {
    public let seconds: Double
    public var description: String { "timed out after \(Int(seconds))s" }
}

/// Runs an async `operation`, throwing `TimedOutError` if it takes too long.
///
/// Only bounds work that actually suspends. A child task that blocks its thread
/// in a synchronous C call cannot be cancelled and, if the cooperative pool is
/// saturated, can starve the timer itself — so use `withBlockingTimeout` for
/// anything that calls into CoreAudio, AVFoundation or similar.
public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimedOutError(seconds: seconds)
        }

        // Whichever finishes first wins; the loser is cancelled.
        guard let result = try await group.next() else {
            throw TimedOutError(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}

/// Runs blocking synchronous work on a dedicated thread, with a real timeout.
///
/// Several macOS APIs this app depends on block indefinitely instead of
/// failing: `AVAudioEngine.start()` without microphone permission,
/// `AudioHardwareCreateProcessTap` without audio capture permission. Running
/// those on Swift Concurrency's cooperative pool is doubly wrong — the thread
/// cannot be reclaimed, and with enough of them the pool deadlocks.
///
/// A dedicated `Thread` keeps the blocked call off the shared pool entirely, so
/// the timeout always fires even though the operation itself cannot be
/// interrupted. The orphaned thread is left to finish on its own; leaking one
/// thread is a far better outcome than a subsystem stuck at "starting…"
/// forever with no explanation.
public func withBlockingTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let box = BlockingTimeoutBox(continuation: continuation, seconds: seconds)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            box.timeout(timer: timer)
        }
        timer.resume()

        let thread = Thread {
            do {
                let val = try operation()
                box.finish(.success(val), timer: timer)
            } catch {
                box.finish(.failure(error), timer: timer)
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

private final class BlockingTimeoutBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let seconds: Double

    init(continuation: CheckedContinuation<T, Error>, seconds: Double) {
        self.continuation = continuation
        self.seconds = seconds
    }

    func finish(_ result: Result<T, Error>, timer: DispatchSourceTimer) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()

        timer.cancel()
        cont.resume(with: result)
    }

    func timeout(timer: DispatchSourceTimer) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()

        timer.cancel()
        cont.resume(throwing: TimedOutError(seconds: seconds))
    }
}
