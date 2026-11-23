import AppKit
import MCACore
import Observation
import OSLog
import SwiftUI

// MARK: - Pure pieces (tested)

/// Converts between the coordinate spaces the overlay straddles.
public enum AgentCursorGeometry {
    /// A global Quartz point (origin at the top-left of the primary display,
    /// y down — what `EventSynthesizer` posts) as a point inside one screen's
    /// overlay view (origin at that screen's top-left, y down — SwiftUI).
    ///
    /// - Parameters:
    ///   - screenFrame: the screen's `NSScreen.frame` (Cocoa: y up from the
    ///     primary display's bottom edge).
    ///   - primaryHeight: the primary display's height, the pivot between the
    ///     two y axes.
    public static func localPoint(
        _ quartz: CGPoint, screenFrame: CGRect, primaryHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: quartz.x - screenFrame.minX,
            y: quartz.y - (primaryHeight - screenFrame.maxY))
    }

    /// The same Quartz point in Cocoa global coordinates, to pick the screen it is on.
    public static func cocoaPoint(_ quartz: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: quartz.x, y: primaryHeight - quartz.y)
    }
}

/// When the overlay is on screen.
///
/// It appears with the agent's first input and stays for as long as the agent
/// is still working, because the gaps between actions — the model thinking
/// about the next screenshot — are part of "the AI has the controls". Once the
/// turn is over it lingers just long enough for the last click to read.
public struct AgentCursorPresence: Sendable, Equatable {
    /// Visible this long after the last input once the agent has finished.
    public var linger: TimeInterval = 1.5
    /// Hidden after this much silence even if the agent claims to be busy, so
    /// a turn that stalls (or a busy flag that never clears) cannot leave a
    /// glowing frame over the screen indefinitely.
    public var busyTimeout: TimeInterval = 120

    /// After the user presses Stop, input still in flight (a click already
    /// past its checks, a report queued on the main thread) must not bring
    /// the frame straight back.
    public var stopQuietPeriod: TimeInterval = 1.0

    public private(set) var lastInput: Date?
    public private(set) var suppressedUntil: Date?

    public init() {}

    public mutating func recordInput(at date: Date) { lastInput = date }
    public mutating func reset() { lastInput = nil }

    public mutating func stopped(at date: Date) {
        lastInput = nil
        suppressedUntil = date.addingTimeInterval(stopQuietPeriod)
    }

    /// Whether a reported input should be drawn at all. Releasing held buttons
    /// is cleanup the loop does after a stop or a failed step; on its own it is
    /// not the agent taking the controls.
    public func accepts(_ activity: AgentInputActivity, isShowing: Bool, now: Date) -> Bool {
        if let suppressedUntil, now < suppressedUntil { return false }
        if activity == .released { return isShowing }
        return true
    }

    public func isVisible(now: Date, agentBusy: Bool) -> Bool {
        guard let lastInput else { return false }
        let idle = now.timeIntervalSince(lastInput)
        return idle < (agentBusy ? busyTimeout : linger)
    }
}

// MARK: - Model

/// What the overlay views draw. Positions are global Quartz points; each
/// screen's view converts them for itself.
@MainActor
@Observable
public final class AgentCursorModel {
    public struct Ripple: Identifiable, Equatable {
        public let id = UUID()
        public let point: CGPoint
        public let secondary: Bool
        public let delay: Double
    }

    public enum Activity: Equatable { case pointing, typing, scrolling, dragging }

    public var isVisible = false
    public var cursor: CGPoint?
    public var ripples: [Ripple] = []
    public var activity: Activity = .pointing

    public init() {}

    /// Folds one reported input into what is drawn.
    public func apply(_ input: AgentInputActivity) {
        switch input {
        case .move(let point):
            cursor = point
            if activity != .dragging { activity = .pointing }
        case .click(let point, let count, let secondary):
            cursor = point
            activity = .pointing
            for index in 0..<min(max(count, 1), 3) {
                ripples.append(Ripple(point: point, secondary: secondary, delay: Double(index) * 0.09))
            }
        case .drag(let from, let to):
            ripples.append(Ripple(point: from, secondary: false, delay: 0))
            cursor = to
            activity = .dragging
        case .scroll(let point):
            cursor = point
            activity = .scrolling
        case .keyboard:
            activity = .typing
        case .released:
            activity = .pointing
        }
        // Old ripples are finished animating; keep the array from growing over a long turn.
        if ripples.count > 12 { ripples.removeFirst(ripples.count - 12) }
    }

    public func clear() {
        isVisible = false
        ripples.removeAll()
        cursor = nil
        activity = .pointing
    }
}

// MARK: - Controller

/// Shows that the agent, not the user, is driving the mouse and keyboard: a
/// glow around every screen, the agent's own pointer gliding to where it acts
/// with a ripple on each click, and a "Stop" control.
///
/// Every window here is `sharingType = .none`, so the agent's screenshots
/// never see its own pointer or the frame (they would otherwise be mistaken
/// for page content and clicked). The frame and pointer windows ignore the
/// mouse entirely. The stop pill takes clicks only while the user's own
/// pointer is over it, and refuses any click or Esc the agent itself
/// synthesized (`AgentInputFeedback.eventSourceTag`).
@MainActor
public final class AgentCursorOverlay {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "AgentCursor")
    private let isAgentBusy: @MainActor () -> Bool
    private let onStop: @MainActor () -> Void
    public let model = AgentCursorModel()

    private var presence = AgentCursorPresence()
    private var screenPanels: [NSPanel] = []
    private var stopPanel: NSPanel?
    private var ticker: Timer?
    private var hideWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var monitors: [Any] = []

    public init(isAgentBusy: @escaping @MainActor () -> Bool, onStop: @escaping @MainActor () -> Void) {
        self.isAgentBusy = isAgentBusy
        self.onStop = onStop
    }

    /// Starts listening for the agent's input. Nothing is drawn until it acts.
    public func start() {
        AgentInputFeedback.install { [weak self] activity in
            // Reported on the synthesizing thread; never block it. The main
            // queue is FIFO, so reports are drawn in the order they were sent.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(activity) }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildIfVisible() }
        }
    }

    public func stop() {
        AgentInputFeedback.install(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDown()
    }

    // MARK: Input

    func receive(_ activity: AgentInputActivity) {
        let now = Date()
        guard presence.accepts(activity, isShowing: model.isVisible, now: now) else { return }
        presence.recordInput(at: now)
        if !model.isVisible {
            // Still fading out from the last turn: start from here, not from there.
            model.cursor = nil
            show()
        }
        // The agent's pointer moved the real one away from wherever the user had it.
        if activity != .keyboard { stopPanel?.ignoresMouseEvents = true }
        // The pointer appears at the first point rather than flying in from nowhere.
        let wasHidden = model.cursor == nil
        if wasHidden {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { model.apply(activity) }
        } else {
            model.apply(activity)
        }
        if let cursor = model.cursor { placeStopPill(near: cursor) }
    }

    // MARK: Visibility

    private func show() {
        hideWork?.cancel()
        hideWork = nil
        if screenPanels.isEmpty { buildPanels() }
        for panel in screenPanels { panel.orderFrontRegardless() }
        stopPanel?.orderFrontRegardless()
        installMonitors()
        model.isVisible = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        log.debug("Agent cursor overlay shown")
    }

    private func tick() {
        guard model.isVisible else { return }
        if !presence.isVisible(now: Date(), agentBusy: isAgentBusy()) { hide() }
    }

    private func hide() {
        ticker?.invalidate()
        ticker = nil
        removeMonitors()
        presence.reset()
        model.isVisible = false // fades out in the views
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isVisible else { return }
                self.model.clear()
                self.tearDown()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func requestStop() {
        log.info("Stop requested from the agent cursor overlay")
        onStop()
        hide()
        presence.stopped(at: Date())
    }

    private func tearDown() {
        ticker?.invalidate()
        ticker = nil
        removeMonitors()
        for panel in screenPanels { panel.orderOut(nil); panel.close() }
        screenPanels.removeAll()
        stopPanel?.orderOut(nil)
        stopPanel?.close()
        stopPanel = nil
    }

    private func rebuildIfVisible() {
        guard model.isVisible else { return }
        for panel in screenPanels { panel.orderOut(nil); panel.close() }
        screenPanels.removeAll()
        buildPanels()
        for panel in screenPanels { panel.orderFrontRegardless() }
        if let cursor = model.cursor { placeStopPill(near: cursor) }
    }

    // MARK: Windows

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func buildPanels() {
        let primaryHeight = Self.primaryHeight
        for screen in NSScreen.screens {
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.configureAsOverlay()
            panel.ignoresMouseEvents = true
            // Above menus and the agent's own floating windows: the pointer must
            // be visible wherever the agent clicks, including an open menu.
            panel.level = .screenSaver
            panel.setFrame(screen.frame, display: false)
            let view = AgentCursorScreenView(
                model: model, screenFrame: screen.frame, primaryHeight: primaryHeight)
            let hosting = NSHostingView(rootView: view)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            screenPanels.append(panel)
        }

        let pill = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        pill.configureAsOverlay()
        pill.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        // Click-through unless the user's own pointer is on it (see
        // `installMonitors`): the agent cannot see the pill, and a click it
        // aims at a tab or title bar underneath must reach that tab.
        pill.ignoresMouseEvents = true
        let hosting = FirstMouseHostingView(rootView: AgentStopPill(model: model) { [weak self] in
            // The agent cannot see this button, but a click it aims at whatever
            // is underneath could still land on it. Only a person's click stops.
            if let event = NSApp.currentEvent?.cgEvent,
               AgentInputFeedback.isAgentGenerated(
                userData: event.getIntegerValueField(.eventSourceUserData)) {
                return
            }
            self?.requestStop()
        })
        hosting.autoresizingMask = [.width, .height]
        pill.contentView = hosting
        stopPanel = pill
        if let cursor = model.cursor { placeStopPill(near: cursor) }
    }

    /// Top-centre of whichever screen the agent is acting on, under the menu bar.
    private func placeStopPill(near quartz: CGPoint) {
        guard let pill = stopPanel else { return }
        let cocoa = AgentCursorGeometry.cocoaPoint(quartz, primaryHeight: Self.primaryHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = pill.contentView?.fittingSize ?? NSSize(width: 300, height: 44)
        let frame = NSRect(
            x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10,
            width: size.width, height: size.height)
        if pill.frame != frame { pill.setFrame(frame, display: true) }
    }

    // MARK: Esc to stop, and a Stop pill only the user can reach

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Values, not the NSEvent itself, cross into the main-actor handler.
        let handler: @MainActor (UInt16, Int64) -> Bool = { [weak self] keyCode, userData in
            guard keyCode == 53, // Escape
                  !AgentInputFeedback.isAgentGenerated(userData: userData) else { return false }
            self?.requestStop()
            return true
        }
        func fields(_ event: NSEvent) -> (UInt16, Int64) {
            (event.keyCode, event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
        }
        // Global: Esc pressed in whatever app the agent is driving (needs the
        // Accessibility permission the agent already holds to act at all).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            let (keyCode, userData) = fields(event)
            MainActor.assumeIsolated { _ = handler(keyCode, userData) }
        }) {
            monitors.append(global)
        }
        // Local: Esc pressed while one of this app's own windows has focus.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let (keyCode, userData) = fields(event)
            let consumed = MainActor.assumeIsolated { handler(keyCode, userData) }
            return consumed ? nil : event
        }) {
            monitors.append(local)
        }

        // The pill takes clicks only while the user's own pointer is over it.
        let pointer: @MainActor (Int64) -> Void = { [weak self] userData in
            guard let pill = self?.stopPanel,
                  !AgentInputFeedback.isAgentGenerated(userData: userData) else { return }
            let over = pill.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
            if pill.ignoresMouseEvents == over { pill.ignoresMouseEvents = !over }
        }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { event in
            let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            MainActor.assumeIsolated { pointer(userData) }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        stopPanel?.ignoresMouseEvents = true
    }
}

/// A borderless panel that never takes key focus away from the app the agent
/// is operating, never shows in screenshots and follows the user across Spaces.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configureAsOverlay() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
    }
}

/// A click on a panel that is not key goes straight to the button instead of
/// being spent on focusing the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private enum AgentCursorStyle {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.66, green: 0.33, blue: 0.97),
                 Color(red: 0.96, green: 0.38, blue: 0.62)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let secondary = Color(red: 0.98, green: 0.62, blue: 0.22)
}

struct AgentCursorScreenView: View {
    let model: AgentCursorModel
    let screenFrame: CGRect
    let primaryHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            AgentScreenGlow(reduceMotion: reduceMotion)

            ForEach(model.ripples) { ripple in
                AgentClickRipple(secondary: ripple.secondary, delay: ripple.delay)
                    .position(local(ripple.point))
            }

            if let cursor = model.cursor {
                AgentPointer(activity: model.activity)
                    // The view's origin is the arrow's tip.
                    .offset(x: local(cursor).x, y: local(cursor).y)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
                        value: cursor)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: model.isVisible)
        .allowsHitTesting(false)
    }

    private func local(_ point: CGPoint) -> CGPoint {
        AgentCursorGeometry.localPoint(point, screenFrame: screenFrame, primaryHeight: primaryHeight)
    }
}

/// A soft coloured frame hugging the screen edge: "this display is being driven".
private struct AgentScreenGlow: View {
    let reduceMotion: Bool
    @State private var breathing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.strokeBorder(AgentCursorStyle.gradient, lineWidth: 14).blur(radius: 18).opacity(0.75)
            shape.strokeBorder(AgentCursorStyle.gradient, lineWidth: 3).blur(radius: 2)
            shape.strokeBorder(AgentCursorStyle.gradient, lineWidth: 1.5)
        }
        .opacity(breathing ? 1 : 0.6)
        .onAppear {
            guard !reduceMotion else { breathing = true; return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// The classic macOS arrow, so it reads as "a pointer" at a glance, but in the
/// agent's colours and with a name tag beside it.
private struct AgentPointer: View {
    let activity: AgentCursorModel.Activity

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArrowShape()
                .fill(AgentCursorStyle.gradient)
                .overlay(ArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
                .frame(width: 22, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
                .shadow(color: Color(red: 0.66, green: 0.33, blue: 0.97).opacity(0.6), radius: 10)

            AgentTag(activity: activity)
                .fixedSize()
                .offset(x: 20, y: 26)
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }
}

private struct AgentTag: View {
    let activity: AgentCursorModel.Activity

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(AgentCursorStyle.gradient))
        .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.15), value: activity)
    }

    private var symbol: String {
        switch activity {
        case .pointing: "sparkles"
        case .typing: "keyboard"
        case .scrolling: "arrow.up.and.down"
        case .dragging: "hand.draw"
        }
    }

    private var label: String {
        switch activity {
        case .pointing: localized("AI", "AI", "AI")
        case .typing: localized("Typing", "入力中", "입력 중")
        case .scrolling: localized("Scrolling", "スクロール", "스크롤")
        case .dragging: localized("Dragging", "ドラッグ", "드래그")
        }
    }
}

/// The outline of the system arrow cursor, tip at the origin.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.80))
        path.addLine(to: CGPoint(x: w * 0.25, y: h * 0.61))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.98))
        path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.91))
        path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.56))
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.56))
        path.closeSubpath()
        return path
    }
}

private struct AgentClickRipple: View {
    let secondary: Bool
    let delay: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(secondary ? AnyShapeStyle(AgentCursorStyle.secondary) : AnyShapeStyle(AgentCursorStyle.gradient),
                    lineWidth: expanded ? 1 : 4)
            .frame(width: expanded ? 64 : 10, height: expanded ? 64 : 10)
            .opacity(expanded ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55).delay(delay)) { expanded = true }
            }
    }
}

/// "AI is operating — Stop (esc)" at the top of the screen being driven.
struct AgentStopPill: View {
    let model: AgentCursorModel
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AgentCursorStyle.gradient)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isVisible)
            Text(localized("AI is using your computer", "AI が操作中", "AI가 조작 중"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Text(localized("Stop", "停止", "중지")).font(.system(size: 12, weight: .semibold))
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.25)))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .help(localized("Stop the agent (esc)", "AI の操作を止める (esc)", "AI 조작 중지 (esc)"))
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(AgentCursorStyle.gradient, lineWidth: 1.2))
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .padding(6)
        .fixedSize()
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: model.isVisible)
    }
}
