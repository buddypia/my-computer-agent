import Foundation

// Value types for browser automation. These are the vocabulary shared by the
// drivers in MCASensing (which know how to talk to a browser) and the tools in
// MCAReasoning (which decide what to do), so they live in the layer both depend
// on. Nothing here performs I/O.
//
// The design is a "hybrid accessibility snapshot" model: the page
// is rendered as an indented text outline where every interactive node carries
// a stable encoded id such as `[0-1234]` (frame ordinal, then a backend node id
// or an element index). The model reads the outline, names an id, and the
// driver resolves that id back to a live element deterministically. Refs are
// only valid for the snapshot that produced them.

/// Where a snapshot came from. Refs are only meaningful for the driver that
/// produced them, so the kind travels with the snapshot.
public enum BrowserDriverKind: String, Sendable, Codable, Equatable {
    /// Chrome DevTools Protocol over a WebSocket. Full fidelity: DOM XPaths,
    /// scrollable containers, iframes, deterministic input.
    case devtools
    /// macOS Accessibility (AXWebArea). Works with any browser without flags,
    /// at the cost of no DOM identity and coarser actions.
    case accessibility
}

/// One node the model can act on, resolved from the outline's encoded id.
public struct BrowserElementRef: Sendable, Codable, Equatable, Hashable {
    /// The id exactly as printed in the outline, e.g. `0-1234`.
    public var id: String
    /// Accessibility role after decoration (`button`, `link`,
    /// `scrollable, div`, `input, file`).
    public var role: String
    public var name: String?
    /// Frame ordinal within the page (0 = main frame).
    public var frameOrdinal: Int
    /// DevTools backend node id, when the devtools driver produced it.
    public var backendNodeID: Int?
    /// Absolute XPath from the document root, when known. Useful for replay
    /// and for the self-heal path that re-resolves a stale element.
    public var xpath: String?
    /// Link target when the node is a link.
    public var url: String?
    /// Screen-space bounds in Quartz coordinates when the accessibility driver
    /// produced the ref; the devtools driver resolves geometry lazily instead.
    public var bounds: CGRect?

    public init(
        id: String, role: String, name: String? = nil, frameOrdinal: Int = 0,
        backendNodeID: Int? = nil, xpath: String? = nil, url: String? = nil,
        bounds: CGRect? = nil
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.frameOrdinal = frameOrdinal
        self.backendNodeID = backendNodeID
        self.xpath = xpath
        self.url = url
        self.bounds = bounds
    }
}

/// The page as the model sees it.
public struct BrowserSnapshot: Sendable, Equatable {
    public var driver: BrowserDriverKind
    public var url: String
    public var title: String
    /// The pruned, indented outline: one `[id] role: name` line per node.
    public var outline: String
    /// Every id that appears in the outline, resolvable by the driver.
    public var refs: [String: BrowserElementRef]
    public var capturedAt: Date

    public init(
        driver: BrowserDriverKind, url: String, title: String, outline: String,
        refs: [String: BrowserElementRef], capturedAt: Date = Date()
    ) {
        self.driver = driver
        self.url = url
        self.title = title
        self.outline = outline
        self.refs = refs
        self.capturedAt = capturedAt
    }

    /// Roughly how many tokens the outline costs. Used to decide when to trim.
    public var approximateTokenCount: Int { outline.utf8.count / 4 }
}

/// The deterministic actions a driver can perform on a resolved element.
///
/// The names are stable
/// because they are what the model is asked to emit in observe/act output.
public enum BrowserActionMethod: String, Sendable, Codable, CaseIterable, Equatable {
    case click
    case fill
    case type
    case press
    case scrollTo
    case nextChunk
    case prevChunk
    case selectOptionFromDropdown
    case hover
    case doubleClick
    case dragAndDrop

    /// Whether the action needs an element at all. `press` acts on whatever is
    /// focused, and the two chunk scrolls default to the document.
    public var requiresElement: Bool {
        switch self {
        case .press, .nextChunk, .prevChunk: return false
        default: return true
        }
    }

    /// The list handed to the model in prompts.
    public static var supportedNames: [String] { allCases.map(\.rawValue) }
}

/// A single grounded action: what to do, to which element, with what.
public struct BrowserAction: Sendable, Codable, Equatable {
    public var method: BrowserActionMethod
    /// Encoded id from the snapshot the action was planned against. Nil for
    /// element-less methods.
    public var elementID: String?
    /// Human description of the element, as the model wrote it. Kept so the
    /// self-heal path can re-find the element after the page changed.
    public var description: String
    public var arguments: [String]

    public init(
        method: BrowserActionMethod, elementID: String? = nil,
        description: String = "", arguments: [String] = []
    ) {
        self.method = method
        self.elementID = elementID
        self.description = description
        self.arguments = arguments
    }
}

/// What happened when an action ran.
public struct BrowserActionOutcome: Sendable, Equatable {
    public var success: Bool
    public var message: String
    public var actions: [BrowserAction]
    /// Set when the driver had to re-find the element after the first attempt
    /// failed — the caller reports it so the user knows the page shifted.
    public var selfHealed: Bool

    public init(success: Bool, message: String, actions: [BrowserAction] = [], selfHealed: Bool = false) {
        self.success = success
        self.message = message
        self.actions = actions
        self.selfHealed = selfHealed
    }
}

/// A browser tab as listed by the driver.
public struct BrowserTab: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var isActive: Bool

    public init(id: String, url: String, title: String, isActive: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}

/// Load states a navigation can be awaited on, in the DevTools sense.
public enum BrowserLoadState: String, Sendable, Codable, CaseIterable {
    case domcontentloaded
    case load
    /// No network activity for half a second (the DOM-settle rule).
    case networkidle
}

/// Options that shape a snapshot.
public struct BrowserSnapshotOptions: Sendable, Equatable {
    /// Case-insensitive substring (or `/regex/`) that a line must match to be
    /// kept; matching lines keep their ancestors so the tree stays readable.
    public var filter: String?
    /// Drop lines nested deeper than this.
    public var maxDepth: Int?
    /// Hard cap on outline characters. Lines past the cap are dropped and a
    /// trailing marker says how many were cut.
    public var maxCharacters: Int
    /// Include child frames (iframes) in the outline.
    public var includeFrames: Bool

    public init(filter: String? = nil, maxDepth: Int? = nil, maxCharacters: Int = 60_000, includeFrames: Bool = true) {
        self.filter = filter
        self.maxDepth = maxDepth
        self.maxCharacters = maxCharacters
        self.includeFrames = includeFrames
    }
}

/// Errors surfaced by every browser driver.
public enum BrowserError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No browser exposing a DevTools endpoint was found and no fallback applies.
    case notConnected(String)
    /// The ref is not in the current snapshot — the caller must snapshot again.
    case staleRef(String, available: Int)
    /// The element resolved but is not interactable (no geometry, detached).
    case elementNotInteractable(String)
    case unsupportedAction(String)
    case navigationFailed(String)
    case timeout(String)
    case protocolError(String)
    /// The page or app is on the privacy blocklist.
    case blocked(String)

    public var description: String {
        switch self {
        case .notConnected(let detail):
            return "No browser is connected: \(detail)"
        case .staleRef(let ref, let available):
            return "Unknown ref '\(ref)' — take a new browser_snapshot first to refresh refs (\(available) refs currently known)."
        case .elementNotInteractable(let detail):
            return "Element is not interactable: \(detail)"
        case .unsupportedAction(let method):
            return "Action '\(method)' is not supported by this browser driver."
        case .navigationFailed(let detail):
            return "Navigation failed: \(detail)"
        case .timeout(let what):
            return "Timed out waiting for \(what)."
        case .protocolError(let detail):
            return "Browser protocol error: \(detail)"
        case .blocked(let what):
            return "'\(what)' is excluded by the privacy settings and cannot be automated."
        }
    }
}
