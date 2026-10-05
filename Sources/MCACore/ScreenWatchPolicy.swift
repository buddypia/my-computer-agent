import Foundation

/// Decides whether the periodic screen watch should spend a request right now.
///
/// Pure and separate from the loop that drives it, because this is the part that
/// decides how much the feature costs and how often it interrupts — and the loop
/// around it cannot be tested at all: it needs Accessibility permission, a
/// frontmost window and a paid vision model.
///
/// The gates are ordered by what they protect. Money first (nothing is sent for
/// a screen that has not changed), then the user's attention, then correctness.
public struct ScreenWatchPolicy: Sendable, Equatable {
    /// Why a tick decided to stay quiet. Carried rather than collapsed into a
    /// boolean so the window can say which one — "watching, screen unchanged"
    /// and "watching, but your password manager is in front" are the same
    /// silence to a user who is told neither.
    public enum Skip: String, Sendable, Equatable {
        /// An answer the user asked for is still streaming.
        case busy
        /// The frontmost window is our own. Looking here would photograph the
        /// agent's own advice and feed it back as if it were the user's screen.
        case ownWindow
        /// A privacy-excluded app or window title.
        case excluded
        /// Nothing readable came back from the accessibility tree.
        case nothingReadable
        /// The interval has not elapsed.
        case tooSoon
        /// Byte-identical to the last screen looked at.
        case unchanged
    }

    public enum Decision: Sendable, Equatable {
        case look
        case skip(Skip)
    }

    /// Minimum gap between two looks.
    public var interval: TimeInterval
    /// How many consecutive failures end the watch.
    ///
    /// Bounded because every failure still costs a request. A watch that cannot
    /// reach a model will not start being able to by trying every 45 seconds
    /// until the user notices, and the failure it is looping on is usually a
    /// missing key — a thing only the user can fix.
    public var maximumConsecutiveFailures: Int

    private(set) public var lastLookedAt: Date?
    private(set) public var lastFingerprint: String?
    private(set) public var consecutiveFailures: Int = 0

    public struct TargetState: Sendable, Equatable {
        public var lastLookedAt: Date?
        public var lastFingerprint: String?
        public var consecutiveFailures: Int = 0

        public init(lastLookedAt: Date? = nil, lastFingerprint: String? = nil, consecutiveFailures: Int = 0) {
            self.lastLookedAt = lastLookedAt
            self.lastFingerprint = lastFingerprint
            self.consecutiveFailures = consecutiveFailures
        }
    }

    private var targetStates: [String: TargetState] = [:]

    public init(
        interval: TimeInterval = 45,
        maximumConsecutiveFailures: Int = 3
    ) {
        self.interval = interval
        self.maximumConsecutiveFailures = maximumConsecutiveFailures
    }

    /// Whether this tick should look at the screen (default target).
    public func decide(
        now: Date = Date(),
        fingerprint: String?,
        isOwnWindow: Bool,
        isExcluded: Bool,
        isBusy: Bool
    ) -> Decision {
        decide(
            for: "default",
            now: now,
            fingerprint: fingerprint,
            interval: interval,
            isOwnWindow: isOwnWindow,
            isExcluded: isExcluded,
            isBusy: isBusy
        )
    }

    /// Whether this tick should look at a specific target screen.
    public func decide(
        for targetKey: String,
        now: Date = Date(),
        fingerprint: String?,
        interval: TimeInterval? = nil,
        isOwnWindow: Bool = false,
        isExcluded: Bool = false,
        isBusy: Bool = false
    ) -> Decision {
        if isBusy { return .skip(.busy) }
        if isOwnWindow { return .skip(.ownWindow) }
        if isExcluded { return .skip(.excluded) }
        guard let fingerprint, !fingerprint.isEmpty else { return .skip(.nothingReadable) }

        let state = targetStates[targetKey] ?? TargetState()

        let targetInterval = interval ?? self.interval
        if let lastLookedAt = state.lastLookedAt, now.timeIntervalSince(lastLookedAt) < targetInterval {
            return .skip(.tooSoon)
        }
        if fingerprint == state.lastFingerprint { return .skip(.unchanged) }
        return .look
    }

    /// Records that a look happened for a specific target.
    public mutating func recordLook(for targetKey: String = "default", now: Date = Date(), fingerprint: String) {
        lastLookedAt = now
        lastFingerprint = fingerprint
        var state = targetStates[targetKey] ?? TargetState()
        state.lastLookedAt = now
        state.lastFingerprint = fingerprint
        targetStates[targetKey] = state
    }

    public mutating func recordSuccess(for targetKey: String = "default") {
        consecutiveFailures = 0
        targetStates[targetKey]?.consecutiveFailures = 0
    }

    /// Records a failed look for a target. Returns `true` when the watch should stop.
    public mutating func recordFailure(for targetKey: String = "default") -> Bool {
        consecutiveFailures += 1
        var state = targetStates[targetKey] ?? TargetState()
        state.consecutiveFailures += 1
        targetStates[targetKey] = state
        return state.consecutiveFailures >= maximumConsecutiveFailures
    }

    /// Forgets everything about previous looks.
    public mutating func reset(for targetKey: String? = nil) {
        if let targetKey {
            targetStates.removeValue(forKey: targetKey)
        } else {
            lastLookedAt = nil
            lastFingerprint = nil
            consecutiveFailures = 0
            targetStates.removeAll()
        }
    }
}
