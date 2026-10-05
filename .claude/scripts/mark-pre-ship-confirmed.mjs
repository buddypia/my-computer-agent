#!/usr/bin/env node

/**
 * mark-pre-ship-confirmed.mjs — Pre-Ship Review Panel confirmation marker creation CLI
 *
 * Why (R-CM-029 Rule 3.1 Proposal-stage obligation):
 *   (a) Threat: When pre-ship-review-guard deny message presents absolute path substring
 *       `mkdir -p /abs/main/.tmp && touch /abs/main/.tmp/pre-ship-review-confirmed-<key>`,
 *       AI operating in worktree cwd risks (1) path truncation or (2) unintentional relative
 *       path shortening, creating marker in wrong `.tmp/` (worktree-local), leading to
 *       recurrent deny loop.
 *   (b) Previous gap: Deny message only provided cwd-agnostic absolute path substring without safety net.
 *   (c) Simpler alternative: Single-line CLI guarantees identical result regardless of invocation cwd.
 *
 * Usage:
 *   node .claude/scripts/mark-pre-ship-confirmed.mjs <branch-or-worktree-path>
 *   node /abs/path/.claude/scripts/mark-pre-ship-confirmed.mjs feature/foo
 *   node /abs/path/.claude/scripts/mark-pre-ship-confirmed.mjs .worktrees/fix__bar
 *   node /abs/path/.claude/scripts/mark-pre-ship-confirmed.mjs --staged    # ship-feature mode
 *
 * Behavior:
 *   - Automatically resolves main project root as parent of `git rev-parse --git-common-dir`.
 *   - Creates marker `<main>/.tmp/pre-ship-review-confirmed-<safeBranchKey>` (mkdir -p + touch).
 *   - safeBranchKey / inferBranchFromWorktreePath via worktree-plan-path.mjs SSOT.
 *   - Outputs resulting path to stdout.
 *
 * Exit codes:
 *   0 — Marker creation succeeded
 *   1 — Missing arguments / git common-dir resolve failure / mkdir/touch failure
 *
 * Boundary (R-CM-028): Perspective 1 (harness repo itself) only.
 */

import { execSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  inferBranchFromWorktreePath,
  preShipMarkerPath,
  resolveWorktreePlanPath,
  safeBranchKey,
} from '../../.cli/lib/worktree-plan-path.mjs';
import {
  TRIVIAL_SKIP_LIMITS,
  VALID_QUALITY_LABELS,
  checkLabelEvidence,
  checkTrivialClaim,
  formatReviewRemedy,
} from '../../.cli/lib/quality-gate-labels.mjs';
import { measureShipScale } from '../../.cli/lib/ship-scale.mjs';
import { parseUncheckedPlanItems } from '../../.cli/lib/worktree-plan-status.mjs';
import {
  readQualityGateRecord,
  checkQualityGateStaleness,
  persistQualityLabel,
} from './lib/worktree-quality-gate.mjs';
import { evaluateSteps, resolveReviewDiffId } from './lib/pre-ship-steps.mjs';
import { resolveShipBaseBranch } from '../../.cli/lib/ship-base-branch.mjs';
import { readCurrentTaskPassport, resolveAcceptanceContract } from './lib/task-passport.mjs';
import { evaluateAcceptance, formatAcceptanceReport } from './lib/task-acceptance.mjs';

/**
 * Resolves main project root as parent of git common-dir.
 *
 * @param {string} cwd
 * @returns {string|null} Absolute path or null
 */
export function resolveMainRoot(cwd = process.cwd()) {
  try {
    const out = execSync('git rev-parse --git-common-dir', {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000,
    }).trim();
    if (!out) return null;
    const abs = resolve(cwd, out);
    if (abs === cwd) return cwd;
    return dirname(abs);
  } catch {
    return null;
  }
}

/**
 * Extracts branch name from argument (worktree path, branch name, or --staged).
 *
 * @param {string} arg
 * @returns {string|null}
 */
export function resolveBranch(arg) {
  if (!arg) return null;
  if (arg === '--staged' || arg === 'staged') return null;
  if (arg.includes('.worktrees/') || arg.includes('.worktrees\\')) {
    return inferBranchFromWorktreePath(arg);
  }
  return arg;
}

/**
 * Resolves existing worktree absolute directory from branch name.
 *
 * @param {string} mainRoot
 * @param {string} branch
 * @returns {string|null}
 */
export function resolveWorktreeDir(mainRoot, branch) {
  const candidates = [
    join(mainRoot, '.worktrees', branch),
    join(mainRoot, '.worktrees', safeBranchKey(branch)),
  ];
  return candidates.find((c) => existsSync(c)) || null;
}

/**
 * Computes marker file path — SSOT: worktree-plan-path.mjs#preShipMarkerPath.
 */
export const markerPath = preShipMarkerPath;

/**
 * Validates and normalizes --quality argument.
 *
 * @param {string|null|undefined} raw
 * @returns {string|null} Valid label or null
 */
export function parseQualityLabel(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  return VALID_QUALITY_LABELS.has(trimmed) ? trimmed : null;
}

/**
 * Creates marker file (mkdir -p + write/touch).
 *
 * @param {string} path
 * @param {string} content
 */
/**
 * Marker contents.
 *
 * `review_diff_id` stamps what the human approved so ship can re-check it after its own base merge.
 * Without it the approval was verified once, here, and never again — and ship then merges
 * `origin/<base>`, whose conflict resolution can rewrite the branch's own files. Reader:
 * `ops.mjs#assertApprovalFreshAfterBaseMerge`. Null when no base ref resolves (fail-open, matching
 * the fallback in `pre-ship-steps`).
 *
 * The base comes from `resolveShipBaseBranch` — the same config `ops.mjs` reads — because the reader
 * compares against *its* base. This was hardcoded `'main'`, so on a project shipping onto another
 * branch the stamp and the comparison measured different diffs and every ship reported a stale
 * approval that was not stale. See `.cli/lib/ship-base-branch.mjs`.
 */
export function buildMarkerPayload(mainRoot, branch, quality, acceptance = null, approval = null) {
  const wtDir = resolveWorktreeDir(mainRoot, branch);
  return {
    quality_gate: quality,
    confirmed_at: new Date().toISOString(),
    review_diff_id: wtDir ? resolveReviewDiffId(wtDir, resolveShipBaseBranch(mainRoot)) : null,
    // DEFECT 2 visibility: a 0-criteria (or never-recorded) acceptance contract is fail-open by
    // design (ADR contract-reconciliation-harness) — but that must not mean invisible. Persisting
    // the status here means a human re-opening the marker later can see "acceptance: 0 criteria"
    // without re-deriving it from stderr, which is the panel's only other surface for it.
    acceptance_status: summarizeAcceptanceStatus(acceptance),
    // Read by ops.mjs into the ledger row, where approval-trust.mjs finds auto-approved ships.
    approval_mode: approval?.mode ?? 'human',
    risk_tier: approval?.tier ?? null,
  };
}

/** Reduces a checkAcceptance() result to the small shape recorded on the marker (DEFECT 2). */
function summarizeAcceptanceStatus(acceptance) {
  if (!acceptance) return { recorded: false, criteria_count: 0, skipped: 'not_evaluated' };
  const criteriaCount = acceptance.report?.total ?? 0;
  return {
    recorded: criteriaCount > 0,
    criteria_count: criteriaCount,
    ok: acceptance.ok,
    skipped: acceptance.skipped ?? null,
    source: acceptance.source ?? null,
    recorded_at: acceptance.recordedAt ?? null,
  };
}

export function createMarker(path, content = '') {
  mkdirSync(dirname(path), { recursive: true });
  if (content === '' && existsSync(path)) {
    const now = new Date();
    utimesSync(path, now, now);
  } else {
    writeFileSync(path, content);
  }
}

/**
 * Pre-checks PLAN.md for incomplete checkboxes.
 *
 * @param {string} mainRoot
 * @param {string|null} branch
 * @param {boolean} force
 * @returns {{ok: boolean, skipped?: string, unchecked?: string[], planPath?: string}}
 */
export function checkPlanCheckboxes(mainRoot, branch, force) {
  if (!branch) return { ok: true, skipped: 'staged_mode' };
  if (force) return { ok: true, skipped: 'force_flag' };

  const wtPath = resolveWorktreeDir(mainRoot, branch);
  if (!wtPath) return { ok: true, skipped: 'worktree_absent' };

  const planPath = resolveWorktreePlanPath(wtPath);
  if (!existsSync(planPath)) return { ok: true, skipped: 'plan_absent' };

  let content;
  try {
    content = readFileSync(planPath, 'utf-8');
  } catch {
    return { ok: true, skipped: 'plan_unreadable' };
  }
  const unchecked = parseUncheckedPlanItems(content);
  if (unchecked.length === 0) return { ok: true };
  return { ok: false, unchecked, planPath };
}

/**
 * Re-runs the task contract's executable acceptance[] (R-CM-038 Rule 6 / R-CM-010) against the
 * worktree before the marker is created. This is the only place the AI's own definition of done is
 * machine-checked after the work — the Stop-time guard it replaces could only see "a verification
 * command ran". Fail-open when there is no applicable contract or no acceptance recorded (the
 * contract is optional); fail-closed when a recorded criterion fails. Freshness is advisory only —
 * every new prompt rotates the objective sha, so requiring it would make the check dead at ship time.
 *
 * DEFECT 1 root-cause fix: the contract is resolved **by branch** via `resolveAcceptanceContract`
 * (durable branch-keyed store first, session passport only as a fallback that must itself declare
 * the same branch) — never by blindly trusting whichever session happens to be calling this. A
 * contract recorded for a different branch (or a passport that never declared this branch) can no
 * longer satisfy this gate; see `task-passport.mjs#resolveAcceptanceContract` for the precedence.
 *
 * @param {string} mainRoot
 * @param {string|null} branch
 * @param {boolean} force
 * @param {{readPassport?: (root: string) => object|null, exec?: (command: string, cwd: string) => void}} [deps]
 * @returns {{ok: boolean, skipped?: string, stale?: boolean, report?: object, root?: string, source?: string, recordedAt?: string|null}}
 */
export function checkAcceptance(mainRoot, branch, force, deps = {}) {
  if (!branch) return { ok: true, skipped: 'staged_mode' };
  if (force) return { ok: true, skipped: 'force_flag' };
  const { interp, source, passport } = resolveAcceptanceContract(mainRoot, branch, {
    readPassport: deps.readPassport ?? readCurrentTaskPassport,
  });
  if (!interp) {
    // No contract applies to THIS branch — either nothing was ever recorded (no_passport), or a
    // passport/contract exists but belongs to a different branch, which must be indistinguishable
    // from "nothing recorded for this branch" (no_acceptance) so it cannot silently satisfy the gate.
    return { ok: true, skipped: passport === null ? 'no_passport' : 'no_acceptance' };
  }
  const acceptance = Array.isArray(interp.acceptance) ? interp.acceptance : [];
  if (acceptance.length === 0) return { ok: true, skipped: 'no_acceptance' };
  const root = resolveWorktreeDir(mainRoot, branch);
  if (!root || !existsSync(root)) return { ok: true, skipped: 'worktree_absent' };
  // Staleness diffs against "current active objective" — meaningful only for a session passport
  // (there is a live session to compare against); a durable branch contract has no such reference
  // point, so recorded_at is surfaced instead (see summarizeAcceptanceStatus / buildMarkerPayload).
  const stale = source === 'session_passport'
    ? interp.objective_sha256 !== passport?.active_objective?.sha256
    : false;
  const report = evaluateAcceptance(acceptance, { root, exec: deps.exec });
  return { ok: report.ok, stale, report, root, source, recordedAt: interp.recorded_at ?? null };
}

/**
 * Checks mailbox quality-gate.json PROOF verdict.
 *
 * @param {string} mainRoot
 * @param {string|null} branch
 * @param {boolean} force
 * @param {string|null} [cliLabel]
 * @param {(worktreePath: string) => string} [execFn] — Test-injectable HEAD resolver
 * @returns {{ok: boolean, skipped?: string, reason?: string, verdict?: string, proofLabel?: string, evidenceMarkers?: string[], proofPath?: string, warning?: string, recordedSha?: string, currentSha?: string, stalenessChecked?: boolean, stalenessSkipped?: 'head_sha_absent'|'head_sha_unresolvable'}}
 */
/**
 * Staleness-related denial reasons (stale HEAD, or an unresolved timeout on the staleness check).
 * @returns {object|null} a denial result, or null if staleness does not block the marker.
 */
function checkQualityGateStalenessVerdict(record, path, staleness) {
  if (staleness.checked && staleness.stale) {
    return {
      ok: false,
      reason: 'stale',
      verdict: record.verdict,
      proofPath: path,
      recordedSha: staleness.recordedSha,
      currentSha: staleness.currentSha,
    };
  }
  // Previously a stderr warning that still issued the marker. A timeout means the tree may have
  // moved while we were unable to look, and the ship-side check shares this same resolver — so
  // warning here left both defences down at once. R-CM-008 Rule 6 already settled the direction
  // for this exact shape: unresolved → deny, never passthrough.
  if (staleness.unresolved === 'timeout') {
    return {
      ok: false,
      reason: 'staleness_unresolved',
      verdict: record.verdict,
      proofPath: path,
      recordedSha: staleness.recordedSha,
    };
  }
  return null;
}

/**
 * Label-related denial reasons (CLI/PROOF label mismatch, or a claimed label lacking gates[] evidence).
 * @returns {object|null} a denial result, or null if the label checks out.
 */
function checkQualityGateLabelVerdict(record, path, cliLabel) {
  if (record.quality_label && cliLabel && record.quality_label !== cliLabel) {
    return {
      ok: false,
      reason: 'label_mismatch',
      verdict: record.verdict,
      proofLabel: record.quality_label,
      proofPath: path,
    };
  }
  const claimedLabel = record.quality_label || cliLabel;
  const evidence = checkLabelEvidence(claimedLabel, record.gates);
  if (evidence.required && !evidence.satisfied) {
    return {
      ok: false,
      reason: 'label_evidence_missing',
      verdict: record.verdict,
      proofLabel: claimedLabel,
      evidenceMarkers: evidence.markers,
      proofPath: path,
    };
  }
  return null;
}

export function checkQualityGateVerdict(
  mainRoot,
  branch,
  force,
  cliLabel = null,
  execFn = undefined,
) {
  if (!branch) return { ok: true, skipped: 'staged_mode' };
  if (force) return { ok: true, skipped: 'force_flag' };

  const wtPath = resolveWorktreeDir(mainRoot, branch);
  if (!wtPath) return { ok: true, skipped: 'worktree_absent' };

  const { record, path, error } = readQualityGateRecord(wtPath, branch);
  if (error) return { ok: true, skipped: 'proof_invalid', warning: `${path} — ${error}` };
  if (!record) return { ok: true, skipped: 'proof_absent' };
  if (record.verdict === 'no_go') {
    return { ok: false, reason: 'no_go', verdict: record.verdict, proofPath: path };
  }
  const staleness = execFn
    ? checkQualityGateStaleness(record, wtPath, execFn)
    : checkQualityGateStaleness(record, wtPath);

  const stalenessVerdict = checkQualityGateStalenessVerdict(record, path, staleness);
  if (stalenessVerdict) return stalenessVerdict;

  const labelVerdict = checkQualityGateLabelVerdict(record, path, cliLabel);
  if (labelVerdict) return labelVerdict;

  const stalenessSkipped = staleness.checked
    ? null
    : staleness.recordedSha
      ? 'head_sha_unresolvable'
      : 'head_sha_absent';
  return {
    ok: true,
    verdict: record.verdict,
    proofPath: path,
    stalenessChecked: staleness.checked,
    ...(stalenessSkipped ? { stalenessSkipped } : {}),
  };
}

/**
 * Checks a `trivial_skip` claim against the measured `<base>...HEAD` diff.
 *
 * The label is a size claim (R-CM-030 Rule 10), so it is measured rather than trusted — unlike the
 * review labels, whose evidence is a record. Fail-open when there is no worktree or git cannot
 * measure (R-CM-006 Rule 2); `--force` bypasses like every other check here.
 *
 * @param {(worktreeAbs: string) => ({files: number, loc: number}|null)} [measureFn]
 * @returns {{ok: boolean, skipped?: string, files?: number, loc?: number}}
 */
export function checkTrivialScale(mainRoot, branch, quality, force, measureFn = measureShipScale) {
  if (quality !== 'trivial_skip') return { ok: true, skipped: 'not_trivial' };
  if (!branch) return { ok: true, skipped: 'staged_mode' };
  if (force) return { ok: true, skipped: 'force_flag' };
  const wtPath = resolveWorktreeDir(mainRoot, branch);
  if (!wtPath) return { ok: true, skipped: 'worktree_absent' };
  const measured = measureFn(wtPath);
  if (!measured) return { ok: true, skipped: 'unmeasurable' };
  return checkTrivialClaim(quality, measured);
}

/**
 * Backfills confirmed quality label to PROOF.
 *
 * @returns {string|null} Warning string for stderr (null if none)
 */
export function backfillProofLabel(mainRoot, branch, quality, force) {
  if (!branch || force) return null;
  const wtPath = resolveWorktreeDir(mainRoot, branch);
  if (!wtPath) return null;
  const persist = persistQualityLabel(wtPath, quality, branch);
  if (persist.persisted || persist.reason === 'already_set') return null;
  return (
    `[mark-pre-ship-confirmed] Warning: PROOF label recording skipped (${persist.reason}) — ` +
    `ship ledger will record this ship as 'review skipped'. PROOF: ${persist.path}\n`
  );
}

/**
 * Verifies that all pre-ship steps are completed.
 *
 * @returns {{ok: boolean, skipped?: string, next?: object, warning?: string}}
 */
/**
 * Turns a ready `evaluateSteps` state into the approval-mode result: a fresh human answer wins over
 * auto-approval in the step itself, so the step's own verdict (not `autoApproval.auto`) says who approved.
 */
function resolveApprovalMode(state) {
  const step = state.steps.find((s) => s.id === 'approval');
  const auto = /^Auto-approved/.test(step?.evidence ?? '');
  return { ok: true, approval: { mode: auto ? 'auto' : 'human', tier: state.autoApproval?.tier ?? null } };
}

export function checkPreShipSteps(mainRoot, branch, force, quality = undefined, evaluateFn = evaluateSteps) {
  if (force) return { ok: true, skipped: 'force' };
  // !branch, not === 'staged': resolveBranch('--staged') returns *null*, so the string comparison
  // never matched and resolveWorktreeDir(mainRoot, null) crashed with a TypeError — the Mode A
  // (--staged) marker path was undeliverable without --force (empirical reproduction 2026-08-26).
  // Mirrors the !branch skip in checkPlanCheckboxes / checkQualityGateVerdict.
  if (!branch) return { ok: true, skipped: 'staged_mode' };
  const worktreeAbs = resolveWorktreeDir(mainRoot, branch);
  if (!worktreeAbs || !existsSync(worktreeAbs)) return { ok: true, skipped: 'no_worktree' };
  try {
    // Same base as buildMarkerPayload stamps and as ops.mjs compares — the review_diff_id binding
    // depends on all three being one measurement.
    const state = evaluateFn({
      worktreeAbs,
      branch,
      projectDir: mainRoot,
      baseBranch: resolveShipBaseBranch(mainRoot),
      qualityLabel: quality,
    });
    if (!state.ready) return { ok: false, next: state.next };
    return resolveApprovalMode(state);
  } catch (e) {
    return { ok: true, warning: `Step evaluation failed: ${e?.message ?? e}` };
  }
}

export function validateUnknownFlags(args) {
  const KNOWN_FLAGS = new Set(['--force', '--quality', '--staged']);
  const qualityIdx = args.indexOf('--quality');
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (typeof a !== 'string' || !a.startsWith('--')) continue;
    if (qualityIdx >= 0 && i === qualityIdx + 1) continue;
    if (!KNOWN_FLAGS.has(a)) return a;
  }
  return null;
}

/**
 * Converts checkQualityGateVerdict failure reason into human-readable message.
 *
 * @param {ReturnType<typeof checkQualityGateVerdict>} gate
 * @param {string} quality
 * @returns {string}
 */
function describeGateFailure(gate, quality) {
  if (gate.reason === 'label_evidence_missing') {
    return (
      `PROOF gates[] lacks execution evidence for ${gate.proofLabel} (required markers: ${gate.evidenceMarkers?.join(' | ') ?? '?'}).\n` +
      `  ${gate.proofLabel} asserts secondary review was executed, resetting skip counter on ship-quality-ledger — declarations alone are insufficient.\n` +
      `  Resolution A: Run ${formatReviewRemedy()} and record it in gates[]\n` +
      `               (e.g. {"name":"adversarial-review (subagent)","status":"pass","detail":"..."}).\n` +
      `               Markers above are wider than that list on purpose — they also accept tools this repo\n` +
      `               does not ship (e.g. /code-review), which count if you have them but cannot be advised.\n` +
      `  Resolution B: If not run, downgrade to --quality self_review_pass and document reason in Panel Decisions.\n`
    );
  }
  if (gate.reason === 'label_mismatch') {
    return (
      `PROOF quality_label=${gate.proofLabel} ≠ --quality ${quality} — preventing label inflation.\n` +
      `  Resolution: Match --quality to PROOF label, or re-record PROOF with record-quality-gate.mjs if verification level increased.\n`
    );
  }
  if (gate.reason === 'stale') {
    return (
      `PROOF is stale (recorded HEAD ${gate.recordedSha?.slice(0, 7) ?? '?'} ≠ current HEAD ${gate.currentSha?.slice(0, 7) ?? '?'}) — new commits occurred after recording so verdict does not cover current code.\n` +
      `  Procedure: Re-run verdict → re-record via node .claude/scripts/record-quality-gate.mjs → retry this CLI.\n`
    );
  }
  if (gate.reason === 'staleness_unresolved') {
    return (
      `PROOF records HEAD ${gate.recordedSha?.slice(0, 7) ?? '?'} but git HEAD lookup kept timing out, so staleness could not be evaluated.\n` +
      `  This is a machine-load symptom, not a defect in the change: the ship-side check uses the same resolver, so proceeding would leave both defences down at once.\n` +
      `  Procedure: wait for load to drop (uptime), then retry this CLI. No re-recording needed.\n`
    );
  }
  return (
    `verdict=no_go.\n` +
    `  Procedure: Fix findings → re-run verdict → re-record via node .claude/scripts/record-quality-gate.mjs → retry this CLI.\n`
  );
}

/** Splits argv into the flags this CLI knows and its single positional target. */
function parseCliArgs(args) {
  const qualityIdx = args.indexOf('--quality');
  const positional = args.filter(
    (a, i) =>
      a !== '--force' &&
      a !== '--quality' &&
      (qualityIdx < 0 || (i !== qualityIdx && i !== qualityIdx + 1)),
  );
  return {
    force: args.includes('--force'),
    qualityRaw: qualityIdx >= 0 ? args[qualityIdx + 1] : null,
    arg: positional[0],
  };
}

/** Writes the task-acceptance outcome to stderr. Returns false when the marker must be rejected. */
function reportAcceptance(acceptance) {
  if (acceptance.skipped === 'no_acceptance' || acceptance.skipped === 'no_passport') {
    process.stderr.write(
      `[mark-pre-ship-confirmed] Note: no executable acceptance[] bound to this branch (${acceptance.skipped}) — ` +
        'definition of done not machine-checked (fail-open, per ADR). ' +
        'Next time: task-interpretation.mjs record --acceptance --branch <this-branch>. ' +
        'See pre-ship-steps for the same status surfaced in the Panel.\n',
    );
  }
  if (acceptance.ok) return true;
  process.stderr.write(
    `[mark-pre-ship-confirmed] Marker creation rejected — task acceptance ${acceptance.report.failed}/${acceptance.report.total} failed` +
      `${acceptance.stale ? ' (interpretation STALE — objective changed since recording; re-record if the task changed)' : ''}:\n` +
      `${formatAcceptanceReport(acceptance.report)}\n` +
      `  Root: ${acceptance.root}\n` +
      '  Fix the work or re-record the contract: node .claude/scripts/task-interpretation.mjs record --acceptance ...\n' +
      '  Explicit user bypass: --force (mandatory reason in Panel Decisions section).\n',
  );
  return false;
}

/** Fail-open conditions of the PROOF check that deserve a line on stderr but never reject. */
function reportGateWarnings(gate) {
  if (gate.warning) {
    process.stderr.write(
      `[mark-pre-ship-confirmed] Warning: quality-gate.json invalid — proceeding fail-open (${gate.warning})\n`,
    );
  }
  if (gate.stalenessSkipped === 'head_sha_unresolvable') {
    process.stderr.write(
      `[mark-pre-ship-confirmed] Warning: PROOF has head_sha but worktree HEAD query failed — ` +
        `skipped staleness check (fail-open). Check git status.\n`,
    );
  }
}

function main(argv) {
  const args = argv.slice(2);

  const unknown = validateUnknownFlags(args);
  if (unknown) {
    process.stderr.write(
      `[mark-pre-ship-confirmed] unknown flag: ${unknown}\n` +
        '  known flags: --force / --quality <label> / --staged\n' +
        '  Usage: node mark-pre-ship-confirmed.mjs <branch | worktree-path | --staged> --quality <label> [--force]\n',
    );
    process.exit(1);
  }

  const { force, qualityRaw, arg } = parseCliArgs(args);

  if (!arg) {
    process.stderr.write(
      'Usage: node mark-pre-ship-confirmed.mjs <branch | worktree-path | --staged> --quality <label> [--force]\n',
    );
    process.exit(1);
  }

  const quality = parseQualityLabel(qualityRaw);
  if (!quality) {
    process.stderr.write(
      '[mark-pre-ship-confirmed] --quality <label> is required.\n' +
        '  Labels:\n' +
        '    agent_go          : code-reviewer agent gives Go\n' +
        '    skill_review_pass : Independent secondary review via a review skill (no agent) gives Go\n' +
        '    self_review_pass  : Pure self-inspection with no secondary review tools (reason must be specified in Panel Decisions)\n' +
        '    trivial_skip      : R-CM-030 Rule 10 trivial exemption (≤2 files + ≤20 LOC + non-substantive)\n' +
        '\n' +
        `  To earn one of the first two, run: ${formatReviewRemedy()}\n` +
        '  Both require execution evidence in PROOF gates[] before marker creation.\n',
    );
    process.exit(1);
  }

  const mainRoot = resolveMainRoot();
  if (!mainRoot) {
    process.stderr.write(
      '[mark-pre-ship-confirmed] git common-dir resolve failed (not a git repo?)\n',
    );
    process.exit(1);
  }
  const branch = resolveBranch(arg);

  const check = checkPlanCheckboxes(mainRoot, branch, force);
  if (!check.ok) {
    process.stderr.write(
      `[mark-pre-ship-confirmed] PLAN.md incomplete checkboxes ${check.unchecked.length} item(s):\n` +
        check.unchecked.map((l) => `  ${l}`).join('\n') +
        `\n\nBypass: --force flag or add (cancelled) / (dropped) / (deferred) / ~~strikethrough~~ marker to item.\n` +
        `PLAN: ${check.planPath}\n`,
    );
    process.exit(1);
  }

  const trivial = checkTrivialScale(mainRoot, branch, quality, force);
  if (!trivial.ok) {
    process.stderr.write(
      `[mark-pre-ship-confirmed] Marker creation rejected — trivial_skip claims ≤${TRIVIAL_SKIP_LIMITS.files} files ` +
        `and ≤${TRIVIAL_SKIP_LIMITS.loc} LOC, but the diff is ${trivial.files} files / ${trivial.loc} LOC.\n` +
        `  Use the label that matches what happened: run ${formatReviewRemedy()},\n` +
        '  or declare --quality self_review_pass with the reason in Panel Decisions.\n' +
        '  A script that passes --quality trivial_skip unconditionally is the observed cause — fix it there.\n' +
        '  Explicit user bypass: --force (mandatory reason in Panel Decisions section).\n',
    );
    process.exit(1);
  }

  const acceptance = checkAcceptance(mainRoot, branch, force);
  if (!reportAcceptance(acceptance)) process.exit(1);

  const gate = checkQualityGateVerdict(mainRoot, branch, force, quality);
  reportGateWarnings(gate);
  if (!gate.ok) {
    process.stderr.write(
      `[mark-pre-ship-confirmed] Pre-Ship Quality Gate marker creation rejected (R-CM-030 Rule 9): ${describeGateFailure(gate, quality)}` +
        `  PROOF: ${gate.proofPath}\n` +
        `  Explicit user bypass: --force (mandatory reason in Panel Decisions section).\n`,
    );
    process.exit(1);
  }

  const steps = checkPreShipSteps(mainRoot, branch, force, quality);
  if (steps.warning) {
    process.stderr.write(`[mark-pre-ship-confirmed] Warning: ${steps.warning} — proceeding fail-open\n`);
  }
  if (!steps.ok) {
    const n = steps.next;
    process.stderr.write(
      '[mark-pre-ship-confirmed] Marker creation rejected — Pre-Ship step checks incomplete.\n' +
        `  Remaining step [${n.index}/${n.total}] ${n.title} (${n.status})\n` +
        `  Evidence: ${n.evidence}\n` +
        (n.remedy ? `  Remedy: ${n.remedy}\n` : '') +
        `  Proceed: node .claude/scripts/pre-ship-steps.mjs next --worktree .worktrees/${branch}\n` +
        '  Explicit user bypass: --force (mandatory reason in Panel Decisions section).\n',
    );
    process.exit(1);
  }

  const backfillWarning = backfillProofLabel(mainRoot, branch, quality, force);
  if (backfillWarning) process.stderr.write(backfillWarning);

  const path = markerPath(mainRoot, branch);
  const payload = JSON.stringify(buildMarkerPayload(mainRoot, branch, quality, acceptance, steps.approval));
  try {
    createMarker(path, payload);
  } catch (e) {
    process.stderr.write(`[mark-pre-ship-confirmed] Marker creation failed: ${e.message}\n`);
    process.exit(1);
  }
  process.stdout.write(`${path}\n`);
}

/**
 * Checks whether this module was executed directly via CLI.
 *
 * @param {string} moduleUrl — import.meta.url
 * @param {string|undefined} argv1 — process.argv[1]
 * @returns {boolean}
 */
export function isMainModule(moduleUrl, argv1) {
  if (!argv1) return false;
  return moduleUrl === pathToFileURL(argv1).href;
}

if (isMainModule(import.meta.url, process.argv[1])) {
  main(process.argv);
}
