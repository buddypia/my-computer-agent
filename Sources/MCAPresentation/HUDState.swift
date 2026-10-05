import Foundation
import MCACore
import Observation
import SwiftUI

/// Something the app has to say, as its call sites name it: a headline, a body
/// and how loud it is.
///
/// A dozen places build one of these, which is why the shape survived the move
/// to a single thread — but it is no longer a second list of its own. `present`
/// turns it into a `ChatMessage` and it is drawn as a bubble like everything
/// else. Severity mirrors `MCAReasoning.AgentCard` without this layer depending
/// on the reasoning layer.
public struct HUDCard: Identifiable, Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case info, suggestion, warning, error, actionItem

        var tint: Color {
            switch self {
            case .info: return .cyan
            case .suggestion: return .mint
            case .warning: return .orange
            case .error: return .red
            case .actionItem: return .purple
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .suggestion: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .actionItem: return "checklist"
            }
        }
    }

    public var id: UUID
    public var title: String
    public var body: String
    public var severity: Severity
    public var timestamp: Date

    public init(
        id: UUID = UUID(), title: String, body: String,
        severity: Severity = .info, timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.severity = severity
        self.timestamp = timestamp
    }
}

/// How far along a live voice session is.
///
/// Three states rather than a boolean because opening one is not instant: the
/// socket has to connect and the server has to acknowledge the setup. A boolean
/// forced that gap to be reported as either "off" — the button appearing to do
/// nothing — or "on", which is what actually shipped, so a session that failed
/// during setup showed as active and then flipped back with nothing said.
public enum VoicePhase: Sendable, Equatable {
    case off
    case connecting
    case live
}

/// Observable state backing the panel.
///
/// Main-actor isolated because every mutation ends in a SwiftUI update; the
/// agent pushes into it from background actors via `MainActor.run`.
@MainActor
@Observable
public final class HUDState {
    /// Tokens of the answer currently streaming in.
    public var streamingText: String = ""
    public var isStreaming: Bool = false
    /// Tokens buffered before being merged into `streamingText` on a throttle interval.
    @ObservationIgnored private var tokenBuffer: String = ""
    @ObservationIgnored private var tokenFlushTask: Task<Void, Never>? = nil
    @ObservationIgnored private var lastTokenFlushTime: ContinuousClock.Instant? = nil
    /// The throttle interval for updating `streamingText` during streaming.
    /// Defaults to 40ms (~25 FPS), protecting the MainActor and SwiftUI layout engine
    /// from high-frequency token churn.
    @ObservationIgnored public var tokenThrottleInterval: Duration = .milliseconds(40)
    public var focusedApp: String = "—"
    public var health: HealthReport = HealthReport()
    public var isClickThrough: Bool = false
    public var isListening: Bool = false
    public var voicePhase: VoicePhase = .off
    /// Which of the two voice modes the button starts. Mirrored here from the
    /// stored preference so every surface — the panel, the chat toolbar, the
    /// menu bar and the caption — reads the same value.
    public var voiceMode: VoiceMode = .realtime
    /// What the session heard and will not revise again.
    ///
    /// On screen because a session that is connected but not hearing anything
    /// is otherwise indistinguishable from one that is working — the difference
    /// lives at the far end of a socket. Seeing your own words come back is the
    /// only local evidence the microphone is reaching the model.
    public private(set) var voiceTranscriptSettled: String = ""
    /// The engine's current guess at the words being spoken right now, which it
    /// may still replace.
    ///
    /// Kept apart from the settled text rather than concatenated into it so the
    /// two can be drawn differently. They are different claims — "this is what
    /// you said" versus "this is what you might be saying" — and a caption that
    /// renders them identically makes every mid-sentence revision look like the
    /// recogniser getting it wrong.
    public private(set) var voiceTranscriptPending: String = ""
    /// Everything heard in this utterance, settled and not. What most surfaces
    /// want, and what the caption falls back to when it cannot style the two
    /// halves separately.
    public var voiceTranscript: String {
        if voiceTranscriptPending.isEmpty { return voiceTranscriptSettled }
        if voiceTranscriptSettled.isEmpty { return voiceTranscriptPending }
        let cleanPending = DictationBuffer.stripOverlap(settled: voiceTranscriptSettled, from: voiceTranscriptPending)
        return voiceTranscriptSettled + cleanPending
    }
    /// What the live model searched the web for on this turn.
    ///
    /// Shown because a spoken answer gives no indication of where it came from.
    /// A claim about something that happened last week is worth more when the
    /// user can see it was looked up rather than recalled.
    public var voiceSearchQueries: [String] = []
    /// Whether the spoken words are drawn large across the bottom of the screen.
    public var showsVoiceCaption: Bool = true
    /// Whether a live voice session is fully up. Derived, so no call site can
    /// claim one is running while it is still connecting.
    public var liveSessionActive: Bool { voicePhase == .live }
    /// Whether the user has opted into the desktop panel. Off — the default —
    /// the same content is reachable from the ✨ menu bar item instead, and
    /// nothing sits on top of the user's work uninvited.
    public var isAlwaysVisible: Bool = false
    /// Whether the panel window is on screen. Mirrored here so the menu bar
    /// and the HUD itself can render the current state without asking AppKit.
    public var isVisible: Bool = false
    /// Whether the menu bar popover is open. Cards that arrive while it is are
    /// already in front of the user, so they must not also be counted unread.
    public var isPopoverOpen: Bool = false
    /// Whether the chat window is on screen. Counts as a surface for the same
    /// reason the popover does.
    public var isChatOpen: Bool = false
    /// Whether the screen picker is on screen.
    ///
    /// Not a surface for cards — it shows none — but the picker keeps its
    /// thumbnails alive by re-photographing them, and that loop must stop the
    /// moment the window goes away. A closed window that is only ordered out
    /// leaves its SwiftUI view alive, so the view cannot tell on its own.
    public var isScreenPickerOpen: Bool = false
    /// Collapsed to a small title bar. The middle ground between a full panel
    /// in the corner of the screen and nothing at all — the agent keeps
    /// running and can still be expanded with one click.
    public var isCollapsed: Bool = false
    /// Whether the panel stays in front of every other window. Off, it behaves
    /// like an ordinary window and can be covered.
    public var isFloating: Bool = true
    /// Which screen corner the panel anchors to.
    public var corner: HUDCorner = .topRight
    /// One line of shortcut help for the empty state, rendered from the live
    /// bindings. Held here rather than built in the view because the view has
    /// no business knowing about `HotKeyCenter`, and a hard-coded chord list
    /// becomes a lie the moment anything is rebound.
    public var shortcutHint: String = ""
    /// Turns that arrived while nothing was on screen. Hiding must not mean
    /// silently dropping what the agent found — the count surfaces in the menu
    /// bar so the user can decide whether to look.
    public var unseenMessages: Int = 0

    // MARK: - Chat

    /// The conversation, oldest first. The single thing all three surfaces draw.
    ///
    /// Kept in order: an answer without the question above it is unreadable. The
    /// ring is long enough that a session's worth of turns survives and short
    /// enough that it cannot grow without bound.
    public var messages: [ChatMessage] = []
    public var onStopTask: (@MainActor () -> Void)?
    @ObservationIgnored private var approvalWaiters: [UUID: CheckedContinuation<ActionApprovalStatus, Never>] = [:]
    @ObservationIgnored private var approvalTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var approvalDeadlines: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let approvalSleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    public var isAwaitingApproval: Bool { !approvalWaiters.isEmpty }

    /// Approval controls resolve only the matching waiter, once. They cannot
    /// execute payload text or grant permission to a later operation.
    public func requestApproval(_ request: ActionApprovalRequest,
                                timeout: Duration = .seconds(300)) async -> ActionApprovalStatus {
        guard !Task.isCancelled, approvalWaiters.isEmpty, approvalWaiters[request.id] == nil,
              !messages.contains(where: { $0.approval?.id == request.id }) else { return .cancelled }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                let deadline = ContinuousClock.now.advanced(by: timeout)
                approvalWaiters[request.id] = continuation
                approvalDeadlines[request.id] = deadline
                var message = ChatMessage(id: request.id, role: .notice, text: request.details,
                    title: localized("Approval required", "承認が必要です", "승인이 필요합니다"), severity: .warning)
                message.approval = request
                message.approvalStatus = .pending
                append(message)
                let sleepUntil = approvalSleepUntil
                approvalTimers[request.id] = Task { [weak self] in
                    do { try await sleepUntil(deadline) } catch { return }
                    self?.resolveApproval(request.id, status: .expired)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(request.id, status: .cancelled) }
        }
    }

    public func resolveApproval(_ id: UUID, status: ActionApprovalStatus) {
        guard status != .pending, let waiter = approvalWaiters.removeValue(forKey: id) else { return }
        let deadline = approvalDeadlines.removeValue(forKey: id)
        // The expiry task may be waiting for MainActor. Enforce the deadline
        // here too, before a late approval can grant permission to mutate.
        let withinDeadline = deadline.map { ContinuousClock.now < $0 } ?? false
        let resolvedStatus: ActionApprovalStatus = status == .approved && !withinDeadline ? .expired : status
        approvalTimers.removeValue(forKey: id)?.cancel()
        if let index = messages.firstIndex(where: { $0.approval?.id == id }) {
            messages[index].approvalStatus = resolvedStatus
        }
        waiter.resume(returning: resolvedStatus)
    }

    public func cancelPendingApprovals() {
        for id in Array(approvalWaiters.keys) { resolveApproval(id, status: .cancelled) }
    }

    /// Returns the recent conversation turns (user and assistant) formatted for reasoning context.
    public func recentConversationTurns(limit: Int = 10) -> [ConversationTurn] {
        messages
            .compactMap { $0.toConversationTurn() }
            .suffix(limit)
            .map { $0 }
    }
    /// Where the periodic screen watch is in its cycle.
    public var watchPhase: ScreenWatchPhase = .off
    public var watchInterval: ScreenWatchInterval = .normal
    /// Which window the watch is looking at (single target legacy or active primary).
    public var watchTarget: WatchTarget = .focused
    public var screenObjectiveText = ""
    public var screenObjective: ScreenObjective?
    public var onStartObjective: (@MainActor (String) -> Void)?
    public var onStopObjective: (@MainActor () -> Void)?
    /// The collection of multiple targets and their assigned objectives/roles.
    /// When non-empty, the watcher operates in multi-target mode.
    public var watchItems: [WatchItem] = []
    /// Available role presets and custom user roles.
    public var availableRoles: [WatchRole] = WatchRole.allBuiltins
    /// The currently selected preset or last-run preset in the quick preset bar.
    public var selectedPreset: WatchRole? = nil
    /// Callback invoked when a user creates or modifies a custom watch role to persist.
    public var onSaveCustomRole: (@MainActor (WatchRole) -> Void)?
    /// Callback invoked when a user deletes a custom watch role.
    public var onDeleteCustomRole: (@MainActor (String) -> Void)?
    /// Callback invoked when a user clicks an action button on an advice card.
    public var onExecuteAction: (@MainActor (String, String?) -> Void)?
    /// Callback invoked when the user selects a prompt preset to execute immediately on a target screen.
    public var onExecutePreset: (@MainActor (WatchRole, WatchTarget?) -> Void)?
    /// Callback invoked when the user sets a preset as the active watch role for a target screen.
    public var onApplyRoleToWatch: (@MainActor (WatchRole, WatchTarget?) -> Void)?

    /// Adds or updates a custom role, notifying persistence.
    public func addCustomRole(_ role: WatchRole) {
        if let idx = availableRoles.firstIndex(where: { $0.id == role.id }) {
            availableRoles[idx] = role
        } else {
            availableRoles.append(role)
        }
        onSaveCustomRole?(role)
    }

    /// Deletes a custom role, notifying persistence.
    public func deleteCustomRole(id: String) {
        availableRoles.removeAll { $0.id == id && !$0.isBuiltin }
        if selectedPreset?.id == id {
            selectedPreset = nil
        }
        onDeleteCustomRole?(id)
    }
    /// Bumped to ask the chat window to put the caret back in its field.
    ///
    /// A counter rather than a boolean because the request is an event, not a
    /// state: SwiftUI's `onAppear` fires once for the life of a hosting view, so
    /// reopening a window that was only ordered out would otherwise leave the
    /// user with a window they have to click into before typing.
    public var chatFocusRequest: Int = 0
    /// One line describing what the watch last did.
    ///
    /// On screen because the watch is deliberately quiet — it says nothing when
    /// the screen has not changed or when it has nothing new to add — and a
    /// quiet watch is otherwise indistinguishable from a dead one.
    public var watchStatus: String = ""

    private let maximumMessages = 200

    /// Whether the next transcript chunk begins a new utterance. Set when a
    /// turn ends, so `voiceTranscript` reads as "what you just said" rather
    /// than an ever-growing log of the whole conversation.
    private var startsNewUtterance = true

    /// Whether the answer currently being generated has been disowned by the
    /// thread — the user emptied the conversation while it was still arriving.
    private var discardsAnswerInFlight = false

    public init() {
        approvalSleepUntil = { try await Task.sleep(until: $0, clock: ContinuousClock()) }
    }

    // Internal timing seam: tests can defer timer delivery while the real
    // monotonic deadline and public approval resolver remain unchanged.
    init(approvalSleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.approvalSleepUntil = approvalSleepUntil
    }

    /// Whether a turn arriving right now would actually be read. The expanded
    /// panel, the open popover and the chat window all count; the collapsed bar
    /// does not, because it shows no message bodies.
    public var isOnScreen: Bool {
        isChatOpen || isPopoverOpen || (isVisible && !isCollapsed)
    }

    /// Puts a notice in the thread.
    ///
    /// The app talking about itself — a session that started, a missing key, a
    /// shortcut another application owns — lands in the same place as everything
    /// else. It used to go to a separate ring of cards that only the panel and
    /// the popover drew, which is how those two surfaces and the chat window
    /// ended up showing different accounts of the same session.
    public func present(_ card: HUDCard) {
        append(ChatMessage(
            id: card.id,
            role: .notice,
            text: card.body,
            title: card.title,
            severity: card.severity,
            timestamp: card.timestamp))
    }

    /// Starts an answer.
    ///
    /// `question` is recorded as the user's turn before the answer begins, so
    /// the chat shows what was asked the moment it is sent rather than only once
    /// the model replies. It is optional because the voice path has no typed
    /// question — what was said is already in `voiceTranscript`.
    public func beginStreaming(question: String? = nil) {
        if let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(ChatMessage(role: .user, text: question))
        }
        discardsAnswerInFlight = false
        cancelTokenFlushTask()
        tokenBuffer = ""
        streamingText = ""
        isStreaming = true
        lastTokenFlushTime = ContinuousClock.now
    }

    public func appendToken(_ token: String) {
        tokenBuffer += token

        let elapsed = lastTokenFlushTime.map { ContinuousClock.now - $0 } ?? .seconds(100)
        if tokenThrottleInterval == .zero || elapsed >= tokenThrottleInterval {
            flushTokens()
            return
        }

        // Otherwise schedule a deferred flush if not already pending.
        if tokenFlushTask == nil {
            tokenFlushTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.tokenThrottleInterval)
                guard !Task.isCancelled else { return }
                self.flushTokens()
            }
        }
    }

    /// Flushes any pending buffered tokens into `streamingText`.
    public func flushTokens() {
        cancelTokenFlushTask()
        guard !tokenBuffer.isEmpty else { return }
        streamingText += tokenBuffer
        tokenBuffer = ""
        lastTokenFlushTime = ContinuousClock.now
    }

    private func cancelTokenFlushTask() {
        tokenFlushTask?.cancel()
        tokenFlushTask = nil
    }

    /// Turns the in-flight answer into a card.
    ///
    /// `text` is the answer as the reasoning layer returned it, and it wins over
    /// what was streamed: a provider that streams nothing — or whose stream this
    /// layer failed to decode — still has a complete answer to show, and relying
    /// on the tokens alone turned that into a HUD that displayed "Thinking" and
    /// then silently reverted.
    ///
    /// An empty result is reported rather than dropped, for the same reason.
    /// Vanishing is the one outcome the user cannot act on: it is
    /// indistinguishable from the question never having been sent.
    public func endStreaming(text: String? = nil) {
        flushTokens()
        isStreaming = false
        let streamed = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let returned = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = returned.isEmpty ? streamed : returned
        streamingText = ""

        // The thread this answer belonged to was emptied while it was still
        // being written, so it is an answer to a question that no longer exists.
        // It is dropped rather than dropped into an empty conversation a second
        // after the user cleared it — which reads as the clear having failed.
        if discardsAnswerInFlight {
            discardsAnswerInFlight = false
            return
        }

        guard !body.isEmpty else {
            append(ChatMessage(role: .failure, text: localized(
                "The model returned an empty answer. Try asking again.",
                "モデルの回答が空でした。もう一度試してください。",
                "모델의 답변이 비어 있습니다. 다시 시도해 주세요.")))
            return
        }
        append(ChatMessage(role: .assistant, text: body))
    }

    /// Something the agent noticed on its own while watching the screen.
    ///
    /// Marked as its own kind so it is never mistaken for a reply to something
    /// the user asked, and counted unread by `append` when no surface is up.
    public func presentAdvice(
        title: String,
        body: String,
        severity: HUDCard.Severity = .suggestion,
        originTarget: String? = nil,
        roleId: String? = nil,
        roleName: String? = nil,
        roleIcon: String? = nil,
        actionTitle: String? = nil,
        actionPayload: String? = nil
    ) {
        append(ChatMessage(
            role: .watch,
            text: body,
            title: title,
            severity: severity,
            originTarget: originTarget,
            roleId: roleId,
            roleName: roleName,
            roleIcon: roleIcon,
            actionTitle: actionTitle,
            actionPayload: actionPayload
        ))
    }

    /// A failure the user needs to see, recorded in the conversation.
    ///
    /// In the thread rather than in an alert because the interesting part is
    /// usually *when* it happened relative to what was being asked.
    public func presentFailure(_ text: String) {
        append(ChatMessage(role: .failure, text: text))
    }

    public func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > maximumMessages {
            for message in messages.prefix(messages.count - maximumMessages) {
                if let id = message.approval?.id { resolveApproval(id, status: .cancelled) }
            }
            messages.removeFirst(messages.count - maximumMessages)
        }
        // The user's own words are never news to the user. Everything else that
        // arrives with no surface up is something they have not seen.
        if message.role != .user, !isOnScreen { unseenMessages += 1 }
    }

    /// Headlines of what the agent has said unprompted, newest first.
    ///
    /// Read by the screen watch so it does not repeat what the proactive loop
    /// said thirty seconds ago.
    public func recentHeadlines(_ limit: Int = 4) -> [String] {
        messages.reversed()
            .filter { $0.role == .watch || $0.role == .notice }
            .prefix(limit)
            .map { $0.title ?? $0.text }
    }

    /// Empties the conversation.
    public func clearChat() {
        cancelPendingApprovals()
        // An answer already in flight belongs to a question that no longer
        // exists. Without this, starting a new conversation mid-answer left the
        // user with an empty thread that a reply to the *old* question dropped
        // into a second later — which reads as the clear having failed.
        discardsAnswerInFlight = isStreaming
        cancelTokenFlushTask()
        tokenBuffer = ""
        messages.removeAll()
        streamingText = ""
        isStreaming = false
        unseenMessages = 0
    }

    /// Drops one turn.
    ///
    /// Not undoable and deliberately not confirmed at the call site: it is one
    /// message, and a confirmation for each would cost more than the mistake.
    ///
    /// The unread count is clamped rather than decremented. It counts turns that
    /// arrived while nothing was on screen, and someone deleting one is plainly
    /// looking at it — but the count can legitimately be lower than the number
    /// of messages, so subtracting blindly would drive it negative.
    public func removeMessage(_ id: UUID) {
        resolveApproval(id, status: .cancelled)
        messages.removeAll { $0.id == id }
        clampUnread()
    }

    /// Drops a chosen set of turns, for the chat's selection mode.
    public func removeMessages(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { resolveApproval(id, status: .cancelled) }
        messages.removeAll { ids.contains($0.id) }
        clampUnread()
    }

    private func clampUnread() {
        unseenMessages = min(unseenMessages, messages.count)
    }

    /// Drops this turn and everything older.
    ///
    /// The shape a long session actually needs: the useful part of a thread is
    /// nearly always its tail, and picking twenty stale turns out one at a time
    /// is not something anyone does twice.
    public func removeMessages(upThrough id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        removeMessages(Set(messages.prefix(index + 1).map(\.id)))
    }

    /// Drops every turn of a kind — the unprompted advice, the notices and the
    /// failures.
    ///
    /// These are the ones the user did not ask for, so they are what accumulates
    /// in a thread left running all day, and removing them is the one prune
    /// worth having a button for.
    public func removeMessages(ofRole roles: Set<ChatMessage.Role>) {
        removeMessages(Set(messages.filter { roles.contains($0.role) }.map(\.id)))
    }

    // MARK: - Live voice

    /// Appends a chunk of what the microphone was heard to say.
    ///
    /// The realtime path, where transcript chunks arrive from the server one
    /// after another and the client has to assemble them.
    public func appendUserSpeech(_ text: String) {
        if startsNewUtterance {
            voiceTranscriptSettled = ""
            voiceTranscriptPending = ""
            // The searches belonged to the answer to the last thing said. A new
            // utterance is a new question, so keeping them would credit this
            // answer with lookups it never made.
            voiceSearchQueries = []
            startsNewUtterance = false
        }
        let delta = DictationBuffer.stripOverlap(settled: voiceTranscriptSettled, from: text)
        voiceTranscriptSettled += delta
    }

    /// Replaces what is on the caption wholesale.
    ///
    /// The dictation path, where a `DictationBuffer` already holds the whole
    /// utterance and revises it in place — appending its output would repeat
    /// every word each time the engine changed its mind about the last one.
    public func setVoiceTranscript(settled: String, pending: String = "") {
        voiceTranscriptSettled = settled
        voiceTranscriptPending = DictationBuffer.stripOverlap(settled: settled, from: pending)
    }

    /// Wipes what is on the caption, for the start of a session.
    public func clearVoiceTranscript() {
        voiceTranscriptSettled = ""
        voiceTranscriptPending = ""
    }

    /// Marks the current utterance finished, and writes it into the
    /// conversation.
    ///
    /// The transcript is not cleared — the user should still be able to read
    /// what was heard after the model replies — and it lands in the chat for the
    /// same reason a typed question does. Without this the live path produced a
    /// thread of answers with no questions above them: readable while the words
    /// were still in the caption, and meaningless an hour later.
    ///
    /// Only the live path calls this. Dictation sends its utterance through
    /// `ask`, which records the turn itself, so committing here as well would
    /// double every spoken question.
    public func endVoiceTurn() {
        let spoken = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty, !startsNewUtterance {
            append(ChatMessage(role: .user, text: spoken))
        }
        startsNewUtterance = true
    }

    public func endVoiceSession() {
        voicePhase = .off
        clearVoiceTranscript()
        voiceSearchQueries = []
        startsNewUtterance = true
    }

    /// Problems worth putting in front of the user. Surfacing these is the
    /// direct fix for the previous implementation reporting "active" while its
    /// audio pipeline was dead.
    public var problems: [(ComponentID, ComponentState)] { health.problems }
}
