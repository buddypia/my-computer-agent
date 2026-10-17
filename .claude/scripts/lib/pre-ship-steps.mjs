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
import { defaultGit, measureShipScale } from '../../../.cli/lib/ship-scale.mjs';
import { resolveWorktreePlanPath } from '../../../.cli/lib/worktree-plan-path.mjs';
import { parseUncheckedPlanItems } from '../../../.cli/lib/worktree-plan-status.mjs';
import { resolveShipBaseBranch } from '../../../.cli/lib/ship-base-branch.mjs';
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
import { APPROVAL_CHOICES, normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';
import { loadReviewPanelConfig } from '../../../.cli/lib/worktree-ship-report.mjs';

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

  human(
    'approval',
    'Human or Trust evaluator has approved',
    (ctx) =>
      `After reading the change summary (Pre-Ship Panel), may we proceed with merge and cleanup? (${(ctx.approvalChoices ?? APPROVAL_CHOICES).join(' / ')})`,
    (ctx) => {
      const a = readFreshAnswer(ctx, 'approval');
      if (a.stale) {
        return {
          status: STEP_STATUS.AWAITING,
          evidence: "Approval invalidated — this branch's own changes moved since it was given",
          remedy: 'Obtain fresh approval for updated changes',
        };
      }
      if (!a.fresh) {
        const auto = ctx.autoApproval;
        if (auto?.auto) return { status: STEP_STATUS.OK, evidence: `Auto-approved: ${auto.why}` };
        return {
          status: STEP_STATUS.AWAITING,
          evidence: 'No answer recorded — run `node Scripts/trust/trust.mjs approve --worktree <wt> --review <json> --ci` or record human approval',
        };
      }
      const decision = normalizeApproval(a.answer.value, { choices: ctx.approvalChoices });
      if (decision === 'approve') {
        const evidence =
          a.answer.source === 'trust'
            ? `Auto-approved (trust.mjs): ${(a.answer.reasons ?? []).join(', ') || 'eligible'}`
            : `User response: "${a.answer.value}"`;
        return { status: STEP_STATUS.OK, evidence };
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
      refMovedAge: readTrunkRefMovedAge(ctx.baseBranch, ctx.git),
      baseBranch: ctx.baseBranch ?? null,
      scale: ctx.scale?.scale ?? null,
      qualityLabel: ctx.readQualityFn(ctx.worktreeAbs, ctx.branch)?.record?.quality_label ?? null,
    });
  } catch {
    return null;
  }
}

const injected = (value, resolve) => (value !== undefined ? value : resolve());

function projectSettings(projectDir, { approvalChoices } = {}) {
  const warnings = [];
  const choices = injected(approvalChoices, () => {
    const panel = loadReviewPanelConfig(projectDir);
    if (panel.warning) warnings.push(panel.warning);
    return panel.approvalChoices;
  });
  return { approvalChoices: choices, settingsWarnings: warnings };
}

function measureScaleSafely(worktreeAbs, gitFn) {
  try {
    return measureShipScale(worktreeAbs, gitFn);
  } catch {
    return null;
  }
}

function withStepDefaults(opts) {
  const or = (v, fallback) => (v === undefined ? fallback() : v);
  return {
    ...opts,
    baseBranch: or(opts.baseBranch, () => resolveShipBaseBranch(opts.projectDir)),
    gitFn: or(opts.gitFn, () => defaultGit),
    existsFn: or(opts.existsFn, () => existsSync),
    readFn: or(opts.readFn, () => readFileSync),
    readQualityFn: or(opts.readQualityFn, () => readQualityGateRecord),
    readLedgerFn: or(opts.readLedgerFn, () => readLedger),
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
    landings,
    settings,
    answers,
    headSha,
    reviewDiffId,
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
    ...projectSettings(projectDir, settings),
  };
  ctx.scale = measureScaleSafely(worktreeAbs, gitFn);
  // The worktree shares the main clone's object store, so `origin/<base>` is whatever the last fetch
  // left — no fetch here (this runs inside hooks). A stale ref can omit recent bypasses, never invent one.
  ctx.crossReview = projectCrossReview(ctx, readLedgerFn, () =>
    injected(landings, () => readTrunkLandings(baseBranch, ctx.git)),
  );
  ctx.autoApproval = autoApproval ?? null;
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
