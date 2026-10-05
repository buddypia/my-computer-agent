import Foundation
import MCACore
import MCASensing

public enum ActionAuthorizationError: LocalizedError, Sendable, Equatable {
    case approvalRequired, denied, staleTarget, budgetExceeded

    public var errorDescription: String? {
        switch self {
        case .approvalRequired: return "approval_required: this operation needs approval in the chat UI."
        case .budgetExceeded: return "Action budget reached; no further action was executed."
        case .denied: return "Operation rejected, cancelled or expired; no action was executed."
        case .staleTarget: return "The approved target changed or could not be revalidated; no action was executed."
        }
    }
}

/// Propagates with the task through tools, actors and native action loops.
/// Without a presenter, risky operations fail closed (including CLI and MCP).
public struct ActionAuthorization: Sendable {
    public typealias Presenter = @Sendable (ActionApprovalRequest) async throws -> ActionApprovalStatus
    public typealias Validator = @Sendable () async throws -> Bool

    @TaskLocal public static var current: ActionAuthorization?

    public let goal: String
    private let presenter: Presenter
    private let validateTarget: Validator?
    public let targetWindow: PinnedWindow?
    public let requiresWindowScope: Bool
    public let privacyConfiguration: AgentConfiguration
    private let state: State

    private actor State {
        var failure: String?
        var observation: UIStateSnapshot?
        var remainingActions: Int
        init(budget: Int) { remainingActions = max(0, budget) }
        func consume() throws {
            guard failure == nil else { throw ActionAuthorizationError.denied }
            guard remainingActions > 0 else {
                stop(ActionAuthorizationError.budgetExceeded.localizedDescription)
                throw ActionAuthorizationError.budgetExceeded
            }
            remainingActions -= 1
        }
        func record(_ snapshot: UIStateSnapshot) { observation = snapshot }
        /// The first failure is the root cause; what follows it is fallout and must not overwrite it.
        func stop(_ reason: String) { if failure == nil { failure = reason } }
    }

    public var nativeObservation: UIStateSnapshot? { get async { await state.observation } }
    public func recordNativeObservation(_ snapshot: UIStateSnapshot) async { await state.record(snapshot) }

    public func consumeAction() async throws { try Task.checkCancellation(); try await state.consume() }
    public func abort(_ error: Error) async { await state.stop(error.localizedDescription) }

    public var terminalFailure: String? { get async { await state.failure } }

    public init(goal: String, requestApproval: @escaping Presenter, validateTarget: Validator? = nil,
                targetWindow: PinnedWindow? = nil, requiresWindowScope: Bool = false,
                privacyConfiguration: AgentConfiguration = PrivacyFilter.configuration,
                actionBudget: Int = 20) {
        self.goal = goal
        self.presenter = requestApproval
        self.validateTarget = validateTarget
        self.targetWindow = targetWindow
        self.requiresWindowScope = requiresWindowScope
        self.privacyConfiguration = privacyConfiguration
        self.state = State(budget: actionBudget)
    }

    public static func withSession<T: Sendable>(_ session: ActionAuthorization,
        isolation: isolated (any Actor)? = #isolation, operation: () async throws -> T) async rethrows -> T {
        try await PrivacyFilter.$configuration.withValue(session.privacyConfiguration) {
            try await $current.withValue(session) {
                try await EventSynthesizer.$expectedTargetPID.withValue(session.targetWindow?.processID) {
                    try await EventSynthesizer.$expectedTargetWindowID.withValue(session.targetWindow?.id) {
                        try await operation()
                    }
                }
            }
        }
    }

    /// The order of outcomes is part of the contract (a rejection is `.denied` even when the
    /// target could not be revalidated, and so on), so it is kept exactly. The session-wide
    /// validator and the caller's validator both apply: a caller cannot waive the session's.
    public static func requireApproval(
        operation: String, target: String, details: String,
        consequence: String = "This operation can change or remove data, or affect another application.",
        revalidate: Validator? = nil
    ) async throws {
        try Task.checkCancellation()
        guard let session = current else { throw ActionAuthorizationError.approvalRequired }
        if await session.terminalFailure != nil { throw ActionAuthorizationError.denied }
        do {
            let request = ActionApprovalRequest(goal: session.goal, operation: operation,
                                                target: target, details: details, consequence: consequence)
            let status = try await session.presenter(request)
            try Task.checkCancellation()
            guard status == .approved else { throw ActionAuthorizationError.denied }
            let validators = [session.validateTarget, revalidate].compactMap { $0 }
            guard !validators.isEmpty else { throw ActionAuthorizationError.staleTarget }
            for validator in validators {
                guard try await validator() else { throw ActionAuthorizationError.staleTarget }
            }
            try Task.checkCancellation()
            try await session.consumeAction()
        } catch {
            await session.state.stop(error.localizedDescription)
            throw error
        }
    }
}
