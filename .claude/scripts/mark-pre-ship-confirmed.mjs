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
  checkTrivialClaim,
  formatReviewRemedy,
} from '../../.cli/lib/quality-gate-labels.mjs';
import { measureShipScale } from '../../.cli/lib/ship-scale.mjs';
import { parseUncheckedPlanItems } from '../../.cli/lib/worktree-plan-status.mjs';
import { evaluateSteps, resolveReviewDiffId } from './lib/pre-ship-steps.mjs';
import { resolveShipBaseBranch } from '../../.cli/lib/ship-base-branch.mjs';

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
      // A CLI, not a hook: nothing waits on it, and 3s timed out under load (load average ~100,
      // 2026-10-21), which read as "not a git repo".
      timeout: 30_000,
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
export function buildMarkerPayload(mainRoot, branch, quality, _acceptance = null, approval = null) {
  const wtDir = resolveWorktreeDir(mainRoot, branch);
  return {
    quality_gate: quality,
    confirmed_at: new Date().toISOString(),
    review_diff_id: wtDir ? resolveReviewDiffId(wtDir, resolveShipBaseBranch(mainRoot)) : null,
    approval_mode: approval?.mode ?? 'human',
    risk_tier: approval?.tier ?? null,
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
  // `forced`, not the 'human' default: a skipped check must not read as a human approval in the ledger.
  if (force) return { ok: true, skipped: 'force', approval: { mode: 'forced', tier: null } };
  // !branch, not === 'staged': resolveBranch('--staged') returns *null*, so the string comparison
  // never matched and resolveWorktreeDir(mainRoot, null) crashed with a TypeError — the Mode A
  // (--staged) marker path was undeliverable without --force (empirical reproduction 2026-08-26).
  // Mirrors the !branch skip in checkPlanCheckboxes.
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
        '  Auto-merge additionally requires a review.json the trust evaluator accepts.\n',
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

  const path = markerPath(mainRoot, branch);
  const payload = JSON.stringify(buildMarkerPayload(mainRoot, branch, quality, null, steps.approval));
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
