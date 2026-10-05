import AppKit
import MCACore
import OSLog
import SwiftUI

/// The menu bar surface for the agent's output.
///
/// This is the default place the HUD lives, and the floating panel is the
/// opt-in. The reasoning is the same one that makes click-through a bad
/// default: a window that sits on top of every other window is intrusive
/// whether or not it takes clicks, and "how do I get rid of this" should not be
/// the first thing a user has to work out. Anchored under the ✨ status item,
/// the same `HUDView` is on screen exactly while they are looking at it.
///
/// `.transient` behaviour is deliberate — clicking anywhere else dismisses it,
/// so the overlay can never be left covering something by accident.
@MainActor
public final class HUDPopover: NSObject, NSPopoverDelegate {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "HUD")
    private let state: HUDState
    private let popover = NSPopover()
    private var callbacks: Callbacks

    struct Callbacks {
        var onSubmit: ((String) -> Void)?
        var onOpenSettings: (() -> Void)?
        var onQuit: (() -> Void)?
        var onVoice: ((VoiceMode) -> Void)?
        var onToggleFloating: (() -> Void)?
        var onToggleVisibility: (() -> Void)?
        var onExplainScreen: (() -> Void)?
        var onSnipScreen: (() -> Void)?
        var onOpenChat: (() -> Void)?
        var onChooseScreen: (() -> Void)?
        var onTogglePin: (() -> Void)?
        var onToggleWatch: (() -> Void)?
        var onClearChat: (() -> Void)?
        var onOpenSettingsTab: ((SettingsTab) -> Void)?
        var onToggleClickThrough: (() -> Void)?
    }

    private static let size = CGSize(width: 380, height: 520)

    public init(
        state: HUDState,
        onSubmit: ((String) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil,
        onOpenSettingsTab: ((SettingsTab) -> Void)? = nil,
        onToggleClickThrough: (() -> Void)? = nil,
        onQuit: (() -> Void)? = nil,
        onVoice: ((VoiceMode) -> Void)? = nil,
        onToggleFloating: (() -> Void)? = nil,
        onToggleVisibility: (() -> Void)? = nil,
        onExplainScreen: (() -> Void)? = nil,
        onSnipScreen: (() -> Void)? = nil,
        onOpenChat: (() -> Void)? = nil,
        onChooseScreen: (() -> Void)? = nil,
        onTogglePin: (() -> Void)? = nil,
        onToggleWatch: (() -> Void)? = nil,
        onClearChat: (() -> Void)? = nil
    ) {
        self.state = state
        self.callbacks = Callbacks(
            onSubmit: onSubmit,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit,
            onVoice: onVoice,
            onToggleFloating: onToggleFloating,
            onToggleVisibility: onToggleVisibility,
            onExplainScreen: onExplainScreen,
            onSnipScreen: onSnipScreen,
            onOpenChat: onOpenChat,
            onChooseScreen: onChooseScreen,
            onTogglePin: onTogglePin,
            onToggleWatch: onToggleWatch,
            onClearChat: onClearChat,
            onOpenSettingsTab: onOpenSettingsTab,
            onToggleClickThrough: onToggleClickThrough)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.size
        popover.delegate = self
        refreshContent()
    }

    /// Late wiring for owners constructed before their actions exist.
    public func setQuickActions(
        onVoice: ((VoiceMode) -> Void)? = nil,
        onToggleFloating: (() -> Void)? = nil,
        onToggleVisibility: (() -> Void)? = nil,
        onExplainScreen: (() -> Void)? = nil,
        onSnipScreen: (() -> Void)? = nil,
        onOpenChat: (() -> Void)? = nil,
        onChooseScreen: (() -> Void)? = nil,
        onTogglePin: (() -> Void)? = nil,
        onToggleWatch: (() -> Void)? = nil,
        onClearChat: (() -> Void)? = nil
    ) {
        if let onVoice { callbacks.onVoice = onVoice }
        if let onToggleFloating { callbacks.onToggleFloating = onToggleFloating }
        if let onToggleVisibility { callbacks.onToggleVisibility = onToggleVisibility }
        if let onExplainScreen { callbacks.onExplainScreen = onExplainScreen }
        if let onSnipScreen { callbacks.onSnipScreen = onSnipScreen }
        if let onOpenChat { callbacks.onOpenChat = onOpenChat }
        if let onChooseScreen { callbacks.onChooseScreen = onChooseScreen }
        if let onTogglePin { callbacks.onTogglePin = onTogglePin }
        if let onToggleWatch { callbacks.onToggleWatch = onToggleWatch }
        if let onClearChat { callbacks.onClearChat = onClearChat }
        if popover.contentViewController != nil { refreshContent() }
    }

    private func refreshContent() {
        popover.contentViewController = NSHostingController(rootView: HUDView(
            state: state,
            chrome: .popover,
            onSubmit: callbacks.onSubmit,
            onHide: { [weak self] in self?.close() },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.callbacks.onOpenSettings?()
            },
            onQuit: callbacks.onQuit,
            onVoice: { [weak self] mode in self?.callbacks.onVoice?(mode) },
            onToggleFloating: { [weak self] in self?.callbacks.onToggleFloating?() },
            // Closes first only when the tap will put the panel on the
            // desktop: leaving the popover open would show the same HUDView
            // twice (popover plus panel). Hiding keeps the popover, which is
            // what the user is looking at — closing both would leave nothing
            // on screen. Closed first for the same reason as the chat and the
            // picker below: the panel taking key focus reads as the outside
            // click that dismisses a `.transient` popover.
            onToggleVisibility: { [weak self] in
                guard let self else { return }
                if !self.state.isAlwaysVisible { self.close() }
                self.callbacks.onToggleVisibility?()
            },
            onExplainScreen: { [weak self] in self?.callbacks.onExplainScreen?() },
            onSnipScreen: { [weak self] in
                self?.close()
                self?.callbacks.onSnipScreen?()
            },
            // Closes first: the chat window it opens takes key focus, which a
            // `.transient` popover reads as the click elsewhere that dismisses
            // it — leaving the popover to vanish a beat after the window
            // appears, which looks like a glitch rather than a transition.
            onOpenChat: { [weak self] in
                self?.close()
                self?.callbacks.onOpenChat?()
            },
            // Closed first for the same reason: the picker is a window, and a
            // `.transient` popover reads it taking key focus as the click
            // elsewhere that dismisses it.
            onChooseScreen: { [weak self] in
                self?.close()
                self?.callbacks.onChooseScreen?()
            },
            onTogglePin: { [weak self] in
                self?.callbacks.onTogglePin?()
            },
            onToggleWatch: { [weak self] in
                self?.callbacks.onToggleWatch?()
            },
            onClearChat: { [weak self] in
                self?.callbacks.onClearChat?()
            },
            onOpenSettingsTab: { [weak self] tab in
                self?.close()
                self?.callbacks.onOpenSettingsTab?(tab)
            },
            onToggleClickThrough: { [weak self] in
                self?.callbacks.onToggleClickThrough?()
            }
        ).frame(width: Self.size.width, height: Self.size.height))
    }

    public var isShown: Bool { popover.isShown }

    public func toggle(relativeTo button: NSStatusBarButton) {
        isShown ? close() : show(relativeTo: button)
    }

    public func show(relativeTo button: NSStatusBarButton) {
        // Activation comes first. The app runs `.accessory`, so it is never
        // frontmost on its own and the question field would silently refuse
        // keystrokes; doing it afterwards risks the activation reading as the
        // outside interaction that dismisses a `.transient` popover.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        log.debug("HUD popover shown")
    }

    public func close() {
        popover.performClose(nil)
    }

    // MARK: - NSPopoverDelegate

    /// Opening the popover is the user reading what accumulated, so the unread
    /// count clears here rather than at each call site — the popover can also be
    /// dismissed by clicking away, which no call site sees.
    public func popoverDidShow(_ notification: Notification) {
        state.isPopoverOpen = true
        state.unseenMessages = 0
    }

    public func popoverDidClose(_ notification: Notification) {
        state.isPopoverOpen = false
    }
}
