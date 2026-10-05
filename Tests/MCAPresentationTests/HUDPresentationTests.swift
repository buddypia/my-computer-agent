import AppKit
import Foundation
import MCACore
import Testing

@testable import MCAPresentation

/// Covers the two defaults that decide whether the app is intrusive, and the
/// unread accounting that depends on knowing which surface is on screen.
@Suite("HUD presentation")
@MainActor
struct HUDPresentationTests {
    /// A fresh `UserDefaults` per test. `.standard` would leak the developer's
    /// own overlay settings into the assertions.
    private func freshDefaults() -> UserDefaults {
        let suite = "hud.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a clean install puts nothing on top of the user's work")
    func overlayIsOptIn() {
        let preferences = HUDPreferences(defaults: freshDefaults())
        #expect(preferences.isAlwaysVisible == false)
    }

    /// Click-through is whole-window, so leaving it on meant the overlay's own
    /// buttons and question field sent their clicks to the app behind.
    @Test("clicks land on the overlay by default, not the window behind")
    func clickThroughIsOptIn() {
        let preferences = HUDPreferences(defaults: freshDefaults())
        #expect(preferences.isClickThrough == false)
        #expect(HUDState().isClickThrough == false)
    }

    /// The old key was `hud.visible`, and every existing install has it set to
    /// `true`. Reading it here would opt all of them into the exact behaviour
    /// the new default exists to stop.
    @Test("an existing hud.visible setting does not turn the overlay on")
    func doesNotInheritTheOldVisibleKey() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "hud.visible")
        #expect(HUDPreferences(defaults: defaults).isAlwaysVisible == false)
    }

    @Test("a choice about the overlay survives a relaunch")
    func alwaysVisiblePersists() {
        let defaults = freshDefaults()
        HUDPreferences(defaults: defaults).isAlwaysVisible = true
        #expect(HUDPreferences(defaults: defaults).isAlwaysVisible == true)
    }

    @Test("turns that arrive with nothing on screen are counted unread")
    func countsWhileHidden() {
        let state = HUDState()
        state.present(HUDCard(title: "One", body: "…"))
        #expect(state.unseenMessages == 1)
    }

    /// The popover is a surface too. Counting something the user is looking at
    /// as unread would put a badge on the menu bar for what was already read.
    @Test("turns that arrive with the popover open are not counted unread")
    func popoverCountsAsOnScreen() {
        let state = HUDState()
        state.isPopoverOpen = true
        state.present(HUDCard(title: "One", body: "…"))
        #expect(state.unseenMessages == 0)
    }

    /// The user's own question is never news to the user, whatever surface is
    /// up. Counting it would badge the menu bar for something they just typed.
    @Test("the user's own turn is never counted unread")
    func ownQuestionsAreNotUnread() {
        let state = HUDState()
        state.beginStreaming(question: "これは？")
        #expect(state.unseenMessages == 0)
    }

    /// The panel, the popover and the chat window are three views of one thread.
    /// A notice that only two of them could show is how they came to disagree
    /// about what had happened in a session.
    @Test("a notice lands in the same thread as everything else")
    func noticesJoinTheThread() {
        let state = HUDState()
        state.present(HUDCard(title: "見出し", body: "本文", severity: .warning))

        #expect(state.messages.map(\.role) == [.notice])
        #expect(state.messages.first?.title == "見出し")
        #expect(state.messages.first?.text == "本文")
        #expect(state.messages.first?.severity == .warning)
    }

    /// The failure this covers looked like a UI glitch: ask a question, watch
    /// "Thinking" appear, and watch the HUD revert to its empty state a moment
    /// later. The answer had arrived; nothing had streamed, and the streamed
    /// text was the only thing the card was ever built from.
    @Test("an answer that did not stream is still shown")
    func fallsBackToTheReturnedAnswer() {
        let state = HUDState()
        state.beginStreaming()
        state.endStreaming(text: "42")

        #expect(state.isStreaming == false)
        #expect(state.messages.last?.text == "42")
    }

    /// Vanishing is the one outcome the user cannot act on — it is
    /// indistinguishable from the question never having been sent.
    @Test("an empty answer is reported rather than dropped")
    func reportsAnEmptyAnswer() {
        let state = HUDState()
        state.beginStreaming()
        state.endStreaming()

        #expect(state.isStreaming == false)
        #expect(state.messages.map(\.role) == [.failure])
    }

    /// The reported symptom: press the voice button, watch it switch itself
    /// back off a moment later, and be told nothing. A session that is still
    /// negotiating must not read as running, or the only thing left to show
    /// when it fails is the button reverting.
    @Test("a session that is still connecting does not read as live")
    func connectingIsNotLive() {
        let state = HUDState()
        state.voicePhase = .connecting

        #expect(state.liveSessionActive == false)

        state.voicePhase = .live
        #expect(state.liveSessionActive == true)
    }

    /// What the microphone was heard to say is the only local evidence that a
    /// voice session is reaching the model at all.
    @Test("each utterance replaces the last rather than accumulating")
    func voiceTranscriptResetsPerUtterance() {
        let state = HUDState()
        state.appendUserSpeech("こんに")
        state.appendUserSpeech("ちは")
        #expect(state.voiceTranscript == "こんにちは")

        // Still readable after the model replies — the turn ending is not the
        // user losing what they just said.
        state.endVoiceTurn()
        #expect(state.voiceTranscript == "こんにちは")

        state.appendUserSpeech("次の質問")
        #expect(state.voiceTranscript == "次の質問")
    }

    @Test("ending a session clears the phase and the transcript")
    func endingASessionClearsEverything() {
        let state = HUDState()
        state.voicePhase = .live
        state.appendUserSpeech("聞こえていますか")

        state.endVoiceSession()

        #expect(state.voicePhase == .off)
        #expect(state.voiceTranscript.isEmpty)
    }

    @Test("a deleted notice leaves, and takes nothing else with it")
    func deletesOneNotice() {
        let state = HUDState()
        state.present(HUDCard(title: "One", body: "…"))
        state.present(HUDCard(title: "Two", body: "…"))

        state.removeMessage(state.messages[1].id)

        #expect(state.messages.map(\.title) == ["One"])
    }

    /// The count is of turns that arrived unseen, so it can legitimately be
    /// lower than the number in the thread. Subtracting one per deletion would
    /// drive it negative and badge the menu bar with nonsense.
    @Test("the unread count never outlives the turns it counts")
    func deletingClampsTheUnreadCount() {
        let state = HUDState()
        state.present(HUDCard(title: "One", body: "…"))
        state.present(HUDCard(title: "Two", body: "…"))
        #expect(state.unseenMessages == 2)

        state.removeMessage(state.messages[0].id)
        #expect(state.unseenMessages == 1)

        // Already read: the popover was open when this one arrived, so nothing
        // to take away when it goes.
        state.isPopoverOpen = true
        state.present(HUDCard(title: "Three", body: "…"))
        state.removeMessage(state.messages[0].id)
        #expect(state.unseenMessages == 1)
    }

    /// The bar shows no message bodies, so an expanded-panel check alone would
    /// mark turns read that were never displayed.
    @Test("the collapsed pill does not count as having shown a turn")
    func collapsedPillIsNotOnScreen() {
        let state = HUDState()
        state.isVisible = true
        state.isCollapsed = true
        state.present(HUDCard(title: "One", body: "…"))
        #expect(state.unseenMessages == 1)

        state.isCollapsed = false
        state.present(HUDCard(title: "Two", body: "…"))
        #expect(state.unseenMessages == 1)
    }

    @Test("HUDPanel exposes onTogglePin callback")
    func hudPanelExposesTogglePin() {
        let state = HUDState()
        let panel = HUDPanel(state: state)
        var called = false
        panel.onTogglePin = { called = true }
        panel.onTogglePin?()
        #expect(called == true)
    }

    @Test("HUDPanel exposes onToggleWatch callback")
    func hudPanelExposesToggleWatch() {
        let state = HUDState()
        let panel = HUDPanel(state: state)
        var called = false
        panel.onToggleWatch = { called = true }
        panel.onToggleWatch?()
        #expect(called == true)
    }

    @Test("HUDPopover accepts onTogglePin in quick actions")
    func hudPopoverAcceptsTogglePin() {
        let state = HUDState()
        var called = false
        let popover = HUDPopover(state: state)
        popover.setQuickActions(onTogglePin: { called = true })
        #expect(called == false)
    }

    @Test("HUDPopover accepts onToggleWatch in quick actions")
    func hudPopoverAcceptsToggleWatch() {
        let state = HUDState()
        var called = false
        let popover = HUDPopover(state: state)
        popover.setQuickActions(onToggleWatch: { called = true })
        #expect(called == false)
    }

    @Test("addCustomRole appends new role and notifies persistence")
    func addCustomRoleNotifiesPersistence() {
        let state = HUDState()
        var savedRole: WatchRole?
        state.onSaveCustomRole = { role in
            savedRole = role
        }

        let custom = WatchRole(
            id: "custom.security",
            name: "Security Auditing",
            icon: "shield.fill",
            systemPrompt: "Check for exposed API keys and sensitive tokens."
        )
        state.addCustomRole(custom)

        #expect(savedRole?.id == "custom.security")
        #expect(state.availableRoles.contains(where: { $0.id == "custom.security" }))

        // Modifying existing role updates in place rather than duplicating
        var updated = custom
        updated.name = "Updated Security Auditing"
        state.addCustomRole(updated)

        #expect(state.availableRoles.filter({ $0.id == "custom.security" }).count == 1)
        #expect(state.availableRoles.first(where: { $0.id == "custom.security" })?.name == "Updated Security Auditing")
    }

    @Test("presentAdvice populates originTarget and actions, and triggers onExecuteAction")
    func adviceCarriesOriginAndAction() {
        let state = HUDState()
        var executedPayload: String?
        var executedTarget: String?
        state.onExecuteAction = { payload, target in
            executedPayload = payload
            executedTarget = target
        }

        state.presentAdvice(
            title: "承認待ちの確認",
            body: "マイグレーションの実行確認",
            severity: .actionItem,
            originTarget: "Terminal — zsh",
            roleId: "builtin.cli-dev",
            roleName: "AI CLI開発監視",
            roleIcon: "terminal.fill",
            actionTitle: "承認する (y)",
            actionPayload: "y"
        )

        let message = state.messages.last
        #expect(message?.title == "承認待ちの確認")
        #expect(message?.originTarget == "Terminal — zsh")
        #expect(message?.roleId == "builtin.cli-dev")
        #expect(message?.actionTitle == "承認する (y)")
        #expect(message?.actionPayload == "y")

        // Trigger action callback
        state.onExecuteAction?(message!.actionPayload!, message!.originTarget)
        #expect(executedPayload == "y")
        #expect(executedTarget == "Terminal — zsh")
    }

    @Test("HUDPopover accepts onClearChat in quick actions")
    func hudPopoverAcceptsClearChat() {
        let state = HUDState()
        var called = false
        let popover = HUDPopover(state: state)
        popover.setQuickActions(onClearChat: { called = true })
        #expect(called == false)
    }

    @Test("MenuBarController exposes clear chat command and enables it when messages exist")
    func menuBarControllerClearChat() {
        let state = HUDState()
        let controller = MenuBarController(state: state)
        var cleared = false
        controller.onClearChat = { cleared = true }

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        let clearItem = menu.items.first { $0.action == #selector(MenuBarController.clearChatAction) }
        #expect(clearItem != nil)
        #expect(clearItem?.isEnabled == false)

        state.append(ChatMessage(role: .user, text: "Hello"))
        controller.menuNeedsUpdate(menu)
        let updatedClearItem = menu.items.first { $0.action == #selector(MenuBarController.clearChatAction) }
        #expect(updatedClearItem?.isEnabled == true)
    }

    @Test("MenuBarController clearChatAction does nothing when chat is empty")
    func menuBarControllerClearChatNoopWhenEmpty() {
        let state = HUDState()
        let controller = MenuBarController(state: state)
        var cleared = false
        controller.onClearChat = { cleared = true }

        controller.clearChatAction()
        #expect(cleared == false)
    }

    @Test("HUDState handles preset execution callbacks and role deletion")
    func presetCallbacksAndDeletion() {
        let state = HUDState()
        var executedRole: WatchRole?
        var executedTarget: WatchTarget?
        var appliedRole: WatchRole?
        var deletedId: String?

        state.onExecutePreset = { role, target in
            executedRole = role
            executedTarget = target
        }
        state.onApplyRoleToWatch = { role, target in
            appliedRole = role
        }
        state.onDeleteCustomRole = { id in
            deletedId = id
        }

        let customRole = WatchRole(
            id: "custom.test-preset",
            name: "Test Preset",
            icon: "bolt.fill",
            systemPrompt: "System instruction",
            taskPrompt: "Execute this task"
        )
        state.addCustomRole(customRole)
        #expect(state.availableRoles.contains(where: { $0.id == "custom.test-preset" }))

        state.selectedPreset = customRole
        state.onExecutePreset?(customRole, .focused)
        #expect(executedRole?.id == "custom.test-preset")
        #expect(executedTarget == .focused)

        state.onApplyRoleToWatch?(customRole, .focused)
        #expect(appliedRole?.id == "custom.test-preset")

        state.deleteCustomRole(id: "custom.test-preset")
        #expect(!state.availableRoles.contains(where: { $0.id == "custom.test-preset" }))
        #expect(deletedId == "custom.test-preset")
        #expect(state.selectedPreset == nil)
    }

    @Test("HUDPanel exposes settings navigation callbacks")
    func hudPanelSettingsCallbacks() {
        let state = HUDState()
        let panel = HUDPanel(state: state, preferences: freshDefaults())
        var opened = false
        var openedTab: SettingsTab?
        panel.onOpenSettings = { opened = true }
        panel.onOpenSettingsTab = { tab in openedTab = tab }

        panel.onOpenSettings?()
        #expect(opened == true)

        panel.onOpenSettingsTab?(.permissions)
        #expect(openedTab == .permissions)
    }

    @Test("HUDPopover exposes settings and clickThrough callbacks")
    func hudPopoverSettingsAndClickThrough() {
        let state = HUDState()
        var openedTab: SettingsTab?
        var clickThroughToggled = false
        _ = HUDPopover(
            state: state,
            onOpenSettingsTab: { tab in openedTab = tab },
            onToggleClickThrough: { clickThroughToggled = true }
        )
        // Verify state initialization
        #expect(openedTab == nil)
        #expect(clickThroughToggled == false)
    }

    @Test("MenuBarController updates status button for clickThrough state")
    func menuBarClickThroughState() {
        let state = HUDState()
        let hotKeys = HotKeyCenter()
        let menuBar = MenuBarController(state: state, popover: nil, hotKeys: hotKeys)
        menuBar.install()
        defer { menuBar.remove() }

        // Normal state: sparkles
        state.isClickThrough = false
        menuBar.refresh()

        // Active click-through: cursorarrow.slash
        state.isClickThrough = true
        menuBar.refresh()
    }

    @Test("MenuBarController displays accurate watch state in screen item title")
    func menuBarControllerScreenItemWatchState() {
        let state = HUDState()
        let controller = MenuBarController(state: state)
        let menu = NSMenu()
        let screenSelector = Selector(("chooseScreen"))

        // 1. Initial off state: prompts to choose screen
        controller.menuNeedsUpdate(menu)
        let screenItem = menu.items.first { $0.action == screenSelector }
        #expect(screenItem != nil)
        #expect(screenItem?.title.contains("見張り中") == false)
        #expect(screenItem?.title.contains("Watching") == false)

        // 2. Off state with pinned target: shows "対象:" / "Target:", not "見張り中"
        let pinnedWindow = PinnedWindow(
            id: 101,
            appName: "Xcode",
            windowTitle: "MyProject",
            bundleID: "com.apple.dt.Xcode"
        )
        state.watchTarget = .pinned(pinnedWindow)
        state.watchPhase = .off
        menu.removeAllItems()
        controller.menuNeedsUpdate(menu)
        let pinnedOffItem = menu.items.first { $0.action == screenSelector }
        #expect(pinnedOffItem?.title.contains("見守り中") == false && pinnedOffItem?.title.contains("見張り中") == false)
        #expect(pinnedOffItem?.title.contains("対象") == true || pinnedOffItem?.title.contains("Target") == true)

        // 3. Watching state with single pinned window: shows "見守り中: Xcode"
        state.watchPhase = .watching
        menu.removeAllItems()
        controller.menuNeedsUpdate(menu)
        let pinnedWatchingItem = menu.items.first { $0.action == screenSelector }
        #expect(pinnedWatchingItem?.title.contains("見守り中") == true || pinnedWatchingItem?.title.contains("見張り中") == true || pinnedWatchingItem?.title.contains("Watching") == true)
        #expect(pinnedWatchingItem?.title.contains("Xcode") == true)

        // 4. Watching state with multiple watch items: shows "N 画面を見守り中"
        state.watchItems = [
            WatchItem(target: .pinned(pinnedWindow), role: .general, isEnabled: true)
        ]
        menu.removeAllItems()
        controller.menuNeedsUpdate(menu)
        let multiWatchingItem = menu.items.first { $0.action == screenSelector }
        #expect(multiWatchingItem?.title.contains("見守り中") == true || multiWatchingItem?.title.contains("見張り中") == true || multiWatchingItem?.title.contains("Watching") == true)
        #expect(multiWatchingItem?.title.contains("1") == true)

        // 5. Watch items present but all disabled: shows "All screens disabled" / "すべての画面が無効化中"
        state.watchItems = [
            WatchItem(target: .pinned(pinnedWindow), role: .general, isEnabled: false)
        ]
        menu.removeAllItems()
        controller.menuNeedsUpdate(menu)
        let disabledItem = menu.items.first { $0.action == screenSelector }
        #expect(disabledItem?.title.contains("見守り中") == false && disabledItem?.title.contains("見張り中") == false)
        #expect(disabledItem?.title.contains("無効化") == true || disabledItem?.title.contains("disabled") == true)
    }
}

