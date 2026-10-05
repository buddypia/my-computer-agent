import Foundation
import MCAReasoning
import Testing

@Suite("Bounded screen content collection")
struct ScreenContentCollectorTests {
    private actor Fixture {
        let pages: [String]
        var index = 0
        var scrolls = 0
        init(_ pages: [String]) { self.pages = pages }
        func read() -> String { pages[min(index, pages.count - 1)] }
        func scroll() { scrolls += 1; index += 1 }
    }

    @Test("Repeated metric lines remain associated with their own viewport")
    func repeatedMetrics() async throws {
        let fixture = Fixture(["@alice\nFirst post\n5K views", "@bob\nSecond post\n5K views"])
        let collector = ScreenContentCollector(readViewport: { await fixture.read() }, scroll: { await fixture.scroll() })
        let result = try await collector.collect(maxScrolls: 1, delay: .zero)
        #expect(result.viewports.count == 2)
        #expect(result.viewports[1].contains("@bob\nSecond post\n5K views"))
        #expect(result.scrolls == 1)
        #expect(result.stopReason == .budget)
    }

    @Test("Scroll failure returns observed content with a partial coverage reason")
    func scrollFailure() async throws {
        let collector = ScreenContentCollector(readViewport: { "original" }, scroll: { throw Failure.targetChanged })
        let result = try await collector.collect(maxScrolls: 4, delay: .zero)
        #expect(result.viewports == ["original"])
        #expect(result.scrolls == 0)
        #expect(result.stopReason == .failed)
        #expect(result.error?.contains("targetChanged") == true)
    }

    @Test("An unchanged viewport stops collection without claiming the feed ended")
    func unchanged() async throws {
        let fixture = Fixture(["same"])
        let collector = ScreenContentCollector(readViewport: { await fixture.read() }, scroll: { await fixture.scroll() })
        let result = try await collector.collect(maxScrolls: 10, delay: .zero)
        #expect(result.scrolls == 2)
        #expect(result.stopReason == .unchanged)
    }

    @Test("Cancellation stops before another scroll")
    func cancelled() async throws {
        let fixture = Fixture(["same"])
        let task = Task {
            let collector = ScreenContentCollector(readViewport: {
                withUnsafeCurrentTask { $0?.cancel() }
                return "initial"
            }, scroll: { await fixture.scroll() })
            return try await collector.collect(maxScrolls: 10, delay: .zero)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.scrolls == 0)
    }
    private enum Failure: Error { case targetChanged }
}
