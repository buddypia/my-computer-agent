import AppKit
import CoreGraphics
import Testing

@testable import MCAPresentation

@Suite("Screen snip selection")
struct ScreenSnipTests {
    @Test("initializes ScreenSnipResult with correct values")
    func resultInitialization() {
        let rect = CGRect(x: 100, y: 150, width: 300, height: 200)
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let displayID: CGDirectDisplayID = 1

        let result = ScreenSnipResult(rect: rect, screenBounds: bounds, displayID: displayID)
        #expect(result.rect == rect)
        #expect(result.screenBounds == bounds)
        #expect(result.displayID == displayID)
    }

    @Test("dismiss resets selection state cleanly")
    @MainActor
    func controllerDismiss() {
        let controller = ScreenSnipController()
        #expect(!controller.isSelecting)

        // Calling dismiss when idle is safe
        controller.dismiss()
        #expect(!controller.isSelecting)
    }
}
