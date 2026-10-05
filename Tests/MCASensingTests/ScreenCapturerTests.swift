import CoreGraphics
import Foundation
import Testing

@testable import MCASensing

@Suite("Screen capturer window filtering")
struct ScreenCapturerTests {
    private let ownPID: pid_t = 1000

    @Test("accepts an ordinary application window")
    func acceptsNormalApp() {
        let ok = ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 800,
            height: 600,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            processID: 2001,
            ownPID: ownPID
        )
        #expect(ok)
    }

    @Test("rejects Finder windows by bundle ID or application name")
    func rejectsFinder() {
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 920,
            height: 492,
            bundleID: "com.apple.finder",
            appName: "Finder",
            processID: 2002,
            ownPID: ownPID
        ))

        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 920,
            height: 492,
            bundleID: nil,
            appName: "Finder",
            processID: 2002,
            ownPID: ownPID
        ))
    }

    @Test("rejects widgets and notification center")
    func rejectsWidgetsAndNotificationCenter() {
        // Desktop widgets have non-zero windowLayer (e.g. -2147483601)
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: -2147483601,
            isOnScreen: true,
            width: 180,
            height: 180,
            bundleID: "com.apple.notificationcenterui",
            appName: "通知センター",
            processID: 2003,
            ownPID: ownPID
        ))

        // Even if layer were 0, bundle ID and app name are rejected
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 180,
            height: 180,
            bundleID: "com.apple.notificationcenterui",
            appName: "Notification Center",
            processID: 2003,
            ownPID: ownPID
        ))

        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 200,
            height: 200,
            bundleID: "com.apple.widgetkit.runner",
            appName: "Widget",
            processID: 2004,
            ownPID: ownPID
        ))

        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 200,
            height: 200,
            bundleID: "com.thirdparty.weather.widget",
            appName: "Weather Widget",
            processID: 2005,
            ownPID: ownPID
        ))
    }

    @Test("rejects system shell components like Dock, Control Center, Spotlight")
    func rejectsSystemShell() {
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 1200,
            height: 80,
            bundleID: "com.apple.dock",
            appName: "Dock",
            processID: 2006,
            ownPID: ownPID
        ))

        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 320,
            height: 480,
            bundleID: "com.apple.controlcenter",
            appName: "Control Center",
            processID: 2007,
            ownPID: ownPID
        ))

        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 680,
            height: 400,
            bundleID: "com.apple.Spotlight",
            appName: "Spotlight",
            processID: 2008,
            ownPID: ownPID
        ))
    }

    @Test("rejects own application windows")
    func rejectsOwnPID() {
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 760,
            height: 560,
            bundleID: "com.buddypia.mca",
            appName: "MyComputerAgent",
            processID: ownPID,
            ownPID: ownPID
        ))
    }

    @Test("rejects off-screen or small scaffolding windows")
    func rejectsOffscreenOrSmall() {
        // Offscreen
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: false,
            width: 800,
            height: 600,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            processID: 2001,
            ownPID: ownPID
        ))

        // Too small width
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 100,
            height: 600,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            processID: 2001,
            ownPID: ownPID
        ))

        // Too small height
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 0,
            isOnScreen: true,
            width: 800,
            height: 100,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            processID: 2001,
            ownPID: ownPID
        ))
    }

    @Test("rejects non-zero window layers")
    func rejectsNonZeroLayer() {
        #expect(!ScreenCapturer.isTargetable(
            windowLayer: 1,
            isOnScreen: true,
            width: 800,
            height: 600,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            processID: 2001,
            ownPID: ownPID
        ))
    }
}

@Suite("Screen capturer region cropping")
struct ScreenCapturerRegionCropTests {
    @Test("translates 1x coordinate with AppKit vertical inversion")
    func test1xInversion() {
        // Display: 1920x1080 points, Image: 1920x1080 pixels
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Selection at top-left of display in visual appearance (AppKit y near top):
        // Visual top 100 points means AppKit y = 1080 - 100 = 980, height = 100
        let screenRect = CGRect(x: 100, y: 980, width: 200, height: 100)

        let crop = ScreenCapturer.calculatePixelCropRect(
            screenRect: screenRect,
            displayBounds: displayBounds,
            imageWidth: 1920,
            imageHeight: 1080)

        #expect(crop.origin.x == 100)
        #expect(crop.origin.y == 0) // Inverted: 1080 - (980 + 100) = 0
        #expect(crop.width == 200)
        #expect(crop.height == 100)
    }

    @Test("scales properly for Retina 2x display")
    func testRetinaScaling() {
        // Display: 1440x900 points, Image: 2880x1800 pixels (2x)
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // AppKit rect: bottom-left origin (100, 100), size (200, 150)
        let screenRect = CGRect(x: 100, y: 100, width: 200, height: 150)

        let crop = ScreenCapturer.calculatePixelCropRect(
            screenRect: screenRect,
            displayBounds: displayBounds,
            imageWidth: 2880,
            imageHeight: 1800)

        #expect(crop.origin.x == 200) // 100 * 2
        // AppKit y=100 with h=150: flippedY = 900 - (100 + 150) = 650 points -> 650 * 2 = 1300 pixels
        #expect(crop.origin.y == 1300)
        #expect(crop.width == 400) // 200 * 2
        #expect(crop.height == 300) // 150 * 2
    }

    @Test("normalizes inverted drag rectangles")
    func testInvertedDragNormalization() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // Dragged backwards: origin at (300, 400) with negative width/height
        let screenRect = CGRect(x: 300, y: 400, width: -100, height: -200)

        let crop = ScreenCapturer.calculatePixelCropRect(
            screenRect: screenRect,
            displayBounds: displayBounds,
            imageWidth: 1000,
            imageHeight: 1000)

        // Standardized rect: origin (200, 200), width 100, height 200
        #expect(crop.origin.x == 200)
        // flippedY = 1000 - (200 + 200) = 600
        #expect(crop.origin.y == 600)
        #expect(crop.width == 100)
        #expect(crop.height == 200)
    }

    @Test("clamps coordinates extending beyond display bounds")
    func testClampingOutOfBounds() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let screenRect = CGRect(x: -50, y: 900, width: 1200, height: 200)

        let crop = ScreenCapturer.calculatePixelCropRect(
            screenRect: screenRect,
            displayBounds: displayBounds,
            imageWidth: 1000,
            imageHeight: 1000)

        #expect(crop.origin.x == 0)
        #expect(crop.origin.y == 0)
        #expect(crop.width <= 1000)
        #expect(crop.height <= 1000)
    }

    @Test("crops CGImage correctly")
    func testImageCropping() {
        // Create 100x100 RGB image
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 255, count: 100 * 100 * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 100 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            Issue.record("Failed to create test CGImage")
            return
        }

        let cropped = ScreenCapturer.crop(image: image, to: CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(cropped != nil)
        #expect(cropped?.width == 30)
        #expect(cropped?.height == 40)
    }
}

