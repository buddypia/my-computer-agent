import Foundation
import MCACore
import Testing

@testable import MCASensing

@Suite("DesktopEventSource")
struct DesktopEventSourceTests {
    @Test("Events that pile up while the consumer is busy collapse to the newest one")
    func backlogCollapsesToNewest() async {
        let source = DesktopEventSource(typingPauseSeconds: 60)
        let events = source.events()

        // Nothing is consuming yet: this is the state while a capture is in flight.
        source.emit(.windowTitleChanged)
        source.emit(.windowTitleChanged)
        source.emit(.focusChanged)
        source.stop()

        var delivered: [CaptureTrigger] = []
        for await event in events { delivered.append(event.trigger) }
        #expect(delivered == [.focusChanged])
    }
}
