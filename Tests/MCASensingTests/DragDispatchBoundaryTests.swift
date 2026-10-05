import CoreGraphics
import Foundation
import Testing
@testable import MCASensing

@Suite("Native drag dispatch boundaries")
struct DragDispatchBoundaryTests {
    let start = CGPoint(x: 100, y: 100)
    let end = CGPoint(x: 200, y: 200)

    @Test("Cancellation or changed target stops new input at every pause", arguments: [1, 2, 3], [false, true])
    func interrupted(pauseIndex: Int, changedTarget: Bool) throws {
        var pauses = 0
        var events: [CGEventType] = []
        var locations: [CGPoint] = []
        var checks: [CGPoint] = []
        var rejected = false
        do {
            try EventSynthesizer.dispatchDrag(from: start, to: end,
                validate: { point in
                    checks.append(point)
                    if pauses >= pauseIndex {
                        if changedTarget { throw EventSynthesizer.SynthesizerError.targetChanged }
                        throw CancellationError()
                    }
                },
                move: { events.append(.mouseMoved); locations.append(start) },
                post: { events.append($0); locations.append($1) },
                pause: { _ in pauses += 1 })
        } catch {
            rejected = true
            if changedTarget {
                #expect((error as? EventSynthesizer.SynthesizerError)?.errorDescription == EventSynthesizer.SynthesizerError.targetChanged.errorDescription)
            } else { #expect(error is CancellationError) }
        }
        #expect(rejected)
        let expected: [CGEventType] = pauseIndex == 1 ? [.mouseMoved] :
            (pauseIndex == 2 ? [.mouseMoved, .leftMouseDown, .leftMouseUp] :
                [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(events == expected)
        #expect(checks.first == start)
        if pauseIndex == 2 { #expect(locations.last == start) }
        if pauseIndex == 3 { #expect(locations.last == end) }
    }

    @Test("Initially invalid target dispatches nothing")
    func initiallyInvalid() {
        var count = 0
        #expect(throws: CancellationError.self) {
            try EventSynthesizer.dispatchDrag(from: start, to: end,
                validate: { _ in throw CancellationError() },
                move: { count += 1 }, post: { _, _ in count += 1 }, pause: { _ in })
        }
        #expect(count == 0)
    }

    @Test("Successful drag checks both points and releases once at the last position")
    func successful() throws {
        var checks: [CGPoint] = []
        var events: [CGEventType] = []
        var locations: [CGPoint] = []
        var delays: [TimeInterval] = []
        try EventSynthesizer.dispatchDrag(from: start, to: end,
            validate: { checks.append($0) }, move: { events.append(.mouseMoved); locations.append(start) },
            post: { events.append($0); locations.append($1) }, pause: { delays.append($0) })
        #expect(events == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(checks == [start, start, end, end])
        #expect(locations == [start, start, end, end])
        #expect(delays == [0.01, 0.02, 0.02])
    }
}
