/**
 * approval-policy.mjs — Risk-tiered approval decisions (pure functions + one config read).
 *
 * Why (user decision 2026-09-25): human approval of AI output is reserved for decisions that are
 * hard to take back — a large UI change, a breaking data change, a pivot. Everything else is
 * approved automatically after an independent automated evaluation. Blanket approval had become
 * theater: Anthropic measured 93% acceptance of per-action prompts in Claude Code, and this repo's
 * only code-enforced human gate treated a typo fix and a schema break identically.
 *
 * Sources for the tiering:
 *   - Amazon one-way / two-way doors (Bezos, 2015 shareholder letter): deliberate on irreversible
 *     decisions, delegate reversible ones.
 *   - ITIL 4 "standard change": pre-authorised low-risk changes; routing them to a CAB is an anti-pattern.
 *   - Meta RADAR diff-risk gating (arXiv 2605.30208): only low-risk diffs skip human review; the
 *     threshold is calibrated against revert / incident rates, not assumed.
 *   - Claude Code auto mode (anthropic.com/engineering/claude-code-auto-mode): classify each action,
 *     escalate only the irreversible.
 *
 * Tiers:
 *   T0 mechanical  — any review label; nothing a program or agent reads as instructions changed.
 *   T1 reversible  — auto-approved once an *independent* review passed (maker-checker split).
 *   T2 one-way     — a human decides. The test for one-way is the user's (2026-09-27): would taking it
 *                    back after the merge cause a critical problem — an architecture change, a
 *                    large refactor, a pivot, data a revert cannot recall, or a loosened gate.
 *
 * A missing or unreadable policy decides T2 everywhere: without the policy there is no basis for
 * trusting anything automatically, so the pre-policy behaviour (always ask) is what remains.
 *
 * Boundary (R-CM-028): boundary-uniform for the `ui` and `stage` surfaces (deployed with
 * ui-approval-gate / harness-orchestrator). The `ship` surface is consumed only by the
 * Perspective 1 ship gate (`change-risk.mjs`, `pre-ship-steps.mjs`).
 */

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const APPROVAL_POLICY_RELPATH = '.claude/config/approval-policy.json';

export const TIERS = Object.freeze({ T0: 'T0', T1: 'T1', T2: 'T2' });

const TIER_RANK = { T0: 0, T1: 1, T2: 2 };

/** The higher-stakes of two tiers. */
export function maxTier(a, b) {
  return (TIER_RANK[a] ?? 2) >= (TIER_RANK[b] ?? 2) ? a : b;
}

const compile = (patterns) => (Array.isArray(patterns) ? patterns : []).map((p) => new RegExp(p));

/**
 * Loads and compiles the policy. Returns `{ policy: null, error }` instead of throwing — callers
 * turn a null policy into T2, and the error is carried into the reasons so it is seen, not guessed.
 */
export function loadApprovalPolicy(projectDir, { existsFn = existsSync, readFn = readFileSync } = {}) {
  const path = join(projectDir, APPROVAL_POLICY_RELPATH);
  try {
    if (!existsFn(path)) return { policy: null, error: `${APPROVAL_POLICY_RELPATH} not found` };
    return { policy: compilePolicy(JSON.parse(String(readFn(path, 'utf-8')))), error: null };
  } catch (e) {
    return { policy: null, error: `${APPROVAL_POLICY_RELPATH} unreadable: ${e?.message ?? e}` };
  }
}

/** Data-contract + product-size thresholds (`data_contract` / `product_large` policy keys). */
function compileShipReachSection(ship) {
  return {
    dataReachTier: ship.data_contract?.reach_tier ?? 'data',
    dataAlwaysOneWay: compile(ship.data_contract?.always_one_way),
    dataNotContract: compile(ship.data_contract?.not_contract),
    productReachTier: ship.product_large?.reach_tier ?? 'product',
    productMaxFiles: Number(ship.product_large?.max_files ?? 10),
    productMaxLoc: Number(ship.product_large?.max_loc ?? 400),
    screenPaths: compile(ship.product_large?.screen_paths),
    designSystemPaths: compile(ship.product_large?.design_system_paths),
  };
}

/** Mass-deletion + mechanical-path thresholds (`mass_deletion` / `mechanical_paths` / `review_labels`). */
function compileShipSafetySection(ship) {
  return {
    massDeletedFiles: Number(ship.mass_deletion?.min_deleted_files ?? 10),
    massDeletedLoc: Number(ship.mass_deletion?.min_deleted_loc ?? 800),
    mechanicalPaths: compile(ship.mechanical_paths?.match),
    reviewLabels: {
      T0: new Set(ship.review_labels?.T0 ?? []),
      T1: new Set(ship.review_labels?.T1 ?? []),
    },
  };
}

/** Compiles the `ship` section: reach-tier thresholds, path matchers, and review-label sets. */
function compileShipSection(ship) {
  return {
    trustBoundary: compile(ship.trust_boundary?.match),
    direction: compile(ship.direction?.match),
    ...compileShipReachSection(ship),
    ...compileShipSafetySection(ship),
  };
}

/** Compiles the `escape` section: post-ship escape-detection window and pattern matchers. */
function compileEscapeSection(esc) {
  return {
    windowDays: Number(esc.window_days ?? 14),
    scanDepth: Number(esc.scan_depth ?? 200),
    fixSubject: new RegExp(esc.fix_subject ?? '^(fix|revert)(\\([^)]*\\))?!?:|^Revert "', 'i'),
    ignorePaths: compile(esc.ignore_paths),
    guardPaths: compile(esc.guard_paths),
  };
}

/** Raw JSON → policy with compiled regexes. Throws on a malformed pattern (a wrong policy is worse than none). */
export function compilePolicy(raw) {
  return {
    raw,
    ship: compileShipSection(raw?.ship ?? {}),
    escape: compileEscapeSection(raw?.escape ?? {}),
    ui: raw?.ui ?? null,
    stage: raw?.stage ?? null,
  };
}

export const matchesAny = (patterns, path) => patterns.some((re) => re.test(path));

const decision = (tier, reasons) => ({ tier, auto: tier !== TIERS.T2, reasons });

const NO_POLICY = (error) => decision(TIERS.T2, [{ code: 'no_policy', detail: error ?? 'approval policy unavailable' }]);

/**
 * UI wireframe approval (ui-approval-gate). Signals are declared by the gate from the wireframes
 * it produced; the policy decides, so the threshold is not re-judged per feature.
 *
 * @param {{navigation_changed?: boolean, design_system_changed?: boolean, screens_removed?: number,
 *          screens_new?: number, existing_screens_changed?: number, automated_critique?: 'pass'|'fail'|null}} signals
 */
/** One-way UI flags (navigation/design-system changes declared directly by the gate). */
function collectUiFlagReasons(ui, s) {
  const reasons = [];
  for (const flag of ui.one_way_flags ?? []) {
    const v = s[flag];
    if (v === true || (typeof v === 'number' && v > 0)) reasons.push({ code: flag, detail: `${flag}=${v}` });
  }
  return reasons;
}

/** Threshold + gate reasons: too many existing screens touched, or critique not passed. */
function collectUiThresholdReasons(ui, s) {
  const reasons = [];
  const changed = Number(s.existing_screens_changed ?? 0);
  if (changed > Number(ui.max_existing_screens_changed ?? 2)) {
    reasons.push({ code: 'many_existing_screens', detail: `${changed} existing screens change (> ${ui.max_existing_screens_changed})` });
  }
  if (ui.require_automated_critique && s.automated_critique !== 'pass') {
    reasons.push({ code: 'critique_not_passed', detail: `automated_critique=${s.automated_critique ?? 'not run'}` });
  }
  return reasons;
}

export function decideUi(signals, policy, error = null) {
  const ui = policy?.ui;
  if (!ui) return NO_POLICY(error ?? 'policy has no `ui` section');
  const s = signals ?? {};
  const reasons = [...collectUiFlagReasons(ui, s), ...collectUiThresholdReasons(ui, s)];
  return reasons.length ? decision(TIERS.T2, reasons) : decision(TIERS.T1, [{ code: 'in_structure', detail: 'screens stay within the existing navigation and design system' }]);
}

/**
 * Pipeline stage checkpoint (R-CM-031 Rule 2-A).
 *
 * @param {{stage: number, decision?: string|null, confidence?: number|null,
 *          production_gate?: 'pass'|'fail'|null, builder_override?: boolean}} signals
 */
/** One-way stage / decision-direction reasons (locking a choice future stages build on). */
function collectStageDirectionReasons(st, s) {
  const reasons = [];
  if ((st.one_way_stages ?? []).includes(Number(s.stage))) {
    reasons.push({ code: 'one_way_stage', detail: `stage ${s.stage} locks a choice later stages build on` });
  }
  const verdict = typeof s.decision === 'string' ? s.decision.toLowerCase() : null;
  if (verdict && (st.one_way_decisions ?? []).includes(verdict)) {
    reasons.push({ code: 'direction_change', detail: `decision=${verdict}` });
  }
  return reasons;
}

/** Gate / override / confidence reasons (whether the automated production gate can be trusted). */
function collectStageGateReasons(st, s) {
  const reasons = [];
  if (s.production_gate !== 'pass') {
    reasons.push({ code: 'production_gate', detail: `production_gate=${s.production_gate ?? 'unknown'}` });
  }
  if (s.builder_override === true) reasons.push({ code: 'builder_override', detail: 'override of a failed gate' });
  const conf = Number(s.confidence);
  if (!Number.isFinite(conf) || conf < Number(st.min_confidence ?? 0.65)) {
    reasons.push({ code: 'low_confidence', detail: `confidence=${Number.isFinite(conf) ? conf : 'unknown'} < ${st.min_confidence}` });
  }
  return reasons;
}

export function decideStage(signals, policy, error = null) {
  const st = policy?.stage;
  if (!st) return NO_POLICY(error ?? 'policy has no `stage` section');
  const s = signals ?? {};
  const reasons = [...collectStageDirectionReasons(st, s), ...collectStageGateReasons(st, s)];
  return reasons.length ? decision(TIERS.T2, reasons) : decision(TIERS.T1, [{ code: 'gate_passed', detail: 'production gate passed, direction unchanged' }]);
}

/** One-line rendering for CLI output and panel evidence. */
export function formatDecision(d) {
  const why = d.reasons.map((r) => r.detail).join('; ');
  return `${d.tier} ${d.auto ? 'auto-approve' : 'human approval required'}${why ? ` — ${why}` : ''}`;
}
