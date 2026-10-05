/**
 * trunk-branch.mjs — Single entry point for trunk (protected) branch evaluation (CLI-neutral leaf util)
 *
 * Root problem: The **single concept** "is this branch trunk?" was implemented inconsistently across 4 hooks,
 * with only two recognizing `master` — `worktree-policy-guard#isProtectedBranch` (policy reference + main/master default)
 * and `trunk-start-warning` (internal Set) handled it, while `commit-guard` (`branch === 'main'`) and
 * `worktree-shipping-guard` (`wt.branch === 'main'`) hardcoded 'main'.
 *
 * Consequently, transplanting the `git-worktree-isolation` bundle to **projects whose default branch is master**
 * resulted in file edit blocking (`worktree-policy-guard`) and session warnings (`trunk-start-warning`) working,
 * while **direct trunk commits were silently permitted** (empirical reproduction 2026-08-01:
 * denied on main repo / passed through on master repo). Partial enforcement is more dangerous than total failure,
 * as active guards create a false sense of security.
 *
 * Solution: Consolidates evaluation into this file, unifying configuration under existing SSOT
 * (`protected_branches` in `.claude/config/worktree-policy.json`). No new configuration concepts are introduced —
 * this field was already the extension point used by `worktree-policy-guard` and part of `extra_files` (customizable)
 * in transplant bundles.
 *
 * Opt-in widening (2026-09-23): `enforce_worktree_all_branches: true` in the same policy file makes a
 * non-worktree checkout on *any* branch count as trunk (`requiresWorktree`). The key is read here only.
 *
 * Design Decision — **Static evaluation, no git queries**: Automatic base detection in `worktree-new.mjs`
 * (origin/HEAD → main → master) handles branch divergence (selection), whereas this module evaluates protection status.
 * Merging them would invoke `git symbolic-ref` on every hook call, increasing PreToolUse latency and destabilizing
 * checks in local repos without remotes. Static defaults + policy overrides suffice.
 *
 * R-CM-028 boundary: **boundary-uniform** — "prevent direct trunk work" carries the identical meaning in
 * Perspective 1 (harness) and Perspective 2 (transplant targets/scaffold). No branching required.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Default branch names considered trunk when unspecified in policy. Both `main` and `master` are protected
 * to accommodate coexistence following GitHub's 2020 transition. Projects using other names (`trunk`, `develop`, etc.)
 * redefine them via `protected_branches` in policy.
 */
export const DEFAULT_TRUNK_BRANCHES = Object.freeze(['main', 'master']);

/** Canonical relative path to worktree-policy.json (read-only — sole reference point). */
export const WORKTREE_POLICY_REL = '.claude/config/worktree-policy.json';

/**
 * Derives trunk branch list from policy object (pure function).
 * Adopted only when `protected_branches` is a **non-empty array** — empty arrays are treated as
 * configuration mistakes and revert to defaults (fail-safe).
 * Non-string / empty elements are filtered out.
 * @param {object|null|undefined} policy
 * @returns {string[]}
 */
export function trunkBranches(policy) {
  const raw = policy && policy.protected_branches;
  if (!Array.isArray(raw)) return [...DEFAULT_TRUNK_BRANCHES];
  const cleaned = raw.filter((b) => typeof b === 'string' && b.length > 0);
  return cleaned.length ? cleaned : [...DEFAULT_TRUNK_BRANCHES];
}

/**
 * Determines whether branch is trunk (protected) (pure function — no I/O).
 * If `branch` is empty or non-string, returns false — avoids false blocks on detached HEAD / git query failures
 * (hooks treat unevaluable states as passthrough, R-CM-006 Rule 2).
 * @param {string|null|undefined} branch
 * @param {object|null} [policy]
 * @returns {boolean}
 */
export function isTrunkBranch(branch, policy = null) {
  if (typeof branch !== 'string' || !branch) return false;
  return trunkBranches(policy).includes(branch);
}

/**
 * Opt-in `enforce_worktree_all_branches` (worktree-policy.json, boolean, default false) — the single
 * reader of the key. Only a literal `true` turns it on, so a string or a typo stays off.
 *
 * Why it exists: git-flow targets (develop / release/* beside main) want "work only in worktrees" on
 * every branch, not only on trunk. This used to require forking four managed hooks; the key
 * provides that behaviour behind one switch.
 * @param {object|null|undefined} policy
 * @returns {boolean}
 */
export function enforcesWorktreeOnAllBranches(policy) {
  return policy?.enforce_worktree_all_branches === true;
}

/**
 * Converts glob patterns to RegExp (avoids minimatch dependency).
 *   `**`  → `.*`           (arbitrary path segments)
 *   `*`   → `[^/]+`        (single segment wildcard)
 * Shared by tier path patterns (worktree-policy-guard) and escape-hatch branch patterns.
 */
export function matchesGlob(relPath, pattern) {
  const regStr = pattern
    .replace(/[.+^${}()|[\]\\*]/g, '\\$&')
    .replace(/\\\*\\\*/g, '@@GLOBSTAR@@')
    .replace(/\\\*/g, '[^/]+')
    .replace(/@@GLOBSTAR@@/g, '.*');
  return new RegExp(`^${regStr}$`).test(relPath);
}

/**
 * Is `branch` one of the policy's escape-hatch branches (`escape_hatch.branch_patterns`, hotfix/*)?
 * @param {string} branch
 * @param {object|null} [policy]
 * @returns {boolean}
 */
export function isEscapeHatch(branch, policy) {
  const patterns = policy?.escape_hatch?.branch_patterns ?? [];
  return patterns.some((p) => matchesGlob(branch, p));
}

/**
 * Must a non-worktree checkout on `branch` be treated like trunk (pure function — no I/O)?
 * Default: trunk only (identical to `isTrunkBranch`). With `enforce_worktree_all_branches: true`:
 * every named branch except the escape-hatch ones, so commit-guard, worktree-policy-guard and
 * trunk-start-warning agree that root `hotfix/x` may be edited *and* committed. The escape hatch is
 * consulted only when the key is on — key-off decisions stay exactly as they were.
 * An empty / non-string branch stays false here — callers keep their own unresolved-branch policy
 * (commit-guard and worktree-policy-guard fail closed on it).
 * @param {string|null|undefined} branch
 * @param {object|null} [policy]
 * @returns {boolean}
 */
export function requiresWorktree(branch, policy = null) {
  if (typeof branch !== 'string' || !branch) return false;
  if (isTrunkBranch(branch, policy)) return true;
  return enforcesWorktreeOnAllBranches(policy) && !isEscapeHatch(branch, policy);
}

/**
 * Reads worktree-policy.json from projectDir. Missing/parse failures return null (fail-safe) —
 * projects without policy files fall back to defaults in `isTrunkBranch`, ensuring failures here do not disable guards.
 * @param {string} projectDir
 * @returns {object|null}
 */
export function loadWorktreePolicy(projectDir) {
  try {
    return JSON.parse(readFileSync(join(projectDir, WORKTREE_POLICY_REL), 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Evaluates trunk status relative to projectDir (including policy loading; callers already holding policy
 * use `isTrunkBranch(branch, policy)` directly).
 * @param {string|null|undefined} branch
 * @param {string} projectDir
 * @returns {boolean}
 */
export function isTrunkBranchIn(branch, projectDir) {
  if (typeof branch !== 'string' || !branch) return false;
  return isTrunkBranch(branch, loadWorktreePolicy(projectDir));
}
