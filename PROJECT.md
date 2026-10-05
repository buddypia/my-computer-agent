# Project: Fix Autonomous Loop Escalation Failure

## Architecture
The system consists of the Two-Tier Autonomous Loop (`TwoTierAutonomousLoopCoordinator`), the local and cloud-based Decision Engine (`TypeSafeDecisionEngine`), the Deliberative/Subgoal Planner (`DefaultSubgoalPlanner`), and the synthetic event actuator (`EventSynthesizer`).
Under offline/unkeyed TypeSafe Jev conditions, the coordinator relies on the decision engine's local deterministic fallback (`fallbackLocalDecision`) and the planner's heuristic replanner (`heuristicReplan`).
The fix introduces:
1. **Target-Grounded & Stagnation-Aware Fallback Engine** (`TypeSafeDecisionEngine.swift`): Container detection (`AXScrollArea`, etc.), coordinate resolution, history/diff feedback integration, and robust partial candidate matching.
2. **Replan & Escalation Feedback Loop** (`TwoTierAutonomousLoopCoordinator.swift`): Passing history and diff to decision cycles, clean non-repeating heuristic replans, coordinate fallback in event execution, and structured recovery before escalation limit exhaustion.
3. **Deterministic Regression Test Suite** (`TwoTierAutonomousLoopOfflineRegressionTests.swift`): Reproducing offline scroll stagnation, confidence drops, and verifying clean recovery.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Container Grounded Fallback Scroll | In offline fallback, target valid `AXScrollArea` / scroll container candidates and their coordinates instead of `target=none` / `at: nil`. | M1 | ORIGINAL_REQUEST §R1 |
| 2 | Stagnation-Aware Action Adaptation | Detect when prior scroll actions yielded `isStateUnchanged == true`, and adapt by switching to keyboard navigation (`PageDown`/`Down`) or concluding the subgoal. | M1 | ORIGINAL_REQUEST §R1 |
| 3 | Token-Based Candidate Matching | In offline fallback, use token/partial matching across label, value, and role to prevent premature 0.00 confidence fallthrough. | M1 | ORIGINAL_REQUEST §R3 |
| 4 | Graceful Low-Confidence Recovery | Prevent zero-confidence fallthroughs from immediately tripping consecutive escalations by providing structured local recovery. | M1 | ORIGINAL_REQUEST §R3 |
| 5 | Feedback Loop to Decision Engine | Pass execution history, recent escalation records, and `lastDiff` into `decideNextAction` / `fallbackLocalDecision`. | M2 | ORIGINAL_REQUEST §R2 |
| 6 | Non-Recursive Heuristic Replan | In `heuristicReplan`, strip stagnant trigger words (`scroll`, `feed`, etc.) from retry subgoal descriptions so the decision engine does not re-issue the failed action. | M2 | ORIGINAL_REQUEST §R2 |
| 7 | Coordinator Coordinate Fallback | In `executeSyntheticAction`, if action is `.scroll` and `targetCenter == nil`, target the active window or container center rather than unpositioned `at: nil`. | M2 | ORIGINAL_REQUEST §R1 |
| 8 | Consecutive Escalation Recovery Guard | Prevent cascading low-confidence or stagnant replans from prematurely exhausting the 3-strike escalation limit. | M2 | ORIGINAL_REQUEST §R2, R3 |
| 9 | Offline Regression Test Suite | Deterministic regression tests reproducing 3-step stagnant scroll and confidence-drop escalation sequences under simulated offline TypeSafe API conditions. | M3 | ORIGINAL_REQUEST §R4 |
| 10 | Quality Gate Verification | Ensure all stages of `Scripts/gate.sh` (G0 classify, G1 build, G2 trust, G2 test, G2 guards) pass cleanly. | M3 | ORIGINAL_REQUEST §R4, AGENTS.md |
| 11 | Comprehensive E2E Verification & Adversarial Coverage | Opaque-box requirement-driven test suite (Tiers 1-4) plus adversarial coverage hardening (Tier 5). | M4 | PROJECT PATTERN §Final Milestone |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Fallback Engine Grounding & Adaptation | `Sources/MCAReasoning/TypeSafeDecisionEngine.swift` (Container targeting, stagnation adaptation, token candidate matching, confidence recovery) | none | DONE |
| M2 | Replan Feedback & Coordinator Hardening | `Sources/MCAReasoning/TwoTierAutonomousLoopCoordinator.swift` (Feedback wiring, non-repeating replan, coordinate fallback, escalation guard) | M1 | DONE |
| M3 | Offline Regression Test Suite | `Tests/MCAReasoningTests/TwoTierAutonomousLoopOfflineRegressionTests.swift` & unit test additions | M1, M2 | DONE |
| M4 | Final Milestone: E2E Test Pass & Adversarial Hardening | Pass 100% of E2E tests (Tiers 1-4) and Tier 5 Adversarial Coverage Hardening | M1, M2, M3 | DONE |

## Interface Contracts
### TypeSafeDecisionEngine ↔ TwoTierAutonomousLoopCoordinator
- `TypeSafeDecisionEngine.decideNextAction`:
  ```swift
  public func decideNextAction(
      goal: String,
      activeApp: String? = nil,
      candidates: [UIElementCandidate],
      history: [LoopStepRecord] = [],
      recentEscalations: [EscalationRecord] = [],
      lastDiff: UIStateDiff? = nil
  ) async throws -> ComputerActionDecision
  ```
- `TypeSafeDecisionEngine.fallbackLocalDecision`:
  ```swift
  public func fallbackLocalDecision(
      goal: String,
      candidates: [UIElementCandidate],
      history: [LoopStepRecord] = [],
      recentEscalations: [EscalationRecord] = [],
      lastDiff: UIStateDiff? = nil
  ) -> ComputerActionDecision
  ```
- **Semantics**:
  - If `candidates` contains an element with role `"AXScrollArea"`, `"AXWebArea"`, `"AXTable"`, `"AXList"`, or `"AXOutline"`, `fallbackLocalDecision` selects that container, populating `targetElementId: container.id` and `targetCenter: container.center`.
  - If `lastDiff?.isStateUnchanged == true` or `recentEscalations.contains(where: { if case .actionStagnant = $0.reason { return true }; return false })`, `fallbackLocalDecision` does NOT repeat a scroll on the same target. It selects an alternate action (e.g. keyboard navigation `keyPress` with `["PageDown"]` or concludes the subgoal if at boundary).
  - If no candidate matches label heuristics, `fallbackLocalDecision` uses token overlap before falling through to low confidence, and provides structured recovery.

## Code Layout
- `Sources/MCAReasoning/TypeSafeDecisionEngine.swift`: Offline local deterministic fallback, candidate grounding, scroll targeting.
- `Sources/MCAReasoning/TwoTierAutonomousLoopCoordinator.swift`: Loop coordination, heuristic replanning, escalation management, event synthesis dispatch.
- `Tests/MCAReasoningTests/TwoTierAutonomousLoopOfflineRegressionTests.swift`: Dedicated offline regression test suite covering R1–R4.
- `Tests/MCAReasoningTests/TypeSafeDecisionEngineTests.swift`: Decision engine unit tests.
- `Tests/MCAReasoningTests/TwoTierAutonomousLoopCoordinatorTests.swift`: Coordinator unit tests.
