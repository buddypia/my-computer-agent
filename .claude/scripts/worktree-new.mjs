#!/usr/bin/env node
/**
 * worktree-new.mjs — Worktree freshness enforcement standard entry point (Layer 1).
 *
 * Purpose: Ensures new worktrees are always branched from the latest `origin/<base>`.
 * Prevents raw `git worktree add ... -b ...` from branching off a stale local main.
 * Claude Code / Codex / Antigravity all share this identical entry point (CLI agnostic).
 *
 * Flow:
 *   1) `git fetch origin <base>` (network failure → fail-loud + hint)
 *   2) In main worktree and base can FF to origin/<base> → attempt `git merge --ff-only`
 *      (SKIP if identical or ahead). non-FF → STOP + guide manual reconcile.
 *   3) `git worktree add <path> -b <branch> origin/<base>` (idempotent SKIP if same
 *      path/branch registered; STOP on conflicting branch/path)
 *   4) Chain `node .claude/scripts/worktree-init.mjs --worktree <path>` (symlink + PLAN.md)
 *   5) JSON report: { ok, branch, base, base_sha, worktree_path, plan_path,
 *                   actions: [...], warnings: [...] }
 *
 * Usage:
 *   node .claude/scripts/worktree-new.mjs --branch feature/<task>
 *   node .claude/scripts/worktree-new.mjs --branch fix/<bug> --base main
 *   node .claude/scripts/worktree-new.mjs --branch feature/<task> --dry-run
 *
 * Exit codes:
 *   0 — Success (created or idempotent SKIP)
 *   1 — Git failure (fetch / non-FF / conflict)
 *   2 — User/argument error
 *
 * Standard entry point for R-CM-008 Rules 4-6 + worktree freshness requirements.
 * Replaces direct `git worktree add` invocations.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, realpathSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readConfiguredShipBaseBranch, resolveShipBaseBranchStrict } from '../../.cli/lib/ship-base-branch.mjs';
import { INHERITED_REPOSITORY_POINTERS, withoutInheritedRepository } from '../../.cli/lib/utils.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, '../..');

const KNOWN_BRANCH_PREFIXES = ['feature', 'fix', 'hotfix', 'chore', 'refactor', 'docs', 'test'];

/* ============================================================
 * CLI parsing
 * ============================================================ */

function parseArgs(argv) {
  // base=null → CLI entry point auto-detects via detectDefaultBase() (create-pr base_branch, then origin/HEAD).
  // Explicit --base is used as-is. Direct runWorktreeNew invocation defaults to 'main'.
  const args = { branch: null, base: null, dryRun: false, path: null, json: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--branch' || a === '-b') args.branch = argv[++i] || null;
    else if (a === '--base') args.base = argv[++i] || null;
    else if (a === '--path' || a === '-p') args.path = argv[++i] || null;
    else if (a === '--dry-run') args.dryRun = true;
    else if (a === '--no-json') args.json = false;
    else if (a === '--help' || a === '-h') args.help = true;
    else if (a.startsWith('-')) {
      throw new Error(`Unknown option: ${a}`);
    }
  }
  return args;
}

const HELP = `worktree-new.mjs — Worktree freshness enforcement standard entry point

Usage:
  node .claude/scripts/worktree-new.mjs --branch <name> [--base main] [--path <dir>] [--dry-run]

Options:
  --branch, -b <name>   Branch name (required). Recommended format: feature/<task> / fix/<bug>.
  --base <name>         Base branch (default: create-pr base_branch; if unset, origin/HEAD → main → master).
                        Used for fetch + worktree base. Uses local <base> if origin is absent.
  --path, -p <dir>      Worktree path (default: .worktrees/<branch>).
  --dry-run             Preview execution plan without making changes.
  --no-json             Output human-readable text to stderr instead of JSON.
  --help, -h            Show this help message.

Flow: (if origin exists) fetch origin <base> → ff base (if possible) → git worktree add
based on <baseRef> → worktree-init.mjs chain. If origin absent: skip fetch/ff + use local <base>.
`;

/* ============================================================
 * Helpers (injectable for tests)
 * ============================================================ */

export function defaultGitFn(args, opts = {}) {
  return execFileSync('git', args, {
    cwd: opts.cwd || REPO_ROOT,
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: opts.timeout || 60_000,
    // The repository is `cwd`'s; an inherited pointer would override it.
    env: withoutInheritedRepository(),
  });
}

export function defaultNodeFn(args, opts = {}) {
  return execFileSync(process.execPath, args, {
    cwd: opts.cwd || REPO_ROOT,
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: opts.timeout || 60_000,
    // worktree-init.mjs runs git of its own.
    env: withoutInheritedRepository(),
  });
}

export function defaultExistsFn(p) {
  return existsSync(p);
}

/* ============================================================
 * Core
 * ============================================================ */

/**
 * Resolve main worktree root (where `.git` directory lives, not a worktree dir).
 */
export function resolveMainRoot(cwd, gitFn = defaultGitFn) {
  try {
    const commonDir = gitFn(['rev-parse', '--git-common-dir'], { cwd }).trim();
    if (!commonDir) return null;
    const absoluteCommonDir = resolve(cwd, commonDir);
    return dirname(absoluteCommonDir);
  } catch {
    return null;
  }
}

/**
 * Whether the given cwd is the main worktree (not a linked worktree).
 */
export function isMainWorktree(cwd, gitFn = defaultGitFn) {
  const mainRoot = resolveMainRoot(cwd, gitFn);
  if (!mainRoot) return false;
  try {
    return realpathSync(cwd) === realpathSync(mainRoot);
  } catch {
    return mainRoot === cwd;
  }
}

/**
 * Parse `git worktree list --porcelain` into a list of entries.
 * Returns: [{ path, branch, head }]
 */
export function listWorktrees(cwd, gitFn = defaultGitFn) {
  let out;
  try {
    out = gitFn(['worktree', 'list', '--porcelain'], { cwd });
  } catch {
    return [];
  }
  const entries = [];
  let cur = null;
  for (const line of out.split(/\r?\n/)) {
    if (line.startsWith('worktree ')) {
      if (cur) entries.push(cur);
      cur = { path: line.slice('worktree '.length), branch: null, head: null };
    } else if (line.startsWith('HEAD ') && cur) {
      cur.head = line.slice('HEAD '.length);
    } else if (line.startsWith('branch ') && cur) {
      const ref = line.slice('branch '.length);
      cur.branch = ref.startsWith('refs/heads/') ? ref.slice('refs/heads/'.length) : ref;
    } else if (line === '' && cur) {
      entries.push(cur);
      cur = null;
    }
  }
  if (cur) entries.push(cur);
  return entries;
}

/**
 * Whether a local branch exists.
 */
export function localBranchExists(branch, cwd, gitFn = defaultGitFn) {
  try {
    gitFn(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`], { cwd });
    return true;
  } catch {
    return false;
  }
}

/**
 * Whether ref `a` is an ancestor of ref `b` (a → b is FF possible).
 */
export function isAncestor(a, b, cwd, gitFn = defaultGitFn) {
  try {
    gitFn(['merge-base', '--is-ancestor', a, b], { cwd });
    return true;
  } catch {
    return false;
  }
}

/**
 * Whether a named remote (default `origin`) is configured.
 * External transplant: core check for graceful degradation in pure local repos without origin.
 */
export function remoteExists(remote = 'origin', cwd, gitFn = defaultGitFn) {
  try {
    const out = gitFn(['remote'], { cwd }) || '';
    return out
      .split(/\r?\n/)
      .map((l) => l.trim())
      .includes(remote);
  } catch {
    return false;
  }
}

/**
 * Detect the repository's default base branch when `--base` is not given.
 * Priority:
 *   0) create-pr `base_branch` (`.cli/lib/ship-base-branch.mjs` — the SSOT for "which branch this project
 *      ships onto"). A worktree must branch from the branch it will ship onto: on a git-flow target
 *      (base `develop`, origin/HEAD = `main`) the guards' deny messages tell the agent to run this script
 *      without `--base`, and step 1 alone branched those worktrees from `main`. A configured but invalid
 *      value throws (the strict resolver) rather than silently branching from somewhere else.
 *   1) origin/HEAD symbolic-ref (most authoritative when origin is configured with default)
 *   2) Local main → master in existence order
 *   3) Current branch (excluding detached HEAD)
 *   4) 'main' (final fallback)
 * Steps 1-4 run only when nothing is configured.
 *
 * @param {string} cwd Main repository root.
 * @param {Function} [gitFn]
 * @param {{existsFn?: Function, readFn?: Function}} [io] Test-injectable config reads (ship-base-branch).
 */
export function detectDefaultBase(cwd, gitFn = defaultGitFn, io = {}) {
  if (readConfiguredShipBaseBranch(cwd, io).status !== 'absent') return resolveShipBaseBranchStrict(cwd, io);
  try {
    const ref = (gitFn(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'], { cwd }) || '').trim();
    if (ref.startsWith('origin/')) {
      const name = ref.slice('origin/'.length).trim();
      if (name) return name;
    }
  } catch {
    // origin/HEAD not set → proceed to next check
  }
  for (const cand of ['main', 'master']) {
    if (localBranchExists(cand, cwd, gitFn)) return cand;
  }
  try {
    const cur = (gitFn(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd }) || '').trim();
    if (cur && cur !== 'HEAD') return cur;
  } catch {
    // detached / outside git → final fallback
  }
  return 'main';
}

/**
 * Sanitize a branch name into a path-safe segment list.
 *   feature/foo → .worktrees/feature/foo
 */
export function defaultWorktreePath(branch) {
  return join('.worktrees', branch);
}

/**
 * Validate branch name shape (very minimal — git ref rules are more permissive).
 */
export function validateBranch(branch) {
  if (!branch || typeof branch !== 'string') return 'branch is required';
  if (branch.includes('..') || branch.includes(' ') || branch.startsWith('-')) {
    return `invalid branch: "${branch}"`;
  }
  const first = branch.split('/')[0];
  if (!KNOWN_BRANCH_PREFIXES.includes(first)) {
    return `branch should start with one of ${KNOWN_BRANCH_PREFIXES.join('|')}/ (got "${first}/")`;
  }
  return null;
}

/**
 * Step 2 helper: fast-forwards local base to origin/<base> when in main worktree and base is checked out.
 * Skips FF if origin is absent (local is authoritative).
 * Divergent / FF failure terminates with error (pushes to result.errors and returns false).
 *
 * @returns {boolean} true=continue, false=STOP
 */
export function ffLocalBaseIfPossible({ base, originExists, cwd, gitFn, dryRun, result }) {
  if (!isMainWorktree(cwd, gitFn)) {
    result.warnings.push(
      'invoked from a linked worktree (not main); skipped ff of local main. ' +
        `Worktree will be created based on ${originExists ? `origin/${base}` : `local ${base}`}.`,
    );
    return true;
  }
  if (!originExists) {
    result.actions.push(`no 'origin' remote — skipped ff of local ${base} (local is authoritative)`);
    return true;
  }

  let currentBranch = '';
  try {
    currentBranch = gitFn(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd }).trim();
  } catch {
    // ignore
  }
  if (currentBranch !== base) {
    result.warnings.push(
      `current branch is "${currentBranch}" (not ${base}); skipped ff of local ${base}. ` +
        `Worktree itself will be created based on origin/${base}.`,
    );
    return true;
  }
  if (dryRun) {
    result.actions.push(`(dry-run) would attempt ff-only merge of origin/${base} into ${base}`);
    return true;
  }

  const countOrZero = (range) => {
    try {
      return parseInt(gitFn(['rev-list', '--count', range], { cwd }).trim() || '0', 10);
    } catch {
      return 0;
    }
  };
  const localAhead = countOrZero(`origin/${base}..HEAD`);
  const localBehind = countOrZero(`HEAD..origin/${base}`);

  if (localBehind === 0) {
    result.actions.push(`local ${base} is up-to-date with origin/${base} (no ff needed)`);
    return true;
  }
  if (localAhead === 0) {
    try {
      gitFn(['merge', '--ff-only', `origin/${base}`], { cwd });
      result.actions.push(`fast-forwarded local ${base} by ${localBehind} commits`);
      return true;
    } catch (e) {
      result.errors.push(
        `fast-forward local ${base} failed: ${(e.stderr || e.message || '').toString().trim()}`,
      );
      return false;
    }
  }

  // local has unique commits — divergent. STOP (avoids silent rebase).
  result.errors.push(
    `local ${base} diverged from origin/${base} (ahead ${localAhead}, behind ${localBehind}). ` +
      `STOP to avoid silent rebase risk. Reconcile manually and retry.`,
  );
  result.errors.push(
    `hint (harness R-CM-008 recovery — rebase/merge blocked by destructive-git-guard): ` +
      `1) git format-patch origin/${base}..HEAD -o .tmp/git-backup/ (backup local unique commit patches) ` +
      `2) git reset --hard origin/${base} (run manually by user — AI is blocked by destructive-git-guard) ` +
      `3) make wt.new BR=feature/<task> (retry after resolving diverge) ` +
      `4) in worktree: git am <main>/.tmp/git-backup/*.patch (preserves original author/message/timestamp) ` +
      `5) /create-pr ship-worktree.`,
  );
  return false;
}

/* ============================================================
 * Main orchestrator (testable)
 * ============================================================ */

export function runWorktreeNew(opts) {
  const {
    branch,
    base = 'main',
    path: explicitPath = null,
    dryRun = false,
    cwd = REPO_ROOT,
    gitFn = defaultGitFn,
    nodeFn = defaultNodeFn,
    existsFn = defaultExistsFn,
  } = opts;

  const result = {
    ok: false,
    branch,
    base,
    base_sha: null,
    worktree_path: null,
    plan_path: null,
    sibling_worktrees: [],
    actions: [],
    warnings: [],
    errors: [],
    dry_run: dryRun,
  };

  const branchErr = validateBranch(branch);
  if (branchErr) {
    result.errors.push(branchErr);
    return result;
  }

  const wtPathRel = explicitPath || defaultWorktreePath(branch);
  const wtPathAbs = resolve(cwd, wtPathRel);
  result.worktree_path = wtPathAbs;

  // What else is already in flight. Two sessions once fixed the identical vitest hookTimeout
  // defect three minutes apart (2026-08-23, 14:33:38 and 14:36:55) because neither could see the
  // other; the branch was literally named `fix/vitest-hook-timeout-and-guard-verbosity`, so the
  // name alone would have stopped the second one. The ship-time superset detector (R-CM-008
  // Rule 9) does catch this, but only after both sessions have finished the work.
  // Names only — no state, no registry, no new file. Just what `git worktree list` already knows,
  // said at the moment the decision is made.
  result.sibling_worktrees = listSiblingWorktrees(cwd, wtPathAbs, gitFn);

  // Origin remote presence → graceful degradation. Skip fetch/FF if absent and use local <base>.
  const originExists = remoteExists('origin', cwd, gitFn);
  const baseRef = originExists ? `origin/${base}` : base;

  // Origin absent + local base branch absent → cannot proceed.
  if (!originExists && !localBranchExists(base, cwd, gitFn)) {
    result.errors.push(
      `no 'origin' remote and local branch "${base}" does not exist. ` +
        `Specify an existing branch with --base <branch> or configure origin (git remote -v).`,
    );
    return result;
  }

  // Step 1: fetch origin <base> (only when origin exists)
  if (originExists) {
    const cacheDir = join(cwd, '.harness', 'system'); // @layout-resolver-allow
    const cacheFile = join(cacheDir, `fetch-cache-${base}.json`);
    let shouldFetch = true;
    const FETCH_TTL = 60_000; // 60s

    if (existsFn(cacheFile)) {
      try {
        const cacheData = JSON.parse(readFileSync(cacheFile, 'utf-8'));
        const age = Date.now() - (cacheData.timestamp || 0);
        if (age < FETCH_TTL) {
          shouldFetch = false;
          result.actions.push(`fetch origin skipped (cached within 60s)`);
        }
      } catch {
        // ignore and fetch
      }
    }

    if (shouldFetch) {
      result.actions.push(`fetch origin ${base}`);
      if (!dryRun) {
        try {
          gitFn(['fetch', 'origin', base], { cwd, timeout: 60_000 });
          try {
            if (!existsSync(cacheDir)) {
              mkdirSync(cacheDir, { recursive: true });
            }
            writeFileSync(cacheFile, JSON.stringify({ timestamp: Date.now() }));
          } catch {
            // ignore cache write error
          }
        } catch (e) {
          result.errors.push(
            `fetch origin ${base} failed: ${(e.stderr || e.message || '').toString().trim()}`,
          );
          result.errors.push('hint: check network / origin configuration and retry. (git remote -v)');
          return result;
        }
      }
    }
  } else {
    result.actions.push(`no 'origin' remote — skipped fetch; using local ${base} as base`);
  }

  // Resolve base SHA for reporting + base for worktree add (baseRef = origin/<base> or local <base>)
  if (!dryRun) {
    try {
      result.base_sha = gitFn(['rev-parse', baseRef], { cwd }).trim();
    } catch (e) {
      result.errors.push(`rev-parse ${baseRef} failed: ${(e.message || '').trim()}`);
      return result;
    }
  }

  // Step 2: FF local base to origin/<base> when in main worktree (only when origin exists)
  if (!ffLocalBaseIfPossible({ base, originExists, cwd, gitFn, dryRun, result })) {
    return result;
  }

  // Step 3: git worktree add
  const existingWorktrees = listWorktrees(cwd, gitFn);
  const matchingWtForPath = existingWorktrees.find(
    (w) => resolve(w.path) === resolve(wtPathAbs),
  );
  const matchingWtForBranch = existingWorktrees.find((w) => w.branch === branch);

  if (matchingWtForPath && matchingWtForPath.branch === branch) {
    // Idempotent: same path + same branch — already registered, proceed to init.
    result.warnings.push(
      `worktree already registered at ${wtPathRel} on branch ${branch} (skipped add — idempotent).`,
    );
    result.actions.push('skip git worktree add (idempotent)');
  } else if (matchingWtForPath) {
    result.errors.push(
      `path ${wtPathRel} is already registered as a worktree for another branch (${matchingWtForPath.branch}). ` +
        `Remove it first via git worktree remove ${wtPathRel} and retry.`,
    );
    return result;
  } else if (matchingWtForBranch) {
    result.errors.push(
      `branch ${branch} is already checked out in another worktree (${matchingWtForBranch.path}). ` +
        `Only one worktree per branch is allowed — use a different path or clean up the existing worktree.`,
    );
    return result;
  } else if (localBranchExists(branch, cwd, gitFn)) {
    // Local branch already exists — check ancestor relationship before adding.
    if (!isAncestor(baseRef, branch, cwd, gitFn)) {
      result.warnings.push(
        `local branch "${branch}" already exists and is not a descendant of ${baseRef}. ` +
          `Adding worktree with existing branch (base not enforced) — may be stale.`,
      );
    }
    result.actions.push(`git worktree add ${wtPathRel} (existing branch ${branch})`);
    if (!dryRun) {
      try {
        gitFn(['worktree', 'add', wtPathAbs, branch], { cwd, timeout: 60_000 });
      } catch (e) {
        result.errors.push(
          `git worktree add failed: ${(e.stderr || e.message || '').toString().trim()}`,
        );
        return result;
      }
    }
  } else {
    result.actions.push(
      `git worktree add ${wtPathRel} -b ${branch} ${baseRef}`,
    );
    if (!dryRun) {
      try {
        gitFn(['worktree', 'add', wtPathAbs, '-b', branch, baseRef], {
          cwd,
          timeout: 60_000,
        });
      } catch (e) {
        result.errors.push(
          `git worktree add failed: ${(e.stderr || e.message || '').toString().trim()}`,
        );
        return result;
      }
    }
  }

  // Step 4: worktree-init.mjs chain
  const initScript = join(cwd, '.claude/scripts/worktree-init.mjs');
  if (!existsFn(initScript)) {
    result.warnings.push(
      `worktree-init.mjs not found at ${initScript} — skipped symlink + PLAN.md auto-creation.`,
    );
  } else {
    result.actions.push(`node worktree-init.mjs --worktree ${wtPathRel}`);
    if (!dryRun) {
      try {
        const out = nodeFn([initScript, '--worktree', wtPathAbs], { cwd, timeout: 30_000 });
        // worktree-init prints PLAN.md path on creation — parse for reporting.
        const planMatch = out.match(/PLAN\.md (?:Automatically created|already exists[^:]*): (.+)/);
        if (planMatch) {
          result.plan_path = resolve(wtPathAbs, planMatch[1].trim());
        }
      } catch (e) {
        result.errors.push(
          `worktree-init.mjs failed: ${(e.stderr || e.message || '').toString().trim()}`,
        );
        return result;
      }
    }
  }

  result.ok = true;
  return result;
}

/**
 * Active worktrees other than the main root and the one being created, as `{branch, path}`.
 *
 * Fail-open (R-CM-006 Rule 2): this is awareness, never a gate — a git failure returns `[]`
 * rather than blocking creation.
 */
export function listSiblingWorktrees(cwd, selfPathAbs, gitFn = defaultGitFn) {
  let out;
  try {
    out = gitFn(['worktree', 'list', '--porcelain'], { cwd, timeout: 15_000 });
  } catch {
    return [];
  }
  const siblings = [];
  // `--porcelain` emits blank-line-separated records: `worktree <path>` then `branch refs/heads/<name>`.
  // Detached or bare records simply carry no `branch` line and are reported as null.
  for (const record of String(out || '').split('\n\n')) {
    const path = record.match(/^worktree (.+)$/m)?.[1];
    if (!path) continue;
    const abs = resolve(cwd, path);
    if (abs === resolve(cwd) || abs === selfPathAbs) continue;
    siblings.push({ branch: record.match(/^branch refs\/heads\/(.+)$/m)?.[1] || null, path: abs });
  }
  return siblings;
}

/* ============================================================
 * CLI entry
 * ============================================================ */

/**
 * Determines whether two paths refer to the same file after symlink resolution.
 */
export function isSamePath(p1, p2, realpathFn = realpathSync) {
  if (!p1 || !p2) return false;
  const a = resolve(p1);
  const b = resolve(p2);
  if (a === b) return true;
  try {
    return realpathFn(a) === realpathFn(b);
  } catch {
    return false;
  }
}

function isMain() {
  return isSamePath(process.argv[1], __filename);
}

if (isMain()) {
  // Every git this CLI runs names its repository by `-C` / cwd; an inherited pointer overrides both.
  for (const pointer of INHERITED_REPOSITORY_POINTERS) delete process.env[pointer];
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    console.error(HELP);
    process.exit(2);
  }

  if (args.help) {
    console.log(HELP);
    process.exit(0);
  }

  if (!args.branch) {
    console.error('--branch <name> is required.');
    console.error(HELP);
    process.exit(2);
  }

  // Always operate from main worktree root so .worktrees/ subtree remains consistent.
  const invocationCwd = process.cwd();
  const mainRoot = resolveMainRoot(invocationCwd) || invocationCwd;

  // Auto-detect default branch if --base is omitted.
  let base = args.base;
  if (!base) {
    try {
      base = detectDefaultBase(mainRoot);
    } catch (e) {
      console.error(`[worktree-new][error] ${e.message}`);
      process.exit(2);
    }
  }

  const result = runWorktreeNew({
    branch: args.branch,
    base,
    path: args.path,
    dryRun: args.dryRun,
    cwd: mainRoot,
  });

  // stderr in both modes — the JSON field alone is easy to scroll past, and this is the one
  // moment where knowing what else is in flight can still change what you do.
  if (result.sibling_worktrees.length > 0) {
    console.error(
      `[worktree-new] ${result.sibling_worktrees.length} other active worktree(s) — check none is already doing this:`,
    );
    for (const s of result.sibling_worktrees) {
      console.error(`[worktree-new]   ${s.branch || '(detached)'}  ${s.path}`);
    }
  }

  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    for (const a of result.actions) console.error(`[worktree-new] ${a}`);
    for (const w of result.warnings) console.error(`[worktree-new][warn] ${w}`);
    for (const e of result.errors) console.error(`[worktree-new][error] ${e}`);
    if (result.ok) {
      console.error(
        `[worktree-new] OK — worktree at ${result.worktree_path} (base ${result.base_sha || 'origin/' + result.base}).`,
      );
    }
  }

  process.exit(result.ok ? 0 : 1);
}
