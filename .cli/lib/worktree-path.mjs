/**
 * worktree-path.mjs — Single SSOT for "which worktree does this target absolute path belong to".
 *
 * Core Design Principle (R-CM-037 Worktree Target-Context):
 *   Worktree determination in path-classifying hooks is resolved **exclusively from the target absolute path**.
 *   Never relies on trigger session ENV/cwd/CLAUDE_PROJECT_DIR (=resolveProjectDir).
 *   The session axis is the wrong axis for per-target evaluation — in multi-session worktrees,
 *   a wt1 session would mis-evaluate wt2 / its own worktree (cross-worktree context misdelivery).
 *
 * This module provides **pure functions only** — 0 file reads, 0 git calls, 0 global state.
 *   → Shared state conflicts structurally impossible even during concurrent multi-session / multi-worktree calls.
 *   → As a non-hook module, importing causes zero standalone stdin pre-consumption side effects.
 *
 * Worktree path conventions (R-CM-034 "Worktree Operations"): All worktrees reside under
 *   `<repo-root>/.worktrees/<branch>`. GitHub Flow branches use `<type>/<slug>`
 *   2 segments (`feature/foo`) — evaluated as 2 segments only when first segment is in KNOWN_BRANCH_PREFIXES.
 *   Escape variants (`hotfix-foo`) and single names (`wt1`) evaluate as 1 segment.
 */

import { KNOWN_BRANCH_PREFIXES } from './worktree-plan-path.mjs';

const WORKTREES_SEGMENT = '/.worktrees/';

/**
 * Splits an absolute path into the repo root that owns `.worktrees/` and the worktree root itself.
 *
 * Sole place in this module where the `.worktrees/` literal is interpreted — the two exported
 * resolvers and `resolveMainRepoRoot` share one parse so a convention change lands once
 * (R-CM-037 Rule 1 SSOT singularity).
 *
 * - lastIndexOf — prioritizes innermost (actual file owner) during nested `.worktrees/`.
 * - **2-segment (`<prefix>/<slug>`) evaluation occurs only when first segment exactly matches KNOWN_BRANCH_PREFIXES**.
 *   Prevents misidentifying sub-files of single-segment worktrees (`hotfix-foo` / `wt1`) as 2-segment,
 *   avoiding false-denials of edits within their own worktrees (DEBT-182).
 *
 * @param {string} absPath
 * @returns {{repoRoot: string, worktreeRoot: string}|null}
 */
function splitWorktreePath(absPath) {
  if (!absPath || typeof absPath !== 'string') return null;
  const norm = absPath.replace(/\\/g, '/');
  const idx = norm.lastIndexOf(WORKTREES_SEGMENT);
  if (idx === -1) return null;
  const after = norm
    .slice(idx + WORKTREES_SEGMENT.length)
    .split('/')
    .filter(Boolean);
  if (after.length === 0) return null;
  const repoRoot = norm.slice(0, idx);
  const base = `${repoRoot}/.worktrees`;
  const worktreeRoot =
    after.length >= 2 && KNOWN_BRANCH_PREFIXES.includes(after[0])
      ? `${base}/${after[0]}/${after[1]}`
      : `${base}/${after[0]}`;
  return { repoRoot, worktreeRoot };
}

/**
 * Returns absolute path of worktree root if absolute path is under `.worktrees/<a>[/<b>]`.
 * Returns null if not under `.worktrees/`.
 *
 * @param {string} absPath
 * @returns {string|null}
 */
export function resolveWorktreeRoot(absPath) {
  return splitWorktreePath(absPath)?.worktreeRoot ?? null;
}

/**
 * Returns the main repo root owning the `.worktrees/` directory that contains absPath.
 * Returns null when absPath is not inside a worktree — callers treat that as "already a repo root".
 *
 * Exists so `system_persistent` resolution can map a worktree to its main worktree **without a git
 * call or cache** (`layout-resolver#resolveSystemFile`). `resolveWorktreeRoot` answers "which
 * worktree", which is the wrong half for that question.
 *
 * Empty repoRoot (path literally starting at `/.worktrees/`) returns null rather than `''` —
 * a filesystem root holding `.worktrees` is pathological and `''` would silently join to a
 * relative path.
 *
 * @param {string} absPath
 * @returns {string|null}
 */
export function resolveMainRepoRoot(absPath) {
  return splitWorktreePath(absPath)?.repoRoot || null;
}

/**
 * Checks whether absolute path is inside any worktree (boolean shortcut).
 * Completely independent of session ENV/cwd/projectDir — inspects target path segments only.
 *
 * @param {string} absPath
 * @returns {boolean}
 */
export function isWorktreeAbsPath(absPath) {
  return resolveWorktreeRoot(absPath) !== null;
}
