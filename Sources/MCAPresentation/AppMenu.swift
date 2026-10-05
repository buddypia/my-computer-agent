import AppKit
import MCACore

/// The application's main menu.
///
/// An accessory-policy app never draws a menu bar, which makes it easy to
/// conclude — as this app did — that it does not need a main menu at all. It
/// does, and for a reason that has nothing to do with drawing: **standard text
/// editing shortcuts are implemented as menu key equivalents, not by the text
/// field.**
///
/// `NSApplication.sendEvent(_:)` offers every key-down to
/// `mainMenu.performKeyEquivalent(with:)` before anything else sees it. That is
/// where ⌘V turns into a `paste(_:)` message down the responder chain. With
/// `mainMenu` left `nil` the translation never happens, so in the Settings
/// window ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z all did nothing — while right-clicking worked,
/// because a text field's context menu targets the responder directly rather
/// than going through a key equivalent. Pasting an API key is the single most
/// important thing that window does, so this is not a cosmetic gap.
///
/// Every item is deliberately target-less. A `nil` target means AppKit sends
/// the action to the first responder and walks the chain, which is what makes
/// one Edit menu work for every text field in the app without wiring.
///
/// Titles are localized and identifiers are not: `mca setup` runs the app with
/// `.regular` policy, where this menu *is* drawn, so the titles are user-facing.
/// Anything that needs to find an item — a test, a future enable/disable pass —
/// matches on the identifier, which does not move when the language does.
@MainActor
public enum AppMenu {
    /// Stable names for the parts of the menu, independent of language.
    public enum ID {
        public static let application = "menu.application"
        public static let edit = "menu.edit"
        public static let window = "menu.window"

        public static let hide = "item.hide"
        public static let hideOthers = "item.hideOthers"
        public static let quit = "item.quit"
        public static let undo = "item.undo"
        public static let redo = "item.redo"
        public static let cut = "item.cut"
        public static let copy = "item.copy"
        public static let paste = "item.paste"
        public static let selectAll = "item.selectAll"
        public static let close = "item.close"
        public static let minimize = "item.minimize"
    }

    /// Installs the menu if the app has none.
    ///
    /// Idempotent: `Copilot.start()` and the standalone `mca setup` window both
    /// call it, and only one of them runs first.
    public static func install(applicationName: String = "My Computer Agent") {
        guard NSApplication.shared.mainMenu == nil else { return }
        NSApplication.shared.mainMenu = build(applicationName: applicationName)
    }

    /// Rebuilds the menu in the current language.
    ///
    /// Needed because the menu is built once at launch, so a language change
    /// would otherwise leave the one visible menu bar — the `.regular`-policy
    /// setup window — in the old language until the next relaunch.
    public static func rebuild(applicationName: String = "My Computer Agent") {
        NSApplication.shared.mainMenu = build(applicationName: applicationName)
    }

    private static func build(applicationName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu(named: applicationName))
        main.addItem(editMenu())
        main.addItem(windowMenu())
        return main
    }

    // MARK: - Menus

    private static func applicationMenu(named name: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: name)
        menu.identifier = NSUserInterfaceItemIdentifier(ID.application)

        // Hide and Quit are the two chords a user will try on any Mac app. The
        // menu bar item offers Quit too, but only to someone who thought to
        // look there.
        menu.addItem(entry(
            localized("Hide \(name)", "\(name) を隠す", "\(name) 가리기"),
            #selector(NSApplication.hide(_:)), "h", id: ID.hide))
        let hideOthers = entry(
            localized("Hide Others", "ほかを隠す", "다른 항목 가리기"),
            #selector(NSApplication.hideOtherApplications(_:)), "h", id: ID.hideOthers)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(.separator())
        menu.addItem(entry(
            localized("Quit \(name)", "\(name) を終了", "\(name) 종료"),
            #selector(NSApplication.terminate(_:)), "q", id: ID.quit))

        item.submenu = menu
        return item
    }

    /// The reason this file exists.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: localized("Edit", "編集", "편집"))
        menu.identifier = NSUserInterfaceItemIdentifier(ID.edit)

        menu.addItem(entry(
            localized("Undo", "取り消す", "실행 취소"), Selector(("undo:")), "z", id: ID.undo))
        let redo = entry(
            localized("Redo", "やり直す", "다시 실행"), Selector(("redo:")), "z", id: ID.redo)
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(entry(
            localized("Cut", "カット", "오려두기"), #selector(NSText.cut(_:)), "x", id: ID.cut))
        menu.addItem(entry(
            localized("Copy", "コピー", "복사하기"), #selector(NSText.copy(_:)), "c", id: ID.copy))
        menu.addItem(entry(
            localized("Paste", "ペースト", "붙여넣기"), #selector(NSText.paste(_:)), "v", id: ID.paste))
        menu.addItem(entry(
            localized("Select All", "すべてを選択", "전체 선택"),
            #selector(NSText.selectAll(_:)), "a", id: ID.selectAll))

        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: localized("Window", "ウインドウ", "윈도우"))
        menu.identifier = NSUserInterfaceItemIdentifier(ID.window)

        // ⌘W closes Settings. Without it the only way out is the traffic light,
        // which is a long way from a keyboard.
        menu.addItem(entry(
            localized("Close", "閉じる", "닫기"),
            #selector(NSWindow.performClose(_:)), "w", id: ID.close))
        menu.addItem(entry(
            localized("Minimize", "しまう", "최소화"),
            #selector(NSWindow.performMiniaturize(_:)), "m", id: ID.minimize))

        item.submenu = menu
        NSApplication.shared.windowsMenu = menu
        return item
    }

    // MARK: - Helper

    /// `target` is left `nil` on purpose — see the type's documentation.
    private static func entry(
        _ title: String, _ action: Selector, _ key: String, id: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    // MARK: - Test seam

    /// The chord and action bound to the item with `itemID`, for a test that has
    /// no run loop to press keys into.
    ///
    /// Keyed on identifiers rather than titles so the assertions keep holding in
    /// whatever language the machine running them happens to be set to.
    static func binding(
        for itemID: String, in menuID: String
    ) -> (key: String, modifiers: NSEvent.ModifierFlags, action: Selector?)? {
        guard let submenu = menu(menuID),
              let item = submenu.items.first(where: { $0.identifier?.rawValue == itemID })
        else { return nil }
        return (item.keyEquivalent, item.keyEquivalentModifierMask, item.action)
    }

    static func menu(_ menuID: String) -> NSMenu? {
        NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu)
            .first { $0.identifier?.rawValue == menuID }
    }
}
