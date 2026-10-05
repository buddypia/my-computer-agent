import AppKit
import ApplicationServices
import Foundation
import MCACore
import OSLog

/// Emits a capture trigger whenever the desktop changes in a way that could
/// matter — and at no other time.
///
/// This is the mechanism that keeps idle CPU near zero. A 30 fps screen grab
/// would burn battery continuously and produce almost entirely redundant
/// frames; instead every capture is attributable to an OS event, and typing is
/// debounced so we sample once the user pauses rather than per keystroke.
///
/// Notably this uses `AXObserver` rather than a `CGEventTap`: watching the
/// focused element's value change gives us the "user stopped typing" signal
/// without requesting Input Monitoring, i.e. without anything resembling a
/// keylogger.
public final class DesktopEventSource: @unchecked Sendable {
    public struct Event: Sendable {
        public var trigger: CaptureTrigger
        public var timestamp: Date
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Events")
    private let typingPause: TimeInterval

    private var continuation: AsyncStream<Event>.Continuation?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedElement: AXUIElement?
    private var workspaceToken: (any NSObjectProtocol)?
    private var typingDebounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.buddypia.mca.events")

    public init(typingPauseSeconds: TimeInterval = 1.5) {
        self.typingPause = typingPauseSeconds
    }

    deinit { stop() }

    /// Starts observing. Must be called with a live main run loop, which
    /// `AXObserver` requires.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.continuation = continuation

            self.workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.emit(.focusChanged)
                self.rebindObserver()
            }

            self.rebindObserver()
            self.emit(.focusChanged)  // prime with the current state

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        typingDebounce?.cancel()
        typingDebounce = nil

        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        tearDownObserver()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Emission

    private func emit(_ trigger: CaptureTrigger) {
        continuation?.yield(Event(trigger: trigger, timestamp: Date()))
    }

    /// Coalesces a burst of value changes into one event once the user pauses.
    private func emitAfterTypingPause() {
        typingDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.emit(.typingPaused)
        }
        typingDebounce = work
        queue.asyncAfter(deadline: .now() + typingPause, execute: work)
    }

    // MARK: - AXObserver lifecycle

    /// Rebinds the AX observer to whichever app is now frontmost. An AXObserver
    /// is per-process, so it has to follow the user.
    private func rebindObserver() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }

        tearDownObserver()
        guard AXIsProcessTrusted() else { return }

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let source = Unmanaged<DesktopEventSource>.fromOpaque(refcon).takeUnretainedValue()
            source.handle(notification as String)
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let newObserver
        else {
            log.debug("AXObserverCreate failed for pid \(pid, privacy: .public)")
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for notification in [
            kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
        ] {
            AXObserverAddNotification(newObserver, element, notification as CFString, refcon)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .defaultMode)

        observer = newObserver
        observedElement = element
        observedPID = pid
    }

    private static let focusedWindowChanged = kAXFocusedWindowChangedNotification as String
    private static let titleChanged = kAXTitleChangedNotification as String
    private static let valueChanged = kAXValueChangedNotification as String
    private static let selectedTextChanged = kAXSelectedTextChangedNotification as String

    private func handle(_ notification: String) {
        switch notification {
        case Self.focusedWindowChanged:
            emit(.focusChanged)
        case Self.titleChanged:
            emit(.windowTitleChanged)
        case Self.valueChanged,
             Self.selectedTextChanged:
            emitAfterTypingPause()
        default:
            emit(.valueChanged)
        }
    }

    private func tearDownObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode)
        }
        observer = nil
        observedElement = nil
        observedPID = 0
    }
}
