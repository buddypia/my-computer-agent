/**
 * ship-base-branch.mjs — SSOT for "which branch does this project ship onto".
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: only `create-pr/ops.mjs` read `base_branch` from the create-pr config; every other
 *       ship-time component hardcoded `main`. `mark-pre-ship-confirmed` stamped `review_diff_id`
 *       against `main` while `ops.mjs#assertApprovalFreshAfterBaseMerge` compared against the
 *       configured base, so on any project whose base is not `main` the two sides measured
 *       different diffs and every ship reported "Pre-Ship human approval is stale". The only way
 *       past was `--force-quality-gate`, which also disables `assertQualityGateNotNoGo` and
 *       `assertQualityGateFreshAfterBaseMerge` — a false alarm that trains operators to silence two
 *       checks that were never wrong. Reproduced on a transplant target shipping onto `develop`:
 *       the contributed diff was byte-identical before and after the base
 *       merge, yet the marker carried the `origin/main` id and the ship refused.
 *   (b) Existing gap: no module owned this value, so each caller re-derived it.
 *   (c) Simpler alternatives: passing `baseBranch` through every call site was rejected — it leaves
 *       the defaults in place, so the next new caller reintroduces the same split.
 *
 * Default is `'main'`, matching what `ops.mjs` used before it delegated here, so behaviour on a
 * project without a create-pr config (or with `base_branch: "main"`) is unchanged.
 *
 * Boundary (R-CM-028): perspective1-only — but `ops.mjs` is deployed as a standalone utility, and
 * its transitive `.cli/lib` dependencies (this module included) are co-deployed with it.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { withoutInheritedRepository } from './utils.mjs';

/** Same file `ops.mjs` reads. Kept as an export so tests and callers cannot drift from it. */
export const CREATE_PR_CONFIG_RELPATH = join('.claude', 'skills', 'create-pr', 'config.json');

/** Used when the project carries no (valid) create-pr `base_branch`. */
export const DEFAULT_SHIP_BASE_BRANCH = 'main';

/**
 * Whether a value is a valid git branch name — git's `check-ref-format --branch` rules, implemented
 * without spawning git (this runs on every session Stop).
 *
 * Deliberately not narrower than git (except quote characters, below): a stricter allowlist silently rewrote valid names such as
 * `release+2`, `rel@1` or `배포` to `main`, and ops.mjs would then open the PR against (and ff-merge)
 * the wrong branch. Shell safety is not this function's job — every shell-string consumer quotes the
 * value (`shellQuote` in `.cli/lib/utils.mjs`); argv consumers need no quoting. What this does rule
 * out is anything git itself would refuse, which includes whitespace, control characters and a
 * leading `-` (so the value can never be read as a git option).
 *
 * @param {unknown} name
 * @returns {boolean}
 */
export function isValidBranchName(name) {
  if (typeof name !== 'string' || !name) return false;
  if (name === '@' || name === 'HEAD') return false;
  // Control chars, DEL, space and git's reserved characters: ~ ^ : ? * [ \
  if (/[\x00-\x20\x7f~^:?*[\\]/.test(name)) return false;
  // The one deliberate narrowing beyond git: quote characters. Git accepts them, but they have no
  // legitimate use in a base branch name and are what breaks hand-written quoting in advisory text.
  // ops.mjs rejects them loudly (resolveShipBaseBranchStrict), so nothing is silently redirected.
  if (/['"]/.test(name)) return false;
  if (name.includes('..') || name.includes('@{') || name.includes('//')) return false;
  if (name.startsWith('-') || name.startsWith('/')) return false;
  if (name.endsWith('/') || name.endsWith('.')) return false;
  return name.split('/').every((c) => !c.startsWith('.') && !c.endsWith('.lock'));
}

/**
 * Reads `base_branch` from the create-pr config and classifies it.
 *
 * - `absent`: no config, unreadable/malformed file, key missing, or a blank string.
 * - `invalid`: present but not a valid branch name (or not a string) — `raw` carries the value.
 * - `ok`: `value` is the trimmed branch name.
 *
 * @param {string} projectDir Main repository root (not a worktree path).
 * @param {{existsFn?: typeof existsSync, readFn?: typeof readFileSync}} [io] Test-injectable.
 * @returns {{status: 'absent'|'invalid'|'ok', value?: string, raw?: unknown}}
 */
export function readConfiguredShipBaseBranch(
  projectDir,
  { existsFn = existsSync, readFn = readFileSync } = {},
) {
  const raw = readRawBaseBranch(projectDir, existsFn, readFn);
  if (raw === undefined || raw === null) return { status: 'absent' };
  if (typeof raw === 'string' && !raw.trim()) return { status: 'absent' };
  const value = typeof raw === 'string' ? raw.trim() : null;
  return isValidBranchName(value) ? { status: 'ok', value } : { status: 'invalid', raw };
}

/** `base_branch` as written in the config, or undefined when the file is absent/unreadable/malformed. */
function readRawBaseBranch(projectDir, existsFn, readFn) {
  return readCreatePrConfigKey(projectDir, 'base_branch', { existsFn, readFn });
}

/**
 * One top-level key of the create-pr config as written, or undefined when the file is
 * absent/unreadable/malformed. Shared so other ship-time settings (e.g. pre-ship-steps'
 * `milestone_waiver_short_reason`) read the same file the same fail-open way.
 *
 * @param {string} projectDir Main repository root.
 * @param {string} key
 * @param {{existsFn?: typeof existsSync, readFn?: typeof readFileSync}} [io] Test-injectable.
 */
export function readCreatePrConfigKey(projectDir, key, { existsFn = existsSync, readFn = readFileSync } = {}) {
  if (typeof projectDir !== 'string' || !projectDir) return undefined;
  const path = join(projectDir, CREATE_PR_CONFIG_RELPATH);
  try {
    if (!existsFn(path)) return undefined;
    const cfg = JSON.parse(String(readFn(path, 'utf-8')));
    return cfg && typeof cfg === 'object' ? cfg[key] : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Resolves the branch this project ships onto — for *measurement* consumers (scale, staleness,
 * review snapshot, decks, review_diff_id).
 *
 * Falls back to the default on a missing, unreadable, malformed, or invalid value (R-CM-006 Rule 2
 * fail-open) so that a broken config cannot make a worktree unmeasurable. Consumers that *act* on
 * the base (ops.mjs: PR target, fetch/checkout/merge) must use `resolveShipBaseBranchStrict`.
 *
 * @param {string} projectDir Main repository root (not a worktree path).
 * @param {{existsFn?: typeof existsSync, readFn?: typeof readFileSync}} [io] Test-injectable.
 * @returns {string}
 */
export function resolveShipBaseBranch(projectDir, io = {}) {
  const r = readConfiguredShipBaseBranch(projectDir, io);
  return r.status === 'ok' ? r.value : DEFAULT_SHIP_BASE_BRANCH;
}

/**
 * Resolves the ship base for consumers that act on it (ops.mjs). A configured but invalid value
 * throws instead of silently becoming `main` — opening a PR against, and ff-merging, a branch the
 * operator never configured is worse than refusing to run.
 *
 * @param {string} projectDir
 * @param {{existsFn?: typeof existsSync, readFn?: typeof readFileSync}} [io] Test-injectable.
 * @returns {string}
 * @throws {Error} when `base_branch` is present but not a valid branch name
 */
export function resolveShipBaseBranchStrict(projectDir, io = {}) {
  const r = readConfiguredShipBaseBranch(projectDir, io);
  if (r.status === 'invalid') {
    throw new Error(
      `Invalid base_branch ${JSON.stringify(r.raw)} in ${CREATE_PR_CONFIG_RELPATH} — ` +
        'not a valid git branch name (git check-ref-format --branch). Fix the config; ' +
        'refusing to fall back to a branch you did not configure.',
    );
  }
  return r.status === 'ok' ? r.value : DEFAULT_SHIP_BASE_BRANCH;
}

/**
 * Last-resort refs, used only when the project root cannot be located from the worktree at all.
 * Kept so that a repository without a create-pr config still measures *something* rather than going
 * unevaluable (R-CM-006 Rule 2 fail-open).
 */
export const FALLBACK_BASE_REFS = Object.freeze(['origin/main', 'main']);

/** Minimal git runner — every caller may substitute its own (R-CM-011 external command isolation). */
function defaultGit(cwd, args) {
  return execFileSync('git', ['-C', cwd, ...args], {
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'ignore'],
    // Hooks call this from a session that may export GIT_DIR, which would override `-C`.
    env: withoutInheritedRepository(),
  });
}

/**
 * Locates the main repository root from inside a worktree (parent of the shared git common-dir).
 *
 * @returns {string|null} absolute path, or null when git cannot answer
 */
export function resolveMainRootFromWorktree(worktreeAbs, gitFn = defaultGit) {
  if (typeof worktreeAbs !== 'string' || !worktreeAbs) return null;
  try {
    const common = String(gitFn(worktreeAbs, ['rev-parse', '--git-common-dir'])).trim();
    if (!common) return null;
    return dirname(isAbsolute(common) ? common : join(worktreeAbs, common));
  } catch {
    return null;
  }
}

/**
 * Git refs that represent this project's ship base, most specific first.
 *
 * Why every base-ref list is derived here rather than written at each site: `ship-scale`,
 * `worktree-shipping-guard` (unmerged count, staleness, review snapshot) and the review/ship decks
 * each carried their own `['origin/main', 'main']`. On a repository that ships onto `develop`, all of
 * them measured the branch's own work *plus every develop commit not yet released to main* — scale
 * was measured at 78 files instead of 9, which pulled large-scale deck gates onto branches that never
 * earned them. The error grows with every unreleased commit, so it degrades silently. The refs are
 * resolved from the worktree instead of accepted as a parameter because a parameter leaves a default
 * at each call site for the next caller to get wrong.
 *
 * @param {string} worktreeAbs Worktree path (or any path inside the repository).
 * @param {{gitFn?: Function, existsFn?: Function, readFn?: Function}} [io] Test-injectable.
 * @returns {string[]} refs to try, in order; never empty
 */
export function resolveShipBaseRefs(worktreeAbs, { gitFn = defaultGit, ...io } = {}) {
  const projectDir = resolveMainRootFromWorktree(worktreeAbs, gitFn);
  if (!projectDir) return [...FALLBACK_BASE_REFS];
  const base = resolveShipBaseBranch(projectDir, io);
  // Fallbacks stay appended: a configured base that is not fetched locally should degrade to a
  // measurement against something, not to no measurement at all.
  return [...new Set([`origin/${base}`, base, ...FALLBACK_BASE_REFS])];
}
