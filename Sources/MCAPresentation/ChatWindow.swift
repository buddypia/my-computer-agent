import AppKit
import MCACore
import OSLog
import SwiftUI

/// The chat window.
///
/// Deliberately *not* an application-modal session. `NSApp.runModal` would give
/// the dimmed, must-answer-this feel the word "modal" usually implies, and it
/// would also stop the run loop this agent lives in: the five-second proactive
/// scan, the screen watch, the menu bar item and every global hot key run on the
/// main actor, and a modal loop starves all of them. Worse, it would lock the
/// user out of the very windows they want to ask about — an assistant whose chat
/// window prevents you from looking at your own screen has defeated itself.
///
/// What "modal" is worth taking is the *immediacy*: one click puts a window in
/// the middle of the screen, in front, with the caret already in the field, and
/// Escape closes it. That is what this does.
@MainActor
public final class ChatWindow: NSObject, NSWindowDelegate {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "Chat")
    private let state: HUDState
    private var window: NSPanel?
    private var callbacks: Callbacks

    public struct Callbacks {
        public var onSubmit: ((String) -> Void)?
        public var onToggleWatch: (() -> Void)?
        public var onChooseInterval: ((ScreenWatchInterval) -> Void)?
        public var onChooseScreen: (() -> Void)?
        public var onExplainScreen: (() -> Void)?
        public var onSnipScreen: (() -> Void)?
        public var onExecutePreset: ((WatchRole, WatchTarget?) -> Void)?
        public var onApplyRoleToWatch: ((WatchRole, WatchTarget?) -> Void)?
        public var onVoice: ((VoiceMode) -> Void)?
        public var onClear: (() -> Void)?

        public init() {}
    }

    private static let size = CGSize(width: 560, height: 640)

    public init(state: HUDState) {
        self.state = state
        self.callbacks = Callbacks()
        super.init()
    }

    /// Late wiring, for a composition root that builds this before the actions
    /// it calls into exist.
    public func setCallbacks(_ callbacks: Callbacks) {
        self.callbacks = callbacks
        if let window {
            window.contentView = NSHostingView(rootView: makeView())
        }
    }

    public var isOpen: Bool { window?.isVisible == true }

    /// Puts the chat in front of the user, ready to type into.
    ///
    /// Idempotent: pressing the button again while it is already open refocuses
    /// the field rather than doing nothing, which is what a user who cannot see
    /// the window behind their editor will press.
    public func present() {
        let window = makeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        // The app runs `.accessory`, so it is never frontmost on its own and the
        // field would silently refuse keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        state.isChatOpen = true
        state.unseenMessages = 0
        // Re-arms the field's focus. `onAppear` fires once for the life of the
        // hosting view, so reopening an existing window would otherwise leave
        // the caret wherever it was left.
        state.chatFocusRequest += 1
        log.debug("Chat window presented")
    }

    /// Puts the chat in front for an approval card, without a caret in the field.
    ///
    /// The caret starts the system's input-mode indicator under it, which waits
    /// on a reply from another process on the main thread. Shown again seconds
    /// after the chat closed for the previous desktop action, that reply never
    /// came, and the whole app froze with the card unanswerable. An approval is
    /// answered with a button, so the field has no reason to be focused.
    public func presentForApproval() {
        let window = makeWindowIfNeeded()
        window.makeFirstResponder(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.isChatOpen = true
        state.unseenMessages = 0
        log.debug("Chat window presented for approval")
    }

    public func close() {
        if let window {
            window.orderOut(nil)
            window.close()
        }
        state.isChatOpen = false
    }

    /// Closes the chat and waits until Quartz no longer lists its panel.
    /// Desktop input must not resume while the panel can still intercept it.
    public func closeAndWaitForSurfaceRemoval(timeout: Duration = .seconds(2)) async -> Bool {
        let closedWindow = window
        close()
        guard let closedWindow else { return true }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if !isSurfaceVisible(windowNumber: closedWindow.windowNumber, title: closedWindow.title) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return !isSurfaceVisible(windowNumber: closedWindow.windowNumber, title: closedWindow.title)
    }

    public func toggle() {
        // Key, not merely visible: with the window floating behind the editor
        // the user is typing in, "toggle" has to mean "bring it to me" rather
        // than "hide the thing I cannot see".
        if let window, window.isVisible, window.isKeyWindow {
            close()
        } else {
            present()
        }
    }

    /// Tears the window down. Called at shutdown.
    public func destroy() {
        window?.delegate = nil
        window?.close()
        window = nil
        state.isChatOpen = false
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        state.isChatOpen = false
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        state.isChatOpen = true
        state.unseenMessages = 0
    }

    // MARK: - Internals

    private func makeWindowIfNeeded() -> NSPanel {
        if let window { return window }

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            // `.titled` for somewhere to drag from and a close button; an
            // `NSPanel` with one also closes on Escape, which is the half of
            // "modal" worth keeping.
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        window.title = localized("Copilot — Chat", "Copilot — チャット", "Copilot — 채팅")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 380)
        window.delegate = self
        // In front of the user's work, like the panel — the questions asked here
        // are about the window behind it, so being covered by that window is
        // exactly the wrong behaviour.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // A closing animation remains in Quartz's hit-test order after AppKit
        // reports the chat hidden, obstructing the newly approved desktop input.
        window.animationBehavior = .none
        // Never captured. The screen watch photographs the frontmost window, and
        // a chat window that appears in that photograph would feed the agent its
        // own advice back as if it were the user's screen.
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: makeView())

        // Centred only the first time. After that the window goes back where the
        // user put it — re-centring on every open would drag a window they
        // deliberately moved to the side back over their work.
        let name = NSWindow.FrameAutosaveName("com.buddypia.mca.chat")
        window.setFrameAutosaveName(name)
        if !window.setFrameUsingName(name) { center(window) }

        self.window = window
        return window
    }

    private func makeView() -> ChatView {
        ChatView(
            state: state,
            onSubmit: { [weak self] question in self?.callbacks.onSubmit?(question) },
            onToggleWatch: { [weak self] in self?.callbacks.onToggleWatch?() },
            onChooseInterval: { [weak self] interval in
                self?.callbacks.onChooseInterval?(interval)
            },
            onChooseScreen: { [weak self] in self?.callbacks.onChooseScreen?() },
            onExplainScreen: { [weak self] in self?.callbacks.onExplainScreen?() },
            onSnipScreen: { [weak self] in self?.callbacks.onSnipScreen?() },
            onExecutePreset: { [weak self] role, target in
                self?.callbacks.onExecutePreset?(role, target)
            },
            onApplyRoleToWatch: { [weak self] role, target in
                self?.callbacks.onApplyRoleToWatch?(role, target)
            },
            onVoice: { [weak self] mode in self?.callbacks.onVoice?(mode) },
            onClear: { [weak self] in self?.callbacks.onClear?() })
    }

    private func isSurfaceVisible(windowNumber: Int, title: String) -> Bool {
        let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return entries.contains { entry in
            (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
                && (entry[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber
                && (entry[kCGWindowName as String] as? String) == title
        }
    }

    /// Centres on the screen the pointer is on, slightly above the middle.
    ///
    /// `NSWindow.center()` uses the main screen, which on a multi-display Mac is
    /// whichever one has the menu bar — not the one the user is working on. A
    /// chat window that opens on the other monitor reads as not having opened.
    private func center(_ window: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.06))
    }
}
