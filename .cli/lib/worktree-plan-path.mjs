/**
 * worktree-plan-path.mjs — Single SSOT helper for worktree PLAN.md locations
 *
 * Why: Placing PLAN.md at the worktree root allows .gitignore to be bypassed once tracked,
 * causing inadvertent merges into main. The `.tmp/worktree-<safeBranch>/PLAN.md` location
 * prevents git tracking via the `.tmp/` pattern in .gitignore.
 *
 * Branch namespace isolation also naturally resolves conflicts across parallel worktrees.
 *
 * Boundary (R-CM-028): Applies to Perspective 1 (harness itself) only. Perspective 2 (CONTEXT.json#execution.worktree.plan_path
 * in scaffold internal feature-pilot) is separate.
 */

import { basename, join } from 'node:path';

/**
 * Converts branch name to filesystem-safe key (`/` → `__`).
 * pre-ship-review-guard.mjs imports this function (SSOT).
 */
export function safeBranchKey(branch) {
  return (branch || 'staged').replace(/[\/\\]/g, '__');
}

// GitHub Flow branch prefixes — targets for reversing `.worktrees/<prefix>__name` escape variants.
// `release/*` `support/*` are intentionally excluded (R-CM-008 Rule 4: harness = GitHub Flow only).
// Updating this array requires adding regression tests in tests/unit/worktree-plan-path.test.mjs.
// worktree-path.mjs#resolveWorktreeRoot also imports this array (shared 2-segment evaluation SSOT under R-CM-037).
export const KNOWN_BRANCH_PREFIXES = ['feature', 'fix', 'hotfix', 'chore', 'refactor', 'docs', 'test'];

/**
 * Reverses single-segment escape variants (`feature__foo`) to slash format (`feature/foo`).
 * Returns null if it does not start with KNOWN_BRANCH_PREFIXES (signal that normalization is skipped).
 */
function reverseEscapeIfKnownPrefix(segment) {
  for (const prefix of KNOWN_BRANCH_PREFIXES) {
    if (segment.startsWith(`${prefix}__`)) {
      const suffix = segment.slice(prefix.length + 2);
      if (!suffix) return null; // `fix__` empty suffix — git rejects trailing-slash branches, skip normalization
      return `${prefix}/${suffix}`;
    }
  }
  return null;
}

/**
 * Infers branch name from worktree absolute/relative path. Normalizes both conventions to the same branch (R-CM-024).
 *
 *   `.worktrees/feature/foo`            → `feature/foo` (slash preserved)
 *   `.worktrees/feature__foo`           → `feature/foo` (escape reversed via KNOWN_BRANCH_PREFIXES)
 *   `.worktrees/fix__bar-baz`           → `fix/bar-baz`
 *   `/abs/path/.worktrees/feature/baz`  → `feature/baz`
 *   `.worktrees/random__name`           → `.worktrees/random__name` (unknown prefix, normalization skipped)
 *   `.worktrees/<single>`               → `.worktrees/<single>` (fallback)
 *   `<a>/<b>`                            → `<a>/<b>` (last 2 segments)
 *
 * pre-ship-review-guard.mjs imports this function (SSOT). worktree-shipping-guard and
 * create-pr/ops.mjs also rely on this via `resolveWorktreePlanPath`.
 */
export function inferBranchFromWorktreePath(wtPath) {
  if (!wtPath) return null;
  const parts = wtPath.split(/[\/\\]/).filter(Boolean);
  const idx = parts.lastIndexOf('.worktrees');
  if (idx >= 0) {
    if (parts.length > idx + 2) {
      return parts.slice(idx + 1, idx + 3).join('/');
    }
    if (parts.length === idx + 2) {
      const normalized = reverseEscapeIfKnownPrefix(parts[idx + 1]);
      if (normalized) return normalized;
    }
  }
  if (parts.length >= 2 && parts[parts.length - 2] !== '.worktrees') {
    return parts.slice(-2).join('/');
  }
  return parts[parts.length - 1] || null;
}

/**
 * Relative path to worktree mailbox file (relative to worktree root) — single assembly point.
 * `.tmp/worktree-<safeBranch>/<filename>`. Modifying mailbox naming conventions changes only this function
 * (PLAN.md / handoff.md / quality-gate.json / .session-owner all delegate here —
 * preventing per-file drift, Phase 2 code-review finding).
 */
function mailboxRelPath(branch, filename) {
  return join('.tmp', `worktree-${safeBranchKey(branch)}`, filename);
}

/**
 * Resolves absolute path to mailbox file from worktree absolute path + (optional) branch — single assembly point.
 * Infers branch from worktree path when unspecified (inferBranchFromWorktreePath → basename fallback).
 */
function resolveMailboxFile(worktreePath, branch, filename) {
  const inferred = branch || inferBranchFromWorktreePath(worktreePath) || basename(worktreePath);
  return join(worktreePath, mailboxRelPath(inferred, filename));
}

/**
 * Relative path of PLAN.md inside worktree (relative to worktree root).
 * `.tmp/worktree-<safeBranch>/PLAN.md`.
 */
export function planRelPath(branch) {
  return mailboxRelPath(branch, 'PLAN.md');
}

/**
 * Absolute path to Pre-Ship Review Panel confirmation marker.
 * Imported by both pre-ship-review-guard.mjs (hook) and mark-pre-ship-confirmed.mjs (CLI).
 * Ensures identical key generation across invocation paths → marker create/check integrity SSOT (R-CM-024).
 *
 * @param {string} mainRoot — Absolute path to main project root (not worktree)
 * @param {string|null} branch — Branch name or null (ship-feature mode = 'staged')
 */
export function preShipMarkerPath(mainRoot, branch) {
  return join(mainRoot, '.tmp', `pre-ship-review-confirmed-${safeBranchKey(branch)}`);
}

/**
 * Returns absolute path to PLAN.md from worktree absolute path.
 * Infers branch from worktree path if unspecified.
 */
export function resolveWorktreePlanPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'PLAN.md');
}

/**
 * Relative path to handoff.md inside worktree (relative to worktree root) — RETURN contract
 * (teamwork-preview transplant Phase 2). `.tmp/worktree-<safeBranch>/handoff.md`.
 *
 * Unlike PLAN.md, handoff.md is not automatically generated upon worktree creation —
 * its *existence itself* signals that a "structured return (RETURN) was authored" (R-CM-034 Rule 2),
 * created on-demand during session handover via `worktree-plan-template.mjs#ensureWorktreeHandoff`.
 */
export function handoffRelPath(branch) {
  return mailboxRelPath(branch, 'handoff.md');
}

/**
 * Returns absolute path to handoff.md from worktree absolute path.
 * Infers branch from worktree path if unspecified (isomorphic to resolveWorktreePlanPath).
 */
export function resolveWorktreeHandoffPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'handoff.md');
}

/**
 * Relative path to quality-gate.json inside worktree (relative to worktree root) — PROOF persistence
 * for Pre-Ship Quality Gate verdict (teamwork-preview transplant Phase 2, R-CM-030 Rule 8/9).
 * `.tmp/worktree-<safeBranch>/quality-gate.json`.
 *
 * Emitter: `record-quality-gate.mjs` (schema validation + atomic write).
 * Consumers: `mark-pre-ship-confirmed.mjs` (refuses marker creation on verdict=no_go) +
 *            `create-pr/ops.mjs#assertQualityGateNotNoGo` (re-verification at ship time).
 *
 * **Caution on branch override / multi-segment branches**:
 * If emitter (record-quality-gate.mjs uses raw branch string) and consumer (create-pr/ops.mjs uses
 * `inferBranchFromWorktreePath` — 2 segments after `.worktrees/`) use divergent branch values,
 * read/write mailbox directories diverge. Identical under standard 2-segment GitHub Flow (`feature/foo`).
 */
export function qualityGateRelPath(branch) {
  return mailboxRelPath(branch, 'quality-gate.json');
}

/**
 * Returns absolute path to quality-gate.json from worktree absolute path.
 * Infers branch from worktree path if unspecified.
 */
export function resolveWorktreeQualityGatePath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'quality-gate.json');
}

/**
 * Relative path to test-lock.json inside worktree (relative to worktree root) — regression-test lock
 * for fix tasks (AI-Native SDLC Playbook Stage 4 "protect the loop"). `.tmp/worktree-<safeBranch>/test-lock.json`.
 *
 * Emitter: `.claude/scripts/regression-test-lock.mjs` (lock / unlock / status).
 * Consumers via `.cli/lib/test-lock.mjs`: `.cli/hooks/commit-guard.mjs` (commit-time DENY) and, where it is
 * installed (harness; not in the transplant bundle), `.cli/hooks/coverage-threshold-guard.mjs` (PreToolUse
 * DENY on Write|Edit|MultiEdit of a locked test file). Same mailbox as PLAN.md so the lock dies with the worktree.
 */
export function testLockRelPath(branch) {
  return mailboxRelPath(branch, 'test-lock.json');
}

/**
 * Returns absolute path to test-lock.json from worktree absolute path.
 * Infers branch from worktree path if unspecified (isomorphic to resolveWorktreePlanPath).
 */
export function resolveWorktreeTestLockPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'test-lock.json');
}

/**
 * Absolute path to CP-MILESTONE reminder one-shot marker (R-CM-030 Rule 12) — inside worktree mailbox.
 * Recorded by `milestone-deck-warning` (PostToolUse Bash) after single notification.
 *
 * Placed *inside* worktree mailbox (rather than main root .tmp) so marker is destroyed along with worktree,
 * structurally eliminating reminder suppression on branch name reuse without GC code (code-review finding 2026-07-18).
 *
 * @param {string} worktreePath — Absolute path to worktree root
 * @param {string|null} branch — Branch name or null (inferred from worktree path)
 */
export function resolveMilestoneReminderPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'milestone-reminder-shown');
}

/**
 * Absolute path to session edit scale ledger (R-CM-030 Rule 12, DEBT-248) — inside worktree mailbox.
 *
 * Accumulated per-file by **PostToolUse Write|Edit** path in `milestone-deck-warning`.
 * Why needed: Relying solely on `git commit` means single-session straight-through implementations
 * commit only at the very end, missing the value of mid-implementation course correction (#1050, #1054, #1056, #1057).
 * Accumulating edits at edit time notifies the moment thresholds are reached.
 *
 * Destroyed together with worktree upon removal (no GC code needed).
 *
 * @param {string} worktreePath — Absolute path to worktree root
 * @param {string|null} branch — Branch name or null (inferred from worktree path)
 */
export function resolveEditScaleLedgerPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, 'edit-scale-ledger.json');
}

/**
 * Absolute path to worktree session ownership sidecar (`.session-owner`) (R-CM-036).
 * Recorded with 1-line session_id upon creation by `worktree-owner-tracker` (PostToolUse),
 * read by `worktree-session-owner-guard` (PreToolUse Layer 2) to evaluate ownership.
 *
 * Placed in `.tmp/worktree-<safeBranch>/` alongside PLAN.md — blocks git tracking via `.tmp/`
 * in `.gitignore` + resolves parallel worktree conflicts via branch namespace isolation.
 *
 * @param {string} worktreePath — Absolute path to worktree root
 * @param {string|null} branch — Branch name or null (inferred from worktree path)
 */
export function worktreeOwnerPath(worktreePath, branch = null) {
  return resolveMailboxFile(worktreePath, branch, '.session-owner');
}

/**
 * Parses `git worktree list --porcelain` output.
 * Each entry: { path, branch } (branch is short name with 'refs/heads/' stripped, or null when detached).
 * Maintained in this side effect-free lib to avoid bottom auto-run execution on hook imports.
 * Imported by worktree-shipping-guard.mjs / worktree-owner-tracker.mjs (SSOT).
 * `.filter((e) => e.path)` — excludes detached/incomplete blocks lacking paths.
 *
 * @param {string} stdout
 * @returns {Array<{path: string, branch: string|null}>}
 */
export function parseWorktreeList(stdout) {
  if (!stdout) return [];
  const blocks = stdout.split(/\n\n+/).map((b) => b.trim()).filter(Boolean);
  return blocks.map((block) => {
    const entry = { path: null, branch: null };
    for (const line of block.split('\n')) {
      if (line.startsWith('worktree ')) entry.path = line.slice('worktree '.length).trim();
      else if (line.startsWith('branch ')) {
        entry.branch = line.slice('branch '.length).trim().replace(/^refs\/heads\//, '');
      }
    }
    return entry;
  }).filter((e) => e.path);
}
