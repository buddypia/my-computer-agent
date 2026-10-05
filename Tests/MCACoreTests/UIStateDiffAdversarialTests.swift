import CoreGraphics
import Foundation
@testable import MCACore
import Testing

/// CPU time this thread spent in `body`, in milliseconds. Unlike wall-clock time it does
/// not grow when other processes compete for the cores, so a budget measured with it
/// catches an algorithmic slowdown without failing on a loaded machine.
func threadCPUMilliseconds(_ body: () -> Void) -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
}

@Suite("UIStateDiff Adversarial Tests: Edge Cases, Stress & Attack Vectors")
struct UIStateDiffAdversarialTests {

    // MARK: - 1. Non-Finite Coordinates (NaN, +Inf, -Inf)

    @Test("Snapshot hashing with NaN and Infinite coordinates determinism")
    func testSnapshotHashingWithNonFiniteCoordinates() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let nanCandidate = UIElementCandidate(
            id: "elem_nan",
            role: "AXButton",
            label: "NaN Button",
            bounds: CGRect(x: Double.nan, y: Double.nan, width: Double.nan, height: Double.nan)
        )
        let infCandidate = UIElementCandidate(
            id: "elem_inf",
            role: "AXButton",
            label: "Inf Button",
            bounds: CGRect(x: -Double.infinity, y: Double.infinity, width: Double.infinity, height: 100)
        )
        let finiteCandidate = UIElementCandidate(
            id: "elem_finite",
            role: "AXButton",
            label: "Finite Button",
            bounds: CGRect(x: 10, y: 20, width: 30, height: 40)
        )

        let snapshot1 = UIStateSnapshot(
            visibleCandidates: [nanCandidate, infCandidate, finiteCandidate],
            timestamp: fixedDate
        )
        let snapshot2 = UIStateSnapshot(
            visibleCandidates: [nanCandidate, infCandidate, finiteCandidate],
            timestamp: fixedDate
        )

        // Verify hash determinism and no crashes
        let hash1 = snapshot1.candidatesHash
        let hash2 = snapshot2.candidatesHash
        #expect(hash1 == hash2, "candidatesHash must be deterministic across identical NaN/Inf candidate lists")

        var hasher1 = Hasher()
        snapshot1.hash(into: &hasher1)
        var hasher2 = Hasher()
        snapshot2.hash(into: &hasher2)
        #expect(hasher1.finalize() == hasher2.finalize(), "UIStateSnapshot.hash(into:) must be deterministic")
    }

    @Test("NaN in candidate bounds causes perpetual false-positive boundsChanged")
    func testNaNCausesPerpetualBoundsChanged() {
        let nanCandidate = UIElementCandidate(
            id: "elem_nan",
            role: "AXButton",
            label: "Button",
            bounds: CGRect(x: Double.nan, y: 100, width: 200, height: 30)
        )

        let before = UIStateSnapshot(visibleCandidates: [nanCandidate])
        let after = UIStateSnapshot(visibleCandidates: [nanCandidate])

        let diff = UIStateDiff.compute(before: before, after: after)

        // In IEEE 754, NaN != NaN is true, so boundsDiff evaluates to true!
        // This causes modifiedElements to contain elem_nan even though before and after are identical!
        print("NaN perpetual mutation: modifiedElements count = \(diff.modifiedElements.count)")
        #expect(diff.modifiedElements.count == 1, "Demonstrates that NaN bounds produce false mutation due to IEEE 754 NaN != NaN")
        let mutation = diff.modifiedElements[0]
        #expect(mutation.boundsChanged)
        #expect(!mutation.isSignificantChange)
    }

    @Test("Finite origin with NaN width safely returns zero displacement")
    func testFiniteOriginWithNaNWidthSafelyReturnsZeroDisplacement() {
        // origin is finite, but size is NaN
        let oldBounds = CGRect(x: 10.0, y: 10.0, width: Double.nan, height: 20.0)
        let newBounds = CGRect(x: 10.0, y: 10.0, width: 50.0, height: 20.0)

        let mutation = UIElementMutation(
            id: "elem_test",
            role: "AXButton",
            oldLabel: "Test",
            newLabel: "Test",
            oldBounds: oldBounds,
            newBounds: newBounds
        )

        // Guard verifies width and height finiteness, returning .zero displacement
        let dx = mutation.displacement.dx
        print("Displacement dx with NaN width: \(dx)")
        #expect(dx == 0.0, "Displacement dx must be 0.0 when width is non-finite")
        #expect(!dx.isNaN, "Displacement dx must not be NaN")
        #expect(!mutation.isSignificantChange, "Comparison with non-finite bounds safely returns false")
    }

    // MARK: - 2. Subpixel Jitter Boundary (1.99pt vs 2.01pt displacement)

    @Test("Subpixel jitter boundary: exactly 1.99pt vs 2.01pt displacement")
    func testSubpixelBoundary1Point99Vs2Point01() {
        let beforeElem = UIElementCandidate(
            id: "target",
            role: "AXButton",
            label: "Click",
            bounds: CGRect(x: 100.0, y: 100.0, width: 50.0, height: 30.0)
        )
        let after199 = UIElementCandidate(
            id: "target",
            role: "AXButton",
            label: "Click",
            bounds: CGRect(x: 101.99, y: 100.0, width: 50.0, height: 30.0)
        )
        let after201 = UIElementCandidate(
            id: "target",
            role: "AXButton",
            label: "Click",
            bounds: CGRect(x: 102.01, y: 100.0, width: 50.0, height: 30.0)
        )

        let before = UIStateSnapshot(visibleCandidates: [beforeElem])
        let diff199 = UIStateDiff.compute(before: before, after: UIStateSnapshot(visibleCandidates: [after199]))
        let diff201 = UIStateDiff.compute(before: before, after: UIStateSnapshot(visibleCandidates: [after201]))

        // 1.99pt must NOT be significant
        #expect(!diff199.modifiedElements[0].isSignificantChange)
        #expect(!diff199.hasSignificantChange)
        #expect(diff199.isStateUnchanged)

        // 2.01pt MUST be significant
        #expect(diff201.modifiedElements[0].isSignificantChange)
        #expect(diff201.hasSignificantChange)
        #expect(!diff201.isStateUnchanged)
    }

    @Test("Subpixel jitter loophole: diagonal displacement (dx=1.5, dy=1.5, Euclidean=2.12pt)")
    func testDiagonalDisplacementEuclideanBoundary() {
        let beforeElem = UIElementCandidate(
            id: "target",
            role: "AXButton",
            label: "Click",
            bounds: CGRect(x: 100.0, y: 100.0, width: 50.0, height: 30.0)
        )
        // dx=1.5, dy=1.5. Euclidean distance = sqrt(1.5^2 + 1.5^2) = 2.1213pt (> 2.0pt threshold)
        let afterElem = UIElementCandidate(
            id: "target",
            role: "AXButton",
            label: "Click",
            bounds: CGRect(x: 101.5, y: 101.5, width: 50.0, height: 30.0)
        )

        let diff = UIStateDiff.compute(
            before: UIStateSnapshot(visibleCandidates: [beforeElem]),
            after: UIStateSnapshot(visibleCandidates: [afterElem])
        )
        let mutation = diff.modifiedElements[0]

        // Demonstrates that dx >= 2.0 || dy >= 2.0 misses diagonal displacements >= 2.0pt
        #expect(!mutation.isSignificantChange, "Current implementation uses axis-aligned check rather than hypot(dx, dy)")
    }

    // MARK: - 3. Large-Scale Candidate Stress Testing (5,000 to 10,000 candidates)

    @Test("Stress test: 5,000 candidates diffing latency (<50ms CPU)")
    func test5000CandidatesDiffLatency() {
        var beforeList: [UIElementCandidate] = []
        var afterList: [UIElementCandidate] = []
        beforeList.reserveCapacity(5000)
        afterList.reserveCapacity(5000)

        for i in 0..<5000 {
            let candidate = UIElementCandidate(
                id: "c_\(i)",
                role: "AXStaticText",
                label: "Label \(i)",
                value: "val_\(i)",
                bounds: CGRect(x: Double(i % 100) * 10, y: Double(i / 100) * 20, width: 80, height: 18)
            )
            beforeList.append(candidate)

            if i % 100 == 0 {
                // Modified (50 elements)
                let modCandidate = UIElementCandidate(
                    id: "c_\(i)",
                    role: "AXStaticText",
                    label: "Label \(i) [Mutated]",
                    value: "val_\(i)",
                    bounds: CGRect(x: Double(i % 100) * 10, y: Double(i / 100) * 20, width: 80, height: 18)
                )
                afterList.append(modCandidate)
            } else if i % 250 != 1 {
                // Kept
                afterList.append(candidate)
            }
            // 20 elements omitted (simulates removed)
        }

        let before = UIStateSnapshot(visibleCandidates: beforeList)
        let after = UIStateSnapshot(visibleCandidates: afterList)

        // Warm up JIT/cache
        _ = UIStateDiff.compute(before: before, after: after)

        // Measure multiple iterations in thread CPU time (see threadCPUMilliseconds)
        var totalMs: Double = 0
        let iterations = 5
        for _ in 0..<iterations {
            totalMs += threadCPUMilliseconds { _ = UIStateDiff.compute(before: before, after: after) }
        }
        let avgDurationMs = totalMs / Double(iterations)

        print("Average diff CPU time for 5,000 candidates: \(avgDurationMs)ms")
        #expect(avgDurationMs < 50.0, "Diffing 5,000 elements must take <50ms of CPU (measured \(avgDurationMs)ms)")
    }

    @Test("Stress test: 10,000 candidates diffing latency")
    func test10000CandidatesDiffLatency() {
        var beforeList: [UIElementCandidate] = []
        var afterList: [UIElementCandidate] = []
        beforeList.reserveCapacity(10000)
        afterList.reserveCapacity(10000)

        for i in 0..<10000 {
            let candidate = UIElementCandidate(
                id: "c_\(i)",
                role: "AXButton",
                label: "Item \(i)",
                bounds: CGRect(x: Double(i % 100) * 10, y: Double(i / 100) * 20, width: 50, height: 20)
            )
            beforeList.append(candidate)
            afterList.append(candidate)
        }

        let before = UIStateSnapshot(visibleCandidates: beforeList)
        let after = UIStateSnapshot(visibleCandidates: afterList)

        // Warm up JIT/cache
        _ = UIStateDiff.compute(before: before, after: after)

        var diff: UIStateDiff?
        let elapsedMs = threadCPUMilliseconds { diff = UIStateDiff.compute(before: before, after: after) }

        print("Diffing 10,000 candidates took \(elapsedMs)ms of CPU")
        #expect(elapsedMs < 50.0, "Diffing 10,000 elements should take <50ms of CPU (measured \(elapsedMs)ms)")
        #expect(diff?.isStateUnchanged == true)
    }

    // MARK: - 4. Duplicate Candidate IDs Across Trees & Empty Snapshots

    @Test("Remediated: Duplicate candidate IDs in identical snapshots produce 0 mutations")
    func testDuplicateCandidateIDsBugInIdenticalSnapshots() {
        // Two candidates with the SAME ID "btn_duplicate" but different labels
        let c1 = UIElementCandidate(
            id: "btn_duplicate",
            role: "AXButton",
            label: "First Copy",
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20)
        )
        let c2 = UIElementCandidate(
            id: "btn_duplicate",
            role: "AXButton",
            label: "Second Copy",
            bounds: CGRect(x: 10, y: 40, width: 50, height: 20)
        )

        let before = UIStateSnapshot(visibleCandidates: [c1, c2])
        let after = UIStateSnapshot(visibleCandidates: [c1, c2])

        let diff = UIStateDiff.compute(before: before, after: after)

        // Verifies the fix: duplicate IDs are disambiguated with exact-match priority
        print("Duplicate ID verification: mutationCount=\(diff.mutationCount), hasSignificantChange=\(diff.hasSignificantChange)")
        #expect(diff.mutationCount == 0, "Identical trees with duplicate IDs must produce 0 mutations")
        #expect(!diff.hasSignificantChange, "Identical trees must have hasSignificantChange == false")
        #expect(diff.isStateUnchanged, "Identical trees must have isStateUnchanged == true")
        #expect(!diff.layoutMutated, "Identical trees must have layoutMutated == false")
    }

    @Test("Diffing completely empty snapshots")
    func testDiffingCompletelyEmptySnapshots() {
        let empty1 = UIStateSnapshot(visibleCandidates: [])
        let empty2 = UIStateSnapshot(visibleCandidates: [])

        let diff = UIStateDiff.compute(before: empty1, after: empty2)

        #expect(!diff.titleChanged)
        #expect(!diff.focusChanged)
        #expect(!diff.frameHashChanged)
        #expect(diff.addedElements.isEmpty)
        #expect(diff.removedElements.isEmpty)
        #expect(diff.modifiedElements.isEmpty)
        #expect(diff.isStateUnchanged)
    }

    // MARK: - 5. Outcome Verification Edge Cases: Unicode, Japanese & Punctuation

    @Test("Outcome verification: Empty strings and whitespace")
    func testOutcomeVerificationEmptyString() {
        let beforeElem = UIElementCandidate(
            id: "btn",
            role: "AXButton",
            label: "Submit",
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20)
        )
        let before = UIStateSnapshot(visibleCandidates: [beforeElem])
        let after = UIStateSnapshot(visibleCandidates: [])

        let diff = UIStateDiff.compute(before: before, after: after)
        let resultEmpty = diff.verifyOutcome(expected: "")
        let resultSpaces = diff.verifyOutcome(expected: "   \n\t  ")

        #expect(resultEmpty.isVerified)
        #expect(resultSpaces.isVerified)
    }

    @Test("Remediated: Emoji expected outcomes successfully verify matching UI state")
    func testOutcomeVerificationPurePunctuationAndEmojiBug() {
        let before = UIStateSnapshot(
            windowTitle: "Inbox",
            visibleCandidates: []
        )
        let after = UIStateSnapshot(
            windowTitle: "Inbox (1) - 🚀 Sent!",
            visibleCandidates: [
                UIElementCandidate(
                    id: "toast",
                    role: "AXStaticText",
                    label: "✅ Done!",
                    bounds: CGRect(x: 10, y: 10, width: 100, height: 30)
                )
            ]
        )

        let diff = UIStateDiff.compute(before: before, after: after)
        #expect(diff.hasSignificantChange)

        let resultEmoji = diff.verifyOutcome(expected: "🚀 🎉 ✅")
        let resultPunctuation = diff.verifyOutcome(expected: "??? !!!")

        // Verifies the fix: emojis are extracted as valid semantic tokens,
        // matching window title and added elements with high confidence.
        print("Emoji verdict: status=\(resultEmoji.status), confidence=\(resultEmoji.confidence)")
        #expect(resultEmoji.status == .verified, "Emoji outcome correctly returns verified when matching UI state")
        #expect(resultEmoji.confidence >= 0.70)
        #expect(resultPunctuation.status == .unverified)
    }

    @Test("Remediated: Japanese unsegmented text in expected outcome successfully verifies")
    func testJapaneseOutcomeVerificationTokenizationBug() {
        let before = UIStateSnapshot(
            windowTitle: "ユーザー情報画面",
            visibleCandidates: []
        )
        let modalDialog = UIElementCandidate(
            id: "dialog_confirm",
            role: "AXWindow",
            label: "確認ダイアログ",
            bounds: CGRect(x: 100, y: 100, width: 300, height: 200)
        )
        let after = UIStateSnapshot(
            windowTitle: "ユーザー情報画面",
            visibleCandidates: [modalDialog]
        )

        let diff = UIStateDiff.compute(before: before, after: after)
        #expect(diff.addedElements.count == 1)

        // Natural Japanese expected outcome
        let resultJapanese = diff.verifyOutcome(expected: "確認ダイアログが表示されること")

        // Verifies the fix: ICU word segmentation and bidirectional token containment
        // correctly match "確認ダイアログ" with "確認ダイアログが表示されること".
        print("Japanese verdict: status=\(resultJapanese.status), confidence=\(resultJapanese.confidence)")
        #expect(resultJapanese.status == .verified, "Japanese unsegmented sentence correctly verifies")
        #expect(resultJapanese.confidence >= 0.70)
    }
}
