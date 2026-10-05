import CoreGraphics
import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

@Suite("SafetyGuardrails & SubgoalPlan Adversarial Stress Tests")
struct SafetyGuardrailsAdversarialTests {

    // MARK: - 1. Step Budget Extreme Boundaries

    @Test("StepBudget: maxSteps = 0 immediately rejects with stepBudgetExceeded(0)")
    func testStepBudgetMaxStepsZeroImmediateRejection() throws {
        var monitor = StepBudgetMonitor(maxSteps: 0, maxSubgoalSteps: nil)
        #expect(monitor.remainingSteps == 0)
        #expect(monitor.totalStepsExecuted == 0)

        #expect(throws: LoopExecutionError.stepBudgetExceeded(steps: 0)) {
            try monitor.increment()
        }
        #expect(monitor.totalStepsExecuted == 0)
    }

    @Test("StepBudget: maxSteps = 1 exact boundary (1 step succeeds, 2nd throws)")
    func testStepBudgetMaxStepsOneBoundary() throws {
        var monitor = StepBudgetMonitor(maxSteps: 1, maxSubgoalSteps: nil)
        #expect(monitor.remainingSteps == 1)

        // Step 1: must succeed
        try monitor.increment()
        #expect(monitor.totalStepsExecuted == 1)
        #expect(monitor.remainingSteps == 0)

        // Step 2: must throw with step count 1
        #expect(throws: LoopExecutionError.stepBudgetExceeded(steps: 1)) {
            try monitor.increment()
        }
        #expect(monitor.totalStepsExecuted == 1)
    }

    @Test("StepBudget: maxSubgoalSteps set lower than remaining global budget")
    func testStepBudgetSubgoalBudgetLowerThanGlobal() throws {
        var monitor = StepBudgetMonitor(maxSteps: 10, maxSubgoalSteps: 2)

        // Subgoal step 1
        try monitor.increment()
        #expect(monitor.totalStepsExecuted == 1)
        #expect(monitor.currentSubgoalSteps == 1)

        // Subgoal step 2
        try monitor.increment()
        #expect(monitor.totalStepsExecuted == 2)
        #expect(monitor.currentSubgoalSteps == 2)

        // Subgoal step 3: must throw because currentSubgoalSteps (2) >= maxSubgoalSteps (2),
        // even though global remainingSteps is 8
        #expect(monitor.remainingSteps == 8)
        #expect(throws: LoopExecutionError.stepBudgetExceeded(steps: 2)) {
            try monitor.increment()
        }

        // After resetting subgoal budget (e.g. subgoal transition), execution can continue
        monitor.resetSubgoalBudget()
        #expect(monitor.currentSubgoalSteps == 0)
        #expect(monitor.totalStepsExecuted == 2)

        try monitor.increment()
        #expect(monitor.currentSubgoalSteps == 1)
        #expect(monitor.totalStepsExecuted == 3)
    }

    @Test("StepBudget: cumulative subgoals correctly halt when global maxSteps reached")
    func testStepBudgetCumulativeSubgoalsReachGlobalLimit() throws {
        var monitor = StepBudgetMonitor(maxSteps: 4, maxSubgoalSteps: 3)

        // Subgoal 1: 2 steps
        try monitor.increment()
        try monitor.increment()
        monitor.resetSubgoalBudget()

        // Subgoal 2: 2 steps -> total reaches 4
        try monitor.increment()
        try monitor.increment()
        #expect(monitor.totalStepsExecuted == 4)
        #expect(monitor.remainingSteps == 0)

        // Next step in Subgoal 2: must throw global limit (4), not subgoal limit
        #expect(throws: LoopExecutionError.stepBudgetExceeded(steps: 4)) {
            try monitor.increment()
        }
    }

    actor SynchronizedStepMonitor {
        private var monitor: StepBudgetMonitor
        private(set) var successfulIncrements = 0
        private(set) var exceededErrors = 0

        init(maxSteps: Int) {
            self.monitor = StepBudgetMonitor(maxSteps: maxSteps, maxSubgoalSteps: nil)
        }

        func attemptIncrement() -> Bool {
            do {
                try monitor.increment()
                successfulIncrements += 1
                return true
            } catch {
                exceededErrors += 1
                return false
            }
        }

        func totalSteps() -> Int {
            monitor.totalStepsExecuted
        }
    }

    @Test("StepBudget: concurrent increments stress test")
    func testStepBudgetConcurrentIncrementsStress() async throws {
        let budgetLimit = 25
        let totalAttempts = 100
        let syncMonitor = SynchronizedStepMonitor(maxSteps: budgetLimit)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<totalAttempts {
                group.addTask {
                    _ = await syncMonitor.attemptIncrement()
                }
            }
        }

        let successes = await syncMonitor.successfulIncrements
        let failures = await syncMonitor.exceededErrors
        let finalSteps = await syncMonitor.totalSteps()

        #expect(successes == budgetLimit, "Expected exactly \(budgetLimit) successes, got \(successes)")
        #expect(failures == totalAttempts - budgetLimit, "Expected \(totalAttempts - budgetLimit) failures, got \(failures)")
        #expect(finalSteps == budgetLimit, "Total executed steps must match budget limit")
    }

    // MARK: - 2. Loop Detector Subpixel Coordinate Jitter Tests

    @Test("LoopDetector: subpixel jitter <= 2.0pt is treated as identical action")
    func testCoordinateJitterWithinToleranceIsIdentical() {
        let decA = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 100.0, y: 100.0)
        )
        // Displaced by 1.99pt along X axis
        let decB = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 101.99, y: 100.0)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == true, "Displacement of 1.99pt must be treated as identical within 2.0pt tolerance")
    }

    @Test("LoopDetector: subpixel jitter > 2.0pt is NOT treated as identical action")
    func testCoordinateJitterExceedingToleranceIsNotIdentical() {
        let decA = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 100.0, y: 100.0)
        )
        // Displaced by 2.01pt along X axis
        let decB = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 102.01, y: 100.0)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == false, "Displacement of 2.01pt must exceed 2.0pt tolerance")
    }

    @Test("LoopDetector: exact boundary jitter (2.00pt) is treated as identical action")
    func testCoordinateJitterExactBoundary() {
        let decA = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 100.0, y: 100.0)
        )
        let decB = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: 102.0, y: 100.0)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == true, "Exact boundary 2.00pt displacement must be treated as identical")
    }

    @Test("LoopDetector: consecutive jitter <= 2.0pt triggers Factor 1 infinite loop detection")
    func testConsecutiveJitterUnderToleranceTriggersLoopDetection() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3, coordinateTolerance: 2.0))

        let step1 = ComputerActionDecision(action: .click, coordinates: CGPoint(x: 100.0, y: 100.0))
        let step2 = ComputerActionDecision(action: .click, coordinates: CGPoint(x: 101.5, y: 101.0))
        let step3 = ComputerActionDecision(action: .click, coordinates: CGPoint(x: 102.8, y: 102.0))

        try detector.recordAction(decision: step1)
        #expect(detector.consecutiveIdenticalActionCount == 1)

        try detector.recordAction(decision: step2)
        #expect(detector.consecutiveIdenticalActionCount == 2)

        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: step3)
        }
    }

    @Test("LoopDetector: alternating displacement > 2.0pt resets identical action counter")
    func testAlternatingJitterExceedingToleranceDoesNotTriggerLoopDetection() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3, coordinateTolerance: 2.0))

        let posA = ComputerActionDecision(action: .click, coordinates: CGPoint(x: 100.0, y: 100.0))
        let posB = ComputerActionDecision(action: .click, coordinates: CGPoint(x: 105.0, y: 100.0))

        for _ in 0..<5 {
            try detector.recordAction(decision: posA)
            #expect(detector.consecutiveIdenticalActionCount == 1)
            try detector.recordAction(decision: posB)
            #expect(detector.consecutiveIdenticalActionCount == 1)
        }
    }

    // MARK: - 3. Non-Finite Coordinate & Distance Robustness

    @Test("LoopDetector: NaN coordinates in distance comparison do not match and do not crash")
    func testNanCoordinatesInDistanceComparisonDoNotCrash() {
        let decA = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: CGFloat.nan, y: 100.0)
        )
        let decB = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: 100.0, y: 100.0)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == false, "NaN coordinate must evaluate to false in distance comparison")
    }

    @Test("LoopDetector: both NaN coordinates do not match (NaN != NaN in IEEE-754)")
    func testBothNanCoordinatesDoNotFalselyMatch() {
        let decA = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        )
        let decB = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == false, "Both NaN coordinates must evaluate to false")
    }

    @Test("LoopDetector: Infinity coordinates in distance comparison do not crash")
    func testInfinityCoordinatesInDistanceComparison() {
        let decA = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: CGFloat.infinity, y: 100.0)
        )
        let decB = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: 100.0, y: 100.0)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(decA, decB, tolerance: 2.0)
        #expect(isEquivalent == false, "Infinity coordinate must evaluate to false")
    }

    @Test("Subprocess test: verify NaN coordinate casting to Int crashes standard runtime")
    func testIntCastOfNanInSubprocessExitsWithCrash() throws {
        // Empirically verifies the safety vulnerability in `Int(pt.x)` when pt.x is NaN
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["-e", "let x = Double.nan; _ = Int(x)"]
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0, "Casting Double.nan to Int must cause a fatal runtime crash")
    }

    // MARK: - 4. Action Oscillation & Factor 2 State Stagnation

    @Test("LoopDetector: alternating action oscillation does not trigger Factor 1")
    func testActionOscillationDoesNotTriggerFactor1() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let actionA = ComputerActionDecision(targetElementId: "btn_a", action: .click)
        let actionB = ComputerActionDecision(targetElementId: "btn_b", action: .click)

        for _ in 0..<10 {
            try detector.recordAction(decision: actionA)
            #expect(detector.consecutiveIdenticalActionCount == 1)
            try detector.recordAction(decision: actionB)
            #expect(detector.consecutiveIdenticalActionCount == 1)
        }
    }

    @Test("LoopDetector: action oscillation with invariant UI state DOES trigger Factor 2")
    func testActionOscillationWithUnchangedStateTriggersFactor2() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3, unchangedStateThreshold: 3))

        let actionA = ComputerActionDecision(targetElementId: "btn_a", action: .click)
        let actionB = ComputerActionDecision(targetElementId: "btn_b", action: .click)
        let stagnantDiff = UIStateDiff(
            titleChanged: false,
            focusChanged: false,
            addedElements: [],
            removedElements: [],
            modifiedElements: [],
            frameHashChanged: false
        )
        #expect(stagnantDiff.isStateUnchanged == true)

        // Step 1: Action A, UI unchanged
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: stagnantDiff)
        #expect(detector.consecutiveUnchangedStateCount == 1)

        // Step 2: Action B, UI unchanged
        try detector.recordAction(decision: actionB)
        try detector.recordStateDiff(diff: stagnantDiff)
        #expect(detector.consecutiveUnchangedStateCount == 2)

        // Step 3: Action A, UI unchanged -> Factor 2 MUST catch the stagnant loop
        try detector.recordAction(decision: actionA)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: stagnantDiff)
        }
    }

    @Test("LoopDetector: Factor 2 resets counter when meaningful UI change occurs")
    func testFactor2ResetsOnStateChange() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 3))

        let stagnantDiff = UIStateDiff(
            titleChanged: false,
            focusChanged: false,
            addedElements: [],
            removedElements: [],
            modifiedElements: []
        )
        let changedDiff = UIStateDiff(
            titleChanged: true,
            focusChanged: false,
            addedElements: [],
            removedElements: [],
            modifiedElements: []
        )

        try detector.recordStateDiff(diff: stagnantDiff)
        #expect(detector.consecutiveUnchangedStateCount == 1)

        try detector.recordStateDiff(diff: stagnantDiff)
        #expect(detector.consecutiveUnchangedStateCount == 2)

        // State change on step 3 resets counter to 0
        try detector.recordStateDiff(diff: changedDiff)
        #expect(detector.consecutiveUnchangedStateCount == 0)

        // Steps 4 and 5 unchanged -> counter reaches 2, no error
        try detector.recordStateDiff(diff: stagnantDiff)
        try detector.recordStateDiff(diff: stagnantDiff)
        #expect(detector.consecutiveUnchangedStateCount == 2)
    }

    // MARK: - Progress-Aware Loop Detection Tests (R1)

    @Test("LoopDetector: continuous exploratory scroll with progress does NOT trigger Factor 1")
    func testContinuousExploratoryScrollWithProgressDoesNotTriggerFactor1() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let scrollDecision = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -100))

        // Simulate 6 consecutive scroll actions where each step produces screen mutations (e.g. feed items moving/appearing)
        for i in 1...6 {
            try detector.recordAction(decision: scrollDecision)
            #expect(detector.consecutiveIdenticalActionCount == i)

            let movingCandidate = UIElementCandidate(
                id: "item_\(i)",
                role: "AXRow",
                label: "Feed Item \(i)",
                bounds: CGRect(x: 100, y: CGFloat(i * 50), width: 400, height: 40)
            )
            let progressiveDiff = UIStateDiff(
                titleChanged: false,
                focusChanged: false,
                addedElements: [movingCandidate],
                removedElements: [],
                modifiedElements: []
            )
            #expect(progressiveDiff.hasSignificantChange == true)

            // Must NOT throw even after 3, 4, 5, 6 repetitions
            try detector.recordStateDiff(diff: progressiveDiff)
            #expect(detector.consecutiveUnchangedStateCount == 0)
        }
    }

    @Test("LoopDetector: scroll at page boundary triggers action stagnation")
    func testScrollAtPageBoundaryTriggersStagnation() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let scrollDecision = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -100))

        // Step 1: Scroll with progress
        try detector.recordAction(decision: scrollDecision)
        let progressiveDiff = UIStateDiff(
            titleChanged: false,
            focusChanged: false,
            addedElements: [UIElementCandidate(id: "item_1", role: "AXRow", label: "Item 1", bounds: .zero)]
        )
        try detector.recordStateDiff(diff: progressiveDiff)

        // Step 2: Scroll with progress
        try detector.recordAction(decision: scrollDecision)
        try detector.recordStateDiff(diff: progressiveDiff)

        // Step 3: Scroll reaches bottom (invariant / unchanged state diff)
        try detector.recordAction(decision: scrollDecision)
        let boundaryDiff = UIStateDiff(
            titleChanged: false,
            focusChanged: false,
            addedElements: [],
            removedElements: [],
            modifiedElements: []
        )
        #expect(boundaryDiff.isStateUnchanged == true)

        // Must throw infiniteLoopDetected with action stagnation reason
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: boundaryDiff)
        }
    }

    @Test("LoopDetector: continuous exploratory scroll breaching exploration ceiling triggers Factor 1")
    func testContinuousExploratoryScrollBreachingCeilingTriggersFactor1() throws {
        var detector = TwoFactorLoopDetector(config: .init(
            identicalActionThreshold: 3,
            maxExplorationRepetitionCeiling: 10
        ))

        let scrollDecision = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -100))

        // Steps 1 to 9: scrolls with screen changes pass
        for i in 1...9 {
            try detector.recordAction(decision: scrollDecision)
            let progressiveDiff = UIStateDiff(
                titleChanged: false,
                focusChanged: false,
                addedElements: [UIElementCandidate(id: "item_\(i)", role: "AXRow", label: "Item \(i)", bounds: .zero)],
                removedElements: [],
                modifiedElements: []
            )
            try detector.recordStateDiff(diff: progressiveDiff)
        }

        // Step 10: reaches maxExplorationRepetitionCeiling (10) -> recordAction throws ceiling error
        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: scrollDecision)
        }
    }

    @Test("LoopDetector: wait action respects waitActionThreshold before triggering Factor 1")
    func testWaitActionThresholdExtended() throws {
        var detector = TwoFactorLoopDetector(config: .init(
            identicalActionThreshold: 3,
            waitActionThreshold: 6
        ))

        let waitDecision = ComputerActionDecision(action: .wait)

        // Steps 1 to 5: within threshold (6), should not throw on recordAction
        for _ in 1...5 {
            try detector.recordAction(decision: waitDecision)
        }

        // Step 6: reaches waitActionThreshold (6) -> throws
        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: waitDecision)
        }
    }

    @Test("LoopDetector: repeatable key presses (e.g. Backspace) respect repeatableKeyPressThreshold")
    func testRepeatableKeyPressThreshold() throws {
        var detector = TwoFactorLoopDetector(config: .init(
            identicalActionThreshold: 3,
            repeatableKeyPressThreshold: 8
        ))

        let backspaceDecision = ComputerActionDecision(action: .keyPress, keyCombination: ["Backspace"])

        // Steps 1 to 7: within threshold (8), should not throw
        for _ in 1...7 {
            try detector.recordAction(decision: backspaceDecision)
        }

        // Step 8: reaches repeatableKeyPressThreshold (8) -> throws
        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: backspaceDecision)
        }
    }

    @Test("LoopDetector: structural oscillation detected despite frameHash pixel jitter")
    func testStructuralOscillationDetectedDespitePixelJitter() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 5))

        let actionA = ComputerActionDecision(targetElementId: "btn_tab_a", action: .click)
        let actionB = ComputerActionDecision(targetElementId: "btn_tab_b", action: .click)

        let candidatesA = [
            UIElementCandidate(id: "btn_tab_a", role: "AXButton", label: "Tab A", bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        ]
        let candidatesB = [
            UIElementCandidate(id: "btn_tab_b", role: "AXButton", label: "Tab B", bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        ]

        // Snapshots have fluctuating frameHash (due to blinking cursor / clock / pixel jitter)
        let snapA1 = UIStateSnapshot(windowTitle: "Tab Screen", appName: "App", visibleCandidates: candidatesA, frameHash: "hash_a_1")
        let snapB1 = UIStateSnapshot(windowTitle: "Tab Screen", appName: "App", visibleCandidates: candidatesB, frameHash: "hash_b_1")
        let snapA2 = UIStateSnapshot(windowTitle: "Tab Screen", appName: "App", visibleCandidates: candidatesA, frameHash: "hash_a_2")
        let snapB2 = UIStateSnapshot(windowTitle: "Tab Screen", appName: "App", visibleCandidates: candidatesB, frameHash: "hash_b_2")

        let diffA1 = UIStateDiff.compute(before: snapB1, after: snapA1)
        let diffB1 = UIStateDiff.compute(before: snapA1, after: snapB1)
        let diffA2 = UIStateDiff.compute(before: snapB1, after: snapA2)
        let diffB2 = UIStateDiff.compute(before: snapA2, after: snapB2)

        // Cycle 1: -> A
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffA1)

        // Cycle 2: -> B
        try detector.recordAction(decision: actionB)
        try detector.recordStateDiff(diff: diffB1)

        // Cycle 3: -> A (with jittered pixel hash)
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffA2)

        // Cycle 4: -> B (with jittered pixel hash - 2-cycle oscillation detected via structuralHash!)
        try detector.recordAction(decision: actionB)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffB2)
        }
    }

    @Test("LoopDetector: rollbackLastAction restores action history and consecutive count")
    func testRollbackLastActionRestoresCount() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))
        let clickDecision = ComputerActionDecision(targetElementId: "btn_1", action: .click)

        try detector.recordAction(decision: clickDecision)
        #expect(detector.consecutiveIdenticalActionCount == 1)

        try detector.recordAction(decision: clickDecision)
        #expect(detector.consecutiveIdenticalActionCount == 2)

        // Rollback simulating hardware dispatch failure
        detector.rollbackLastAction()
        #expect(detector.consecutiveIdenticalActionCount == 1)

        // Another click will now be count 2 instead of count 3
        try detector.recordAction(decision: clickDecision)
        #expect(detector.consecutiveIdenticalActionCount == 2)
    }

    @Test("LoopDetector: virtualized list with reused DOM IDs differentiates states via candidate labels")
    func testVirtualizedListWithReusedDOMIDsDifferentiatesStates() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 3))

        let scrollDown = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -100))

        // Page 1 of virtualized feed: elements have static IDs and roles, but labels correspond to items 1..3
        let snapPage1 = UIStateSnapshot(windowTitle: "Feed", appName: "App", visibleCandidates: [
            UIElementCandidate(id: "cell_0", role: "AXRow", label: "Post #1: Hello", bounds: CGRect(x: 0, y: 0, width: 200, height: 50)),
            UIElementCandidate(id: "cell_1", role: "AXRow", label: "Post #2: World", bounds: CGRect(x: 0, y: 50, width: 200, height: 50)),
            UIElementCandidate(id: "cell_2", role: "AXRow", label: "Post #3: Swift", bounds: CGRect(x: 0, y: 100, width: 200, height: 50))
        ])

        // Page 2 of virtualized feed: DOM nodes are reused (cell_0..cell_2, AXRow), but labels now show items 4..6
        let snapPage2 = UIStateSnapshot(windowTitle: "Feed", appName: "App", visibleCandidates: [
            UIElementCandidate(id: "cell_0", role: "AXRow", label: "Post #4: Agents", bounds: CGRect(x: 0, y: 0, width: 200, height: 50)),
            UIElementCandidate(id: "cell_1", role: "AXRow", label: "Post #5: Loop", bounds: CGRect(x: 0, y: 50, width: 200, height: 50)),
            UIElementCandidate(id: "cell_2", role: "AXRow", label: "Post #6: Defense", bounds: CGRect(x: 0, y: 100, width: 200, height: 50))
        ])

        let fp1 = TwoFactorLoopDetector.StateFingerprint(snapshot: snapPage1)
        let fp2 = TwoFactorLoopDetector.StateFingerprint(snapshot: snapPage2)

        // Must NOT be equal because semantic labels differ despite identical IDs and roles
        #expect(fp1.structuralHash != fp2.structuralHash)
        #expect(fp1 != fp2)

        // Verifying that scrolling from Page 1 to Page 2 does not falsely flag an unchanged state
        let diff = UIStateDiff.compute(before: snapPage1, after: snapPage2)
        try detector.recordAction(decision: scrollDown)
        try detector.recordStateDiff(diff: diff)
        #expect(detector.consecutiveUnchangedStateCount == 0, "Moving to new virtualized content must count as significant progress")
    }

    @Test("LoopDetector: 2-cycle alternating state oscillation triggers Factor 2")
    func testStateOscillationDetectionAB_AB() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 5))

        let actionA = ComputerActionDecision(targetElementId: "btn_tab_a", action: .click)
        let actionB = ComputerActionDecision(targetElementId: "btn_tab_b", action: .click)

        let snapA = UIStateSnapshot(windowTitle: "Tab A Screen", visibleCandidates: [
            UIElementCandidate(id: "btn_tab_a", role: "AXButton", label: "Tab A", bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        ])
        let snapB = UIStateSnapshot(windowTitle: "Tab B Screen", visibleCandidates: [
            UIElementCandidate(id: "btn_tab_b", role: "AXButton", label: "Tab B", bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        ])

        // Cycle 1: -> A
        let diffA1 = UIStateDiff.compute(before: snapB, after: snapA)
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffA1)

        // Cycle 2: -> B
        let diffB1 = UIStateDiff.compute(before: snapA, after: snapB)
        try detector.recordAction(decision: actionB)
        try detector.recordStateDiff(diff: diffB1)

        // Cycle 3: -> A
        let diffA2 = UIStateDiff.compute(before: snapB, after: snapA)
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffA2)

        // Cycle 4: -> B (A -> B -> A -> B complete: 2-cycle oscillation detected!)
        let diffB2 = UIStateDiff.compute(before: snapA, after: snapB)
        try detector.recordAction(decision: actionB)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffB2)
        }
    }

    @Test("LoopDetector: cyclic state revisit detection")
    func testCyclicStateRevisitDetection() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 3))

        let action = ComputerActionDecision(targetElementId: "btn_cycle", action: .click)

        let snapA = UIStateSnapshot(windowTitle: "State A", visibleCandidates: [
            UIElementCandidate(id: "item_a", role: "AXStaticText", label: "A", bounds: .zero)
        ])
        let snapB = UIStateSnapshot(windowTitle: "State B", visibleCandidates: [
            UIElementCandidate(id: "item_b", role: "AXStaticText", label: "B", bounds: .zero)
        ])
        let snapC = UIStateSnapshot(windowTitle: "State C", visibleCandidates: [
            UIElementCandidate(id: "item_c", role: "AXStaticText", label: "C", bounds: .zero)
        ])

        let diffA_B = UIStateDiff.compute(before: snapA, after: snapB)
        let diffB_C = UIStateDiff.compute(before: snapB, after: snapC)
        let diffC_A = UIStateDiff.compute(before: snapC, after: snapA)

        // A -> B -> C -> A -> B -> C -> A (State A visited 3 times)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffC_A) // visit 1
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffA_B)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffB_C)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffC_A) // visit 2
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffA_B)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffB_C)

        // Visit 3 to State A: must trigger cycle detection
        try detector.recordAction(decision: action)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffC_A)
        }
    }

    @Test("LoopDetector: interim unchanged state does not trigger false positive 3-cycle on visit 2")
    func testCyclicStateRevisitWithUnchangedInterimStateDoesNotFalseTrigger() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 3))

        let action = ComputerActionDecision(targetElementId: "btn_action", action: .click)

        let snapA = UIStateSnapshot(windowTitle: "State A", visibleCandidates: [
            UIElementCandidate(id: "item_a", role: "AXStaticText", label: "A", bounds: .zero)
        ])
        let snapB = UIStateSnapshot(windowTitle: "State B", visibleCandidates: [
            UIElementCandidate(id: "item_b", role: "AXStaticText", label: "B", bounds: .zero)
        ])
        let snapC = UIStateSnapshot(windowTitle: "State C", visibleCandidates: [
            UIElementCandidate(id: "item_c", role: "AXStaticText", label: "C", bounds: .zero)
        ])

        let diffToA = UIStateDiff.compute(before: snapC, after: snapA)
        let diffA_Unchanged = UIStateDiff.compute(before: snapA, after: snapA)
        let diffA_B = UIStateDiff.compute(before: snapA, after: snapB)
        let diffB_C = UIStateDiff.compute(before: snapB, after: snapC)
        let diffC_A = UIStateDiff.compute(before: snapC, after: snapA)

        // Step 1: Arrive at State A (Visit 1)
        try detector.recordAction(decision: action)
        try detector.recordStateDiff(diff: diffToA)

        // Step 2: Unchanged action while staying in State A
        try detector.recordAction(decision: ComputerActionDecision(targetElementId: "btn_noop", action: .click))
        try detector.recordStateDiff(diff: diffA_Unchanged)

        // Step 3: Transition A -> B -> C
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffA_B)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffB_C)

        // Step 4: Transition back to State A (Visit 2 - NOT a 3-cycle!)
        try detector.recordAction(decision: action)
        // Must NOT throw on visit 2
        try detector.recordStateDiff(diff: diffC_A)

        // Step 5: Transition A -> B -> C
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffA_B)
        try detector.recordAction(decision: action); try detector.recordStateDiff(diff: diffB_C)

        // Step 6: Transition back to State A (Visit 3 - genuine 3-cycle!)
        try detector.recordAction(decision: action)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffC_A)
        }
    }

    @Test("LoopDetector: 2-cycle oscillation with interim unchanged step is preserved and detected")
    func testStateOscillationWithInterimUnchangedStepIsStillDetected() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 5))

        let actionA = ComputerActionDecision(targetElementId: "btn_tab_a", action: .click)
        let actionB = ComputerActionDecision(targetElementId: "btn_tab_b", action: .click)

        let snapA = UIStateSnapshot(windowTitle: "Tab A Screen", visibleCandidates: [
            UIElementCandidate(id: "btn_tab_a", role: "AXButton", label: "Tab A", bounds: CGRect(x: 10, y: 10, width: 80, height: 30))
        ])
        let snapB = UIStateSnapshot(windowTitle: "Tab B Screen", visibleCandidates: [
            UIElementCandidate(id: "btn_tab_b", role: "AXButton", label: "Tab B", bounds: CGRect(x: 100, y: 10, width: 80, height: 30))
        ])

        let diffToA = UIStateDiff.compute(before: snapB, after: snapA)
        let diffToB = UIStateDiff.compute(before: snapA, after: snapB)
        let diffB_Unchanged = UIStateDiff.compute(before: snapB, after: snapB)

        // Cycle 1: -> A
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffToA)

        // Cycle 2: -> B
        try detector.recordAction(decision: actionB)
        try detector.recordStateDiff(diff: diffToB)

        // Interim step: stay in B (e.g. slow response / no-op)
        try detector.recordAction(decision: ComputerActionDecision(targetElementId: "btn_other", action: .click))
        try detector.recordStateDiff(diff: diffB_Unchanged)

        // Cycle 3: -> A
        try detector.recordAction(decision: actionA)
        try detector.recordStateDiff(diff: diffToA)

        // Cycle 4: -> B (A -> B -> A -> B complete: 2-cycle oscillation detected!)
        try detector.recordAction(decision: actionB)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffToB)
        }
    }

    @Test("LoopDetector: alternating scroll directions bouncing between 2 states triggers oscillation")
    func testAlternatingScrollDirectionsOscillationDetection() throws {
        var detector = TwoFactorLoopDetector(config: .init(unchangedStateThreshold: 5))

        let scrollDown = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -100))
        let scrollUp = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: 100))

        let snapTop = UIStateSnapshot(windowTitle: "Page Top", visibleCandidates: [
            UIElementCandidate(id: "header", role: "AXStaticText", label: "Header", bounds: CGRect(x: 10, y: 10, width: 200, height: 30))
        ])
        let snapScrolled = UIStateSnapshot(windowTitle: "Page Scrolled", visibleCandidates: [
            UIElementCandidate(id: "content", role: "AXRow", label: "Content", bounds: CGRect(x: 10, y: 10, width: 200, height: 30))
        ])

        let diffDown = UIStateDiff.compute(before: snapTop, after: snapScrolled)
        let diffUp = UIStateDiff.compute(before: snapScrolled, after: snapTop)

        // Step 1: Scroll down -> snapScrolled
        try detector.recordAction(decision: scrollDown)
        try detector.recordStateDiff(diff: diffDown)

        // Step 2: Scroll up -> snapTop
        try detector.recordAction(decision: scrollUp)
        try detector.recordStateDiff(diff: diffUp)

        // Step 3: Scroll down -> snapScrolled
        try detector.recordAction(decision: scrollDown)
        try detector.recordStateDiff(diff: diffDown)

        // Step 4: Scroll up -> snapTop (completes 2-cycle oscillation)
        try detector.recordAction(decision: scrollUp)
        #expect(throws: LoopExecutionError.self) {
            try detector.recordStateDiff(diff: diffUp)
        }
    }

    // MARK: - 5. Cancellation Race Conditions

    @Test("CancellationToken: immediate cancellation before execution")
    func testCancellationTokenImmediateCancellation() throws {
        let token = CancellationToken()
        token.cancel()

        #expect(token.isCancelled == true)
        #expect(throws: LoopExecutionError.cancelled) {
            try token.throwIfCancelled()
        }
    }

    @Test("CancellationToken: async sleep aborts quickly upon cancellation")
    func testCancellationTokenAsyncSleepInterruption() async throws {
        let token = CancellationToken()
        let startTime = Date()

        // Long enough that it can never finish on its own, even on a loaded machine:
        // a `.cancelled` throw can then only come from the cancellation.
        let sleepTask = Task {
            try await token.sleep(milliseconds: 60_000)
        }

        // Cancel after 30ms
        try await Task.sleep(for: .milliseconds(30))
        token.cancel()

        var caughtCancelled = false
        do {
            try await sleepTask.value
        } catch {
            if let loopErr = error as? LoopExecutionError, loopErr == .cancelled {
                caughtCancelled = true
            }
        }

        let elapsedMs = Date().timeIntervalSince(startTime) * 1000
        #expect(caughtCancelled == true, "Sleeping task must throw LoopExecutionError.cancelled")
        #expect(elapsedMs < 30_000, "Sleep must abort well before its full 60s duration (took \(elapsedMs)ms)")
    }

    @Test("CancellationToken: concurrent cancellation calls invoke onCancel exactly once")
    func testCancellationTokenConcurrentCancelStress() async throws {
        let token = CancellationToken()
        let counter = Counter()

        token.onCancel {
            counter.increment()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    token.cancel()
                }
            }
        }

        #expect(token.isCancelled == true)
        #expect(counter.value == 1, "onCancel handler must be invoked exactly once under 100 concurrent cancels")
    }

    @Test("CancellationToken: onCancel registered after cancellation runs immediately")
    func testCancellationTokenLateOnCancelRegistration() {
        let token = CancellationToken()
        token.cancel()

        let counter = Counter()
        token.onCancel {
            counter.increment()
        }

        #expect(counter.value == 1, "onCancel handler registered on already-cancelled token must execute immediately")
    }

    // MARK: - 6. Hardware Safety & Emergency Release

    @Test("HardwareSafety: EmergencyHaltManager triggers releaseAllHeldEvents on cancellation")
    func testEmergencyHaltManagerTriggersReleaseOnCancellation() {
        let token = CancellationToken()
        let mockSynthesizer = MockEventSynthesizer()

        EmergencyHaltManager.bindEmergencyRelease(token: token, synthesizer: mockSynthesizer)
        let countBefore = mockSynthesizer.recordedEvents.filter { $0 == .releaseAllHeldEvents }.count
        #expect(countBefore == 0)

        token.cancel()
        let countAfter = mockSynthesizer.recordedEvents.filter { $0 == .releaseAllHeldEvents }.count
        #expect(countAfter == 1)

        // Duplicate cancel does not double release
        token.cancel()
        let countDuplicate = mockSynthesizer.recordedEvents.filter { $0 == .releaseAllHeldEvents }.count
        #expect(countDuplicate == 1)
    }

    @Test("HardwareSafety: EmergencyHaltManager with pre-cancelled token releases immediately")
    func testEmergencyHaltManagerPreCancelledToken() {
        let token = CancellationToken()
        token.cancel()

        let mockSynthesizer = MockEventSynthesizer()
        EmergencyHaltManager.bindEmergencyRelease(token: token, synthesizer: mockSynthesizer)
        let count = mockSynthesizer.recordedEvents.filter { $0 == .releaseAllHeldEvents }.count
        #expect(count == 1)
    }

    @Test("HardwareSafety: live EventSynthesizer.releaseAllHeldEvents() executes without crash")
    func testLiveEventSynthesizerReleaseAllHeldEventsExecution() {
        let liveSynthesizer = EventSynthesizer()
        // Must not crash regardless of accessibility permissions status
        liveSynthesizer.releaseAllHeldEvents()
    }

    // MARK: - 7. SubgoalPlan Boundary & Invariants

    @Test("SubgoalPlan: empty plan returns nil currentSubgoal and isCompleted true")
    func testSubgoalPlanEmptyPlan() {
        var plan = SubgoalPlan(goal: "Empty Goal", subgoals: [])
        #expect(plan.isCompleted == true)
        #expect(plan.currentSubgoal == nil)
        #expect(plan.advance() == false)
    }

    @Test("SubgoalPlan: advance transitions statuses cleanly")
    func testSubgoalPlanAdvanceStatusTransitions() {
        let subgoals = [
            Subgoal(description: "Step 1", expectedOutcome: "Outcome 1"),
            Subgoal(description: "Step 2", expectedOutcome: "Outcome 2")
        ]
        var plan = SubgoalPlan(goal: "Multi-step Goal", subgoals: subgoals)

        #expect(plan.currentSubgoal?.description == "Step 1")
        #expect(plan.currentSubgoal?.status == .pending)

        let hasMore1 = plan.advance()
        #expect(hasMore1 == true)
        #expect(plan.subgoals[0].status == .completed)
        #expect(plan.subgoals[1].status == .inProgress)
        #expect(plan.currentSubgoal?.description == "Step 2")

        let hasMore2 = plan.advance()
        #expect(hasMore2 == false)
        #expect(plan.subgoals[1].status == .completed)
        #expect(plan.isCompleted == true)
        #expect(plan.currentSubgoal == nil)
    }

    @Test("SubgoalPlan: replaceRemaining handles boundary index safely")
    func testSubgoalPlanReplaceRemainingBoundaryIndices() {
        var plan = SubgoalPlan(goal: "Test", subgoals: [
            Subgoal(description: "S1", expectedOutcome: "O1"),
            Subgoal(description: "S2", expectedOutcome: "O2")
        ])

        // Negative index: guard prevents crash
        plan.replaceRemaining(from: -1, with: [Subgoal(description: "X", expectedOutcome: "X")])
        #expect(plan.subgoals.count == 2)

        // Index exceeding count: guard prevents crash
        plan.replaceRemaining(from: 5, with: [Subgoal(description: "X", expectedOutcome: "X")])
        #expect(plan.subgoals.count == 2)

        // Valid replacement from index 1
        plan.replaceRemaining(from: 1, with: [
            Subgoal(description: "New S2", expectedOutcome: "New O2"),
            Subgoal(description: "New S3", expectedOutcome: "New O3")
        ])
        #expect(plan.subgoals.count == 3)
        #expect(plan.subgoals[1].description == "New S2")
        #expect(plan.subgoals[2].description == "New S3")
    }

    @Test("Subgoal: JSON decoding boundary values")
    func testSubgoalJsonDecodingBoundary() throws {
        let json = """
        {
            "id": "sub_1",
            "description": "Test Subgoal",
            "expectedOutcome": "Test Outcome",
            "maxSteps": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Subgoal.self, from: json)
        #expect(decoded.id == "sub_1")
        #expect(decoded.maxSteps == 1) // Clamped to >= 1
    }
}

// MARK: - Thread-safe Counter Helper
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
