import Foundation

/// A window the watch has been pinned to.
///
/// Identified by window number rather than by name, because names are not
/// identity: two Chrome windows can carry the same title, and a browser window's
/// title changes on every navigation. Pinning by title would either follow the
/// wrong window or lose the right one the moment the user clicked a link — and a
/// watch that silently changes what it is looking at is worse than one that
/// stops.
///
/// The name is carried anyway, for the sentence the interface has to write. "Not
/// watching window 41773" is not something a user can act on.
public struct PinnedWindow: Sendable, Equatable, Identifiable, Codable {
    /// `CGWindowID`, spelled as its underlying type so this layer keeps its
    /// promise of depending on nothing.
    public var id: UInt32
    public var appName: String
    public var windowTitle: String
    public var bundleID: String?
    public var processID: pid_t?

    public init(id: UInt32, appName: String, windowTitle: String, bundleID: String? = nil, processID: pid_t? = nil) {
        self.id = id
        self.appName = appName
        self.windowTitle = windowTitle
        self.bundleID = bundleID
        self.processID = processID
    }

    /// What to call this window in one line of interface.
    ///
    /// Falls back to the application on its own for a window that exposes no
    /// title, which is most of them on a first capture — the title arrives with
    /// the first frame, not with the pin.
    public var displayName: String {
        windowTitle.isEmpty ? appName : "\(appName) — \(windowTitle)"
    }
}

/// A whole display the watch has been pinned to.
///
/// The unit for "keep an eye on that monitor" — work spread across two screens
/// where the interesting half is the one you are not typing into. Coarser than a
/// window on purpose: windows moved around inside the display stay in frame,
/// which is the entire difference from pinning one of them.
///
/// The privacy cost is real and is paid for in `ScreenCapturer`: a display holds
/// windows belonging to applications the user may have excluded, and those are
/// left out of the frame rather than photographed and hoped about.
public struct PinnedDisplay: Sendable, Equatable, Identifiable, Codable {
    /// `CGDirectDisplayID`, spelled as its underlying type for the same reason
    /// `PinnedWindow.id` is.
    public var id: UInt32
    /// What macOS calls this screen, e.g. "Built-in Retina Display".
    public var name: String
    public var width: Int
    public var height: Int

    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }

    /// A display that has lost its name is still worth naming something. The
    /// number is stable and at least distinguishes two of them.
    public var displayName: String {
        name.isEmpty ? "Display \(id)" : name
    }

    public var resolution: String { "\(width)×\(height)" }
}

/// What the periodic watch looks at.
///
/// The cases are not variations on a theme; they answer different questions.
/// `focused` means "whatever I am doing now", and it follows the user around at
/// the cost of losing sight of anything the moment they look away. The other two
/// mean "that, specifically", and they hold still — which is the only way to
/// watch a build that takes four minutes while working somewhere else, and the
/// only way the watch survives the user coming to this app to ask a question.
///
/// `pinned` and `display` differ in what counts as staying still. A pinned
/// window follows its own content wherever the window is dragged; a pinned
/// display holds a region of the desk and lets whatever is on it come and go.
public enum WatchTarget: Sendable, Equatable, Codable {
    case focused
    case pinned(PinnedWindow)
    case display(PinnedDisplay)

    public var pinnedWindow: PinnedWindow? {
        if case .pinned(let window) = self { return window }
        return nil
    }

    public var pinnedDisplay: PinnedDisplay? {
        if case .display(let display) = self { return display }
        return nil
    }

    /// Whether the watch is held on one subject rather than following focus.
    public var isPinned: Bool {
        if case .focused = self { return false }
        return true
    }

    /// One line naming what is being watched, or `nil` while following focus.
    public var subjectName: String? {
        switch self {
        case .focused: return nil
        case .pinned(let window): return window.displayName
        case .display(let display): return display.displayName
        }
    }

    /// A stable name for this target, for keying a thumbnail to it.
    ///
    /// Built from the identifier alone rather than from the whole value. The
    /// picker re-photographs its rows every few seconds, and a key that included
    /// the title would miss its own cache the moment a browser navigated —
    /// leaving the row blank for a beat, which reads as the window having closed.
    public var key: String {
        switch self {
        case .focused: return "focused"
        case .pinned(let window): return "window:\(window.id)"
        case .display(let display): return "display:\(display.id)"
        }
    }
}

/// Everything the user could pin right now.
///
/// Gathered in one value rather than fetched per section, because the picker
/// shows both lists at once and two independent refreshes would let it render a
/// window list from one moment beside a display list from another.
public struct WatchTargetList: Sendable, Equatable {
    public var windows: [PinnedWindow]
    public var displays: [PinnedDisplay]

    public init(windows: [PinnedWindow] = [], displays: [PinnedDisplay] = []) {
        self.windows = windows
        self.displays = displays
    }

    public static let empty = WatchTargetList()

    public var isEmpty: Bool { windows.isEmpty && displays.isEmpty }
}

/// Why a window cannot be pinned.
///
/// A pin is refused rather than accepted-then-ignored: the user picked a window
/// deliberately, so "this one will not be watched, and here is why" is the only
/// honest answer. Silently pinning something the privacy gate then skips forever
/// would look identical to the feature being broken.
public enum PinRefusal: Sendable, Equatable {
    /// The frontmost window belongs to this app. Watching it would photograph
    /// the agent's own output and feed it back as if it were the user's work.
    case ownWindow
    /// The app or window title is on the privacy exclusion list.
    ///
    /// An explicit pin does *not* override the list. The list is where the user
    /// wrote down what must never be sent, and a shortcut pressed over the wrong
    /// window is exactly the accident it exists to catch.
    case excluded(appName: String)
    /// Nothing was frontmost, or it exposed no capturable window.
    case noWindow

    /// Decides whether a candidate window can be watched.
    ///
    /// Pure, and separate from the capture that produces the candidate, because
    /// this is the privacy boundary — the one piece of the pin worth testing
    /// without a display, a permission dialog or a running app behind it.
    public static func refusal(
        for window: PinnedWindow?,
        isOwnWindow: Bool,
        isExcluded: Bool
    ) -> PinRefusal? {
        guard let window else { return .noWindow }
        if isOwnWindow { return .ownWindow }
        if isExcluded { return .excluded(appName: window.appName) }
        return nil
    }
}
