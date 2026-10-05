# SPEC: TypeSafe AI × Native macOS Computer Automation Mechanism

## 1. Overview & Long-term Viability Goals

This specification defines the permanent, production-ready architecture for autonomous GUI computer operation in `my-computer-agent` (MCA).
It solves the core trade-off of current GUI agents:
- **Pure Vision VLM (Slow, 3-10s/step)**: Too slow for human-like interactive workflow; prone to pixel-coordinate hallucinations and token cost explosion.
- **Pure Rule-based / Scripting (Brittle)**: Breaks immediately when UI layout changes, button labels vary, or unexpected modal dialogs appear.

### The Solution: Dual-System Autonomous Operation Loop
We combine **macOS Local Deterministic Perception (0-30ms)** with **TypeSafe Jev System One (100-200ms typed judgments)** and **System Two Multimodal LLM (deep planning & fallback)** to achieve human-reflex speed with enterprise-grade safety.

---

## 2. Architecture & Data Flow Contract

```
                     ┌───────────────────────────────────────┐
                     │         User Goal / Intent            │
                     │ ("Open Safari and search for Flights")│
                     └───────────────────┬───────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 1. Perception & Privacy Layer (MCASensing / MCACore)                             │
│   - AccessibilityInspector: Extracts actionable elements with CG coordinates    │
│   - PrivacyFilter: Drops AXSecureTextField, blocks 1Password/Keychain, redacts   │
│     API keys, tokens, and credit card numbers                                    │
│   - ViewportPruner: Caches and prunes candidates to top 25 to prevent token bloat│
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ Sanitized UIElementCandidates
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 2. Dual-System Decision Engine (MCAReasoning)                                   │
│   - TypeSafeClient: Calls POST https://api.typesafe.ai/v1/systemone             │
│   - Speculative Fan-out Questions in 1 round-trip:                              │
│       * target_element (Choice): Identifies next element ID or "none"           │
│       * action_type (Choice): click, double_click, type, key, wait, none        │
│       * is_completed (Noul): Goal completion probability                        │
│   - Confidence-Gated Arbiter:                                                   │
│       * Confidence >= 0.80 ──> Proceed with native execution (System 1 Loop)    │
│       * Confidence < 0.80 or target="none" ──> Escalate to System 2 (VLM)       │
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ ComputerActionDecision
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 3. Execution & Safety Layer (MCASensing / EventSynthesizer)                     │
│   - CoordinateMapper: Resolves CG global point (origin.x + w/2, origin.y + h/2) │
│   - Screen Bounds Check: Asserts target point is inside NSScreen visible frame  │
│   - Fail-safe (Dead Man's Switch): If user physically moves mouse, abort loop   │
│   - Event Dispatch: Native CGEvent mouse / keyboard input                       │
└────────────────────────────────────────┬────────────────────────────────────────┘
                                         │ State Change
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ 4. Verification & Feedback Loop                                                 │
│   - Loop condition: Re-inspect window state; verify is_completed Noul >= 0.70   │
│   - Max steps guard (e.g. 10 steps max per user command)                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Responsibilities & Conformance

| Component | Layer | Responsibilities |
|---|---|---|
| `UIElementCandidate` | `MCACore` (0) | Immutable value type for UI nodes (`id`, `role`, `label`, `value`, `bounds: CGRect`, `center`). |
| `ComputerActionDecision` | `MCACore` (0) | Typed action decision (`action`, `targetElementId`, `confidence`, `isCompleted`, `targetCenter`). |
| `PrivacyFilter` | `MCASensing` (1) | Redacts PII, blocks credential managers (1Password, Bitwarden, Keychain), removes secure text. |
| `AccessibilityInspector` | `MCASensing` (1) | Traverses `AXUIElement` tree, collects actionable nodes with exact screen bounds, prunes to max 25. |
| `EventSynthesizer` | `MCASensing` (1) | Dispatches CoreGraphics `CGEvent` for mouse moves, clicks, drag, Unicode typing, and shortcut keys. |
| `TypeSafeClient` | `MCAReasoning` (4) | HTTP client for TypeSafe API (`/v1/systemone`), handles auth via `SecretStore` or env. |
| `TypeSafeDecisionEngine` | `MCAReasoning` (4) | Transforms candidates to Choice/Noul questions, runs Speculative Fan-out, maps decision back to screen center. |
| `ComputerActionTool` | `MCAReasoning` (4) | Anthropic Computer Use tool integration for external agent / MCP coordination. |

---

## 4. Safety & Guardrails (SSOT)

1. **Zero-Trust Privacy**:
   - `AXSecureTextField` nodes are completely discarded prior to serialization.
   - Known password managers (`com.1password.*`, `com.bitwarden.*`, `com.apple.keychainaccess`) yield 0 candidates.
   - Text is run through regex filters to scrub API keys, tokens, and credit card numbers.
2. **Token Economy & Latency Guarantee**:
   - Max candidate cap = 25 elements.
   - Prevents prompt bloat and guarantees single-turn inference latency < 200ms.
3. **Fail-safe Emergency Stop**:
   - Before executing an action, check current mouse location (`NSEvent.mouseLocation`). If user has moved the physical mouse during automation, the loop immediately terminates to prevent rogue interactions.
4. **Coordinate Integrity**:
   - `UIElementCandidate.center` computes `(bounds.origin.x + bounds.size.width / 2.0, bounds.origin.y + bounds.size.height / 2.0)` in CoreGraphics coordinates directly compatible with `CGEvent`.

---

## 5. Test & Quality Matrix

| Test Suite | File | Coverage |
|---|---|---|
| `PrivacyFilterTests` | `Tests/MCASensingTests/PrivacyFilterTests.swift` | App blocking, regex redaction, secure field stripping. |
| `TypeSafeDecisionEngineTests` | `Tests/MCAReasoningTests/TypeSafeDecisionEngineTests.swift` | Empty candidate safety, center calculation, serialization. |
| `EventSynthesizerTests` | `Tests/MCASensingTests/EventSynthesizerTests.swift` | Mouse button events, bounds safety, string input. |
| `ComputerToolsTests` | `Tests/MCAReasoningTests/ComputerToolsTests.swift` | Tool schema conformance, AppleScript execution. |

All changes must pass:
```bash
Scripts/gate.sh
```

## 6. Screen-driven autonomous agent extension (pending approval)

This section defines the requested end state; it is not a claim that the current
implementation provides it. The dual-system loop above remains an implementation
detail. A task must produce a useful result, not only an actuator trace.

### Original Request

このプロジェクトはAIが画面をみながら状況や判断を自動的に行うエージェントにするつもり。例えば、MTG(ZoomやGoogle Meet)などで画面共有したらその内容に基づいて自動的に何かをする（破壊的な処理ならユーザーにチャットUIで承認依頼）するComptuer Use的に動かしたい。他の例はFirefoxなどブラウザー上でx.comのTwttier内容を共有しながらチャットでビューが5K以上のデータをスクロールしながら探してって言ったら画面を操作して要求を満たすことのできるプログラムにしたい

### Current implementation evidence (2026-10-01, base e9b9d7f)

| Requirement | Observed source evidence | Remaining work |
|---|---|---|
| Screen observation | ScreenWatcher captures focused/pinned windows and displays, deduplicates frames, supports meeting roles | Bind an ongoing user objective to observation and execution |
| Meeting assistance | WatchRole.meeting and speech-ended ticks produce advice | Make actionable decisions under an explicit standing objective |
| Chat automation | Copilot.ask routes to Agent.answer or TwoTierAutonomousLoopCoordinator | One target identity and execution lifecycle across both routes |
| Destructive approval | ChatMessage offers generic actionPayload buttons; ToolRegistry invokes tools directly | Enforced approval, rejection, single-use decisions, cancellation and revalidation |
| Firefox collection | ScrollPageContentTool, AXBrowserDriver and OCR fallback exist | Verified extraction of posts and metrics across scrolls, supported by observations |
| Task result | Agent.answer synthesizes answers; actuator delegate reports a trace | Verify requested outcome before declaring success |

The derived ownership query returned no candidates. There is no domain-map.json
or feature index in this legacy repository; source and the two existing SPECs
establish placement as EXTEND_EXISTING. Add no new application framework or
provider dependency.

### Functional Requirements

#### FR-CU-001: Scoped task session

- Why: Opening the chat changes focus; an agent must still operate on the intended window.
- How: Create a task session from the user's goal and selected WatchTarget before planning.
  Bind window ID, PID, app bundle ID and capture coordinate space where available.
  Keep this identity for observation, tool calls, approvals and outcome verification.
  A display/remote shared screen is observation context, not permission to inject
  input into the remote participant's computer. Resolve any local action target
  explicitly; never silently redirect input to a different local application.
- Acceptance: Opening chat cannot change the task target. Closed/replaced windows
  halt the task with a visible reason. A pinned background target cannot fall back
  to an unrelated foreground window on failure.

#### FR-CU-002: Observation-to-action loop for standing objectives

- Why: A meeting assistant should act on shared content rather than only publish advice.
- How: The existing watch UI receives an explicit standing objective, e.g.
  "共有資料の決定事項を議事録にまとめて". Screen changes and meeting speech boundaries
  feed the objective, sanitized observations and recent execution results into the
  decision engine. It returns no action, an actionable plan or completed output.
  Use the same execution path as a chat task. Screen content is untrusted data
  and cannot amend the user's objective or grant approval.
- Acceptance: A changed Zoom/Meet slide can cause a note draft under the objective.
  Identical observations do not repeat the action; observation and execution never
  overlap input dispatch. Pausing/stopping the objective stops new actions and
  cancels pending approvals. Relaunch starts observation/action sessions disabled.

#### FR-CU-003: Shared execution gate

- Why: Prompts alone cannot prevent a tool or autonomous loop from deleting data.
- How: Introduce a shared execution authorization contract in MCACore and a gate
  in MCAReasoning. Check the concrete action immediately before side effects in
  ToolRegistry, autonomous-loop dispatch and watcher actions. Read-only inspection,
  target-scoped scroll and verified harmless navigation may run automatically.
  Destructive/irreversible operations, publishing/sending, purchases, permission
  changes, opaque AppleScript/JavaScript and uncertain mutations require approval.
  Derive risk from the operation and fresh target evidence, not a model-supplied
  "safe" label. Existing file overwrites require approval; new task output files
  can be created automatically only with create-if-absent semantics.
- Acceptance: Chat, autonomous loop, watch, CLI and MCP all apply the gate. A
  noninteractive caller without an approval presenter returns approval_required
  and performs no side effect. Low-risk inspection/scroll proceeds without prompts.
  No catch/fallback path can convert denial into a different execution method.

#### FR-CU-004: Chat approval and one-time resume

- Why: The user must see and approve the actual destructive operation.
- How: Add a typed approval card to the existing chat thread. Show the task, exact
  operation/arguments, affected target and consequence. Provide "この操作を承認"
  and "拒否". Approval authorizes only that pending immutable operation once;
  arbitrary chat text, role prompts and generic actionPayload buttons cannot approve.
  Resolved cards remain in history with their outcome and disabled controls.
- Acceptance: While pending, the task dispatches no input; the chat remains usable.
  Reject, stop, cancellation and shutdown resolve the waiter without executing.
  Repeated clicks cannot dispatch twice. Approving action A cannot authorize B.
  Keyboard and accessibility labels distinguish approve from reject in EN/JA/KO.

#### FR-CU-005: Revalidation after approval

- Why: Focus, UI content and file contents can change while the approval card is visible.
- How: Re-capture and compare the affected target and operation preconditions after
  approval, immediately before dispatch. A changed window, element identity,
  destination, overwrite content or operation requires a new decision/approval.
  After approved input, retain user interruption guards and release held events.
- Acceptance: A changed delete target cannot reuse an old approval. Approval UI
  focus cannot cause input into the chat. For file overwrite, compare and replace
  under a mutation API that rejects stale contents rather than a separate unsafe
  fileExists check. Cancellation wins over an approved-but-not-dispatched operation.

#### FR-CU-006: Firefox/X search with evidence

- Why: The user's request is to find qualifying posts, not merely scroll the page.
- How: Route "Firefox の X でビューが5K以上の投稿をスクロールしながら探して"
  to collection plus answer synthesis even without "まとめて/教えて". Preserve
  the requested target, gather AX text or OCR from each settled viewport, associate
  each view count with its own post, deduplicate by post URL/ID when available,
  and parse localized counts (5K, 5,000, 1.2万). Use >= 5,000 as the default bound.
  Missing/ambiguous view counts are unknown, never inferred from likes/reposts.
- Acceptance: A multi-viewport fixture containing 4.9K, 5K, 12K and duplicates
  returns the 5K/12K posts once with their observed view count, author/text and link
  when visible. Virtualized feeds retain previous results. Page end, unchanged
  viewports, cancellation and budgets produce an honest partial-result reason.
  Live Firefox verification must confirm actual scrolling and readable results.

#### FR-CU-007: Useful results and bounded execution

- Why: A successful event dispatch does not establish that the user's goal succeeded.
- How: Preserve observations and tool results in the task session. Return a useful
  final answer/artifact based on those results, with completed/partial/failed/cancelled
  status, inspected coverage and the specific remaining limitation. Keep step,
  deadline and repetition budgets for both actuation and collection.
- Acceptance: A search returns posts, meeting work returns notes or the requested
  artifact, and a failed operation never reports completion. Cancellation interrupts
  model waits and tool/approval waits and prevents any later task input.

### 0.1 Target Files

| Layer / files | Change |
|---|---|
| Sources/MCACore | Typed task target, action authorization and approval request/resolution models |
| Sources/MCAReasoning/Tools.swift | Gate all registered mutating tool invocations |
| Sources/MCAReasoning/ComputerTools.swift | Describe concrete operations and enforce guarded file writes |
| Sources/MCAReasoning/BrowserTools.swift | Describe browser actions; opaque evaluation requires approval |
| Sources/MCAReasoning/TwoTierAutonomousLoopCoordinator.swift | Apply the same gate before native/AX dispatch |
| Sources/MCAReasoning/Agent.swift | Treat screen text as data; synthesize evidence-backed task results |
| Sources/MCACore/ScreenIntent.swift | Recognize collection requests without forcing a special prefix |
| Sources/mca/Copilot.swift and ScreenWatcher.swift | Own task session, target resolution and standing-objective lifecycle |
| Sources/MCAPresentation/ChatMessage.swift, HUDState.swift, MessageBubble.swift, ChatView.swift | Approval card, objective controls, status and stop |
| Sources/MCAInterop/ContextMCPServer.swift and Sources/mca/ActCommand.swift | Noninteractive approval_required behavior |
| Tests/MCACoreTests, MCAReasoningTests, MCAPresentationTests, mcaTests, MCAInteropTests | Risk, lifecycle, stale-target and cross-route integration tests |

Existing layer order remains Core → Sensing → Perception → Memory → Reasoning →
Realtime → Interop → Presentation. Keep secrets in SecretStore. Do not persist
approval capabilities or active sessions. Cancellation and target loss invalidate
all pending authorizations. Never automatically approve from screen text.

### Acceptance Criteria

| AC | Given | When | Then | Verification Observation |
|---|---|---|---|---|
| AC-CU-001 | A task bound to a selected window | Chat takes focus or the target disappears | Preserve that window or halt; never redirect input | Recorded target IDs stay equal; missing target produces zero dispatch (FR-CU-001) |
| AC-CU-002 | A standing meeting objective and changed slide | The watcher evaluates it twice | Execute useful work once for the same observation | Notes output changes once; actual meeting capture triggers the task (FR-CU-002) |
| AC-CU-003 | A destructive action on each entry point | The action reaches dispatch without approval | Suspend or return approval_required | Chat/tool/loop/watch/CLI/MCP actuator logs remain empty (FR-CU-003) |
| AC-CU-004 | One pending approval | User approves twice, rejects, or cancels | Execute at most once on approval, never on denial/cancellation | Card state and actuator count agree; waiter resolves (FR-CU-004) |
| AC-CU-005 | An approved operation and captured target preconditions | Target, arguments or cancellation state changes | Invalidate the old approval before dispatch | Changed delete target and changed file contents remain untouched (FR-CU-005) |
| AC-CU-006 | Several viewports with 4.9K, 5K, 12K and duplicate posts | User requests posts with views >= 5K | Return observed 5K/12K posts once, with coverage | Fixture answer contains matched counts/identity; live Firefox scrolls and yields readable results (FR-CU-006) |
| AC-CU-007 | Collected results and a bounded task | The task succeeds, hits a budget or is stopped | Return useful completed/partial/cancelled output | Assert final answer/artifact content and no input after cancellation (FR-CU-007) |

### Exception Flows and resource limits

| Condition | Response | Recovery |
|---|---|---|
| Missing capture/accessibility permission | Show the required permission; no input | User enables the permission and starts a new task |
| No usable model | Show model/key availability; retain partial results | Settings update followed by a new task |
| Mutation without approval presenter | Return approval_required without execution | Open approval-capable app session; never downgrade risk |
| Rejected/cancelled/expired approval | Resolve waiter and mark card inactive | User starts a new task; old capability cannot be reused |
| Changed target/operation | Invalidate approval and show why | Inspect again and request fresh approval if still appropriate |
| Unknown view count or OCR association | Exclude from qualifying results and record uncertainty | Collect another viewport; never substitute engagement metrics |
| Feed end, stagnant viewport or budget | Return partial results with the stop reason | User can request more collection explicitly |

Use one active executing task in the app and serialize input across watch/chat.
The default task budget is 20 native action steps, 15 tool rounds, and 120 seconds
of active execution; each collection call is capped at 10 scrolls. A standing
objective may evaluate again after a later observation, but cannot reset a budget
to continue the same failed action forever. Approval waiting does not consume the
active-execution budget; an unresolved card expires after five minutes, denying
the operation. Screen observations use existing watch intervals and change
deduplication. Stop cancels active model/tool/approval waits immediately.

### Verification and completion contract

1. Offline tests exercise real task execution entry points with fake model/sensor
   inputs and recorded actuators, proving zero dispatch before approval and on denial.
2. Approval tests cover cancellation, duplicate resolve, changed target, changed
   arguments, focus changes, and CLI/MCP without a presenter.
3. A multi-viewport post fixture proves count association, boundary parsing,
   duplicate suppression and final answer content; checking routing alone is insufficient.
4. `Scripts/gate.sh` must pass in the implementation worktree, with existing tests retained.
5. Live macOS smoke verification must exercise pinned Firefox collection, a meeting
   screen-driven objective, and a harmless disposable mutation requiring approval.
   No real user data is deleted or posted during verification. Record permission/model
   availability and unverified behavior explicitly; fixture tests do not prove live behavior.
6. Independent review and main-side trust evaluation precede shipping. This changes
   specification, UI and authorization behavior, so human Pre-Ship approval is required.
7. This goal is complete only after all seven requirements and live cases pass,
   followed by the repository's required PR/merge and cleanup workflow.

### Delivery sequence

1. Review the full requirement set and approval/objective UI; record the verdict.
2. Implement the execution gate and chat approval lifecycle across all routes.
3. Bind task identity and integrate standing-objective screen decisions with execution.
4. Implement evidence-backed collection/results and verify Firefox/meeting behavior.
5. Run the final gate, independent review, trust evaluation and human shipping approval.

No milestone redefines the original goal as complete. Remote desktop control,
meeting bot participation and installing another browser are not required by the
request; local operation on the selected content remains in scope.

## Revision History

| Version | Date | Description | Affected FRs |
|---|---|---|---|
| 1.1 | 2026-10-01 | Screen-driven objectives, shared execution approval and evidence-backed Firefox collection; SPEC/UI approved by explicit 承認. Implementation acceptance remains in progress | FR-CU-001 through FR-CU-007 |
