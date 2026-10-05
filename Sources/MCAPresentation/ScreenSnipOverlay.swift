import AppKit
import CoreGraphics
import MCACore
import OSLog

/// Result of a screen region snip selection.
public struct ScreenSnipResult: Sendable {
    /// Selection rectangle in the screen's coordinate space (AppKit origin).
    public var rect: CGRect
    /// The screen bounds in the same coordinate space.
    public var screenBounds: CGRect
    /// Display ID corresponding to the screen.
    public var displayID: CGDirectDisplayID?

    public init(rect: CGRect, screenBounds: CGRect, displayID: CGDirectDisplayID?) {
        self.rect = rect
        self.screenBounds = screenBounds
        self.displayID = displayID
    }
}

/// Custom NSView for tracking mouse drag and drawing the snip selection box.
private final class ScreenSnipSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var trackingAreaRef: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        // ESC key (key code 53) cancels snipping
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let current = currentPoint else {
            onCancel?()
            return
        }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        startPoint = nil
        currentPoint = nil
        needsDisplay = true

        // Minimum selection threshold (10x10) to guard against accidental clicks
        if rect.width >= 10 && rect.height >= 10 {
            onComplete?(rect)
        } else {
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Semi-transparent dark mask over the whole view
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let start = startPoint, let current = currentPoint else {
            drawHintText()
            return
        }

        let selectionRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        guard selectionRect.width > 0, selectionRect.height > 0 else { return }

        // Clear the inside of the selection so the screen underneath is visible in full brightness
        if let cgContext = NSGraphicsContext.current?.cgContext {
            cgContext.clear(selectionRect)
        }

        // Draw border around selection
        let path = NSBezierPath(rect: selectionRect)
        path.lineWidth = 1.5
        NSColor.white.setStroke()
        path.stroke()

        // Draw dimension badge (e.g. "480 × 320")
        drawDimensionBadge(for: selectionRect)
    }

    private func drawHintText() {
        let text = localized(
            "Drag to select a screen area to explain (ESC to cancel)",
            "ドラッグして説明させたい範囲を選択 (ESCでキャンセル)",
            "설명할 영역을 드래그하여 선택 (ESC로 취소)"
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ]
        let attrString = NSAttributedString(string: "  \(text)  ", attributes: attributes)
        let size = attrString.size()
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2 + bounds.height * 0.1
        )
        attrString.draw(at: origin)
    }

    private func drawDimensionBadge(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()
        let badgePadding: CGFloat = 4
        let badgeRect = CGRect(
            x: rect.maxX - textSize.width - badgePadding * 2,
            y: max(bounds.minY, rect.minY - textSize.height - badgePadding * 2 - 2),
            width: textSize.width + badgePadding * 2,
            height: textSize.height + badgePadding * 2
        )

        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        badgePath.fill()

        attrString.draw(at: CGPoint(x: badgeRect.minX + badgePadding, y: badgeRect.minY + badgePadding))
    }
}

/// Controller that presents the fullscreen transparent snipping overlay across active displays.
@MainActor
public final class ScreenSnipController: NSObject {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "ScreenSnip")
    private var windows: [NSWindow] = []
    private var onSelection: ((ScreenSnipResult) -> Void)?
    private var onCancelCallback: (() -> Void)?

    public var isSelecting: Bool { !windows.isEmpty }

    /// Presents fullscreen snipping overlays across active screen
    public func startSnipping(
        onSelection: @escaping (ScreenSnipResult) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        dismiss()
        self.onSelection = onSelection
        self.onCancelCallback = onCancel

        let pointer = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main

        guard let screen = targetScreen else {
            onCancel?()
            return
        }

        let window = makeOverlayWindow(for: screen)
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log.debug("Screen snip overlay presented on screen \(screen.frame.debugDescription, privacy: .public)")
    }

    public func dismiss() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .none // Exclude from screenshots!
        window.ignoresMouseEvents = false

        let snipView = ScreenSnipSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        snipView.onComplete = { [weak self, weak screen] localRect in
            guard let self else { return }
            self.dismiss()
            guard let screen else { return }
            // Convert view local coordinates to screen frame coordinates
            let screenRect = CGRect(
                x: screen.frame.origin.x + localRect.origin.x,
                y: screen.frame.origin.y + localRect.origin.y,
                width: localRect.width,
                height: localRect.height
            )
            let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let result = ScreenSnipResult(
                rect: screenRect,
                screenBounds: screen.frame,
                displayID: displayID
            )
            self.onSelection?(result)
        }

        snipView.onCancel = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.onCancelCallback?()
        }

        window.contentView = snipView
        return window
    }
}
