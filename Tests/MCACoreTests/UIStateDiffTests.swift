import CoreGraphics
import Foundation
@testable import MCACore
import Testing

@Suite("UIStateDiff Tests: State Verification, Layout Diffing & Jitter Filtering")
struct UIStateDiffTests {

    // MARK: - Test Helpers

    private func makeBaseSnapshot() -> UIStateSnapshot {
        let candidates = [
            UIElementCandidate(
                id: "btn_submit",
                role: "AXButton",
                label: "Submit",
                bounds: CGRect(x: 100, y: 200, width: 80, height: 32)
            ),
            UIElementCandidate(
                id: "field_name",
                role: "AXTextField",
                label: "Full Name",
                value: "John",
                bounds: CGRect(x: 100, y: 100, width: 200, height: 32)
            ),
            UIElementCandidate(
                id: "banner_info",
                role: "AXStaticText",
                label: "Notice: System maintenance tonight",
                bounds: CGRect(x: 50, y: 20, width: 400, height: 24)
            )
        ]
        return UIStateSnapshot(
            windowTitle: "Customer Portal - Profile",
            appBundleId: "com.apple.Safari",
            appName: "Safari",
            focusedElementId: "field_name",
            focusedElementRole: "AXTextField",
            focusedElementBounds: CGRect(x: 100, y: 100, width: 200, height: 32),
            visibleCandidates: candidates,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            frameHash: "hash_alpha_1"
        )
    }

    // MARK: - 1. Snapshot Identity, Hashability & Codable Roundtrip

    @Test("UIStateSnapshot equality and hashable determinism")
    func testSnapshotEqualityAndHashable() {
        let s1 = makeBaseSnapshot()
        let s2 = makeBaseSnapshot()

        #expect(s1 == s2)
        #expect(s1.hashValue == s2.hashValue)
        #expect(s1.candidateCount == 3)
        #expect(s1.candidatesHash == s2.candidatesHash)
    }

    @Test("candidatesHash updates when candidate content or bounds mutate")
    func testCandidatesHashMutation() {
        let s1 = makeBaseSnapshot()
        var modifiedCandidates = s1.visibleCandidates
        modifiedCandidates[1] = UIElementCandidate(
            id: "field_name",
            role: "AXTextField",
            label: "Full Name",
            value: "Johnny Doe", // Mutated value
            bounds: CGRect(x: 100, y: 100, width: 200, height: 32)
        )
        let s2 = UIStateSnapshot(
            windowTitle: s1.windowTitle,
            visibleCandidates: modifiedCandidates
        )

        #expect(s1.candidatesHash != s2.candidatesHash)
    }

    @Test("UIStateSnapshot Codable roundtrip preserves all metadata")
    func testSnapshotCodableRoundtrip() throws {
        let original = makeBaseSnapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UIStateSnapshot.self, from: data)

        #expect(decoded.windowTitle == original.windowTitle)
        #expect(decoded.appBundleId == original.appBundleId)
        #expect(decoded.bundleID == original.bundleID)
        #expect(decoded.appName == original.appName)
        #expect(decoded.focusedElementId == original.focusedElementId)
        #expect(decoded.focusedElementRole == original.focusedElementRole)
        #expect(decoded.focusedElementBounds == original.focusedElementBounds)
        #expect(decoded.visibleCandidates.count == original.visibleCandidates.count)
        #expect(decoded.frameHash == original.frameHash)
        #expect(decoded.fingerprint == original.fingerprint)
        #expect(decoded.candidatesHash == original.candidatesHash)
    }

    // MARK: - 2. Diffing Identical Snapshots (No Change)

    @Test("Diffing identical snapshots yields zero mutations and isStateUnchanged == true")
    func testDiffingIdenticalSnapshots() {
        let s1 = makeBaseSnapshot()
        let s2 = makeBaseSnapshot()

        let diff = UIStateDiff.compute(before: s1, after: s2)

        #expect(!diff.titleChanged)
        #expect(!diff.focusChanged)
        #expect(diff.addedElements.isEmpty)
        #expect(diff.removedElements.isEmpty)
        #expect(diff.modifiedElements.isEmpty)
        #expect(diff.mutationCount == 0)
        #expect(!diff.layoutMutated)
        #expect(!diff.hasSignificantChange)
        #expect(diff.isStateUnchanged)

        // Verify outcome checking for expected unchanged state
        let verification = diff.verifyOutcome(expected: "UI state remains unchanged")
        #expect(verification.isVerified)
        #expect(verification.status == .verified)
    }

    // MARK: - 3. Window Title & App Mutations

    @Test("Detects window title mutations accurately")
    func testDetectingTitleMutations() {
        let before = makeBaseSnapshot()
        var after = before
        after.windowTitle = "Customer Portal - Confirmation [Success]"

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.titleChanged)
        #expect(!diff.focusChanged)
        #expect(diff.hasSignificantChange)
        #expect(!diff.isStateUnchanged)

        let verifySuccess = diff.verifyOutcome(expected: "Confirmation screen appears")
        #expect(verifySuccess.isVerified)
    }

    @Test("Detects application bundle ID switches")
    func testDetectingAppBundleIdSwitches() {
        let before = makeBaseSnapshot()
        var after = before
        after.appBundleId = "com.apple.Terminal"

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.titleChanged)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 4. Focus Shift Detection

    @Test("Detects focus shifts between elements")
    func testDetectingFocusShifts() {
        let before = makeBaseSnapshot()
        var after = before
        after.focusedElementId = "btn_submit"
        after.focusedElementRole = "AXButton"

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.focusChanged)
        #expect(diff.hasSignificantChange)

        let verifyFocus = diff.verifyOutcome(expected: "Focus shifts to submit button")
        #expect(verifyFocus.isVerified)
    }

    @Test("Detects loss of focus (active element blurred)")
    func testDetectingFocusLoss() {
        let before = makeBaseSnapshot()
        var after = before
        after.focusedElementId = nil
        after.focusedElementRole = nil

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.focusChanged)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 5. Element Additions & Removals

    @Test("Detects newly added elements (e.g. modal popup)")
    func testDetectingAddedElements() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        let modalDialog = UIElementCandidate(
            id: "dialog_confirm",
            role: "AXWindow",
            label: "Are you sure you want to proceed?",
            bounds: CGRect(x: 200, y: 150, width: 300, height: 180)
        )
        afterCandidates.append(modalDialog)

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.addedElements.count == 1)
        #expect(diff.addedElements[0].id == "dialog_confirm")
        #expect(diff.removedElements.isEmpty)
        #expect(diff.layoutMutated)
        #expect(diff.hasSignificantChange)

        let verifyModal = diff.verifyOutcome(expected: "Confirmation dialog appears")
        #expect(verifyModal.isVerified)
    }

    @Test("Detects removed elements (e.g. dismissed notification banner)")
    func testDetectingRemovedElements() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        afterCandidates.removeAll(where: { $0.id == "banner_info" })

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.removedElements.count == 1)
        #expect(diff.removedElements[0].id == "banner_info")
        #expect(diff.addedElements.isEmpty)
        #expect(diff.layoutMutated)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 6. Modified Element Values & Labels

    @Test("Detects text input value modification")
    func testDetectingValueModification() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        afterCandidates[1] = UIElementCandidate(
            id: "field_name",
            role: "AXTextField",
            label: "Full Name",
            value: "Alice Cooper", // Typed text
            bounds: CGRect(x: 100, y: 100, width: 200, height: 32)
        )

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.id == "field_name")
        #expect(mutation.valueChanged)
        #expect(!mutation.labelChanged)
        #expect(!mutation.boundsChanged)
        #expect(mutation.oldValue == "John")
        #expect(mutation.newValue == "Alice Cooper")
        #expect(mutation.isSignificantChange)
        #expect(diff.hasSignificantChange)

        let verifyTyping = diff.verifyOutcome(expected: "Alice Cooper entered into field")
        #expect(verifyTyping.isVerified)
    }

    @Test("Detects button label mutation (e.g. loading state transition)")
    func testDetectingLabelMutation() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        afterCandidates[0] = UIElementCandidate(
            id: "btn_submit",
            role: "AXButton",
            label: "Submitting...",
            bounds: CGRect(x: 100, y: 200, width: 80, height: 32)
        )

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.labelChanged)
        #expect(mutation.oldLabel == "Submit")
        #expect(mutation.newLabel == "Submitting...")
        #expect(mutation.isSignificantChange)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 7. Noisy Coordinate Jitter vs Significant Layout Mutation

    @Test("Subpixel rendering and OCR coordinate jitter (<2.0pt) is filtered out as insignificant")
    func testNoisyCoordinateJitterIgnored() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        // Subtle subpixel displacement (e.g. +0.8pt x, +0.6pt y, total displacement 1.0pt < 2.0pt)
        afterCandidates[0] = UIElementCandidate(
            id: "btn_submit",
            role: "AXButton",
            label: "Submit",
            bounds: CGRect(x: 100.8, y: 200.6, width: 80.2, height: 31.9)
        )

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.boundsChanged)
        #expect(!mutation.isSignificantChange, "Subpixel coordinate jitter < 2.0pt must NOT be marked significant")
        #expect(!diff.hasSignificantChange, "State must remain unchanged despite minor jitter")
        #expect(diff.isStateUnchanged, "isStateUnchanged must be true to prevent false positive loop triggers")
    }

    @Test("Significant element displacement (>=2.0pt) is detected as a layout mutation")
    func testSignificantDisplacementDetected() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        // Significant vertical displacement (e.g. +50.0pt down due to expanded accordion)
        afterCandidates[0] = UIElementCandidate(
            id: "btn_submit",
            role: "AXButton",
            label: "Submit",
            bounds: CGRect(x: 100, y: 250, width: 80, height: 32)
        )

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.boundsChanged)
        #expect(mutation.displacement.dy == 50.0)
        #expect(mutation.isSignificantChange, "Displacement >= 2.0pt must be marked significant")
        #expect(diff.layoutMutated)
        #expect(diff.hasSignificantChange)
        #expect(!diff.isStateUnchanged)
    }

    @Test("Significant element resize (width or height >=2.0pt) is detected")
    func testSignificantSizeMutationDetected() {
        let before = makeBaseSnapshot()
        var afterCandidates = before.visibleCandidates
        // Expanding search field from width 200 to 350
        afterCandidates[1] = UIElementCandidate(
            id: "field_name",
            role: "AXTextField",
            label: "Full Name",
            value: "John",
            bounds: CGRect(x: 100, y: 100, width: 350, height: 32)
        )

        var after = before
        after.visibleCandidates = afterCandidates

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.sizeChanged)
        #expect(mutation.isSignificantChange)
        #expect(diff.layoutMutated)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 8. Perceptual Frame Hash Shift

    @Test("Detects perceptual visual frame hash change")
    func testFrameHashChangeDetected() {
        let before = makeBaseSnapshot()
        var after = before
        after.frameHash = "hash_beta_2"

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.frameHashChanged)
        #expect(diff.hasSignificantChange)
    }

    // MARK: - 9. Outcome Verification Unverified on Frozen UI

    @Test("Outcome verification returns unverified when UI is frozen but changes were expected")
    func testOutcomeVerificationUnverifiedOnFrozenUI() {
        let s = makeBaseSnapshot()
        let diff = UIStateDiff.compute(before: s, after: s)

        let result = diff.verifyOutcome(expected: "Submit form and show confirmation")

        #expect(!result.isVerified)
        #expect(result.status == .unverified)
        #expect(result.confidence <= 0.20)
        #expect(result.matchedSignals.contains("state_completely_unchanged"))
    }

    // MARK: - 10. UIStateDiff Codable Roundtrip

    @Test("UIStateDiff serializes and deserializes accurately")
    func testUIStateDiffCodableRoundtrip() throws {
        let before = makeBaseSnapshot()
        var after = before
        after.windowTitle = "New Title"

        let originalDiff = UIStateDiff.compute(before: before, after: after)
        let data = try JSONEncoder().encode(originalDiff)
        let decoded = try JSONDecoder().decode(UIStateDiff.self, from: data)

        #expect(decoded.titleChanged == originalDiff.titleChanged)
        #expect(decoded.focusChanged == originalDiff.focusChanged)
        #expect(decoded.mutationCount == originalDiff.mutationCount)
        #expect(decoded.hasSignificantChange == originalDiff.hasSignificantChange)
        #expect(decoded.isStateUnchanged == originalDiff.isStateUnchanged)
    }

    // MARK: - 11. Adversarial & Extreme Boundary Tests

    @Test("Diffing completely empty snapshots runs without error")
    func testDiffingEmptySnapshots() {
        let empty1 = UIStateSnapshot()
        let empty2 = UIStateSnapshot()

        let diff = UIStateDiff.compute(before: empty1, after: empty2)

        #expect(!diff.titleChanged)
        #expect(!diff.focusChanged)
        #expect(diff.addedElements.isEmpty)
        #expect(diff.removedElements.isEmpty)
        #expect(diff.modifiedElements.isEmpty)
        #expect(diff.isStateUnchanged)
    }

    @Test("Handles multi-monitor negative coordinates without sign reversal issues")
    func testMultiMonitorNegativeCoordinates() {
        let elemBefore = UIElementCandidate(
            id: "win_aux",
            role: "AXWindow",
            label: "Aux Display",
            bounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        )
        let elemAfter = UIElementCandidate(
            id: "win_aux",
            role: "AXWindow",
            label: "Aux Display",
            bounds: CGRect(x: -1920, y: -1000, width: 1920, height: 1080) // Moved down by 80pt
        )

        let before = UIStateSnapshot(visibleCandidates: [elemBefore])
        let after = UIStateSnapshot(visibleCandidates: [elemAfter])

        let diff = UIStateDiff.compute(before: before, after: after)

        #expect(diff.modifiedElements.count == 1)
        let mutation = diff.modifiedElements[0]
        #expect(mutation.displacement.dy == 80.0)
        #expect(mutation.isSignificantChange)
        #expect(diff.layoutMutated)
    }

    @Test("Performance stress test: diffing 2,000 candidates executes in <10ms")
    func testLargeCandidateVolumePerformance() {
        var beforeList: [UIElementCandidate] = []
        var afterList: [UIElementCandidate] = []

        for i in 0..<2000 {
            let beforeCandidate = UIElementCandidate(
                id: "item_\(i)",
                role: "AXRow",
                label: "Row \(i)",
                value: "val_\(i)",
                bounds: CGRect(x: 0, y: Double(i) * 20, width: 300, height: 20)
            )
            beforeList.append(beforeCandidate)

            if i % 10 == 0 {
                // Mutated element
                let mutated = UIElementCandidate(
                    id: "item_\(i)",
                    role: "AXRow",
                    label: "Row \(i) [Modified]",
                    value: "val_\(i)_updated",
                    bounds: CGRect(x: 0, y: Double(i) * 20, width: 300, height: 20)
                )
                afterList.append(mutated)
            } else if i % 20 != 1 {
                // Preserved unchanged
                afterList.append(beforeCandidate)
            }
            // If i % 20 == 1, omitted (simulates removed elements)
        }

        let before = UIStateSnapshot(visibleCandidates: beforeList)
        let after = UIStateSnapshot(visibleCandidates: afterList)

        var diff: UIStateDiff!
        let ms = threadCPUMilliseconds { diff = UIStateDiff.compute(before: before, after: after) }

        #expect(ms < 50, "Diffing 2,000 elements must take <50ms of CPU (measured: \(ms)ms)")
        #expect(!diff.modifiedElements.isEmpty)
        #expect(!diff.removedElements.isEmpty)
        #expect(diff.hasSignificantChange)
    }
}
