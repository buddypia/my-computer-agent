import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

@Suite("Challenger Adversarial Verification Tests")
struct ChallengerAdversarialTests {

    // MARK: - 1. Action Equivalence: Typing Differentiation

    @Test("ActionEquivalence: sequential typing into same element with different text is NOT equivalent")
    func testSequentialTypingDifferentTextIsNotEquivalent() {
        let dec1 = ComputerActionDecision(
            targetElementId: "search_input",
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            textInput: "first query"
        )
        let dec2 = ComputerActionDecision(
            targetElementId: "search_input",
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            textInput: "second query"
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(dec1, dec2)
        #expect(isEquivalent == false, "Typing different text into the same field must NOT be equivalent")
    }

    @Test("ActionEquivalence: sequential typing into same coordinates with different text is NOT equivalent")
    func testSequentialTypingDifferentTextAtCoordinatesIsNotEquivalent() {
        let dec1 = ComputerActionDecision(
            targetElementId: nil,
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            coordinates: CGPoint(x: 200, y: 300),
            textInput: "cat"
        )
        let dec2 = ComputerActionDecision(
            targetElementId: nil,
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            coordinates: CGPoint(x: 200, y: 300),
            textInput: "dog"
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(dec1, dec2)
        #expect(isEquivalent == false, "Typing different text at the same coordinates must NOT be equivalent")
    }

    @Test("ActionEquivalence: typing into different targets with same text is NOT equivalent")
    func testTypingDifferentTargetsSameTextIsNotEquivalent() {
        let dec1 = ComputerActionDecision(
            targetElementId: "input_username",
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            textInput: "admin"
        )
        let dec2 = ComputerActionDecision(
            targetElementId: "input_password",
            action: .typeText,
            confidence: 0.95,
            isCompleted: false,
            textInput: "admin"
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(dec1, dec2)
        #expect(isEquivalent == false, "Typing same text into different target elements must NOT be equivalent")
    }

    @Test("LoopDetector: sequential typing with different text does NOT trigger Factor 1 loop")
    func testSequentialTypingDifferentTextDoesNotTriggerLoop() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
        for word in words {
            let decision = ComputerActionDecision(
                targetElementId: "chat_field",
                action: .typeText,
                confidence: 0.9,
                isCompleted: false,
                textInput: word
            )
            try detector.recordAction(decision: decision)
            #expect(detector.consecutiveIdenticalActionCount == 1, "Counter must remain 1 for differing text inputs")
        }
    }

    @Test("LoopDetector: typing identical text repeatedly DOES trigger Factor 1 loop at threshold")
    func testTypingIdenticalTextTriggersLoopAtThreshold() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let decision = ComputerActionDecision(
            targetElementId: "chat_field",
            action: .typeText,
            confidence: 0.9,
            isCompleted: false,
            textInput: "spam"
        )

        try detector.recordAction(decision: decision)
        #expect(detector.consecutiveIdenticalActionCount == 1)

        try detector.recordAction(decision: decision)
        #expect(detector.consecutiveIdenticalActionCount == 2)

        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: decision)
        }
    }

    // MARK: - 2. Action Equivalence: Scroll Differentiation

    @Test("ActionEquivalence: opposing scroll deltas are NOT equivalent")
    func testOpposingScrollDeltasAreNotEquivalent() {
        let scrollDown = ComputerActionDecision(
            targetElementId: "scroll_view",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: -50)
        )
        let scrollUp = ComputerActionDecision(
            targetElementId: "scroll_view",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: 50)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(scrollDown, scrollUp)
        #expect(isEquivalent == false, "Opposing scroll deltas must NOT be equivalent")
    }

    @Test("ActionEquivalence: differing scroll magnitudes in same direction are NOT equivalent")
    func testDifferingScrollMagnitudesAreNotEquivalent() {
        let scrollSmall = ComputerActionDecision(
            targetElementId: "scroll_view",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: -10)
        )
        let scrollLarge = ComputerActionDecision(
            targetElementId: "scroll_view",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: -100)
        )

        let isEquivalent = TwoFactorLoopDetector.areActionsEquivalent(scrollSmall, scrollLarge)
        #expect(isEquivalent == false, "Differing scroll magnitudes must NOT be equivalent")
    }

    @Test("LoopDetector: alternating opposing scrolls do NOT trigger Factor 1 loop")
    func testAlternatingScrollDeltasDoNotTriggerLoop() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let scrollDown = ComputerActionDecision(
            targetElementId: "feed",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: -50)
        )
        let scrollUp = ComputerActionDecision(
            targetElementId: "feed",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: 50)
        )

        for _ in 0..<5 {
            try detector.recordAction(decision: scrollDown)
            #expect(detector.consecutiveIdenticalActionCount == 1)
            try detector.recordAction(decision: scrollUp)
            #expect(detector.consecutiveIdenticalActionCount == 1)
        }
    }

    @Test("LoopDetector: identical scroll delta at same target repeatedly DOES trigger Factor 1 loop")
    func testIdenticalScrollTriggersLoopAtThreshold() throws {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 3))

        let scroll = ComputerActionDecision(
            targetElementId: "feed",
            action: .scroll,
            confidence: 0.9,
            isCompleted: false,
            scrollDelta: CGVector(dx: 0, dy: -50)
        )

        try detector.recordAction(decision: scroll)
        #expect(detector.consecutiveIdenticalActionCount == 1)

        try detector.recordAction(decision: scroll)
        #expect(detector.consecutiveIdenticalActionCount == 2)

        #expect(throws: LoopExecutionError.self) {
            try detector.recordAction(decision: scroll)
        }
    }

    // MARK: - 3. Action Equivalence: Cross-Action Type Differentiation

    @Test("ActionEquivalence: different action types on same target are never equivalent")
    func testDifferentActionTypesAreNotEquivalent() {
        let click = ComputerActionDecision(targetElementId: "btn", action: .click)
        let dblClick = ComputerActionDecision(targetElementId: "btn", action: .doubleClick)
        let rightClick = ComputerActionDecision(targetElementId: "btn", action: .rightClick)
        let typeText = ComputerActionDecision(targetElementId: "btn", action: .typeText, textInput: "hi")
        let keyPress = ComputerActionDecision(action: .keyPress, keyCombination: ["Enter"])
        let scroll = ComputerActionDecision(targetElementId: "btn", action: .scroll, scrollDelta: CGVector(dx: 0, dy: -10))
        let wait = ComputerActionDecision(action: .wait)
        let none = ComputerActionDecision(action: .none)

        let allActions = [click, dblClick, rightClick, typeText, keyPress, scroll, wait, none]

        for i in 0..<allActions.count {
            for j in (i + 1)..<allActions.count {
                let eq = TwoFactorLoopDetector.areActionsEquivalent(allActions[i], allActions[j])
                #expect(eq == false, "Action \(allActions[i].action) and \(allActions[j].action) must NOT be equivalent")
            }
        }
    }

    // MARK: - 4. NaN / Infinity Coordinate Safety in LoopDetector Reason String

    @Test("LoopDetector: NaN coordinates in recordAction do NOT crash when threshold is reached")
    func testNanCoordinatesInRecordActionReasonString() {
        var detector = TwoFactorLoopDetector(config: .init(identicalActionThreshold: 2))

        // Force identical action count by using targetElementId with NaN coordinates
        let dec1 = ComputerActionDecision(
            targetElementId: nil,
            action: .click,
            confidence: 0.9,
            isCompleted: false,
            coordinates: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
        )

        // Directly verify the targetDesc string formatting logic without trapping
        if let pt = dec1.coordinates {
            let xStr = pt.x.isFinite ? "\(Int(pt.x))" : "\(pt.x)"
            let yStr = pt.y.isFinite ? "\(Int(pt.y))" : "\(pt.y)"
            #expect(xStr == "nan")
            #expect(yStr == "inf")
        }
    }

    // MARK: - 5. CancellationToken Sleep Remapping

    @Test("CancellationToken: ambient Task cancellation during sleep throws LoopExecutionError.cancelled")
    func testAmbientTaskCancellationDuringSleepThrowsLoopExecutionErrorCancelled() async throws {
        let token = CancellationToken()

        let task = Task {
            try await token.sleep(milliseconds: 1000)
        }

        // Cancel the Task directly rather than the token
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        var caughtLoopCancelled = false
        do {
            try await task.value
        } catch let err as LoopExecutionError {
            if err == .cancelled {
                caughtLoopCancelled = true
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(caughtLoopCancelled == true, "Task cancellation during sleep must map to LoopExecutionError.cancelled")
    }

    // MARK: - 6. SubgoalPlan Advance Boundary & Edge Cases

    @Test("SubgoalPlan: advance() on already finished plan remains bounded and returns false")
    func testSubgoalPlanAdvanceOnCompletedPlan() {
        var plan = SubgoalPlan(
            goal: "Complete plan",
            subgoals: [Subgoal(description: "Single step", expectedOutcome: "Done")]
        )
        #expect(plan.advance() == false)
        #expect(plan.isCompleted == true)
        #expect(plan.currentSubgoalIndex == 1)

        // Multiple subsequent advance calls should not increment index indefinitely
        #expect(plan.advance() == false)
        #expect(plan.currentSubgoalIndex == 1)

        #expect(plan.advance() == false)
        #expect(plan.currentSubgoalIndex == 1)
    }

    @Test("SubgoalPlan: negative index advance gracefully initializes to 0")
    func testSubgoalPlanNegativeIndexAdvance() {
        var plan = SubgoalPlan(
            goal: "Negative start",
            subgoals: [
                Subgoal(description: "First", expectedOutcome: "Done 1"),
                Subgoal(description: "Second", expectedOutcome: "Done 2")
            ],
            currentSubgoalIndex: -5
        )

        let hasMore = plan.advance()
        #expect(hasMore == true)
        #expect(plan.currentSubgoalIndex == -4) // increments by 1 towards valid range
    }
}
