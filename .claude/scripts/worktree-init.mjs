#!/usr/bin/env node
/**
 * worktree-init.mjs — R-CM-030 system_persistent worktree share helper
 *
 * Purpose: Creates a symlink from the current worktree's `.harness/system/`
 *          directory pointing to the same directory in the main worktree.
 *          Ensures all worktrees share a single SSOT
 *          (system_persistent root — parent of git common-dir).
 *
 * Idempotency:
 *   - Normalizes repo-local core.hooksPath to relative `.husky` if not already set
 *   - Already correct symlink → no-op (exit 0)
 *   - Empty directory → safely removes and creates symlink
 *   - Absent → creates parent directories and symlink
 *   - Directory with files → STOP + error (avoids silent data loss, R-CM-029 Rule 5)
 *   - Different symlink → STOP + error
 *
 * Usage:
 *   node .claude/scripts/worktree-init.mjs                  # Current CWD
 *   node .claude/scripts/worktree-init.mjs --worktree <path>
 *   node .claude/scripts/worktree-init.mjs --dry-run        # Inspection only
 *
 * Exit codes:
 *   0 — Symlink OK (created / already exists)
 *   1 — Conflict (manual resolution needed) / outside git / main worktree itself
 *   2 — Argument / user error
 *
 * AI / User guidance:
 *   This script belongs to R-CM-031 Consequential category (directory modification + data lifecycle impact)
 *   and is not automatically called by SessionStart guard. Must be invoked explicitly by user.
 */

import { existsSync, lstatSync, readlinkSync, readdirSync, rmdirSync, mkdirSync, symlinkSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname, join, relative } from 'node:path';
import { execFileSync } from 'node:child_process';
import { ensureWorktreePlan } from './lib/worktree-plan-template.mjs';
import { assertKnownFlags } from './lib/cli-flag-guard.mjs';
import { resolveShipBaseBranch } from '../../.cli/lib/ship-base-branch.mjs';
import { INHERITED_REPOSITORY_POINTERS } from '../../.cli/lib/utils.mjs';

// Every git below names its repository by `-C` / cwd. An inherited GIT_DIR/GIT_WORK_TREE overrides
// both, and the `core.hooksPath` write would land in that repository instead.
for (const pointer of INHERITED_REPOSITORY_POINTERS) delete process.env[pointer];

const args = process.argv.slice(2);
// Default is to initialize (symlink + PLAN). A dropped `--dry-run` writes into the worktree.
assertKnownFlags(
  args,
  { flags: ['--dry-run'], valueFlags: ['--worktree'] },
  { name: 'worktree-init' },
);
const DRY_RUN = args.includes('--dry-run');

function getOpt(name) {
  const idx = args.indexOf(name);
  if (idx < 0) return null;
  return args[idx + 1] || null;
}

const worktreeArg = getOpt('--worktree');
const WORKTREE = resolve(worktreeArg || process.cwd());

function fail(code, msg) {
  console.error(msg);
  process.exit(code);
}

function info(msg) {
  console.log(msg);
}

/**
 * Resolves the main worktree root using `git rev-parse --git-common-dir`.
 * Returns null on failure (handled by caller).
 */
function resolveMainWorktreeRoot(cwd) {
  try {
    const commonDir = execFileSync('git', ['rev-parse', '--git-common-dir'], {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (!commonDir) return null;
    // common-dir is the main repo's .git directory (absolute inside a worktree,
    // ".git" in main). Its parent is the main worktree root.
    const absoluteCommonDir = resolve(cwd, commonDir);
    return dirname(absoluteCommonDir);
  } catch {
    return null;
  }
}

function readGitConfig(cwd, key) {
  try {
    return execFileSync('git', ['config', '--get', key], {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
}

function normalizeHooksPath(cwd) {
  const current = readGitConfig(cwd, 'core.hooksPath');
  if (current === '.husky') {
    info(`[worktree-init] core.hooksPath already relative: .husky (no-op)`);
    return;
  }

  // For projects not using .husky (e.g. transplant targets), forcing it may silently disable
  // other existing/future hooks mechanisms (lefthook / simple-git-hooks / manual hooksPath).
  // Only normalize when .husky directory actually exists.
  if (!existsSync(join(cwd, '.husky'))) {
    info(`[worktree-init] .husky directory absent — skipping core.hooksPath normalization (husky not used; preserving existing config).`);
    return;
  }

  if (DRY_RUN) {
    info(`[worktree-init] (dry-run) Planned core.hooksPath normalization: ${current || '(unset)'} → .husky`);
    return;
  }

  execFileSync('git', ['config', 'core.hooksPath', '.husky'], {
    cwd,
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  info(`[worktree-init] Normalized core.hooksPath: ${current || '(unset)'} → .husky`);
}

const mainRoot = resolveMainWorktreeRoot(WORKTREE);
if (!mainRoot) {
  fail(1, `[worktree-init] Failed to resolve git common-dir. cwd=${WORKTREE} may be outside git.`);
}

normalizeHooksPath(WORKTREE);

if (mainRoot === WORKTREE) {
  info(`[worktree-init] Current location (${WORKTREE}) is the main worktree. System directory is already the SSOT root; symlink not needed. SKIP.`);
  process.exit(0);
}

// @layout-resolver-allow — This script is responsible for bootstrapping layout-resolver's dependency (symlink creation).
// Calling resolver would resolve this worktree's system path to the main symlink target, so hardcoding is intentional.
const mainSystemDir = join(mainRoot, '.harness', 'system'); // @layout-resolver-allow
const localBriefDir = join(WORKTREE, '.harness'); // @layout-resolver-allow
const localSystemPath = join(localBriefDir, 'system');

// Absence of system directory in main → Graceful SKIP since there is no symlink target (not a failure).
//  - External transplant target: Normal not to use cross-aidea SSOT (.harness/system)
//    (behavior promised in transplant bundle adaptation_notes[0]).
//  - harness itself: Fresh clone before first orchestrator run with uncreated system.
//  In both cases, "no system to share → symlink no-op" has the same meaning (boundary-uniform).
//  Auto-generating PLAN.md remains valid for worktree isolation; proceed to finishInit.
if (!existsSync(mainSystemDir)) {
  info(
    `[worktree-init] Main system directory absent (${mainSystemDir}) — skipping symlink step ` +
      `(no cross-aidea SSOT to share). Proceeding with PLAN.md.`,
  );
  finishInit();
}

// Current status classification
let status; // 'absent' | 'correct_symlink' | 'wrong_symlink' | 'empty_dir' | 'non_empty_dir' | 'file'
let detail = null;

if (!existsSync(localSystemPath)) {
  try {
    const st = lstatSync(localSystemPath);
    if (st.isSymbolicLink()) {
      const target = readlinkSync(localSystemPath);
      const resolved = resolve(dirname(localSystemPath), target);
      status = resolved === mainSystemDir ? 'correct_symlink' : 'wrong_symlink';
      detail = { target, resolved };
    } else {
      status = 'absent';
    }
  } catch {
    status = 'absent';
  }
} else {
  const st = lstatSync(localSystemPath);
  if (st.isSymbolicLink()) {
    const target = readlinkSync(localSystemPath);
    const resolved = resolve(dirname(localSystemPath), target);
    status = resolved === mainSystemDir ? 'correct_symlink' : 'wrong_symlink';
    detail = { target, resolved };
  } else if (st.isDirectory()) {
    const entries = readdirSync(localSystemPath).filter((e) => !e.startsWith('.DS_'));
    status = entries.length === 0 ? 'empty_dir' : 'non_empty_dir';
    detail = { entries };
  } else {
    status = 'file';
  }
}

const relSystemFromWorktree = relative(WORKTREE, localSystemPath);
const relTargetFromLink = relative(dirname(localSystemPath), mainSystemDir);

function createSymlink() {
  if (DRY_RUN) {
    info(`[worktree-init] (dry-run) Planned symlink creation: ${relSystemFromWorktree} → ${relTargetFromLink}`);
    return;
  }
  if (!existsSync(localBriefDir)) {
    mkdirSync(localBriefDir, { recursive: true });
  }
  // Relative symlink — remains valid even if worktrees are moved relative to each other.
  symlinkSync(relTargetFromLink, localSystemPath);
  info(`[worktree-init] Created: ${relSystemFromWorktree} → ${relTargetFromLink}`);
}

/**
 * Automatically creates PLAN.md from standard template if absent. Preserves if existing.
 * Skipped in DRY_RUN. Fail-open (does not affect symlink responsibility).
 */
function ensurePlanIfApplicable() {
  if (DRY_RUN) return;
  try {
    const result = ensureWorktreePlan(WORKTREE);
    if (result.created) {
      info(`[worktree-init] Automatically created PLAN.md: ${relative(WORKTREE, result.path)}`);
    } else {
      info(`[worktree-init] PLAN.md already exists (preserved): ${relative(WORKTREE, result.path)}`);
    }
  } catch (e) {
    info(`[worktree-init] Skipped PLAN.md automatic creation: ${e.message}`);
  }
}

const MAIN_LOG_LINES = 5;

/**
 * Displays the recent N commits from the ship base branch (`.cli/lib/ship-base-branch.mjs`, default
 * main) — the branch this worktree will merge into, not a hardcoded `main`.
 * Alerts AI to CLI/hook changes on the base prior to starting work.
 * Does not perform fetch — displays the base as of the user's latest fetch.
 * Fail-open on git log failure.
 */
function showMainRecentCommits() {
  if (DRY_RUN) return;
  try {
    const baseBranch = resolveShipBaseBranch(mainRoot);
    const log = execFileSync('git', ['log', '--oneline', `-${MAIN_LOG_LINES}`, `origin/${baseBranch}`], {
      cwd: WORKTREE,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (log) {
      const indented = log.split('\n').map((l) => `  ${l}`).join('\n');
      info(`[worktree-init] Recent ${MAIN_LOG_LINES} commits on ${baseBranch} (recommended review before work):\n${indented}`);
    }
  } catch {
    // Fail-open
  }
}

// init used to write GIT_DIR / GIT_WORK_TREE into the worktree's .claude/settings.local.json,
// .codex/config.toml and .agents/config.json. Those files become the environment of every command the
// agent runs, and git lets GIT_DIR override `-C <dir>` and cwd — so a test that ran `git -C <tmp>
// init/commit` wrote into the shared repository instead (harness 2026-09-23: 95 commits authored by
// the test fixture; a transplant target had core.worktree set on the shared config and local main
// moved). git already finds the repository from cwd through the worktree's `.git` file, so the pin
// bought nothing. Init now removes what older inits wrote.
// finishInit() runs from top-level branches above this line, so the key list lives inside the
// function (a module-level const would still be in its temporal dead zone).
function scrubJsonEnv(path) {
  const INJECTED_GIT_ENV = ['GIT_WORK_TREE', 'GIT_DIR'];
  if (!existsSync(path)) return false;
  let data;
  try {
    data = JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return false;
  }
  const env = data?.env;
  if (!env || typeof env !== 'object' || !INJECTED_GIT_ENV.some((k) => k in env)) return false;
  for (const k of INJECTED_GIT_ENV) delete env[k];
  if (Object.keys(env).length === 0) delete data.env;
  writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
  return true;
}

function scrubTomlEnv(path) {
  if (!existsSync(path)) return false;
  const before = readFileSync(path, 'utf-8');
  // Only the top-level [env] table is where init wrote; the same key under another table is the user's.
  const out = [];
  let table = null;
  let envHeader = -1;
  let envKeys = 0;
  const dropEmptyEnvHeader = () => {
    if (table !== 'env' || envKeys !== 0 || envHeader < 0) return;
    // A section left with blank lines only goes whole, so no stray gap is left behind.
    const rest = out.slice(envHeader + 1);
    out.splice(envHeader, rest.every((l) => !l.trim()) ? rest.length + 1 : 1);
  };
  for (const line of before.split('\n')) {
    // `[[x]]` (array of tables) ends [env] as well.
    const header = line.match(/^\s*\[(\[?)([^\]]+)\]\]?\s*$/);
    if (header) {
      dropEmptyEnvHeader();
      table = header[1] ? null : header[2].trim();
      if (table === 'env') {
        envHeader = out.length;
        envKeys = 0;
      }
      out.push(line);
      continue;
    }
    if (table === 'env' && /^\s*(GIT_WORK_TREE|GIT_DIR)\s*=/.test(line)) continue;
    if (table === 'env' && /^\s*[^#\s]/.test(line)) envKeys++;
    out.push(line);
  }
  dropEmptyEnvHeader();
  const after = out.join('\n').replace(/\n{3,}/g, '\n\n').replace(/\n+$/, '\n');
  if (after === before) return false;
  writeFileSync(path, after.trim() ? after : '');
  return true;
}

function scrubInjectedGitEnv(worktreePath) {
  if (DRY_RUN) return;
  try {
    const cleaned = [
      scrubJsonEnv(join(worktreePath, '.claude', 'settings.local.json')) && '.claude/settings.local.json',
      scrubTomlEnv(join(worktreePath, '.codex', 'config.toml')) && '.codex/config.toml',
      scrubJsonEnv(join(worktreePath, '.agents', 'config.json')) && '.agents/config.json',
    ].filter(Boolean);
    if (cleaned.length) info(`[worktree-init] Removed injected GIT_DIR/GIT_WORK_TREE from: ${cleaned.join(', ')}`);
  } catch (e) {
    info(`[worktree-init] Failed to remove injected git env: ${e.message}`);
  }
}

/**
 * Common exit sequence for successful initialization (DRY).
 */
function finishInit() {
  scrubInjectedGitEnv(WORKTREE);
  ensurePlanIfApplicable();
  showMainRecentCommits();
  process.exit(0);
}

switch (status) {
  case 'correct_symlink':
    info(`[worktree-init] Symlink already valid: ${relSystemFromWorktree} → ${relTargetFromLink} (no-op)`);
    finishInit();
    break;

  case 'absent':
    createSymlink();
    finishInit();
    break;

  case 'empty_dir':
    if (DRY_RUN) {
      info(`[worktree-init] (dry-run) Will remove empty directory and create symlink`);
      process.exit(0);
    }
    rmdirSync(localSystemPath);
    createSymlink();
    finishInit();
    break;

  case 'wrong_symlink':
    fail(
      1,
      `[worktree-init] CONFLICT: ${relSystemFromWorktree} is already a different symlink.\n` +
        `  Current target : ${detail.target} (= ${detail.resolved})\n` +
        `  Required target: ${relTargetFromLink} (= ${mainSystemDir})\n` +
        `Resolution: If this is intentional, SKIP. Otherwise, fix manually:\n` +
        `  rm '${localSystemPath}' && node ${process.argv[1]} --worktree '${WORKTREE}'`,
    );
    break;

  case 'non_empty_dir':
    fail(
      1,
      `[worktree-init] CONFLICT: ${relSystemFromWorktree} is an actual directory containing files.\n` +
        `  Contents: ${detail.entries.slice(0, 5).join(', ')}${detail.entries.length > 5 ? ' ...' : ''}\n` +
        `Automatic conversion stopped to prevent silent data loss.\n` +
        `Resolution options:\n` +
        `  (a) If system/ contents are not needed: rm -rf '${localSystemPath}' and rerun\n` +
        `  (b) If contents should merge into main system/: compare, copy to main, then rm -rf '${localSystemPath}' and rerun\n` +
        `  (c) If isolated system is specifically needed: skip symlink mechanism (not recommended, violates R-CM-030).`,
    );
    break;

  case 'file':
    fail(
      1,
      `[worktree-init] CONFLICT: ${relSystemFromWorktree} is a file (directory or symlink expected).\n` +
        `Resolution: rm '${localSystemPath}' and rerun.`,
    );
    break;

  default:
    fail(2, `[worktree-init] internal: Unknown status — ${status}`);
}
