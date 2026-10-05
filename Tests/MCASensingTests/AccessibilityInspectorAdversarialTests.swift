import ApplicationServices
import CoreGraphics
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("AccessibilityInspector Adversarial Challenge Suite")
struct AccessibilityInspectorAdversarialTests {

    // MARK: - 1. clipBoundsToWindow Extreme & Degenerate Scenarios

    @Test("clipBoundsToWindow: Zero-size window frame returns nil")
    func clipBoundsZeroSizeWindow() {
        let zeroWindow = CGRect(x: 100, y: 100, width: 0, height: 0)
        let element = CGRect(x: 100, y: 100, width: 50, height: 50)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: zeroWindow)
        #expect(clipped == nil)
    }

    @Test("clipBoundsToWindow: Negative-dimension window frame returns nil")
    func clipBoundsNegativeWindowDimensions() {
        let negWindow = CGRect(x: 100, y: 100, width: -800, height: -600)
        let element = CGRect(x: 100, y: 100, width: 50, height: 50)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: negWindow)
        #expect(clipped == nil)
    }

    @Test("clipBoundsToWindow: Extreme multi-display coordinate ranges")
    func clipBoundsExtremeCoordinates() {
        let window = CGRect(x: -3840, y: -1080, width: 3840, height: 2160)
        let element = CGRect(x: -2000, y: -500, width: 200, height: 40)

        let clipped = AccessibilityInspector.clipBoundsToWindow(element, windowBounds: window)
        #expect(clipped != nil)
        #expect(clipped?.origin.x == -2000)
        #expect(clipped?.origin.y == -500)
        #expect(clipped?.width == 200)
        #expect(clipped?.height == 40)
    }

    @Test("clipBoundsToWindow: Exact 2.0 pt threshold behavior")
    func clipBoundsThresholdEdge() {
        let window = CGRect(x: 0, y: 0, width: 500, height: 500)

        // Exactly 2.0 pt width -> Discarded (> 2 required)
        let exactly2 = CGRect(x: 10, y: 10, width: 2.0, height: 10.0)
        #expect(AccessibilityInspector.clipBoundsToWindow(exactly2, windowBounds: window) == nil)

        // 2.001 pt width -> Retained
        let slightlyOver2 = CGRect(x: 10, y: 10, width: 2.001, height: 10.0)
        let clipped = AccessibilityInspector.clipBoundsToWindow(slightlyOver2, windowBounds: window)
        #expect(clipped != nil)
    }

    @Test("clipBoundsToWindow with nil windowBounds sanitizes and rejects NaN and Infinite coordinates")
    func clipBoundsNilWindowNaNSanitization() {
        // Elements with NaN coordinates in origin or size
        let nanOriginBoth = CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 50, height: 50)
        let nanOriginX = CGRect(x: CGFloat.nan, y: 100, width: 50, height: 50)
        let nanOriginY = CGRect(x: 100, y: CGFloat.nan, width: 50, height: 50)
        let nanSizeW = CGRect(x: 100, y: 100, width: CGFloat.nan, height: 50)
        let nanSizeH = CGRect(x: 100, y: 100, width: 50, height: CGFloat.nan)

        #expect(AccessibilityInspector.clipBoundsToWindow(nanOriginBoth, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(nanOriginX, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(nanOriginY, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(nanSizeW, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(nanSizeH, windowBounds: nil) == nil)

        // Elements with Infinite coordinates in origin or size
        let infOriginX = CGRect(x: CGFloat.infinity, y: 100, width: 50, height: 50)
        let negInfOriginX = CGRect(x: -CGFloat.infinity, y: 100, width: 50, height: 50)
        let infOriginY = CGRect(x: 100, y: CGFloat.infinity, width: 50, height: 50)
        let infSizeW = CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 50)
        let infSizeH = CGRect(x: 100, y: 100, width: 50, height: CGFloat.infinity)
        let infiniteRect = CGRect.infinite

        #expect(AccessibilityInspector.clipBoundsToWindow(infOriginX, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(negInfOriginX, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(infOriginY, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(infSizeW, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(infSizeH, windowBounds: nil) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(infiniteRect, windowBounds: nil) == nil)

        // Negative raw size dimensions
        let negSize = CGRect(x: 100, y: 100, width: -50, height: 50)
        #expect(AccessibilityInspector.clipBoundsToWindow(negSize, windowBounds: nil) == nil)

        // Valid element passes through unharmed
        let validElement = CGRect(x: 150, y: 150, width: 100, height: 30)
        #expect(AccessibilityInspector.clipBoundsToWindow(validElement, windowBounds: nil) == validElement)
    }

    @Test("clipBoundsToWindow with non-nil windowBounds rejects NaN and Infinite window frames")
    func clipBoundsInvalidWindowFrames() {
        let validElement = CGRect(x: 150, y: 150, width: 100, height: 30)
        let nanWindowOrigin = CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600)
        let nanWindowSize = CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600)
        let infWindow = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)
        let infiniteWindow = CGRect.infinite

        #expect(AccessibilityInspector.clipBoundsToWindow(validElement, windowBounds: nanWindowOrigin) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(validElement, windowBounds: nanWindowSize) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(validElement, windowBounds: infWindow) == nil)
        #expect(AccessibilityInspector.clipBoundsToWindow(validElement, windowBounds: infiniteWindow) == nil)
    }

    // MARK: - 2. extractString with Malformed and IPC Attribute Values

    @Test("extractString handles malformed and edge-case types safely")
    func extractStringMalformedTypes() {
        // 1. CFArray
        let arrayVal = ["test"] as NSArray
        #expect(AccessibilityInspector.extractString(from: arrayVal) == nil)

        // 2. CFDictionary
        let dictVal = ["key": "value"] as NSDictionary
        #expect(AccessibilityInspector.extractString(from: dictVal) == nil)

        // 3. AXValue of type CGPoint (should NOT extract as string)
        var point = CGPoint(x: 123, y: 456)
        if let axPoint = AXValueCreate(.cgPoint, &point) {
            #expect(AccessibilityInspector.extractString(from: axPoint) == nil)
        }

        // 4. AXValue of type CGSize (should NOT extract as string)
        var size = CGSize(width: 80, height: 30)
        if let axSize = AXValueCreate(.cgSize, &size) {
            #expect(AccessibilityInspector.extractString(from: axSize) == nil)
        }

        // 5. AXValue of type CFRange (should NOT extract as string)
        var range = CFRange(location: 0, length: 10)
        if let axRange = AXValueCreate(.cfRange, &range) {
            #expect(AccessibilityInspector.extractString(from: axRange) == nil)
        }

        // 6. Various NSNumber types (int, float, boolean)
        let intNum = NSNumber(value: 42)
        #expect(AccessibilityInspector.extractString(from: intNum) == "42")

        let doubleNum = NSNumber(value: 3.14159)
        #expect(AccessibilityInspector.extractString(from: doubleNum) != nil)

        let boolNum = NSNumber(value: true)
        #expect(AccessibilityInspector.extractString(from: boolNum) == "1")
    }
}
