/**
 * task-acceptance.mjs — Executable acceptance criteria for the AI task contract (P1, 2026-09-22)
 *
 * Why: `ai_interpretation.verification` is prose. Prose cannot be checked by a machine, so the
 * ship gate could only confirm "a verification command ran", never "the task's own definition of
 * done holds". This module turns the contract into a small list of checks the AI writes *before*
 * coding and the ship gate re-runs *after* — the same idea as a red test written first.
 *
 * Deliberately minimal (three kinds, one inversion flag). Anything richer belongs in a real test
 * file that a `command` criterion invokes. `command` runs a shell string from the passport that the
 * same local single-user session wrote — no new trust boundary (Perspective 1 only, R-CM-028).
 *
 * Criterion shape: { kind: 'file_exists'|'grep'|'command', target, pattern?, expect?: 'pass'|'fail' }
 *   file_exists — target path (relative to root) exists
 *   grep        — file at target contains a match for RegExp(pattern)
 *   command     — shell target exits 0 (cwd = root)
 *   expect:'fail' inverts the outcome (e.g. "no remaining references to X").
 *
 * @see .claude/scripts/lib/task-passport.mjs (recordTaskInterpretation stores acceptance[])
 * @see .claude/scripts/task-interpretation.mjs (`check` subcommand)
 * @see .claude/scripts/mark-pre-ship-confirmed.mjs (checkAcceptance — ship gate)
 */
import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const ACCEPTANCE_KINDS = Object.freeze(['file_exists', 'grep', 'command']);
export const ACCEPTANCE_EXPECT = Object.freeze(['pass', 'fail']);
export const COMMAND_TIMEOUT_MS = 120_000;
/** Whole-list ceiling — keeps the ship gate under the 600 s Bash cap even with MAX_CRITERIA commands. */
export const ACCEPTANCE_TOTAL_BUDGET_MS = 300_000;
export const MAX_CRITERIA = 20;

function invalid(message) {
  const error = new Error(message);
  error.code = 'INVALID_ACCEPTANCE';
  return error;
}

/**
 * Validates and normalizes acceptance input (array or JSON string). Throws INVALID_ACCEPTANCE.
 *
 * @param {unknown} input
 * @returns {Array<{kind: string, target: string, pattern?: string, expect: 'pass'|'fail'}>}
 */
export function normalizeAcceptance(input) {
  if (input === undefined || input === null || input === '') return [];
  let list = input;
  if (typeof input === 'string') {
    try {
      list = JSON.parse(input);
    } catch {
      throw invalid('acceptance must be a JSON array of {kind, target, pattern?, expect?}.');
    }
  }
  if (!Array.isArray(list)) throw invalid('acceptance must be a JSON array.');
  if (list.length > MAX_CRITERIA) throw invalid(`acceptance supports at most ${MAX_CRITERIA} criteria.`);
  return list.map((raw, index) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw invalid(`acceptance[${index}] must be an object.`);
    }
    const kind = String(raw.kind || '').trim();
    if (!ACCEPTANCE_KINDS.includes(kind)) {
      throw invalid(`acceptance[${index}].kind must be one of ${ACCEPTANCE_KINDS.join('|')} (got "${kind}").`);
    }
    const target = String(raw.target || '').trim();
    if (!target) throw invalid(`acceptance[${index}].target is required.`);
    const expect = raw.expect === undefined ? 'pass' : String(raw.expect).trim();
    if (!ACCEPTANCE_EXPECT.includes(expect)) {
      throw invalid(`acceptance[${index}].expect must be pass|fail (got "${expect}").`);
    }
    const criterion = { kind, target, expect };
    if (kind === 'grep') {
      const pattern = String(raw.pattern || '');
      if (!pattern) throw invalid(`acceptance[${index}].pattern is required for kind=grep.`);
      try {
        new RegExp(pattern);
      } catch {
        throw invalid(`acceptance[${index}].pattern is not a valid RegExp.`);
      }
      criterion.pattern = pattern;
    }
    return criterion;
  });
}

function defaultExec(command, cwd, timeoutMs = COMMAND_TIMEOUT_MS) {
  execSync(command, { cwd, stdio: ['ignore', 'pipe', 'pipe'], timeout: timeoutMs });
}

function runFileExists(root, target) {
  const found = existsSync(resolve(root, target));
  return { raw: found, detail: found ? 'exists' : 'missing' };
}

function runGrep(root, target, pattern) {
  const abs = resolve(root, target);
  if (!existsSync(abs)) return { raw: false, detail: 'file missing' };
  let text;
  try {
    text = readFileSync(abs, 'utf8');
  } catch (error) {
    return { raw: false, detail: `unreadable: ${error.message}` };
  }
  const matched = new RegExp(pattern, 'm').test(text);
  return { raw: matched, detail: matched ? `matched /${pattern}/` : `no match for /${pattern}/` };
}

function runCommand(root, target, exec, remainingMs) {
  if (remainingMs <= 0) {
    return { raw: false, detail: `skipped: total budget ${ACCEPTANCE_TOTAL_BUDGET_MS}ms exhausted` };
  }
  try {
    exec(target, root, Math.min(COMMAND_TIMEOUT_MS, remainingMs));
    return { raw: true, detail: 'exit 0' };
  } catch (error) {
    const status = error?.status ?? error?.code ?? 'error';
    const tail = String(error?.stderr || error?.message || '').trim().split('\n').slice(-3).join(' | ');
    return { raw: false, detail: `exit ${status}${tail ? `: ${tail}` : ''}` };
  }
}

function runOne(criterion, root, exec, remainingMs) {
  const { kind, target } = criterion;
  if (kind === 'file_exists') return runFileExists(root, target);
  if (kind === 'grep') return runGrep(root, target, criterion.pattern);
  // Only a validated `command` reaches the shell. Stored criteria are re-normalized in
  // evaluateAcceptance, so this is the last line of defense, not the first.
  if (kind !== 'command') return { raw: false, detail: `unsupported kind "${kind}"` };
  return runCommand(root, target, exec, remainingMs);
}

/**
 * Evaluates every criterion against `root`. Never throws — an unexpected error is a failed criterion.
 *
 * The list is re-validated here even when it was validated at `record` time: the ship gate reads
 * it back from a JSON file, and a criterion that fails validation must fail the gate, never reach
 * the shell (an unknown `kind` used to fall through to `execSync(target)`).
 *
 * @param {unknown} criteria — raw acceptance[] (array or JSON string); see normalizeAcceptance
 * @param {{root: string, exec?: (command: string, cwd: string, timeoutMs: number) => void, budgetMs?: number, now?: () => number}} opts
 * @returns {{ok: boolean, total: number, failed: number, invalid?: string, results: Array<{index: number, kind: string, target: string, expect: string, ok: boolean, detail: string}>}}
 */
export function evaluateAcceptance(
  criteria,
  { root, exec = defaultExec, budgetMs = ACCEPTANCE_TOTAL_BUDGET_MS, now = Date.now } = {},
) {
  let list;
  try {
    list = normalizeAcceptance(criteria);
  } catch (error) {
    const total = Array.isArray(criteria) ? criteria.length : 1;
    return { ok: false, total, failed: total, invalid: error.message, results: [] };
  }
  const startedAt = now();
  const results = list.map((criterion, index) => {
    let outcome;
    try {
      outcome = runOne(criterion, root, exec, budgetMs - (now() - startedAt));
    } catch (error) {
      outcome = { raw: false, detail: `evaluator error: ${error?.message ?? error}` };
    }
    const ok = criterion.expect === 'fail' ? !outcome.raw : outcome.raw;
    return {
      index,
      kind: criterion.kind,
      target: criterion.target,
      expect: criterion.expect,
      ok,
      detail: outcome.detail,
    };
  });
  const failed = results.filter((r) => !r.ok).length;
  return { ok: failed === 0, total: results.length, failed, results };
}

/**
 * One line per criterion, for stderr/stdout reports.
 *
 * @param {ReturnType<typeof evaluateAcceptance>} report
 * @returns {string}
 */
export function formatAcceptanceReport(report) {
  if (report.invalid) return `  [FAIL] acceptance contract invalid — ${report.invalid}`;
  return report.results
    .map((r) => {
      const expect = r.expect === 'fail' ? ' (expect fail)' : '';
      return `  [${r.ok ? 'PASS' : 'FAIL'}] ${r.kind} ${r.target}${expect} — ${r.detail}`;
    })
    .join('\n');
}
