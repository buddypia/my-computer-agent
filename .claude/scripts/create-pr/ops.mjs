#!/usr/bin/env node

/**
 * ops.mjs — Unified execution engine for create-pr (8 commands, GitHub Flow, v2 response contract).
 *
 * Commands:
 *   Mode A (Staged Isolation):  init / isolate / commit / ship-feature / finalize
 *   Mode B (Worktree):          verify-plan / ship-worktree / cleanup-worktree
 *
 * Output Contract (v2): stdout single-line JSON
 *   Success: { ok: true,  mode, command, ... }                   (exit 0)
 *   Failure: { ok: false, mode, command, error, hint?, details? } (exit 1)
 *
 *   sync_status values: synced | no_remote | fetch_failed | local_changes | ff_failed
 *
 * Config: .claude/skills/create-pr/config.json
 *   { github_account, base_branch, enforce_ssh_remote?, superset_check_local_branches? }
 *   (base_branch defaults to main; resolved by .cli/lib/ship-base-branch.mjs.
 *    superset_check_local_branches defaults to true; false skips the unpushed-local-branch warning)
 *
 * Invariants: Unstaged/untracked files must remain untouched before and after execution.
 *   - Worktree isolation: Original HEAD invariant.
 *   - Dirty main sync abort: Halts sync without touching local modifications (no auto-stash).
 *
 * Security: All external commands use execFileSync argument arrays (no shell interpretation).
 *
 * Hook integration: cmdInit creates .tmp/create-pr-active flag →
 *   commit-guard.mjs / destructive-git-guard.mjs switch to allowlist mode.
 *   cmdFinalize / cmdCleanupWorktree automatically remove the flag upon completion.
 */

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, writeFileSync, readFileSync, realpathSync, rmSync, statSync, readdirSync } from 'node:fs';
import { basename, join, resolve, dirname, isAbsolute, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  inferBranchFromWorktreePath,
  resolveMilestoneReminderPath,
  resolveWorktreePlanPath,
  safeBranchKey,
} from '../../../.cli/lib/worktree-plan-path.mjs';
import { readQualityGateRecord, checkQualityGateStaleness } from '../lib/worktree-quality-gate.mjs';
import { recordQualityGate } from '../record-quality-gate.mjs';
import { answerStorePath, readAnswerStore, resolveReviewDiffId } from '../lib/pre-ship-steps.mjs';
import { loadApprovalPolicy } from '../lib/approval-policy.mjs';
import { loadTrust, saveTrustStore } from '../lib/approval-trust.mjs';
import { removeBranchTaskContract } from '../lib/task-passport.mjs';
// isAncestor: worktree-new.mjs 의 기존 export 재사용 (merge-base --is-ancestor boolean 화 SSOT)
import { isAncestor } from '../worktree-new.mjs';
import { classifyScale } from '../lib/ship-deck-core.mjs';
import { appendJsonlAtomicSync } from '../lib/atomic-fs.mjs';
import {
  assessTrunk,
  buildShipRecord,
  countCrossReviewSkipStreak,
  formatCurrentShipNote,
  formatStreakWarning,
  ledgerPath,
  readLedger,
  readTrunkLandings,
} from '../../../.cli/lib/ship-quality-ledger.mjs';
import { parseUncheckedPlanItems } from '../../../.cli/lib/worktree-plan-status.mjs';
import { shipTestLockFindings } from '../../../.cli/lib/test-lock.mjs';
import {
  canonicalizePath,
  INHERITED_REPOSITORY_POINTERS,
  safeGit,
  withoutInheritedRepository,
} from '../../../.cli/lib/utils.mjs';
import { resolveShipBaseBranchStrict } from '../../../.cli/lib/ship-base-branch.mjs';
import { detectBarMove, formatBarMoveWarning } from '../../../.cli/lib/self-improving-loop.mjs';
import {
  buildFileTree,
  buildPostApprovalCompletionReport,
  loadReviewPanelConfig,
} from '../../../.cli/lib/worktree-ship-report.mjs';
import {
  getActiveRunPath,
  getPipelineDataRoot,
  getRunsRoot,
  hasHarnessMarker,
} from '../../../.cli/lib/layout-resolver.mjs';

export { buildFileTree };

// ═ Paths + Config ═
const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Resolves the project root. Ensures recovery of main worktree root even when AI
 * invokes ops.mjs directly inside a secondary worktree.
 *
 * Priority:
 *   1. `process.env.CLAUDE_PROJECT_DIR` — explicit override (tests / user specified).
 *   2. Parent of `git rev-parse --git-common-dir` — all worktrees share the common root.
 *   3. `__dirname` based fallback — fallback for non-git environments.
 */
export function resolveProjectRoot(cwd = process.cwd()) {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  try {
    const commonDir = execFileSync('git', ['rev-parse', '--git-common-dir'], {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      env: withoutInheritedRepository(),
    }).trim();
    if (commonDir && commonDir !== '.' && commonDir !== '') {
      return dirname(resolve(cwd, commonDir));
    }
    process.stderr.write(
      `[ops.mjs] resolveProjectRoot: git common-dir empty (cwd=${cwd}), falling back to __dirname-based path.\n`,
    );
  } catch {
    // Non-git / git uninstalled — fallback to __dirname
  }
  return resolve(__dirname, '..', '..', '..');
}

const PROJECT_DIR = resolveProjectRoot();
const STATE_DIR = join(PROJECT_DIR, '.tmp', 'create-pr');
const ACTIVE_FLAG = join(PROJECT_DIR, '.tmp', 'create-pr-active');
const WT_DIR = join(STATE_DIR, 'wt');
const PATCH_FILE = join(STATE_DIR, 'patch');
const BRANCH_FILE = join(STATE_DIR, 'branch');
const MSG_FILE = join(STATE_DIR, 'msg');
const BODY_FILE = join(STATE_DIR, 'body');
const CONFIG_PATH = join(PROJECT_DIR, '.claude', 'skills', 'create-pr', 'config.json');

const CFG = existsSync(CONFIG_PATH) ? JSON.parse(readFileSync(CONFIG_PATH, 'utf-8')) : {};
// Resolved through the shared SSOT rather than re-derived here: `mark-pre-ship-confirmed` stamps
// review_diff_id against this same value, and a second local default is exactly how the two sides
// drifted apart (.cli/lib/ship-base-branch.mjs). Same file as CONFIG_PATH. Strict: ops *acts* on
// the base (PR target, fetch/checkout/ff-merge), so a configured-but-invalid value throws here
// instead of silently becoming 'main' — measurement consumers use the fail-open variant.
const BASE_BRANCH = resolveShipBaseBranchStrict(PROJECT_DIR);
const GH_ACCOUNT = CFG.github_account || null;
const ENFORCE_SSH = CFG.enforce_ssh_remote === true;
// Opt-out for the "other unpushed local branch touched the same files" ship warning. Default on;
// a target that judges the warning unactionable for the shipping session sets it to false.
const CHECK_LOCAL_BRANCH_SUPERSET = localBranchSupersetCheckEnabled(CFG);

// Active flag stale threshold (30 minutes)
export const ACTIVE_FLAG_STALE_MS = 30 * 60 * 1000;
const MERGEABLE_TIMEOUT_MS = 300_000;
const MERGEABLE_POLL_MS = 5_000;

// ═ Shell ═
// Transient network error patterns for gh/git retries
const TRANSIENT_ERROR_PATTERNS = [
  /ETIMEDOUT/i,
  /ECONNRESET/i,
  /ENETUNREACH/i,
  /EAI_AGAIN/i,
  /ENOTFOUND/i,
  /timed out/i,
  /Client\.Timeout exceeded/i,
  /TLS handshake/i,
  /connection reset/i,
  /reset by peer/i,
  /connection closed/i,
  /could not resolve host/i,
  /temporary failure in name resolution/i,
  /banner exchange/i,
  /kex_exchange_identification/i,
  /Could not read from remote repository/i,
  /Connection refused/i,
];

export function isTransient(err) {
  const msg = String(err && err.message ? err.message : err == null ? '' : err);
  return TRANSIENT_ERROR_PATTERNS.some((re) => re.test(msg));
}

function defaultSleepSeconds(sec) {
  if (!(sec > 0)) return;
  try {
    execFileSync('sleep', [String(sec)], { stdio: 'ignore' });
  } catch {
    /* Ignore sleep failure */
  }
}

export function retryTransient(fn, opts = {}) {
  const attempts = Number.isInteger(opts.attempts) && opts.attempts > 0 ? opts.attempts : 3;
  const sleep = typeof opts.sleep === 'function' ? opts.sleep : defaultSleepSeconds;
  const baseDelaySec = Number.isFinite(opts.baseDelaySec) ? opts.baseDelaySec : 2;
  let lastErr;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return fn();
    } catch (e) {
      lastErr = e;
      if (attempt >= attempts || !isTransient(e)) throw e;
      sleep(Math.min(baseDelaySec * attempt, 8));
    }
  }
  throw lastErr;
}

function execOnce(cmd, opts = {}) {
  try {
    const r = execFileSync(cmd[0], cmd.slice(1), {
      cwd: opts.cwd || PROJECT_DIR,
      encoding: opts.raw ? 'buffer' : 'utf-8',
      timeout: opts.timeout ?? 30_000,
      stdio: ['pipe', 'pipe', 'pipe'],
      // Every git here names its repository by `cwd`; an inherited pointer would override it.
      env: withoutInheritedRepository(opts.env || process.env),
      maxBuffer: opts.maxBuffer ?? 256 * 1024 * 1024,
    });
    return opts.raw ? r : (typeof r === 'string' ? r : r.toString('utf-8')).trim();
  } catch (e) {
    const stderr = (e.stderr || '').toString().trim();
    const err = new Error(`${cmd[0]} failed: ${stderr || e.message}`);
    // Gate runners print their step table to stdout; without this the caller only sees stderr and
    // cannot say *which* step failed.
    err.stdout = (e.stdout || '').toString();
    err.stderr = stderr;
    throw err;
  }
}

function exec(cmd, opts = {}) {
  if (opts.retry && opts.retry > 1) {
    return retryTransient(() => execOnce(cmd, opts), { attempts: opts.retry, sleep: opts.sleep });
  }
  return execOnce(cmd, opts);
}

const git = (args, opts = {}) => exec(['git', ...args], opts);

/**
 * Builds the gh auth token command using the specified or default account.
 */
export function buildGhTokenCommand(ghAccount) {
  return ghAccount ? ['gh', 'auth', 'token', '-u', ghAccount] : ['gh', 'auth', 'token'];
}

let cachedToken = null;
function ghToken() {
  if (cachedToken) return cachedToken;
  const tokenCmd = buildGhTokenCommand(GH_ACCOUNT);
  try {
    cachedToken = retryTransient(() => exec(tokenCmd), { attempts: 3 });
  } catch (e) {
    const err = new Error(
      `Failed to retrieve gh auth token (${GH_ACCOUNT ? `account: ${GH_ACCOUNT}` : 'default login account'}): ${e.message}`
    );
    err.details = { hint: `Check gh auth login status, or specify account in config.github_account: ${CONFIG_PATH}` };
    throw err;
  }
  return cachedToken;
}

/**
 * Dedicated timeout for `git push` (30 minutes).
 *
 * The pre-push hook runs the whole CI mirror inside this push, so this budget must contain the
 * *entire* gate, not one step. Measured 2026-08-24: a full 31-step run took 884.8s against the
 * old 900_000 — a 15-second margin, and `retry: 3` on that push would have silently re-run the
 * 15-minute gate three more times. Raised alongside the product-e2e step ceiling it must exceed
 * (`ci-local-status.mjs`), keeping the three-layer ordering intact.
 */
export const PUSH_TIMEOUT_MS = 1_800_000;

const gh = (args, opts = {}) => exec(['gh', ...args], {
  timeout: 60_000,
  retry: 3,
  ...opts,
  env: { ...process.env, GH_TOKEN: ghToken(), GH_HOST: 'github.com' },
});

function resolveRepo() {
  const url = git(['remote', 'get-url', 'origin']);
  const m = url.match(/[:/]([^:/]+\/[^/]+?)(?:\.git)?$/);
  if (!m) throw new Error(`Failed to parse origin URL: ${url}`);
  return m[1];
}

/**
 * Normalizes `--worktree <p>` argument to an absolute path relative to PROJECT_DIR.
 */
export function resolveWorktreeAbsPath(wtPath) {
  if (!wtPath) return wtPath;
  return isAbsolute(wtPath) ? wtPath : join(PROJECT_DIR, wtPath);
}

/**
 * Extracts worktree absolute paths from `git worktree list --porcelain`.
 */
const WORKTREE_LINE_RE = /^worktree (.+)$/;

export function parseWorktreePaths(porcelainOutput) {
  if (!porcelainOutput) return [];
  const paths = [];
  for (const line of porcelainOutput.split(/\r?\n/)) {
    const match = WORKTREE_LINE_RE.exec(line);
    if (match) {
      const path = match[1].trim();
      if (path) paths.push(path);
    }
  }
  return paths;
}

/**
 * Classifies `git status --porcelain` output as clean or dirty.
 */
export function parsePorcelainStatus(porcelain) {
  if (!porcelain || !porcelain.trim()) return { status: 'clean' };
  const dirty_paths = porcelain
    .split(/\r?\n/)
    .filter((line) => line && !line.startsWith('??'))
    .map((line) => {
      const rest = line.slice(3).trim();
      const arrow = rest.indexOf(' -> ');
      return arrow >= 0 ? rest.slice(arrow + 4).trim() : rest;
    })
    .filter(Boolean);
  return dirty_paths.length > 0 ? { status: 'dirty', dirty_paths } : { status: 'clean' };
}

/**
 * Detects whether main repo working tree has uncommitted modifications post-merge.
 */
export function detectPostMergeMainStatus(cwd = PROJECT_DIR) {
  try {
    const status = git(['status', '--porcelain'], { cwd, timeout: 5_000 });
    return parsePorcelainStatus(status);
  } catch {
    return { status: 'unknown' };
  }
}

// ═ Pure helpers ═

/**
 * Collects the full changed-file list for a just-merged PR.
 *
 * Root-cause fix (A1, observed on PR #1280): `gh pr view --json files` silently caps at 100
 * entries — PR #1280 had 107 files, and the completion report omitted the 7 beyond the cap with
 * no error, no warning, nothing. A capped source must never be used silently.
 *
 * Primary path reuses `myChangedFiles()` — the exact `git diff --name-only origin/<base>...HEAD`
 * source the bar-move/superset detectors already trust (R-CM-008 Rule 9 "same source" contract).
 * It is uncapped by construction and available whenever the local worktree checkout still exists
 * (true for both `createAndMergePr()` call sites at merge time, before worktree cleanup runs).
 *
 * Fallback (`gh api --paginate .../pulls/{n}/files --jq '.[].filename'`) covers the case where no
 * local worktree/base is available — `--paginate` walks every page instead of truncating, unlike
 * `gh pr view --json files`.
 *
 * @param {number} prNumber
 * @param {string} repo `owner/repo`
 * @param {{worktreeDir?: string|null, baseBranch?: string|null, gitFn?: Function, ghFn?: Function}} [opts]
 * @returns {string[]}
 */
export function collectChangedFilesViaPr(prNumber, repo, { worktreeDir = null, baseBranch = null, gitFn = git, ghFn = gh } = {}) {
  if (worktreeDir && baseBranch) {
    try {
      return myChangedFiles(worktreeDir, baseBranch, gitFn);
    } catch {
      // Local checkout unusable (e.g. already removed) — fall through to gh api below.
    }
  }
  try {
    const out = ghFn(['api', '--paginate', `repos/${repo}/pulls/${String(prNumber)}/files`, '--jq', '.[].filename']);
    return splitNonEmptyLines(out);
  } catch {
    return []; // fail-open (R-CM-006 Rule 2) — a missing changed_files list must not block a merge already done.
  }
}

/**
 * Runs the tracker's `register` subcommand and returns its raw stdout. Split out as the injection
 * seam for `registerFollowupDebtFromPr` — `--pr N` without `--from-text` fetches the PR body over
 * `gh`, so the real child cannot run in a unit test. Locating the script belongs here rather than
 * in the caller: it is this runner's own precondition, and keeping it here leaves the caller with a
 * single failure path — anything that prevents stdout arrives as a thrown error.
 */
function runFollowupDebtRegister(prNumber) {
  const scriptPath = join(PROJECT_DIR, '.claude', 'scripts', 'followup-debt-tracker.mjs');
  if (!existsSync(scriptPath)) throw new Error(`tracker script not found at ${scriptPath}`);
  return execFileSync(
    process.execPath,
    [scriptPath, 'register', '--pr', String(prNumber), '--json'],
    {
      cwd: PROJECT_DIR,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
      env: withoutInheritedRepository(),
    },
  );
}

/**
 * Registers follow-up debt from merged PR description.
 *
 * Returns everything the caller must show the human as one `warnings` array — skip reasons and the
 * tracker's own warnings alike. They were two fields once, and the caller read only `error`: the
 * tracker's malformed-marker warning went to the child's stderr, which this function pipes and
 * reads **only when the child fails**, so on the success path it was dropped. DEBT-326 was
 * registered that way on 2026-09-05 with nothing printed anywhere. One array cannot be half-read.
 *
 * @param {number} prNumber
 * @param {(prNumber: number) => string} [runFn] — Test-injectable child runner
 * @returns {{ warnings: string[], count: number, items: object[] }}
 */
export function registerFollowupDebtFromPr(prNumber, runFn = runFollowupDebtRegister) {
  const skipped = (reason) => ({ warnings: [reason], count: 0, items: [] });
  if (!Number.isInteger(prNumber) || prNumber < 1) {
    return skipped(`followup-debt registration skipped: invalid PR number (${prNumber})`);
  }

  let stdout;
  try {
    stdout = runFn(prNumber);
  } catch (e) {
    const stderr = (e.stderr || '').toString().trim();
    const errStdout = (e.stdout || '').toString().trim();
    return skipped(`followup-debt registration skipped: ${stderr || errStdout || e.message}`);
  }

  try {
    const parsed = JSON.parse((stdout || '').trim());
    return {
      warnings: Array.isArray(parsed.warnings)
        ? parsed.warnings.map((w) => `followup-debt: ${w}`)
        : [],
      count: typeof parsed.registered === 'number' ? parsed.registered : 0,
      items: Array.isArray(parsed.items) ? parsed.items : [],
    };
  } catch (e) {
    return skipped(`followup-debt stdout parse failed: ${e.message}`);
  }
}

function deleteBranchAndStashes(branch) {
  if (!branch || branch === BASE_BRANCH || branch === 'main' || branch === 'master') return;
  try {
    const list = git(['stash', 'list']).split('\n').filter(Boolean);
    const toDrop = [];
    list.forEach((line, idx) => {
      const match = line.match(/^(?:stash@\{\d+\}:\s+)?(?:On|WIP on)\s+([^\s:]+):\s*auto-checkpoint/);
      if (match && match[1] === branch) toDrop.push(idx);
    });
    toDrop.reverse().forEach(idx => {
      try { git(['stash', 'drop', `stash@{${idx}}`]); } catch {}
    });
  } catch {}
  try { git(['branch', '-D', branch]); } catch {}
  try { git(['push', 'origin', '--delete', branch], { timeout: 30_000 }); } catch {}
}

export const parseUnchecked = parseUncheckedPlanItems;

const STAGED_CMDS = new Set(['init', 'isolate', 'commit', 'ship-feature', 'finalize']);
const WORKTREE_CMDS = new Set(['verify-plan', 'ship-worktree', 'cleanup-worktree']);
function inferMode(command) {
  if (STAGED_CMDS.has(command)) return 'staged';
  if (WORKTREE_CMDS.has(command)) return 'worktree';
  return null;
}

function isStaleActiveFlag(flagPath, now = Date.now(), thresholdMs = ACTIVE_FLAG_STALE_MS) {
  if (!existsSync(flagPath)) return true;
  try {
    const mtime = statSync(flagPath).mtimeMs;
    return (now - mtime) > thresholdMs;
  } catch { return true; }
}

// ═ Args ═
function parseArgs(tokens) {
  const opts = {};
  for (let i = 0; i < tokens.length; i++) {
    if (!tokens[i].startsWith('--')) continue;
    const key = tokens[i].slice(2);
    opts[key] = (tokens[i + 1] && !tokens[i + 1].startsWith('--')) ? tokens[++i] : true;
  }
  return opts;
}
function requireArg(args, key, { type = 'string' } = {}) {
  const v = args[key];
  if (v === undefined) throw new Error(`--${key} is required`);
  if (type === 'string' && typeof v !== 'string') {
    throw new Error(`--${key} requires a value (got: ${v}). Usage: --${key} <value>`);
  }
  return v;
}

/**
 * Resolves a PR body from `--body` (inline) or `--body-file` (path).
 *
 * A PR body is multi-paragraph markdown, so callers reach for the file form — `gh` itself offers
 * `--body-file` for exactly that reason. It was not accepted here, and `parseArgs` discards flags a
 * command does not read, so the body silently became '' and the PR shipped blank. Measured
 * 2026-08-25: 6 of the last 40 merged PRs have an empty body, and of those, #1067 and #1069 have
 * `--body-file` ship commands on record in `governance-events.jsonl` (the other four were not
 * traced back to an invocation).
 */
export function resolveBodyArg(args) {
  const inline = typeof args.body === 'string' ? args.body : null;
  const path = typeof args['body-file'] === 'string' ? args['body-file'] : null;
  if (inline !== null && path !== null) {
    throw new Error('--body and --body-file are mutually exclusive. Pass exactly one.');
  }
  if (path === null) return inline ?? '';
  if (!existsSync(path)) throw new Error(`--body-file not found: ${path}`);
  return readFileSync(path, 'utf-8');
}

// ═ State ═
const readBranch = () => {
  if (!existsSync(BRANCH_FILE)) throw new Error('No active session. Run isolate first.');
  return readFileSync(BRANCH_FILE, 'utf-8').trim();
};

function autoCleanup() {
  try { if (existsSync(ACTIVE_FLAG)) rmSync(ACTIVE_FLAG); } catch {}
  if (!existsSync(STATE_DIR)) return;
  if (existsSync(WT_DIR)) {
    try { git(['worktree', 'remove', WT_DIR, '--force']); } catch {}
    try { git(['worktree', 'prune']); } catch {}
  }
  if (existsSync(BRANCH_FILE)) {
    const branch = readFileSync(BRANCH_FILE, 'utf-8').trim();
    if (branch) { try { git(['branch', '-D', branch]); } catch {} }
  }
  rmSync(STATE_DIR, { recursive: true, force: true });
}

// Pre-Ship Review marker lifecycle (R-CM-030)
const SHIP_REVIEW_MARKER_PREFIX = 'pre-ship-review-confirmed-';
const SHIP_REVIEW_MARKER_MAX_AGE_MS = 60 * 60 * 1000;
/**
 * Absolute path of the pre-ship approval marker. Exported so tests resolve it through the same
 * PROJECT_DIR this module computed, rather than guessing at it from the environment.
 */
export function shipReviewMarkerPath(absWtPath) {
  return join(PROJECT_DIR, '.tmp', `${SHIP_REVIEW_MARKER_PREFIX}${shipReviewMarkerKey(absWtPath)}`);
}

export function shipReviewMarkerKey(branchOrPath) {
  // Key parity SSOT: safeBranchKey ∘ inferBranchFromWorktreePath — the same composition
  // pre-ship-review-guard / mark-pre-ship-confirmed use to *create and check* the marker.
  // The former inline reimplementation produced `.worktrees__fix__bar` for escaped-form
  // paths (`.worktrees/fix__bar`), so the post-ship unlink missed the marker the guard
  // actually honors — a fresh approval survived into the 10-min TTL reuse window.
  if (!branchOrPath) return 'staged';
  return safeBranchKey(inferBranchFromWorktreePath(String(branchOrPath)) ?? String(branchOrPath));
}
function unlinkShipReviewMarker(branchOrPath) {
  const path = shipReviewMarkerPath(branchOrPath);
  try { if (existsSync(path)) rmSync(path, { force: true }); } catch {}
}
function gcStaleShipReviewMarkers(maxAgeMs = SHIP_REVIEW_MARKER_MAX_AGE_MS) {
  const dir = join(PROJECT_DIR, '.tmp');
  if (!existsSync(dir)) return;
  try {
    for (const name of readdirSync(dir)) {
      if (!name.startsWith(SHIP_REVIEW_MARKER_PREFIX)) continue;
      const p = join(dir, name);
      try {
        if (Date.now() - statSync(p).mtime.getTime() > maxAgeMs) rmSync(p, { force: true });
      } catch {}
    }
  } catch {}
}

function checkSshRemoteIfRequired() {
  if (!ENFORCE_SSH) return;
  const remoteUrl = git(['remote', 'get-url', 'origin']);
  const isSsh = remoteUrl.startsWith('git@') || remoteUrl.startsWith('ssh://');
  if (!isSsh) {
    const err = new Error('origin is not an SSH remote');
    err.details = {
      remote_url: remoteUrl,
      hint: 'SSH alias remote required when config.enforce_ssh_remote=true. Switch via git remote set-url and retry.',
    };
    throw err;
  }
}

/**
 * Checks whether a make target exists using dry-run (`make -n <target>`).
 *
 * The three failure modes below are NOT the same answer, and collapsing them into one
 * `catch { return false }` cost a real quality gate: the sole caller runs the 31-step CI mirror
 * only `if (makeTargetExists('q.ci-mirror'))`, so a slow `make` silently reported "no such target"
 * and shipped without ever running it. Observed 2026-08-24 as a retry-passed test
 * (`r-cm-041-flaky-tests`); `make -n q.check` measured 0.45s idle but 5.3s cold at load 77,
 * and the full suite runs vitest + e2e in parallel well above that.
 *
 *   make answered, non-zero  → false. The target (or the Makefile) genuinely is not there.
 *   make is not installed    → false. A transplant target without `make` must stay usable (R-CM-009).
 *   make never finished      → true.  We do not know, and "don't know" is no reason to skip a gate.
 *                                     Worst case the caller runs a target that fails loudly.
 */
export function makeTargetExists(target, cwd, { timeoutMs = 60_000 } = {}) {
  try {
    execFileSync('make', ['-n', target], { cwd, stdio: 'pipe', encoding: 'utf-8', timeout: timeoutMs });
    return true;
  } catch (e) {
    const inconclusive = e?.killed === true || e?.signal != null || e?.code === 'ETIMEDOUT';
    return inconclusive;
  }
}

// ═ Mode A: Staged Isolation ═

function cmdInit() {
  if (!isStaleActiveFlag(ACTIVE_FLAG)) {
    const err = new Error('Another create-pr session is in progress (active flag updated within 30 minutes).');
    err.details = { hint: 'Wait for the current session to complete or manually clear .tmp/create-pr-active and retry.' };
    throw err;
  }
  autoCleanup();

  const CI_MIRROR_STAMP = join(PROJECT_DIR, '.tmp', 'ci-mirror-passed');
  const STAMP_FRESHNESS_MS = 60 * 60 * 1000;
  let stampValid = false;
  if (existsSync(CI_MIRROR_STAMP)) {
    try {
      if (Date.now() - statSync(CI_MIRROR_STAMP).mtime.getTime() <= STAMP_FRESHNESS_MS) {
        stampValid = true;
      }
    } catch {}
  }
  if (!stampValid && makeTargetExists('q.ci-mirror', PROJECT_DIR)) {
    try {
      execFileSync('make', ['q.ci-mirror'], {
        cwd: PROJECT_DIR, stdio: 'pipe', encoding: 'utf-8', timeout: 600_000,
      });
    } catch (e) {
      const stdout = e.stdout || '';
      const stderr = e.stderr || '';
      const err = new Error(
        `CI mirror (make q.ci-mirror) failed. Fix issues manually or retry.\n\n[STDOUT]\n${stdout}\n[STDERR]\n${stderr}`
      );
      err.details = { stdout, stderr };
      throw err;
    }
  }

  const branch = git(['branch', '--show-current']);
  if (branch !== BASE_BRANCH) throw new Error(`Current branch is not ${BASE_BRANCH}: ${branch}`);

  const stagedFiles = git(['diff', '--cached', '--name-only']).split('\n').filter(Boolean);
  if (stagedFiles.length === 0) throw new Error('No staged files found.');

  const secretPattern = /\.(env|key|pem|p12|keystore)$|(^|\/)credentials\.json$|service-account/;
  const secrets = stagedFiles.filter(f => secretPattern.test(f));
  if (secrets.length) {
    const err = new Error(`Secret files detected: ${secrets.join(', ')}`);
    err.details = { secrets };
    throw err;
  }

  checkSshRemoteIfRequired();
  ghToken();

  const warnings = [];
  try {
    git(['fetch', 'origin', BASE_BRANCH], { timeout: 30_000, retry: 3 });
  } catch (e) {
    warnings.push(`Remote fetch failed: ${e.message}. Freshness unverified.`);
  }
  try {
    const localSha = git(['rev-parse', 'HEAD']);
    const remoteSha = git(['rev-parse', `origin/${BASE_BRANCH}`]);
    if (localSha !== remoteSha) {
      const ahead = parseInt(git(['rev-list', '--count', `origin/${BASE_BRANCH}..HEAD`]) || '0', 10);
      const behind = parseInt(git(['rev-list', '--count', `HEAD..origin/${BASE_BRANCH}`]) || '0', 10);
      if (ahead > 0) {
        throw new Error(
          `Local ${BASE_BRANCH} is ahead of origin/${BASE_BRANCH} by ${ahead} commit(s). ` +
          `Push/PR pending commits first before retrying.`
        );
      }
      if (behind > 0) {
        warnings.push(
          `Local ${BASE_BRANCH} is behind origin/${BASE_BRANCH} by ${behind} commit(s). ` +
          `finalize will automatically sync via ff-merge.`
        );
      }
    }
  } catch (e) {
    if (e.message.includes('ahead of')) throw e;
    warnings.push(`Freshness comparison failed: ${e.message}`);
  }

  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(join(STATE_DIR, '.gitignore'), '*\n');
  writeFileSync(PATCH_FILE, exec(['git', 'diff', '--cached', '--binary'], { raw: true }));
  writeFileSync(ACTIVE_FLAG, String(Date.now()));

  return { ok: true, stagedFiles, baseCommit: git(['rev-parse', 'HEAD']), warnings };
}

function cmdIsolate(args) {
  const branchName = requireArg(args, 'branch');
  if (!existsSync(PATCH_FILE)) throw new Error('Run init first.');

  git(['worktree', 'add', '-b', branchName, WT_DIR, 'HEAD']);
  writeFileSync(BRANCH_FILE, branchName);
  git(['apply', '--index', PATCH_FILE], { cwd: WT_DIR });

  writeFileSync(ACTIVE_FLAG, String(Date.now()));
  return { ok: true, branch: branchName, worktreeDir: WT_DIR };
}

function cmdCommit(args) {
  const message = requireArg(args, 'message');
  const files = (typeof args.files === 'string') ? args.files.split(',') : null;
  if (!existsSync(WT_DIR)) throw new Error('No worktree found. Run isolate first.');

  writeFileSync(MSG_FILE, message);
  const cmdArgs = files
    ? ['commit', '--only', '-F', MSG_FILE, '--', ...files]
    : ['commit', '-F', MSG_FILE];
  git(cmdArgs, { cwd: WT_DIR });

  writeFileSync(ACTIVE_FLAG, String(Date.now()));
  return { ok: true, sha: git(['rev-parse', 'HEAD'], { cwd: WT_DIR }).slice(0, 7) };
}

/**
 * Idempotent PR creation: Reuses open PR with same head and updates title/body.
 */
export function getOrCreatePr({ base, head, title, body, repo }, ghFn = gh) {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(BODY_FILE, body);

  const findExistingPr = () => {
    const existing = ghFn([
      'pr', 'list', '--repo', repo, '--head', head, '--state', 'open',
      '--json', 'number,url',
    ]);
    const parsed = JSON.parse(existing);
    return Array.isArray(parsed) && parsed.length > 0
      ? { prNumber: parsed[0].number, prUrl: parsed[0].url }
      : null;
  };
  const useExisting = (found) => {
    try {
      ghFn(['pr', 'edit', String(found.prNumber), '--repo', repo, '--title', title, '--body-file', BODY_FILE]);
    } catch {}
    return { prNumber: found.prNumber, prUrl: found.prUrl, existing: true };
  };

  try {
    const found = findExistingPr();
    if (found) return useExisting(found);
  } catch {
    /* Detection failed — fallback to already-exists handler in pr create */
  }

  try {
    const url = ghFn([
      'pr', 'create', '--repo', repo, '--base', base, '--head', head,
      '--title', title, '--body-file', BODY_FILE,
    ]);
    const prNumber = parseInt(url.match(/\/pull\/(\d+)/)?.[1] || '0', 10);
    if (!prNumber) throw new Error(`Failed to parse PR number: ${url}`);
    return { prNumber, prUrl: url, existing: false };
  } catch (e) {
    if (/already exists/i.test(String(e && e.message))) {
      try {
        const recovered = findExistingPr();
        if (recovered) return useExisting(recovered);
      } catch {
        /* Recovery failed */
      }
    }
    throw e;
  }
}

export function waitMergeable(prNumber, repo, { ghFn = gh, sleepFn = null } = {}) {
  let waited = 0;
  while (waited < MERGEABLE_TIMEOUT_MS) {
    const state = ghFn([
      'pr', 'view', String(prNumber), '--repo', repo,
      '--json', 'mergeStateStatus', '--jq', '.mergeStateStatus',
    ]);
    if (state === 'CLEAN' || state === 'UNSTABLE') return { mergeable: true, state };
    // DIRTY (merge conflict) never resolves by waiting — return immediately so the caller's
    // auto-sync/conflict-resolution branch (state === 'DIRTY') can fire. Without this early
    // return the loop polled to TIMEOUT and that recovery path was dead code (observed 2026-08-26).
    if (state === 'BLOCKED' || state === 'BEHIND' || state === 'DIRTY') return { mergeable: false, state };
    if (sleepFn) sleepFn(MERGEABLE_POLL_MS);
    else execFileSync('sleep', [String(MERGEABLE_POLL_MS / 1000)]);
    waited += MERGEABLE_POLL_MS;
  }
  return { mergeable: false, state: 'TIMEOUT' };
}

const PASSING_CONCLUSIONS = new Set(['SUCCESS', 'SKIPPED', 'NEUTRAL']);

/**
 * Reduces a PR's `statusCheckRollup` to passed | failed | pending. A re-run leaves the superseded
 * run in the rollup (a CANCELLED next to its SUCCESS), so only the latest start per check counts.
 * No checks at all is pending, not passed: right after the push they are not registered yet.
 * A queued run has no startedAt yet and is the newest of its check.
 */
export function checksVerdict(rollup) {
  const latest = new Map();
  const started = (c) => c.startedAt || '\uffff';
  for (const c of rollup ?? []) {
    const key = `${c.workflowName ?? ''}/${c.name ?? c.context}`;
    const prev = latest.get(key);
    if (!prev || started(c) >= started(prev)) latest.set(key, c);
  }
  if (latest.size === 0) return { state: 'pending', failed: [] };
  const failed = [];
  let pending = false;
  for (const [key, c] of latest) {
    const done = c.__typename === 'StatusContext' ? c.state !== 'PENDING' && c.state !== 'EXPECTED' : c.status === 'COMPLETED';
    if (!done) pending = true;
    else if (!PASSING_CONCLUSIONS.has(c.conclusion ?? c.state)) failed.push(key);
  }
  if (failed.length) return { state: 'failed', failed };
  return { state: pending ? 'pending' : 'passed', failed };
}

/**
 * Waits for the PR's CI to finish and pass. mergeStateStatus cannot be this signal: with no required
 * checks (branch protection is unavailable on a free private repo) it reads CLEAN before a check is
 * registered and UNSTABLE while checks run or fail, and waitMergeable merges on both. PRs #5 and
 * #9–#17 each landed seconds before their own CI, gitleaks included, had finished.
 *
 * The rollup only counts while GitHub's PR head is `headSha`: right after a push it can still
 * describe the previous head, whose green checks say nothing about the tree being merged.
 */
export function waitChecks(prNumber, repo, headSha, { ghFn = gh, sleepFn = null } = {}) {
  let waited = 0;
  for (;;) {
    const pr = JSON.parse(ghFn([
      'pr', 'view', String(prNumber), '--repo', repo, '--json', 'headRefOid,statusCheckRollup',
    ]) || '{}');
    const verdict = pr.headRefOid === headSha ? checksVerdict(pr.statusCheckRollup) : { state: 'pending' };
    if (verdict.state === 'passed') return { passed: true, state: 'CHECKS_PASSED' };
    if (verdict.state === 'failed') return { passed: false, state: `CHECKS_FAILED: ${verdict.failed.join(', ')}` };
    if (waited >= MERGEABLE_TIMEOUT_MS) return { passed: false, state: 'CHECKS_TIMEOUT' };
    if (sleepFn) sleepFn(MERGEABLE_POLL_MS);
    else execFileSync('sleep', [String(MERGEABLE_POLL_MS / 1000)]);
    waited += MERGEABLE_POLL_MS;
  }
}

/** A repo without workflows has no CI to wait for (scaffolded targets, R-CM-028). */
function hasWorkflows(dir) {
  const wf = join(dir, '.github', 'workflows');
  return existsSync(wf) && readdirSync(wf).some((f) => /\.ya?ml$/.test(f));
}

function createAndMergePr({
  base, head, title, body, deleteBranch = null, noMerge = false, worktreeDir = null,
  forceQualityGate = false,
}) {
  const repo = resolveRepo();
  const { prNumber, prUrl, existing } = getOrCreatePr({ base, head, title, body, repo });

  if (noMerge) {
    return { prNumber, prUrl, merged: false, pending: true, existing };
  }

  let { mergeable, state } = waitMergeable(prNumber, repo);
  if (!mergeable && worktreeDir && (state === 'BEHIND' || state === 'DIRTY' || state === 'BLOCKED')) {
    console.log(`[create-pr] PR #${prNumber} is not mergeable (${state}). Attempting automatic sync and retry.`);
    try {
      git(['fetch', 'origin', base], { cwd: worktreeDir, timeout: 30_000, retry: 3 });
      let syncSuccess = false;
      try {
        git(['merge', '--no-edit', `origin/${base}`], { cwd: worktreeDir });
        console.log(`[create-pr] Local merge succeeded.`);
        syncSuccess = true;
      } catch (_mergeErr) {
        console.log(`[create-pr] Local merge conflict detected. Attempting auto-resolution...`);
        const conflictingFiles = git(['diff', '--name-only', '--diff-filter=U'], { cwd: worktreeDir })
          .trim()
          .split('\n')
          .filter(Boolean);
        
        const resolved = tryAutoResolveConflicts(worktreeDir, conflictingFiles);
        if (resolved) {
          const hasMakefile = existsSync(join(worktreeDir, 'Makefile'));
          const validateCmd = hasMakefile ? 'make q.check' : (existsSync(join(worktreeDir, 'package.json')) ? 'npm test' : null);
          if (validateCmd) {
            console.log(`[create-pr] Conflict resolved. Running validation (${validateCmd})...`);
            try {
              exec(validateCmd.split(' '), { cwd: worktreeDir });
              console.log(`[create-pr] Validation passed!`);
              syncSuccess = true;
            } catch (_gateErr) {
              console.error(`[create-pr] Validation failed. Aborting merge.`);
              try { git(['merge', '--abort'], { cwd: worktreeDir }); } catch {}
            }
          } else {
            console.log(`[create-pr] Conflict resolved. Skipping validation.`);
            syncSuccess = true;
          }
        } else {
          try { git(['merge', '--abort'], { cwd: worktreeDir }); } catch {}
        }
      }

      if (syncSuccess) {
        git(['push', 'origin', head], { cwd: worktreeDir, timeout: PUSH_TIMEOUT_MS, retry: 3 });
        console.log(`[create-pr] Updated branch pushed. Re-checking PR status...`);
        const retryResult = waitMergeable(prNumber, repo);
        mergeable = retryResult.mergeable;
        state = retryResult.state;
      }
    } catch (syncErr) {
      console.error(`[create-pr] Error during automatic sync attempt: ${syncErr.message}`);
    }
  }

  // Second site where ship mutates the branch tree after the PROOF was validated — the sync above
  // runs when GitHub reports BEHIND/DIRTY/BLOCKED and merges the base in exactly like cmdShipWorktree does.
  //
  // Asserted *after* the try/catch rather than before the sync push: that catch deliberately swallows
  // failures into a console line, and a swallowed PROOF violation would merge anyway. Pushing an
  // uncertified tree to the feature branch is harmless — nothing consumes it — whereas landing it on
  // the trunk is not, and this throws before the merge call below.
  if (worktreeDir) assertQualityGateFreshAfterBaseMerge(worktreeDir, forceQualityGate);

  // After the sync above, so a re-pushed head is judged by its own checks. The merge below names
  // the same sha, so GitHub refuses it if the head moved after the checks were read.
  const headSha = worktreeDir ? git(['rev-parse', 'HEAD'], { cwd: worktreeDir }).trim() : null;
  if (mergeable && worktreeDir && hasWorkflows(worktreeDir)) {
    ({ passed: mergeable, state } = waitChecks(prNumber, repo, headSha));
  }

  if (!mergeable) {
    return {
      prNumber, prUrl, merged: false, pending: true, existing,
      warnings: [`PR #${prNumber} automatic merge deferred (${state}). Re-run ship once CI passes, or merge manually after CI/review passes.`],
    };
  }

  const resp = JSON.parse(gh([
    'api', '--method', 'PUT',
    '-H', 'Accept: application/vnd.github+json',
    `/repos/${repo}/pulls/${prNumber}/merge`,
    '-f', `merge_method=squash`,
    ...(headSha ? ['-f', `sha=${headSha}`] : []),
  ]));
  if (!resp.merged) throw new Error(`PR #${prNumber} merge failed`);

  if (deleteBranch) {
    try { gh(['api', '--method', 'DELETE', `/repos/${repo}/git/refs/heads/${deleteBranch}`]); } catch {}
  }

  const changed_files = collectChangedFilesViaPr(prNumber, repo, { worktreeDir, baseBranch: base });
  const changed_files_tree = buildFileTree(changed_files);
  const warnings = [];
  const followupDebt = registerFollowupDebtFromPr(prNumber);
  warnings.push(...followupDebt.warnings);

  return {
    prNumber, prUrl, sha: resp.sha, merged: true, pending: false, existing,
    changed_files, changed_files_tree, warnings,
    followup_debt_registered: { count: followupDebt.count, items: followupDebt.items },
  };
}

function cmdShipFeature(args) {
  const branch = readBranch();
  const title = requireArg(args, 'title');
  const body = resolveBodyArg(args);
  const noMerge = args['no-merge'] === true;

  // Taken before the push, like cmdShipWorktree: the label and scale describe what is being shipped.
  const qualitySnapshot = collectShipQualitySnapshot({ absWtPath: WT_DIR, branch, baseBranch: BASE_BRANCH });

  git(['push', '-u', 'origin', branch], { cwd: WT_DIR, timeout: PUSH_TIMEOUT_MS, retry: 3 });
  writeFileSync(ACTIVE_FLAG, String(Date.now()));

  const result = createAndMergePr({
    base: BASE_BRANCH, head: branch, title, body,
    deleteBranch: noMerge ? null : branch,
    noMerge,
    worktreeDir: WT_DIR,
  });

  if (result.merged) unlinkShipReviewMarker('staged');

  // Mode A merges into the same trunk as Mode B but wrote no ledger row, so every PR shipped through
  // this documented path was a permanent gap — and, now that the trunk is reconciled against the
  // ledger, would be reported as a gate bypass.
  const ledgerWarnings = recordShipQualityAndDetectStreak({
    pr: result.prNumber ?? null,
    branch,
    snapshot: qualitySnapshot,
    result,
  });

  return { ok: true, ...result, warnings: [...(result.warnings ?? []), ...ledgerWarnings, ...syncApprovalTrust()] };
}

function cmdFinalize() {
  const localBranch = existsSync(BRANCH_FILE) ? readFileSync(BRANCH_FILE, 'utf-8').trim() : null;
  if (existsSync(WT_DIR)) {
    try { git(['worktree', 'remove', WT_DIR, '--force']); } catch {}
    try { git(['worktree', 'prune']); } catch {}
  }
  if (localBranch) deleteBranchAndStashes(localBranch);

  const cleanupState = () => {
    rmSync(STATE_DIR, { recursive: true, force: true });
    try { if (existsSync(ACTIVE_FLAG)) rmSync(ACTIVE_FLAG); } catch {}
  };

  try {
    git(['fetch', '--prune', 'origin', BASE_BRANCH], { timeout: 60_000, retry: 3 });
  } catch (e) {
    cleanupState();
    return {
      ok: false, error: `Sync fetch failed: ${e.message}`,
      hint: 'Check remote (git remote -v). After restoring network, run git fetch + git merge --ff-only manually.',
      worktree_cleaned: true, sync_status: 'fetch_failed',
    };
  }

  const hasChanges = git(['status', '--porcelain']).trim().length > 0;
  if (hasChanges) {
    cleanupState();
    return {
      ok: false,
      error: 'Cannot proceed with sync because local uncommitted changes exist.',
      hint: 'Manually commit or stash changes before syncing again.',
      worktree_cleaned: true,
      sync_status: 'local_changes',
    };
  }

  let ffFailed = null;
  try {
    git(['checkout', BASE_BRANCH]);
    git(['merge', '--ff-only', `origin/${BASE_BRANCH}`]);
  } catch (e) {
    ffFailed = `${BASE_BRANCH} ff-only failed: ${e.message}`;
  }

  cleanupState();

  if (ffFailed) {
    return {
      ok: false, error: ffFailed,
      hint: `origin/${BASE_BRANCH} is not an ancestor of local ${BASE_BRANCH} (non-fast-forward). Check git log and rebase manually.`,
      sync_status: 'ff_failed',
    };
  }
  return { ok: true, sync_status: 'synced' };
}

// ═ Mode B: Worktree ═

const SUPERSET_MAX_FILES = 5;
const SUPERSET_MAX_SUBJECT = 80;

const splitNonEmptyLines = (s) => String(s).split('\n').map((line) => line.trim()).filter(Boolean);

function parseNameOnlyLog(logOutput) {
  const blocks = [];
  for (const raw of String(logOutput).split('\0')) {
    const lines = splitNonEmptyLines(raw);
    if (lines.length === 0) continue;
    blocks.push({ fields: lines[0].split('\t'), files: lines.slice(1) });
  }
  return blocks;
}

function truncateSubject(subject) {
  return subject.length > SUPERSET_MAX_SUBJECT
    ? subject.slice(0, SUPERSET_MAX_SUBJECT) + '…'
    : subject;
}

function myChangedFiles(absWtPath, baseBranch, gitFn) {
  return splitNonEmptyLines(
    gitFn(['diff', '--name-only', `origin/${baseBranch}...HEAD`], { cwd: absWtPath }),
  );
}

/**
 * Detects whether recently landed commits on origin/<baseBranch> touched the same files.
 * Only commits HEAD does not already contain count: a merge the branch was cut after is its
 * base, not something it could supersede.
 */
export function detectExternalSupersetRisk(absWtPath, baseBranch, gitFn = git) {
  try {
    const myFiles = myChangedFiles(absWtPath, baseBranch, gitFn);
    if (myFiles.length === 0) return null;

    const blocks = parseNameOnlyLog(
      gitFn(
        [
          'log', `HEAD..origin/${baseBranch}`, '--since=24.hours.ago',
          '--name-only', '--format=%x00%H%x09%s',
        ],
        { cwd: absWtPath },
      ),
    );
    if (blocks.length === 0) return null;

    const myFileSet = new Set(myFiles);
    const overlaps = [];
    for (const { fields, files } of blocks) {
      const [sha, ...subjectParts] = fields;
      const subject = subjectParts.join('\t');
      if (!sha || !subject) continue;
      const intersection = files.filter((f) => myFileSet.has(f));
      if (intersection.length > 0) {
        overlaps.push({
          sha: sha.slice(0, 7),
          subject: truncateSubject(subject),
          files: intersection.slice(0, SUPERSET_MAX_FILES),
        });
      }
    }
    return overlaps.length > 0 ? overlaps : null;
  } catch {
    return null;
  }
}

/**
 * Detects whether unpushed local branches touched the same files.
 */
export function detectLocalBranchSupersetRisk(absWtPath, baseBranch, gitFn = git) {
  try {
    const myFiles = myChangedFiles(absWtPath, baseBranch, gitFn);
    if (myFiles.length === 0) return null;

    const blocks = parseNameOnlyLog(
      gitFn(
        [
          'log', '--branches', '--not', `origin/${baseBranch}`, 'HEAD',
          '--source', '--name-only', '--format=%x00%S%x09%H%x09%s',
        ],
        { cwd: absWtPath },
      ),
    );
    if (blocks.length === 0) return null;

    const myFileSet = new Set(myFiles);
    const overlaps = [];
    for (const { fields, files } of blocks) {
      const [branch, sha, ...subjectParts] = fields;
      const subject = subjectParts.join('\t');
      if (!branch || !sha || !subject) continue;
      const intersection = files.filter((f) => myFileSet.has(f));
      if (intersection.length > 0) {
        overlaps.push({
          branch,
          sha: sha.slice(0, 7),
          subject: truncateSubject(subject),
          files: intersection.slice(0, SUPERSET_MAX_FILES),
        });
      }
    }
    return overlaps.length > 0 ? overlaps : null;
  } catch {
    return null;
  }
}

/**
 * `superset_check_local_branches` in create-pr/config.json (default true). Only an explicit `false`
 * turns the unpushed-local-branch check off; the trunk-side check always runs.
 */
export function localBranchSupersetCheckEnabled(cfg) {
  return cfg?.superset_check_local_branches !== false;
}

/**
 * Ship-time superset warnings: trunk-side (always) + unpushed local branches (opt-out via config).
 */
export function collectSupersetWarnings(absWtPath, baseBranch, { checkLocalBranches = true, gitFn = git } = {}) {
  const warnings = [
    formatSupersetWarning(detectExternalSupersetRisk(absWtPath, baseBranch, gitFn), baseBranch),
  ];
  if (checkLocalBranches) {
    warnings.push(
      formatLocalSupersetWarning(detectLocalBranchSupersetRisk(absWtPath, baseBranch, gitFn), baseBranch),
    );
  }
  return warnings.filter(Boolean);
}

export function tryAutoResolveConflicts(absWtPath, conflictingFiles) {
  if (!conflictingFiles || conflictingFiles.length === 0) return true;

  console.log(`[auto-resolve] Conflicting files detected: ${conflictingFiles.join(', ')}`);

  const LOCKFILE_PATTERNS = [/package-lock\.json$/, /pnpm-lock\.yaml$/, /yarn\.lock$/];
  const WORKTREE_PRIVATE_PATTERNS = [/\.tmp\/worktree-.*\/PLAN\.md$/];

  const isLockfile = (file) => LOCKFILE_PATTERNS.some((pattern) => pattern.test(file));
  const isWorktreePrivate = (file) =>
    WORKTREE_PRIVATE_PATTERNS.some((pattern) => pattern.test(file));
  const unresolvable = conflictingFiles.filter(
    (file) => !isLockfile(file) && !isWorktreePrivate(file),
  );

  if (unresolvable.length > 0) {
    console.log(`[auto-resolve] Non-auto-resolvable files found: ${unresolvable.join(', ')}`);
    console.log(
      `[auto-resolve] Reconcile manually: .claude/skills/create-pr/references/merge-conflict-resolution.md`,
    );
    return false;
  }

  try {
    for (const file of conflictingFiles) {
      if (isLockfile(file)) {
        console.log(`[auto-resolve] Resolving ${file}: selecting --theirs and regenerating package lock`);
        git(['checkout', '--theirs', file], { cwd: absWtPath });
        if (file.endsWith('package-lock.json')) {
          try { exec(['npm', 'install'], { cwd: absWtPath }); } catch {}
        } else if (file.endsWith('pnpm-lock.yaml')) {
          try { exec(['pnpm', 'install'], { cwd: absWtPath }); } catch {}
        } else if (file.endsWith('yarn.lock')) {
          try { exec(['yarn', 'install'], { cwd: absWtPath }); } catch {}
        }
        git(['add', file], { cwd: absWtPath });
      } else {
        console.log(`[auto-resolve] Resolving ${file}: selecting --ours`);
        git(['checkout', '--ours', file], { cwd: absWtPath });
        git(['add', file], { cwd: absWtPath });
      }
    }

    const remaining = git(['diff', '--name-only', '--diff-filter=U'], { cwd: absWtPath }).trim();
    if (remaining.length > 0) {
      console.log(`[auto-resolve] Unresolved conflicts remain: ${remaining}`);
      return false;
    }

    git(['commit', '--no-edit'], { cwd: absWtPath });
    console.log(`[auto-resolve] All conflicts resolved automatically; merge commit created.`);
    return true;
  } catch (err) {
    console.error(`[auto-resolve] Error during conflict resolution: ${err.message}`);
    return false;
  }
}

export function formatSupersetWarning(overlaps, baseBranch) {
  if (!overlaps || overlaps.length === 0) return null;
  const lines = overlaps
    .map((o) => `  ${o.sha} ${o.subject} (${o.files.join(', ')})`)
    .join('\n');
  return `multi-worktree superset risk: ${overlaps.length} recent 24h merge(s) on origin/${baseBranch} touched files modified in this worktree. This PR may be redundant or silently superset-absorbed — verify your intent before proceeding.\n${lines}`;
}

export function formatLocalSupersetWarning(overlaps, baseBranch) {
  if (!overlaps || overlaps.length === 0) return null;
  const branches = [...new Set(overlaps.map((o) => o.branch))];
  const lines = overlaps
    .map((o) => `  ${o.branch} ${o.sha} ${o.subject} (${o.files.join(', ')})`)
    .join('\n');
  return `multi-worktree superset risk (${branches.length} unpushed local branch(es)): ${overlaps.length} local commit(s) not yet on origin/${baseBranch} touched the same files as this worktree. Merging this PR may silently absorb or conflict with that work — decide whether to reconcile with the worktree owner before proceeding.\n${lines}`;
}

export function shouldRecordShipQuality(result) {
  return result?.merged === true;
}

/**
 * Appends the ship row and reports what the ledger and the trunk now say.
 *
 * Returns warnings (possibly empty) rather than one string, because a failed write is a different
 * fact from a skip streak. The append used to sit in a bare `catch {}`; a silently dropped row is
 * indistinguishable from a gate bypass to the trunk reconciliation, which would then report this
 * process's own failure as someone else's merge. Never throws: the merge already happened, and
 * failing now would leave the caller unable to tell which half succeeded.
 *
 * @returns {string[]}
 */
export function recordShipQualityAndDetectStreak({
  pr,
  branch,
  snapshot,
  result,
  nowIso = new Date().toISOString(),
  readLedgerFn = readLedger,
  readLandingsFn = () => readTrunkLandings(BASE_BRANCH, (args) => git(args, { cwd: PROJECT_DIR })),
  appendFn = (record) => appendJsonlAtomicSync(ledgerPath(), record),
}) {
  if (!shouldRecordShipQuality(result)) return [];
  const record = buildShipRecord({
    ...snapshot,
    pr,
    branch,
    at: nowIso,
    merge_sha: typeof result?.sha === 'string' ? result.sha : null,
  });
  const warnings = [];
  let prior;
  try {
    // Read before appending: the reconciliation must see the ledger as it stood before this ship.
    prior = readLedgerFn();
  } catch (e) {
    warnings.push(`ship quality ledger could not be read (${e?.message ?? e}); streak check skipped.`);
  }
  const writeFailure = appendShipRecord(appendFn, record, pr);
  if (writeFailure) warnings.push(writeFailure);
  if (prior !== undefined) warnings.push(...detectStreakOverTrunk(prior, record, readLandingsFn));
  // Kept branch-free on purpose: this function sits at the complexity ratchet's ceiling.
  warnings.push(formatCurrentShipNote(record, { proofPath: snapshot?.proof_path }));
  return warnings.filter(Boolean);
}

/** Appends `record`; returns a warning when the write failed, null otherwise. */
function appendShipRecord(appendFn, record, pr) {
  try {
    appendFn(record);
    return null;
  } catch (e) {
    let where = 'the ship quality ledger';
    try {
      where = ledgerPath();
    } catch {
      /* path unresolvable — keep the generic name */
    }
    return (
      `ship quality ledger write FAILED (${e?.message ?? e}) at ${where}. PR #${pr} merged, but no ` +
      'row was recorded — the trunk reconciliation will report this merge as a landing with no ledger ' +
      'row until the row is restored. Fix the path and append the row manually.'
    );
  }
}

/**
 * Streak + bypass census for the ship that just merged.
 *
 * `record` is appended after the reconciliation rather than joined by it: GitHub merged server-side
 * and nothing fetched since, so its squash commit is not in the local `origin/<base>` and joining would
 * drop this ship from its own streak. The census (`unrecorded`) is computed without it, since a newest
 * recorded entry would bury every earlier bypass by construction.
 */
function detectStreakOverTrunk(prior, record, readLandingsFn) {
  const warnings = [];
  try {
    const landings = readLandingsFn();
    const trunk = assessTrunk({ ledger: prior, landings });
    if (!trunk.trunkRead) {
      warnings.push(
        `trunk (origin/${BASE_BRANCH}) could not be read — the gate-bypass check did not run for this ` +
          'ship. The streak below counts ledger rows only.',
      );
    }
    const streak = formatStreakWarning({
      ...countCrossReviewSkipStreak([...trunk.entries, record]),
      unrecorded: trunk.unrecorded,
      unrecordedTotal: trunk.unrecordedTotal,
    });
    if (streak) warnings.push(streak);
  } catch (e) {
    warnings.push(`ship quality ledger check failed: ${e?.message ?? e}`);
  }
  return warnings;
}

function readProofLabel(absWtPath) {
  try {
    const proof = readQualityGateRecord(absWtPath);
    return { quality_label: proof.record?.quality_label ?? null, proof_path: proof.path ?? null };
  } catch {
    return { quality_label: null, proof_path: null }; /* Missing PROOF */
  }
}

export function collectShipQualitySnapshot({
  absWtPath,
  branch,
  baseBranch,
  gitFn = git,
  projectDir = PROJECT_DIR,
  existsFn = existsSync,
  readdirFn = readdirSync,
}) {
  let scale = null;
  try {
    scale = measureWorktreeDiffScale({ absWtPath, baseBranch, gitFn }).scale;
  } catch {
    /* Scale determination failure */
  }
  const { quality_label, proof_path } = readProofLabel(absWtPath);
  let milestone_deck = false;
  try {
    milestone_deck = hasMilestoneDeck({ branch, projectDir, existsFn, readdirFn });
  } catch {
    /* fs error */
  }
  // proof_path is not a ledger field — it only names where a null label was looked for.
  return { scale, quality_label, milestone_deck, proof_path, ...readMarkerApproval(absWtPath) };
}

/**
 * Persists escapes found in trunk history so they outlive the scan window, and names new ones.
 * Runs after the merge; never throws (same contract as the ledger append above).
 */
export function syncApprovalTrust({
  loadPolicyFn = () => loadApprovalPolicy(PROJECT_DIR),
  loadTrustFn = loadTrust,
  saveFn = saveTrustStore,
  readLedgerFn = readLedger,
} = {}) {
  try {
    // No policy, or one without `escape` (the scaffold copy carries ui/stage only): escape tracking
    // is not enabled here. P1's missing policy already surfaces as the ship gate's T2 `no_policy`.
    const { policy } = loadPolicyFn();
    if (!policy?.raw?.escape) return [];
    const trust = loadTrustFn({
      projectDir: PROJECT_DIR,
      baseBranch: BASE_BRANCH,
      ledger: readLedgerFn(),
      policy,
      runGit: (args) => git(args, { cwd: PROJECT_DIR }),
    });
    if (!trust.added.length) return [];
    saveFn(trust.storePath, trust.store);
    return [
      `approval escape(s) detected: ${trust.added.map((e) => `${e.id} [${e.areas.join(', ')}]`).join('; ')} — ` +
        'these areas now need human approval until a prevention guard is registered ' +
        '(node .claude/scripts/approval-trust.mjs status).',
    ];
  } catch (e) {
    return [`approval trust sync failed: ${e?.message ?? e}`];
  }
}

/**
 * Pulls the human's Pre-Ship answer into the Trust ledger (`Scripts/trust/trust.mjs reconcile`)
 * while the answer store still exists. Cleanup deletes it, so a reconcile run after the ship had
 * nothing to read and the human decision was lost (PR #11). Answers written by `trust approve`
 * are already in the ledger.
 *
 * Runs before the push and throws on failure: a warning would let the merge and cleanup go ahead
 * and lose the answer again. The CLI is the main checkout's, never the branch's own copy — the
 * evaluator must not be one the change under review can edit.
 *
 * @returns {'recorded'|'no_answer'|'trust_answer'|'no_trust_cli'}
 */
export function reconcileTrustLedger(absWtPath, branch, {
  mainRoot = dirname(git(['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: absWtPath })),
  existsFn = existsSync,
  run = execFileSync,
} = {}) {
  const cli = join(mainRoot, 'Scripts', 'trust', 'trust.mjs');
  if (!existsFn(cli)) return 'no_trust_cli';
  const answer = readAnswerStore(answerStorePath(absWtPath, branch)).approval;
  if (!answer?.value) return 'no_answer';
  if (answer.source === 'trust') return 'trust_answer';
  try {
    run(process.execPath, [cli, 'reconcile', '--worktree', absWtPath], {
      cwd: mainRoot, stdio: 'pipe', timeout: 30_000, env: withoutInheritedRepository(),
    });
  } catch (e) {
    const reason = e?.stderr?.toString().trim() || e?.message || String(e);
    throw new Error(
      `Trust ledger reconcile failed, so the human approval would be lost at cleanup: ${reason}\n` +
        `Fix it and re-run, or record it first: node ${cli} reconcile --worktree ${absWtPath}`,
    );
  }
  return 'recorded';
}

/** How the marker says this ship was approved (`mark-pre-ship-confirmed`); nulls when unstamped. */
function readMarkerApproval(absWtPath) {
  try {
    const marker = JSON.parse(readFileSync(shipReviewMarkerPath(absWtPath), 'utf-8'));
    return { approval: marker?.approval_mode ?? null, risk_tier: marker?.risk_tier ?? null };
  } catch {
    return { approval: null, risk_tier: null };
  }
}

export function measureWorktreeDiffScale({ absWtPath, baseBranch, gitFn = git }) {
  const numstatText = gitFn(['diff', '--numstat', `origin/${baseBranch}...HEAD`], {
    cwd: absWtPath,
  });
  let files = 0;
  let loc = 0;
  for (const line of numstatText.split('\n')) {
    const m = line.trim().match(/^(\d+|-)\t(\d+|-)\t(.+)$/);
    if (!m) continue;
    files += 1;
    if (m[1] !== '-') loc += Number(m[1]);
    if (m[2] !== '-') loc += Number(m[2]);
  }
  return { files, loc, ...classifyScale({ files, loc }) };
}

export function hasMilestoneDeck({
  branch,
  projectDir = PROJECT_DIR,
  existsFn = existsSync,
  readdirFn = readdirSync,
}) {
  const deckRoot = join(projectDir, '.tmp', 'review-deck', safeBranchKey(branch));
  return (
    existsFn(deckRoot) &&
    readdirFn(deckRoot).some(
      (d) => String(d).startsWith('milestone-') && existsFn(join(deckRoot, d, 'index.html')),
    )
  );
}

export function detectMissingReviewDeckWarning({
  absWtPath,
  branch,
  baseBranch,
  gitFn = git,
  projectDir = PROJECT_DIR,
  existsFn = existsSync,
  readdirFn = readdirSync,
}) {
  try {
    const { files, loc, scale } = measureWorktreeDiffScale({ absWtPath, baseBranch, gitFn });
    if (scale !== 'large') return null;

    const key = safeBranchKey(branch);
    if (hasMilestoneDeck({ branch, projectDir, existsFn, readdirFn })) return null;

    const reminded = existsFn(resolveMilestoneReminderPath(absWtPath, branch));
    const head = `CP-MILESTONE review deck missing: Large change (${files} files, ${loc} LOC) but no .tmp/review-deck/${key}/milestone-*/ deck trace exists.`;
    return reminded
      ? `${head} Reminded during implementation but shipping without deck — next time run: ` +
          `node .claude/scripts/review-deck.mjs --stage milestone (R-CM-030 Rule 12).`
      : `${head} Reached threshold without prior reminder opportunity (informational — ship deck covers same scope). ` +
          `milestone-deck-warning notifies during active editing (R-CM-030 Rule 12).`;
  } catch {
    return null;
  }
}

export function detectBarMoveWarning({ absWtPath, baseBranch, gitFn = git }) {
  try {
    const diff = gitFn(['diff', `origin/${baseBranch}...HEAD`], { cwd: absWtPath });
    return formatBarMoveWarning(detectBarMove(diff));
  } catch {
    return null;
  }
}

function runStalenessAll(script) {
  try {
    const out = execFileSync('node', [script, '--all', '--json'], {
      cwd: PROJECT_DIR,
      encoding: 'utf8',
      timeout: 30_000,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return JSON.parse(out);
  } catch (err) {
    // --all exits 1 when any target is stale; its JSON is still on stdout.
    try {
      return JSON.parse(err.stdout);
    } catch {
      return null; // advisory only — never block a merge that already happened
    }
  }
}

/**
 * Names the recorded transplant targets this merge made stale (a stale bundle file is among changed_files),
 * with the re-transplant command. Only harness has the staleness checker (it is not transplanted), so this
 * is a no-op in targets. Without it, merged harness fixes sat unapplied downstream until someone happened to
 * run transplant-staleness — 3 of 4 recorded targets were stale unnoticed (2026-09-23). Re-transplanting
 * writes into another repository, so this reports; it never applies.
 */
export function detectTransplantTargetsMadeStale(changedFiles, { projectDir = PROJECT_DIR, run = runStalenessAll } = {}) {
  const script = join(projectDir, '.claude/scripts/transplant-staleness.mjs');
  if (!changedFiles || !changedFiles.length || !existsSync(script)) return [];
  const changed = new Set(changedFiles);
  return ((run(script) || {}).targets || [])
    .flatMap((t) => (t.bundles || []).map((b) => ({ target: t.target, ...b })))
    .map((b) => ({ ...b, hit: [...(b.changed || []), ...(b.added || [])].filter((f) => changed.has(f)) }))
    .filter((b) => b.stale && b.hit.length)
    .map((b) => `transplant target made stale by this merge: ${b.target} [${b.bundle}] (${b.hit.join(', ')}). ${staleTargetRemedy(b)}`);
}

/** A target that edited managed files has forked them: re-transplanting would discard those edits. */
function staleTargetRemedy(b) {
  const edited = b.locally_modified || [];
  if (edited.length) {
    return (
      `It edited ${edited.length} managed file(s) locally (${edited.slice(0, 3).join(', ')}${edited.length > 3 ? ', ...' : ''}); ` +
      `re-transplanting would discard them. Upstream those edits to harness first, or leave the target as a fork.`
    );
  }
  return (
    `Re-transplant after user confirmation (writes to that repo, from a worktree there): ` +
    `node .claude/scripts/transplant-bundle.mjs --bundle ${b.bundle} --target <worktree of ${b.target}>`
  );
}

export function mergeShipWarnings({
  result,
  supersetWarnings = [],
  preservationWarnings = [],
  runBundle = null,
  cleanupResult = null,
}) {
  return [
    ...(result.warnings || []),
    ...supersetWarnings,
    ...preservationWarnings,
    ...(runBundle?.warnings ?? []),
    ...(cleanupResult?.warnings ?? []),
  ];
}

export function composeCleanupHint({ cleanup = true, merged = false, wtPath, cleanupResult = null }) {
  if (!cleanup && merged) {
    return `worktree not cleaned up — run: node .claude/scripts/create-pr/ops.mjs cleanup-worktree --worktree ${wtPath}`;
  }
  const cr = cleanupResult ?? {};
  return cr.ok === false ? (cr.hint ?? null) : null;
}

export function composeShipResponse({
  result,
  supersetWarnings = [],
  preservationWarnings = [],
  runBundle = null,
  cleanupResult = null,
  cleanedUp = false,
  cleanup = true,
  wtPath,
  postMergeMainStatus = null,
  projectDir = PROJECT_DIR,
}) {
  const cr = cleanupResult ?? {};
  const mergedWarnings = mergeShipWarnings({
    result,
    supersetWarnings,
    preservationWarnings,
    runBundle,
    cleanupResult,
  });
  const cleanup_hint = composeCleanupHint({
    cleanup,
    merged: result.merged,
    wtPath,
    cleanupResult,
  });

  return {
    ok: true,
    ...result,
    warnings: mergedWarnings,
    cleanedUp,
    cleanup_sync_status: cr.sync_status ?? null,
    cleanup_hint,
    post_merge_main_status: postMergeMainStatus,
    run_bundle: runBundle,
    completion_report_markdown: buildPostApprovalCompletionReport({
      result: { ...result, warnings: mergedWarnings },
      cleanup,
      cleanedUp,
      cleanupResult,
      wtPath,
      postMergeMainStatus,
      // Project-localized report copy (.claude/config/pre-ship-review-panel-sections.json `labels`).
      labels: loadReviewPanelConfig(projectDir).labels,
    }),
  };
}

function runOutputCandidateRelPaths(absWtPath) {
  const pipelineRoot = getPipelineDataRoot();
  const pipelineRootName = basename(pipelineRoot);
  const candidates = [
    join(pipelineRootName, relative(pipelineRoot, dirname(getActiveRunPath()))),
    join(pipelineRootName, relative(pipelineRoot, getRunsRoot())),
  ];
  const isHarnessNative = absWtPath ? hasHarnessMarker(absWtPath) : false;
  if (isHarnessNative) {
    candidates.push('output', 'docs/pipeline-log');
  }
  return candidates;
}

function safeBundleName(value) {
  return String(value || 'worktree')
    .replace(/[^a-zA-Z0-9._-]+/g, '_')
    .replace(/^_+|_+$/g, '') || 'worktree';
}

function scanTreeStats(root) {
  let files = 0;
  let bytes = 0;
  function walk(current) {
    const stat = statSync(current);
    if (stat.isFile()) {
      files += 1;
      bytes += stat.size;
      return;
    }
    if (!stat.isDirectory()) return;
    for (const entry of readdirSync(current)) {
      walk(join(current, entry));
    }
  }
  walk(root);
  return { files, bytes };
}

export function detectRunOutputCandidates(absWtPath) {
  return runOutputCandidateRelPaths(absWtPath)
    .map((relPath) => ({ relPath, absPath: join(absWtPath, relPath) }))
    .filter((candidate) => existsSync(candidate.absPath));
}

export function preserveWorktreeRunOutputs(absWtPath, branch, options = {}) {
  const candidates = detectRunOutputCandidates(absWtPath);
  const warnings = [];
  if (candidates.length === 0) {
    return {
      ok: true,
      skipped: true,
      warnings: ['No run/output candidate paths to preserve.'],
      copied_paths: [],
      total_files: 0,
      total_bytes: 0,
    };
  }

  const createdAt = options.createdAt || new Date().toISOString();
  const timestamp = createdAt.replace(/[:.]/g, '-');
  const bundlePath = options.bundlePath || join(
    PROJECT_DIR,
    '.tmp',
    'run-bundles',
    `${safeBundleName(branch)}-${timestamp}`,
  );
  mkdirSync(bundlePath, { recursive: true });

  let headSha = null;
  try {
    headSha = git(['rev-parse', 'HEAD'], { cwd: absWtPath });
  } catch {
    warnings.push('Failed to resolve worktree HEAD sha — recorded manifest.head_sha=null.');
  }

  const copied = [];
  let totalFiles = 0;
  let totalBytes = 0;
  for (const candidate of candidates) {
    const dest = join(bundlePath, candidate.relPath);
    mkdirSync(dirname(dest), { recursive: true });
    cpSync(candidate.absPath, dest, { recursive: true, force: true });
    const stats = scanTreeStats(dest);
    totalFiles += stats.files;
    totalBytes += stats.bytes;
    copied.push({
      source: candidate.absPath,
      destination: dest,
      relative_path: candidate.relPath,
      files: stats.files,
      bytes: stats.bytes,
    });
  }

  const manifest = {
    schema_version: '1.0',
    created_at: createdAt,
    branch,
    base_branch: BASE_BRANCH,
    source_worktree: absWtPath,
    head_sha: headSha,
    copied,
    total_files: totalFiles,
    total_bytes: totalBytes,
    candidates_considered: runOutputCandidateRelPaths(absWtPath),
    exclusion_rules: [
      'Only known harness run/output roots are copied.',
      'node_modules, .git, and arbitrary .tmp contents are not candidate roots.',
    ],
  };
  const manifestPath = join(bundlePath, 'manifest.json');
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n', 'utf-8');

  return {
    ok: true,
    skipped: false,
    bundle_path: bundlePath,
    manifest_path: manifestPath,
    copied_paths: copied.map((entry) => entry.relative_path),
    total_files: totalFiles,
    total_bytes: totalBytes,
    warnings,
  };
}

function cmdVerifyPlan(args) {
  const wtPath = requireArg(args, 'worktree');
  const planPath = resolveWorktreePlanPath(resolveWorktreeAbsPath(wtPath));
  if (!existsSync(planPath)) throw new Error(`PLAN.md not found: ${planPath}`);
  const content = readFileSync(planPath, 'utf-8');
  const force = args.force === true;
  const unchecked = parseUnchecked(content);
  if (!force && unchecked.length > 0) {
    throw new Error(
      `There are ${unchecked.length} uncompleted tasks in PLAN.md:\n${unchecked.join('\n')}\n\n` +
      `※ Override: Use --force or mark items with (cancelled)/(dropped)/(deferred)/~~strikethrough~~`
    );
  }
  return {
    ok: true,
    message: unchecked.length === 0
      ? 'All PLAN checkboxes completed (or cancelled/ignored)'
      : `--force override: ignoring ${unchecked.length} uncompleted items`,
    unchecked_count: unchecked.length,
  };
}

/**
 * PROOF freshness message shown when ship itself moved HEAD by merging the base branch in.
 *
 * Kept distinct from the default wording because the two read as opposite accusations: the default
 * says "you committed after recording", which is bewildering to a human who committed nothing.
 * Here the mutator is this script.
 *
 * This path is machine-only. The human approval is bound to the branch's contributed diff
 * (`pre-ship-steps.mjs#resolveReviewDiffId`), which a base merge leaves untouched, so re-verifying
 * does not re-ask the human. That separation exists because it once did: with the approval bound to
 * HEAD, this same merge invalidated it and one ship consumed four approvals (observed 2026-08-27).
 */
const BASE_MERGE_STALE_REASON =
  `ship merged origin/${BASE_BRANCH} into the branch, so the tree that lands is no longer the tree ` +
  `the PROOF certified. The merge is intentionally kept — rolling it back would re-merge and ` +
  `re-stale on every attempt. Re-verify and retry; the human approval is unaffected.`;

/**
 * @param {string} absWtPath
 * @param {boolean} [force]
 * @param {string|null} [staleReason] Prepended to the staleness error to name what moved HEAD.
 * @param {(worktreePath: string) => string} [execFn] Test-injectable HEAD resolver.
 */
export function assertQualityGateNotNoGo(absWtPath, force = false, staleReason = null, execFn = undefined) {
  if (force) return;
  const { record, path } = readQualityGateRecord(absWtPath);
  if (!record) return;
  if (record.verdict === 'no_go') {
    throw new Error(
      `Pre-Ship Quality Gate verdict=no_go recorded: ${path}\n` +
      `Fix issues → re-evaluate verdict → re-record via record-quality-gate.mjs and retry.\n` +
      `※ User override: --force-quality-gate (reason required in Panel Decisions section)`
    );
  }
  const staleness = execFn
    ? checkQualityGateStaleness(record, absWtPath, execFn)
    : checkQualityGateStaleness(record, absWtPath);
  if (staleness.checked && staleness.stale) {
    throw new Error(
      `Pre-Ship Quality Gate PROOF is stale: ${path}\n` +
      (staleReason ? `${staleReason}\n` : '') +
      `New commit occurred after recorded HEAD ${staleness.recordedSha?.slice(0, 7) ?? '?'} ` +
      `(current HEAD ${staleness.currentSha?.slice(0, 7) ?? '?'}).\n` +
      `Re-evaluate verdict → re-record via record-quality-gate.mjs and retry.\n` +
      `※ User override: --force-quality-gate (reason required in Panel Decisions section)`
    );
  }
  // `checked && stale` silently passed every unresolved lookup — the one branch with no warning at
  // all. Since `mark-pre-ship-confirmed` shares this resolver, a load spike took both defences down
  // together and a stale PROOF would have shipped. Unresolved is not fresh; refuse it.
  if (staleness.unresolved === 'timeout') {
    throw new Error(
      `Pre-Ship Quality Gate PROOF freshness could not be verified: ${path}\n` +
      (staleReason ? `${staleReason}\n` : '') +
      `git HEAD lookup kept timing out, so the recorded HEAD ` +
      `${staleness.recordedSha?.slice(0, 7) ?? '?'} could not be compared against the current tree.\n` +
      `This is machine load, not a defect in the change — wait for load to drop (uptime) and retry. ` +
      `No re-recording needed.\n` +
      `※ User override: --force-quality-gate (reason required in Panel Decisions section)`
    );
  }
}

/**
 * Re-asserts PROOF freshness after a base-branch merge has mutated the worktree tree.
 *
 * Why this exists (observed 2026-08-25): `assertQualityGateNotNoGo` enforced the HEAD-sha binding
 * *before* `git merge origin/<base>`, and nothing re-checked afterwards — so ship invalidated the
 * very PROOF it had just enforced and shipped anyway. 3 of the last 30 merges landed a tree no gate
 * had seen; #1184's head commit is the literal evidence
 * (`Merge remote-tracking branch 'origin/main' into fix/skill-audit-round-1`).
 *
 * This is GitHub's "Require branches to be up to date before merging" enforced locally: Actions are
 * disabled repo-wide and a private free plan cannot set branch protection, so the merge-initiating
 * point is the only place the rule can live (same reasoning as `.husky/pre-push`).
 *
 * No-op when the merge changed nothing (`Already up to date`), which is the common case.
 */
export function assertQualityGateFreshAfterBaseMerge(absWtPath, force, deps = {}) {
  if (force) return;
  const { record } = readQualityGateRecord(absWtPath);
  if (record && record.verdict !== 'no_go') {
    const staleness = checkQualityGateStaleness(record, absWtPath);
    const diffStatus = contributedDiffStatusAfterBaseMerge(
      absWtPath,
      deps.diffIdFn ?? resolveReviewDiffId,
    );
    // R-CM-028: scaffolded targets receive this bundle but may not carry the CI mirror. Without the
    // runner there is nothing to measure, so they keep the original strict block rather than
    // silently shipping an unverified merged tree.
    const runnerPresent = deps.runCiMirror ? true : existsSync(join(absWtPath, CI_MIRROR_SCRIPT));
    if (staleness.checked && staleness.stale && diffStatus === 'same' && runnerPresent) {
      reverifyMergedTree(absWtPath, record, deps);
      return;
    }
  }
  assertQualityGateNotNoGo(absWtPath, force, BASE_MERGE_STALE_REASON);
}

/**
 * Command that certifies a tree. SSOT is `.husky/pre-push` — the same runner that gates the push a
 * few lines later, so a merged tree is judged by one standard rather than two.
 * `tests/unit/create-pr-reverify.test.mjs` fails if the two drift apart.
 */
const CI_MIRROR_SCRIPT = '.claude/scripts/ci-local-status.mjs';
export const CI_MIRROR_CMD = ['node', CI_MIRROR_SCRIPT, '--all', '--strikes'];

/** Fixed name so repeated re-verifications replace the entry instead of stacking duplicates. */
const SELF_REVERIFY_GATE = 'ship self re-verification after base merge';

/**
 * Budget for one full gate run. Deliberately its own constant rather than borrowing
 * `PUSH_TIMEOUT_MS`: the two happen to be equal today, but they bound unrelated things (a network
 * push vs. the whole local suite), so a future change to either must not silently move the other.
 * Measured range for `./.husky/pre-push` on this repo: 81s idle → 233s at 5.3x load.
 */
const CI_MIRROR_TIMEOUT_MS = 1_800_000;

function tailLines(text, n = 40) {
  return String(text || '').trimEnd().split('\n').slice(-n).join('\n');
}

/**
 * Earns the PROOF back on the tree the base merge just produced, instead of demanding that someone
 * had already certified a tree that did not exist yet.
 *
 * The old contract was unsatisfiable in one pass: ship merges the base, which moves HEAD, and then
 * required a PROOF bound to that new HEAD. The only way through was to pre-merge by hand and beat
 * every other session to the push — observed 2026-09-01, three ship attempts and four full suite
 * runs lost to a base that advanced every ~18 minutes while re-verification took ~7.
 *
 * This does not relax the rule; it satisfies it with a measurement. The gate is the *same* runner
 * `.husky/pre-push` uses on the push that follows, so nothing lands on weaker evidence than before,
 * and the record is stamped from an actual run rather than hand-written.
 *
 * Only reachable when the branch's contributed diff is byte-identical across the merge
 * (`contributedDiffStatusAfterBaseMerge === 'same'`), i.e. the base is provably the only thing that
 * moved. A conflict resolution that touched this branch's files reports `changed` and still throws.
 */
function reverifyMergedTree(absWtPath, record, deps = {}) {
  const runner =
    deps.runCiMirror ?? ((wt) => exec(CI_MIRROR_CMD, { cwd: wt, timeout: CI_MIRROR_TIMEOUT_MS }));
  const writer = deps.recordFn ?? recordQualityGate;
  console.log(
    `[ship-worktree] Base merge moved HEAD. Re-verifying the merged tree (${CI_MIRROR_CMD.join(' ')})...`,
  );
  let output;
  try {
    output = runner(absWtPath);
  } catch (e) {
    throw new Error(
      `Pre-Ship Quality Gate re-verification failed on the merged tree.\n` +
        `The branch's own diff is unchanged, so this is an interaction with newly landed ` +
        `origin/${BASE_BRANCH} commits. Fix it in the worktree and retry.\n` +
        `${tailLines(`${e.stdout || ''}\n${e.stderr || e.message}`)}`,
    );
  }
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: absWtPath });
  const gates = (Array.isArray(record.gates) ? record.gates : []).filter(
    (g) => g?.name !== SELF_REVERIFY_GATE,
  );
  gates.push({
    name: SELF_REVERIFY_GATE,
    status: 'pass',
    command: CI_MIRROR_CMD.join(' '),
    detail: tailLines(output, 6),
  });
  const res = writer(absWtPath, branch, { ...record, gates });
  if (!res.ok) {
    // The record is read with `rejectUnknownKeys: false` and written with `true`, so a *pre-existing*
    // stray key on a record this code did not author lands here — and a live worktree carries exactly
    // one (`reviewer`, documented at `worktree-quality-gate.mjs#RECORD_KEYS`). Blaming "re-recording"
    // would point the reader at the measurement that just passed instead of at the drifted record.
    // Not silently stripped: an unread key is still someone's data, and dropping it to unblock a ship
    // is the same silent-repair habit this gate exists to prevent.
    const unknownKey = (res.errors || []).some((e) => /unknown key/i.test(String(e)));
    throw new Error(
      `Merged tree PASSED re-verification (${CI_MIRROR_CMD.join(' ')}), but the PROOF could not be ` +
        `written back: ${(res.errors || []).join('; ')}\n` +
        (unknownKey
          ? `This is pre-existing schema drift on the stored record, not a failure of the change ` +
            `being shipped. Re-record it without the stray key(s):\n` +
            `  node .claude/scripts/record-quality-gate.mjs ${branch} --json '<record>'`
          : `Fix the record and retry.`),
    );
  }
  console.log(`[ship-worktree] Merged tree verified. PROOF re-recorded at ${res.headSha?.slice(0, 7)}.`);
}

/**
 * Did the base merge change what this branch contributes?
 *
 * `same` / `changed` / `unknown` rather than a boolean: absence of an approved id is not evidence of
 * sameness, and the two consumers need opposite defaults for it — the approval check must not block
 * on `unknown` (markers predating the stamp exist), while re-verification must not proceed on it.
 */
function contributedDiffStatusAfterBaseMerge(absWtPath, diffIdFn) {
  const path = shipReviewMarkerPath(absWtPath);
  if (!existsSync(path)) return 'unknown';
  let approved;
  try {
    approved = JSON.parse(readFileSync(path, 'utf-8'))?.review_diff_id;
  } catch {
    return 'unknown';
  }
  if (!approved) return 'unknown';
  const current = diffIdFn(absWtPath, BASE_BRANCH);
  if (!current) return 'unknown';
  return current === approved ? 'same' : 'changed';
}

/**
 * Re-checks the *human* approval against the tree the base merge produced.
 *
 * The approval binds to the branch's contributed diff, which a base merge normally leaves alone —
 * that is the whole point of the binding. But it does not always: resolving a conflict, or the base
 * moving lines inside a file this branch also edits, changes that diff. In those cases the human
 * approved something the merge then rewrote.
 *
 * Nothing re-checked it. `mark-pre-ship-confirmed` verified the approval once, before ship ran, and
 * ship only re-checked the machine PROOF afterwards — so the one case the binding is *supposed* to
 * catch was the one case nobody looked at (found in adversarial review, 2026-08-27).
 *
 * Fail-open when either id is absent: markers written before this stamp existed, and worktrees where
 * no base ref resolves, must not become unshippable.
 *
 * @param {string} absWtPath
 * @param {boolean} force
 * @param {(wt: string, base: string) => string|null} [diffIdFn] Test-injectable.
 */
export function assertApprovalFreshAfterBaseMerge(absWtPath, force, diffIdFn = resolveReviewDiffId) {
  if (force) return;
  if (contributedDiffStatusAfterBaseMerge(absWtPath, diffIdFn) !== 'changed') return;
  const path = shipReviewMarkerPath(absWtPath);
  throw new Error(
    `Pre-Ship human approval is stale: ${path}\n` +
      `Merging origin/${BASE_BRANCH} changed the diff this branch contributes, so the change that ` +
      `lands is no longer the change the human approved.\n` +
      `Re-review the updated diff and record a fresh answer:\n` +
      `  node .claude/scripts/pre-ship-steps.mjs next --worktree ${absWtPath}\n` +
      `※ User override: --force-quality-gate (reason required in Panel Decisions section)`,
  );
}

function cmdShipWorktree(args) {
  const wtPath = requireArg(args, 'worktree');
  const absWtPath = resolveWorktreeAbsPath(wtPath);
  if (!existsSync(absWtPath)) {
    let candidates = [];
    try {
      candidates = parseWorktreePaths(git(['worktree', 'list', '--porcelain']));
    } catch {
      /* fallback */
    }
    const candidateBlock = candidates.length > 0
      ? `\nActive worktree candidates:\n  - ${candidates.join('\n  - ')}`
      : '';
    throw new Error(`Worktree does not exist: ${absWtPath}${candidateBlock}`);
  }

  const planPath = resolveWorktreePlanPath(absWtPath);
  if (!existsSync(planPath)) {
    throw new Error(`PLAN.md file does not exist: ${planPath}. Draft at .tmp/worktree-<branch>/PLAN.md in the worktree root and retry.`);
  }
  const forcePlan = args['force-plan'] === true;
  if (!forcePlan) {
    const unchecked = parseUnchecked(readFileSync(planPath, 'utf-8'));
    if (unchecked.length > 0) {
      throw new Error(
        `There are ${unchecked.length} uncompleted tasks in PLAN.md.\n` +
        `※ Override: Use --force-plan flag or mark items with (cancelled)/(dropped)/(deferred)/~~strikethrough~~`
      );
    }
  }

  assertQualityGateNotNoGo(absWtPath, args['force-quality-gate'] === true);

  const status = git(['status', '--porcelain', '--untracked-files=all'], { cwd: absWtPath }).trim();
  if (status.length > 0) {
    const err = new Error(
      `Worktree has uncommitted changes.\nCommit all changes before retrying.\n[Status]\n${status}`
    );
    err.details = {
      code: 'commit_required',
      dirty_status: status.split('\n'),
      hint: 'Run git status --short in worktree, stage/commit authored files, and run ship-worktree again.',
    };
    throw err;
  }

  const supersetWarnings = [];
  try {
    git(['fetch', 'origin', BASE_BRANCH], { cwd: absWtPath, timeout: 30_000, retry: 3 });

    supersetWarnings.push(
      ...collectSupersetWarnings(absWtPath, BASE_BRANCH, { checkLocalBranches: CHECK_LOCAL_BRANCH_SUPERSET }),
    );

    // Regression-test lock (R-CM-002 Rule 10): every recorded release and every locked test whose content
    // moved after its red commit reaches the Panel as a warning. Warn-only — the human is the judge; the
    // point is that a release or a bypassed lock can never be invisible at ship time. Fail-open on git error.
    try {
      supersetWarnings.push(
        ...shipTestLockFindings({ root: absWtPath, gitFn: (args) => safeGit(args, absWtPath, { timeout: 10_000 }) }),
      );
    } catch {
      /* fail-open (R-CM-006 Rule 2) */
    }

    try {
      git(['merge', '--no-edit', `origin/${BASE_BRANCH}`], { cwd: absWtPath });
    } catch (mergeErr) {
      console.log(`[ship-worktree] Merge conflict detected with origin(${BASE_BRANCH}). Attempting automatic resolution.`);
      const conflictingFiles = git(['diff', '--name-only', '--diff-filter=U'], { cwd: absWtPath })
        .trim()
        .split('\n')
        .filter(Boolean);
      
      const resolved = tryAutoResolveConflicts(absWtPath, conflictingFiles);
      if (!resolved) {
        try { git(['merge', '--abort'], { cwd: absWtPath }); } catch {}
        mergeErr.details = {
          code: 'merge_conflict_manual',
          conflicting_files: conflictingFiles,
          hint: `Conflicts could not be resolved automatically. Reconcile manually in worktree and retry: .claude/skills/create-pr/references/merge-conflict-resolution.md`,
          ...(supersetWarnings.length > 0 ? { warnings: [...supersetWarnings] } : {}),
        };
        throw mergeErr;
      }
      
      const hasMakefile = existsSync(join(absWtPath, 'Makefile'));
      const validateCmd = hasMakefile ? 'make q.check' : (existsSync(join(absWtPath, 'package.json')) ? 'npm test' : null);
      if (validateCmd) {
        console.log(`[ship-worktree] Auto-resolution complete. Running validation tool (${validateCmd})...`);
        try {
          exec(validateCmd.split(' '), { cwd: absWtPath });
          console.log(`[ship-worktree] Validation passed!`);
        } catch (gateErr) {
          console.error(`[ship-worktree] Validation failed: Code did not pass quality gate. Aborting merge.`);
          try { git(['merge', '--abort'], { cwd: absWtPath }); } catch {}
          throw new Error(`Quality check (${validateCmd}) failed after conflict resolution: ${gateErr.message}`);
        }
      } else {
        console.log(`[ship-worktree] Auto-resolution complete. Skipping validation.`);
      }
    }
  } catch (e) {
    throw new Error(`Conflict occurred while merging with base (${BASE_BRANCH}). Resolve manually, commit, and retry.\nError: ${e.message}`);
  }

  // The merge may have rewritten the branch's own diff, which invalidates the human approval.
  // Checked first: it is a string comparison, and failing it makes the minutes-long machine
  // re-verification below pointless work.
  assertApprovalFreshAfterBaseMerge(absWtPath, args['force-quality-gate'] === true);
  // The merge also added a commit, which invalidates the PROOF asserted before it. Re-earned by
  // measurement when the base is provably the only thing that moved.
  assertQualityGateFreshAfterBaseMerge(absWtPath, args['force-quality-gate'] === true);

  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: absWtPath });
  if (!branch || branch === 'HEAD') throw new Error(`Failed to determine branch: ${wtPath}`);

  const reviewDeckWarning = detectMissingReviewDeckWarning({
    absWtPath,
    branch,
    baseBranch: BASE_BRANCH,
  });
  if (reviewDeckWarning) supersetWarnings.push(reviewDeckWarning);

  const barMoveWarning = detectBarMoveWarning({ absWtPath, baseBranch: BASE_BRANCH });
  if (barMoveWarning) supersetWarnings.push(barMoveWarning);

  const qualitySnapshot = collectShipQualitySnapshot({ absWtPath, branch, baseBranch: BASE_BRANCH });
  // Before anything can remove the worktree: the answer it reads lives there.
  console.log(`[ship-worktree] trust ledger: ${reconcileTrustLedger(absWtPath, branch)}`);

  git(['push', '-u', 'origin', branch], { cwd: absWtPath, timeout: PUSH_TIMEOUT_MS, retry: 3 });

  const title = requireArg(args, 'title');
  const body = resolveBodyArg(args);
  const noMerge = args['no-merge'] === true;
  const cleanup = args['no-cleanup'] !== true;
  const preserveRun = args['preserve-run'] === true;

  const result = createAndMergePr({
    base: BASE_BRANCH, head: branch, title, body,
    deleteBranch: noMerge ? null : branch,
    noMerge,
    worktreeDir: absWtPath,
    forceQualityGate: args['force-quality-gate'] === true,
  });

  supersetWarnings.push(
    ...recordShipQualityAndDetectStreak({
      pr: result.prNumber ?? null,
      branch,
      snapshot: qualitySnapshot,
      result,
    }),
  );
  supersetWarnings.push(...syncApprovalTrust());

  let cleanedUp = false;
  let cleanupResult = null;
  let runBundle = null;
  const preservationWarnings = [];
  if (cleanup && result.merged) {
    const candidates = detectRunOutputCandidates(absWtPath);
    if (preserveRun) {
      runBundle = preserveWorktreeRunOutputs(absWtPath, branch);
    } else if (candidates.length > 0) {
      preservationWarnings.push(
        `cleanup will remove ${candidates.map((candidate) => candidate.relPath).join(', ')}. To preserve, run ship-worktree with --preserve-run.`,
      );
    }
    cleanupResult = cmdCleanupWorktree({ worktree: wtPath }, { verifiedMerged: true });
    cleanedUp = cleanupResult.worktree_cleaned === true;
  }

  if (result.merged) {
    unlinkShipReviewMarker(wtPath);
    // The branch's acceptance contract is spent once merged; fail-open like the marker unlink.
    try { removeBranchTaskContract(PROJECT_DIR, branch); } catch { /* fail-open */ }
  }

  const post_merge_main_status = result.merged ? detectPostMergeMainStatus() : null;
  if (result.merged) supersetWarnings.push(...detectTransplantTargetsMadeStale(result.changed_files));

  return composeShipResponse({
    result,
    supersetWarnings,
    preservationWarnings,
    runBundle,
    cleanupResult,
    cleanedUp,
    cleanup,
    wtPath,
    postMergeMainStatus: post_merge_main_status,
  });
}

/**
 * Reaps leftover empty worktree directory residue.
 */
export function reapWorktreeResidue(absWtPath, { projectDir = PROJECT_DIR, gitFn = git } = {}) {
  if (!existsSync(absWtPath)) return null;
  const abs = resolve(absWtPath);
  const info = { removed: false, path: abs };
  if (!abs.startsWith(join(projectDir, '.worktrees') + sep)) {
    return { ...info, reason: 'outside .worktrees/ path' };
  }
  try {
    const registered = gitFn(['worktree', 'list', '--porcelain'])
      .split('\n')
      .some((l) => l.startsWith('worktree ') && resolve(l.slice('worktree '.length).trim()) === abs);
    if (registered) return { ...info, reason: 'still recognized by git as worktree' };
    if (gitFn(['ls-files', '--', relative(projectDir, abs)]).trim()) {
      return { ...info, reason: 'tracked files remain' };
    }
  } catch (e) {
    return { ...info, reason: `failed to check status: ${e.message}` };
  }
  try {
    rmSync(abs, { recursive: true, force: true });
  } catch (e) {
    return { ...info, reason: `deletion failed: ${e.message}` };
  }
  return { removed: true, path: abs };
}

export function describeWorktreeResidue(residue) {
  if (!residue) return [];
  return residue.removed
    ? [`Cleaned up leftover worktree residue directory: ${residue.path}`]
    : [`Worktree directory remains (${residue.reason}): ${residue.path}`];
}

/** Whether an `origin` remote is configured. A remote that has not been fetched is still a remote. */
function hasOriginRemote() {
  try {
    git(['remote', 'get-url', 'origin'], { cwd: PROJECT_DIR });
    return true;
  } catch {
    return false;
  }
}

/**
 * The ref a worktree is measured against: `origin/<base>` when that ref exists, the local `<base>`
 * otherwise. A repository with no remote lands by merging into the local base, so there the local
 * base is the authority — the same answer worktree-new.mjs gives when it skips its fetch. Measuring
 * against an `origin/<base>` that cannot resolve refused every cleanup, and a merged worktree whose
 * only sanctioned removal always failed was left behind.
 */
export function baseRef(absWtPath, baseBranch = BASE_BRANCH, gitFn = git) {
  try {
    gitFn(['rev-parse', '--verify', '--quiet', `refs/remotes/origin/${baseBranch}`], { cwd: absWtPath });
    return `origin/${baseBranch}`;
  } catch {
    return baseBranch;
  }
}

/**
 * Whether HEAD's tree is byte-identical to the base (`baseRef`) — i.e. nothing here is absent from
 * base. Fails closed (unknown → false): an unreadable diff is not evidence of safety.
 */
function treeMatchesBase(absWtPath, base, gitFn) {
  try {
    gitFn(['diff', '--quiet', base, 'HEAD'], { cwd: absWtPath });
    return true; // exit 0 = no differences
  } catch {
    return false; // exit 1 = differences, or the ref/command failed
  }
}

/**
 * Pre-removal loss check for cleanup-worktree.
 *
 * destructive-git-guard routes "already-merged or abandoned" worktrees here, but nothing verified
 * that premise — `worktree remove --force` + `branch -D` ran unconditionally, so a mistyped path
 * pointing at another session's live worktree destroyed uncommitted files (unrecoverable) and
 * orphaned unpushed commits. Refuses when either is present:
 *   - dirty working tree (uncommitted / untracked files — no reflog, no recovery)
 *   - commits ahead of the base (`baseRef`: origin/<base>, or the local <base> when there is no
 *     remote) whose HEAD is not on origin/<branch> (squash-merged husks always look "ahead" by
 *     ancestry, so a pushed tip — recoverable from the remote — passes; with no remote there is no
 *     such tip, and only a tree identical to the base passes)
 *
 * `origin/<branch>` is a *cache*, not a fact: any `git fetch --prune` / `fetch.prune=true` deletes the
 * stale ref left by a squash-merge-and-delete, after which the ancestry probe reports a fully landed
 * branch as unpushed and refuses the very cleanup destructive-git-guard steers here (review 2026-08-26).
 * So a second, prune-proof signal is consulted: if the worktree tree is identical to origin/<base>,
 * every byte already exists in base and nothing can be lost — true exactly for a landed squash husk,
 * and never true for a branch carrying unique unpushed work.
 */
export function assessCleanupSafety(absWtPath, { gitFn = git, baseBranch = BASE_BRANCH } = {}) {
  let dirty;
  try {
    dirty = gitFn(['status', '--porcelain', '--untracked-files=all'], { cwd: absWtPath }).trim();
  } catch (e) {
    return { safe: false, reason: `worktree state unreadable: ${e.message}`, details: {} };
  }
  if (dirty) {
    return {
      safe: false,
      reason: 'uncommitted changes present (unrecoverable once removed)',
      details: { dirty_files: dirty.split('\n').slice(0, 10) },
    };
  }
  const base = baseRef(absWtPath, baseBranch, gitFn);
  let ahead = 0;
  try {
    ahead = parseInt(gitFn(['rev-list', '--count', `${base}..HEAD`], { cwd: absWtPath }).trim(), 10) || 0;
  } catch (e) {
    return { safe: false, reason: `unmerged-commit check failed: ${e.message}`, details: {} };
  }
  return ahead > 0 ? assessAheadCommits(absWtPath, { gitFn, base, hasRemote: base !== baseBranch, ahead }) : { safe: true };
}

/**
 * The ahead > 0 half of `assessCleanupSafety`: safe only when the tip is on origin/<branch> (with a
 * remote) or the tree is identical to the base (a landed squash husk, prune-proof).
 */
function assessAheadCommits(absWtPath, { gitFn, base, hasRemote, ahead }) {
  let branch = null;
  let pushed = false;
  try {
    branch = gitFn(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: absWtPath }).trim();
    pushed = hasRemote && isAncestor('HEAD', `origin/${branch}`, absWtPath, gitFn);
  } catch { pushed = false; }
  if (!pushed) pushed = treeMatchesBase(absWtPath, base, gitFn); // prune-proof squash-husk signal
  if (pushed) return { safe: true };
  let commits = [];
  try {
    commits = gitFn(['log', '--oneline', `${base}..HEAD`], { cwd: absWtPath })
      .trim().split('\n').filter(Boolean).slice(0, 10);
  } catch { /* listing is best-effort */ }
  return {
    safe: false,
    // Names both probes: a bare "not on origin" reads as certain data loss, but this state is
    // also reached by a merged branch whose base has since moved on (review 2026-08-26).
    reason:
      `${ahead} commit(s) not provably on origin ` +
      (hasRemote
        ? `(not on origin/${branch ?? '<branch>'}, and tree differs from ${base})`
        : `(not merged into ${base}, and no remote to hold them)`),
    details: { unpushed_commits: commits },
  };
}

/** Drops `execution.worktree` from CONTEXT.json when it still points at the worktree being removed. */
function clearWorktreeFromContext(wtPath, warnings) {
  const ctxPath = join(PROJECT_DIR, 'CONTEXT.json');
  if (!existsSync(ctxPath)) return;
  try {
    const ctx = JSON.parse(readFileSync(ctxPath, 'utf-8'));
    if (ctx.execution?.worktree?.worktree_path !== wtPath) return;
    delete ctx.execution.worktree;
    writeFileSync(ctxPath, JSON.stringify(ctx, null, 2) + '\n');
  } catch (e) {
    warnings.push(`Failed to update CONTEXT.json: ${e.message}`);
  }
}

/**
 * Post-removal main sync: fetch → refuse on dirty main → ff-only.
 * Returns the failing response (fail-loud, R-CM-010) or null once synced.
 */
function syncMainAfterCleanup(worktreeCleaned, warnings) {
  const fail = (error, hint, syncStatus) => ({
    ok: false, error, hint, sync_status: syncStatus, worktree_cleaned: worktreeCleaned, warnings,
  });
  // No remote: the local base is already the authority, so there is nothing to sync from. Failing
  // here reported a finished cleanup as `fetch_failed`.
  if (!hasOriginRemote()) {
    return worktreeCleaned
      ? { ok: true, sync_status: 'no_remote', worktree_cleaned: true, warnings }
      : fail('worktree could not be removed', 'See warnings for what remains.', 'no_remote');
  }
  try {
    git(['fetch', '--prune', 'origin', BASE_BRANCH], { cwd: PROJECT_DIR, timeout: 60_000, retry: 3 });
  } catch (e) {
    return fail(`${BASE_BRANCH} fetch failed: ${e.message}`, 'Check remote status and sync manually.', 'fetch_failed');
  }
  if (git(['status', '--porcelain'], { cwd: PROJECT_DIR }).trim().length > 0) {
    return fail(
      'Cannot proceed with sync because local uncommitted changes exist.',
      'Manually commit or stash changes before syncing again.',
      'local_changes',
    );
  }
  try {
    git(['checkout', BASE_BRANCH], { cwd: PROJECT_DIR });
    git(['merge', '--ff-only', `origin/${BASE_BRANCH}`], { cwd: PROJECT_DIR });
  } catch (e) {
    return fail(
      `${BASE_BRANCH} ff-only failed: ${e.message}`,
      `origin/${BASE_BRANCH} is not an ancestor of local ${BASE_BRANCH}. Manual rebase required.`,
      'ff_failed',
    );
  }
  return null;
}

/**
 * Path compared resolved through symlinks (git prints /private/var where a caller may say /var) and,
 * via `.native`, in the filesystem's own case, so a case-differing path to a real worktree matches
 * on a case-insensitive filesystem. A path that no longer exists keeps its missing tail and resolves
 * the existing prefix (`canonicalizePath`), so a pruned `/var/…` entry still matches `/private/var/…`.
 */
function canonicalPath(p) {
  try {
    return realpathSync.native(p);
  } catch {
    return canonicalizePath(resolve(p));
  }
}

/** Branch a `<PROJECT_DIR>/.worktrees/<branch>` path names, or null for any other layout. */
export function branchFromWorktreePath(absWtPath, projectDir = PROJECT_DIR) {
  const marker = `${sep}.worktrees${sep}`;
  const idx = absWtPath.indexOf(marker);
  if (idx < 0 || canonicalPath(absWtPath.slice(0, idx)) !== canonicalPath(projectDir)) return null;
  const branch = absWtPath.slice(idx + marker.length).replace(/[\\/]+$/, '').split(sep).join('/');
  return branch || null;
}

function refExists(ref, gitFn) {
  try {
    gitFn(['rev-parse', '--verify', '--quiet', ref], { cwd: PROJECT_DIR });
    return true;
  } catch {
    return false;
  }
}

function contextNamesWorktree(absWtPath) {
  try {
    const ctx = JSON.parse(readFileSync(join(PROJECT_DIR, 'CONTEXT.json'), 'utf-8'));
    const recorded = ctx?.execution?.worktree?.worktree_path;
    return typeof recorded === 'string' && canonicalPath(resolveWorktreeAbsPath(recorded)) === canonicalPath(absWtPath);
  } catch {
    return false;
  }
}

/**
 * Evidence that a path which no longer exists was a real worktree of this repository, or null.
 *
 * Checked in order: git worktree metadata still listing it (prunable or not); the branch its
 * `.worktrees/<branch>` layout names, locally or as `origin/<branch>` (cleanup deletes the local
 * branch before syncing, so a retry after `fetch_failed` still finds the pushed one); a ship-ledger
 * row for that branch (ship-worktree writes it before cleanup); CONTEXT.json's recorded worktree.
 */
export function worktreeTrace(absWtPath, { gitFn = git, readLedgerFn = readLedger } = {}) {
  try {
    const listed = parseWorktreePaths(gitFn(['worktree', 'list', '--porcelain'], { cwd: PROJECT_DIR }));
    if (listed.some((p) => canonicalPath(p) === canonicalPath(absWtPath))) return 'worktree_metadata';
  } catch { /* unreadable list is not evidence either way */ }
  const branch = branchFromWorktreePath(absWtPath);
  if (branch && refExists(`refs/heads/${branch}`, gitFn)) return 'local_branch';
  if (branch && refExists(`refs/remotes/origin/${branch}`, gitFn)) return 'remote_branch';
  try {
    if (branch && readLedgerFn().some((row) => row?.branch === branch)) return 'ship_ledger';
  } catch { /* unreadable ledger is not evidence */ }
  return contextNamesWorktree(absWtPath) ? 'context' : null;
}

/**
 * Refusal for a path cleanup-worktree must not act on, or null to proceed.
 *
 * An existing directory that is not a linked worktree (a mis-resolved path, a plain directory, the
 * main checkout — first entry of the list, and with no remote it would otherwise pass the safety
 * check: clean, 0 ahead of itself) is refused.
 *
 * A path that no longer exists proceeds when something in this repository still refers to it
 * (`worktreeTrace`) — the #1295 contract: ship-worktree's post-prune call, and a CLI retry after a
 * `fetch_failed` sync, have nothing left to remove but must still sync main. With no trace at all it
 * is almost always a typo, and proceeding would report a cleanup that removed nothing.
 */
export function refuseUnlinkedWorktree(absWtPath, gitFn = git, { readLedgerFn = readLedger } = {}) {
  if (!existsSync(absWtPath)) {
    if (worktreeTrace(absWtPath, { gitFn, readLedgerFn })) return null;
    return {
      ok: false,
      error: `worktree path does not exist and nothing in this repository refers to it: ${absWtPath}`,
      hint: 'Check the path for a typo — `git worktree list` prints the linked worktrees.',
    };
  }
  let linked;
  try {
    linked = parseWorktreePaths(gitFn(['worktree', 'list', '--porcelain'], { cwd: PROJECT_DIR })).slice(1);
  } catch (e) {
    return { ok: false, error: `worktree list unreadable: ${e.message}` };
  }
  const target = canonicalPath(absWtPath);
  if (linked.some((p) => canonicalPath(p) === target)) return null;
  return {
    ok: false,
    error: `not a linked worktree of this repository: ${absWtPath}`,
    hint: 'Pass the path `git worktree list` prints for it.',
  };
}

function cmdCleanupWorktree(args, { verifiedMerged = false } = {}) {
  const wtPath = requireArg(args, 'worktree');
  const absWtPath = resolveWorktreeAbsPath(wtPath);
  const warnings = [];

  const notLinked = refuseUnlinkedWorktree(absWtPath);
  if (notLinked) return notLinked;

  // verifiedMerged: internal post-merge call from ship-worktree (merge already confirmed) — the
  // ancestry check would false-block there because squash merges never make branch commits ancestors.
  if (!verifiedMerged && args.force !== true && existsSync(absWtPath)) {
    const safety = assessCleanupSafety(absWtPath);
    if (!safety.safe) {
      return {
        ok: false,
        error: `cleanup refused: ${safety.reason}`,
        hint: 'Ship first (/create-pr ship-worktree), or re-run with --force to discard the listed work.',
        ...safety.details,
      };
    }
  }

  unlinkShipReviewMarker(wtPath);
  gcStaleShipReviewMarkers();

  let branch = null;
  if (existsSync(absWtPath)) {
    try { branch = git(['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: absWtPath }); } catch {}
    // Not the 30s default: a worktree carrying a large `target/` or `node_modules/` is tens of
    // thousands of files, and a removal killed half-way leaves a directory git still lists.
    try { git(['worktree', 'remove', absWtPath, '--force'], { timeout: 600_000 }); } catch {}
    try { git(['worktree', 'prune']); } catch {}
    warnings.push(...describeWorktreeResidue(reapWorktreeResidue(absWtPath)));
  }
  const worktreeCleaned = !existsSync(absWtPath);
  if (branch) deleteBranchAndStashes(branch);

  clearWorktreeFromContext(wtPath, warnings);

  return (
    syncMainAfterCleanup(worktreeCleaned, warnings) ??
    { ok: true, sync_status: 'synced', worktree_cleaned: worktreeCleaned, warnings }
  );
}

// ═ Dispatch ═
const COMMANDS = {
  'init': cmdInit,
  'isolate': cmdIsolate,
  'commit': cmdCommit,
  'ship-feature': cmdShipFeature,
  'finalize': cmdFinalize,
  'verify-plan': cmdVerifyPlan,
  'ship-worktree': cmdShipWorktree,
  'cleanup-worktree': cmdCleanupWorktree,
};

// Doubles as the accepted-flag allowlist (`assertKnownFlags`), so a flag cannot be accepted without
// also appearing in `--help`. Entry format: `<flag>` optionally followed by ` (annotation)`.
const USAGE = {
  'init': { required: [], optional: [] },
  'isolate': { required: ['branch'], optional: [] },
  'commit': { required: ['message'], optional: ['files (comma-separated)'] },
  'ship-feature': {
    required: ['title'],
    optional: ['body', 'body-file (path — mutually exclusive with body)', 'no-merge (flag)'],
  },
  'finalize': { required: [], optional: [] },
  'verify-plan': { required: ['worktree'], optional: ['force (flag)'] },
  'ship-worktree': {
    required: ['worktree', 'title'],
    optional: [
      'body',
      'body-file (path — mutually exclusive with body)',
      'no-merge (flag)',
      'no-cleanup (flag)',
      'preserve-run (flag)',
      'force-plan (flag)',
      'force-quality-gate (flag — justification required in Panel Decisions)',
    ],
  },
  'cleanup-worktree': {
    required: ['worktree'],
    optional: ['force (flag — discard uncommitted changes / unpushed commits listed by the refusal)'],
  },
};

/**
 * Rejects flags the target command does not read.
 *
 * `parseArgs` accepts any `--key` and each command then picks out the keys it knows, so a flag the
 * command does not read is dropped without a word — indistinguishable from one that was never
 * passed. That is how `--body-file` produced PRs with empty bodies from #1067 (2026-07-27) onward,
 * and why nothing reported it: `registerFollowupDebtFromPr` parses the *merged* PR body, so an
 * empty body yields `count: 0` with no error. Runs before any push/merge side effect, so a rejected
 * invocation leaves no half-shipped state.
 */
export function assertKnownFlags(command, args, usageTable = USAGE) {
  const usage = usageTable[command] || { required: [], optional: [] };
  const entries = [...usage.required, ...usage.optional];
  const known = new Set(entries.map((entry) => entry.split(' ')[0]).concat('help'));
  const unknown = Object.keys(args).filter((key) => !known.has(key));
  if (unknown.length > 0) {
    const err = new Error(
      `Unknown flag(s) for ${command}: ${unknown.map((k) => `--${k}`).join(', ')}`,
    );
    err.details = { code: 'unknown_flag', unknown, accepted: [...known].sort() };
    throw err;
  }

  // `(flag)` keys are valueless: parseArgs consumes a following non-`--` token as the value, so
  // `--no-merge true` yields the *string* 'true' and every `=== true` consumer reads it as false —
  // the flag silently inverts (merge runs despite --no-merge, --preserve-run deletes the run bundle).
  // Fail loud instead, symmetrically with requireArg's missing-value check.
  const flagKeys = new Set(
    entries.filter((entry) => /\(flag/.test(entry)).map((entry) => entry.split(' ')[0]),
  );
  const misused = Object.keys(args).filter((key) => flagKeys.has(key) && args[key] !== true);
  if (misused.length > 0) {
    const err = new Error(
      `Flag(s) take no value: ${misused.map((k) => `--${k} (got: ${JSON.stringify(args[k])})`).join(', ')}. Pass the bare flag.`,
    );
    err.details = { code: 'flag_with_value', misused };
    throw err;
  }
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);

  if (!command || command === '--help') {
    process.stdout.write(JSON.stringify({
      ok: true, mode: null, command: '--help',
      commands: Object.keys(COMMANDS),
      modes: { staged: [...STAGED_CMDS], worktree: [...WORKTREE_CMDS] },
      config: {
        github_account: GH_ACCOUNT, base_branch: BASE_BRANCH,
        enforce_ssh_remote: ENFORCE_SSH,
      },
    }) + '\n');
    process.exit(0);
  }

  const mode = inferMode(command);
  if (!COMMANDS[command]) {
    process.stdout.write(JSON.stringify({
      ok: false, mode, command,
      error: `Unknown: ${command}`, available: Object.keys(COMMANDS),
    }) + '\n');
    process.exit(1);
  }

  if (args.help !== undefined) {
    process.stdout.write(JSON.stringify({
      ok: true, mode, command, help: true,
      usage: USAGE[command] || { required: [], optional: [] },
      note: 'Arguments format: --<key> <value>. (flag) indicates a valueless boolean switch.',
    }) + '\n');
    process.exit(0);
  }

  try {
    assertKnownFlags(command, args);
    const result = COMMANDS[command](args);
    process.stdout.write(JSON.stringify({ mode, command, ...result }) + '\n');
    process.exit(result.ok === false ? 1 : 0);
  } catch (e) {
    process.stdout.write(JSON.stringify({
      ok: false, mode, command,
      error: e.message, ...(e.details || {}),
    }) + '\n');
    process.exit(1);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  // Every git this CLI runs names its repository by `-C` / cwd; an inherited pointer overrides both.
  for (const pointer of INHERITED_REPOSITORY_POINTERS) delete process.env[pointer];
  main();
}
