/**
 * worktree-quality-gate.mjs — Pre-Ship Quality Gate PROOF record contract SSOT
 * (teamwork-preview transplant Phase 2, R-CM-030 Rule 8/9. head_sha/staleness is Phase 3).
 *
 * Why: If the PROOF (command / actual result / finding / verdict) of a Quality Gate verdict (Go/No-Go)
 * exists only in chat, auditability is lost after session termination and No-Go enforcement relies solely
 * on prompt-level discipline. This module provides schema validation and fail-open reading for
 * mailbox `quality-gate.json` (`worktree-plan-path.mjs#resolveWorktreeQualityGatePath`) as a single shared contract.
 *
 * Publishers: `.claude/scripts/record-quality-gate.mjs` (validation + atomic write + head_sha stamp)
 *             `.claude/scripts/mark-pre-ship-confirmed.mjs` (`persistQualityLabel` — missing labels only)
 * Consumers:  `.claude/scripts/mark-pre-ship-confirmed.mjs` (verdict=no_go / rejects stale marker)
 *             `.claude/scripts/create-pr/ops.mjs#assertQualityGateNotNoGo` (re-verification at ship time)
 *             `.claude/scripts/create-pr/ops.mjs#collectShipQualitySnapshot` (ledger label — sole read path)
 *
 * Record format (PROOF — command / actual result / finding / verdict):
 *   {
 *     "branch": "feature/x",            // Stamped by publishing CLI
 *     "recorded_at": "ISO8601",         // Stamped by publishing CLI
 *     "head_sha": "abc123...",          // Stamped by publishing CLI (optional — omitted if git lookup fails)
 *     "verdict": "go" | "no_go",        // Required
 *     "quality_label": "agent_go",      // Optional — populated via marker CLI's --quality if omitted
 *     "gates": [                         // Required, 1+ items
 *       {
 *         "name": "code-review --fix",  // Required — Gate/tool name
 *         "status": "pass|warn|fail|skip", // Required — Matches ship-deck signal enum
 *         "command": "npx vitest run ...", // Optional — Executed command (PROOF command)
 *         "detail": "31 passed",           // Optional — Actual result (PROOF actual result)
 *         "finding": "LOW 1 item fixed"    // Optional — Findings (PROOF finding)
 *       }
 *     ]
 *   }
 *
 * Staleness (Phase 3): `head_sha` is the worktree HEAD sha at record time. If new commits are added
 * after recording, verdict=go no longer verifies the current codebase. `checkQualityGateStaleness()`
 * evaluates this via opt-in-by-presence.
 *
 * Boundary (R-CM-028): Perspective 1 (harness itself) only.
 * Regression tests: `tests/unit/worktree-quality-gate.test.mjs`.
 */

import { existsSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { resolveWorktreeQualityGatePath } from '../../../.cli/lib/worktree-plan-path.mjs';
import { VALID_QUALITY_LABELS } from '../../../.cli/lib/quality-gate-labels.mjs';
import { writeJsonAtomicSync } from './atomic-fs.mjs';

/** Final verdict enum — Machine representation for R-CM-030 Rule 9 (No-Go enforcement) */
export const VALID_VERDICTS = new Set(['go', 'no_go']);

/**
 * Gate status enum — Single source of truth for recording (record-quality-gate.mjs)
 * and inspection (mark-pre-ship-confirmed / ops.mjs no_go / stale blocking).
 */
export const GATE_STATUSES = new Set(['pass', 'warn', 'fail', 'skip']);

/**
 * Legal PROOF keys. Every optional key here is a key a typo can silently delete, because an
 * unrecognised key is simply not read by anyone: `quality_label` mistyped as `label` passed
 * validation and downgraded the ship's review label to "skipped" (observed on #1250), and a live
 * worktree still carries a `reviewer` key nothing has ever read.
 *
 * `branch` / `recorded_at` / `head_sha` are stamped by the publishing CLI, so they are legal on the
 * record even though a caller never supplies them.
 */
export const RECORD_KEYS = new Set([
  'branch',
  'recorded_at',
  'head_sha',
  'verdict',
  'quality_label',
  'gates',
]);

/** Legal `gates[i]` keys. `command` / `detail` / `finding` carry the PROOF body itself. */
export const GATE_ENTRY_KEYS = new Set(['name', 'status', 'command', 'detail', 'finding']);

function isNonEmptyString(v) {
  return typeof v === 'string' && v.trim() !== '';
}

/**
 * Returns 0 or 1 error naming every key outside `allowed`. Array-returning rather than
 * boolean-returning so callers spread it in a single statement — the extra branch at each call site
 * is what pushed `validateQualityGateRecord` past the CC ratchet.
 */
function unknownKeyErrors(obj, allowed, label) {
  const unknown = Object.keys(obj).filter((k) => !allowed.has(k));
  if (unknown.length === 0) return [];
  return [
    `${label} has unknown key(s): ${unknown.join(', ')} — allowed: ${[...allowed].join(' | ')}. ` +
      'Nothing reads an unknown key, so the value meant to be recorded would be lost',
  ];
}

/** Validates a single gate entry in gates[i] — dedicated helper for validateQualityGateRecord */
function validateGateEntry(gate, i, rejectUnknownKeys) {
  if (!gate || typeof gate !== 'object' || Array.isArray(gate)) {
    return [`gates[${i}] must be an object`];
  }
  const errors = [];
  if (!isNonEmptyString(gate.name)) {
    errors.push(`gates[${i}].name is required (non-empty string)`);
  }
  if (!GATE_STATUSES.has(gate.status)) {
    errors.push(`gates[${i}].status must be one of ${[...GATE_STATUSES].join(' | ')} (got: ${JSON.stringify(gate.status)})`);
  }
  for (const key of ['command', 'detail', 'finding']) {
    if (gate[key] !== undefined && typeof gate[key] !== 'string') {
      errors.push(`gates[${i}].${key} must be a string`);
    }
  }
  if (rejectUnknownKeys) {
    errors.push(...unknownKeyErrors(gate, GATE_ENTRY_KEYS, `gates[${i}]`));
  }
  return errors;
}

/**
 * The record's scalar fields — required `verdict`, author-supplied `quality_label`, CLI-stamped
 * `head_sha` — grouped the way the record reads: scalars first, then the `gates[]` body. Keeping
 * them out of `validateQualityGateRecord` is also what holds that function under the A3 CC ratchet.
 */
function validateScalarFields(record) {
  const errors = [];
  if (!VALID_VERDICTS.has(record.verdict)) {
    errors.push(`verdict is required — must be one of ${[...VALID_VERDICTS].join(' | ')} (got: ${JSON.stringify(record.verdict)})`);
  }
  if (record.quality_label !== undefined && !VALID_QUALITY_LABELS.has(record.quality_label)) {
    errors.push(`quality_label must be one of ${[...VALID_QUALITY_LABELS].join(' | ')} (got: ${JSON.stringify(record.quality_label)})`);
  }
  if (record.head_sha !== undefined && !isNonEmptyString(record.head_sha)) {
    errors.push('head_sha must be a non-empty string when set (used for staleness detection)');
  }
  return errors;
}

/**
 * Validates PROOF record schema. Pure — no fs access.
 *
 * Contradiction check: verdict='go' but gates contain status='fail' is a violation —
 * if fail was judged non-blocking, it must be recorded as 'warn' (prevents false metric reporting).
 *
 * `rejectUnknownKeys` is **opt-in, and only the write path opts in.** Turning it on for readers
 * would invert the very gate it is meant to protect: both consumers treat a schema-invalid record
 * as no record at all (`ops.mjs#assertQualityGateNotNoGo` `if (!record) return`,
 * `mark-pre-ship-confirmed.mjs#checkQualityGateVerdict` `skipped: 'proof_invalid'`), so a
 * `{verdict:'no_go', typo:1}` record would flip from *blocks the ship* to *passes silently*. The
 * live `reviewer` key on `fix/li1-silent-noop` is exactly such a record. `recordQualityGate` is the
 * only producer, so catching the typo where it is written loses nothing.
 *
 * @param {unknown} record
 * @param {{ rejectUnknownKeys?: boolean }} [options]
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateQualityGateRecord(record, { rejectUnknownKeys = false } = {}) {
  const errors = [];
  if (!record || typeof record !== 'object' || Array.isArray(record)) {
    return { ok: false, errors: ['record must be a JSON object'] };
  }
  if (rejectUnknownKeys) {
    errors.push(...unknownKeyErrors(record, RECORD_KEYS, 'record'));
  }
  errors.push(...validateScalarFields(record));
  if (!Array.isArray(record.gates) || record.gates.length === 0) {
    errors.push('gates is required — array with 1+ items (verdicts without PROOF have no recording value)');
  } else {
    record.gates.forEach((gate, i) => errors.push(...validateGateEntry(gate, i, rejectUnknownKeys)));
    if (record.verdict === 'go' && record.gates.some((g) => g && g.status === 'fail')) {
      errors.push("verdict='go' but gates contain status='fail' — contradiction. Record as 'warn' if non-blocking");
    }
  }
  return { ok: errors.length === 0, errors };
}

/**
 * Fail-open reader for mailbox quality-gate.json.
 *
 * - Missing file → { record: null, path, error: null } (opt-in-by-presence)
 * - Parse/schema error → { record: null, path, error: <reason> }
 * - Normal → { record, path, error: null }
 *
 * @param {string} worktreePath — Worktree absolute path
 * @param {string|null} [branch]
 * @returns {{ record: object|null, path: string, error: string|null }}
 */
export function readQualityGateRecord(worktreePath, branch = null) {
  const path = resolveWorktreeQualityGatePath(worktreePath, branch);
  if (!existsSync(path)) return { record: null, path, error: null };
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, 'utf-8'));
  } catch (e) {
    return { record: null, path, error: `JSON parse failed: ${e.message}` };
  }
  const { ok, errors } = validateQualityGateRecord(parsed);
  if (!ok) return { record: null, path, error: `Schema violation: ${errors.join(' / ')}` };
  return { record: parsed, path, error: null };
}

// Raised 3s → 10s on 2026-09-01. The retry below was meant to absorb load flake, and 3x3s did not:
// under `ci-local-status` parallelism the whole budget expired and both consumers *acted on it* —
// `checkQualityGateStaleness` reported `unresolved: 'timeout'` and `recordQualityGate` refused to
// write the PROOF at all ("Re-run once the machine is less loaded"), on a machine that was merely
// busy. That surfaced as two retry-passed tests in `worktree-quality-gate.test.mjs` and blocked
// push via the R-CM-041 strict flaky audit. Waiting longer is the correct response for a read that
// cannot fail slowly for any reason other than scheduling delay; no judgement threshold moves with
// this number (R-CM-041 Rule 5/6). Worst case is 30s, reached only when the box is saturated —
// exactly the case where refusing early is the wrong answer.
const HEAD_SHA_TIMEOUT_MS = 10_000;

// `git rev-parse HEAD` is a pure file read — no network, no lock, no worktree scan. An expired
// timeout therefore means "not answered yet", never "answered: nothing there". Retrying is the
// correct response; the expired timeout itself supplies the backoff, so no artificial sleep.
const HEAD_SHA_ATTEMPTS = 3;

/**
 * Default implementation to resolve current git HEAD sha — injectable for tests.
 *
 * **Must throw on failure; must never fold a failure into `null`.** `resolveHeadShaResult`
 * discriminates *not answered yet* from *answered: nothing there* solely by the thrown error's
 * `code`. Routing this through the `safeGit` / `safeExec` family therefore disables the retry **and**
 * all four refusal sites downstream — silently, with the whole suite still green, because at the
 * `resolveHeadShaResult` boundary both cases collapse to the same `{sha: null, timedOut: false}`.
 * Measured 2026-08-26: `safeExec('sleep 5', { timeout: 60 })` returns `null`, indistinguishable from
 * an uninitialised directory (`.cli/lib/utils.mjs#safeExec` catches every error).
 *
 * Such a swap was proposed on `fix/li1-silent-noop` for a legitimate reason — this 3s budget is
 * invisible to the shared exec-timeout floor, so the "real git repo" test above retry-passed under
 * load. The retry in `resolveHeadShaResult` absorbs that flake without giving up the discrimination,
 * so the budget stays local and raw. `tests/unit/worktree-quality-gate.test.mjs` pins both halves of
 * this contract; that is the only place the regression is observable.
 *
 * Exported for that pinning only — **not a production call path.** Calling this directly skips the
 * retry and hands back a raw throw, which is precisely the discrimination the callers below exist to
 * perform. Anything that gates on the answer goes through `resolveHeadShaResult`.
 *
 * @param {string} worktreePath
 * @param {number} [timeoutMs] — Overridable so the timeout half of the contract is testable at all
 */
export function defaultResolveHeadSha(worktreePath, timeoutMs = HEAD_SHA_TIMEOUT_MS) {
  return execSync('git rev-parse HEAD', {
    cwd: worktreePath,
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'ignore'],
    timeout: timeoutMs,
  }).trim();
}

/** Node marks a killed-by-timeout child with `code: 'ETIMEDOUT'`; real exits carry a numeric status. */
function isTimeoutError(error) {
  return error?.code === 'ETIMEDOUT';
}

/**
 * Resolves current git HEAD sha, retrying only on timeout.
 *
 * `timedOut` exists because collapsing a timeout into the same `null` as a genuine failure turns
 * *could not determine* into *determined to be fine*. Every consumer of this PROOF binding shared
 * that single hole: `record-quality-gate` wrote records with no `head_sha` (permanently
 * unverifiable), `mark-pre-ship-confirmed` warned and issued the marker anyway, and `ops.mjs`
 * passed without even a warning — so the marker and ship defences failed together under load
 * (observed 2026-08-26 at load average 102).
 *
 * Non-timeout failures are *not* retried: an uninitialised git directory will not appear by waiting.
 * That case keeps its fail-open `null` (legitimately undeterminable, R-CM-006 Rule 2).
 *
 * @param {string} worktreePath
 * @param {(worktreePath: string) => string} [execFn] — Test-injectable
 * @returns {{ sha: string|null, timedOut: boolean }}
 */
export function resolveHeadShaResult(worktreePath, execFn = defaultResolveHeadSha) {
  let timedOut = false;
  for (let attempt = 1; attempt <= HEAD_SHA_ATTEMPTS; attempt++) {
    try {
      const sha = execFn(worktreePath);
      return { sha: isNonEmptyString(sha) ? sha.trim() : null, timedOut };
    } catch (e) {
      if (!isTimeoutError(e)) return { sha: null, timedOut };
      timedOut = true;
    }
  }
  return { sha: null, timedOut: true };
}

/**
 * Resolves current git HEAD sha for worktree. Fail-open: returns null on failure
 * (git uninitialized / unavailable). Thin accessor over `resolveHeadShaResult` for callers that
 * only need the sha — anything that *gates* on the answer must use the result form instead, so a
 * timeout cannot masquerade as a clean verdict.
 *
 * @param {string} worktreePath
 * @param {(worktreePath: string) => string} [execFn] — Test-injectable
 * @returns {string|null}
 */
export function resolveHeadSha(worktreePath, execFn = defaultResolveHeadSha) {
  return resolveHeadShaResult(worktreePath, execFn).sha;
}

/**
 * Compares `record.head_sha` (HEAD sha at record time) against current worktree HEAD
 * to evaluate staleness (Phase 3). Opt-in-by-presence: missing `record.head_sha`
 * returns `checked: false`.
 *
 * `unresolved: 'timeout'` distinguishes "the tree may have moved and we could not look" from
 * "there was nothing to look at". Callers that gate shipping must refuse the former.
 *
 * @param {object} record — Record validated by validateQualityGateRecord
 * @param {string} worktreePath — Worktree absolute path
 * @param {(worktreePath: string) => string} [execFn] — Test-injectable
 * @returns {{ checked: boolean, stale: boolean, recordedSha: string|null, currentSha: string|null, unresolved: 'timeout'|null }}
 */
export function checkQualityGateStaleness(record, worktreePath, execFn = defaultResolveHeadSha) {
  const recordedSha = isNonEmptyString(record?.head_sha) ? record.head_sha : null;
  if (!recordedSha) {
    return { checked: false, stale: false, recordedSha: null, currentSha: null, unresolved: null };
  }
  const { sha: currentSha, timedOut } = resolveHeadShaResult(worktreePath, execFn);
  if (!currentSha) {
    return {
      checked: false,
      stale: false,
      recordedSha,
      currentSha: null,
      unresolved: timedOut ? 'timeout' : null,
    };
  }
  return {
    checked: true,
    stale: currentSha !== recordedSha,
    recordedSha,
    currentSha,
    unresolved: null,
  };
}

/**
 * Persists `--quality` label determined by marker CLI back into PROOF record (if missing).
 *
 * @param {string} worktreePath — Worktree absolute path
 * @param {string} label — quality-gate-labels.mjs enum
 * @param {string|null} [branch]
 * @returns {{ persisted: boolean, reason: string|null, path: string }}
 */
export function persistQualityLabel(worktreePath, label, branch = null) {
  if (!VALID_QUALITY_LABELS.has(label)) {
    return { persisted: false, reason: 'invalid_label', path: resolveWorktreeQualityGatePath(worktreePath, branch) };
  }
  const { record, path, error } = readQualityGateRecord(worktreePath, branch);
  if (error) return { persisted: false, reason: 'proof_invalid', path };
  if (!record) return { persisted: false, reason: 'proof_absent', path };
  if (record.quality_label) return { persisted: false, reason: 'already_set', path };
  try {
    writeJsonAtomicSync(path, { ...record, quality_label: label });
  } catch (e) {
    return { persisted: false, reason: `write_failed: ${e.message}`, path };
  }
  return { persisted: true, reason: null, path };
}
