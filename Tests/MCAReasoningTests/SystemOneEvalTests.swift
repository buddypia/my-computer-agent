import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

/// System One eval: grades request routing and next-step decisions against
/// `Evals/system-one/{train,heldout}.jsonl`. Design and hillclimb protocol are in
/// `docs/evals/system-one.md`; the driver is `Scripts/eval/hillclimb.mjs`.
///
/// In the gate this is a regression floor: pass counts may not drop below
/// `baseline.json`. Per-case detail is written only for the train split, so the
/// optimizer never reads held-out failures.
@Suite("SystemOneEval")
struct SystemOneEvalTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Evals/system-one")

    static func describe(_ backend: any TypeSafeEvaluating) -> String {
        switch backend {
        case let clef as CloudflareClefClient: return clef.model.rawValue
        case is TypeSafeClient: return "typesafe"
        default: return "none"
        }
    }

    @Test("cases decode, run deterministically, and stay above the baseline floor")
    func evaluate() async throws {
        let online = ProcessInfo.processInfo.environment["MCA_EVAL_ONLINE"] == "1"
        // Online uses the same backend the app resolves (MCA_SYSTEM_ONE / TypeSafe key / cf).
        let backend = SystemOneBackend.resolve()
        let engine = online
            ? TypeSafeDecisionEngine(client: backend)
            : TypeSafeDecisionEngine(customEvaluator: { _ in throw EvalOffline() })
        let mode = online ? "online:\(Self.describe(backend))" : "offline"

        var splits: [String: SplitReport] = [:]
        var nondeterministic: [String] = []
        for split in ["train", "heldout"] {
            let cases = try Self.loadCases(split)
            var report = SplitReport()
            for c in cases {
                let first = try await Self.observe(c, engine: engine)
                let second = try await Self.observe(c, engine: engine)
                if first != second { nondeterministic.append(c.id) }

                let failure = Self.grade(first, against: [c.expect] + (c.alsoAccept ?? []))
                report.record(kind: c.kind, passed: failure == nil)
                if let failure, split == "train" {
                    report.failures.append(.init(id: c.id, kind: c.kind, source: c.source, input: c.input.summary, mismatch: failure, observed: first))
                }
            }
            splits[split] = report
        }

        let train = splits["train"]!, heldout = splits["heldout"]!
        print("SystemOneEval mode=\(mode) train \(train.passed)/\(train.total) heldout \(heldout.passed)/\(heldout.total)")

        if let path = ProcessInfo.processInfo.environment["MCA_EVAL_REPORT"] {
            let report = EvalReport(
                mode: mode,
                train: train,
                heldout: .init(passed: heldout.passed, total: heldout.total, byKind: heldout.byKind),
                nondeterministic: nondeterministic
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }

        // Low variance is a property of a good eval, not an assumption: verify it.
        #expect(nondeterministic.isEmpty, "non-deterministic cases: \(nondeterministic)")

        // The floor guards the offline path only; the online model is a different system.
        if !online {
            let floor = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: Self.directory.appendingPathComponent("baseline.json")))
            #expect(train.passed >= floor.train, "train regressed below baseline: \(train.passed) < \(floor.train)")
            #expect(heldout.passed >= floor.heldout, "heldout regressed below baseline: \(heldout.passed) < \(floor.heldout)")
        }
    }

    // MARK: - Running a case

    static func observe(_ c: EvalCase, engine: TypeSafeDecisionEngine) async throws -> Observation {
        switch c.kind {
        case "routing":
            let text = c.input.text ?? ""
            let triage = await engine.triageGoal(goal: RequestRoute.explicitGoal(in: text) ?? text)
            return Observation(route: RequestRoute.decide(question: text, triage: triage).rawValue)
        case "decision":
            let decision = try await engine.decideNextAction(
                goal: c.input.goal ?? "",
                candidates: (c.input.candidates ?? []).map(\.candidate),
                history: (c.input.history ?? []).enumerated().map { index, step in
                    LoopStepRecord(
                        stepNumber: index + 1,
                        subgoalId: "eval",
                        action: ComputerActionDecision(
                            targetElementId: nil,
                            action: ComputerActionDecision.ActionType(rawValue: step.action) ?? .none,
                            confidence: 0.85,
                            isCompleted: false,
                            keyCombination: step.keys
                        )
                    )
                },
                recentEscalations: (c.input.escalations ?? []).enumerated().map { index, reason in
                    EscalationRecord(
                        attempt: index + 1,
                        reason: reason == "actionStagnant"
                            ? .actionStagnant(reason: "eval")
                            : .lowConfidence(confidence: 0.3, threshold: 0.8)
                    )
                },
                lastDiff: c.input.unchanged.map { UIStateDiff(titleChanged: !$0, focusChanged: false) }
            )
            let delta = decision.scrollDelta
            return Observation(
                action: decision.action.rawValue,
                target: decision.targetElementId ?? "none",
                completed: decision.isCompleted,
                keys: decision.keyCombination?.map { $0.lowercased() },
                text: decision.textInput,
                scroll: delta.map { d in
                    d.dy > 0 ? "up" : d.dy < 0 ? "down" : d.dx > 0 ? "right" : d.dx < 0 ? "left" : "none"
                },
                escalate: engine.shouldEscalate(decision: decision),
                reasoning: decision.reasoning
            )
        default:
            throw EvalHarnessError(message: "case \(c.id): unknown kind '\(c.kind)'")
        }
    }

    /// Programmatic grader: every field the expectation names must match.
    /// Returns `nil` on a pass, or the mismatches against the closest expectation.
    static func grade(_ o: Observation, against expectations: [Expectation]) -> String? {
        var best: [String]?
        for e in expectations {
            var miss: [String] = []
            func check<T: Equatable>(_ name: String, _ want: T?, _ got: T?) {
                if let want, want != got { miss.append("\(name): want \(want), got \(got.map { "\($0)" } ?? "nil")") }
            }
            check("route", e.route, o.route)
            check("action", e.action, o.action)
            check("target", e.target, o.target)
            check("completed", e.completed, o.completed)
            check("keys", e.keys?.map { $0.lowercased() }, o.keys)
            check("text", e.text, o.text)
            check("scroll", e.scroll, o.scroll)
            check("escalate", e.escalate, o.escalate)
            if miss.isEmpty { return nil }
            if best == nil || miss.count < best!.count { best = miss }
        }
        return best?.joined(separator: "; ")
    }

    static func loadCases(_ split: String) throws -> [EvalCase] {
        let url = directory.appendingPathComponent("\(split).jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return try lines.enumerated().map { index, line in
            do {
                return try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
            } catch {
                // A case that cannot be read is a harness error, never a model failure.
                throw EvalHarnessError(message: "\(split).jsonl:\(index + 1): \(error)")
            }
        }
    }
}

// MARK: - Case schema

struct EvalCase: Decodable {
    let id: String
    let kind: String
    let source: String
    let input: Input
    let expect: Expectation
    let alsoAccept: [Expectation]?

    struct Input: Decodable {
        let text: String?
        let goal: String?
        let candidates: [Candidate]?
        let history: [Step]?
        let escalations: [String]?
        let unchanged: Bool?

        var summary: String {
            if let text { return text }
            let roles = (candidates ?? []).map { "\($0.id)=\($0.role):'\($0.label)'" }.joined(separator: ", ")
            var extra = ""
            if let history, !history.isEmpty { extra += " history=\(history.map(\.action))" }
            if let escalations, !escalations.isEmpty { extra += " escalations=\(escalations)" }
            if let unchanged { extra += " unchanged=\(unchanged)" }
            return "goal='\(goal ?? "")' candidates=[\(roles)]\(extra)"
        }
    }

    struct Candidate: Decodable {
        let id: String
        let role: String
        let label: String
        let value: String?
        let bounds: [Double]
        let actionable: Bool?

        var candidate: UIElementCandidate {
            UIElementCandidate(
                id: id, role: role, label: label, value: value,
                bounds: CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]),
                isActionable: actionable ?? true
            )
        }
    }

    struct Step: Decodable {
        let action: String
        let keys: [String]?
    }
}

struct Expectation: Decodable {
    let route: String?
    let action: String?
    let target: String?
    let completed: Bool?
    let keys: [String]?
    let text: String?
    let scroll: String?
    let escalate: Bool?
}

struct Observation: Codable, Equatable {
    var route: String?
    var action: String?
    var target: String?
    var completed: Bool?
    var keys: [String]?
    var text: String?
    var scroll: String?
    var escalate: Bool?
    var reasoning: String?
}

// MARK: - Report

struct SplitReport: Encodable {
    var passed = 0
    var total = 0
    var byKind: [String: [Int]] = [:]
    var failures: [Failure] = []

    struct Failure: Encodable {
        let id: String
        let kind: String
        let source: String
        let input: String
        let mismatch: String
        let observed: Observation
    }

    mutating func record(kind: String, passed ok: Bool) {
        total += 1
        if ok { passed += 1 }
        var counts = byKind[kind] ?? [0, 0]
        counts[0] += ok ? 1 : 0
        counts[1] += 1
        byKind[kind] = counts
    }
}

/// Held-out results are aggregates only, by construction.
struct HeldoutReport: Encodable {
    let passed: Int
    let total: Int
    let byKind: [String: [Int]]
}

struct EvalReport: Encodable {
    let mode: String
    let train: SplitReport
    let heldout: HeldoutReport
    let nondeterministic: [String]
}

struct Baseline: Decodable {
    let train: Int
    let heldout: Int
}

struct EvalOffline: Error {}

struct EvalHarnessError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
