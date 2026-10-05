/**
 * ship-scale.mjs — Shared library for measuring worktree diff scale + checking review deck traces (CLI-agnostic)
 *
 * Why (preventing drift): Measuring scale (git numstat → classifyScale) and checking review deck traces are shared
 * between pre-ship-review-guard (large-scale deck gate at ship time) and milestone-deck-warning (proactive commit-time reminder).
 * Reimplementing individually causes criteria to drift silently (isomorphic to eventOrder scoping flaw in PR #1010).
 * Scale classification SSOT is ship-deck-core.mjs#classifyScale — this lib is the measurement/trace inspection layer above it.
 *
 * Transparent note: create-pr/ops.mjs#detectMissingReviewDeckWarning (retroactive ship-time warning, DEBT-223)
 * retains its inline implementation (single origin/<base> ref + inline numstat parsing) — migration is a follow-up PR (Surgical).
 *
 * .cli→.claude import precedents: pre-ship-review-guard (ship-deck-core), ownership-context-injector.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { classifyScale, parseNumstat } from '../../.claude/scripts/lib/ship-deck-core.mjs';
import { resolveShipBaseRefs } from './ship-base-branch.mjs';
import { withoutInheritedRepository } from './utils.mjs';

/** Default git runner — stubbed via gitFn in tests (R-CM-011 external command isolation) */
export function defaultGit(cwd, args) {
  // stderr ignore: prevents fail-open git error text from leaking into hook stderr
  return execFileSync('git', ['-C', cwd, ...args], {
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'ignore'],
    // An inherited GIT_DIR would override `-C` and measure another repository's diff.
    env: withoutInheritedRepository(),
  });
}

/**
 * Measures the worktree's `<base>...HEAD` diff scale.
 *
 * Base refs come from `.cli/lib/ship-base-branch.mjs#resolveShipBaseRefs` (the configured ship base
 * first, `origin/main` / `main` as fallbacks) — the local `['origin/main', 'main']` this used to
 * carry inflated the scale on projects shipping onto another branch. `base` is returned alongside the
 * numbers so a measurement can never be quoted without the ref it was taken against.
 *
 * @param {string} worktreeAbsPath
 * @param {Function} [gitFn]
 * @param {{existsFn?: Function, readFn?: Function}} [io] Test-injectable config I/O.
 * @returns {{files:number, loc:number, base:string, scale:string, label:string, reason:string}|null}
 *   null = unevaluable via git (fail-open — caller SKIPs inspection, R-CM-006 Rule 2)
 */
export function measureShipScale(worktreeAbsPath, gitFn = defaultGit, io = undefined) {
  for (const base of resolveShipBaseRefs(worktreeAbsPath, { gitFn, ...io })) {
    try {
      const numstat = gitFn(worktreeAbsPath, ['diff', `${base}...HEAD`, '--numstat']);
      const rows = parseNumstat(String(numstat)); // Reuses ship-deck-core parser (binary → null, rename normalization)
      const files = rows.length;
      const loc = rows.reduce((sum, r) => sum + (r.added ?? 0) + (r.deleted ?? 0), 0);
      return { files, loc, base, ...classifyScale({ files, loc }) };
    } catch {
      // Unevaluable for this base ref — try next candidate
    }
  }
  return null;
}

/**
 * Checks for presence of CP-MILESTONE review deck traces (.tmp/review-deck/<safeKey>/milestone-<slug>/index.html).
 * Path structure SSOT: review-deck.mjs output convention.
 * @returns {boolean} true if 1+ traces exist
 * @throws Re-throws fs errors — caller responsible for fail-open handling (SKIP warning/reminder).
 *         Swallowing as false flips fail-open direction to "fs error → no traces → fire warning".
 */
export function hasMilestoneDeckTrace(
  projectDir,
  safeKey,
  { existsFn = existsSync, readdirFn = readdirSync } = {},
) {
  const deckRoot = join(projectDir, '.tmp', 'review-deck', safeKey);
  return (
    existsFn(deckRoot) &&
    readdirFn(deckRoot).some(
      (d) => String(d).startsWith('milestone-') && existsFn(join(deckRoot, d, 'index.html')),
    )
  );
}

/** Path to ship deck index.html (.tmp/ship-deck/<safeKey>/index.html) — unified path assembly */
export function shipDeckIndexPath(projectDir, safeKey) {
  return join(projectDir, '.tmp', 'ship-deck', safeKey, 'index.html');
}

/** Tolerance for future committer timestamps (seconds) — handles clock skew / rebase future dates. */
export const FUTURE_SKEW_TOLERANCE_SEC = 300;

/**
 * Validates presence + freshness of ship deck artifact (deck mtime >= worktree HEAD commit timestamp).
 * Isomorphic in spirit to quality-gate PROOF head_sha staleness — stale if new commits accumulate after deck creation.
 *
 * **Shared SSOT between two consumers**: `pre-ship-review-guard` (ship-time deny) and
 * `pre-ship-steps.mjs` (pre-approval dry run). Independent implementations create round-trip discrepancies
 * where pre-check passes but ship denies.
 *
 * Committer timestamps in the future create unrecoverable deny loops where regenerating decks remains stale;
 * treated as unevaluable (fail-open).
 *
 * @returns {{ok:boolean, reason?:'deck_absent'|'deck_stale', deckPath:string}}
 */
export function checkShipDeckFreshness(
  projectDir,
  safeKey,
  worktreeAbsPath,
  gitFn = defaultGit,
  { existsFn = existsSync, statFn = statSync, nowMs = () => Date.now() } = {},
) {
  const deckPath = shipDeckIndexPath(projectDir, safeKey);
  if (!existsFn(deckPath)) return { ok: false, reason: 'deck_absent', deckPath };
  try {
    const headTimeSec = Number(String(gitFn(worktreeAbsPath, ['log', '-1', '--format=%ct'])).trim());
    const deckMtimeSec = statFn(deckPath).mtimeMs / 1000;
    const headInFuture = headTimeSec > nowMs() / 1000 + FUTURE_SKEW_TOLERANCE_SEC;
    if (Number.isFinite(headTimeSec) && !headInFuture && deckMtimeSec < headTimeSec) {
      return { ok: false, reason: 'deck_stale', deckPath };
    }
    return { ok: true, deckPath };
  } catch {
    return { ok: true, deckPath }; // Freshness unevaluable — pass on existence alone (fail-open)
  }
}

// ─── Edit-time Scale Accumulation (DEBT-248) ─────────────────────────────────────────────
//
// Why counting session tool activity rather than git measurement: Changes *during* implementation
// are mostly uncommitted, and untracked new files do not appear in `git diff` (`git add -N` is a repo
// mutation hooks must avoid). In contrast, tool invocation payloads can be counted instantly with 0 git spawns.
//
// Transparent limitations (why this is an advisory trigger rather than a gate):
//   - Repeated edits to the same file accumulate as churn, resulting in counts **larger** than git net diff →
//     fires earlier than reality. Safe since this is a 1-time non-blocking notification.
//   - Full file overwrites (Write) do not know previous contents, resulting in counts **smaller** than reality.
//   - Bulk changes generated by scripts bypass tools and remain invisible → commit-time path
//     (measureShipScale, git measurement) continues to cover this. Both paths are complementary.
// Thresholds share SCALE_THRESHOLDS SSOT — measurement *source* differs while standards remain aligned.

/**
 * Estimates LOC change from tool payload.
 *   Matches git definition of `loc = added + deleted` — changing N lines to M lines counts as N deleted + M added,
 *   so Edit counts `old_string` line count + `new_string` line count aligned with git.
 * @param {string} toolName Write | Edit | MultiEdit
 * @param {object} toolInput Tool input from hook stdin
 * @returns {number} Estimated LOC (0 if unevaluable)
 */
export function estimateEditLoc(toolName, toolInput) {
  const lines = (s) => (typeof s === 'string' && s !== '' ? s.split('\n').length : 0);
  if (toolName === 'Write') return lines(toolInput?.content);
  if (toolName === 'Edit') return lines(toolInput?.old_string) + lines(toolInput?.new_string);
  if (toolName === 'MultiEdit') {
    const edits = Array.isArray(toolInput?.edits) ? toolInput.edits : [];
    return edits.reduce((sum, e) => sum + lines(e?.old_string) + lines(e?.new_string), 0);
  }
  return 0;
}

/**
 * Merges 1 edit into the ledger (pure — caller handles read/write).
 *   `files` is deduplicated path array (file count axis), `loc` is cumulative sum (churn axis).
 * @param {object|null} prev Previous ledger (treated as null on absence/corruption)
 * @param {{file: string, loc: number}} entry
 * @returns {{files: string[], loc: number}}
 */
export function mergeEditLedger(prev, { file, loc }) {
  const prevFiles = Array.isArray(prev?.files) ? prev.files.filter((f) => typeof f === 'string') : [];
  const prevLoc = Number.isFinite(prev?.loc) && prev.loc > 0 ? prev.loc : 0;
  const files = prevFiles.includes(file) || !file ? prevFiles : [...prevFiles, file];
  return { files, loc: prevLoc + (Number.isFinite(loc) && loc > 0 ? loc : 0) };
}

/** Ledger → scale classification (shares classifyScale SSOT). */
export function classifyEditLedgerScale(ledger) {
  const files = Array.isArray(ledger?.files) ? ledger.files.length : 0;
  const loc = Number.isFinite(ledger?.loc) ? ledger.loc : 0;
  return { files, loc, ...classifyScale({ files, loc }) };
}
