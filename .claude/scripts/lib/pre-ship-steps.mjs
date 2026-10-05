/**
 * pre-ship-steps.mjs — Fixed-order step-by-step verification SSOT before ship approval (pure evaluator)
 *
 * Why:
 *   Replaces the previous approach where AI dumped the full panel at once and solicited a single yes/no.
 *   Enforces deterministic machine validation for the prerequisite steps, isolating human trust to 1 explicit approval.
 *
 * Deterministic guarantees:
 *   - Step order is fixed by the `PRE_SHIP_STEPS` array.
 *   - Answers can ONLY be recorded for the currently pending step.
 *   - Answers are bound to what the human actually reviewed — the diff this branch contributes
 *     (`resolveReviewDiffId`), not the HEAD sha. See that function for why.
 *
 * Boundary (R-CM-028): perspective1-only — R-CM-030 is never_deploy. Not deployed to scaffolds.
 */

import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { writeJsonAtomicSync } from './atomic-fs.mjs';
import {
  defaultGit,
  checkShipDeckFreshness,
  hasMilestoneDeckTrace,
  measureShipScale,
} from '../../../.cli/lib/ship-scale.mjs';
import { safeBranchKey, resolveWorktreePlanPath } from '../../../.cli/lib/worktree-plan-path.mjs';
import { parseUncheckedPlanItems } from '../../../.cli/lib/worktree-plan-status.mjs';
import {
  OBLIGATION_MIN_REASON_LENGTH,
  parseObligationDecisions,
} from '../../../.cli/lib/plan-obligation.mjs';
import { readCreatePrConfigKey, resolveShipBaseBranch } from '../../../.cli/lib/ship-base-branch.mjs';
import {
  COUNTED_SCALES,
  assessTrunk,
  buildShipRecord,
  countCrossReviewSkipStreak,
  formatLandingName,
  formatTrunkRefMovedAge,
  readLedger,
  readTrunkLandings,
  readTrunkRefMovedAge,
  trunkRef,
} from '../../../.cli/lib/ship-quality-ledger.mjs';
import { readQualityGateRecord, resolveHeadSha } from './worktree-quality-gate.mjs';
import { readBranchTaskContract } from './task-passport.mjs';
import { APPROVAL_CHOICES, normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';
import { loadReviewPanelConfig } from '../../../.cli/lib/worktree-ship-report.mjs';
import { checkLabelEvidence } from '../../../.cli/lib/quality-gate-labels.mjs';
import { loadApprovalPolicy } from './approval-policy.mjs';
import { measureDiffRisk } from './change-risk.mjs';
import { assessAutoApproval, loadTrust } from './approval-trust.mjs';
import { loadReachMap } from './change-reach.mjs';

export const STEP_STATUS = {
  OK: 'ok',
  BLOCKED: 'blocked',
  WARN: 'warn',
  NA: 'na',
  AWAITING: 'awaiting',
};

// Approval vocabulary (labels shown + tokens parsed) lives in one module shared with the review
// panel; re-exported here so existing importers of this module keep working.
export { APPROVAL_SPECS, APPROVAL_CHOICES, normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';

export function answerStorePath(worktreeAbs, branch) {
  return join(dirname(resolveWorktreePlanPath(worktreeAbs, branch)), 'pre-ship-answers.json');
}

export function readAnswerStore(path, { existsFn = existsSync, readFn = readFileSync } = {}) {
  try {
    if (!existsFn(path)) return {};
    const parsed = JSON.parse(String(readFn(path, 'utf-8')));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/**
 * Projects cross-review skip streak including the current ship, over what actually landed on the trunk.
 *
 * `landings` (newest-first, from `git log --first-parent origin/<base>`) is joined with the ledger
 * first, so a merge that never wrote a row counts instead of being absent. `landings` null/omitted
 * means the trunk was not read: reported as `trunkRead: false`, never as zero bypasses, and the streak
 * falls back to the ledger rows alone.
 *
 * The census (`unrecorded`, `unrecordedTotal`) is computed even when the current scale is not counted
 * and before the projected entry is appended — a bypass is a fact about the repository, and a
 * projected `agent_go` would otherwise bury every bypass behind itself.
 *
 * @param {{ledger: Array<object>|null, landings?: Array<object>|null, scale: string|null,
 *          qualityLabel: string|null, refMovedAge?: number|null, baseBranch?: string|null}} input
 * @returns {{counted: boolean, streak: number, prs: Array<number|string>, unrecorded: Array<number|string>,
 *            unrecordedTotal: number, bots: Array<number|string>, noLedger: boolean, trunkRead: boolean, refMovedAge: number|null,
 *            baseBranch: string|null, scale: string|null}}
 */
export function projectCrossReviewStreak({
  ledger,
  landings = null,
  scale,
  qualityLabel,
  refMovedAge = null,
  baseBranch = null,
}) {
  const normalizedScale = typeof scale === 'string' ? scale : null;
  const trunk = assessTrunk({ ledger, landings });
  const census = {
    unrecorded: trunk.unrecorded,
    unrecordedTotal: trunk.unrecordedTotal,
    bots: trunk.bots,
    noLedger: trunk.noLedger,
    trunkRead: trunk.trunkRead,
    refMovedAge,
    baseBranch,
  };
  if (!COUNTED_SCALES.has(normalizedScale)) {
    return { counted: false, streak: 0, prs: [], ...census, scale: normalizedScale };
  }
  const projected = buildShipRecord({
    pr: null,
    branch: null,
    quality_label: qualityLabel,
    scale: normalizedScale,
    milestone_deck: false,
    at: '',
  });
  const { streak, prs } = countCrossReviewSkipStreak([...trunk.entries, projected]);
  return {
    counted: true,
    streak,
    prs: prs.filter((p) => p !== null && p !== undefined),
    ...census,
    scale: normalizedScale,
  };
}

/**
 * The bypass census as its own panel line — a fact about the **repository**, so it renders whenever
 * the panel does (including when the ship is blocked before PROOF, the population most likely to be
 * skipping the gate), not as a tail of step 4's evidence.
 *
 * A read trunk is always qualified with the local ref and when it last moved: `origin/<base>` is a
 * local copy that may be a day old, and an unqualified "0 unrecorded" reads as current. An unread
 * trunk is never qualified — a timestamp beside "NOT READ" would imply something was seen.
 */
export function formatTrunkCensusLine(crossReview) {
  if (!crossReview) return 'Trunk: census undetermined';
  if (!crossReview.trunkRead) {
    const ref = crossReview.baseBranch ? trunkRef(crossReview.baseBranch) : 'origin/<base>';
    return `Trunk: NOT READ (${ref} unavailable — no remote, or never fetched); the gate-bypass check did not run`;
  }
  if (crossReview.noLedger) {
    return 'Trunk: no ledger yet — the bypass census starts at the first ship recorded by ship-worktree';
  }
  const total = crossReview.unrecordedTotal ?? 0;
  const list = crossReview.unrecorded ?? [];
  const named = list.length
    ? `${list.length} landing(s) merged outside ship-worktree (UI or direct push) with NO ledger row since the last recorded ship: ` +
      list.map(formatLandingName).join(' ') +
      (total > list.length ? ` (${total} in the window)` : '')
    : `0 unrecorded landings since the last recorded ship (${total} in the window)`;
  const bots = crossReview.bots?.length
    ? `; ${crossReview.bots.length} bot landing(s), not counted: ${crossReview.bots.map(formatLandingName).join(' ')}`
    : '';
  const qualifier = ` [local ${trunkRef(crossReview.baseBranch)}, ${formatTrunkRefMovedAge(crossReview.refMovedAge)}]`;
  return `Trunk: ${named}${bots}${qualifier}`;
}

// ─── Step Definitions (Array order = Contract) ────────────────────────────────

const machine = (id, title, evaluate) => ({ id, title, kind: 'machine', evaluate });
const human = (id, title, question, evaluate) => ({ id, title, kind: 'human', question, evaluate });

export function isLargeScale(ctx) {
  return ctx?.scale?.scale === 'large';
}

function resolveQuestion(def, ctx) {
  if (typeof def.question === 'function') {
    try {
      return def.question(ctx);
    } catch {
      return null;
    }
  }
  return def.question ?? null;
}

function formatCrossReviewEvidence(crossReview) {
  if (!crossReview) return 'Cross-review skip streak undetermined';
  if (!crossReview.counted) {
    return `Cross-review skip streak not counted (Scale: ${crossReview.scale ?? 'undetermined'})`;
  }
  return `Cross-review skip streak: ${crossReview.streak} consecutive (including current ship)`;
}

/**
 * Identifies *what the human reviewed*: the diff this branch contributes, hashed.
 *
 * **Why not the HEAD sha (observed 2026-08-25 → 2026-08-27)**: `ship-worktree` merges
 * `origin/<base>` into the branch as part of shipping (`ops.mjs#cmdShipWorktree`). That merge moves
 * HEAD, so a HEAD-bound approval was invalidated **by the very command the human had just
 * authorised**, and the human was re-asked. With other sessions landing PRs the same day, one ship
 * consumed four separate human approvals before it completed — the loop is structural, not bad luck:
 * re-verification takes minutes, and any PR landing inside that window restarts it.
 *
 * `<base>...HEAD` survives those merges when the base did not touch what this branch touches. Three-
 * dot diffs are computed against `merge-base(base, HEAD)`, so merging the base only advances the
 * merge-base and the branch's own hunks come out identical. The id *does* change when the branch
 * gains real work, when conflict resolution rewrites the branch's own files, and — because the hash
 * covers the rendered patch, not just its semantics — when the base edits a file this branch also
 * edits closely enough to shift hunk headers or context lines. The last case re-asks the human for a
 * change they arguably already reviewed; that is the conservative direction, and it is why this is
 * "survives an unrelated base merge", not "invariant under any base merge".
 *
 * Ship re-checks this after its own merge (`ops.mjs#assertApprovalFreshAfterBaseMerge`) — recording
 * the id at approval time is not enough on its own, because ship mutates the tree afterwards.
 *
 * This mirrors GitHub's own semantics (approvals survive base updates; "dismiss stale reviews"
 * fires on branch commits) and is stricter than it looks here, because this repo squash-merges:
 * the diff *is* the commit that lands.
 *
 * Machine PROOF keeps its HEAD binding deliberately (`quality-gate-proof` step) — re-running a test
 * suite is cheap and must cover the merged tree. Only the expensive, human-blocking signal is
 * rebound. Two bindings, two costs.
 *
 * @returns {string|null} sha256 of the diff, or null when git cannot resolve any base ref
 *   (fail-closed at the call sites: a null id falls back to the HEAD-sha comparison).
 */
export function resolveReviewDiffId(worktreeAbs, baseBranch, gitFn = defaultGit) {
  for (const ref of [`origin/${baseBranch}`, baseBranch]) {
    try {
      const diff = gitFn(worktreeAbs, ['diff', `${ref}...HEAD`]);
      if (typeof diff !== 'string') continue;
      return createHash('sha256').update(diff).digest('hex');
    } catch {
      /* try next ref */
    }
  }
  return null;
}

/**
 * An answer is stale when what the human reviewed changed.
 *
 * Prefers the review-diff binding and falls back to the HEAD sha when either side lacks one —
 * answers recorded before this binding existed, and worktrees where no base ref resolves, keep the
 * old (stricter) behaviour rather than silently becoming un-invalidatable.
 */
function readFreshAnswer(ctx, id) {
  const a = ctx.answers?.[id];
  if (!a || typeof a.value !== 'string' || !a.value.trim()) return { fresh: false, stale: false };
  if (a.review_diff_id && ctx.reviewDiffId) {
    return a.review_diff_id === ctx.reviewDiffId
      ? { fresh: true, stale: false, answer: a }
      : { fresh: false, stale: true, answer: a };
  }
  if (a.head_sha && ctx.headSha && a.head_sha !== ctx.headSha) {
    return { fresh: false, stale: true, answer: a };
  }
  return { fresh: true, stale: false, answer: a };
}

/**
 * Verdict for a large-scale branch that has no milestone deck trace.
 *
 * An accountable waiver must never cost more than saying nothing. A declared exemption used to
 * return BLOCKED while silence returned WARN, and the remedy read "or revert exemption line" — the
 * cheapest way past the gate was deleting the disclosure. "No deck exists"
 * also cannot refute an exemption *from producing a deck*: absence is the expected state under a
 * valid waiver, so the old test was circular. What is checkable is whether the waiver is accountable,
 * which `OBLIGATION_MIN_REASON_LENGTH` already defines. The measurement is quoted beside the claim so
 * a reviewer weighs the two together. A too-short reason is WARN like silence (with a remedy asking
 * for a real reason) — never more severe, unless the project opts into `block` (below).
 *
 * `shortReason: 'block'` (create-pr config `milestone_waiver_short_reason`) makes a too-short reason
 * BLOCKED. Silence stays WARN either way: the key tightens what an accountable waiver must carry, it
 * does not re-create the old gradient where deleting the disclosure was cheaper than keeping it —
 * a project choosing `block` accepts that trade explicitly.
 *
 * @param {{dropped?: boolean, reason?: string|null, reason_too_short?: boolean}|undefined} waiver
 * @param {{files:number, loc:number, base?:string}|null} scale
 * @param {{shortReason?: 'warn'|'block'}} [options]
 */
export function evaluateMilestoneWaiver(waiver, scale, { shortReason = 'warn' } = {}) {
  const measured = scale
    ? `measured ${scale.files} files / ${scale.loc} LOC vs ${scale.base ?? 'base'}`
    : 'scale unmeasured';
  if (!waiver?.dropped) {
    return {
      status: STEP_STATUS.WARN,
      evidence: `Proceeded without interim milestone deck, and without declaring why — ${measured}`,
      remedy: 'node .claude/scripts/review-deck.mjs --stage milestone (can be generated now)',
    };
  }
  if (waiver.reason_too_short) {
    // Same severity as silence — a thin reason is still more disclosure than none, so it must not
    // cost more. The message asks for a real reason instead.
    const why = waiver.reason ? `too short a reason ("${waiver.reason}")` : 'no reason';
    return {
      status: shortReason === 'block' ? STEP_STATUS.BLOCKED : STEP_STATUS.WARN,
      evidence: `Exemption declared with ${why} — ${measured}`,
      remedy:
        `State a real reason (at least ${OBLIGATION_MIN_REASON_LENGTH} characters) on the obligation line, ` +
        'or generate the deck: node .claude/scripts/review-deck.mjs --stage milestone',
    };
  }
  return {
    status: STEP_STATUS.WARN,
    evidence: `Interim milestone deck waived: "${waiver.reason}" — ${measured}`,
    remedy: null,
  };
}

/** Values of the create-pr config key `milestone_waiver_short_reason`; the first is the default. */
export const MILESTONE_WAIVER_SHORT_REASON_MODES = Object.freeze(['warn', 'block']);

/**
 * `milestone_waiver_short_reason` from the create-pr config. Only the exact lowercase values are
 * honoured; anything else reads as `warn` and carries a warning (a mistyped `"Block"` silently
 * meaning `warn` is exactly the kind of drift a gate setting must not hide).
 *
 * @returns {{mode: 'warn'|'block', warning: string|null}}
 */
export function readMilestoneWaiverShortReason(projectDir, io) {
  const raw = readCreatePrConfigKey(projectDir, 'milestone_waiver_short_reason', io);
  if (raw === undefined || MILESTONE_WAIVER_SHORT_REASON_MODES.includes(raw)) {
    return { mode: raw ?? 'warn', warning: null };
  }
  return {
    mode: 'warn',
    warning: `create-pr config milestone_waiver_short_reason ${JSON.stringify(raw)} is not "warn" or "block" — using "warn"`,
  };
}

/** Mode only (see readMilestoneWaiverShortReason). */
export function resolveMilestoneWaiverShortReason(projectDir, io) {
  return readMilestoneWaiverShortReason(projectDir, io).mode;
}

export const PRE_SHIP_STEPS = [
  machine('worktree-clean', 'No uncommitted changes in worktree', (ctx) => {
    const out = String(ctx.git(['status', '--porcelain', '--untracked-files=all'])).trim();
    if (!out) return { status: STEP_STATUS.OK, evidence: 'git status --porcelain -uall → clean' };
    const lines = out.split('\n');
    return {
      status: STEP_STATUS.BLOCKED,
      evidence: `${lines.length} uncommitted changes: ${lines.slice(0, 5).join(' | ')}`,
      remedy: 'Stage and commit your changes in the worktree (R-CM-034 Rule 6)',
    };
  }),

  machine('unmerged-commit', 'At least 1 unmerged commit exists', (ctx) => {
    const out = String(ctx.git(['log', '--oneline', `origin/${ctx.baseBranch}..HEAD`])).trim();
    const n = out ? out.split('\n').length : 0;
    return n > 0
      ? { status: STEP_STATUS.OK, evidence: `origin/${ctx.baseBranch}..HEAD → ${n} commits` }
      : {
          status: STEP_STATUS.BLOCKED,
          evidence: 'No commits to merge',
          remedy: 'No work to ship — commit your changes or clean up the worktree',
        };
  }),

  machine('plan-checklist', 'No unchecked items in PLAN.md checklist', (ctx) => {
    const planPath = resolveWorktreePlanPath(ctx.worktreeAbs, ctx.branch);
    if (!ctx.existsFn(planPath)) {
      return {
        status: STEP_STATUS.BLOCKED,
        evidence: `PLAN.md missing: ${planPath}`,
        remedy: 'Create PLAN.md first (R-CM-034 Rule 2)',
      };
    }
    const unchecked = parseUncheckedPlanItems(ctx.readFn(planPath, 'utf-8'));
    return unchecked.length === 0
      ? { status: STEP_STATUS.OK, evidence: '0 unchecked checkboxes' }
      : {
          status: STEP_STATUS.BLOCKED,
          evidence: `${unchecked.length} unchecked items: ${unchecked.slice(0, 3).map((s) => s.trim()).join(' | ')}`,
          remedy: 'Mark completed items with [x], or append (dropped: reason) to non-applicable items',
        };
  }),

  machine('quality-gate-proof', 'Quality Gate verdict proof is recorded for current HEAD', (ctx) => {
    const rec = ctx.readQualityFn(ctx.worktreeAbs, ctx.branch);
    if (!rec?.record) {
      const dropped = ctx.obligations?.get('quality-gate-proof');
      return {
        status: STEP_STATUS.BLOCKED,
        evidence: dropped?.dropped
          ? 'Exemption declared in PLAN but no PROOF record exists — declaration contradicts facts'
          : 'quality-gate.json missing or corrupted',
        remedy:
          'Execute Quality Gate and record proof: node .claude/scripts/record-quality-gate.mjs <branch> --json ...',
      };
    }
    const r = rec.record;
    if (r.verdict !== 'go') {
      return {
        status: STEP_STATUS.BLOCKED,
        evidence: `verdict=${r.verdict}`,
        remedy: 'Fix issues and re-record Quality Gate verdict (R-CM-030 Rule 9)',
      };
    }
    if (r.head_sha && ctx.headSha && r.head_sha !== ctx.headSha) {
      return {
        status: STEP_STATUS.BLOCKED,
        evidence: `stale — recorded at ${String(r.head_sha).slice(0, 8)} ≠ current HEAD ${String(ctx.headSha).slice(0, 8)}`,
        remedy: 'New commits added since recording. Re-run verification and record PROOF again',
      };
    }
    const gates = Array.isArray(r.gates) ? r.gates : [];
    return {
      status: STEP_STATUS.OK,
      evidence:
        `verdict=go, label=${r.quality_label ?? '(none)'}, gates=${gates.length}, head match` +
        `, ${formatCrossReviewEvidence(ctx.crossReview)}`,
    };
  }),

  machine('ship-deck', 'Visual review deck exists for large scale changes', (ctx) => {
    if (!isLargeScale(ctx)) {
      return { status: STEP_STATUS.NA, evidence: `Scale ${ctx.scale?.label ?? 'undetermined'} — Deck not required` };
    }
    const deck = checkShipDeckFreshness(
      ctx.projectDir,
      safeBranchKey(ctx.branch),
      ctx.worktreeAbs,
      ctx.gitFn,
      { existsFn: ctx.existsFn, statFn: ctx.statFn },
    );
    return deck.ok
      ? { status: STEP_STATUS.OK, evidence: `Deck fresh: ${deck.deckPath}` }
      : {
          status: STEP_STATUS.BLOCKED,
          evidence: deck.reason === 'deck_stale' ? 'New commits added after deck generation' : 'Deck missing',
          remedy: `node .claude/scripts/ship-deck.mjs --worktree ${ctx.worktreeAbs} --narrative-json <path>`,
        };
  }),

  machine('milestone-deck', 'Implementation interim check deck trace exists for large scale changes', (ctx) => {
    if (!isLargeScale(ctx)) {
      return { status: STEP_STATUS.NA, evidence: 'Not large scale — interim review not required' };
    }
    let trace = false;
    try {
      trace = hasMilestoneDeckTrace(ctx.projectDir, safeBranchKey(ctx.branch), {
        existsFn: ctx.existsFn,
        readdirFn: ctx.readdirFn,
      });
    } catch {
      return { status: STEP_STATUS.WARN, evidence: 'Trace query failed — unable to evaluate' };
    }
    if (trace) return { status: STEP_STATUS.OK, evidence: 'CP-MILESTONE deck trace found' };

    return evaluateMilestoneWaiver(ctx.obligations?.get('cp-milestone-deck'), ctx.scale, {
      shortReason: ctx.milestoneWaiverShortReason,
    });
  }),

  // DEFECT 2 visibility fix (contract-reconciliation-harness ADR M3): a 0-criteria acceptance
  // contract stays fail-open (deliberate ADR choice — never blocks) but must be impossible to miss
  // in the one place a human actually looks before approving. WARN (not BLOCKED) preserves that.
  machine('acceptance-contract', 'Executable acceptance contract recorded for this branch', (ctx) => {
    let contract = null;
    try {
      contract = ctx.readBranchContractFn?.(ctx.projectDir, ctx.branch) ?? null;
    } catch {
      contract = null;
    }
    const acceptance = Array.isArray(contract?.acceptance) ? contract.acceptance : [];
    if (acceptance.length === 0) {
      return {
        status: STEP_STATUS.WARN,
        evidence: 'acceptance: 0 criteria (branch-bound) / none recorded — definition of done not machine-checked (fail-open per ADR)',
        remedy: `node .claude/scripts/task-interpretation.mjs record --acceptance '[...]' --branch ${ctx.branch}`,
      };
    }
    return {
      status: STEP_STATUS.OK,
      evidence: `acceptance: ${acceptance.length} criteria (branch-bound), recorded_at=${contract.recorded_at ?? 'unknown'}`,
    };
  }),

  human(
    'approval',
    'Human has explicitly approved',
    // One human step, not two. A separate "have you reviewed the deck?" step accepted any
    // non-empty text, so it could not tell a review from a reply: on 2026-09-23 the human
    // answered it "다 진행해" ("just do it all") and it recorded "Human has directly reviewed
    // the changes" PASS — a false record that cost a round-trip. What the human needs to see
    // is named here instead; whether they looked is theirs to answer, not ours to log.
    (ctx) =>
      `${isLargeScale(ctx) ? 'After opening the review deck' : 'After reading the change summary (Pre-Ship Panel — not large scale, so no review deck)'}` +
      `, may we proceed with merge and cleanup? (${(ctx.approvalChoices ?? APPROVAL_CHOICES).join(' / ')})`,
    (ctx) => {
      const a = readFreshAnswer(ctx, 'approval');
      if (a.stale) {
        return {
          status: STEP_STATUS.AWAITING,
          evidence: "Approval invalidated — this branch's own changes moved since it was given",
          remedy: 'Obtain fresh approval for updated changes',
        };
      }
      // A recorded human answer always wins — including a reject of an auto-approvable ship.
      if (!a.fresh) {
        const auto = ctx.autoApproval;
        if (auto?.auto) return { status: STEP_STATUS.OK, evidence: `Auto-approved (R-CM-030 Rule 13.1): ${auto.why}` };
        return {
          status: STEP_STATUS.AWAITING,
          evidence: `No answer recorded — human approval required: ${auto?.why ?? 'risk tier undetermined'}`,
        };
      }
      const decision = normalizeApproval(a.answer.value, { choices: ctx.approvalChoices });
      if (decision === 'approve') {
        return { status: STEP_STATUS.OK, evidence: `User response: "${a.answer.value}"` };
      }
      return {
        status: STEP_STATUS.BLOCKED,
        evidence: `User response: "${a.answer.value}" → ${decision ?? 'uninterpretable'}`,
        remedy:
          decision === null
            ? `Please respond with one of: ${(ctx.approvalChoices ?? APPROVAL_CHOICES).join(' / ')}`
            : 'User requested not to proceed — ship aborted',
      };
    },
  ),
];

const HALTING = new Set([STEP_STATUS.BLOCKED, STEP_STATUS.AWAITING]);

function projectCrossReview(ctx, readLedgerFn, readLandingsFn) {
  try {
    return projectCrossReviewStreak({
      ledger: readLedgerFn(),
      landings: readLandingsFn(),
      // Read through `ctx.git`, which binds this module's `gitFn(cwd, args)` convention once.
      refMovedAge: readTrunkRefMovedAge(ctx.baseBranch, ctx.git),
      baseBranch: ctx.baseBranch ?? null,
      scale: ctx.scale?.scale ?? null,
      qualityLabel: ctx.readQualityFn(ctx.worktreeAbs, ctx.branch)?.record?.quality_label ?? null,
    });
  } catch {
    return null;
  }
}

/** Test-injectable value, or the real resolver when nothing was injected. */
const injected = (value, resolve) => (value !== undefined ? value : resolve());

/**
 * Project-configured knobs the steps read: create-pr `milestone_waiver_short_reason` and the review
 * panel's `approval_choices`. Each is resolved only when not injected.
 */
function projectSettings(projectDir, { milestoneWaiverShortReason, approvalChoices } = {}) {
  const warnings = [];
  const waiver = injected(milestoneWaiverShortReason, () => {
    const r = readMilestoneWaiverShortReason(projectDir);
    if (r.warning) warnings.push(r.warning);
    return r.mode;
  });
  const choices = injected(approvalChoices, () => {
    const panel = loadReviewPanelConfig(projectDir);
    if (panel.warning) warnings.push(panel.warning);
    return panel.approvalChoices;
  });
  return { milestoneWaiverShortReason: waiver, approvalChoices: choices, settingsWarnings: warnings };
}

/** Scale is advisory — an unmeasurable worktree must not fail the whole evaluation. */
function measureScaleSafely(worktreeAbs, gitFn) {
  try {
    return measureShipScale(worktreeAbs, gitFn);
  } catch {
    return null;
  }
}

/**
 * PROOF's label, only when its `gates[]` carry the evidence the label claims. Without this, `next`
 * run standalone (no `--quality`) previewed "Auto-approved" on a label the marker would later refuse.
 */
export function evidencedProofLabel(record) {
  const label = record?.quality_label ?? null;
  return label && checkLabelEvidence(label, record.gates).satisfied ? label : null;
}

/**
 * Risk tier + review label + escape history → may the `approval` step pass without a human?
 * Any failure answers "no": the pre-policy behaviour (ask the human) is the safe fallback.
 */
export function defaultAutoApproval(ctx, { readLedgerFn = readLedger, qualityLabel } = {}) {
  try {
    const { policy, error } = loadApprovalPolicy(ctx.projectDir);
    const reachMap = loadReachMap(ctx.projectDir);
    const risk = measureDiffRisk(ctx.worktreeAbs, { policy, policyError: error, reachMap, gitFn: ctx.gitFn });
    const label = qualityLabel ?? evidencedProofLabel(ctx.readQualityFn(ctx.worktreeAbs, ctx.branch)?.record);
    let trust;
    try {
      trust = policy ? loadTrust({ projectDir: ctx.projectDir, baseBranch: ctx.baseBranch, ledger: readLedgerFn(), policy, runGit: ctx.git }) : { error };
    } catch (e) {
      trust = { error: e?.message ?? String(e) };
    }
    return { ...assessAutoApproval({ risk, qualityLabel: label, policy, trust }), risk };
  } catch (e) {
    return { auto: false, tier: 'T2', why: `auto-approval check failed: ${e?.message ?? e}`, demotions: [] };
  }
}

function readObligationDecisions(worktreeAbs, branch, existsFn, readFn) {
  try {
    const planPath = resolveWorktreePlanPath(worktreeAbs, branch);
    if (!existsFn(planPath)) return new Map();
    return parseObligationDecisions(readFn(planPath, 'utf-8'));
  } catch {
    return new Map();
  }
}

/**
 * Fills in `evaluateSteps`' test-injectable defaults (git/fs accessors, ledger/quality readers). Kept
 * separate from `evaluateSteps` itself — each default expression is its own decision point for the
 * complexity linter, and this is where they belong: one place resolving "what runs when nothing was injected".
 */
function withStepDefaults(opts) {
  // `undefined` only, as the destructuring defaults this replaced: an injected `null` stays `null`.
  const or = (v, fallback) => (v === undefined ? fallback() : v);
  return {
    ...opts,
    baseBranch: or(opts.baseBranch, () => resolveShipBaseBranch(opts.projectDir)),
    gitFn: or(opts.gitFn, () => defaultGit),
    existsFn: or(opts.existsFn, () => existsSync),
    readFn: or(opts.readFn, () => readFileSync),
    readQualityFn: or(opts.readQualityFn, () => readQualityGateRecord),
    readLedgerFn: or(opts.readLedgerFn, () => readLedger),
    readBranchContractFn: or(opts.readBranchContractFn, () => readBranchTaskContract),
  };
}

export function evaluateSteps(opts) {
  const {
    worktreeAbs,
    branch,
    projectDir,
    baseBranch,
    gitFn,
    existsFn,
    readFn,
    readdirFn,
    statFn,
    readQualityFn,
    readLedgerFn,
    readBranchContractFn,
    landings,
    // Test-injectable project settings; omitted keys come from the project config (see projectSettings).
    settings,
    answers,
    headSha,
    reviewDiffId,
    // Injected verdict for tests; `qualityLabel` lets the marker CLI pass its verified --quality
    // before it is backfilled into PROOF (one value, whichever channel carried it).
    autoApproval,
    qualityLabel,
  } = withStepDefaults(opts);

  const ctx = buildStepContext({
    worktreeAbs,
    branch,
    projectDir,
    baseBranch,
    gitFn,
    existsFn,
    readFn,
    readdirFn,
    statFn,
    readQualityFn,
    readLedgerFn,
    readBranchContractFn,
    landings,
    settings,
    answers,
    headSha,
    reviewDiffId,
    autoApproval,
    qualityLabel,
  });

  const steps = computeStepResults(ctx);
  const next = steps.find((s) => HALTING.has(s.status)) ?? null;
  return {
    steps,
    next,
    ready: next === null,
    headSha: ctx.headSha,
    reviewDiffId: ctx.reviewDiffId,
    scale: ctx.scale,
    crossReview: ctx.crossReview,
    autoApproval: ctx.autoApproval,
    approvalChoices: ctx.approvalChoices,
    settingsWarnings: ctx.settingsWarnings,
  };
}

/** Assembles the shared evaluation context (git/fs accessors, scale, cross-review, auto-approval) once per call. */
function buildStepContext({
  worktreeAbs,
  branch,
  projectDir,
  baseBranch,
  gitFn,
  existsFn,
  readFn,
  readdirFn,
  statFn,
  readQualityFn,
  readLedgerFn,
  readBranchContractFn,
  landings,
  settings,
  answers,
  headSha,
  reviewDiffId,
  autoApproval,
  qualityLabel,
}) {
  const resolvedHead = injected(headSha, () => resolveHeadSha(worktreeAbs));
  const resolvedDiffId = injected(reviewDiffId, () => resolveReviewDiffId(worktreeAbs, baseBranch, gitFn));
  const store = injected(answers, () => readAnswerStore(answerStorePath(worktreeAbs, branch), { existsFn, readFn }));
  const ctx = {
    worktreeAbs,
    branch,
    projectDir,
    baseBranch,
    gitFn,
    git: (args) => gitFn(worktreeAbs, args),
    existsFn,
    readFn,
    readdirFn,
    statFn,
    readQualityFn,
    readBranchContractFn,
    answers: store,
    headSha: resolvedHead,
    reviewDiffId: resolvedDiffId,
    scale: null,
    crossReview: null,
    autoApproval: null,
    obligations: readObligationDecisions(worktreeAbs, branch, existsFn, readFn),
    ...projectSettings(projectDir, settings),
  };
  ctx.scale = measureScaleSafely(worktreeAbs, gitFn);
  // The worktree shares the main clone's object store, so `origin/<base>` is whatever the last fetch
  // left — no fetch here (this runs inside hooks). A stale ref can omit recent bypasses, never invent one.
  ctx.crossReview = projectCrossReview(ctx, readLedgerFn, () =>
    injected(landings, () => readTrunkLandings(baseBranch, ctx.git)),
  );
  ctx.autoApproval = injected(autoApproval, () => defaultAutoApproval(ctx, { readLedgerFn, qualityLabel }));
  return ctx;
}

/** Evaluates every step definition against the context, catching per-step evaluation failures as BLOCKED. */
function computeStepResults(ctx) {
  return PRE_SHIP_STEPS.map((def, index) => {
    let result;
    try {
      result = def.evaluate(ctx);
    } catch (e) {
      result = { status: STEP_STATUS.BLOCKED, evidence: `Evaluation failed: ${e?.message ?? e}` };
    }
    return {
      index: index + 1,
      total: PRE_SHIP_STEPS.length,
      id: def.id,
      title: def.title,
      kind: def.kind,
      question: resolveQuestion(def, ctx),
      status: result.status,
      evidence: result.evidence ?? '',
      remedy: result.remedy ?? null,
    };
  });
}

/**
 * Records human answer — allowed ONLY for the currently pending step.
 *
 * @returns {{ok: boolean, error?: string, path?: string, store?: object}}
 */
export function recordAnswer({
  worktreeAbs,
  branch,
  stepId,
  value,
  evaluation,
  nowIso = new Date().toISOString(),
  writeFn = writeJsonAtomicSync,
  ...evalOpts
}) {
  const def = PRE_SHIP_STEPS.find((s) => s.id === stepId);
  if (!def) return { ok: false, error: `Unknown step: ${stepId}` };
  if (def.kind !== 'human') return { ok: false, error: `Cannot answer machine step: ${stepId}` };
  if (typeof value !== 'string' || !value.trim()) return { ok: false, error: 'Answer is empty' };

  const state = evaluation ?? evaluateSteps({ worktreeAbs, branch, ...evalOpts });
  if (!state.next) return { ok: false, error: 'No steps remaining (all steps passed)' };
  if (state.next.id !== stepId) {
    return {
      ok: false,
      error: `Sequence violation — currently awaiting step ${state.next.index} "${state.next.id}" (requested: ${stepId})`,
    };
  }

  // An answer stored with head_sha: null can never be invalidated — `evaluateSteps` only compares
  // when both sides are present (see the `a.head_sha && ctx.headSha` guards). So recording one while
  // HEAD lookup was timing out would make a human approval permanently valid across any number of
  // later commits, which is exactly what R-CM-030 Rule 13's binding exists to prevent. Refuse
  // instead; the human's words are not lost, they are simply re-asked once the machine responds.
  if (!state.headSha) {
    return {
      ok: false,
      error:
        'Cannot bind this answer to a HEAD sha (git HEAD lookup returned nothing). An unbound ' +
        'answer would survive every later commit. Retry once the machine is less loaded.',
    };
  }

  const path = answerStorePath(worktreeAbs, branch);
  const store = readAnswerStore(path);

  // A revise/abort leaves this step pending, so without this an "approve" could be written over the
  // human's veto of the very same diff. Only a clear veto blocks: an answer the parser could not read
  // is re-asked by design, and a new diff (after the requested revision) is answered afresh. The
  // binding is compared the way staleness is: review_diff_id, else head_sha.
  const prior = store[stepId];
  const veto = stepId === 'approval' && prior?.value
    ? normalizeApproval(prior.value, { choices: state.approvalChoices ?? APPROVAL_CHOICES })
    : null;
  const sameDiff = prior?.review_diff_id && state.reviewDiffId
    ? prior.review_diff_id === state.reviewDiffId
    : prior?.head_sha === state.headSha;
  if ((veto === 'revise' || veto === 'abort') && sameDiff) {
    return {
      ok: false,
      error:
        `The human answered "${prior.value}" (${veto}) for this diff; an answer cannot overwrite that veto. ` +
        'Change the diff as asked, then ask again.',
    };
  }
  // head_sha is kept for audit and as the fallback binding when no base ref resolves; review_diff_id
  // is what actually decides staleness (see resolveReviewDiffId).
  store[stepId] = {
    value: value.trim(),
    head_sha: state.headSha,
    ...(state.reviewDiffId ? { review_diff_id: state.reviewDiffId } : {}),
    at: nowIso,
  };
  writeFn(path, store);
  return { ok: true, path, store };
}
