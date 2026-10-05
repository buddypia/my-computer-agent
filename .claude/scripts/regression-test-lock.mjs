#!/usr/bin/env node

/**
 * regression-test-lock.mjs — Regression-test lock CLI for fix tasks (AI-Native SDLC Playbook, Stage 4 "protect the loop").
 *
 * Why:
 *   `bug-fix` Step 3.3 writes a failing regression test and verifies Red before the fix. On `fix/*` / `hotfix/*`
 *   branches the commit that adds the test *is* the lock (git history — `.cli/lib/test-lock.mjs#derivedLockedFiles`);
 *   nothing to run. This CLI covers the rest: locking by hand on other branches or for a test that was not new,
 *   showing the effective set, and — the part that must never be silent — releasing a lock with a recorded reason.
 *
 * Usage:
 *   node .claude/scripts/regression-test-lock.mjs lock <test-file>... [--reason "<why>"] [--json]
 *   node .claude/scripts/regression-test-lock.mjs lock --all [--reason "<why>"] [--json]      # every test file
 *   node .claude/scripts/regression-test-lock.mjs unlock [<test-file>...] --reason "<why>" [--json]   # no files = all
 *   node .claude/scripts/regression-test-lock.mjs status [--json]
 *
 * Behavior:
 *   - Root = worktree owning the first file path (or cwd when not under `.worktrees/`).
 *   - Ledger `.tmp/worktree-<safeBranch>/test-lock.json` (mailbox slot; dies with the worktree) is written
 *     atomically and only by this CLI. It records manual locks and *releases*; it is never deleted, so the
 *     Pre-Ship Panel can list every release (`create-pr/ops.mjs` warnings).
 *   - `unlock` requires `--reason`. Releasing is the sanctioned route out of a deny — but it is recorded.
 *   - Enforcement: commit time `.cli/hooks/commit-guard.mjs`, ship time `create-pr/ops.mjs`, and — only where
 *     `.cli/hooks/coverage-threshold-guard.mjs` is installed (harness; not in the transplant bundle) — edit
 *     time as well. See `.cli/lib/test-lock.mjs` header.
 *
 * Exit codes:
 *   0 — success (status: lock present or absent are both 0)
 *   1 — usage error / no test file given / missing --reason on unlock / write failure
 *
 * Boundary (R-CM-028): boundary-uniform meaning; Perspective 1 deployment only (P2 port = follow-up debt).
 */

import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { safeGit } from '../../.cli/lib/utils.mjs';
import { inferBranchFromWorktreePath } from '../../.cli/lib/worktree-plan-path.mjs';
import { resolveWorktreeRoot } from '../../.cli/lib/worktree-path.mjs';
import {
  TEST_LOCK_VERSION,
  effectiveTestLock,
  isTestFilePath,
  readTestLock,
  recordTestLockRelease,
  resolveLockScope,
  toRootRelative,
  upsertTestLock,
} from '../../.cli/lib/test-lock.mjs';

export function parseArgs(argv) {
  const out = { command: null, files: [], reason: '', all: false, json: false };
  const rest = [...argv];
  out.command = rest.shift() ?? null;
  while (rest.length) {
    const a = rest.shift();
    if (a === '--json') out.json = true;
    else if (a === '--all') out.all = true;
    else if (a === '--reason') out.reason = rest.shift() ?? '';
    else if (a.startsWith('--reason=')) out.reason = a.slice('--reason='.length);
    else if (a.startsWith('--')) throw new Error(`unknown option: ${a}`);
    else out.files.push(a);
  }
  return out;
}

/** Root that owns the lock: first file's worktree → cwd's worktree → cwd. */
export function resolveRoot(files, cwd) {
  const first = files[0] ? (isAbsolute(files[0]) ? files[0] : resolve(cwd, files[0])) : null;
  return (first && resolveWorktreeRoot(first)) || resolveWorktreeRoot(cwd) || cwd;
}

/**
 * The lock ledger is a worktree mailbox (`.tmp/worktree-<safeBranch>/`, removed with the worktree).
 * When the root resolves to something that is not a worktree, **fail instead of writing**.
 *
 * Why: running `unlock` with a relative path from the main clone makes `resolveRoot` fall back to
 * cwd. `inferBranchFromWorktreePath` then **invents** a branch name from the last two path segments
 * of a path outside `.worktrees/` (e.g. `<owner>/<repo>` in the main clone), and the release is
 * recorded in a mailbox that neither that worktree's commit guard nor its ship panel ever reads,
 * while the command still printed success. Reporting an unrecorded release as success is claiming
 * work that was not done.
 *
 * Why not fix `inferBranchFromWorktreePath` instead: it is a shared SSOT with many consumers, most
 * of which pass the branch explicitly and never hit the fallback. The blast radius outweighs the
 * gain; the right place to refuse is this CLI, which **writes** to the worktree mailbox.
 *
 * @param {string} root
 * @returns {string|null} Rejection message, or null when root is a worktree
 */
export function rejectNonWorktreeRoot(root) {
  if (resolveWorktreeRoot(root)) return null;
  return (
    `test-lock: ${root} is not a worktree. Each worktree has its own lock ledger, so anything ` +
    "written here would never be read by that worktree's commit guard or ship panel, and " +
    "reading here cannot see another worktree's locks.\n" +
    '  Pass the target file as an absolute path, or run inside that worktree:\n' +
    '    node .claude/scripts/regression-test-lock.mjs <lock|unlock> ' +
    '<repo>/.worktrees/<branch>/<file> --reason "<why>"'
  );
}

/** Prints the rejection and returns true when `root` is not a worktree. */
function refuseNonWorktree(root) {
  const reject = rejectNonWorktreeRoot(root);
  if (reject) console.error(reject);
  return Boolean(reject);
}

const gitAt = (root) => (args) => safeGit(args, root, { timeout: 5000 });

/**
 * @param {{files: string[], reason: string, all: boolean}} opts
 * @param {string} cwd
 * @returns {{root: string, lockPath: string, lock: object, rejected: string[]}}
 */
export function buildLock(opts, cwd, { now = () => new Date().toISOString(), headSha = null } = {}) {
  const root = resolveRoot(opts.files, cwd);
  const scope = resolveLockScope(root, root);
  const rejected = [];
  const files = [];
  for (const f of opts.files) {
    const rel = toRootRelative(root, isAbsolute(f) ? f : resolve(cwd, f));
    if (!rel) rejected.push(`${f} (outside ${root})`);
    else if (!isTestFilePath(rel)) rejected.push(`${rel} (not a test file — see TEST_FILE_PATTERNS)`);
    else if (!files.includes(rel)) files.push(rel);
  }
  const lock = {
    version: TEST_LOCK_VERSION,
    locked_at: now(),
    branch: inferBranchFromWorktreePath(root),
    head_sha: headSha,
    reason: opts.reason || '',
    files,
    all_tests: opts.all === true,
  };
  return { root, lockPath: scope.lockPath, lock, rejected };
}

/** Effective view for `status` / `unlock`: derived (git) ∪ manual − released, as plain data. */
export function effectiveView(root) {
  const lock = readTestLock(resolveLockScope(root, root).lockPath);
  const eff = effectiveTestLock({ root, lock, gitFn: gitAt(root) });
  return {
    branch: eff.branch,
    all_tests: eff.all_tests,
    files: [...eff.files].map(([path, m]) => ({ path, source: m.source, sha: m.sha })),
    released: eff.released,
    lock,
  };
}

const scopeText = (allTests, files) => (allTests ? 'all test files' : files.join(', '));

function printLocked({ lock, lockPath }) {
  console.log(`🔒 test-lock (manual): ${scopeText(lock.all_tests, lock.files)}`);
  console.log(`   reason: ${lock.reason || '(none)'}  head: ${lock.head_sha ? lock.head_sha.slice(0, 12) : 'n/a'}`);
  console.log(`   ledger: ${lockPath}`);
}

function printReleased({ entry, lockPath }) {
  console.log(`🔓 test-lock released: ${scopeText(entry.all_tests, entry.files)}`);
  console.log(`   reason: ${entry.reason}  (recorded — listed in the Pre-Ship Panel)`);
  console.log(`   ledger: ${lockPath}`);
}

function printStatus({ view, lockPath }) {
  const where = view.branch ?? 'this root';
  if (view.files.length === 0 && !view.all_tests) console.log(`(no active test-lock on ${where})`);
  else {
    console.log(`🔒 test-lock active on ${where}${view.all_tests ? ' (all test files)' : ''}:`);
    for (const f of view.files) console.log(`   ${f.path}  ← ${f.source}${f.sha ? ` ${f.sha.slice(0, 12)}` : ''}`);
  }
  for (const r of view.released) console.log(`   🔓 released ${r.at}: ${scopeText(r.all_tests, r.files)} — ${r.reason}`);
  console.log(`   ledger: ${lockPath}`);
}

const PRINTERS = { locked: printLocked, released: printReleased, status: printStatus };

function printResult(result, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  PRINTERS[result.action]?.(result);
  for (const r of result.rejected ?? []) console.log(`   ⚠️  ignored: ${r}`);
}

function cmdLock(args, cwd) {
  if (!args.all && args.files.length === 0) {
    console.error('test-lock: give at least one test file, or --all');
    return 1;
  }
  const root = resolveRoot(args.files, cwd);
  if (refuseNonWorktree(root)) return 1;
  const headSha = safeGit('rev-parse HEAD', root) || null;
  const built = buildLock(args, cwd, { headSha });
  if (!built.lock.all_tests && built.lock.files.length === 0) {
    console.error(`test-lock: nothing to lock\n  ${built.rejected.join('\n  ')}`);
    return 1;
  }
  let written;
  try {
    written = upsertTestLock({
      lockPath: built.lockPath,
      files: built.lock.files,
      allTests: built.lock.all_tests,
      reason: built.lock.reason,
      headSha,
      branch: built.lock.branch,
    });
  } catch (e) {
    console.error(`test-lock: write failed — ${e.message}`);
    return 1;
  }
  printResult({ action: 'locked', ...built, lock: written.lock }, args.json);
  return 0;
}

function cmdStatus(args, cwd) {
  const root = resolveRoot([], cwd);
  // The read path is refused too: outside a worktree it would print an invented branch name and a
  // nonexistent ledger path next to "nothing locked", which is looking in the wrong place, not an answer.
  if (refuseNonWorktree(root)) return 1;
  const { lockPath } = resolveLockScope(root, root);
  printResult({ action: 'status', lockPath, view: effectiveView(root) }, args.json);
  return 0;
}

function cmdUnlock(args, cwd) {
  if (!args.reason.trim()) {
    console.error('test-lock: unlock needs --reason "<why the test itself was wrong>" — the release is recorded');
    return 1;
  }
  const root = resolveRoot(args.files, cwd);
  if (refuseNonWorktree(root)) return 1;
  const { lockPath } = resolveLockScope(root, root);
  const view = effectiveView(root);
  const rejected = [];
  let files = [];
  for (const f of args.files) {
    const rel = toRootRelative(root, isAbsolute(f) ? f : resolve(cwd, f));
    if (!rel) rejected.push(`${f} (outside ${root})`);
    else if (!files.includes(rel)) files.push(rel);
  }
  const allTests = args.all || (args.files.length === 0 && view.all_tests);
  if (args.files.length === 0) files = view.files.map((f) => f.path);
  if (files.length === 0 && !allTests) {
    console.log(`(nothing locked to release on ${view.branch ?? 'this root'})`);
    return 0;
  }
  let written;
  try {
    written = recordTestLockRelease({
      lockPath,
      files,
      allTests,
      reason: args.reason.trim(),
      headSha: safeGit('rev-parse HEAD', root) || null,
      branch: view.branch,
    });
  } catch (e) {
    console.error(`test-lock: write failed — ${e.message}`);
    return 1;
  }
  printResult({ action: 'released', lockPath, lock: written.lock, entry: written.entry, rejected }, args.json);
  return 0;
}

export function main(argv = process.argv.slice(2), cwd = process.cwd()) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (e) {
    console.error(`test-lock: ${e.message}`);
    return 1;
  }
  if (args.command === 'lock') return cmdLock(args, cwd);
  if (args.command === 'unlock') return cmdUnlock(args, cwd);
  if (args.command === 'status') return cmdStatus(args, cwd);
  console.error(
    'Usage: node .claude/scripts/regression-test-lock.mjs <lock <file>... [--all] [--reason "..."] | unlock [<file>...] --reason "..." | status> [--json]',
  );
  return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main());
}
