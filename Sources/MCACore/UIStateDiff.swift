import CoreGraphics
import Foundation

// MARK: - UIStateSnapshot

/// A point-in-time capture of the active desktop/window UI state,
/// including window context, focus state, visible candidates, and visual fingerprints.
public struct UIStateSnapshot: Sendable, Codable, Equatable, Hashable {
    /// Active window title of the frontmost application.
    public var windowTitle: String?

    /// Application bundle identifier (e.g. "com.apple.Safari").
    public var appBundleId: String?

    /// Bundle ID alias for compatibility with ScreenObservation.bundleID.
    public var bundleID: String? {
        get { appBundleId }
        set { appBundleId = newValue }
    }

    /// Application name (e.g. "Safari").
    public var appName: String?

    /// Identifier of the currently focused UI element (if any).
    public var focusedElementId: String?

    /// Accessibility role of the focused UI element (e.g. "AXTextField").
    public var focusedElementRole: String?

    /// Screen bounds of the currently focused UI element.
    public var focusedElementBounds: CGRect?

    /// Actionable UI element candidates visible within the active window viewport.
    public var visibleCandidates: [UIElementCandidate]
    /// Candidate cap used by perception, retained for like-for-like revalidation.
    public var candidateLimit: Int?

    /// Point-in-time timestamp when snapshot was captured.
    public var timestamp: Date

    /// Perceptual visual hash / fingerprint of the screen or window frame (e.g. via FrameFingerprint).
    public var frameHash: String?

    /// Alias for frameHash matching ScreenWatchPolicy and ScreenWatcher fingerprint conventions.
    public var fingerprint: String? {
        get { frameHash }
        set { frameHash = newValue }
    }

    // MARK: - Computed Properties for Convenience & PROJECT.md Compatibility

    /// Number of visible actionable candidates in the snapshot.
    public var candidateCount: Int {
        visibleCandidates.count
    }

    /// Fast structural integer hash over the visible candidates for quick unchanged checks.
    public var candidatesHash: Int {
        var hasher = Hasher()
        for c in visibleCandidates {
            hasher.combine(c.id)
            hasher.combine(c.role)
            hasher.combine(c.label)
            hasher.combine(c.value)
            if c.bounds.origin.x.isFinite && c.bounds.origin.y.isFinite &&
               c.bounds.size.width.isFinite && c.bounds.size.height.isFinite {
                hasher.combine(c.bounds.origin.x)
                hasher.combine(c.bounds.origin.y)
                hasher.combine(c.bounds.size.width)
                hasher.combine(c.bounds.size.height)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Initializer

    public init(
        windowTitle: String? = nil,
        appBundleId: String? = nil,
        appName: String? = nil,
        focusedElementId: String? = nil,
        focusedElementRole: String? = nil,
        focusedElementBounds: CGRect? = nil,
        visibleCandidates: [UIElementCandidate] = [],
        timestamp: Date = Date(),
        frameHash: String? = nil,
        fingerprint: String? = nil,
        candidateLimit: Int? = nil
    ) {
        self.windowTitle = windowTitle
        self.appBundleId = appBundleId
        self.appName = appName
        self.focusedElementId = focusedElementId
        self.focusedElementRole = focusedElementRole
        self.focusedElementBounds = focusedElementBounds
        self.visibleCandidates = visibleCandidates
        self.candidateLimit = candidateLimit
        self.timestamp = timestamp
        self.frameHash = frameHash ?? fingerprint
    }

    // MARK: - Hashable Implementation

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowTitle)
        hasher.combine(appBundleId)
        hasher.combine(focusedElementId)
        hasher.combine(focusedElementRole)
        hasher.combine(timestamp)
        hasher.combine(frameHash)
        hasher.combine(candidatesHash)
    }

    // MARK: - Codable Custom Decoding for Robust Forward/Backward Compatibility

    private enum CodingKeys: String, CodingKey {
        case windowTitle
        case appBundleId
        case bundleID
        case appName
        case focusedElementId
        case focusedElementRole
        case focusedElementBounds
        case visibleCandidates
        case candidateLimit
        case candidates
        case timestamp
        case frameHash
        case fingerprint
        case candidateCount
        case candidatesHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        self.appBundleId = try container.decodeIfPresent(String.self, forKey: .appBundleId)
            ?? container.decodeIfPresent(String.self, forKey: .bundleID)
        self.appName = try container.decodeIfPresent(String.self, forKey: .appName)
        self.focusedElementId = try container.decodeIfPresent(String.self, forKey: .focusedElementId)
        self.focusedElementRole = try container.decodeIfPresent(String.self, forKey: .focusedElementRole)
        self.focusedElementBounds = try container.decodeIfPresent(CGRect.self, forKey: .focusedElementBounds)
        self.visibleCandidates = try container.decodeIfPresent([UIElementCandidate].self, forKey: .visibleCandidates)
            ?? container.decodeIfPresent([UIElementCandidate].self, forKey: .candidates)
            ?? []
        self.candidateLimit = try container.decodeIfPresent(Int.self, forKey: .candidateLimit)
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.frameHash = try container.decodeIfPresent(String.self, forKey: .frameHash)
            ?? container.decodeIfPresent(String.self, forKey: .fingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(appBundleId, forKey: .appBundleId)
        try container.encodeIfPresent(appBundleId, forKey: .bundleID)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(focusedElementId, forKey: .focusedElementId)
        try container.encodeIfPresent(focusedElementRole, forKey: .focusedElementRole)
        try container.encodeIfPresent(focusedElementBounds, forKey: .focusedElementBounds)
        try container.encodeIfPresent(candidateLimit, forKey: .candidateLimit)
        try container.encode(visibleCandidates, forKey: .visibleCandidates)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(frameHash, forKey: .frameHash)
        try container.encodeIfPresent(frameHash, forKey: .fingerprint)
        try container.encode(candidateCount, forKey: .candidateCount)
        try container.encode(candidatesHash, forKey: .candidatesHash)
    }
}

// MARK: - UIElementMutation

/// Represents a structural, value, or geometric mutation of an individual UI element
/// that persisted across state transitions (identified by matching element `id`).
public struct UIElementMutation: Sendable, Codable, Equatable, Hashable {
    /// Stable element identifier.
    public let id: String

    /// Accessibility role of the element.
    public let role: String

    /// Label before the action was taken.
    public let oldLabel: String

    /// Label after the action was taken.
    public let newLabel: String

    /// Value before the action (nil if element had no value).
    public let oldValue: String?

    /// Value after the action (nil if element has no value).
    public let newValue: String?

    /// Element bounding box before the action.
    public let oldBounds: CGRect

    /// Element bounding box after the action.
    public let newBounds: CGRect

    public init(
        id: String,
        role: String,
        oldLabel: String,
        newLabel: String,
        oldValue: String? = nil,
        newValue: String? = nil,
        oldBounds: CGRect,
        newBounds: CGRect
    ) {
        self.id = id
        self.role = role
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldBounds = oldBounds
        self.newBounds = newBounds
    }

    /// Whether the visible text label changed.
    public var labelChanged: Bool {
        oldLabel != newLabel
    }

    /// Whether the text or state value changed (e.g. text entered, slider moved, checkbox toggled).
    public var valueChanged: Bool {
        oldValue != newValue
    }

    /// Whether the element bounds moved or resized.
    public var boundsChanged: Bool {
        oldBounds != newBounds
    }

    /// Geometric displacement of the element center (dx, dy).
    public var displacement: CGVector {
        guard oldBounds.origin.x.isFinite, oldBounds.origin.y.isFinite,
              oldBounds.size.width.isFinite, oldBounds.size.height.isFinite,
              newBounds.origin.x.isFinite, newBounds.origin.y.isFinite,
              newBounds.size.width.isFinite, newBounds.size.height.isFinite else {
            return .zero
        }
        return CGVector(
            dx: newBounds.midX - oldBounds.midX,
            dy: newBounds.midY - oldBounds.midY
        )
    }

    /// Whether the element's size changed.
    public var sizeChanged: Bool {
        oldBounds.size.width != newBounds.size.width || oldBounds.size.height != newBounds.size.height
    }

    /// True if mutation represents a semantically meaningful change:
    /// value change, label change, or geometric movement exceeding subpixel jitter tolerance (>= 2.0pt).
    public var isSignificantChange: Bool {
        if valueChanged || labelChanged { return true }
        if boundsChanged {
            guard oldBounds.origin.x.isFinite, oldBounds.origin.y.isFinite,
                  oldBounds.size.width.isFinite, oldBounds.size.height.isFinite,
                  newBounds.origin.x.isFinite, newBounds.origin.y.isFinite,
                  newBounds.size.width.isFinite, newBounds.size.height.isFinite else {
                return false
            }
            let dx = abs(displacement.dx)
            let dy = abs(displacement.dy)
            let dw = abs(newBounds.width - oldBounds.width)
            let dh = abs(newBounds.height - oldBounds.height)
            return dx >= 2.0 || dy >= 2.0 || dw >= 2.0 || dh >= 2.0
        }
        return false
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(role)
        hasher.combine(oldLabel)
        hasher.combine(newLabel)
        hasher.combine(oldValue)
        hasher.combine(newValue)
        if oldBounds.origin.x.isFinite && oldBounds.origin.y.isFinite &&
           oldBounds.size.width.isFinite && oldBounds.size.height.isFinite {
            hasher.combine(oldBounds.origin.x)
            hasher.combine(oldBounds.origin.y)
            hasher.combine(oldBounds.size.width)
            hasher.combine(oldBounds.size.height)
        }
        if newBounds.origin.x.isFinite && newBounds.origin.y.isFinite &&
           newBounds.size.width.isFinite && newBounds.size.height.isFinite {
            hasher.combine(newBounds.origin.x)
            hasher.combine(newBounds.origin.y)
            hasher.combine(newBounds.size.width)
            hasher.combine(newBounds.size.height)
        }
    }
}

// MARK: - StateVerificationResult

/// Outcome of verifying a state transition against an expected subgoal outcome.
public struct StateVerificationResult: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        /// The expected condition is positively verified by observed diff signals.
        case verified
        /// The expected condition failed or the screen remained unchanged when change was required.
        case unverified
        /// State changed significantly, but signals are ambiguous or require System 2 / Jev evaluation.
        case indeterminate
    }

    public let status: Status
    /// Confidence of the verification verdict (0.0 ... 1.0).
    public let confidence: Float
    /// Specific diff signals that contributed to the verdict.
    public let matchedSignals: [String]
    /// Human- and LLM-readable explanation of why this verdict was reached.
    public let rationale: String

    public var isVerified: Bool {
        status == .verified
    }

    public init(
        status: Status,
        confidence: Float,
        matchedSignals: [String] = [],
        rationale: String
    ) {
        self.status = status
        self.confidence = confidence
        self.matchedSignals = matchedSignals
        self.rationale = rationale
    }
}

// MARK: - UIStateDiff

/// Structured diff between two consecutive UIStateSnapshots.
/// Evaluates element additions, removals, mutations, focus shifts, title changes,
/// and verifies whether expected outcomes have occurred.
public struct UIStateDiff: Sendable, Codable, Equatable {
    /// Snapshot before action execution.
    public let before: UIStateSnapshot?

    /// Snapshot after action execution.
    public let after: UIStateSnapshot?

    /// True if the window title or application changed.
    public let titleChanged: Bool

    /// True if the focused element ID or role changed.
    public let focusChanged: Bool

    /// Elements that appeared in the after state but were not present in before.
    public let addedElements: [UIElementCandidate]

    /// Elements that were present in before but vanished in after.
    public let removedElements: [UIElementCandidate]

    /// Elements persisting across states with mutated values, labels, or bounds.
    public let modifiedElements: [UIElementMutation]

    /// True if perceptual frameHash/fingerprint changed between snapshots.
    public let frameHashChanged: Bool

    // MARK: - Quantitative Change Metrics

    /// Total count of element lifecycle mutations (added + removed + modified).
    public var mutationCount: Int {
        addedElements.count + removedElements.count + modifiedElements.count
    }

    /// True if the layout structure changed (candidates added, removed, or bounds shifted).
    /// Conforms to PROJECT.md interface contract.
    public var layoutMutated: Bool {
        !addedElements.isEmpty || !removedElements.isEmpty || modifiedElements.contains(where: { $0.isSignificantChange && $0.boundsChanged })
    }

    /// True if any semantically significant change occurred:
    /// title change, focus change, added/removed elements, significant mutations, or frame hash shift.
    public var hasSignificantChange: Bool {
        if titleChanged || focusChanged { return true }
        if !addedElements.isEmpty || !removedElements.isEmpty { return true }
        if modifiedElements.contains(where: { $0.isSignificantChange }) { return true }
        if frameHashChanged { return true }
        return false
    }

    /// True if no meaningful change occurred anywhere in the UI state.
    /// Conforms to PROJECT.md interface contract.
    public var isStateUnchanged: Bool {
        !hasSignificantChange
    }

    // MARK: - Initializer

    public init(
        before: UIStateSnapshot? = nil,
        after: UIStateSnapshot? = nil,
        titleChanged: Bool,
        focusChanged: Bool,
        addedElements: [UIElementCandidate] = [],
        removedElements: [UIElementCandidate] = [],
        modifiedElements: [UIElementMutation] = [],
        frameHashChanged: Bool = false
    ) {
        self.before = before
        self.after = after
        self.titleChanged = titleChanged
        self.focusChanged = focusChanged
        self.addedElements = addedElements
        self.removedElements = removedElements
        self.modifiedElements = modifiedElements
        self.frameHashChanged = frameHashChanged
    }

    // MARK: - State Diff Computation

    /// Computes the structured diff between before and after UI state snapshots.
    /// Operates in O(N + M) time with zero I/O and minimal allocations.
    public static func compute(before: UIStateSnapshot, after: UIStateSnapshot) -> UIStateDiff {
        let titleChanged = (before.windowTitle != after.windowTitle) || (before.appBundleId != after.appBundleId)
        let focusChanged = (before.focusedElementId != after.focusedElementId) || (before.focusedElementRole != after.focusedElementRole)

        let frameHashChanged: Bool
        if before.frameHash != nil || after.frameHash != nil {
            frameHashChanged = (before.frameHash != after.frameHash)
        } else {
            frameHashChanged = false
        }

        // Group before candidate indices by element ID to support duplicate IDs
        var beforeBuckets = [String: [Int]](minimumCapacity: before.visibleCandidates.count)
        for (index, candidate) in before.visibleCandidates.enumerated() {
            beforeBuckets[candidate.id, default: []].append(index)
        }

        var matchedBeforeIndices = [Bool](repeating: false, count: before.visibleCandidates.count)
        var matchedCount = 0
        var addedElements: [UIElementCandidate] = []
        var modifiedElements: [UIElementMutation] = []

        for afterCandidate in after.visibleCandidates {
            guard var candidateIndices = beforeBuckets[afterCandidate.id], !candidateIndices.isEmpty else {
                // Element is newly added in after state
                addedElements.append(afterCandidate)
                continue
            }

            let chosenIndex: Int
            if candidateIndices.count == 1 {
                chosenIndex = candidateIndices[0]
                beforeBuckets.removeValue(forKey: afterCandidate.id)
            } else {
                // Multi-candidate disambiguation for duplicate IDs:
                // 1. Prefer an exact match (identical label, role, bounds, and value).
                var matchedExactIdx: Int?
                if let firstIdx = candidateIndices.first {
                    let firstCandidate = before.visibleCandidates[firstIdx]
                    if firstCandidate.label == afterCandidate.label &&
                       firstCandidate.role == afterCandidate.role &&
                       firstCandidate.bounds == afterCandidate.bounds &&
                       firstCandidate.value == afterCandidate.value {
                        matchedExactIdx = firstIdx
                    }
                }
                if matchedExactIdx == nil {
                    if let exactBucketIdx = candidateIndices.firstIndex(where: {
                        let c = before.visibleCandidates[$0]
                        return c.label == afterCandidate.label &&
                               c.role == afterCandidate.role &&
                               c.bounds == afterCandidate.bounds &&
                               c.value == afterCandidate.value
                    }) {
                        matchedExactIdx = candidateIndices[exactBucketIdx]
                    }
                }

                if let exactIdx = matchedExactIdx {
                    chosenIndex = exactIdx
                    if let removeIdx = candidateIndices.firstIndex(of: exactIdx) {
                        candidateIndices.remove(at: removeIdx)
                    }
                } else {
                    // 2. Fall back to FIFO order for candidates with same ID
                    chosenIndex = candidateIndices.removeFirst()
                }
                if candidateIndices.isEmpty {
                    beforeBuckets.removeValue(forKey: afterCandidate.id)
                } else {
                    beforeBuckets[afterCandidate.id] = candidateIndices
                }
            }

            matchedBeforeIndices[chosenIndex] = true
            matchedCount += 1
            let beforeCandidate = before.visibleCandidates[chosenIndex]

            // Element existed before: check for mutations
            let labelDiff = beforeCandidate.label != afterCandidate.label
            let valueDiff = beforeCandidate.value != afterCandidate.value
            let boundsDiff = beforeCandidate.bounds != afterCandidate.bounds

            if labelDiff || valueDiff || boundsDiff {
                let mutation = UIElementMutation(
                    id: afterCandidate.id,
                    role: afterCandidate.role,
                    oldLabel: beforeCandidate.label,
                    newLabel: afterCandidate.label,
                    oldValue: beforeCandidate.value,
                    newValue: afterCandidate.value,
                    oldBounds: beforeCandidate.bounds,
                    newBounds: afterCandidate.bounds
                )
                modifiedElements.append(mutation)
            }
        }

        var removedElements: [UIElementCandidate] = []
        if matchedCount < before.visibleCandidates.count {
            for (index, beforeCandidate) in before.visibleCandidates.enumerated() {
                if !matchedBeforeIndices[index] {
                    removedElements.append(beforeCandidate)
                }
            }
        }

        return UIStateDiff(
            before: before,
            after: after,
            titleChanged: titleChanged,
            focusChanged: focusChanged,
            addedElements: addedElements,
            removedElements: removedElements,
            modifiedElements: modifiedElements,
            frameHashChanged: frameHashChanged
        )
    }

    // MARK: - Outcome Verification

    /// Evaluates the observed state diff against a natural-language or keyword-based expected outcome.
    /// Returns a structured StateVerificationResult with status, confidence, matched signals, and rationale.
    public func verifyOutcome(expected: String) -> StateVerificationResult {
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExpected.isEmpty {
            return StateVerificationResult(
                status: hasSignificantChange ? .verified : .indeterminate,
                confidence: hasSignificantChange ? 0.85 : 0.50,
                matchedSignals: hasSignificantChange ? ["significant_state_change"] : ["empty_expected_outcome"],
                rationale: hasSignificantChange
                    ? "Expected outcome was empty, but significant state changes were observed (\(mutationCount) mutations)."
                    : "Expected outcome was empty and no significant state changes occurred."
            )
        }

        let lowerExpected = trimmedExpected.lowercased()
        let expectedTokens = Self.extractOutcomeTokens(from: lowerExpected)

        var matchedSignals: [String] = []
        var matchScore: Float = 0.0

        // 1. Unchanged state check
        if isStateUnchanged {
            let expectsUnchanged = lowerExpected.contains("unchanged") ||
                                   lowerExpected.contains("no change") ||
                                   lowerExpected.contains("stay") ||
                                   lowerExpected.contains("remain") ||
                                   lowerExpected.contains("変化なし") ||
                                   lowerExpected.contains("変わらない") ||
                                   lowerExpected.contains("そのまま")
            if expectsUnchanged {
                return StateVerificationResult(
                    status: .verified,
                    confidence: 0.95,
                    matchedSignals: ["expected_state_unchanged"],
                    rationale: "UI state remained unchanged as expected."
                )
            } else {
                return StateVerificationResult(
                    status: .unverified,
                    confidence: 0.10,
                    matchedSignals: ["state_completely_unchanged"],
                    rationale: "Expected outcome '\(trimmedExpected)' required UI changes, but no mutations or focus/title changes occurred."
                )
            }
        }

        // 2. Focus change matching
        if focusChanged {
            let roleMatch = expectedTokens.contains { token in
                after?.focusedElementRole?.lowercased().contains(token) == true ||
                after?.focusedElementId?.lowercased().contains(token) == true ||
                (token.contains("submit") && after?.focusedElementId?.lowercased().contains("submit") == true) ||
                (token.contains("button") && after?.focusedElementRole?.lowercased().contains("button") == true) ||
                (token.contains("ボタン") && after?.focusedElementRole?.lowercased().contains("button") == true) ||
                (token.contains("入力") && (after?.focusedElementRole?.lowercased().contains("textfield") == true || after?.focusedElementRole?.lowercased().contains("text") == true))
            }
            let focusKeywords = ["focus", "focused", "active", "cursor", "selected", "shifts", "shift", "フォーカス", "アクティブ", "選択"]
            let expectsFocus = expectedTokens.contains { focusKeywords.contains($0) } ||
                               focusKeywords.contains { lowerExpected.contains($0) }

            if expectsFocus || roleMatch {
                matchedSignals.append("focus_changed_to_\(after?.focusedElementRole ?? "element")")
                matchScore += (roleMatch && expectsFocus) ? 0.60 : 0.45
            }
        }

        // 3. Window title / app navigation matching
        if titleChanged, let newTitle = after?.windowTitle?.lowercased() {
            let matchingTitleTokens = expectedTokens.filter { token in
                newTitle.contains(token) || (newTitle.count >= 2 && token.contains(newTitle))
            }
            let directTitleMatch = newTitle.count >= 2 && lowerExpected.contains(newTitle)
            if !matchingTitleTokens.isEmpty || directTitleMatch {
                let tokenDesc: String
                if !matchingTitleTokens.isEmpty {
                    tokenDesc = matchingTitleTokens.prefix(3).joined(separator: "_")
                } else {
                    tokenDesc = newTitle
                }
                matchedSignals.append("window_title_matched_\(tokenDesc)")
                matchScore += Float(min(max(matchingTitleTokens.count, 1), 3)) * 0.30 + 0.30
            }
        }

        // 4. Added elements matching (appearance / dialog / popup / window)
        for added in addedElements {
            let label = added.label.lowercased()
            let role = added.role.lowercased()
            let id = added.id.lowercased()
            let matchedWord = expectedTokens.first { token in
                label.contains(token) ||
                (label.count >= 2 && token.contains(label)) ||
                role.contains(token) ||
                (role.count >= 2 && token.contains(role)) ||
                id.contains(token) ||
                (id.count >= 2 && token.contains(id)) ||
                (label.count >= 2 && lowerExpected.contains(label)) ||
                (token.contains("dialog") && (id.contains("dialog") || role.contains("window"))) ||
                (token.contains("confirm") && (id.contains("confirm") || label.contains("proceed") || label.contains("sure"))) ||
                (token.contains("ダイアログ") && (id.contains("dialog") || role.contains("window") || label.contains("ダイアログ"))) ||
                (token.contains("確認") && (id.contains("confirm") || label.contains("確認") || label.contains("proceed") || label.contains("sure"))) ||
                (token.contains("ボタン") && (role.contains("button") || id.contains("btn") || label.contains("ボタン"))) ||
                (token.contains("閉じる") && (id.contains("close") || label.contains("閉じる"))) ||
                (token.contains("保存") && (id.contains("save") || label.contains("保存")))
            }
            if let matched = matchedWord {
                let signalName = (label.count >= 2 && matched.contains(label)) ? label : matched
                matchedSignals.append("element_added_\(signalName)")
                matchScore += 0.55
                break
            } else if label.count >= 2 && lowerExpected.contains(label) {
                matchedSignals.append("element_added_\(label)")
                matchScore += 0.55
                break
            }
        }

        // 5. Modified elements matching (typed text, updated value, toggled state)
        for mod in modifiedElements {
            if let val = mod.newValue?.lowercased(), !val.isEmpty {
                let matchingVal = expectedTokens.first { token in
                    val.contains(token) || (val.count >= 2 && token.contains(val)) ||
                    (val.count >= 2 && lowerExpected.contains(val))
                }
                if let matched = matchingVal {
                    let signalName = (val.count >= 2 && matched.contains(val)) ? val : matched
                    matchedSignals.append("value_updated_with_\(signalName)")
                    matchScore += 0.55
                    break
                } else if val.count >= 2 && lowerExpected.contains(val) {
                    matchedSignals.append("value_updated_with_\(val)")
                    matchScore += 0.55
                    break
                }
            }
            if mod.labelChanged {
                let newLabel = mod.newLabel.lowercased()
                let matchingLabel = expectedTokens.first { token in
                    newLabel.contains(token) || (newLabel.count >= 2 && token.contains(newLabel)) ||
                    (newLabel.count >= 2 && lowerExpected.contains(newLabel))
                }
                if let matched = matchingLabel {
                    let signalName = (newLabel.count >= 2 && matched.contains(newLabel)) ? newLabel : matched
                    matchedSignals.append("label_updated_with_\(signalName)")
                    matchScore += 0.45
                    break
                } else if newLabel.count >= 2 && lowerExpected.contains(newLabel) {
                    matchedSignals.append("label_updated_with_\(newLabel)")
                    matchScore += 0.45
                    break
                }
            }
        }

        // 6. Removed elements matching (dismissal / closing / completion)
        let dismissalKeywords = ["close", "closed", "dismiss", "dismissed", "disappear", "vanish", "removed", "閉じる", "閉じ", "消える", "消失", "削除"]
        let expectsDismissal = expectedTokens.contains { dismissalKeywords.contains($0) } ||
                               dismissalKeywords.contains { lowerExpected.contains($0) }
        if expectsDismissal && !removedElements.isEmpty {
            matchedSignals.append("elements_removed_as_expected(\(removedElements.count))")
            matchScore += 0.55
        }

        // 7. General significant change fallback bonus
        if hasSignificantChange && matchScore > 0.0 {
            matchScore += 0.15
        }

        let clampedConfidence = min(max(matchScore, 0.0), 1.0)

        if clampedConfidence >= 0.70 {
            return StateVerificationResult(
                status: .verified,
                confidence: clampedConfidence,
                matchedSignals: matchedSignals,
                rationale: "Observed state diff matches expected outcome '\(trimmedExpected)' (signals: \(matchedSignals.joined(separator: ", ")))."
            )
        } else if clampedConfidence >= 0.30 || (hasSignificantChange && !matchedSignals.isEmpty) {
            return StateVerificationResult(
                status: .indeterminate,
                confidence: clampedConfidence,
                matchedSignals: matchedSignals,
                rationale: "UI state mutated (\(mutationCount) changes), but signals partially match expected outcome '\(trimmedExpected)'."
            )
        } else {
            return StateVerificationResult(
                status: .unverified,
                confidence: clampedConfidence,
                matchedSignals: matchedSignals,
                rationale: "State mutations observed do not match expected outcome '\(trimmedExpected)'."
            )
        }
    }

    // MARK: - Tokenization Helpers

    /// Extracts semantic tokens from an expected outcome string, supporting Latin words,
    /// CJK word boundaries (via linguistic analysis & n-grams), and non-alphanumeric symbols / emojis.
    private static func extractOutcomeTokens(from text: String) -> [String] {
        let lower = text.lowercased()
        var tokens = Set<String>()

        // 1. Linguistic word segmentation (ICU-backed natural word boundaries for both Latin and CJK)
        lower.enumerateSubstrings(in: lower.startIndex..<lower.endIndex, options: .byWords) { substr, _, _, _ in
            if let s = substr {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2 {
                    tokens.insert(trimmed)
                }
            }
        }

        // 2. Standard alphanumeric tokenization (fallback for hyphenated words, alphanumeric codes)
        let alphaTokens = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        for t in alphaTokens {
            tokens.insert(t)
        }

        // 3. Preserve non-whitespace symbols and emojis (e.g. 🚀, 🎉, ✅, symbols)
        for char in lower {
            if !char.isWhitespace && (char.isSymbol || (!char.isASCII && !char.isLetter && !char.isNumber)) {
                tokens.insert(String(char))
            }
        }

        // 4. Preserve non-empty whitespace-separated chunks (captures multi-emoji or symbol sequences)
        let spaceChunks = lower.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        for chunk in spaceChunks {
            if chunk.count == 1 || chunk.contains(where: { $0.isSymbol || !($0.isLetter || $0.isNumber) }) {
                tokens.insert(chunk)
            }
        }

        // 5. CJK n-grams (bigrams and trigrams) to support unsegmented Asian natural language clauses
        let chars = Array(lower)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                let c1 = chars[i]
                let c2 = chars[i + 1]
                if !c1.isASCII && c1.isLetter && !c2.isASCII && c2.isLetter {
                    tokens.insert(String([c1, c2]))
                    if i + 2 < chars.count {
                        let c3 = chars[i + 2]
                        if !c3.isASCII && c3.isLetter {
                            tokens.insert(String([c1, c2, c3]))
                        }
                    }
                }
            }
        }

        // 6. Include full unsegmented clause when trimmed length >= 2
        let trimmedFull = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFull.count >= 2 {
            tokens.insert(trimmedFull)
        }

        return tokens.sorted { $0.count > $1.count }
    }
}
