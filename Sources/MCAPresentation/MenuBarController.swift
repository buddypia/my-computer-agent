import AppKit
import MCACore
import Observation

/// The status bar item, and the popover it opens.
///
/// This is now the agent's primary surface rather than a fallback for the
/// overlay. Nothing is on screen unless the user clicks the ✨ item, which
/// makes "always on top of my work" a thing they opt into instead of a thing
/// they have to find the switch for. Left click opens the popover; right or
/// control click opens the command menu.
///
/// It is also the one control that cannot fail the way the others can: a global
/// hot key can be lost to another app that registered the same chord first, and
/// the overlay may be turned off entirely.
///
/// The app runs with `.accessory` activation policy, so this is also the only
/// place a Quit command can live — there is no Dock icon and no app menu.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let state: HUDState
    /// The menu bar's own rendering of the HUD. Optional so the controller can
    /// still be constructed in a test without an `NSPopover`.
    private let popover: HUDPopover?
    /// Read only for display: the menu shows whatever chord each action is
    /// actually bound to, so a rebound or broken shortcut is never advertised
    /// as still working.
    private let hotKeys: HotKeyCenter?

    public var onToggleVisibility: (() -> Void)?
    public var onToggleCollapsed: (() -> Void)?
    public var onToggleClickThrough: (() -> Void)?
    public var onToggleFloating: (() -> Void)?
    public var onAsk: (() -> Void)?
    public var onSnipScreen: (() -> Void)?
    public var onClearChat: (() -> Void)?
    /// A voice command. Starts that mode, or ends it if it is the one running.
    public var onVoice: ((VoiceMode) -> Void)?
    public var onChooseCorner: ((HUDCorner) -> Void)?
    /// Opens the grid of windows and displays the agent could be pointed at.
    public var onChooseScreen: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenPermissions: (() -> Void)?

    public init(
        state: HUDState,
        popover: HUDPopover? = nil,
        hotKeys: HotKeyCenter? = nil
    ) {
        self.state = state
        self.popover = popover
        self.hotKeys = hotKeys
        super.init()
    }

    public func install() {
        // Variable rather than square: the button grows a count when cards
        // arrive while nothing is on screen.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles", accessibilityDescription: "Copilot")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Copilot"

        menu.delegate = self
        // We decide what is enabled; AppKit's automatic pass would re-enable
        // items that only make sense while the overlay is on screen.
        menu.autoenablesItems = false

        // The menu is attached only for the click that asked for it. Leaving it
        // on `statusItem.menu` would make *every* click open the menu, which is
        // what stops a left click from opening the popover.
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        refresh()
        track()
    }

    public func remove() {
        popover?.close()
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// Opens the menu bar popover, whatever the overlay is doing. The hot key
    /// for "ask a question" routes here when the overlay is off.
    public func showPopover() {
        guard let button = statusItem?.button else { return }
        popover?.show(relativeTo: button)
    }

    /// Shows how many cards arrived while nothing was on screen, so hiding the
    /// overlay never means silently dropping what the agent found.
    public func refresh() {
        guard let button = statusItem?.button else { return }

        let imageName = state.isClickThrough ? "cursorarrow.slash" : "sparkles"
        button.image = NSImage(
            systemSymbolName: imageName, accessibilityDescription: "Copilot")

        let unseen = state.unseenMessages
        button.title = unseen > 0 ? " \(unseen)" : ""
        button.toolTip = switch (unseen, state.isClickThrough, state.isAlwaysVisible) {
        case (let count, _, _) where count > 0:
            localized(
                "Copilot — \(count) unread. Click to read.",
                "Copilot — 未読 \(count) 件。クリックで表示。",
                "Copilot — 읽지 않음 \(count)건. 클릭하면 표시됩니다.")
        case (_, true, _):
            localized(
                "Copilot — click-through active (⌥⌘X). Click to open, right click for menu.",
                "Copilot — クリック透過中 (⌥⌘X)。クリックで開く、右クリックでメニュー。",
                "Copilot — 클릭 통과 활성화 (⌥⌘X). 클릭하면 열리고, 우클릭하면 메뉴가 나옵니다.")
        case (_, false, true):
            localized(
                "Copilot — the panel is on the desktop. Click to open, right click for the menu.",
                "Copilot — パネルをデスクトップに表示中。クリックで開く、右クリックでメニュー。",
                "Copilot — 패널을 데스크탑에 표시 중. 클릭하면 열리고, 우클릭하면 메뉴가 나옵니다.")
        case (_, false, false):
            localized(
                "Copilot — running. Click to open, right click for the menu.",
                "Copilot — 動作中。クリックで開く、右クリックでメニュー。",
                "Copilot — 실행 중. 클릭하면 열리고, 우클릭하면 메뉴가 나옵니다.")
        }
    }

    /// Keeps the button in step with the panel without every call site having
    /// to remember to refresh it. `onChange` fires *before* the mutation lands,
    /// so the redraw is deferred by a hop.
    private func track() {
        withObservationTracking {
            _ = state.isVisible
            _ = state.isAlwaysVisible
            _ = state.isCollapsed
            _ = state.isFloating
            _ = state.isClickThrough
            _ = state.unseenMessages
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }

    // MARK: - Click routing

    /// Left click reads; right or control click commands.
    ///
    /// Two gestures rather than one because they are different intents at
    /// different frequencies: looking at what the agent found happens many
    /// times a day, changing how the overlay behaves happens rarely. Putting
    /// the frequent one behind a menu would cost a click every time.
    @objc private func handleClick() {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if wantsMenu || popover == nil {
            presentMenu()
        } else {
            popover?.toggle(relativeTo: button)
        }
    }

    /// Shows the command menu from a status item that has no permanent menu.
    ///
    /// Assigning `menu` and re-clicking is the supported way to do this: it
    /// gives the menu the item's highlight and dismissal behaviour, which
    /// `popUpMenu(_:)` does not. It is cleared straight after so the next left
    /// click reaches `handleClick` again.
    private func presentMenu() {
        guard let statusItem else { return }
        popover?.close()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - NSMenuDelegate

    /// Rebuilt on every open rather than mutated, so the check marks can never
    /// drift out of step with the panel.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Health first. A subsystem that is down changes what every command
        // below it will actually do, so burying it under the window controls
        // would be the wrong order.
        if let problem = state.problems.first {
            let (id, componentState) = problem
            let extra = state.problems.count - 1
            let detail = "⚠ \(id.displayName): \(componentState.localizedDisplayText)"
            let summary = NSMenuItem(
                title: extra > 0
                    ? detail + localized(" (+\(extra) more)", "（他 \(extra) 件）", "(외 \(extra)건)")
                    : detail,
                action: #selector(openSettings), keyEquivalent: "")
            summary.target = self
            summary.toolTip = localized("Open Settings to fix", "設定を開いて対処する", "설정을 열어 해결하기")
            menu.addItem(summary)
            menu.addItem(.separator())
        }

        // The one switch that decides whether anything sits on top of the
        // user's work. Everything below it only matters once it is on, so those
        // items are disabled rather than silently doing nothing.
        let alwaysVisible = item(
            title: localized("Show the Panel on the Desktop", "デスクトップにパネルを表示",
                "데스크탑에 패널 표시"),
            action: #selector(toggleVisibility),
            hotKey: .toggleVisibility)
        alwaysVisible.state = state.isAlwaysVisible ? .on : .off
        alwaysVisible.toolTip = localized(
            "Off, the same panel opens from here for as long as you keep it open",
            "オフのときは、✨ をクリックしているあいだだけ同じパネルがここから開きます",
            "끄면 ✨ 를 클릭하는 동안에만 같은 패널이 여기서 열립니다")
        menu.addItem(alwaysVisible)

        menu.addItem(item(
            title: state.isCollapsed
                ? localized("Restore the Panel", "元の大きさに戻す", "패널을 원래 크기로")
                : localized("Collapse to a Bar", "細いバーにたたむ", "얇은 바로 접기"),
            action: #selector(toggleCollapsed),
            hotKey: .toggleCollapse,
            enabled: state.isAlwaysVisible))

        let floating = item(
            title: localized("Keep in Front of Other Windows", "常に最前面に表示", "항상 맨 앞에 표시"),
            action: #selector(toggleFloating),
            enabled: state.isAlwaysVisible)
        floating.state = state.isFloating ? .on : .off
        floating.toolTip = localized(
            "Off, the panel behaves like an ordinary window and other windows cover it",
            "オフにすると普通のウインドウと同じで、他のウインドウの後ろに隠れます",
            "끄면 일반 윈도우와 같아져서 다른 윈도우에 가려집니다")
        menu.addItem(floating)

        let clickThrough = item(
            title: localized("Let Clicks Pass Through", "クリックを背面に通す", "클릭을 뒤로 통과시키기"),
            action: #selector(toggleClickThrough),
            hotKey: .toggleClickThrough,
            enabled: state.isAlwaysVisible)
        clickThrough.state = state.isClickThrough ? .on : .off
        clickThrough.toolTip = localized(
            "When on, every click on the panel — buttons included — goes to the app behind instead",
            "オンのとき、パネルへのクリックはボタンも含めてすべて背面のアプリに届きます",
            "켜면 패널 클릭이 버튼까지 포함해 모두 뒤쪽 앱으로 전달됩니다")
        menu.addItem(clickThrough)

        let position = NSMenuItem(
            title: localized("Position", "表示位置", "표시 위치"), action: nil, keyEquivalent: "")
        position.isEnabled = state.isAlwaysVisible
        let submenu = NSMenu()
        for corner in HUDCorner.allCases {
            let entry = item(
                title: corner.title,
                action: #selector(chooseCorner(_:)),
                enabled: state.isAlwaysVisible)
            entry.representedObject = corner.rawValue
            entry.state = state.corner == corner ? .on : .off
            submenu.addItem(entry)
        }
        position.submenu = submenu
        menu.addItem(position)

        menu.addItem(.separator())

        let chat = item(
            title: localized("Open the Chat…", "チャットを開く…", "채팅 열기…"),
            action: #selector(ask),
            hotKey: .ask)
        chat.toolTip = localized(
            "Everything the agent says lands here, including what it notices on its own",
            "エージェントの発言は、自分で気づいたことも含めてすべてここに届きます",
            "에이전트가 하는 말은 스스로 알아챈 것까지 모두 여기로 옵니다")
        menu.addItem(chat)

        let snip = item(
            title: localized("Snip Screen & Explain…", "範囲を選択して説明…", "화면 영역 선택하여 설명…"),
            action: #selector(snipScreenAction))
        snip.toolTip = localized(
            "Drag to select a part of your screen and ask the agent to explain it",
            "画面の一部をドラッグして選択し、エージェントに説明させます",
            "화면 일부를 드래그하여 선택하고 에이전트에게 설명을 요청합니다")
        menu.addItem(snip)

        let clearChat = item(
            title: localized("Clear Chat…", "チャットを消去…", "채팅 지우기…"),
            action: #selector(clearChatAction),
            enabled: !state.messages.isEmpty || state.isStreaming)
        clearChat.toolTip = localized(
            "Clear all messages and start a new conversation",
            "すべてのメッセージを消去して新しい会話を始めます",
            "모든 메시지를 삭제하고 새 대화를 시작합니다")
        menu.addItem(clearChat)

        // Next to the chat rather than with the window controls above: this is
        // about what the agent looks at, not about where its panel sits. The
        // subject goes in the title because the menu is also where someone
        // checks it — "is it still watching that build" is asked far more often
        // than it is changed.
        let activeMultiCount = state.watchItems.filter(\.isEnabled).count
        let screenTitle: String = {
            if !state.watchItems.isEmpty {
                if state.watchPhase != .off && activeMultiCount > 0 {
                    return localized(
                        "Watching \(activeMultiCount) screens…",
                        "\(activeMultiCount) 画面を見守り中…",
                        "\(activeMultiCount)개 화면 지켜보는 중…")
                } else if activeMultiCount == 0 {
                    return localized(
                        "All screens disabled",
                        "すべての画面が無効化中",
                        "모든 화면 비활성화됨")
                } else {
                    return localized(
                        "\(activeMultiCount) screens selected",
                        "\(activeMultiCount) 画面を選択中",
                        "\(activeMultiCount)개 화면 선택됨")
                }
            } else if state.watchPhase != .off, let subject = state.watchTarget.subjectName {
                return localized("Watching: \(subject)…", "見守り中: \(subject)…", "지켜보는 중: \(subject)…")
            } else if let subject = state.watchTarget.subjectName {
                return localized("Target: \(subject)", "対象: \(subject)", "대상: \(subject)")
            } else {
                return localized(
                    "Choose a Screen to Watch…", "見守る画面を選ぶ…", "지켜볼 화면 고르기…")
            }
        }()
        let screen = item(
            title: screenTitle,
            action: #selector(chooseScreen))
        screen.toolTip = localized(
            "Pick the window or display the agent looks at, from a preview of each",
            "エージェントに見せるウインドウやディスプレイを、プレビューを見ながら選びます",
            "에이전트에게 보여줄 윈도우나 디스플레이를 미리보기를 보며 고릅니다")
        menu.addItem(screen)

        // One item per mode, rather than a start/stop command in front of a
        // "Voice Mode" submenu that decided what it meant. Two commands are what
        // the two modes are: they differ in what leaves this Mac, and choosing
        // between them was never a setting so much as a choice of what to do
        // right now.
        for mode in VoiceMode.allCases {
            let isCurrent = state.voiceMode == mode && state.voicePhase != .off
            let title = switch (isCurrent, state.voicePhase) {
            case (true, .connecting): localized("Connecting…", "接続中…", "연결 중…")
            case (true, _): mode.stopCommandTitle
            case (false, _): mode.startCommandTitle
            }
            // The chord goes on the one item it would actually trigger. ⌃⌥V
            // repeats the mode last used, and advertising it on both would make
            // one of the two a lie.
            let entry = item(
                title: title,
                action: #selector(startVoice(_:)),
                hotKey: state.voiceMode == mode ? .toggleVoice : nil)
            entry.representedObject = mode.rawValue
            entry.state = isCurrent ? .on : .off
            entry.toolTip = mode.detail
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(item(
            title: localized("Settings…", "設定…", "설정…"),
            action: #selector(openSettings),
            literalKey: ","))
        menu.addItem(item(
            title: localized("Permissions…", "アクセス権限…", "접근 권한…"),
            action: #selector(openPermissions)))

        menu.addItem(.separator())
        menu.addItem(item(
            title: localized("Quit Copilot", "Copilot を終了", "Copilot 종료"),
            action: #selector(quit),
            literalKey: "q"))
    }

    // MARK: - Actions

    @objc private func toggleVisibility() { onToggleVisibility?() }
    @objc private func toggleCollapsed() { onToggleCollapsed?() }
    @objc private func toggleClickThrough() { onToggleClickThrough?() }
    @objc private func toggleFloating() { onToggleFloating?() }
    @objc private func ask() { onAsk?() }
    @objc func clearChatAction() {
        guard !state.messages.isEmpty || state.isStreaming else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localized("Start a new conversation?", "新しい会話しますか？", "새 대화를 시작할까요?")
        alert.informativeText = localized(
            "All messages will be deleted. This cannot be undone.",
            "すべてのメッセージが消去されます。元には戻せません。",
            "모든 메시지가 삭제됩니다. 되돌릴 수 없습니다.")
        alert.addButton(withTitle: localized("Yes", "はい", "예"))
        alert.addButton(withTitle: localized("No", "いいえ", "아니요"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            if let onClearChat {
                onClearChat()
            } else {
                state.clearChat()
            }
        }
    }
    @objc private func snipScreenAction() { onSnipScreen?() }
    @objc private func chooseScreen() { onChooseScreen?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func startVoice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = VoiceMode(rawValue: raw)
        else { return }
        onVoice?(mode)
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = HUDCorner(rawValue: raw)
        else { return }
        onChooseCorner?(corner)
    }

    /// Builds an item whose key equivalent mirrors the *live* binding for
    /// `hotKey`, rather than a hard-coded chord that a rebinding would make a
    /// lie. An unassigned or unrepresentable chord simply shows no shortcut.
    private func item(
        title: String,
        action: Selector,
        hotKey: HotKeyAction? = nil,
        literalKey: String? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled

        if let literalKey {
            entry.keyEquivalent = literalKey
            entry.keyEquivalentModifierMask = [.command]
        } else if let hotKey, let chord = hotKeys?.chord(for: hotKey),
                  let equivalent = chord.menuKeyEquivalent,
                  hotKeys?.problems[hotKey]?.isFault != true {
            entry.keyEquivalent = equivalent
            entry.keyEquivalentModifierMask = chord.menuModifierMask
        }
        return entry
    }
}
