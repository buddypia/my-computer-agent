import AppKit
import CoreGraphics
import MCACore
import OSLog
import SwiftUI

/// Which list the picker is showing.
///
/// The same split every screen-sharing dialog on this platform makes, and for
/// the same reason: "a window" and "a whole screen" are answers to different
/// questions, and mixing forty of the first with two of the second buries the
/// second.
public enum ScreenPickerScope: String, CaseIterable, Sendable {
    case windows
    case displays

    @MainActor
    var title: String {
        switch self {
        case .windows: return localized("Windows", "ウインドウ", "윈도우")
        case .displays: return localized("Entire screen", "画面全体", "화면 전체")
        }
    }
}

/// Choosing what the agent looks at, by looking at it.
///
/// The list this replaces named windows and nothing else, which is the one thing
/// a window is worst identified by: four Chrome windows are four rows reading
/// "Google Chrome", and the title of the one that matters is a truncated URL.
/// What a person actually recognises is the picture — which is why every
/// screen-sharing dialog shows one, and why this does too.
///
/// The thumbnails are re-photographed while the picker is open rather than taken
/// once. A still from thirty seconds ago is not a preview, it is a claim about
/// the past, and the interesting case here — "which of these two terminals is
/// the build running in" — is exactly the one a stale frame gets wrong.
public struct ScreenPickerView: View {
    @Bindable var state: HUDState

    /// Everything that could be watched. Asynchronous because the window list
    /// comes from ScreenCaptureKit.
    var onList: (() async -> WatchTargetList)?
    /// Thumbnails for the tiles on screen, keyed by `WatchTarget.key`. Anything
    /// that has gone, or that the privacy list forbids photographing, is simply
    /// absent from what comes back.
    var onPreviews: (([WatchTarget]) async -> [String: CGImage])?
    var onChoose: ((WatchTarget) -> Void)?
    var onChooseItems: (([WatchItem]) -> Void)?
    var onClose: (() -> Void)?

    @State private var targets: WatchTargetList = .empty
    /// Thumbnails, keyed by `WatchTarget.key` so a window that renames itself
    /// between two refreshes keeps the picture it already had.
    @State private var previews: [String: CGImage] = [:]
    @State private var selection: WatchTarget = .focused
    @State private var selectedItems: [String: WatchItem] = [:]
    @State private var editingItem: WatchItem? = nil
    @State private var scope: ScreenPickerScope = .windows
    @State private var isLoading = false
    /// Whether a list has come back at least once. Distinguishes "no windows"
    /// from "not asked yet", which look the same and mean opposite things.
    @State private var hasLoaded = false

    /// How often the thumbnails are taken again while the picker is open.
    ///
    /// Slow enough that a grid of a dozen windows is a background cost rather
    /// than a fan, fast enough that the preview is recognisably the present.
    private static let refreshInterval = Duration.seconds(3)

    public init(
        state: HUDState,
        onList: (() async -> WatchTargetList)? = nil,
        onPreviews: (([WatchTarget]) async -> [String: CGImage])? = nil,
        onChoose: ((WatchTarget) -> Void)? = nil,
        onChooseItems: (([WatchItem]) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.state = state
        self.onList = onList
        self.onPreviews = onPreviews
        self.onChoose = onChoose
        self.onChooseItems = onChooseItems
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingItem) { item in
            CustomPromptSheet(
                item: item,
                onSave: { updated in
                    if updated.customPromptOverride != nil {
                        let customRole = WatchRole(
                            id: updated.role.isBuiltin ? "custom.\(UUID().uuidString.prefix(8))" : updated.role.id,
                            name: updated.role.name,
                            icon: updated.role.icon,
                            systemPrompt: updated.effectivePrompt,
                            triggerKind: updated.role.triggerKind,
                            defaultInterval: updated.role.defaultInterval,
                            isBuiltin: false
                        )
                        state.addCustomRole(customRole)
                        var itemWithRole = updated
                        itemWithRole.role = customRole
                        selectedItems[updated.targetKey] = itemWithRole
                    } else {
                        selectedItems[updated.targetKey] = updated
                    }
                },
                onDismiss: {
                    editingItem = nil
                })
        }
        .task { await live() }
        .onAppear {
            // Restore from state.watchItems
            for item in state.watchItems {
                selectedItems[item.targetKey] = item
            }
        }
        .onChange(of: scope) { Task { await refreshPreviews() } }
        // Re-opening the window does not rebuild the view — it was only ordered
        // out — so without this the user would be shown the grid they left,
        // windows that have since closed and all.
        .onChange(of: state.isScreenPickerOpen) {
            if state.isScreenPickerOpen { Task { await reload() } }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized(
                    "What should the agent look at?",
                    "エージェントに見せる画面",
                    "에이전트에게 보여줄 화면"))
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView().controlSize(.small)
                }

                Button { Task { await reload() } } label: {
                    Label(
                        localized("Refresh", "更新", "새로 고침"),
                        systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localized(
                    "Take the list and the previews again",
                    "一覧とプレビューを取り直します",
                    "목록과 미리보기를 다시 가져옵니다"))
            }

            Text(currentSubjectLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("", selection: $scope) {
                ForEach(ScreenPickerScope.allCases, id: \.rawValue) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// What the agent is looking at right now, said in the picker that changes
    /// it. Without it the grid is a set of options with no indication of which
    /// one is already in force.
    private var currentSubjectLine: String {
        guard let subject = state.watchTarget.subjectName else {
            return localized(
                "Now following whatever window is in front.",
                "いまは前面のウインドウを追いかけています。",
                "지금은 앞쪽 윈도우를 따라가고 있습니다.")
        }
        return localized(
            "Now watching \(subject).",
            "いま見張っているのは \(subject) です。",
            "지금 지켜보는 대상: \(subject).")
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 14)],
                spacing: 14
            ) {
                ForEach(visibleTargets, id: \.key) { target in
                    tile(target)
                }
            }
            .padding(16)

            if visibleTargets.isEmpty {
                emptyState
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleTargets: [WatchTarget] {
        switch scope {
        case .windows: return targets.windows.map(WatchTarget.pinned)
        case .displays: return targets.displays.map(WatchTarget.display)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !hasLoaded {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized(
                    "Nothing here to choose from.",
                    "選べるものがありません。",
                    "고를 수 있는 것이 없습니다."))
                    .font(.system(size: 12, weight: .medium))
                Text(localized(
                    """
                    Windows only appear once Screen Recording is granted — open \
                    ✨ ▸ Settings ▸ Permissions. Apps on the exclusion list are \
                    left out on purpose.
                    """,
                    """
                    ウインドウは画面収録を許可してから表示されます。✨ ▸ 設定 ▸ 権限 を\
                    開いてください。除外リストのアプリは意図的に出していません。
                    """,
                    """
                    윈도우는 화면 기록을 허용해야 표시됩니다. ✨ ▸ 설정 ▸ 권한 을 \
                    열어 주세요. 제외 목록의 앱은 일부러 표시하지 않습니다.
                    """))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One candidate: its picture, its name, and whether it is the one in force.
    ///
    /// A single click selects and a double click applies, which is what a grid
    /// of pictures in this shape means everywhere else on the platform. The
    /// button below is the discoverable half of the same act.
    private func tile(_ target: WatchTarget) -> some View {
        let isSelected = selection.key == target.key
        let isWatchedInMulti = selectedItems[target.key]?.isEnabled ?? false
        let isCurrent = state.watchTarget.key == target.key || isWatchedInMulti
        let currentItem = selectedItems[target.key]

        return Button { selection = target } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    thumbnail(target)

                    Button {
                        toggleItem(target)
                    } label: {
                        Image(systemName: isWatchedInMulti ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(isWatchedInMulti ? Color.accentColor : Color.white.opacity(0.8))
                            .padding(5)
                            .background(Color.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                }

                caption(target, isCurrent: isCurrent)

                roleSelector(for: target, item: currentItem)
            }
            .padding(7)
            .background(
                isSelected ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isSelected ? Color.accentColor : (isWatchedInMulti ? Color.accentColor.opacity(0.5) : Color.clear),
                        lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { apply(target) })
        .help(target.subjectName ?? "")
        .accessibilityLabel(target.subjectName ?? "")
    }

    private func roleSelector(for target: WatchTarget, item: WatchItem?) -> some View {
        let activeRole = item?.role ?? .general
        let isCustomPrompt = item?.customPromptOverride?.isEmpty == false

        return HStack(spacing: 4) {
            Image(systemName: activeRole.icon)
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)

            Menu {
                Text(localized("Purpose & System Prompt", "見守りの目的 (System Prompt)", "지켜보기 목적"))
                Divider()
                ForEach(state.availableRoles) { role in
                    Button {
                        setRole(role, for: target)
                    } label: {
                        Label(role.name, systemImage: role.icon)
                    }
                }
                Divider()
                Button {
                    editingItem = item ?? WatchItem(target: target, role: activeRole)
                } label: {
                    Label(
                        localized("Custom System Prompt…", "カスタム目的を編集…", "사용자 지정 목적 편집…"),
                        systemImage: "pencil")
                }
            } label: {
                HStack(spacing: 3) {
                    Text(isCustomPrompt ? "\(activeRole.name)*" : activeRole.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()
        }
    }

    private func toggleItem(_ target: WatchTarget) {
        if var existing = selectedItems[target.key] {
            existing.isEnabled.toggle()
            if !existing.isEnabled {
                selectedItems.removeValue(forKey: target.key)
            } else {
                selectedItems[target.key] = existing
            }
        } else {
            selectedItems[target.key] = WatchItem(target: target, role: .general, isEnabled: true)
        }
    }

    private func setRole(_ role: WatchRole, for target: WatchTarget) {
        if var existing = selectedItems[target.key] {
            existing.role = role
            existing.isEnabled = true
            selectedItems[target.key] = existing
        } else {
            selectedItems[target.key] = WatchItem(target: target, role: role, isEnabled: true)
        }
    }

    private func thumbnail(_ target: WatchTarget) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.black.opacity(0.28))

            if let image = previews[target.key] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                // Not a spinner: a tile that spins forever is how a window that
                // cannot be photographed at all would look, and most of these
                // fill in within a frame or two anyway.
                Image(systemName: target.pinnedDisplay == nil ? "macwindow" : "display")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 108)
        .frame(maxWidth: .infinity)
    }

    private func caption(_ target: WatchTarget, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The app's own icon, which is how someone finds the window they
            // mean before they have read a word of the label. A thumbnail of a
            // terminal and a thumbnail of an editor are both mostly text at this
            // size; the icons are not.
            if let icon = appIcon(target) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryName(target))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let detail = secondaryName(target), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.mint)
                    .help(localized(
                        "This is what the agent is watching now",
                        "いまエージェントが見ている対象です",
                        "지금 에이전트가 보고 있는 대상입니다"))
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 2)
    }

    /// The icon of the application a window belongs to, if it can be found.
    ///
    /// By bundle identifier rather than by name: the name is what the picker
    /// already shows, and two applications are allowed to share one.
    private func appIcon(_ target: WatchTarget) -> NSImage? {
        guard let bundleID = target.pinnedWindow?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func primaryName(_ target: WatchTarget) -> String {
        switch target {
        case .focused:
            return localized("Focused window", "前面のウインドウ", "앞쪽 윈도우")
        case .pinned(let window): return window.appName
        case .display(let display): return display.displayName
        }
    }

    private func secondaryName(_ target: WatchTarget) -> String? {
        switch target {
        case .focused: return nil
        case .pinned(let window): return window.windowTitle
        case .display(let display): return display.resolution
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // The third answer, and the one a grid cannot show a picture of:
            // "whatever I happen to be doing" has no thumbnail because it is not
            // one window. It stays on screen next to the grid rather than being
            // a row inside it, so going back to it is never buried under forty
            // windows in the other tab.
            Button { apply(.focused) } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.watchTarget.isPinned ? "circle" : "largecircle.fill.circle")
                        .font(.system(size: 11))
                    Text(localized(
                        "Follow the focused window",
                        "前面のウインドウを追う",
                        "앞쪽 윈도우를 따라가기"))
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.watchTarget.isPinned ? Color.secondary : Color.accentColor)
            .help(localized(
                "Stops while this app is in front",
                "このアプリが前面のあいだは止まります",
                "이 앱이 앞에 있는 동안에는 멈춥니다"))

            Spacer(minLength: 12)

            Button { onClose?() } label: {
                Text(localized("Cancel", "キャンセル", "취소"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            if !selectedItems.isEmpty {
                Button { applyMultiple() } label: {
                    Text(localized(
                        "Watch \(selectedItems.count) targets",
                        "\(selectedItems.count) 画面を見守り開始",
                        "\(selectedItems.count)개 화면 지켜보기 시작"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                Button { apply(selection) } label: {
                    Text(localized("Watch this", "この画面を見る", "이 화면 보기"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            selection.isPinned ? Color.accentColor : Color.secondary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!selection.isPinned)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Loading

    private func applyMultiple() {
        let items = Array(selectedItems.values.filter(\.isEnabled))
        if let onChooseItems {
            onChooseItems(items)
        } else if let first = items.first {
            // Fallback for single target
            if let window = targets.windows.first(where: { "window:\($0.id)" == first.targetKey }) {
                onChoose?(.pinned(window))
            } else if let display = targets.displays.first(where: { "display:\($0.id)" == first.targetKey }) {
                onChoose?(.display(display))
            }
        }
        onClose?()
    }

    /// Applies a choice and gets out of the way.
    private func apply(_ target: WatchTarget) {
        selectedItems.removeAll()
        onChooseItems?([])
        onChoose?(target)
        onClose?()
    }

    /// Fills the grid, then keeps it honest for as long as it is on screen.
    private func live() async {
        await reload()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            guard !Task.isCancelled else { return }
            // The window is only ordered out when it closes, so this view stays
            // alive with its task running. Photographing the user's screen every
            // three seconds for a window nobody is looking at is exactly the
            // behaviour this app exists not to have.
            guard state.isScreenPickerOpen else { continue }
            await refreshPreviews()
        }
    }

    private func reload() async {
        isLoading = true
        let list = await onList?() ?? .empty
        targets = list
        hasLoaded = true
        // Synchronize selectedItems with active watchItems from state
        for item in state.watchItems {
            selectedItems[item.targetKey] = item
        }
        // Open on the tab the current subject is in, and fall back to whichever
        // one has anything in it. A picker that opens on an empty "Windows" tab
        // while two displays sit in the other one reads as broken.
        scope = preferredScope(for: list)
        selection = state.watchTarget
        isLoading = false
        await refreshPreviews()
    }

    private func preferredScope(for list: WatchTargetList) -> ScreenPickerScope {
        if state.watchTarget.pinnedDisplay != nil { return .displays }
        if list.windows.isEmpty && !list.displays.isEmpty { return .displays }
        return .windows
    }

    /// Re-photographs what is on screen.
    ///
    /// Merged rather than assigned, for two reasons. A target that failed this
    /// time round keeps the last picture that worked, so a window that is
    /// momentarily unphotographable does not blink out from under the pointer;
    /// and the tab that is not on screen keeps its pictures for when the user
    /// switches back. Only the visible tab is asked for, since photographing
    /// tiles nobody is looking at is the cost this loop exists to avoid.
    private func refreshPreviews() async {
        guard let onPreviews else { return }
        let fresh = await onPreviews(visibleTargets)
        guard !Task.isCancelled else { return }
        previews.merge(fresh) { _, new in new }
    }
}

/// The window the picker lives in.
///
/// A real window rather than a popover hanging off a button, which is what the
/// old list was. A popover is sized by whatever it is anchored to and dies on
/// the first click elsewhere — and this grid is a thing people scroll, resize
/// and look back and forth between, with the window they are trying to identify
/// sitting behind it.
@MainActor
public final class ScreenPickerWindow: NSObject, NSWindowDelegate {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "ScreenPicker")
    private let state: HUDState
    private var window: NSPanel?
    private var callbacks: Callbacks

    public struct Callbacks {
        public var onList: (() async -> WatchTargetList)?
        public var onPreviews: (([WatchTarget]) async -> [String: CGImage])?
        public var onChoose: ((WatchTarget) -> Void)?
        public var onChooseItems: (([WatchItem]) -> Void)?

        public init() {}
    }

    private static let size = CGSize(width: 760, height: 560)

    public init(state: HUDState) {
        self.state = state
        self.callbacks = Callbacks()
        super.init()
    }

    /// Late wiring, for a composition root that builds this before the watch it
    /// drives exists.
    public func setCallbacks(_ callbacks: Callbacks) {
        self.callbacks = callbacks
        if let window {
            window.contentView = NSHostingView(rootView: makeView())
        }
    }

    public var isOpen: Bool { window?.isVisible == true }

    public func present() {
        // Before the window is built, not after. This is what the view watches
        // to know it is on screen again, and flipping it afterwards would make a
        // view that has only just loaded its grid immediately reload it.
        state.isScreenPickerOpen = true
        let window = makeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        // `.accessory` activation policy: the app is never frontmost on its own,
        // and a picker that opens behind the windows it is a picker *of* has
        // failed at its one job.
        NSApp.activate(ignoringOtherApps: true)
        log.debug("Screen picker presented")
    }

    public func close() {
        window?.performClose(nil)
    }

    public func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            close()
        } else {
            present()
        }
    }

    public func destroy() {
        window?.delegate = nil
        window?.close()
        window = nil
        state.isScreenPickerOpen = false
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        state.isScreenPickerOpen = false
    }

    // MARK: - Internals

    private func makeWindowIfNeeded() -> NSPanel {
        if let window { return window }

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        window.title = localized(
            "Copilot — Choose a screen",
            "Copilot — 見せる画面を選ぶ",
            "Copilot — 보여줄 화면 선택")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 420)
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        // Never captured — this window is full of pictures of the user's other
        // windows, and letting it into a frame would hand the agent a hall of
        // mirrors instead of a screen.
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: makeView())

        let name = NSWindow.FrameAutosaveName("com.buddypia.mca.screenpicker")
        window.setFrameAutosaveName(name)
        if !window.setFrameUsingName(name) { center(window) }

        self.window = window
        return window
    }

    private func makeView() -> ScreenPickerView {
        ScreenPickerView(
            state: state,
            onList: { [weak self] in await self?.callbacks.onList?() ?? .empty },
            onPreviews: { [weak self] targets in
                await self?.callbacks.onPreviews?(targets) ?? [:]
            },
            onChoose: { [weak self] target in self?.callbacks.onChoose?(target) },
            onChooseItems: { [weak self] items in self?.callbacks.onChooseItems?(items) },
            onClose: { [weak self] in self?.close() })
    }

    /// Centres on the screen the pointer is on. `NSWindow.center()` uses the
    /// display with the menu bar, which on a two-monitor Mac is routinely not
    /// the one being worked on.
    private func center(_ window: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.04))
    }
}

/// Modal sheet to edit or customize a role's system prompt for a specific target.
struct CustomPromptSheet: View {
    let item: WatchItem
    var onSave: (WatchItem) -> Void
    var onDismiss: () -> Void

    @State private var name: String = ""
    @State private var promptText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Custom System Prompt for Screen", "画面ごとの目的 (System Prompt) 編集", "화면별 목적 편집"))
                .font(.headline)

            Text("\(localized("Target", "対象画面", "대상")): \(item.targetName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Role Name", "目的の名称", "목적 이름"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(localized("e.g. Meeting Assistant, AI CLI Monitor", "例: ミーティング支援, AI CLI開発見守り", "예: 회의 지원, AI CLI 개발 모니터링"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(localized("System Prompt (Instructions)", "System Prompt（見守り時の具体的な指示）", "System Prompt (지켜보기 지시)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $promptText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 140)
                    .padding(4)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    }
            }

            HStack {
                Button(localized("Cancel", "キャンセル", "취소")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(localized("Save", "保存して適用", "저장")) {
                    var updated = item
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        updated.role.name = name
                    }
                    updated.customPromptOverride = promptText
                    onSave(updated)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            name = item.role.name
            promptText = item.customPromptOverride ?? item.role.systemPrompt
        }
    }
}
