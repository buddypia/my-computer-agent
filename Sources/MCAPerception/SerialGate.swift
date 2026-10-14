/// Runs async work one call at a time, in arrival order.
///
/// An actor alone does not do this: it is reentrant, so a second call starts
/// as soon as the first suspends. A caller cancelled while waiting still waits
/// its turn; the work it then runs sees the cancellation and returns early.
final class SerialGate: Sendable {
    private let state = State()

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await state.acquire()
        do {
            let value = try await work()
            await state.release()
            return value
        } catch {
            await state.release()
            throw error
        }
    }

    private actor State {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard busy else {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
