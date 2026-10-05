import Foundation
import Testing

@testable import MCACore

@Suite("Watch role and multi-target policy")
struct WatchRoleTests {
    private let windowA = PinnedWindow(
        id: 101, appName: "Zoom", windowTitle: "Product Sync", bundleID: "us.zoom.xos")
    private let windowB = PinnedWindow(
        id: 202, appName: "Ghostty", windowTitle: "agent-worker", bundleID: "com.mitchellh.ghostty")

    @Test("builtin roles provide specialized prompts and trigger policies")
    func builtinRolesHaveSpecializedPrompts() {
        let builtins = WatchRole.allBuiltins
        #expect(builtins.count >= 8)

        let meeting = WatchRole.meeting
        #expect(meeting.id == "builtin.meeting")
        #expect(meeting.triggerKind == .meetingFast)
        #expect(meeting.systemPrompt.contains("ミーティング") || meeting.systemPrompt.contains("会議"))

        let cli = WatchRole.cliDev
        #expect(cli.id == "builtin.cli-dev")
        #expect(cli.triggerKind == .cliPromptWait)
        #expect(cli.systemPrompt.contains("CLI") || cli.systemPrompt.contains("自律型AI"))

        let err = WatchRole.errorDiagnosis
        #expect(err.id == "builtin.error-diagnosis")
        #expect(err.icon == "exclamationmark.triangle.fill")
        #expect(err.effectiveTaskPrompt.contains("エラー"))

        let summary = WatchRole.summaryNotes
        #expect(summary.id == "builtin.summary-notes")
        #expect(summary.effectiveTaskPrompt.contains("要点") || summary.effectiveTaskPrompt.contains("まとめ"))

        let tasks = WatchRole.actionItems
        #expect(tasks.id == "builtin.action-items")
        #expect(tasks.effectiveTaskPrompt.contains("タスク") || tasks.effectiveTaskPrompt.contains("ToDo"))

        let review = WatchRole.codeReview
        #expect(review.id == "builtin.code-review")
        #expect(review.effectiveTaskPrompt.contains("レビュー"))
    }

    @Test("custom roles preserve user prompt overrides")
    func customRolePreservesPrompt() {
        let customPrompt = "Watch for security vulnerability disclosures only."
        let custom = WatchRole(
            id: "custom.security",
            name: "Security Guard",
            icon: "shield.fill",
            systemPrompt: customPrompt,
            triggerKind: .screenDiff
        )

        #expect(custom.name == "Security Guard")
        #expect(custom.icon == "shield.fill")
        #expect(custom.systemPrompt == customPrompt)
        #expect(custom.triggerKind == .screenDiff)
    }

    @Test("one-shot directive uses the task prompt and forbids the PASS reply")
    func oneShotDirectiveForbidsPass() {
        let directive = WatchRole.summaryNotes.oneShotDirective(targetName: "Zoom — Product Sync")
        #expect(directive.contains("Zoom — Product Sync"))
        #expect(directive.contains(WatchRole.summaryNotes.taskPrompt!))
        #expect(!directive.contains(WatchRole.summaryNotes.systemPrompt))
        #expect(directive.contains("never reply PASS"))

        // A custom role without a task prompt falls back to its watch prompt,
        // PASS instruction included — the closing line must still override it.
        let custom = WatchRole(
            id: "custom.watch-only", name: "Watch Only", icon: "eye",
            systemPrompt: "Report changes. If nothing changed, reply PASS.")
        #expect(custom.oneShotDirective(targetName: "Zoom").hasSuffix("never reply PASS."))
    }

    @Test("WatchItem pairs a target with a role and supports Codable")
    func watchItemPairingAndCodable() throws {
        let item = WatchItem(
            target: .pinned(windowA),
            role: .meeting,
            customPromptOverride: "Focus strictly on action items.",
            intervalOverride: 5.0
        )

        #expect(item.targetName == "Zoom — Product Sync")
        #expect(item.role.id == "builtin.meeting")
        #expect(item.effectiveInterval == 5.0)
        #expect(item.effectivePrompt == "Focus strictly on action items.")

        // Codable round-trip
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchItem.self, from: data)

        #expect(decoded.id == item.id)
        #expect(decoded.targetName == item.targetName)
        #expect(decoded.role.id == "builtin.meeting")
        #expect(decoded.intervalOverride == 5.0)
        #expect(decoded.effectivePrompt == "Focus strictly on action items.")
    }

    @Test("ScreenWatchPolicy tracks state per target independently")
    func policyTracksPerTargetIndependently() {
        var policy = ScreenWatchPolicy(interval: 30)
        let now = Date()

        let keyA = WatchTarget.pinned(windowA).key
        let keyB = WatchTarget.pinned(windowB).key

        // Target A first look
        let decisionA1 = policy.decide(for: keyA, now: now, fingerprint: "Zoom|Frame1")
        #expect(decisionA1 == .look)
        policy.recordLook(for: keyA, now: now, fingerprint: "Zoom|Frame1")

        // Target B first look
        let decisionB1 = policy.decide(for: keyB, now: now, fingerprint: "Ghostty|Frame1")
        #expect(decisionB1 == .look)
        policy.recordLook(for: keyB, now: now, fingerprint: "Ghostty|Frame1")

        // Next tick: Target A unchanged, Target B changed
        let decisionA2 = policy.decide(for: keyA, now: now.addingTimeInterval(35), fingerprint: "Zoom|Frame1")
        #expect(decisionA2 == ScreenWatchPolicy.Decision.skip(.unchanged))

        let decisionB2 = policy.decide(for: keyB, now: now.addingTimeInterval(35), fingerprint: "Ghostty|Frame2")
        #expect(decisionB2 == .look)

        // Target A should not be blocked by Target B's interval
        let decisionA3 = policy.decide(for: keyA, now: now.addingTimeInterval(40), fingerprint: "Zoom|Frame2")
        #expect(decisionA3 == .look)
    }

    @Test("policy handles target-specific failure backoff")
    func targetSpecificBackoff() {
        var policy = ScreenWatchPolicy(interval: 10)
        let now = Date()
        let keyA = WatchTarget.pinned(windowA).key
        let keyB = WatchTarget.pinned(windowB).key

        let shouldStop = policy.recordFailure(for: keyA)
        #expect(!shouldStop)

        // Target A is backed off
        policy.recordLook(for: keyA, now: now, fingerprint: "ChangedA")
        let decisionA = policy.decide(for: keyA, now: now.addingTimeInterval(2), fingerprint: "ChangedA2")
        #expect(decisionA == ScreenWatchPolicy.Decision.skip(.tooSoon))

        // Target B is unaffected
        let decisionB = policy.decide(for: keyB, now: now.addingTimeInterval(2), fingerprint: "ChangedB")
        #expect(decisionB == .look)

        // Target A recovers after success
        policy.recordSuccess(for: keyA)
        let decisionARecovered = policy.decide(for: keyA, now: now.addingTimeInterval(12), fingerprint: "ChangedA3")
        #expect(decisionARecovered == .look)
    }

    @Test("effectiveInterval picks individual override or defaults to role setting")
    func effectiveIntervalResolution() {
        let defaultItem = WatchItem(target: .pinned(windowA), role: .cliDev)
        #expect(defaultItem.effectiveInterval == 10)

        let overriddenItem = WatchItem(target: .pinned(windowB), role: .meeting, intervalOverride: 3.0)
        #expect(overriddenItem.effectiveInterval == 3.0)

        let items = [defaultItem, overriddenItem]
        let minInterval = items.filter(\.isEnabled).map(\.effectiveInterval).min()
        #expect(minInterval == 3.0)
    }
}
