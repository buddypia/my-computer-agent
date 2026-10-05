import Foundation
import MCACore

/// What a browser can be asked to wait for.
public enum BrowserWaitCondition: Sendable, Equatable {
    case load(BrowserLoadState)
    case selector(String)
    case text(String)
    case milliseconds(Int)
}

/// Which URLs the agent may send a browser to.
///
/// The model chooses the URL, and a page it read can have chosen it first.
/// `file:` would put local documents in a tab the agent then reads; `javascript:`
/// and `data:` run attacker-supplied script in the user's logged-in browser;
/// custom schemes launch other applications. Only web pages are in scope.
public enum BrowserURLPolicy {
    /// The parsed URL when it is an `http(s)` URL with a host, otherwise a
    /// `navigationFailed` error. `allowBlank` additionally admits exactly
    /// `about:blank`, which opening a fresh tab needs.
    public static func validate(_ raw: String, allowBlank: Bool = false) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowBlank, trimmed.lowercased() == "about:blank", let blank = URL(string: "about:blank") {
            return blank
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw BrowserError.navigationFailed("invalid URL \(raw)")
        }
        guard scheme == "http" || scheme == "https" else {
            throw BrowserError.navigationFailed("only http and https URLs can be opened (got '\(scheme):')")
        }
        guard let host = url.host, !host.isEmpty else {
            throw BrowserError.navigationFailed("invalid URL \(raw)")
        }
        return url
    }
}

/// The capability the reasoning layer programs against.
///
/// Two implementations exist: `CDPBrowserDriver` (Chrome DevTools, full
/// fidelity) and `AXBrowserDriver` (macOS Accessibility, any browser). Both
/// produce the same outline format and the same ref semantics — a ref is
/// valid only for the snapshot that produced it — so the tools and prompts do
/// not care which one is underneath.
public protocol BrowserDriving: Sendable {
    var kind: BrowserDriverKind { get }
    /// Bind to a specific user-selected window, or reject if identity cannot be established.
    func scope(to window: PinnedWindow) async throws

    /// Establishes the connection. Idempotent; cheap when already connected.
    func connect() async throws
    /// Human-readable description of what is connected, for tool output.
    func describeConnection() async -> String

    func snapshot(options: BrowserSnapshotOptions) async throws -> BrowserSnapshot
    /// Runs one deterministic action. `ref` is the element the action targets
    /// (nil for element-less methods); `target` is the drop target for
    /// `dragAndDrop`. Returns a short message for the model.
    func perform(_ action: BrowserAction, ref: BrowserElementRef?, target: BrowserElementRef?) async throws -> String

    func navigate(to url: String, waitUntil: BrowserLoadState) async throws
    /// Returns false when history has nowhere to go.
    func goBack() async throws -> Bool
    func goForward() async throws -> Bool
    func reload() async throws
    func wait(for condition: BrowserWaitCondition, timeout: TimeInterval) async throws

    func currentPage() async throws -> (url: String, title: String)
    /// Visible text of the document (innerText).
    func pageText() async throws -> String
    func screenshotPNG() async throws -> Data

    func tabs() async throws -> [BrowserTab]
    func openTab(url: String) async throws -> BrowserTab
    func switchTab(id: String) async throws
    func closeTab(id: String) async throws

    /// JavaScript evaluation. Drivers without a script engine throw
    /// `BrowserError.unsupportedAction`.
    func evaluate(_ expression: String) async throws -> String
}

public extension BrowserDriving {
    func scope(to window: PinnedWindow) async throws {
        throw BrowserError.unsupportedAction("this driver cannot verify the selected macOS window identity")
    }
}
