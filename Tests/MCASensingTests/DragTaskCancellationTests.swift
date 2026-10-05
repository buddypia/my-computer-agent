import CoreGraphics
import Foundation
import Testing
@testable import MCASensing

@Suite("Drag task cancellation propagation")
struct DragTaskCancellationTests {
    @Test("Actual child Task cancellation at a pause permits only necessary release", arguments: [1, 2, 3])
    func taskCancellation(pauseIndex: Int) async {
        let child = Task {
            let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 200, y: 200)
            var pauses = 0
            var events: [UInt32] = []
            var cancelled = false
            do {
                try EventSynthesizer.dispatchDrag(from: start, to: end,
                    validate: { _ in try Task.checkCancellation() },
                    move: { events.append(CGEventType.mouseMoved.rawValue) },
                    post: { event, _ in events.append(event.rawValue) },
                    pause: { _ in
                        pauses += 1
                        if pauses == pauseIndex { withUnsafeCurrentTask { $0?.cancel() } }
                    })
            } catch is CancellationError { cancelled = true }
            catch { Issue.record("Unexpected error: \(error)") }
            return (events, cancelled)
        }
        let (events, cancelled) = await child.value
        let expected: [CGEventType] = pauseIndex == 1 ? [.mouseMoved] :
            (pauseIndex == 2 ? [.mouseMoved, .leftMouseDown, .leftMouseUp] :
                [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(cancelled)
        #expect(events == expected.map(\.rawValue))
        #expect(!Task.isCancelled)
    }
}
