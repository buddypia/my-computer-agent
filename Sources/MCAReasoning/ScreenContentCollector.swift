import Foundation

/// Keeps complete viewport records rather than deleting repeated metric lines.
/// Coverage describes only the bounded sequence that was actually observed.
public struct ScreenContentCollector: Sendable {
    public enum StopReason: String, Sendable { case budget, unchanged, timeLimit, failed }
    public struct Result: Sendable {
        public var viewports: [String]
        public var scrolls: Int
        public var stopReason: StopReason
        public var error: String?
        public var truncated: Bool
    }
    private let readViewport: @Sendable () async throws -> String
    private let scroll: @Sendable () async throws -> Void

    public init(readViewport: @escaping @Sendable () async throws -> String,
                scroll: @escaping @Sendable () async throws -> Void) {
        self.readViewport = readViewport
        self.scroll = scroll
    }

    public func collect(maxScrolls: Int = 10, delay: Duration = .milliseconds(500)) async throws -> Result {
        let clock = ContinuousClock(), started = ContinuousClock.now
        var result = Result(viewports: [], scrolls: 0, stopReason: .budget, error: nil, truncated: false)
        var previous = "", unchanged = 0
        do {
            try Task.checkCancellation()
            let initial = try await readViewport()
            result.truncated = initial.count > 8_000
            result.viewports.append(String(initial.prefix(8_000)))
            previous = initial
            for _ in 0..<max(0, min(maxScrolls, 10)) {
                try Task.checkCancellation()
                if clock.now - started >= .seconds(120) { result.stopReason = .timeLimit; break }
                try await scroll()
                result.scrolls += 1
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                let text = try await readViewport()
                result.truncated = result.truncated || text.count > 8_000
                result.viewports.append(String(text.prefix(8_000)))
                unchanged = text == previous ? unchanged + 1 : 0
                previous = text
                if unchanged >= 2 { result.stopReason = .unchanged; break }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.stopReason = .failed
            result.error = String(describing: error)
        }
        return result
    }
}
