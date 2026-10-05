import Foundation
import MCACore
import Testing

@Suite("SubgoalPlan & Subgoal Tests")
struct SubgoalPlanTests {

    @Test("Subgoal initialization and default parameters")
    func testSubgoalInitialization() {
        let subgoal = Subgoal(
            description: "Click login button",
            expectedOutcome: "Login modal appears"
        )

        #expect(!subgoal.id.isEmpty)
        #expect(subgoal.description == "Click login button")
        #expect(subgoal.expectedOutcome == "Login modal appears")
        #expect(subgoal.maxSteps == 10)
        #expect(subgoal.status == .pending)

        let customSubgoal = Subgoal(
            id: "custom_1",
            description: "Type username",
            expectedOutcome: "Username entered",
            maxSteps: 3,
            status: .inProgress
        )
        #expect(customSubgoal.id == "custom_1")
        #expect(customSubgoal.maxSteps == 3)
        #expect(customSubgoal.status == .inProgress)

        // Clamping minSteps to at least 1
        let clamped = Subgoal(
            description: "Test clamp",
            expectedOutcome: "Outcome",
            maxSteps: 0
        )
        #expect(clamped.maxSteps == 1)
    }

    @Test("SubgoalStatus enum values and equatability")
    func testSubgoalStatus() {
        let statuses: [SubgoalStatus] = [
            .pending,
            .inProgress,
            .completed,
            .failed(reason: "Element not found"),
            .skipped(reason: "Not necessary")
        ]

        #expect(statuses[0] == .pending)
        #expect(statuses[1] == .inProgress)
        #expect(statuses[2] == .completed)
        #expect(statuses[3] == .failed(reason: "Element not found"))
        #expect(statuses[4] == .skipped(reason: "Not necessary"))
        #expect(statuses[3] != statuses[4])
    }

    @Test("Subgoal Codable roundtrip with full and partial JSON")
    func testSubgoalCodableRoundtrip() throws {
        let original = Subgoal(
            id: "sg_full",
            description: "Open Safari",
            expectedOutcome: "Safari is frontmost",
            maxSteps: 5,
            status: .completed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Subgoal.self, from: data)

        #expect(decoded == original)
        #expect(decoded.id == "sg_full")
        #expect(decoded.description == "Open Safari")
        #expect(decoded.expectedOutcome == "Safari is frontmost")
        #expect(decoded.maxSteps == 5)
        #expect(decoded.status == .completed)

        // Decode from minimal JSON without id, maxSteps, or status
        let minimalJSON = """
        {
            "description": "Minimal subgoal",
            "expectedOutcome": "Minimal outcome"
        }
        """.data(using: .utf8)!

        let minimalDecoded = try decoder.decode(Subgoal.self, from: minimalJSON)
        #expect(!minimalDecoded.id.isEmpty)
        #expect(minimalDecoded.description == "Minimal subgoal")
        #expect(minimalDecoded.expectedOutcome == "Minimal outcome")
        #expect(minimalDecoded.maxSteps == 10)
        #expect(minimalDecoded.status == .pending)
    }

    @Test("SubgoalPlan initialization and empty state")
    func testSubgoalPlanEmpty() {
        let plan = SubgoalPlan(goal: "Do nothing")
        #expect(plan.goal == "Do nothing")
        #expect(plan.subgoals.isEmpty)
        #expect(plan.currentSubgoalIndex == 0)
        #expect(plan.currentSubgoal == nil)
        #expect(plan.isCompleted)
        #expect(plan.isComplete)
    }

    @Test("SubgoalPlan advance and status transitions")
    func testSubgoalPlanAdvance() {
        let sg1 = Subgoal(id: "1", description: "First", expectedOutcome: "One done", maxSteps: 5)
        let sg2 = Subgoal(id: "2", description: "Second", expectedOutcome: "Two done", maxSteps: 5)
        var plan = SubgoalPlan(goal: "Multi-step goal", subgoals: [sg1, sg2])

        #expect(!plan.isCompleted)
        #expect(!plan.isComplete)
        #expect(plan.currentSubgoal?.id == "1")

        // First advance: sg1 completes, sg2 becomes inProgress
        let hasMore1 = plan.advance()
        #expect(hasMore1)
        #expect(!plan.isCompleted)
        #expect(plan.currentSubgoalIndex == 1)
        #expect(plan.subgoals[0].status == .completed)
        #expect(plan.subgoals[1].status == .inProgress)
        #expect(plan.currentSubgoal?.id == "2")

        // Second advance: sg2 completes, plan finishes
        let hasMore2 = plan.advance()
        #expect(!hasMore2)
        #expect(plan.isCompleted)
        #expect(plan.isComplete)
        #expect(plan.currentSubgoalIndex == 2)
        #expect(plan.subgoals[1].status == .completed)
        #expect(plan.currentSubgoal == nil)
    }

    @Test("SubgoalPlan replaceRemaining from current index")
    func testSubgoalPlanReplaceRemaining() {
        let sg1 = Subgoal(id: "1", description: "Step 1", expectedOutcome: "Done 1")
        let sg2 = Subgoal(id: "2", description: "Step 2", expectedOutcome: "Done 2")
        let sg3 = Subgoal(id: "3", description: "Step 3", expectedOutcome: "Done 3")
        var plan = SubgoalPlan(goal: "Replan test", subgoals: [sg1, sg2, sg3])

        // Advance to step 2
        plan.advance()
        #expect(plan.currentSubgoalIndex == 1)

        // Replace from index 1 onwards with 2 new subgoals
        let revised2 = Subgoal(id: "2_revised", description: "Revised Step 2", expectedOutcome: "Done 2R")
        let revised3 = Subgoal(id: "3_revised", description: "Revised Step 3", expectedOutcome: "Done 3R")
        plan.replaceRemaining(from: 1, with: [revised2, revised3])

        #expect(plan.subgoals.count == 3)
        #expect(plan.subgoals[0].id == "1")
        #expect(plan.subgoals[1].id == "2_revised")
        #expect(plan.subgoals[2].id == "3_revised")
        #expect(plan.currentSubgoal?.id == "2_revised")

        // Out-of-bounds replacements do nothing
        plan.replaceRemaining(from: -1, with: [revised2])
        plan.replaceRemaining(from: 10, with: [revised2])
        #expect(plan.subgoals.count == 3)
    }

    @Test("SubgoalPlan updateCurrentSubgoal")
    func testSubgoalPlanUpdateCurrent() {
        let sg1 = Subgoal(id: "1", description: "Initial", expectedOutcome: "Initial outcome")
        var plan = SubgoalPlan(goal: "Update test", subgoals: [sg1])

        let updated = Subgoal(id: "1", description: "Updated", expectedOutcome: "Updated outcome", maxSteps: 8, status: .inProgress)
        plan.updateCurrentSubgoal(with: updated)

        #expect(plan.currentSubgoal?.description == "Updated")
        #expect(plan.currentSubgoal?.maxSteps == 8)
        #expect(plan.currentSubgoal?.status == .inProgress)
    }

    @Test("SubgoalPlan Codable roundtrip")
    func testSubgoalPlanCodableRoundtrip() throws {
        let plan = SubgoalPlan(
            goal: "Search and click",
            subgoals: [
                Subgoal(id: "sg_1", description: "Search Tokyo", expectedOutcome: "Results shown", maxSteps: 4),
                Subgoal(id: "sg_2", description: "Click Wikipedia", expectedOutcome: "Article opened", maxSteps: 3)
            ],
            currentSubgoalIndex: 1
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(plan)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SubgoalPlan.self, from: data)

        #expect(decoded == plan)
        #expect(decoded.goal == "Search and click")
        #expect(decoded.subgoals.count == 2)
        #expect(decoded.currentSubgoalIndex == 1)
        #expect(decoded.currentSubgoal?.id == "sg_2")
    }

    @Test("SubgoalPlan advance handles negative index and bounds protection cleanly")
    func testSubgoalPlanAdvanceBoundaryProtection() {
        let sg1 = Subgoal(id: "1", description: "Step 1", expectedOutcome: "Outcome 1")
        var plan = SubgoalPlan(goal: "Bounds test", subgoals: [sg1], currentSubgoalIndex: -1)

        // Negative index: does not crash, increments to 0 and activates first subgoal
        let hasMore = plan.advance()
        #expect(hasMore)
        #expect(plan.currentSubgoalIndex == 0)
        #expect(plan.subgoals[0].status == .inProgress)
        #expect(plan.currentSubgoal?.id == "1")

        // Complete step 1
        let finished = plan.advance()
        #expect(!finished)
        #expect(plan.currentSubgoalIndex == 1)
        #expect(plan.subgoals[0].status == .completed)
        #expect(plan.isCompleted)

        // Calling advance() on already completed plan returns false without unbounded index increment
        let overrun = plan.advance()
        #expect(!overrun)
        #expect(plan.currentSubgoalIndex == 1)
    }

    @Test("SubgoalPlan replaceRemaining resets currentSubgoalIndex and activates new subgoal")
    func testSubgoalPlanReplaceRemainingIndexReset() {
        let sg1 = Subgoal(id: "1", description: "Step 1", expectedOutcome: "Outcome 1")
        var plan = SubgoalPlan(goal: "Reset test", subgoals: [sg1], currentSubgoalIndex: 1)
        #expect(plan.isCompleted)

        let newSg1 = Subgoal(id: "new_1", description: "New Step 1", expectedOutcome: "New Outcome 1")
        let newSg2 = Subgoal(id: "new_2", description: "New Step 2", expectedOutcome: "New Outcome 2")
        plan.replaceRemaining(from: 0, with: [newSg1, newSg2])

        #expect(!plan.isCompleted)
        #expect(plan.currentSubgoalIndex == 0)
        #expect(plan.subgoals[0].id == "new_1")
        #expect(plan.subgoals[0].status == .inProgress)
        #expect(plan.subgoals[1].status == .pending)
        #expect(plan.currentSubgoal?.id == "new_1")
    }

    @Test("Subgoal JSON decoding clamps non-positive maxSteps to 1")
    func testSubgoalDecodingClamping() throws {
        let zeroJson = #"{"description": "D", "expectedOutcome": "O", "maxSteps": 0}"#.data(using: .utf8)!
        let negativeJson = #"{"description": "D", "expectedOutcome": "O", "maxSteps": -5}"#.data(using: .utf8)!

        #expect(try JSONDecoder().decode(Subgoal.self, from: zeroJson).maxSteps == 1)
        #expect(try JSONDecoder().decode(Subgoal.self, from: negativeJson).maxSteps == 1)
    }
}
