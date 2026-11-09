import ApplicationServices
import CoreGraphics
import MCACore
@testable import MCASensing
import Testing

@Suite("AX ref geometry")
struct AXRefGeometryTests {
    private let saved = CGRect(x: 100, y: 200, width: 40, height: 20)

    @Test("an OCR ref without an element is located by its saved bounds")
    func ocrRefUsesSavedBounds() throws {
        let ref = BrowserElementRef(id: "ocr-1", role: "button", name: "Follow", frameOrdinal: 0, bounds: nil)
        let point = try AXBrowserDriver.center(of: ref, element: nil, savedBounds: saved, knownRefs: 1)
        #expect(point == CGPoint(x: 120, y: 210))
    }

    /// An element of a process that does not exist cannot be measured; under any
    /// permission state it must not be clicked at where it used to be.
    @Test("an element ref that cannot be measured never falls back to its saved bounds")
    func unmeasurableElementIsRefused() {
        let ref = BrowserElementRef(id: "0-7", role: "button", name: "Send", frameOrdinal: 0, bounds: saved)
        let gone = AXUIElementCreateApplication(-1)
        #expect(throws: BrowserError.self) {
            _ = try AXBrowserDriver.center(of: ref, element: gone, savedBounds: saved, knownRefs: 3)
        }
    }

    @Test("a ref with no geometry at all is refused")
    func noGeometryIsRefused() {
        let ref = BrowserElementRef(id: "ocr-2", role: "button", name: "Go", frameOrdinal: 0, bounds: nil)
        #expect(throws: BrowserError.self) {
            _ = try AXBrowserDriver.center(of: ref, element: nil, savedBounds: nil, knownRefs: 0)
        }
    }
}
