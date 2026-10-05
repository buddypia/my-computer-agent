import Foundation

// MARK: - SubgoalStatus

/// Lifecycle status of an individual subgoal within a plan.
public enum SubgoalStatus: Sendable, Codable, Equatable, Hashable {
    case pending
    case inProgress
    case completed
    case failed(reason: String)
    case skipped(reason: String)
}

// MARK: - Subgoal

/// A coarse-grained milestone or intermediate objective produced by System 2.
public struct Subgoal: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public var description: String
    public var expectedOutcome: String
    public var maxSteps: Int
    public var status: SubgoalStatus

    public init(
        id: String = UUID().uuidString,
        description: String,
        expectedOutcome: String,
        maxSteps: Int = 10,
        status: SubgoalStatus = .pending
    ) {
        self.id = id
        self.description = description
        self.expectedOutcome = expectedOutcome
        self.maxSteps = max(1, maxSteps)
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case expectedOutcome
        case maxSteps
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.description = try container.decode(String.self, forKey: .description)
        self.expectedOutcome = try container.decode(String.self, forKey: .expectedOutcome)
        self.maxSteps = max(1, try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 10)
        self.status = try container.decodeIfPresent(SubgoalStatus.self, forKey: .status) ?? .pending
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(description, forKey: .description)
        try container.encode(expectedOutcome, forKey: .expectedOutcome)
        try container.encode(maxSteps, forKey: .maxSteps)
        try container.encode(status, forKey: .status)
    }
}

// MARK: - SubgoalPlan

/// An ordered execution plan decomposed from a top-level natural language goal.
public struct SubgoalPlan: Sendable, Codable, Equatable {
    public let goal: String
    public var subgoals: [Subgoal]
    public var currentSubgoalIndex: Int

    public init(
        goal: String,
        subgoals: [Subgoal] = [],
        currentSubgoalIndex: Int = 0
    ) {
        self.goal = goal
        self.subgoals = subgoals
        self.currentSubgoalIndex = currentSubgoalIndex
    }

    /// The currently active subgoal being executed by System 1.
    public var currentSubgoal: Subgoal? {
        guard currentSubgoalIndex >= 0 && currentSubgoalIndex < subgoals.count else { return nil }
        return subgoals[currentSubgoalIndex]
    }

    /// Whether all subgoals in the plan have been executed.
    public var isCompleted: Bool {
        currentSubgoalIndex >= subgoals.count
    }

    /// Compatibility alias matching both `isComplete` and `isCompleted` conventions.
    public var isComplete: Bool {
        isCompleted
    }

    /// Advances the pointer to the next subgoal. Returns true if another subgoal remains.
    @discardableResult
    public mutating func advance() -> Bool {
        guard currentSubgoalIndex < subgoals.count else { return false }
        if currentSubgoalIndex >= 0 && currentSubgoalIndex < subgoals.count {
            if subgoals[currentSubgoalIndex].status == .pending || subgoals[currentSubgoalIndex].status == .inProgress {
                subgoals[currentSubgoalIndex].status = .completed
            }
        }
        currentSubgoalIndex += 1
        if currentSubgoalIndex >= 0 && currentSubgoalIndex < subgoals.count {
            if subgoals[currentSubgoalIndex].status == .pending {
                subgoals[currentSubgoalIndex].status = .inProgress
            }
        }
        return !isCompleted
    }

    /// Replaces remaining subgoals from the specified index onwards with a revised list.
    public mutating func replaceRemaining(from index: Int, with newSubgoals: [Subgoal]) {
        guard index >= 0 && index <= subgoals.count else { return }
        subgoals.removeSubrange(index..<subgoals.count)
        subgoals.append(contentsOf: newSubgoals)
        if currentSubgoalIndex >= index {
            currentSubgoalIndex = index
            if index < subgoals.count {
                subgoals[index].status = .inProgress
            }
        }
    }

    /// Updates the active subgoal with modified parameters or revised instructions.
    public mutating func updateCurrentSubgoal(with subgoal: Subgoal) {
        guard currentSubgoalIndex >= 0 && currentSubgoalIndex < subgoals.count else { return }
        subgoals[currentSubgoalIndex] = subgoal
    }
}
