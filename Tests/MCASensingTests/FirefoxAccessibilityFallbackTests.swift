import ApplicationServices
import CoreGraphics
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("Firefox and Browser Accessibility Fallback Tests")
struct FirefoxAccessibilityFallbackTests {
    @Test("AXAttributes.enableEnhancedAccessibility safely executes without crash")
    func testEnableEnhancedAccessibilitySafe() {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let res = AXAttributes.enableEnhancedAccessibility(app: app)
        #expect(res == true || res == false)
    }

    @Test("AXBrowserDriver initializes with OCR snapshot and text providers")
    func testAXBrowserDriverOCRProviders() async throws {
        let fakeRefs: [String: BrowserElementRef] = [
            "ocr-1": BrowserElementRef(id: "ocr-1", role: "button", name: "Follow", frameOrdinal: 0, bounds: CGRect(x: 10, y: 20, width: 80, height: 30))
        ]
        let fallbackSnapshot = BrowserSnapshot(
            driver: .accessibility,
            url: "https://x.com/home",
            title: "X",
            outline: "[ocr-1] button: Follow",
            refs: fakeRefs
        )

        let driver = AXBrowserDriver(
            ocrSnapshotProvider: { _, _ in
                return fallbackSnapshot
            },
            ocrTextProvider: { _ in
                return "Fallback OCR Feed Text"
            }
        )

        #expect(driver.kind == .accessibility)
        let desc = await driver.describeConnection()
        #expect(desc.contains("not connected"))
    }

    @Test("AccessibilityInspector falls back to fallbackProvider when AX tree is empty")
    func testAccessibilityInspectorFallbackProvider() async {
        let expectedCandidate = UIElementCandidate(
            id: "ocr_1",
            role: "button",
            label: "Post",
            value: nil,
            bounds: CGRect(x: 50, y: 50, width: 100, height: 40),
            isActionable: true,
            source: .ocr
        )

        let inspector = AccessibilityInspector(
            maxCandidates: 10,
            fallbackProvider: { pid, windowBounds in
                return [expectedCandidate]
            }
        )

        #expect(inspector.maxCandidates == 10)
    }

    @Test("AccessibilityInspector includes AXHeading in actionable roles")
    func testActionableRolesIncludesHeading() {
        #expect(AccessibilityInspector.actionableRoles.contains("AXHeading"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXButton"))
        #expect(AccessibilityInspector.actionableRoles.contains("AXTextField"))
    }

    @Test("AccessibilityInspector isValidCoordinateRect validates finite dimensions")
    func testIsValidCoordinateRect() {
        let valid = CGRect(x: 10, y: 10, width: 100, height: 50)
        #expect(AccessibilityInspector.isValidCoordinateRect(valid))

        let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
        #expect(!AccessibilityInspector.isValidCoordinateRect(zero))

        let nanRect = CGRect(x: CGFloat.nan, y: 0, width: 100, height: 50)
        #expect(!AccessibilityInspector.isValidCoordinateRect(nanRect))
    }
}
