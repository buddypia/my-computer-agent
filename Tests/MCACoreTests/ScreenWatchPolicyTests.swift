import Foundation
import Testing

@testable import MCACore

/// The watch's cost and its intrusiveness are both decided here, so these are
/// the assertions that stop "look at my screen" from becoming an expensive way
/// to be interrupted.
@Suite("Screen watch policy")
struct ScreenWatchPolicyTests {
    private func policy(interval: TimeInterval = 45) -> ScreenWatchPolicy {
        ScreenWatchPolicy(interval: interval)
    }

    @Test("the first look at a readable screen goes ahead")
    func firstLookProceeds() {
        let policy = policy()
        #expect(policy.decide(
            fingerprint: "Xcode|Agent.swift|1",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .look)
    }

    /// The single most important gate: without it the watch pays for a request
    /// every interval for as long as the user reads one page.
    @Test("an unchanged screen is not looked at twice")
    func unchangedScreenIsSkipped() {
        var policy = policy(interval: 0)
        let screen = "Xcode|Agent.swift|1"

        policy.recordLook(fingerprint: screen)

        #expect(policy.decide(
            fingerprint: screen,
            isOwnWindow: false, isExcluded: false, isBusy: false) == .skip(.unchanged))
        #expect(policy.decide(
            fingerprint: "Xcode|Agent.swift|2",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .look)
    }

    /// A look that produced no advice still counts as paid for. Recording only
    /// the ones that spoke would re-send the same silent screen forever.
    @Test("a look that said nothing still marks the screen as seen")
    func silentLookStillCounts() {
        var policy = policy(interval: 0)
        policy.recordLook(fingerprint: "Mail|Inbox|7")

        #expect(policy.decide(
            fingerprint: "Mail|Inbox|7",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .skip(.unchanged))
    }

    @Test("the interval is honoured even when the screen changed")
    func waitsForTheInterval() {
        var policy = policy(interval: 45)
        let start = Date()
        policy.recordLook(now: start, fingerprint: "one")

        #expect(policy.decide(
            now: start.addingTimeInterval(10), fingerprint: "two",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .skip(.tooSoon))
        #expect(policy.decide(
            now: start.addingTimeInterval(46), fingerprint: "two",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .look)
    }

    /// Our own window in front means the chat is what would be photographed —
    /// the agent reading its own advice back and treating it as the user's
    /// screen. That is a feedback loop, not a look.
    @Test("our own window is never photographed")
    func skipsOurOwnWindow() {
        let policy = policy()
        #expect(policy.decide(
            fingerprint: "Copilot|Chat|1",
            isOwnWindow: true, isExcluded: false, isBusy: false) == .skip(.ownWindow))
    }

    @Test("an excluded app is never photographed")
    func skipsExcludedApps() {
        let policy = policy()
        #expect(policy.decide(
            fingerprint: "1Password|Vault|1",
            isOwnWindow: false, isExcluded: true, isBusy: false) == .skip(.excluded))
    }

    /// Ordered ahead of everything else: an answer the user asked for is being
    /// written, and an unprompted note landing in the middle of it is the exact
    /// interruption this whole design is trying to avoid.
    @Test("nothing is looked at while an answer is streaming")
    func skipsWhileBusy() {
        let policy = policy()
        #expect(policy.decide(
            fingerprint: "Xcode|Agent.swift|1",
            isOwnWindow: false, isExcluded: false, isBusy: true) == .skip(.busy))
    }

    @Test("a window with nothing readable is skipped")
    func skipsUnreadableWindows() {
        let policy = policy()
        #expect(policy.decide(
            fingerprint: nil,
            isOwnWindow: false, isExcluded: false, isBusy: false) == .skip(.nothingReadable))
        #expect(policy.decide(
            fingerprint: "",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .skip(.nothingReadable))
    }

    /// Every failed look still costs a request, and the cause is usually a
    /// missing key — which will not fix itself by being retried every 45
    /// seconds until the user happens to notice.
    @Test("the watch gives up after repeated failures")
    func stopsAfterRepeatedFailures() {
        var policy = ScreenWatchPolicy(interval: 45, maximumConsecutiveFailures: 3)

        #expect(policy.recordFailure() == false)
        #expect(policy.recordFailure() == false)
        #expect(policy.recordFailure() == true)
    }

    @Test("a successful look forgets earlier failures")
    func successResetsTheFailureCount() {
        var policy = ScreenWatchPolicy(interval: 45, maximumConsecutiveFailures: 3)

        _ = policy.recordFailure()
        _ = policy.recordFailure()
        policy.recordSuccess()

        #expect(policy.consecutiveFailures == 0)
        #expect(policy.recordFailure() == false)
    }

    /// Switching the watch off and on is the only way to ask for a fresh look
    /// at a screen that has not changed. Keeping the fingerprint across a reset
    /// would make that do nothing.
    @Test("switching the watch on again looks at the same screen")
    func resetForgetsTheLastScreen() {
        var policy = policy(interval: 0)
        policy.recordLook(fingerprint: "same")
        policy.reset()

        #expect(policy.decide(
            fingerprint: "same",
            isOwnWindow: false, isExcluded: false, isBusy: false) == .look)
    }
}
