import AppKit
import MCACore
import OSLog
import SwiftUI

/// A borderless panel that can still take keyboard focus.
///
/// `NSWindow.canBecomeKey` is false for a window with no title bar, and
/// `NSPanel` does not change that for a borderless one. Without this override
/// `makeKey()` is a no-op, which makes the question field impossible to type
/// into — the caret never appears and every keystroke goes to the app behind.
private final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    // Deliberately *not* main: a `.nonactivatingPanel` that became the main
    // window would move the user's document focus onto the overlay.
    override var canBecomeMain: Bool { false }
}

/// The floating overlay window.
///
/// Four settings do the work here:
///
/// - `.nonactivatingPanel` — clicking the HUD does not pull focus out of the
///   user's editor. A plain `NSWindow` steals first responder and interrupts
///   exactly the work the agent is supposed to be assisting.
/// - `.fullScreenAuxiliary` — without it the panel is invisible over
///   full-screen apps, which is where a developer or a meeting actually lives.
/// - `ignoresMouseEvents` — real OS-level click-through, off by default. It is
///   whole-window and cannot be scoped to the transparent parts, so leaving it
///   on made every click on the overlay land in the app underneath: the
///   collapse and hide buttons did nothing, and the click went somewhere the
///   user did not aim it. It stays available as an explicit choice.
/// - `setActivationPolicy(.accessory)` — no Dock icon, no menu bar takeover.
///
/// The content is SwiftUI rather than a `WKWebView`: an always-on-top window
/// should not carry a browser engine in its render path, and transparency and
/// hit-testing are both simpler natively.
///
/// The window is opt-in. By default the same `HUDView` is rendered in the menu
/// bar popover instead, and nothing is created here at all until the user turns
/// the overlay on — an always-on-top window over someone else's work is a thing
/// they should have to ask for.
@MainActor
public final class HUDPanel: NSObject, NSWindowDelegate {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "HUD")
    private var panel: NSPanel?
    private let state: HUDState
    private let preferences: HUDPreferences

    private static let expandedSize = CGSize(width: 420, height: 620)
    private static let collapsedSize = CGSize(width: 240, height: 38)

    /// Suppresses the `windowDidMove` write-back while we are the ones moving
    /// the window, so a corner preset is not immediately overwritten by the
    /// dragged-origin it just produced.
    private var isRepositioning = false

    /// Invoked when the user submits a question from the overlay's text field.
    public var onSubmit: ((String) -> Void)?
    /// One-tap actions from the HUD's quick-action row.
    public var onVoice: ((VoiceMode) -> Void)?
    public var onToggleFloating: (() -> Void)?
    public var onToggleVisibility: (() -> Void)?
    public var onExplainScreen: (() -> Void)?
    public var onSnipScreen: (() -> Void)?
    public var onOpenChat: (() -> Void)?
    public var onChooseScreen: (() -> Void)?
    public var onTogglePin: (() -> Void)?
    public var onToggleWatch: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenSettingsTab: ((SettingsTab) -> Void)?

    public init(
        state: HUDState,
        preferences: UserDefaults = .standard,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.state = state
        self.preferences = HUDPreferences(defaults: preferences)
        self.onSubmit = onSubmit
        super.init()
    }

    // MARK: - Lifecycle

    /// Restores the placement the user last chose, and puts the overlay back on
    /// screen only if they had opted into it.
    ///
    /// Nothing is built when the overlay is off: a window that is never ordered
    /// front still costs a backing store and a SwiftUI host, and the popover
    /// path does not need either.
    public func start() {
        state.corner = preferences.corner
        state.isCollapsed = preferences.isCollapsed
        state.isClickThrough = preferences.isClickThrough
        state.isFloating = preferences.isFloating
        state.isAlwaysVisible = preferences.isAlwaysVisible

        guard state.isAlwaysVisible else {
            state.isVisible = false
            log.info("Overlay off — output goes to the menu bar popover")
            return
        }
        show()
    }

    /// Turns the floating overlay on or off, and remembers the choice.
    ///
    /// This is the switch the user actually reasons about — "do I want a window
    /// on top of everything" — so it is the one that persists. `show()` and
    /// `hide()` below are the mechanics it drives.
    public func setAlwaysVisible(_ enabled: Bool) {
        state.isAlwaysVisible = enabled
        preferences.isAlwaysVisible = enabled
        enabled ? show() : hide()
    }

    public func toggleAlwaysVisible() {
        setAlwaysVisible(!state.isAlwaysVisible)
    }

    public func show() {
        let panel = makePanelIfNeeded()
        panel.orderFrontRegardless()
        setVisibleState(true)
        log.info("HUD panel shown")
    }

    public func hide() {
        panel?.orderOut(nil)
        setVisibleState(false)
        log.info("HUD panel hidden")
    }

    public func close() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    /// Kept as the name the hot key and the menu bind to; the overlay being on
    /// screen and the user wanting an overlay at all are now the same thing.
    public func toggleVisibility() {
        toggleAlwaysVisible()
    }

    // MARK: - Placement

    /// Flips true OS click-through. On, the HUD is a heads-up display that
    /// clicks fall straight through; off, it can be dragged and typed into.
    public func setClickThrough(_ enabled: Bool) {
        state.isClickThrough = enabled
        preferences.isClickThrough = enabled
        panel?.ignoresMouseEvents = enabled
        log.debug("Click-through set to \(enabled, privacy: .public)")
    }

    public func toggleClickThrough() {
        setClickThrough(!state.isClickThrough)
    }

    /// Whether the overlay stays above every other window.
    ///
    /// `.floating` is what makes it a heads-up display; `.normal` demotes it to
    /// an ordinary window that the frontmost app covers. The second is here
    /// because "always in front" is the single most intrusive thing about an
    /// overlay, and the alternative to offering the switch is the user quitting
    /// the app altogether.
    public func setFloating(_ enabled: Bool) {
        state.isFloating = enabled
        preferences.isFloating = enabled
        panel?.level = enabled ? .floating : .normal
        // A non-floating panel that still joins every Space and sits over
        // full-screen apps would defeat the point of demoting it.
        panel?.collectionBehavior = enabled
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .stationary]
        log.debug("Floating set to \(enabled, privacy: .public)")
    }

    public func toggleFloating() {
        setFloating(!state.isFloating)
    }

    /// Lets the overlay appear in screenshots and screen shares.
    public func setCapturable(_ enabled: Bool) {
        preferences.isCapturable = enabled
        panel?.sharingType = enabled ? .readOnly : .none
        log.debug("Overlay capturable set to \(enabled, privacy: .public)")
    }

    public var isCapturable: Bool { preferences.isCapturable }

    /// Shrinks the overlay to a title pill, or restores it.
    ///
    /// Collapsing keeps the agent running; it only stops the panel from taking
    /// up a corner of the screen. Hiding is the stronger option and stays
    /// available for when even the pill is unwanted.
    public func setCollapsed(_ collapsed: Bool) {
        state.isCollapsed = collapsed
        preferences.isCollapsed = collapsed
        if !collapsed { state.unseenMessages = 0 }
        applySize(collapsed ? Self.collapsedSize : Self.expandedSize)
    }

    public func toggleCollapsed() {
        setCollapsed(!state.isCollapsed)
    }

    /// Moves the overlay to one of the four screen corners and forgets any
    /// position the user had dragged it to.
    public func move(to corner: HUDCorner) {
        state.corner = corner
        preferences.corner = corner
        preferences.origin = nil
        reposition()
        log.info("HUD moved to \(corner.rawValue, privacy: .public)")
    }

    // Deliberately no `focusForInput()` any more. It used to be where ⌥Space
    // landed — bring the panel forward, turn click-through off, take key focus
    // — and it is now the wrong answer to that request: asking a question opens
    // `ChatWindow`, which is built for a conversation rather than for one line
    // under a list of cards. The panel's own field still works for anyone who
    // has the panel on the desktop and clicks into it.

    // MARK: - NSWindowDelegate

    /// Remembers a manual drag, so the overlay stays where the user put it.
    public func windowDidMove(_ notification: Notification) {
        guard !isRepositioning, let panel else { return }
        preferences.origin = panel.frame.origin
    }

    // MARK: - Internals

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let size = state.isCollapsed ? Self.collapsedSize : Self.expandedSize
        let panel = HUDWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.ignoresMouseEvents = state.isClickThrough
        // Key only when a view needs it, so merely clicking the overlay to drag
        // it does not move the caret out of the user's editor.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = state.isFloating ? .floating : .normal
        panel.collectionBehavior = state.isFloating
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // Excluded from screen capture by default so the agent never reads its
        // own output back through the OCR path and feeds it into the next
        // prompt. Overridable, because an overlay that cannot be screenshotted
        // cannot be reported as broken either.
        panel.sharingType = preferences.isCapturable ? .readOnly : .none
        panel.delegate = self

        let hosting = NSHostingView(rootView: HUDView(
            state: state,
            chrome: .panel,
            onSubmit: { [weak self] question in self?.onSubmit?(question) },
            onToggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            onHide: { [weak self] in self?.setAlwaysVisible(false) },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onVoice: { [weak self] mode in self?.onVoice?(mode) },
            onToggleFloating: { [weak self] in
                if let external = self?.onToggleFloating { external() }
                else { self?.toggleFloating() }
            },
            onToggleVisibility: { [weak self] in
                if let external = self?.onToggleVisibility { external() }
                else { self?.toggleVisibility() }
            },
            onExplainScreen: { [weak self] in self?.onExplainScreen?() },
            onSnipScreen: { [weak self] in self?.onSnipScreen?() },
            onOpenChat: { [weak self] in self?.onOpenChat?() },
            onChooseScreen: { [weak self] in self?.onChooseScreen?() },
            onTogglePin: { [weak self] in self?.onTogglePin?() },
            onToggleWatch: { [weak self] in self?.onToggleWatch?() },
            onOpenSettingsTab: { [weak self] tab in self?.onOpenSettingsTab?(tab) }))
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        reposition()
        return panel
    }

    private func setVisibleState(_ visible: Bool) {
        state.isVisible = visible
        // Showing the panel is the user looking at what accumulated, unless it
        // is only the collapsed pill coming back.
        if visible && !state.isCollapsed { state.unseenMessages = 0 }
    }

    /// Puts the panel at the remembered origin, or at the chosen corner when
    /// there is none. A remembered origin that no longer lands on any screen —
    /// an external display that has since been unplugged — falls back to the
    /// corner rather than leaving the overlay somewhere unreachable.
    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame

        var origin = state.corner.origin(in: visible, width: size.width, height: size.height)
        if let saved = preferences.origin {
            let frame = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                origin = saved
            }
        }

        isRepositioning = true
        panel.setFrameOrigin(origin)
        isRepositioning = false
    }

    /// Resizes in place, keeping the top edge and the anchored side fixed so a
    /// collapse does not make the overlay appear to jump across the screen.
    private func applySize(_ size: CGSize) {
        guard let panel else { return }
        let old = panel.frame
        let x = state.corner.isRight ? old.maxX - size.width : old.minX
        let y = old.maxY - size.height

        isRepositioning = true
        panel.setFrame(
            NSRect(x: x, y: y, width: size.width, height: size.height),
            display: true, animate: false)
        isRepositioning = false

        if preferences.origin != nil { preferences.origin = panel.frame.origin }
    }
}
