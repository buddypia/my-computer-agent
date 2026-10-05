import AppKit
import CoreGraphics
import Foundation
import MCACore
import MCAInterop
import MCAMemory
import MCAPerception
import MCAPresentation
import MCAReasoning
import MCASensing
import OSLog

/// One look at the screen: what was readable, and a picture of it.
struct ScreenLook: Sendable {
    var appName: String
    var windowTitle: String
    var text: String
    /// `nil` when Screen Recording is not granted, or the capture failed. The
    /// watch keeps running on the text alone rather than switching itself off —
    /// a degraded look is worth more than none.
    var image: ImageAttachment?
    /// Identity of what is on screen. Two looks with the same fingerprint are
    /// the same screen, and the second one is not worth paying for.
    var fingerprint: String
    /// Whether the frontmost window belongs to this app.
    var isOwnWindow: Bool
    /// Whether the privacy gate excluded it.
    var isExcluded: Bool
    /// What the user pinned, named — or `nil` when this came from whatever
    /// happens to be in front.
    ///
    /// Used to label the context. The model is told which of the two it is
    /// looking at, because "the window you are working in" and "the thing you
    /// asked me to keep an eye on" invite different advice: the second is
    /// usually not where the user's attention is, so telling them what they can
    /// plainly see is worth nothing and telling them a build failed is worth a
    /// lot.
    var pinnedSubject: String?
}

/// Watches the screen on a timer and speaks only when it has something to say.
///
/// This is the "explain my screen" button turned into a standing arrangement,
/// and the difference between the two is entirely about restraint. A button is
/// pressed when the user wants an answer; a timer fires whether they want one or
/// not, so everything here is built to *not* spend a request:
///
/// 1. The frontmost window is read through the accessibility tree — free.
/// 2. `ScreenWatchPolicy` drops the tick if the screen has not changed, if our
///    own window is in front, if the app is privacy-excluded, or if an answer
///    the user asked for is still streaming.
/// 3. Only what survives that is photographed and sent, and the prompt's first
///    instruction is to reply `PASS` and say nothing.
///
/// Living in the composition root is deliberate: it is the one place allowed to
/// know about sensing, perception, memory, reasoning and presentation at once.
@MainActor
final class ScreenWatcher {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "ScreenWatch")
    private let privacyFilter = PrivacyFilter()

    private let state: HUDState
    private let store: any ContextStoring
    /// Rebuilt, not fixed: adding an API key in Settings replaces both of these,
    /// and a watch left holding the old pair would keep reporting that no model
    /// is reachable long after one is.
    private var agent: Agent
    private var router: ModelRouter
    private let capturer: ScreenCapturer
    private let recognizer: TextRecognizer
    private let reader: AccessibilityReader
    private let configuration: AgentConfiguration
    private let preferences: WatchPreferences

    private var policy = ScreenWatchPolicy()
    /// What the watch is looking at. Never persisted, for the same reason the
    /// on/off switch is not: a pin is a decision about one window in one
    /// session, and a window number does not survive the app that owned it
    /// quitting anyway.
    private var target: WatchTarget = .focused
    /// Active multi-target items being watched in parallel with assigned roles.
    private var watchItems: [WatchItem] = []
    private var loop: Task<Void, Never>?
    private var requestedActionTask: Task<Void, Never>?

    func cancelRequestedAction() {
        requestedActionTask?.cancel()
        requestedActionTask = nil
    }
    var onRequestedAction: (@MainActor (String, WatchTarget) -> Void)?
    var onObjectiveObservation: (@MainActor (ScreenLook, PinnedWindow) -> Void)?

    func startObjective() {
        policy.reset()
        setEnabled(true)
    }

    /// Headlines already given, newest last. Fed back into the prompt: without
    /// them a model looking at a screen it has commented on before says the same
    /// thing again in different words, which is how a watch becomes noise.
    private var recentAdvice: [String] = []
    private var canCaptureScreen = false
    /// The last application that was frontmost and was not us.
    ///
    /// Needed because of where "pin this window" is pressed from. The shortcut
    /// is pressed over the user's own work and the frontmost window is the right
    /// answer — but the button in the chat toolbar is *in* this app, so by the
    /// time it is clicked the frontmost window is ours, and pinning it would
    /// point the watch at its own advice. Every press of that button would be
    /// refused. What the user means in both cases is the window they were in
    /// last, so that is what gets remembered.
    private var lastForeignApp: NSRunningApplication?

    /// Notified when meeting session state (active role is meeting) changes, passing whether active and the target process ID if pinned.
    var onMeetingSessionChanged: ((Bool, pid_t?) -> Void)?
    private var lastReportedMeetingActive = false

    /// Whether a meeting assistant session is currently active in either single-target or multi-screen mode.
    var isMeetingSessionActive: Bool {
        guard state.watchPhase != .off else { return false }
        if !watchItems.isEmpty {
            return watchItems.contains { $0.isEnabled && ($0.role.id == "builtin.meeting" || $0.role.triggerKind == .meetingFast) }
        } else {
            return state.selectedPreset?.id == "builtin.meeting" || state.selectedPreset?.triggerKind == .meetingFast
        }
    }

    /// The target process ID if a window is pinned for the active meeting session.
    var activeMeetingPID: pid_t? {
        if case .pinned(let window) = target {
            if state.selectedPreset?.id == "builtin.meeting" || state.selectedPreset?.triggerKind == .meetingFast {
                return window.processID
            }
        }
        return nil
    }

    /// Evaluates meeting session status and triggers `onMeetingSessionChanged` on state transitions.
    func updateMeetingSessionState() {
        let active = isMeetingSessionActive
        let pid = active ? activeMeetingPID : nil
        if active != lastReportedMeetingActive {
            lastReportedMeetingActive = active
            onMeetingSessionChanged?(active, pid)
        }
    }

    /// Called when participant speech ends; triggers an immediate meeting assistant evaluation without waiting for the polling timer.
    func notifySpeechEnded(channel: AudioChannel) async {
        guard state.watchPhase != .off, isMeetingSessionActive else { return }
        log.info("Speech ended on \(channel.rawValue); triggering immediate meeting assistant look")
        await tick()
    }

    init(
        state: HUDState,
        agent: Agent,
        store: any ContextStoring,
        router: ModelRouter,
        capturer: ScreenCapturer,
        recognizer: TextRecognizer,
        reader: AccessibilityReader,
        configuration: AgentConfiguration,
        defaults: UserDefaults = .standard
    ) {
        self.state = state
        self.agent = agent
        self.store = store
        self.router = router
        self.capturer = capturer
        self.recognizer = recognizer
        self.reader = reader
        self.configuration = configuration
        self.preferences = WatchPreferences(defaults: defaults)

        let interval = preferences.interval
        state.watchInterval = interval
        policy.interval = interval.seconds

        state.onExecuteAction = { [weak self] payload, target in
            self?.executeAction(payload, target: target)
        }

        let savedCustomRoles = preferences.customRoles
        state.availableRoles = WatchRole.allBuiltins + savedCustomRoles

        state.onSaveCustomRole = { [weak self] role in
            guard let self else { return }
            var currentCustom = self.preferences.customRoles
            if let idx = currentCustom.firstIndex(where: { $0.id == role.id }) {
                currentCustom[idx] = role
            } else {
                currentCustom.append(role)
            }
            self.preferences.customRoles = currentCustom
        }

        state.onDeleteCustomRole = { [weak self] id in
            guard let self else { return }
            var currentCustom = self.preferences.customRoles
            currentCustom.removeAll { $0.id == id }
            self.preferences.customRoles = currentCustom
        }

        trackForegroundApplication()
    }

    /// Remembers which application the user was in before they came here.
    ///
    /// No matching teardown: this object lives for as long as the app does, and
    /// the closure holds `self` weakly, so there is nothing to release and
    /// nothing to crash if there were.
    private func trackForegroundApplication() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                app.processIdentifier != ownPID
            else { return }
            Task { @MainActor in self?.lastForeignApp = app }
        }
    }

    /// Swaps in the rebuilt agent and router after a credential change.
    func reasoningChanged(agent: Agent, router: ModelRouter) {
        self.agent = agent
        self.router = router
    }

    // MARK: - Switches

    func toggle() {
        setEnabled(state.watchPhase == .off)
    }

    /// Turns the watch on or off.
    ///
    /// Never persisted, unlike the interval. A setting that survives a relaunch
    /// means an app that starts photographing the screen and sending it to a
    /// cloud model on login, because of a switch flicked once last week. Being
    /// asked for again is the cheaper mistake.
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            stop(status: localized(
                "Not watching.", "画面は見ていません。",
                "화면을 보고 있지 않습니다."))
            return
        }
        guard state.watchPhase == .off else { return }

        // Both routes, because a look without Screen Recording permission falls
        // back to the text path and its cheaper model. Refusing to start is only
        // correct when neither can run.
        if let visionReason = router.blockedReason(for: .vision),
           let textReason = router.blockedReason(for: .classify) {
            state.presentFailure(localized("""
                The screen watch needs a model it can reach — \(visionReason); \(textReason).

                Open **✨ ▸ Settings ▸ Models & Keys** and add an API key.
                """, """
                画面を見るにはモデルが必要ですが、到達できません（\(visionReason); \(textReason)）。

                **✨ ▸ 設定 ▸ モデルとキー** で API キーを追加してください。
                """,
                """
                화면을 보려면 모델이 필요한데 연결할 수 없습니다(\(visionReason); \(textReason)).
                
                **✨ ▸ 설정 ▸ 모델과 키** 에서 API 키를 추가하세요.
                """))
            return
        }

        policy.reset()
        recentAdvice.removeAll()
        state.watchPhase = .watching
        state.watchStatus = watchingStatus
        updateMeetingSessionState()

        loop = Task { [weak self] in
            guard let self else { return }
            self.canCaptureScreen = await ScreenCapturer.hasPermission()
            // Only the focused-window path can carry on without it, by falling
            // back to the accessibility tree. A pinned window has no such tree
            // to read, so `tickPinned` stops instead of limping.
            if !self.canCaptureScreen, !self.target.isPinned {
                self.state.watchStatus = localized(
                    "Watching, but without Screen Recording permission it can only read text.",
                    "見ていますが、画面収録の許可がないため文字しか読めません。",
                    "보고는 있지만 화면 기록 권한이 없어 글자만 읽을 수 있습니다.")
            }
            while !Task.isCancelled {
                await self.tick()
                guard !Task.isCancelled else { return }
                let sleepSeconds = self.effectiveLoopInterval
                try? await Task.sleep(for: .seconds(sleepSeconds))
            }
        }
        log.info("Screen watch started at \(self.policy.interval, privacy: .public)s (effective: \(self.effectiveLoopInterval, privacy: .public)s)")
    }

    /// Computes the effective loop sleep interval, adapting to active multi-target role schedules.
    private var effectiveLoopInterval: TimeInterval {
        if !watchItems.isEmpty {
            let activeIntervals = watchItems.filter(\.isEnabled).map(\.effectiveInterval)
            if let minItemInterval = activeIntervals.min() {
                return max(2.0, min(self.policy.interval, minItemInterval))
            }
        }
        return self.policy.interval
    }

    /// Restarts the monitoring loop to pick up new schedules without waiting for the old interval to elapse.
    private func restartLoop() {
        if state.watchPhase != .off {
            loop?.cancel()
            state.watchPhase = .off
            setEnabled(true)
        }
    }

    func setInterval(_ interval: ScreenWatchInterval) {
        guard interval != state.watchInterval else { return }
        state.watchInterval = interval
        preferences.interval = interval
        policy.interval = interval.seconds

        // Restarted rather than left to pick the new interval up on its next
        // wake: the point of choosing 15 seconds while a 2-minute sleep is in
        // flight is not to wait out the two minutes first.
        restartLoop()
    }

    func stop(status: String = "") {
        cancelRequestedAction()
        if state.screenObjective?.isActive == true { state.onStopObjective?() }
        loop?.cancel()
        loop = nil
        state.watchPhase = .off
        state.watchStatus = status
        updateMeetingSessionState()
    }

    // MARK: - Pinning

    /// Pins the window in front, or lets go of the one already pinned.
    ///
    /// One command rather than two because there is only ever one sensible next
    /// action, and a shortcut the user has to remember the state of is a
    /// shortcut they stop using.
    func togglePin() async {
        if target.isPinned {
            unpin()
        } else {
            await pinFocusedWindow()
            if target.isPinned && state.watchPhase == .off {
                setEnabled(true)
            }
        }
    }

    /// Fixes the target on whatever window is in front right now.
    ///
    /// Decoupled from automatically starting continuous observation: pinning
    /// locks the target for both one-shot explanations and continuous watching.
    func pinFocusedWindow() async {
        guard await requireCapturePermission() else { return }

        let candidate = subjectApplication()
        var window: PinnedWindow?
        if let app = candidate.app {
            window = try? await capturer.focusedWindow(pid: app.processIdentifier)
        }
        let isExcluded = window.map {
            configuration.isExcluded(bundleID: $0.bundleID, windowTitle: $0.windowTitle)
        } ?? false

        if let refusal = PinRefusal.refusal(
            for: window, isOwnWindow: candidate.isOwn, isExcluded: isExcluded) {
            state.presentFailure(describe(refusal))
            return
        }
        guard let window else { return }
        adopt(.pinned(window))
    }

    /// Applies a subject the user picked from the list.
    ///
    /// Takes the whole `WatchTarget` rather than one of its payloads so the
    /// picker can offer "follow the focused window" as one of the rows — it is a
    /// choice about the same thing, and a separate control for it would put two
    /// ways of saying "stop watching that" in the same toolbar.
    func choose(_ chosen: WatchTarget) async {
        cancelRequestedAction()
        if chosen != target { state.onStopObjective?() }
        switch chosen {
        case .focused:
            unpin()
        case .pinned(let window):
            guard await requireCapturePermission() else { return }
            // Checked again even though the picker already filtered the list:
            // between it being drawn and a row being clicked, a browser window
            // can navigate onto the exclusion list. The gate belongs where the
            // decision is taken, not where it was offered.
            guard !configuration.isExcluded(
                bundleID: window.bundleID, windowTitle: window.windowTitle) else {
                state.presentFailure(describe(.excluded(appName: window.appName)))
                return
            }
            adopt(.pinned(window))
        case .display(let display):
            guard await requireCapturePermission() else { return }
            adopt(.display(display))
        }
        if state.watchPhase == .off {
            setEnabled(true)
        }
    }

    /// Applies a collection of multiple screen targets with individual roles.
    func chooseItems(_ items: [WatchItem]) async {
        cancelRequestedAction()
        state.onStopObjective?()
        guard await requireCapturePermission() else { return }
        self.watchItems = items
        state.watchItems = items
        policy.reset()
        recentAdvice.removeAll()

        let activeCount = items.filter(\.isEnabled).count
        if items.isEmpty {
            state.watchStatus = watchingStatus
            if state.watchPhase != .off {
                stop(status: state.watchStatus)
            }
        } else if activeCount == 0 {
            let msg = localized(
                "All watch targets are disabled.",
                "すべての監視対象が無効化されています。",
                "모든 감시 대상이 비활성화되었습니다."
            )
            if state.watchPhase != .off {
                stop(status: msg)
            } else {
                state.watchStatus = msg
            }
        } else {
            state.watchStatus = localized(
                "Watching \(activeCount) screen(s) with custom objectives.",
                "\(activeCount) 個の画面を個別の目的で監視しています。",
                "\(activeCount)개의 화면을 개별 목적으로 감시하고 있습니다."
            )
            if state.watchPhase != .off {
                restartLoop()
            } else {
                setEnabled(true)
            }
        }
        updateMeetingSessionState()
        log.info("Multi-screen watch items updated: \(items.count) items (active: \(activeCount))")
    }

    /// Sets or updates the active role/objective for a specific watch target.
    func setRoleForTarget(_ role: WatchRole, target: WatchTarget? = nil) async {
        guard await requireCapturePermission() else { return }
        let activeTarget = target ?? self.target
        let item = WatchItem(target: activeTarget, role: role, isEnabled: true)

        if let existingIdx = watchItems.firstIndex(where: { $0.targetKey == item.targetKey }) {
            watchItems[existingIdx].role = role
            watchItems[existingIdx].isEnabled = true
        } else {
            watchItems.append(item)
        }
        state.watchItems = watchItems
        state.selectedPreset = role

        policy.reset(for: item.targetKey)
        recentAdvice.removeAll()

        let targetName = activeTarget.subjectName ?? localized("Screen", "画面", "화면")
        state.watchStatus = localized(
            "Watching [\(targetName)] with objective: \(role.name)",
            "[\(targetName)] を「\(role.name)」の目的で監視中",
            "[\(targetName)]을(를) ‘\(role.name)’ 목적으로 감시 중"
        )

        if state.watchPhase != .off {
            restartLoop()
        }
        updateMeetingSessionState()
        log.info("Role [\(role.name, privacy: .public)] applied to target [\(item.targetKey, privacy: .public)]")
    }

    /// Executes an action requested from an advice card (e.g. CLI prompt approval).
    ///
    /// The payload was written by the model, which may have been steered by text
    /// on the watched screen, so nothing is typed until the user has seen it in
    /// full. Return is never pressed on the user's behalf unless they pick that
    /// option explicitly.
    private func executeAction(_ payload: String, target: String?) {
        cancelRequestedAction()
        requestedActionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let selected: WatchTarget
            if let target {
                let matches = state.watchItems.filter { $0.targetName == target }
                if matches.count == 1 {
                    let key = matches[0].targetKey
                    let available = await availableTargets()
                    guard !Task.isCancelled else { return }
                    guard let window = available.windows.first(where: { WatchTarget.pinned($0).key == key }) else {
                        state.presentFailure("The action window is unavailable; no action was executed."); return
                    }
                    selected = .pinned(window)
                } else if target == state.watchTarget.subjectName { selected = state.watchTarget }
                else { state.presentFailure("The action target could not be identified; no action was executed."); return }
            } else { selected = state.watchTarget }
            guard !Task.isCancelled else { return }
            onRequestedAction?(payload, selected)
        }
    }

    nonisolated static func needsPaste(_ payload: String) -> Bool {
        payload.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}"
        }
    }

    nonisolated static func keystrokeScript(payload: String, appName: String, pressReturn: Bool) -> String {
        let needsPaste = needsPaste(payload)
        var lines = [
            "tell application \(AppleScriptLiteral.quoted(appName)) to activate",
            "delay 0.15",
        ]
        if needsPaste {
            lines.append("set the clipboard to \(AppleScriptLiteral.quoted(payload))")
        }
        lines.append("tell application \"System Events\"")
        lines.append(needsPaste
            ? "    keystroke \"v\" using command down"
            : "    keystroke \(AppleScriptLiteral.quoted(payload))")
        if pressReturn { lines.append("    key code 36") }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// Everything that could be pinned right now, with the privacy list applied.
    ///
    /// Excluded windows are left out rather than shown greyed out. A disabled
    /// row invites a click and then explains itself; an absent one asks nothing
    /// of the user, and the list of what is excluded already has a home in
    /// Settings.
    func availableTargets() async -> WatchTargetList {
        let windows = (try? await capturer.availableWindows()) ?? []
        return WatchTargetList(
            windows: windows.filter {
                !configuration.isExcluded(bundleID: $0.bundleID, windowTitle: $0.windowTitle)
            },
            displays: Self.attachedDisplays())
    }

    /// Thumbnails for the picker's grid, keyed the way the picker holds them.
    ///
    /// Goes through the same privacy gate as a real capture rather than around
    /// it. A preview is a photograph of the user's screen like any other, and an
    /// app on the exclusion list must not appear in one — not even in a picture
    /// that never leaves this Mac, because the whole promise of the list is that
    /// those windows are not photographed.
    ///
    /// A target that produced nothing — no permission, a window closed while the
    /// grid was open, a display unplugged — is absent from the result rather
    /// than mapped to a failure. The picker keeps whatever picture it already
    /// had and nothing about the choice is blocked by a missing thumbnail.
    ///
    /// `.focused` is never photographed: "whatever is in front" is not a subject
    /// that can be, since the moment the picker is in front the answer would be
    /// the picker.
    func previews(of targets: [WatchTarget]) async -> [String: CGImage] {
        let configuration = self.configuration
        let windows = targets.compactMap(\.pinnedWindow).filter {
            !configuration.isExcluded(bundleID: $0.bundleID, windowTitle: $0.windowTitle)
        }
        let displays = targets.compactMap(\.pinnedDisplay)

        var result: [String: CGImage] = [:]

        let windowImages = await capturer.previews(of: windows)
        for window in windows where windowImages[window.id] != nil {
            result[WatchTarget.pinned(window).key] = windowImages[window.id]
        }

        let displayImages = await capturer.previews(of: displays) { bundleID, title in
            configuration.isExcluded(bundleID: bundleID, windowTitle: title)
        }
        for display in displays where displayImages[display.id] != nil {
            result[WatchTarget.display(display).key] = displayImages[display.id]
        }

        return result
    }

    /// The screens currently attached, as the picker should name them.
    ///
    /// Read from `NSScreen` rather than from `SCShareableContent`, which knows
    /// the geometry but not what the screen is called — and "Display 1" beside
    /// "Display 2" is not a choice anyone can make.
    private static func attachedDisplays() -> [PinnedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let scale = screen.backingScaleFactor
            return PinnedDisplay(
                id: number,
                name: screen.localizedName,
                width: Int(screen.frame.width * scale),
                height: Int(screen.frame.height * scale))
        }
    }

    /// Takes on a new subject without forcing the watch loop to start.
    ///
    /// Decoupled from auto-starting: choosing or pinning a target sets what the
    /// agent observes (for both one-shot explanations and continuous watch). If
    /// watching is already active it continues on the new subject, but it does
    /// not force an off watch to turn on.
    private func adopt(_ newTarget: WatchTarget) {
        if newTarget != target { state.onStopObjective?() }
        target = newTarget
        state.watchTarget = newTarget
        watchItems.removeAll()
        state.watchItems.removeAll()
        // The header names what the agent is reading, not what has keyboard
        // focus. While a subject is pinned those are different things, and the
        // desktop sampler that normally keeps this line current stands down —
        // so it would otherwise freeze on whichever window happened to be in
        // front at the moment of pinning and quietly claim to be reading it.
        if let subject = newTarget.subjectName { state.focusedApp = subject }
        log.info("Watch target changed")

        // A pin is a new subject, so nothing about the last one carries over:
        // neither the fingerprint that would make the first look count as
        // unchanged, nor the headlines that were about something else.
        policy.reset()
        recentAdvice.removeAll()

        if state.watchPhase != .off {
            state.watchStatus = watchingStatus
            restartLoop()
        } else if let subject = newTarget.subjectName {
            state.watchStatus = localized(
                "Target set to \(subject).",
                "\(subject) を対象に設定しました。",
                "\(subject)을(를) 대상으로 설정했습니다."
            )
        }
        updateMeetingSessionState()
    }

    /// Whether the screen can be photographed at all, complaining if not.
    ///
    /// Pinning is the one part of the watch with no degraded mode: a subject
    /// that is not in front exposes no accessibility tree, so without this
    /// permission there is nothing to look at rather than less to look at.
    private func requireCapturePermission() async -> Bool {
        guard await ScreenCapturer.hasPermission() else {
            state.presentFailure(localized("""
                Pinning needs Screen Recording permission to capture background windows and inspect them.

                Open **✨ ▸ Settings ▸ Permissions** to grant it.
                """, """
                見守り固定には画面収録の許可が必要です。バックグラウンドでの画面確認やスクロール情報収集に使用します。

                **✨ ▸ 設定 ▸ 権限** から許可してください。
                """, """
                고정 지켜보기에는 화면 기록 권한이 필요합니다. 백그라운드 화면 확인 및 스크롤 정보 수집에 사용됩니다.

                **✨ ▸ 설정 ▸ 권한** 에서 허용해 주세요.
                """))
            return false
        }
        return true
    }

    /// Which application's window a pin should be about.
    ///
    /// The frontmost one, unless that is us — in which case it is whichever the
    /// user was in before, because they got here by clicking a button in this
    /// app and did not mean to change the subject by doing so. `isOwn` is only
    /// true when there is no other candidate at all, which is a fresh launch
    /// with nothing else running.
    private func subjectApplication() -> (app: NSRunningApplication?, isOwn: Bool) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication

        if let frontmost, frontmost.processIdentifier != ownPID {
            return (frontmost, false)
        }
        if let previous = lastForeignApp, !previous.isTerminated {
            return (previous, false)
        }
        return (frontmost, frontmost != nil)
    }

    /// Goes back to following the focused window. Does not stop the watch —
    /// the switch that started it is the one that ends it.
    func unpin() {
        cancelRequestedAction()
        state.onStopObjective?()
        guard target.isPinned || !watchItems.isEmpty else { return }
        target = .focused
        state.watchTarget = .focused
        watchItems.removeAll()
        state.watchItems.removeAll()
        policy.reset()
        recentAdvice.removeAll()
        state.watchStatus = state.watchPhase == .off ? "" : watchingStatus
        updateMeetingSessionState()
    }

    /// Lets go of a pinned window that no longer exists, and stops.
    ///
    /// Stopping rather than falling back to the focused window: the user named a
    /// subject, and quietly switching to a different one would be the watch
    /// looking at — and paying for — something nobody asked about.
    private func endPin(gone subject: String) {
        target = .focused
        state.watchTarget = .focused
        watchItems.removeAll()
        state.watchItems.removeAll()
        stop(status: "")
        updateMeetingSessionState()
        state.presentFailure(localized(
            "Stopped watching \(subject) — it is no longer there.",
            "\(subject) を見張るのをやめました。対象がなくなっています。",
            "지켜보기를 멈췄습니다: \(subject) — 대상이 없어졌습니다."))
        log.info("Pinned subject disappeared")
    }

    // MARK: - One tick

    private func tick() async {
        guard state.watchPhase != .off else { return }
        if !watchItems.isEmpty {
            await tickMulti()
        } else {
            switch target {
            case .focused:
                await tickFocused()
            case .pinned(let window):
                await tickPinnedWindow(window)
            case .display(let display):
                await tickPinnedDisplay(display)
            }
        }
    }

    /// Parallel multi-screen monitoring loop: iterates through active items,
    /// checks per-target fingerprints for free skipping, and triggers role-specific LLM advice.
    private func tickMulti() async {
        guard await requireCapturePermission() else { return }
        let activeItems = watchItems.filter(\.isEnabled)
        guard !activeItems.isEmpty else { return }

        let available = await availableTargets()

        for item in activeItems {
            guard state.watchPhase != .off, !Task.isCancelled else { return }

            if item.targetKey.hasPrefix("window:") {
                guard let windowIdString = item.targetKey.split(separator: ":").last,
                      let windowId = UInt32(windowIdString),
                      let window = available.windows.first(where: { $0.id == windowId }) else {
                    continue
                }
                await tickTargetItem(item, window: window, display: nil)
            } else if item.targetKey.hasPrefix("display:") {
                guard let displayIdString = item.targetKey.split(separator: ":").last,
                      let displayId = UInt32(displayIdString),
                      let display = available.displays.first(where: { $0.id == displayId }) else {
                    continue
                }
                await tickTargetItem(item, window: nil, display: display)
            } else if item.targetKey == "focused" {
                await tickFocused()
            }
        }
    }

    private func tickTargetItem(_ item: WatchItem, window: PinnedWindow?, display: PinnedDisplay?) async {
        let captured: Captured
        if let window {
            let capture: ScreenCapturer.WindowCapture
            do {
                capture = try await capturer.captureWindow(window)
            } catch {
                return
            }
            captured = Captured(
                image: capture.image,
                appName: capture.appName,
                windowTitle: capture.windowTitle,
                bundleID: capture.bundleID,
                subject: "\(capture.appName) — \(capture.windowTitle)",
                isExcluded: configuration.isExcluded(bundleID: capture.bundleID, windowTitle: capture.windowTitle),
                fingerprintMasks: await objectiveDecorationRects(window, capture: capture)
            )
        } else if let display {
            let capture: ScreenCapturer.DisplayCapture
            let configuration = self.configuration
            do {
                capture = try await capturer.capturePinnedDisplay(display) { bundleID, title in
                    configuration.isExcluded(bundleID: bundleID, windowTitle: title)
                }
            } catch {
                return
            }
            captured = Captured(
                image: capture.image,
                appName: display.displayName,
                windowTitle: display.resolution,
                bundleID: nil,
                subject: display.displayName,
                isExcluded: false
            )
        } else {
            return
        }

        guard !Task.isCancelled, let fingerprint = captured.fingerprint else { return }

        let decision = policy.decide(
            for: item.targetKey,
            fingerprint: fingerprint,
            interval: item.effectiveInterval,
            isOwnWindow: false,
            isExcluded: captured.isExcluded,
            isBusy: state.isStreaming
        )

        if case .skip(let reason) = decision {
            if case .unchanged = reason {
                let timeStr = Self.clock.string(from: Date())
                let activeCount = watchItems.filter(\.isEnabled).count
                if activeCount <= 1 {
                    state.watchStatus = localized(
                        "Watching [\(item.targetName)] — no changes detected (\(timeStr)).",
                        "[\(item.targetName)] を見張り中（変化なし、\(timeStr) 確認）",
                        "[\(item.targetName)] 감시 중 (변화 없음, \(timeStr) 확인)"
                    )
                } else {
                    state.watchStatus = localized(
                        "Watching \(activeCount) screens — actively checking (\(timeStr)).",
                        "\(activeCount) 画面を監視中（巡回中、\(timeStr) 確認）",
                        "\(activeCount)개 화면 감시 중 (확인 중, \(timeStr) 확인)"
                    )
                }
            }
            return
        }

        // Content changed: recognize text and invoke model with the assigned role
        let text = (try? await recognizer.recognizeText(in: captured.image)) ?? ""
        let image = router.blockedReason(for: .vision) == nil
            ? await Self.encode(captured.image)
            : nil

        await record(captured, text: text)

        policy.recordLook(for: item.targetKey, fingerprint: fingerprint)
        state.watchPhase = .looking
        defer { if state.watchPhase == .looking { state.watchPhase = .watching } }

        do {
            let look = ScreenLook(
                appName: captured.appName,
                windowTitle: captured.windowTitle,
                text: text,
                image: image,
                fingerprint: fingerprint,
                isOwnWindow: false,
                isExcluded: false,
                pinnedSubject: captured.subject
            )

            if state.screenObjective?.isActive == true, let pinned = window {
                onObjectiveObservation?(look, pinned)
                return
            }
            let card = try await agent.advise(
                screenshot: look.image,
                context: await context(for: look, role: item.role),
                recentAdvice: alreadySaid(),
                role: item.role,
                originTarget: item.targetName,
                promptOverride: item.customPromptOverride
            )
            policy.recordSuccess(for: item.targetKey)

            guard let card else { return }

            recentAdvice.append(card.title)
            if recentAdvice.count > 6 { recentAdvice.removeFirst() }

            let hudSev: HUDCard.Severity
            switch card.severity {
            case .info: hudSev = .info
            case .suggestion: hudSev = .suggestion
            case .warning: hudSev = .warning
            case .error: hudSev = .error
            case .actionItem: hudSev = .actionItem
            }

            state.presentAdvice(
                title: card.title,
                body: card.body,
                severity: hudSev,
                originTarget: item.targetName,
                roleId: item.role.id,
                roleName: item.role.name,
                roleIcon: item.role.icon,
                actionTitle: card.actionTitle,
                actionPayload: card.actionPayload
            )
            state.watchStatus = localized(
                "Spoke at \(Self.clock.string(from: Date())) on [\(item.targetName)].",
                "\(Self.clock.string(from: Date())) に [\(item.targetName)] について助言しました。",
                "\(Self.clock.string(from: Date())) 에 [\(item.targetName)]에 대해 조언했습니다."
            )
        } catch {
            _ = policy.recordFailure(for: item.targetKey)
        }
    }

    /// One look at whatever is in front.
    ///
    /// The order here is forced by where the text comes from: the fingerprint
    /// includes the window's text, OCR is what supplies that text for a canvas
    /// app, and OCR needs the picture. So the picture is taken before the policy
    /// is asked — a screenshot the policy then throws away is the price of being
    /// able to notice that a Figma board changed at all.
    private func tickFocused() async {
        // No picture when nothing can look at one. Capturing anyway would spend
        // the screenshot, send it to a route that is blocked, and fail — three
        // times, at which point the watch stops. The text path still works.
        let wantsImage = canCaptureScreen && router.blockedReason(for: .vision) == nil
        let look = await currentLook(includeImage: wantsImage)
        let decision = policy.decide(
            fingerprint: look?.fingerprint,
            isOwnWindow: look?.isOwnWindow ?? false,
            isExcluded: look?.isExcluded ?? false,
            isBusy: state.isStreaming)

        if case .skip(let reason) = decision {
            state.watchStatus = describe(reason)
            return
        }
        guard let look else { return }
        await respond(to: look)
    }

    /// A frame from a pinned subject, before anything expensive has been done
    /// with it. The two pinned paths differ only in how they fill this in.
    private struct Captured {
        var image: CGImage
        var appName: String
        var windowTitle: String
        var bundleID: String?
        /// Named for the context block and the status line.
        var subject: String
        /// Whether the privacy list rules this frame out entirely. Always false
        /// for a display, where exclusion is enforced by leaving windows out of
        /// the picture rather than by dropping the whole look.
        var isExcluded: Bool
        var fingerprintMasks: [CGRect] = []

        var fingerprint: String? {
            guard let picture = FrameFingerprint.compute(image, masking: fingerprintMasks) else { return nil }
            // Title wording remains meaningful even when its focus color is normalized.
            return fingerprintMasks.isEmpty ? picture : "\(picture):\(windowTitle)"
        }
    }

    private func objectiveDecorationRects(_ pinned: PinnedWindow,
                                          capture: ScreenCapturer.WindowCapture) async -> [CGRect] {
        guard !state.isStreaming, let objective = state.screenObjective, objective.isActive,
              objective.target.id == pinned.id, objective.target.processID == pinned.processID,
              !configuration.isExcluded(bundleID: capture.bundleID, windowTitle: capture.windowTitle) else { return [] }
        let lookup = Task.detached(priority: .utility) {
            AccessibilityInspector().windowDecorationRects(of: pinned, in: capture)
        }
        return await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
    }

    /// One look at the window the user pinned.
    private func tickPinnedWindow(_ pinned: PinnedWindow) async {
        let capture: ScreenCapturer.WindowCapture
        do {
            capture = try await capturer.captureWindow(pinned)
        } catch ScreenCapturer.CaptureError.windowGone {
            endPin(gone: pinned.displayName)
            return
        } catch {
            recordFailure((error as? ScreenCapturer.CaptureError)?.description
                ?? error.localizedDescription)
            return
        }

        await look(at: Captured(
            image: capture.image,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            bundleID: capture.bundleID,
            subject: "\(capture.appName) — \(capture.windowTitle)",
            // Re-checked every tick against the title as it is right now: a
            // pinned browser window can navigate somewhere the user asked never
            // to send.
            isExcluded: configuration.isExcluded(
                bundleID: capture.bundleID, windowTitle: capture.windowTitle),
            fingerprintMasks: await objectiveDecorationRects(pinned, capture: capture)))
    }

    /// One look at the display the user pinned.
    ///
    /// Windows on the privacy list are left out of the frame by the capture
    /// itself, so there is no per-window exclusion decision to make here. That
    /// is the only honest way to watch a display: it is a region of the desk,
    /// not an application, and the user's excluded apps are free to sit on it.
    private func tickPinnedDisplay(_ display: PinnedDisplay) async {
        let capture: ScreenCapturer.DisplayCapture
        let configuration = self.configuration
        do {
            capture = try await capturer.capturePinnedDisplay(display) { bundleID, title in
                configuration.isExcluded(bundleID: bundleID, windowTitle: title)
            }
        } catch ScreenCapturer.CaptureError.displayGone {
            endPin(gone: display.displayName)
            return
        } catch {
            recordFailure((error as? ScreenCapturer.CaptureError)?.description
                ?? error.localizedDescription)
            return
        }

        let subject = capture.excludedWindows > 0
            ? "\(display.displayName) (whole screen, \(capture.excludedWindows) excluded window(s) left out)"
            : "\(display.displayName) (whole screen)"

        await look(at: Captured(
            image: capture.image,
            appName: display.displayName,
            windowTitle: display.resolution,
            bundleID: nil,
            subject: subject,
            isExcluded: false))
    }

    /// The shared half of both pinned paths: decide, then pay.
    ///
    /// The reverse order of `tickFocused`, and cheaper for it. A pinned subject
    /// is identified by its picture rather than by its text, so the policy can be
    /// asked *before* anything expensive happens — an unchanged subject costs one
    /// screenshot and one hash, with no OCR and no request. That is what makes
    /// leaving this on for an afternoon reasonable.
    private func look(at captured: Captured) async {
        guard !Task.isCancelled else { return }
        // `nil` means the frame could not be measured, which is not the same as
        // it being unchanged — so the look is skipped without being recorded and
        // the next tick starts over.
        guard let fingerprint = captured.fingerprint else {
            state.watchStatus = describe(.nothingReadable)
            return
        }

        // `isOwnWindow: false` unconditionally, and that is the point of pinning
        // rather than an oversight. The focused path has to stand down when this
        // app comes to the front, because "the focused window" would then be our
        // own advice. A pinned subject does not move when the user clicks over
        // here to ask a question, so the watch keeps running through it.
        let decision = policy.decide(
            fingerprint: fingerprint,
            isOwnWindow: false,
            isExcluded: captured.isExcluded,
            isBusy: state.isStreaming)

        if case .skip(let reason) = decision {
            state.watchStatus = describe(reason)
            return
        }

        // Everything from here costs something, and none of it runs for a
        // subject that has not changed.
        let text = (try? await recognizer.recognizeText(in: captured.image)) ?? ""
        let image = router.blockedReason(for: .vision) == nil
            ? await Self.encode(captured.image)
            : nil

        // Into memory, not just into this one request.
        //
        // While a subject is pinned the accessibility sampler stands down — the
        // user said to look at that rather than at them — so this is the only
        // thing writing what the agent can see. Without it the store's newest
        // screen is whatever they happened to be in before they pinned, and a
        // question about "this screen" is answered from a window nobody is
        // watching any more.
        await record(captured, text: text)

        await respond(to: ScreenLook(
            appName: captured.appName,
            windowTitle: captured.windowTitle,
            text: text,
            image: image,
            fingerprint: fingerprint,
            isOwnWindow: false,
            isExcluded: false,
            pinnedSubject: captured.subject))
    }

    /// Writes what the watch just read into the same store the desktop sampler
    /// uses, so every other surface — the answer path, `read_current_screen`,
    /// the proactive scan, search — sees the pinned subject as the current
    /// screen rather than having to be told about it separately.
    ///
    /// Marked `.watch` rather than passed off as an OS event: this is the one
    /// row in the store describing something the user may not be able to see.
    ///
    /// A failed write is logged and dropped. It costs this one look's memory,
    /// and the advice built from the same text is already on its way.
    private func record(_ captured: Captured, text: String) async {
        guard text.count >= 20 else { return }
        let privacy = PrivacyFilter()
        do {
            try await store.append(.screen(ScreenObservation(
                bundleID: captured.bundleID,
                appName: privacy.redactSensitiveText(captured.appName),
                windowTitle: privacy.redactSensitiveText(captured.windowTitle),
                text: privacy.redactSensitiveText(text),
                source: .ocr,
                trigger: .watch)))
        } catch {
            log.error("Watch observation not stored: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks the model about a look and puts whatever comes back on screen.
    ///
    /// Shared by both paths: what to do with a look does not depend on how the
    /// watch decided to take it, and the failure handling in particular — three
    /// strikes and the watch stops — is the part that must not drift between
    /// them.
    private func respond(to look: ScreenLook) async {
        policy.recordLook(fingerprint: look.fingerprint)
        state.watchPhase = .looking
        defer { if state.watchPhase == .looking { state.watchPhase = .watching } }

        do {
            if state.screenObjective?.isActive == true, let pinned = target.pinnedWindow {
                onObjectiveObservation?(look, pinned)
                return
            }
            let card = try await agent.advise(
                screenshot: look.image,
                context: await context(for: look),
                recentAdvice: alreadySaid())
            policy.recordSuccess()

            guard let card else {
                state.watchStatus = localized(
                    "Looked at \(Self.clock.string(from: Date())) — nothing worth saying.",
                    "\(Self.clock.string(from: Date())) に確認 — 伝えることはありませんでした。",
                    "\(Self.clock.string(from: Date())) 에 확인 — 전할 말은 없었습니다.")
                return
            }

            recentAdvice.append(card.title)
            if recentAdvice.count > 6 { recentAdvice.removeFirst() }
            state.presentAdvice(title: card.title, body: card.body)
            state.watchStatus = localized(
                "Last spoke at \(Self.clock.string(from: Date())).",
                "\(Self.clock.string(from: Date())) に話しかけました。",
                "\(Self.clock.string(from: Date())) 에 말을 걸었습니다.")
        } catch {
            recordFailure((error as? LanguageModelError)?.description
                ?? error.localizedDescription)
        }
    }

    /// Counts a failed look, and stops the watch once there have been enough.
    ///
    /// Stopping rather than looping: every attempt costs a request, and the
    /// cause is almost always something only the user can fix.
    private func recordFailure(_ reason: String) {
        log.warning("Screen watch failed: \(reason, privacy: .public)")

        guard policy.recordFailure() else {
            state.watchStatus = localized(
                "That look failed (\(reason)). Trying again shortly.",
                "今回の確認は失敗しました（\(reason)）。しばらくして再試行します。",
                "이번 확인은 실패했습니다(\(reason)). 잠시 후 다시 시도합니다.")
            return
        }
        stop(status: "")
        state.presentFailure(localized("""
            The screen watch stopped after \(policy.consecutiveFailures) failed looks: \(reason)
            """, """
            画面の確認が \(policy.consecutiveFailures) 回続けて失敗したため停止しました: \(reason)
            """,
            """
            화면 확인이 \(policy.consecutiveFailures)회 연속 실패해 중지했습니다: \(reason)
            """))
    }

    /// Everything the user has already been told, from either path.
    ///
    /// The proactive loop is still running alongside this one and posts into the
    /// same thread from the same screen. Without its headlines here, the watch
    /// reads a visible error, sees nothing in its own history about it, and says
    /// the thing the user was told thirty seconds ago.
    private func alreadySaid() -> [String] {
        var seen = Set<String>()
        return (recentAdvice + state.recentHeadlines())
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What the model is told, beyond the picture.
    ///
    /// The current window's text is included explicitly rather than relied on
    /// through memory: the capture path only writes an observation when the text
    /// changed by enough to be worth a row, so the window in front right now is
    /// not guaranteed to be in the store at all.
    private func context(for look: ScreenLook, role: WatchRole? = nil) async -> String {
        let recent = (try? await store.recent(seconds: 180, limit: 30)) ?? []
        var parts: [String] = []

        let isMeeting = role?.triggerKind == .meetingFast || role?.id == "builtin.meeting"

        if isMeeting {
            // For meetings, spoken audio dialogue (both me and other participants) is paramount
            let audioObservations = recent.compactMap { observation -> DesktopObservation? in
                if case .audio = observation { return observation }
                return nil
            }
            if !audioObservations.isEmpty {
                parts.append("## Recent meeting dialogue / 会話履歴 (相手およびあなたの発言)\n" +
                    ContextFormatter.synthesize(audioObservations, maxCharacters: 4000))
            }
        }

        if !recent.isEmpty && !isMeeting {
            parts.append(ContextFormatter.synthesize(recent, maxCharacters: 3500))
        }

        if !look.text.isEmpty {
            // Which of the two this is matters to the answer. A pinned subject
            // is usually not what the user is doing right now — it is the build,
            // the deploy, the long-running job they stepped away from — so
            // advice phrased as "you are currently editing…" would be wrong
            // about the one thing the model can check.
            let heading = look.pinnedSubject.map { "## Pinned subject being watched — \($0)" }
                ?? "## Focused window right now — \(look.appName): \(look.windowTitle)"
            parts.append("""
                \(heading)
                \(privacyFilter.redactSensitiveText(look.text).prefix(isMeeting ? 2000 : 3500))
                """)
        }
        return PrivacyFilter().redactSensitiveText(parts.joined(separator: "\n\n"))
    }

    // MARK: - Looking

    /// Reads the frontmost window, and photographs it when asked to.
    ///
    /// Returns `nil` only when there is no frontmost application at all. An
    /// excluded or own window still comes back, carrying the flag — the caller
    /// needs to tell the user *why* nothing happened, and a `nil` cannot.
    func currentLook(includeImage: Bool) async -> ScreenLook? {
        let configuration = self.configuration
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let isOwnWindow = frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier

        if isOwnWindow {
            return ScreenLook(
                appName: frontmost.localizedName ?? "My Computer Agent",
                windowTitle: "",
                text: "",
                image: nil,
                fingerprint: "",
                isOwnWindow: true,
                isExcluded: false)
        }

        guard let snapshot = reader.readFocusedWindow() else { return nil }
        let isExcluded = configuration.isExcluded(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle)

        // Nothing is captured for an excluded or own window — not even to throw
        // it away afterwards. The privacy gate runs before the screenshot, not
        // after it, which is the whole point of it being a pre-capture gate.
        guard !isExcluded else {
            return ScreenLook(
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle,
                text: "",
                image: nil,
                fingerprint: "",
                isOwnWindow: false,
                isExcluded: true)
        }

        var text = snapshot.text
        var image: ImageAttachment?

        if includeImage {
            do {
                let configuration = self.configuration
                let frame = try await capturer.captureFocusedWindow(
                    pid: frontmost.processIdentifier
                ) { bundleID, title in
                    configuration.isExcluded(bundleID: bundleID, windowTitle: title)
                }
                image = await Self.encode(frame)
                // Same fallback the capture path uses: a canvas app exposes
                // almost no accessibility tree, and OCR is what makes its text
                // searchable in the prompt alongside the picture.
                if text.count < 40, let recognised = try? await recognizer.recognizeText(in: frame) {
                    text = recognised
                }
            } catch {
                log.debug("Watch capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return ScreenLook(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            text: text,
            image: image,
            // The window identity is part of it: switching to another window
            // with identical text — two empty editors — is still a change worth
            // looking at.
            fingerprint: "\(snapshot.appName)|\(snapshot.windowTitle)|\(text.hashValue)",
            isOwnWindow: false,
            isExcluded: false)
    }

    /// Encodes off the main actor. A 1400-point JPEG is tens of milliseconds of
    /// pure CPU, and the main actor is where the HUD, the hot keys and the
    /// capture loop all live.
    private static func encode(_ frame: CGImage) async -> ImageAttachment? {
        await Task.detached(priority: .utility) {
            ImageEncoder.jpeg(frame).map { ImageAttachment(data: $0, mimeType: "image/jpeg") }
        }.value
    }

    // MARK: - Status

    /// What the status line says while the watch is running and has nothing to
    /// report — which is most of the time, by design.
    ///
    /// The pinned wording leads with the window's name because that is the fact
    /// a user cannot otherwise recover: a watch that follows the focus is
    /// self-evident from whatever is in front, while a pinned one is looking at
    /// something that may be entirely off screen.
    private var watchingStatus: String {
        if !watchItems.isEmpty {
            let activeCount = watchItems.filter(\.isEnabled).count
            if activeCount == 0 {
                return localized(
                    "All watch targets are disabled.",
                    "すべての見守り対象が無効化されています。",
                    "모든 지켜보기 대상이 비활성화되었습니다."
                )
            }
            return localized(
                "Watching \(activeCount) screen(s) with custom objectives.",
                "\(activeCount) 個の画面を個別の目的で見守っています。",
                "\(activeCount)개의 화면을 개별 목적으로 지켜보고 있습니다."
            )
        }
        guard let subject = target.subjectName else {
            return localized(
                "Watching. It will only say something when it spots something.",
                "見守り中（アクティブ追従）。何か気づいたときだけ話しかけます。",
                "지켜보는 중 (활성 추적). 무언가 발견했을 때만 말을 겁니다.")
        }
        return localized(
            "Watching \(subject) — it stays there while you work elsewhere.",
            "\(subject) を見守り固定中。ほかのウインドウで作業していてもバックグラウンドで継続します。",
            "지켜보는 중: \(subject) — 다른 곳에서 작업해도 백그라운드에서 유지됩니다.")
    }

    private func describe(_ refusal: PinRefusal) -> String {
        switch refusal {
        case .ownWindow:
            return localized("""
                That is this app's own window. Bring the window you want watched \
                to the front first, then press the shortcut again.
                """, """
                それはこのアプリ自身のウインドウです。見張りたいウインドウを前面にしてから、\
                もう一度ショートカットを押してください。
                """, """
                그것은 이 앱 자체의 윈도우입니다. 지켜보게 하려는 윈도우를 앞으로 가져온 뒤 \
                단축키를 다시 눌러 주세요.
                """)
        case .excluded(let appName):
            return localized("""
                \(appName) is on the excluded list, so it will not be watched or \
                sent anywhere. Remove it in **✨ ▸ Settings ▸ Privacy** if that \
                is not what you want.
                """, """
                \(appName) は除外リストに入っているため、見張りも送信も行いません。\
                意図しない場合は **✨ ▸ 設定 ▸ プライバシー** から外してください。
                """, """
                \(appName) 은(는) 제외 목록에 있어 지켜보지도, 어디로 보내지도 않습니다. \
                의도한 것이 아니라면 **✨ ▸ 설정 ▸ 개인정보** 에서 빼 주세요.
                """)
        case .noWindow:
            return localized(
                "There is no window in front to pin.",
                "前面に固定できるウインドウがありません。",
                "앞에 고정할 수 있는 윈도우가 없습니다.")
        }
    }

    private func describe(_ skip: ScreenWatchPolicy.Skip) -> String {
        switch skip {
        case .busy:
            return localized(
                "Waiting for the current answer to finish.",
                "いまの回答が終わるのを待っています。",
                "지금 답변이 끝나기를 기다리고 있습니다.")
        case .ownWindow:
            return localized(
                "Waiting — this window is in front. Click back into your work.",
                "このウインドウが前面のため待機中です。作業中のウインドウに戻ると見にいきます。",
                "이 윈도우가 앞에 있어 대기 중입니다. 작업 중인 윈도우로 돌아가세요.")
        case .excluded:
            return localized(
                "Not looking — the app in front is on the excluded list.",
                "前面のアプリは除外リストにあるため見ていません。",
                "앞쪽 앱이 제외 목록에 있어 보고 있지 않습니다.")
        case .nothingReadable:
            return localized(
                "Nothing readable in the window in front.",
                "前面のウインドウから読み取れるものがありません。",
                "앞쪽 윈도우에서 읽을 수 있는 것이 없습니다.")
        case .tooSoon:
            return localized("Waiting for the next look.", "次に見るまで待機中です。",
                "다음에 볼 때까지 대기 중입니다.")
        case .unchanged:
            let timeStr = Self.clock.string(from: Date())
            return localized(
                "The screen has not changed (\(timeStr)).",
                "画面に変化はありません（\(timeStr) 確認）。",
                "화면에 변화가 없습니다 (\(timeStr) 확인).")
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

/// How often the watch looks, remembered across launches.
///
/// The interval is persisted and the on/off switch is not, and the asymmetry is
/// the point: how often to look is a preference, while whether to photograph the
/// screen at all is a decision that should be made again each time the app runs.
private struct WatchPreferences {
    private let defaults: UserDefaults
    private static let key = "watch.intervalSeconds"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var interval: ScreenWatchInterval {
        get {
            ScreenWatchInterval(rawValue: defaults.integer(forKey: Self.key)) ?? .normal
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }

    private static let customRolesKey = "watch.customRoles"

    var customRoles: [WatchRole] {
        get {
            guard let data = defaults.data(forKey: Self.customRolesKey),
                  let roles = try? JSONDecoder().decode([WatchRole].self, from: data) else {
                return []
            }
            return roles
        }
        nonmutating set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Self.customRolesKey)
        }
    }
}
