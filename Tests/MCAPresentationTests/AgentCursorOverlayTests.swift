import CoreGraphics
import Foundation
import Testing

@testable import MCACore
@testable import MCAPresentation

/// The agent's pointer is only useful if it lands exactly where the agent
/// clicked, on whichever display that was, and only while the agent is acting.
@Suite("Agent cursor overlay")
@MainActor
struct AgentCursorOverlayTests {
    @Test("a Quartz point lands at the same place on the primary display")
    func primaryDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let local = AgentCursorGeometry.localPoint(CGPoint(x: 100, y: 40), screenFrame: frame, primaryHeight: 1117)
        #expect(local == CGPoint(x: 100, y: 40))
    }

    /// Cocoa puts a display above the primary at positive y; Quartz at negative y.
    /// Getting the pivot wrong draws the pointer on the wrong row of the wrong screen.
    @Test("a display above and to the left of the primary is converted through the primary's height")
    func secondaryDisplay() {
        let primaryHeight: CGFloat = 1117
        let above = CGRect(x: -500, y: 1117, width: 2560, height: 1440)
        // Its top-left corner in Quartz is (-500, -1440).
        let topLeft = AgentCursorGeometry.localPoint(CGPoint(x: -500, y: -1440), screenFrame: above, primaryHeight: primaryHeight)
        #expect(topLeft == .zero)
        let inside = AgentCursorGeometry.localPoint(CGPoint(x: 0, y: -100), screenFrame: above, primaryHeight: primaryHeight)
        #expect(inside == CGPoint(x: 500, y: 1340))
        #expect(above.contains(AgentCursorGeometry.cocoaPoint(CGPoint(x: 0, y: -100), primaryHeight: primaryHeight)))
    }

    @Test("hidden until the agent acts, kept while it works, gone soon after it finishes")
    func presence() {
        var presence = AgentCursorPresence()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!presence.isVisible(now: start, agentBusy: true))

        presence.recordInput(at: start)
        // Thinking about the next screenshot is still "the AI has the controls".
        #expect(presence.isVisible(now: start.addingTimeInterval(30), agentBusy: true))
        #expect(presence.isVisible(now: start.addingTimeInterval(1), agentBusy: false))
        #expect(!presence.isVisible(now: start.addingTimeInterval(2), agentBusy: false))
        // A busy flag that never clears cannot pin the frame on screen.
        #expect(!presence.isVisible(now: start.addingTimeInterval(121), agentBusy: true))

        presence.reset()
        #expect(!presence.isVisible(now: start, agentBusy: true))
    }

    /// A stop must stick: input already in flight when the user pressed it
    /// cannot bring the frame back.
    @Test("after Stop, in-flight input is ignored for the quiet period")
    func quietAfterStop() {
        var presence = AgentCursorPresence()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        presence.recordInput(at: start)
        presence.stopped(at: start)
        #expect(!presence.isVisible(now: start, agentBusy: true))
        #expect(!presence.accepts(.click(.zero, count: 1, secondary: false), isShowing: false, now: start.addingTimeInterval(0.5)))
        #expect(presence.accepts(.click(.zero, count: 1, secondary: false), isShowing: false, now: start.addingTimeInterval(1.1)))
    }

    /// The loop releases held buttons as cleanup after a stop or a failed step.
    @Test("releasing held input alone does not show the overlay")
    func releaseIsNotActivity() {
        let presence = AgentCursorPresence()
        let now = Date()
        #expect(!presence.accepts(.released, isShowing: false, now: now))
        #expect(presence.accepts(.released, isShowing: true, now: now))
        #expect(presence.accepts(.keyboard, isShowing: false, now: now))
    }

    @Test("clicks leave one ripple per click and move the pointer")
    func clicks() {
        let model = AgentCursorModel()
        model.apply(.click(CGPoint(x: 10, y: 20), count: 2, secondary: false))
        #expect(model.cursor == CGPoint(x: 10, y: 20))
        #expect(model.ripples.count == 2)

        model.apply(.keyboard)
        #expect(model.activity == .typing)
        #expect(model.cursor == CGPoint(x: 10, y: 20))

        model.apply(.drag(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 50, y: 60)))
        #expect(model.cursor == CGPoint(x: 50, y: 60))
        #expect(model.activity == .dragging)

        for _ in 0..<20 { model.apply(.click(.zero, count: 1, secondary: true)) }
        #expect(model.ripples.count <= 12)

        model.clear()
        #expect(model.cursor == nil && model.ripples.isEmpty && !model.isVisible)
    }
}
