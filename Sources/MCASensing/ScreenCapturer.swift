import CoreGraphics
import Foundation
import MCACore
import OSLog
import ScreenCaptureKit

/// On-demand single-frame capture of the focused window.
///
/// Deliberately *not* an `SCStream`. Streaming exists to deliver frames at a
/// fixed rate; we only ever want a frame at the moment an OS event says the
/// screen changed meaningfully, which is what `SCScreenshotManager` is for.
/// This is the difference between ~3% idle CPU and a hot fan.
public final class ScreenCapturer: Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case noMatchingWindow
        case windowExcluded
        /// A window that was being watched is no longer on screen — closed,
        /// minimised, or moved to another Space. Distinct from
        /// `noMatchingWindow` because the caller's response differs: this one
        /// ends a watch the user explicitly started, and has to say so.
        case windowGone
        /// A display that was being watched is no longer attached.
        case displayGone
        /// The window belongs to an application the privacy settings exclude.
        case excluded
        case captureFailed(Error)

        public var description: String {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission not granted"
            case .noMatchingWindow:
                return "No on-screen window matched the frontmost application"
            case .windowExcluded:
                return "The window is excluded from screen capture"
            case .windowGone:
                return "The window is no longer on screen"
            case .displayGone:
                return "The display is no longer attached"
            case .excluded:
                return "The window belongs to an application excluded by the privacy settings"
            case .captureFailed(let e):
                return "Screen capture failed: \(e.localizedDescription)"
            }
        }
    }

    /// A frame plus who it belongs to, read at capture time.
    ///
    /// The identity travels with the picture rather than being remembered from
    /// when the window was pinned, because a window's title is the part of it
    /// most likely to change while being watched — a browser navigating, an
    /// editor switching files — and the privacy exclusion list is matched
    /// against titles. Trusting the title recorded at pin time would let a
    /// window drift into something the user asked never to send.
    public struct WindowCapture: Sendable {
        public var image: CGImage
        public var appName: String
        public var bundleID: String?
        public var windowTitle: String
        public var frame: CGRect
        public var processID: pid_t?

        public init(
            image: CGImage,
            appName: String,
            bundleID: String? = nil,
            windowTitle: String,
            frame: CGRect = .zero,
            processID: pid_t? = nil
        ) {
            self.image = image
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
            self.frame = frame
            self.processID = processID
        }
    }

    /// A frame of a whole display, and what was kept out of it.
    ///
    /// The count is carried because the interface has to be able to say it. A
    /// user who pinned a monitor and then opened their password manager on it
    /// should be told the manager is being left out, rather than having to
    /// deduce it from an agent that never mentions the window in front of them.
    public struct DisplayCapture: Sendable {
        public var image: CGImage
        public var excludedWindows: Int
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "ScreenCapture")

    /// Pixels per logical window point. Keep UI text at its point resolution;
    /// halving it makes small labels and metrics unreadable to OCR. Thumbnails
    /// pass their own lower scale explicitly.
    private let scale: Double

    public init(scale: Double = 1.0) {
        self.scale = scale
    }

    /// The privacy list, asked per window: `(bundleID, windowTitle)`.
    public typealias WindowExclusion = @Sendable (_ bundleID: String?, _ windowTitle: String) -> Bool

    private static let processExclusion = ExclusionBox()

    private final class ExclusionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var exclusion: WindowExclusion?

        var value: WindowExclusion? {
            get { lock.withLock { exclusion } }
            set { lock.withLock { exclusion = newValue } }
        }
    }

    /// The user's exclusion list for every capture in this process, including
    /// those made by code that is never handed the configuration (the System One
    /// screenshot, the accessibility fallbacks of the agent tools). Set once by
    /// the composition root; each capture applies it on top of whatever it was
    /// passed explicitly, so a path that forgot to thread the list through still
    /// honours it.
    public static var processWideExclusion: WindowExclusion? {
        get { processExclusion.value }
        set { processExclusion.value = newValue }
    }

    /// Whether a window must be kept out of any frame.
    ///
    /// Password managers are refused unconditionally — a capture path that
    /// forgot to pass the user's list must not become a way around it — and
    /// `extra` plus the process-wide list add the user's own exclusions on top.
    static func isRefused(
        bundleID: String?, windowTitle: String,
        extra: (_ bundleID: String?, _ windowTitle: String) -> Bool
    ) -> Bool {
        PrivacyFilter.isWindowExcluded(bundleID: bundleID, windowTitle: windowTitle)
            || extra(bundleID, windowTitle)
            || (processWideExclusion?(bundleID, windowTitle) ?? false)
    }

    /// The windows a whole-display frame has to be composited without.
    private static func windowsToExclude(
        in content: SCShareableContent,
        extra: (_ bundleID: String?, _ windowTitle: String) -> Bool
    ) -> [SCWindow] {
        content.windows.filter {
            isRefused(
                bundleID: $0.owningApplication?.bundleIdentifier,
                windowTitle: $0.title ?? "", extra: extra)
        }
    }

    /// Whether Screen Recording permission is granted. `SCShareableContent`
    /// throws rather than returning empty when it is not.
    public static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Captures the frontmost window of `pid`. A missing target fails
    /// rather than photographing unrelated windows.
    public func captureFocusedWindow(
        pid: pid_t, excluding isExcluded: WindowExclusion? = nil
    ) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = Self.frontWindow(in: content, pid: pid) else {
            throw CaptureError.noMatchingWindow
        }

        do {
            return try await captureCheckedWindow(window, excluding: isExcluded ?? { _, _ in false }).image
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Identifies the frontmost window of `pid`, without photographing it.
    ///
    /// This is what turns "the window I am looking at" into something that can
    /// be held onto after the user looks away. Separate from the capture because
    /// pinning happens once, at a keypress, and must be able to fail with a
    /// reason the user can read — while the captures that follow happen every
    /// interval and must be cheap.
    public func focusedWindow(pid: pid_t) async throws -> PinnedWindow {
        let content = try await shareableContent()
        guard let window = Self.frontWindow(in: content, pid: pid) else {
            throw CaptureError.noMatchingWindow
        }
        return Self.describe(window)
    }

    /// Photographs a specific window, wherever it is in the stacking order.
    ///
    /// Window capture on macOS does not require the window to be visible: a
    /// window buried behind three others still renders, which is the entire
    /// reason a pinned watch can work at all. It does require the window to
    /// *exist* and be on screen — minimising it or moving it to another Space
    /// takes it out of `SCShareableContent`, and that is reported as
    /// `windowGone` rather than as a capture failure, because it is a thing the
    /// user did rather than a thing that broke.
    public func captureWindow(
        _ pinned: PinnedWindow,
        excluding isExcluded: @Sendable (String?, String) -> Bool = { PrivacyFilter.isWindowExcluded(bundleID: $0, windowTitle: $1) }
    ) async throws -> WindowCapture {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: {
            $0.windowID == pinned.id && $0.isOnScreen
        }) else {
            throw CaptureError.windowGone
        }

        let identity = Self.describe(window)
        guard (pinned.processID == nil || pinned.processID == identity.processID),
              (pinned.bundleID == nil || pinned.bundleID == identity.bundleID) else {
            throw CaptureError.windowGone
        }
        guard !Self.isRefused(bundleID: identity.bundleID, windowTitle: identity.windowTitle, extra: isExcluded) else {
            throw CaptureError.windowExcluded
        }
        do {
            return try await captureCheckedWindow(window, excluding: isExcluded)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Post-capture validation seam shared by real pinned capture and deterministic callers.
    static func revalidatedWindowCapture(
        _ captured: WindowCapture, target: PinnedWindow,
        excluding isExcluded: WindowExclusion,
        freshWindow: @Sendable () async throws -> (window: PinnedWindow, frame: CGRect)?
    ) async throws -> WindowCapture {
        try Task.checkCancellation()
        guard let fresh = try await freshWindow() else { throw CaptureError.windowGone }
        try Task.checkCancellation()
        guard !Self.isRefused(bundleID: fresh.window.bundleID, windowTitle: fresh.window.windowTitle, extra: isExcluded) else {
            throw CaptureError.windowExcluded
        }
        guard fresh.window.id == target.id,
              let pid = captured.processID, fresh.window.processID == pid,
              (target.processID == nil || target.processID == pid),
              captured.bundleID == fresh.window.bundleID,
              (target.bundleID == nil || target.bundleID == fresh.window.bundleID),
              captured.windowTitle == fresh.window.windowTitle,
              captured.frame == fresh.frame,
              AccessibilityInspector.isValidCoordinateRect(fresh.frame) else { throw CaptureError.windowGone }
        try Task.checkCancellation()
        return captured
    }

    static func revalidatedDisplayImage(
        _ image: CGImage, excluded: Set<CGWindowID>,
        freshExcluded: @Sendable () async throws -> Set<CGWindowID>
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let current = try await freshExcluded()
        try Task.checkCancellation()
        guard current == excluded else { throw CaptureError.excluded }
        return image
    }

    private func captureCheckedWindow(_ window: SCWindow, excluding isExcluded: WindowExclusion,
                                      scale: Double? = nil) async throws -> WindowCapture {
        let identity = Self.describe(window), frame = window.frame
        guard !Self.isRefused(bundleID: identity.bundleID, windowTitle: identity.windowTitle, extra: isExcluded) else {
            throw CaptureError.windowExcluded
        }
        try Task.checkCancellation()
        let image = try await capture(filter: SCContentFilter(desktopIndependentWindow: window),
            width: frame.width, height: frame.height, scale: scale)
        let captured = WindowCapture(image: image, appName: identity.appName, bundleID: identity.bundleID,
            windowTitle: identity.windowTitle, frame: frame, processID: identity.processID)
        return try await Self.revalidatedWindowCapture(captured, target: identity, excluding: isExcluded,
            freshWindow: { try await self.freshIdentity(for: identity.id) })
    }

    private func captureCheckedDisplay(_ display: SCDisplay, content: SCShareableContent,
        excluding isExcluded: WindowExclusion, scale: Double? = nil) async throws -> DisplayCapture {
        let displayID = display.displayID
        let excluded = Self.windowsToExclude(in: content, extra: isExcluded)
        try Task.checkCancellation()
        let image = try await capture(filter: SCContentFilter(display: display, excludingWindows: excluded),
            width: Double(display.width), height: Double(display.height), scale: scale)
        let checked = try await Self.revalidatedDisplayImage(image, excluded: Set(excluded.map(\.windowID)),
            freshExcluded: {
                let fresh = try await self.shareableContent()
                guard fresh.displays.contains(where: { $0.displayID == displayID }) else { throw CaptureError.displayGone }
                return Set(Self.windowsToExclude(in: fresh, extra: isExcluded).map(\.windowID))
            })
        return DisplayCapture(image: checked, excludedWindows: excluded.count)
    }

    private func freshIdentity(for id: CGWindowID) async throws -> (window: PinnedWindow, frame: CGRect)? {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id && $0.isOnScreen }) else { return nil }
        let identity = Self.describe(window)
        return (PinnedWindow(id: id, appName: identity.appName, windowTitle: identity.windowTitle,
            bundleID: identity.bundleID, processID: identity.processID), window.frame)
    }

    /// Resolves the current on-screen frame and process ID of a pinned window without performing a full capture.
    public func findWindowInfo(for pinned: PinnedWindow) async throws -> (frame: CGRect, processID: pid_t?) {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: {
            $0.windowID == pinned.id && $0.isOnScreen
        }) else {
            throw CaptureError.windowGone
        }
        let pid = pinned.processID ?? window.owningApplication?.processID
        return (window.frame, pid)
    }

    /// Every window that could reasonably be pinned, frontmost first.
    ///
    /// Filtered rather than returned raw, because the raw list is mostly not
    /// windows in any sense a user recognises: status item hosts, offscreen
    /// popovers, one-pixel tracking rectangles and the wallpaper. A picker that
    /// showed those would bury the three windows the user is actually working
    /// in.
    ///
    /// This app's own windows are dropped here rather than at the call site —
    /// pinning one is refused anyway, so offering it is an invitation to a
    /// refusal. The privacy exclusion list is *not* applied here: this layer has
    /// no business reading the user's configuration, and the caller that owns it
    /// filters what comes back.
    /// System and background shell bundle IDs that should never be offered as target windows.
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.wallpaper",
        "com.apple.spotlight",
        "com.apple.windowmanager",
        "com.apple.loginwindow",
        "com.apple.screensaver",
        "com.apple.talagent",
        "com.apple.airplayuiagent",
        "com.apple.textinputmenuagent",
        "com.apple.textinputswitcher",
        "com.apple.quicklook.ui.helper",
    ]

    /// System application names (lowercased) that should be excluded from targets.
    public static let ignoredApplicationNames: Set<String> = [
        "finder",
        "notification center",
        "通知センター",
        "dock",
        "control center",
        "コントロールセンター",
        "spotlight",
        "wallpaper",
        "loginwindow",
        "screensaver",
    ]

    /// Pure predicate to determine whether an on-screen window qualifies as an observable application window.
    public static func isTargetable(
        windowLayer: Int,
        isOnScreen: Bool,
        width: Double,
        height: Double,
        bundleID: String?,
        appName: String,
        processID: pid_t,
        ownPID: pid_t
    ) -> Bool {
        guard isOnScreen,
              windowLayer == 0,
              width > 100,
              height > 100,
              processID != ownPID
        else {
            return false
        }

        if let bundleID = bundleID?.lowercased() {
            if ignoredBundleIDs.contains(bundleID)
                || bundleID.hasPrefix("com.apple.notificationcenter")
                || bundleID.hasPrefix("com.apple.widgetkit")
                || bundleID.contains(".widget")
            {
                return false
            }
        }

        let lowerAppName = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ignoredApplicationNames.contains(lowerAppName) {
            return false
        }

        return true
    }

    /// Determines whether an SCWindow qualifies as an observable application window.
    public static func isTargetableWindow(_ window: SCWindow, ownPID: pid_t) -> Bool {
        guard let app = window.owningApplication else { return false }
        return isTargetable(
            windowLayer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            width: window.frame.width,
            height: window.frame.height,
            bundleID: app.bundleIdentifier,
            appName: app.applicationName,
            processID: app.processID,
            ownPID: ownPID
        )
    }

    public func availableWindows() async throws -> [PinnedWindow] {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { Self.isTargetableWindow($0, ownPID: ownPID) }
            .map(Self.describe)
    }

    /// Photographs one display, leaving out anything the caller refuses.
    ///
    /// Strict about which display, unlike `captureDisplay`: falling back to
    /// another screen is right for a one-off "explain what I am looking at" and
    /// wrong for a standing watch, where it would quietly start photographing a
    /// monitor nobody asked about.
    ///
    /// `isExcluded` is the privacy list, asked per window. This is the only way
    /// a display capture can honour it at all — a display is a region, not an
    /// application, so the choice is between filtering the windows out of the
    /// frame here and sending a picture of the user's password manager every 45
    /// seconds. `SCContentFilter` removes them before the frame is composited,
    /// so the excluded pixels are never drawn rather than drawn and painted
    /// over.
    public func capturePinnedDisplay(
        _ pinned: PinnedDisplay,
        excluding isExcluded: @Sendable (_ bundleID: String?, _ windowTitle: String) -> Bool
    ) async throws -> DisplayCapture {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == pinned.id }) else {
            throw CaptureError.displayGone
        }

        do {
            return try await captureCheckedDisplay(display, content: content, excluding: isExcluded)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Small stills of several windows, for a picker to draw.
    ///
    /// Separate from `captureWindow` because the two want opposite things from
    /// the same frame. A watch capture is read by OCR and has to stay legible; a
    /// thumbnail is looked at from across a grid and only has to be
    /// recognisable, so it is taken at a fraction of the size.
    ///
    /// Batched rather than one call per tile because the expensive part is not
    /// the screenshot — it is asking the window server what exists.
    /// `SCShareableContent` is an XPC round trip, and paying one of those per
    /// tile every few seconds is most of what a live picker would cost.
    ///
    /// Windows that have gone are simply absent from the result. A tile whose
    /// window closed while the grid was open is a stale picture, not an error
    /// the user has to dismiss.
    public func previews(
        of windows: [PinnedWindow], maxWidth: Double = 420
    ) async -> [UInt32: CGImage] {
        guard !windows.isEmpty, let content = try? await shareableContent() else { return [:] }

        var pending: [UInt32: WindowCapture] = [:]
        for pinned in windows {
            guard !Task.isCancelled else { return [:] }
            guard let window = content.windows.first(where: { $0.windowID == pinned.id && $0.isOnScreen }) else { continue }
            let identity = Self.describe(window)
            guard (pinned.processID == nil || pinned.processID == identity.processID),
                  (pinned.bundleID == nil || pinned.bundleID == identity.bundleID),
                  !Self.isRefused(bundleID: identity.bundleID, windowTitle: identity.windowTitle, extra: { _, _ in false }) else { continue }
            if let image = try? await capture(filter: SCContentFilter(desktopIndependentWindow: window),
                width: window.frame.width, height: window.frame.height,
                scale: Self.thumbnailScale(for: window.frame.width, maxWidth: maxWidth)) {
                pending[pinned.id] = WindowCapture(image: image, appName: identity.appName, bundleID: identity.bundleID,
                    windowTitle: identity.windowTitle, frame: window.frame, processID: identity.processID)
            }
        }
        guard !Task.isCancelled, let fresh = try? await shareableContent(), !Task.isCancelled else { return [:] }
        let identities = Dictionary(uniqueKeysWithValues: fresh.windows.filter(\.isOnScreen).map { ($0.windowID, (window: Self.describe($0), frame: $0.frame)) })
        var result: [UInt32: CGImage] = [:]
        for (id, captured) in pending {
            guard !Task.isCancelled else { return [:] }
            let target = PinnedWindow(id: id, appName: captured.appName, windowTitle: captured.windowTitle,
                bundleID: captured.bundleID, processID: captured.processID)
            if let checked = try? await Self.revalidatedWindowCapture(captured, target: target,
                excluding: { _, _ in false }, freshWindow: { identities[id] }) { result[id] = checked.image }
        }
        return Task.isCancelled ? [:] : result
    }

    /// Small stills of whole displays, with the same windows left out that a
    /// real capture would leave out.
    ///
    /// The exclusion is not a detail: this picture is shown to the user as an
    /// answer to "what would the agent see here", and a preview that included an
    /// app the privacy list forbids would be a lie about what gets sent.
    public func previews(
        of displays: [PinnedDisplay],
        maxWidth: Double = 420,
        excluding isExcluded: @Sendable (_ bundleID: String?, _ windowTitle: String) -> Bool
    ) async -> [UInt32: CGImage] {
        guard !displays.isEmpty, let content = try? await shareableContent() else { return [:] }

        let excluded = Self.windowsToExclude(in: content, extra: isExcluded)

        var result: [UInt32: CGImage] = [:]
        for pinned in displays {
            guard !Task.isCancelled else { return [:] }
            guard let display = content.displays.first(where: {
                $0.displayID == pinned.id
            }) else { continue }

            if let image = try? await capture(
                filter: SCContentFilter(display: display, excludingWindows: excluded),
                width: Double(display.width),
                height: Double(display.height),
                scale: Self.thumbnailScale(for: Double(display.width), maxWidth: maxWidth)) {
                result[pinned.id] = image
            }
        }
        guard !Task.isCancelled, let fresh = try? await shareableContent(), !Task.isCancelled else { return [:] }
        let freshIDs = Set(Self.windowsToExclude(in: fresh, extra: isExcluded).map(\.windowID))
        let displayIDs = Set(fresh.displays.map(\.displayID))
        var checked: [UInt32: CGImage] = [:]
        for (id, image) in result where displayIDs.contains(id) {
            guard !Task.isCancelled else { return [:] }
            if let permitted = try? await Self.revalidatedDisplayImage(image, excluded: Set(excluded.map(\.windowID)),
                freshExcluded: { freshIDs }) { checked[id] = permitted }
        }
        return Task.isCancelled ? [:] : checked
    }

    /// Captures a whole display.
    ///
    /// Exists for "explain what is on my screen", which is asked *from* one of
    /// this app's own windows — so the frontmost application at that moment is
    /// this one, and the focused-window path would photograph the question
    /// rather than the thing it is about. The display capture sidesteps that
    /// entirely: our windows set `sharingType = .none`, so macOS leaves them out
    /// of the frame and what comes back is the user's screen as it was before
    /// they clicked.
    ///
    /// `displayID` is passed in rather than worked out here because deciding
    /// *which* screen the user means needs `NSScreen`, which is main-actor
    /// state, and this type is deliberately off the main actor. Unspecified — or
    /// unmatched, on a display that was just unplugged — falls back to the first
    /// one, which is the only answer available when there is nothing better.
    ///
    /// Windows of password managers are always left out, plus whatever `isExcluded`
    /// refuses: unlike a window capture, nothing upstream has checked what
    /// happens to be on this display.
    public func captureDisplay(
        displayID: CGDirectDisplayID? = nil, excluding isExcluded: WindowExclusion? = nil
    ) async throws -> CGImage {
        let content = try await shareableContent()

        let match = displayID.flatMap { id in
            content.displays.first { $0.displayID == id }
        }
        guard let display = match ?? content.displays.first else {
            throw CaptureError.noMatchingWindow
        }
        do {
            return try await captureCheckedDisplay(display, content: content,
                excluding: isExcluded ?? { _, _ in false }).image
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Captures a whole display at native 1.0 resolution (unscaled), ensuring that
    /// cropped regions maintain full visual fidelity.
    public func captureDisplayFullResolution(
        displayID: CGDirectDisplayID? = nil, excluding isExcluded: WindowExclusion? = nil
    ) async throws -> CGImage {
        let content = try await shareableContent()

        let match = displayID.flatMap { id in
            content.displays.first { $0.displayID == id }
        }
        guard let display = match ?? content.displays.first else {
            throw CaptureError.noMatchingWindow
        }
        do {
            return try await captureCheckedDisplay(display, content: content,
                excluding: isExcluded ?? { _, _ in false }, scale: 1.0).image
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Translates a selection rectangle on a display into pixel crop bounds within a captured CGImage.
    ///
    /// Handles translation from AppKit coordinates (bottom-left origin) to CGImage coordinates
    /// (top-left origin), screen-to-image pixel scaling, and bounds clamping.
    public static func calculatePixelCropRect(
        screenRect: CGRect,
        displayBounds: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        guard displayBounds.width > 0, displayBounds.height > 0,
              imageWidth > 0, imageHeight > 0 else {
            return .zero
        }

        let standard = screenRect.standardized
        let localX = standard.origin.x - displayBounds.origin.x
        let localY = standard.origin.y - displayBounds.origin.y

        // AppKit bottom-left to top-left inverted Y
        let flippedY = displayBounds.height - (localY + standard.height)

        let scaleX = Double(imageWidth) / displayBounds.width
        let scaleY = Double(imageHeight) / displayBounds.height

        let pixelX = max(0, min(Double(imageWidth), localX * scaleX))
        let pixelY = max(0, min(Double(imageHeight), flippedY * scaleY))
        let pixelW = max(1, min(Double(imageWidth) - pixelX, standard.width * scaleX))
        let pixelH = max(1, min(Double(imageHeight) - pixelY, standard.height * scaleY))

        return CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
    }

    /// Crops a CGImage to the specified pixel rectangle.
    public static func crop(image: CGImage, to pixelRect: CGRect) -> CGImage? {
        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return image.cropping(to: pixelRect)
    }

    /// Captures a specific rectangular region of a display.
    ///
    /// - Parameters:
    ///   - rect: Selection rectangle in display coordinate space.
    ///   - displayBounds: The display's full bounds in the same coordinate space as `rect`.
    ///   - displayID: Optional ID of the display to capture.
    /// - Returns: Cropped CGImage containing only the selected region.
    public func captureRegion(
        rect: CGRect,
        displayBounds: CGRect,
        displayID: CGDirectDisplayID? = nil,
        excluding isExcluded: WindowExclusion? = nil
    ) async throws -> CGImage {
        let fullImage = try await captureDisplayFullResolution(displayID: displayID, excluding: isExcluded)
        let cropRect = Self.calculatePixelCropRect(
            screenRect: rect,
            displayBounds: displayBounds,
            imageWidth: fullImage.width,
            imageHeight: fullImage.height)
        guard let cropped = Self.crop(image: fullImage, to: cropRect) else {
            throw CaptureError.captureFailed(
                NSError(domain: "com.buddypia.mca.capture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to crop image to specified region"]))
        }
        return cropped
    }

    // MARK: - Shared lookups

    /// The window list, with a missing permission reported as such.
    ///
    /// `SCShareableContent` throws for a denied permission and for a dozen
    /// transient reasons that look identical from here, and the honest reading
    /// of "I cannot see any windows" is the one the user can act on.
    private func shareableContent() async throws -> SCShareableContent {
        try Task.checkCancellation()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            return content
        } catch {
            try Task.checkCancellation()
            throw CaptureError.permissionDenied
        }
    }

    /// Frontmost on-screen window belonging to `pid`. The list is already in
    /// front-to-back order.
    ///
    /// The size floor drops the invisible scaffolding every app carries —
    /// status item hosts, offscreen popovers, one-pixel tracking windows — which
    /// otherwise come back first and get pinned instead of the document the user
    /// was looking at.
    private static func frontWindow(in content: SCShareableContent, pid: pid_t) -> SCWindow? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.first { window in
            window.owningApplication?.processID == pid
                && isTargetableWindow(window, ownPID: ownPID)
        }
    }

    private static func describe(_ window: SCWindow) -> PinnedWindow {
        PinnedWindow(
            id: window.windowID,
            appName: window.owningApplication?.applicationName ?? "Unknown",
            windowTitle: window.title ?? "",
            bundleID: window.owningApplication?.bundleIdentifier,
            processID: window.owningApplication?.processID)
    }

    /// How far down to scale a frame of `width` so it lands inside `maxWidth`.
    ///
    /// Never scales *up*: a 300-point palette window blown up to 420 is blurrier
    /// than the thing it is a picture of, and costs more to encode.
    static func thumbnailScale(for width: Double, maxWidth: Double) -> Double {
        guard width > 0 else { return 1 }
        return min(1, maxWidth / width)
    }

    private func capture(
        filter: SCContentFilter, width: Double, height: Double, scale: Double? = nil
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let factor = scale ?? self.scale
        let config = SCStreamConfiguration()
        config.width = max(Int(width * factor), 1)
        config.height = max(Int(height * factor), 1)
        config.captureResolution = .best
        config.showsCursor = false
        // Excluding our own HUD keeps the agent from reading its own output and
        // feeding it back into the next prompt.
        config.ignoreShadowsSingleWindow = true

        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        return image
    }
}
