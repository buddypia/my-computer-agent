# E2E Test Infra: Dual-Track Offline & Fallback Autonomous Loop

## 1. Test Philosophy & Architecture
- **Requirement-Driven & Opaque-Box**: All test specifications are derived directly from `ORIGINAL_REQUEST.md` (R1–R4), `PROJECT.md` (Features 1–8), and user acceptance criteria. Tests interact strictly through the public interfaces of `TwoTierAutonomousLoopCoordinator`, `TypeSafeDecisionEngine`, and `DefaultSubgoalPlanner`, without relying on private implementation details.
- **Zero-Network In-Memory Mock Harness**: Real-time macOS accessibility (`AXUIElement`) and `CGEvent` synthesis require window server privileges and network access for cloud Jev. The test suite operates entirely in-memory using deterministic mock primitives (`MockTypeSafeEvaluator`, `MockPlanningLLM`, `MockUIInspector`, `MockEventSynthesizer`), guaranteeing reproducibility and sub-second test runs in CI and `Scripts/gate.sh`.
- **Progressive Testability & Defect Isolation**: Tests isolate failure modes across the two tiers (System 2 Subgoal Planner and System 1 Decision Engine), state diff verification (`UIStateDiff`), and safety guardrails (`TwoFactorLoopDetector`).

---

## 2. Dual-Track Testing Strategy

The test suite enforces a **Dual-Track** validation model to guarantee that the agent operates safely across both connected and disconnected environments:

### Track 1: Offline Deterministic Fallback & Local Grounding Track
- **Operational Condition**: TypeSafe Jev API is unavailable (missing API key `TypeSafeClient.ClientError.missingApiKey`, network disconnection `URLError.notConnectedToInternet`, or HTTP timeout).
- **Core Verification**:
  1. Container Grounding: Targets valid scroll containers (`AXScrollArea`, `AXWebArea`, `AXTable`, `AXList`) with concrete coordinates instead of `target=none` / `at: nil`.
  2. Stagnation-Aware Adaptation: Monitors `UIStateDiff.isStateUnchanged` after scroll actions and adapts (switching to keyboard navigation `PageDown`/`Down` or concluding subgoals) rather than looping.
  3. Token-Based Candidate Matching: Performs token and partial overlap matching across candidate labels, values, and roles to avoid premature `confidence: 0.00` fallthrough.
  4. Non-Recursive Heuristic Replanning: Strips stagnant trigger keywords from retry subgoal descriptions so the decision engine does not re-issue the failed action.
  5. Escalation Guard: Prevents cascading low-confidence or stagnant replans from tripping the 3-strike escalation limit (`Exceeded maximum consecutive escalations (3)`).

### Track 2: Online / Keyed Cloud Jev Simulation with Failover Track
- **Operational Condition**: Normal cloud Jev System 1 evaluation (`MockTypeSafeEvaluator.scripted` / `stepSequence`), with simulated transient or permanent network drop mid-task.
- **Core Verification**:
  1. Fast Path Execution: Sub-200ms decision processing and outcome verification.
  2. Seamless Failover: Graceful transition from cloud evaluation to Track 1 local deterministic fallback upon error.
  3. Reflection & Escalation: System 2 LLM replanning (`replacePlan`, `retrySubgoal`, `skipCurrentSubgoal`) with escalation record tracking.
  4. Progress Recovery: Resetting consecutive escalation counters upon successful state transitions.

---

## 3. Four-Tier Test Hierarchy

| Tier | Category | Scope & Objective | Target Count |
|:---:|:---|:---|:---:|
| **Tier 1** | **Feature Coverage** | Dedicated verification of Features 1–8 from `PROJECT.md` (>= 5 test cases per feature). | **40** |
| **Tier 2** | **Boundary & Corner Cases** | Edge conditions: empty candidates, 1x1 candidates, extreme scroll deltas, unkeyed Jev network failure, zero maxSteps, float confidence boundary, large candidate sets. | **8** |
| **Tier 3** | **Cross-Feature Combinations** | Multi-feature interactions: stagnant scroll + low confidence + heuristic replan; network failover + coordinate fallback; multi-subgoal escalation resets. | **5** |
| **Tier 4** | **Real-World Application Scenarios** | End-to-end simulated user workflows: unkeyed feed scrolling, multi-field form input recovery, search stream exhaustion, settings navigation and toggle. | **4** |
| **Total** | | **Comprehensive Offline E2E Suite** | **57** |

---

## 4. Feature Inventory & Mapping (Tier 1)

| Feature # | Feature Name | Source | Tier 1 Tests | Focus Areas |
|:---:|:---|:---:|:---:|:---|
| **F1** | Container Grounded Fallback Scroll | R1 | 5 | `AXScrollArea` targeting, `AXWebArea` fallback, `AXTable`/`AXList` scrolling, container center coordinate resolution, nested container selection. |
| **F2** | Stagnation-Aware Action Adaptation | R1 | 5 | Stagnation detection on `isStateUnchanged`, keyboard navigation fallback (`PageDown`/`Down`), boundary completion, state diff monitoring, counter reset on progress. |
| **F3** | Token-Based Candidate Matching | R3 | 5 | Partial label matching, value and role matching, multi-word token overlap, case/whitespace trimming, score disambiguation. |
| **F4** | Graceful Low-Confidence Recovery | R3 | 5 | Structured recovery on low confidence, candidate absence handling, retry without immediate abort, diagnostic reasoning, subgoal budget tracking. |
| **F5** | Feedback Loop to Decision Engine | R2 | 5 | Step history tracking, recent escalation record propagation, post-action diff notification, action recording, initial clean state. |
| **F6** | Non-Recursive Heuristic Replan | R2 | 5 | Stagnant keyword stripping, navigation goal reformulation, alternative description generation, outcome reassignment, safe fallback. |
| **F7** | Coordinator Coordinate Fallback | R1 | 5 | Scroll with nil coordinates, click targeting candidate center, scroll delta passing, event synthesizer recording, coordinate safety. |
| **F8** | Consecutive Escalation Recovery Guard | R2, R3 | 5 | Configurable escalation ceiling, 3-strike halt protection, detailed diagnostic logging, single-escalation recovery, counter reset on progress. |

---

## 5. Test Execution & Quality Gate Integration

### Execution Commands
- **Run Offline E2E Suite Only**:
  ```bash
  swift test --filter TwoTierAutonomousLoopOfflineE2ETests
  ```
- **Run All MCAReasoning Tests**:
  ```bash
  swift test --filter MCAReasoningTests
  ```
- **Run Full Project Quality Gate**:
  ```bash
  Scripts/gate.sh --force
  ```

### Gate Stage Integration
- **G0 (classify)**: Detects test and implementation changes.
- **G1 (build)**: Compiles `MCAReasoning` and `MCAReasoningTests`.
- **G2 (trust & test)**: Runs `node --test Scripts/trust/tests/*.test.mjs` and all Swift tests via `swift test`.
- **G2 (guards)**: Validates incident checklist and breaker state.

---

## 6. Coverage & Readiness Metrics
- **Passing Threshold**: 100% of tests in `TwoTierAutonomousLoopOfflineE2ETests` must pass.
- **Zero Network Flakiness**: All network and AX dependencies are mocked with 0ms settling delay.
- **No Facade Tests**: Every test asserts observable side effects (synthesized events, diff verification, execution summary status, or error cause).
