#!/usr/bin/env node

/**
 * worktree-owner-tracker.mjs — PostToolUse Bash Hook (CLI-agnostic)
 *
 * Writes worktree mailbox sidecars after successful git events. Two responsibilities, one execution path:
 *
 *   1. Ownership — immediately after successful worktree creation commands (`make wt.new` /
 *      `worktree-new.mjs` / `git worktree add`), records current session ID into
 *      `.tmp/worktree-<safeBranch>/.session-owner`. Tracks owning sessions per worktree (1 sidecar per worktree).
 *      The write goes through `claimOwnerLease`, so re-running `make wt.new` on a branch another
 *      session is actively holding does **not** take it over — `worktree-new.mjs` exits 0 on an
 *      idempotent skip, and an unconditional write there silently stole live leases.
 *      TTL SSOT: `.cli/lib/worktree-owner-lease.mjs`. Policy SSOT: R-CM-036 (worktree-session-ownership.md).
 *
 *   2. Lease heartbeat — on **every** successful Bash call, refreshes the lease of the worktree the
 *      command acted on (`commitDir`: `git -C <path>` first, then the session cwd) **only if this
 *      session already holds it** (`renewOwnerLease`). Without this the only renewal points were edits
 *      and commits, so a live session doing builds, gates, deploys or waiting on human review went
 *      silent past the TTL and lost its own worktree. It never adopts: this hook has no Layer 1 cwd
 *      check, so a read-only `git -C <other-worktree> log` adopting an expired lease would lock the
 *      real owner out for a full TTL. Adoption belongs to the edit/commit guard.
 *
 *   3. Regression-test lock announcement — immediately after a successful `git commit` on a `fix/*` /
 *      `hotfix/*` branch, tells the agent (one context line) which test files that commit **added** and that
 *      they are now locked. The lock itself is **git history** (`.cli/lib/test-lock.mjs#derivedLockedFiles`):
 *      this hook writes nothing, so there is no state to forge or forget (adversarial review 2026-09-07 —
 *      the earlier ledger write was replaced because a file the agent can edit is not a lock).
 *      `commit-guard` denies commits touching those files until `regression-test-lock.mjs unlock <file> --reason`
 *      records a release. Edits are denied only where `coverage-threshold-guard` is installed and wired (harness;
 *      the transplant bundle does not ship it) — the notice asks `test-lock.mjs#isEditLockEnforced` and says
 *      so either way, because a notice promising a block that does not exist is worse than none. Attached here because this hook
 *      already sits on PostToolUse Bash and `harness-budget#hook_files` is frozen at 65.
 *      Scope: `fix/*` / `hotfix/*` only — feature branches edit tests continuously and would only collect
 *      friction. Added (`A`) files only — a modified test in a fix commit is the fix author's judgement call.
 *      Policy SSOT: R-CM-002 Rule 10 (testing.md).
 *
 * Why: For worktree-session-owner-guard to allow edits/commits only for "worktrees created by my session",
 * the owning session must be recorded at creation time. Since session_id is provided via hook stdin JSON
 * rather than env vars, only a PostToolUse hook can record this.
 *
 * Multi-CLI: `session_id` is present in Claude Code and Codex payloads.
 * `run(data)` is exported and delegated to by `.cli/_cli-dispatch.mjs`.
 *
 * Behavior: Non-worktree-creation / missing session_id / unparseable branch / failed command / worktree not found
 *       → no-op. The tracker never blocks tool invocations.
 */

import { isAbsolute, resolve } from 'node:path';
import { HookOutput } from '../lib/hook-output.mjs';
import { readStdin, output, safeHookMain, safeGit, resolveProjectDir } from '../lib/utils.mjs';
import { DERIVED_LOCK_BRANCH_RE, isEditLockEnforced, isTestFilePath } from '../lib/test-lock.mjs';
import { parseWorktreeList } from '../lib/worktree-plan-path.mjs';
import { claimOwnerLease, renewOwnerLease } from '../lib/worktree-owner-lease.mjs';
import { resolveWorktreeRoot } from '../lib/worktree-path.mjs';

const WORKTREE_CREATE_RE = /(?:\bwt\.new\b|worktree-new\.(?:mjs|sh)|\bgit\s+worktree\s+add\b)/;
const GIT_COMMIT_RE = /\bgit\b[^|;&]*\bcommit\b/;

/**
 * Extracts branch name from worktree creation commands.
 *   1) `make wt.new BR=<x>` / `BRANCH=<x>` / `--branch <x>` (worktree-new.mjs)
 *   2) `worktree-new.sh <x>` (positional, non-flag)
 *   3) `git worktree add <path> -b <x>` (new branch)
 *   4) `git worktree add <path> <x>` (attach existing branch)
 * Unparseable → null (fail-open skip).
 */
export function parseBranchFromCommand(cmd) {
  if (!cmd || typeof cmd !== 'string') return null;
  const mBr = cmd.match(/\bBR=([^\s'"]+)/);
  if (mBr) return mBr[1];
  const mEnv = cmd.match(/\bBRANCH=([^\s'"]+)/);
  if (mEnv) return mEnv[1];
  const mFlag = cmd.match(/--branch\s+([^\s'"]+)/);
  if (mFlag) return mFlag[1];
  const mPos = cmd.match(/worktree-new\.sh\s+(?!-)([^\s'"]+)/);
  if (mPos) return mPos[1];
  const mNew = cmd.match(/\bgit\s+worktree\s+add\s+\S+\s+-b\s+([^\s'"]+)/);
  if (mNew) return mNew[1];
  const mAttach = cmd.match(/\bgit\s+worktree\s+add\s+(?!-)\S+\s+(?!-)([^\s'"]+)/);
  if (mAttach) return mAttach[1];
  return null;
}

/**
 * Session ownership sidecar write logic (CLI-agnostic, side-effect only — always passthrough).
 *
 * @param {object} data - Normalized hook payload
 * @returns {Promise<object>} Always {} (passthrough — tracker never blocks)
 */
export async function run(data) {
  if (!data || data.tool_name !== 'Bash') return {};

  const cmd = data.tool_input?.command;
  if (!cmd || typeof cmd !== 'string') return {};

  const resp = data.tool_response;
  if (resp && typeof resp.exit_code === 'number' && resp.exit_code !== 0) return {};

  renewLease(data, cmd);

  if (WORKTREE_CREATE_RE.test(cmd)) return recordOwner(data, cmd);
  if (GIT_COMMIT_RE.test(cmd) && !/--dry-run\b/.test(cmd)) return announceLockedTests(data, cmd);
  return {};
}

/**
 * Directory the commit ran in: `git -C <path>` wins, then the session cwd, then the project dir.
 * Relative `-C` is resolved against the session cwd (that is what the shell did).
 */
export function commitDir(cmd, data) {
  const base = data?.cwd || resolveProjectDir(data);
  const m = /\bgit\s+(?:-C|--git-dir=\S+\s+-C)\s+(["']?)([^\s"']+)\1/.exec(cmd);
  if (!m) return base;
  return isAbsolute(m[2]) ? m[2] : resolve(base, m[2]);
}

/** Test files with status `A` in the commit at HEAD (worktree-relative, forward slashes). */
export function addedTestFiles(nameStatus) {
  if (!nameStatus) return [];
  return nameStatus
    .split('\n')
    .map((l) => l.split('\t'))
    .filter((cols) => cols[0] === 'A' && cols[1])
    .map((cols) => cols[1].replace(/\\/g, '/'))
    .filter((p) => isTestFilePath(p));
}

async function announceLockedTests(data, cmd) {
  try {
    const dir = commitDir(cmd, data);
    const branch = safeGit('rev-parse --abbrev-ref HEAD', dir, { timeout: 3000 });
    if (!branch || !DERIVED_LOCK_BRANCH_RE.test(branch)) return {};
    // `--root`: a root commit (no parent) otherwise diffs against nothing and the red test is never seen.
    const files = addedTestFiles(safeGit('diff-tree --no-commit-id --name-status -r --root HEAD', dir, { timeout: 3000 }));
    if (files.length === 0) return {};
    const sha = safeGit('rev-parse --short=12 HEAD', dir, { timeout: 3000 }) || 'HEAD';
    const root = safeGit('rev-parse --show-toplevel', dir, { timeout: 3000 }) || resolveProjectDir(data);
    return HookOutput.context(formatLockNotice({ files, sha, branch, editGuarded: isEditLockEnforced(root) }), 'PostToolUse');
  } catch {
    return {};
  }
}

/**
 * The `[test-lock]` notice. Commit-time denial is always true (`commit-guard` ships wherever this hook
 * does); edit-time denial is stated only when `editGuarded` (see header item 3).
 */
export function formatLockNotice({ files, sha, branch, editGuarded }) {
  const edit = editGuarded
    ? 'Write/Edit on them is denied as well (coverage-threshold-guard is wired here). '
    : 'Editing them is not blocked in this repository (no edit-time guard is wired), but the commit will be refused. ';
  return (
    `[test-lock] ${files.length} regression test(s) added by commit ${sha} are now locked on ${branch}: ` +
    `${files.join(', ')}. The lock is git history itself: committing a change to them (edit, delete, rename, or ` +
    `excluding them from the test runner) is denied until ` +
    `\`node .claude/scripts/regression-test-lock.mjs unlock <file> --reason "<why>"\`, which is recorded and listed ` +
    `in the Pre-Ship Panel. ${edit}Fix the code, not the test (R-CM-002 Rule 10).`
  );
}

/**
 * Refreshes this session's own lease on the worktree this Bash call acted on. Silent and
 * best-effort — a tracker must never block a tool invocation. Never adopts (see header item 2).
 */
function renewLease(data, cmd) {
  try {
    const sessionId = data.session_id;
    if (!sessionId || typeof sessionId !== 'string') return;
    const wtRoot = resolveWorktreeRoot(commitDir(cmd, data));
    if (wtRoot) renewOwnerLease(wtRoot, null, sessionId);
  } catch {
    // silent — failures must not block tool invocations
  }
}

async function recordOwner(data, cmd) {
  const sessionId = data.session_id;
  if (!sessionId || typeof sessionId !== 'string') return {};

  const branch = parseBranchFromCommand(cmd);
  if (!branch) {
    if (process.env.DEBUG_WORKTREE_OWNER) {
      console.error(`[worktree-owner-tracker] Failed to extract branch → skipping sidecar: ${cmd.slice(0, 80)}`);
    }
    return {};
  }

  const projectDir = resolveProjectDir(data);
  const wtOut = safeGit('worktree list --porcelain', projectDir, { timeout: 3000 });
  if (wtOut === null) return {};

  const wt = parseWorktreeList(wtOut).find((e) => e.branch === branch);
  if (!wt) return {};

  // The branch is deliberately not passed: the guard and the heartbeat both infer it from the path,
  // so passing the real branch only here would split the sidecar in two for worktrees whose path
  // differs from the branch name.
  claimOwnerLease(wt.path, null, sessionId);
  return {};
}

if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMain(async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
