import Foundation

/// An objective remains bound to one window for its lifetime.
public struct ScreenObjective: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let target: PinnedWindow
    private var claimedFingerprints: Set<String> = []
    public private(set) var isActive = true

    public init(text: String, target: PinnedWindow) {
        self.id = UUID(); self.text = text; self.target = target
    }
    public mutating func claim(fingerprint: String, target: PinnedWindow) -> Bool {
        guard isActive, target.id == self.target.id, target.processID == self.target.processID,
              !fingerprint.isEmpty, !claimedFingerprints.contains(fingerprint) else { return false }
        guard claimedFingerprints.count < 256 else { isActive = false; return false }
        claimedFingerprints.insert(fingerprint)
        return true
    }
    public mutating func stop() { isActive = false }
}
