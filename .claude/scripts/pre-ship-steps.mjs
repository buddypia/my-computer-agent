#!/usr/bin/env node

/**
 * pre-ship-steps.mjs — CLI for the Pre-Ship step runner (lib/pre-ship-steps.mjs is the SSOT).
 *
 * Why: the ship guard, the marker helper and ops.mjs all tell the agent to run this command, but
 * only the library existed, so answers were recorded through ad-hoc `node -e` calls. This is the
 * thin entry point those hints name; every decision stays in the library.
 *
 * Usage:
 *   node .claude/scripts/pre-ship-steps.mjs next   --worktree <path>
 *   node .claude/scripts/pre-ship-steps.mjs answer --worktree <path> --step <id> --value "<what the user said>"
 *
 * Output: JSON on stdout. `next` prints the pending step (or READY); `answer` refuses any step
 * other than the pending one, as `recordAnswer` does.
 *
 * Exit codes:
 *   0 — `next`: all steps pass (READY); `answer`: recorded
 *   1 — usage error / worktree not found / answer refused
 *   2 — `next`: a step is still pending
 *
 * Boundary (R-CM-028): Perspective 1 (harness repo itself) only.
 */

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { evaluateSteps, recordAnswer } from './lib/pre-ship-steps.mjs';
import { resolveShipBaseBranch } from '../../.cli/lib/ship-base-branch.mjs';
import { resolveMainRoot, isMainModule } from './mark-pre-ship-confirmed.mjs';

const USAGE =
  'Usage: node .claude/scripts/pre-ship-steps.mjs next --worktree <path>\n' +
  '       node .claude/scripts/pre-ship-steps.mjs answer --worktree <path> --step <id> --value "<text>"';

const FLAGS = { next: ['--worktree'], answer: ['--worktree', '--step', '--value'] };

/** Parses `--key value` pairs; rejects flags the command does not take and flags without a value. */
export function parseArgs(argv) {
  const [command, ...rest] = argv;
  const known = FLAGS[command];
  if (!known) return { error: USAGE };
  const opts = {};
  for (let i = 0; i < rest.length; i += 2) {
    const flag = rest[i];
    const value = rest[i + 1];
    if (!known.includes(flag)) return { error: `Unknown argument for ${command}: ${flag}\n${USAGE}` };
    if (value === undefined || value.startsWith('--')) return { error: `${flag} needs a value` };
    opts[flag.slice(2)] = value;
  }
  const missing = known.filter((f) => opts[f.slice(2)] === undefined);
  if (missing.length) return { error: `Missing ${missing.join(', ')}\n${USAGE}` };
  return { command, opts };
}

/** Trimmed stdout, or null when git fails. */
function git(cwd, args) {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 3000 }).trim() || null;
  } catch {
    return null;
  }
}

function fail(message) {
  process.stderr.write(`[pre-ship-steps] ${message}\n`);
  process.exit(1);
}

function main(argv) {
  const parsed = parseArgs(argv.slice(2));
  if (parsed.error) fail(parsed.error);
  const { command, opts } = parsed;

  const mainRoot = resolveMainRoot();
  if (!mainRoot) fail('git common-dir resolve failed (not a git repo?)');
  // Hints pass `.worktrees/<branch>` relative to the main checkout; accept that, cwd-relative and absolute.
  const given = [resolve(opts.worktree), resolve(mainRoot, opts.worktree)].find((p) => existsSync(p));
  if (!given) fail(`worktree does not exist: ${opts.worktree}`);
  // The worktree root, so a subdirectory cannot put the answer store where ship never reads it.
  const worktreeAbs = git(given, ['rev-parse', '--show-toplevel']);
  if (!worktreeAbs) fail(`not inside a git worktree: ${given}`);
  if (!worktreeAbs.startsWith(join(mainRoot, '.worktrees') + sep)) {
    fail(`not a worktree of this repository (expected under ${join(mainRoot, '.worktrees')}): ${worktreeAbs}`);
  }
  // The branch git reports, as ship-worktree and trust reconcile read it — a path-derived name can
  // differ (branches with 3+ segments) and send the answer to a store nobody reads.
  const branch = git(worktreeAbs, ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (!branch || branch === 'HEAD') fail(`not a worktree on a branch: ${worktreeAbs}`);

  // Same inputs as mark-pre-ship-confirmed#checkPreShipSteps, so both read one evaluation.
  const evalOpts = { worktreeAbs, branch, projectDir: mainRoot, baseBranch: resolveShipBaseBranch(mainRoot) };

  if (command === 'next') {
    const state = evaluateSteps(evalOpts);
    process.stdout.write(`${JSON.stringify({ ready: state.ready, next: state.next, approvalChoices: state.approvalChoices }, null, 2)}\n`);
    process.exit(state.ready ? 0 : 2);
  }

  const result = recordAnswer({ ...evalOpts, stepId: opts.step, value: opts.value });
  if (!result.ok) fail(result.error);
  process.stdout.write(`${JSON.stringify({ ok: true, step: opts.step, path: result.path }, null, 2)}\n`);
}

if (isMainModule(import.meta.url, process.argv[1])) {
  main(process.argv);
}
