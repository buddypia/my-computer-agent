import Darwin
import Foundation

/// Owns only the child process launched for this tool invocation.
/// Cancellation before launch and during execution share one locked state.
enum CancellableToolProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        /// Time spent supervising the process, excluding caller-executor rescheduling.
        let supervisorElapsed: Duration
    }
    // Deadline and force-stop callbacks must not queue behind unrelated global work.
    private static let timeoutQueue = DispatchQueue(
        label: "com.buddypia.mca.tool-process-timeouts",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var timedOut = false
        private var pid: pid_t?
        private var finished = false
        func start(executable: String, arguments: [String], out: Pipe, err: Pipe) throws -> pid_t {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try check(posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
            for handle in [out.fileHandleForReading, err.fileHandleForReading, out.fileHandleForWriting, err.fileHandleForWriting] {
                try check(posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor))
            }
            var argv = ([executable] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var spawned: pid_t = 0
            let result = argv.withUnsafeMutableBufferPointer {
                posix_spawn(&spawned, executable, &actions, &attributes, $0.baseAddress!, environ)
            }
            try check(result)
            pid = spawned
            return spawned
        }
        private func check(_ code: Int32) throws {
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        func cancel(timeout: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            timedOut = timedOut || timeout
            guard !finished, let pid else { return }
            kill(-pid, SIGTERM)
            timeoutQueue.asyncAfter(deadline: .now() + 0.25) { self.forceStop() }
        }
        private func forceStop() {
            lock.lock(); defer { lock.unlock() }
            if !finished, let pid { kill(-pid, SIGKILL) }
        }
        func finish() {
            lock.lock(); defer { lock.unlock() }
            // The direct child is still unreaped, so its PID cannot be reused.
            if let pid { kill(-pid, SIGKILL) }
            finished = true
            pid = nil
        }
        func isFinished() -> Bool {
            lock.lock(); defer { lock.unlock() }; return finished
        }
        func didTimeout() -> Bool {
            lock.lock(); defer { lock.unlock() }; return timedOut
        }
    }
    private final class Text: @unchecked Sendable {
        var value = ""
    }
    private static func drain(_ handle: FileHandle, state: State) -> String {
        var data = Data(), truncated = false
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var drainDeadline: ContinuousClock.Instant?
        while true {
            if state.isFinished() {
                if drainDeadline == nil { drainDeadline = .now.advanced(by: .milliseconds(100)) }
                if let drainDeadline, ContinuousClock.now >= drainDeadline { truncated = true; break }
            }
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN || state.isFinished() { break }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let remaining = max(0, 65_536 - data.count)
            data.append(contentsOf: buffer.prefix(min(count, remaining)))
            truncated = truncated || count > remaining
        }
        return String(decoding: data, as: UTF8.self) + (truncated ? "\n… (truncated)" : "")
    }
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 15,
                    onStart: (@Sendable () -> Void)? = nil) async throws -> Output {
        try Task.checkCancellation()
        let began = ContinuousClock.now
        let state = State()
        let out = Pipe(), err = Pipe()
        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let timer = DispatchWorkItem { state.cancel(timeout: true) }
                    do {
                        let pid = try state.start(executable: executable, arguments: arguments, out: out, err: err)
                        // The child inherited its descriptors. The parent must not
                        // keep a writer alive or the concurrent readers never see EOF.
                        try? out.fileHandleForWriting.close()
                        try? err.fileHandleForWriting.close()
                        onStart?()
                        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timer)
                        let group = DispatchGroup(), stdout = Text(), stderr = Text()
                        group.enter()
                        DispatchQueue.global().async { stdout.value = drain(out.fileHandleForReading, state: state); group.leave() }
                        group.enter()
                        DispatchQueue.global().async { stderr.value = drain(err.fileHandleForReading, state: state); group.leave() }
                        var info = siginfo_t()
                        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
                            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                        }
                        state.finish()
                        var status: Int32 = 0
                        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                        timer.cancel()
                        group.wait()
                        let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                        let supervisorElapsed = began.duration(to: .now)
                        continuation.resume(returning: Output(status: exitStatus,
                            stdout: stdout.value.trimmingCharacters(in: .whitespacesAndNewlines),
                            stderr: stderr.value.trimmingCharacters(in: .whitespacesAndNewlines),
                            timedOut: state.didTimeout(), supervisorElapsed: supervisorElapsed))
                    } catch { state.cancel(); state.finish(); timer.cancel(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.cancel() }
        try Task.checkCancellation()
        return output
    }
}
