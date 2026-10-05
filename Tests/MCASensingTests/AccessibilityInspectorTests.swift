import ApplicationServices
import CoreGraphics
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("AccessibilityInspector tests")
struct AccessibilityInspectorTests {
    @Test("Same-title AX windows resolve only to the selected Quartz frame")
    func selectedWindowIdentity() {
        let first = CGRect(x: 10, y: 10, width: 200, height: 120)
        let selected = CGRect(x: 300, y: 10, width: 200, height: 120)
        let windows: [(title: String?, bounds: CGRect?)] = [("Meeting", first), ("Meeting", selected)]
        #expect(AccessibilityInspector.uniqueWindowIndex(windows, title: "Meeting", bounds: selected) == 1)
        #expect(AccessibilityInspector.uniqueWindowIndex(windows, title: "Different", bounds: selected) == nil)
    }

    @Test("Ambiguous, absent and malformed window identities never pick the first window")
    func ambiguousSelectedWindow() {
        let frame = CGRect(x: 10, y: 10, width: 200, height: 120)
        #expect(AccessibilityInspector.uniqueWindowIndex([("Meeting", frame), ("Meeting", frame)], title: "Meeting", bounds: frame) == nil)
        #expect(AccessibilityInspector.uniqueWindowIndex([], title: "Meeting", bounds: frame) == nil)
        #expect(AccessibilityInspector.uniqueWindowIndex([("Meeting", .infinite)], title: "Meeting", bounds: .infinite) == nil)
    }

    @Test("safely ignores own process PID and returns empty candidates")
    func testIgnoresOwnProcessPID() {
        let inspector = AccessibilityInspector(maxCandidates: 10)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Passing own process PID must never inspect in-process AX elements
        let candidates = inspector.inspectFocusedWindow(targetPID: ownPID)
        #expect(candidates.isEmpty)
    }

    @Test("respects maxCandidates configuration")
    func testRespectsMaxCandidates() {
        let inspector = AccessibilityInspector(maxCandidates: 42)
        #expect(inspector.maxCandidates == 42)
    }

    @Test("has expected actionableRoles including scroll and slider")
    func testActionableRoles() {
        #expect(AccessibilityInspector.actionableRoles.contains("AXButton"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXTextField"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXPopUpButton"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXMenuItem"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXScrollArea"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXSlider"))
    }

    @Test("frontmostExternalApplication never returns own process PID")
    func testFrontmostExternalApplicationNeverReturnsOwnPID() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = AccessibilityInspector.frontmostExternalApplication() {
            #expect(app.processIdentifier != ownPID)
        }
    }

    // MARK: - Window Bounds Clipping Tests

    @Test("clipBoundsToWindow retains elements fully inside window")
    func testClipBoundsToWindow_inside() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let element = CGRect(x: 150, y: 150, width: 120, height: 40)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: window)
        #expect(clipped == element)
        #expect(clipped?.origin.x == 150)
        #expect(clipped?.origin.y == 150)
        #expect(clipped?.width == 120)
        #expect(clipped?.height == 40)
    }

    @Test("clipBoundsToWindow discards elements scrolled above viewport")
    func testClipBoundsToWindow_scrolledAbove() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let element = CGRect(x: 150, y: -200, width: 120, height: 40)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: window)
        #expect(clipped == nil)
    }

    @Test("clipBoundsToWindow discards elements scrolled below viewport")
    func testClipBoundsToWindow_scrolledBelow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Window maxY is 700. Element is at y=750.
        let element = CGRect(x: 150, y: 750, width: 120, height: 40)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: window)
        #expect(clipped == nil)
    }

    @Test("clipBoundsToWindow discards elements completely to the left or right")
    func testClipBoundsToWindow_horizontalOffscreen() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let leftElement = CGRect(x: -50, y: 200, width: 40, height: 40)
        let rightElement = CGRect(x: 950, y: 200, width: 40, height: 40)

        #expect(AccessibilityInspector.clipBoundsToWindow(leftElement, windowBounds: window) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(rightElement, windowBounds: window) == nil)
    }

    @Test("clipBoundsToWindow clips partially overlapping element to visible sub-rect and guarantees clickable center inside window")
    func testClipBoundsToWindow_partialOverlap() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600) // maxY = 700
        // Element spans y: 680 to 730 (height 50)
        let element = CGRect(x: 200, y: 680, width: 100, height: 50)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: window)
        #expect(clipped != nil)
        #expect(clipped?.origin.y == 680)
        #expect(clipped?.height == 20) // 700 - 680 = 20
        #expect(clipped?.width == 100)

        // Midpoint of original element would be y = 705 (outside the window!)
        // Midpoint of clipped element must be y = 690 (safely inside the window!)
        if let clipped {
            #expect(clipped.midY < window.maxY)
            #expect(clipped.midY >= window.minY)
        }
    }

    @Test("clipBoundsToWindow discards negligible slivers (< 3 pt)")
    func testClipBoundsToWindow_negligibleSliver() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        // 1px overlap at top: element y: 80 to 101, intersection height = 1
        let element1 = CGRect(x: 150, y: 80, width: 100, height: 21)
        #expect(AccessibilityInspector.clipBoundsToWindow(element1, windowBounds: window) == nil)

        // 2px overlap at bottom: element y: 698 to 750, intersection height = 2
        let element2 = CGRect(x: 150, y: 698, width: 100, height: 52)
        #expect(AccessibilityInspector.clipBoundsToWindow(element2, windowBounds: window) == nil)
    }

    @Test("clipBoundsToWindow allows non-empty bounds when windowBounds is nil")
    func testClipBoundsToWindow_nilWindowBounds() {
        let element = CGRect(x: 150, y: 150, width: 100, height: 30)
        let empty = CGRect(x: 0, y: 0, width: 1, height: 1)

        #expect(AccessibilityInspector.clipBoundsToWindow(element, windowBounds: nil) == element)
        #expect(AccessibilityInspector.clipBoundsToWindow(empty, windowBounds: nil) == nil)
    }

    // MARK: - Value Extraction Tests

    @Test("extractString handles NSString, CFAttributedString, NSNumber, NSNull, and AXError")
    func testExtractString() {
        // Plain string
        let strVal = "Submit" as NSString
        #expect(AccessibilityInspector.extractString(from: strVal) == "Submit")

        // Attributed string
        let attrStr = NSAttributedString(string: "Formatted Label")
        #expect(AccessibilityInspector.extractString(from: attrStr) == "Formatted Label")

        // Number
        let numVal = NSNumber(value: 85)
        #expect(AccessibilityInspector.extractString(from: numVal) == "85")

        // NSNull
        #expect(AccessibilityInspector.extractString(from: NSNull()) == nil)
        #expect(AccessibilityInspector.extractString(from: nil) == nil)

        // AXValue wrapping AXError
        var err = AXError.attributeUnsupported
        if let axErr = AXValueCreate(.axError, &err) {
            #expect(AccessibilityInspector.extractString(from: axErr) == nil)
        }
    }

    @Test("subTreePruningRoles contains standard leaf and row container roles")
    func testSubtreePruningRoles() {
        #expect(AccessibilityInspector.subTreePruningRoles.contains("AXRow"))
        #expect(AccessibilityInspector.subTreePruningRoles.contains("AXCell"))
        #expect(AccessibilityInspector.subTreePruningRoles.contains("AXListItem"))
        #expect(AccessibilityInspector.subTreePruningRoles.contains("AXButton"))
        #expect(AccessibilityInspector.subTreePruningRoles.contains("AXTextField"))
        #expect(!AccessibilityInspector.subTreePruningRoles.contains("AXScrollArea"))
        #expect(!AccessibilityInspector.subTreePruningRoles.contains("AXTable"))
    }
}
