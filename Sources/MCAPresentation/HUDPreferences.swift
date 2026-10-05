import AppKit
import Foundation
import MCACore

/// Which screen corner the overlay anchors to.
///
/// The default is the top-right, but that is exactly where many apps keep
/// their own controls, so the choice has to be the user's rather than ours.
public enum HUDCorner: String, CaseIterable, Sendable {
    case topRight, topLeft, bottomRight, bottomLeft

    @MainActor
    public var title: String {
        switch self {
        case .topRight: return localized("Top Right", "右上", "우측 상단")
        case .topLeft: return localized("Top Left", "左上", "좌측 상단")
        case .bottomRight: return localized("Bottom Right", "右下", "우측 하단")
        case .bottomLeft: return localized("Bottom Left", "左下", "좌측 하단")
        }
    }

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topRight || self == .topLeft }

    /// Bottom-left origin for a panel of this size, inset from the visible
    /// frame so the overlay never sits under the menu bar or the Dock.
    func origin(in visible: NSRect, width: CGFloat, height: CGFloat) -> NSPoint {
        let inset: CGFloat = 24
        let x = isRight ? visible.maxX - width - inset : visible.minX + inset
        let y = isTop ? visible.maxY - height - 12 : visible.minY + 12
        return NSPoint(x: x, y: y)
    }
}

/// Overlay placement and visibility, remembered across launches.
///
/// This is deliberately `UserDefaults` rather than `AgentConfiguration`: it is
/// window state the user changes by clicking, not policy they edit in a config
/// file, and it must survive a quit — hiding the HUD is worthless if it comes
/// back on the next launch.
struct HUDPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let alwaysVisible = "hud.alwaysVisible"
        static let collapsed = "hud.collapsed"
        static let clickThrough = "hud.clickThrough"
        static let floating = "hud.floating"
        static let capturable = "hud.capturable"
        static let corner = "hud.corner"
        static let originX = "hud.originX"
        static let originY = "hud.originY"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A fresh install puts nothing on screen: the agent lives in the menu
        // bar and the floating overlay is opt-in. Click-through is off, so the
        // overlay a user does ask for is a window they can actually click.
        defaults.register(defaults: [
            Key.alwaysVisible: false,
            Key.collapsed: false,
            Key.clickThrough: false,
            Key.floating: true,
            Key.capturable: false,
        ])
    }

    /// Whether the floating overlay is on screen at all.
    ///
    /// Off — the default — the agent's output lives in a popover under the ✨
    /// menu bar item, which is on screen only while the user is looking at it.
    /// An always-on-top window over someone else's work has to be something
    /// they asked for, not something they have to discover how to turn off.
    ///
    /// The key is deliberately not the old `hud.visible`: an existing install
    /// had that set to `true`, and reusing it would silently opt every one of
    /// them into the behaviour this setting exists to stop.
    var isAlwaysVisible: Bool {
        get { defaults.bool(forKey: Key.alwaysVisible) }
        nonmutating set { defaults.set(newValue, forKey: Key.alwaysVisible) }
    }

    var isCollapsed: Bool {
        get { defaults.bool(forKey: Key.collapsed) }
        nonmutating set { defaults.set(newValue, forKey: Key.collapsed) }
    }

    /// Whether clicks pass straight through the overlay to the app behind.
    ///
    /// Off by default, and that is a correction rather than a preference: on,
    /// the whole window is `ignoresMouseEvents`, so every click on the overlay
    /// — its buttons, its text, its question field — lands in whatever window
    /// happens to be underneath. A HUD that cannot be clicked and silently
    /// redirects clicks elsewhere reads as a broken window, not as a feature.
    var isClickThrough: Bool {
        get { defaults.bool(forKey: Key.clickThrough) }
        nonmutating set { defaults.set(newValue, forKey: Key.clickThrough) }
    }

    /// Whether the overlay floats above every other window.
    ///
    /// Separate from `isVisible` because "always in front" and "on screen at
    /// all" are different wants: a user who finds a permanently-on-top panel
    /// intrusive still wants the agent's answers, just behind whatever they are
    /// working in.
    var isFloating: Bool {
        get { defaults.bool(forKey: Key.floating) }
        nonmutating set { defaults.set(newValue, forKey: Key.floating) }
    }

    /// Whether the overlay appears in screenshots and screen shares.
    ///
    /// Off by default, and that default is load-bearing: the agent's own OCR
    /// path reads the screen, so a capturable overlay lets it read its own last
    /// answer back and feed it into the next prompt. The switch exists anyway
    /// because an invisible-to-screenshot window is impossible to report a bug
    /// about — the user screenshots the error and gets an empty rectangle.
    var isCapturable: Bool {
        get { defaults.bool(forKey: Key.capturable) }
        nonmutating set { defaults.set(newValue, forKey: Key.capturable) }
    }

    var corner: HUDCorner {
        get { HUDCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .topRight }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.corner) }
    }

    /// Where the user last dragged the panel. `nil` until they move it, so the
    /// corner preset stays in charge on a clean install.
    var origin: NSPoint? {
        get {
            guard defaults.object(forKey: Key.originX) != nil,
                  defaults.object(forKey: Key.originY) != nil
            else { return nil }
            return NSPoint(
                x: defaults.double(forKey: Key.originX),
                y: defaults.double(forKey: Key.originY))
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.originX)
                defaults.removeObject(forKey: Key.originY)
                return
            }
            defaults.set(Double(newValue.x), forKey: Key.originX)
            defaults.set(Double(newValue.y), forKey: Key.originY)
        }
    }
}
