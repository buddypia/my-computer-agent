/**
 * Common Utilities Module
 *
 * Utility functions shared across Hook scripts.
 * stdin reading, stdout output, safety checks, etc.
 */

import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync, renameSync, unlinkSync, realpathSync } from 'fs';
import { join, dirname, basename, resolve } from 'path';
import { pathToFileURL } from 'url';
import { homedir } from 'os';
import { execSync } from 'child_process';
import { randomBytes } from 'crypto';
import { isHookEnabled } from './hook-flags.mjs';

// Execution telemetry state. Configured by safeHookMainWithProfile, consumed by output.
// Placed at top to avoid TDZ ReferenceErrors.
/** Hook id currently running in this process (1 hook = 1 process). @type {string|null} */
let activeHookId = null;
/** governance-writer module cache. null = unloaded or load failed (proceeds without telemetry). */
let telemetryModule = null;

// ═══════════════════════════════════════════════════════════════
// Safe JSON File Reading (Centralized)
//
// Unifies existsSync + readFileSync + JSON.parse + try/catch pattern
// into a single reusable helper.
// ═══════════════════════════════════════════════════════════════

/**
 * Safely reads and parses a JSON file.
 *
 * Returns defaultValue on missing file, read errors, or JSON parse errors.
 * Never throws, eliminating try/catch requirements across call sites.
 *
 * @param {string} filePath - Absolute path
 * @param {*} [defaultValue=null] - Default value to return on failure
 * @returns {object|*} Parsed JSON object or defaultValue
 */
export function safeReadJson(filePath, defaultValue = null) {
  try {
    if (!existsSync(filePath)) return defaultValue;
    return JSON.parse(readFileSync(filePath, 'utf-8'));
  } catch {
    return defaultValue;
  }
}

/**
 * Helper extracting confidence score from handoff.confidence supporting both
 * object {score, level, ...} and number (legacy) formats. Returns null if not a finite number.
 *
 * Conforms to R-CM-026: Boundary helper accommodating variable confidence formats in handoff SSOT.
 * Shared across saga-manager.syncStageFromHandoff and stage-output-aggregator.mergeHandoffConfidence.
 *
 * @param {*} conf - handoff.confidence value (object|number|undefined|null)
 * @returns {number|null} Finite score or null
 */
export function extractConfidenceScore(conf) {
  const raw =
    typeof conf === 'object' && conf !== null
      ? conf.score
      : typeof conf === 'number'
        ? conf
        : null;
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : null;
}

// ═══════════════════════════════════════════════════════════════
// Atomic File Writing (Centralized)
//
// Unifies tmp+rename pattern into a single function.
// Used by all state management modules (state.mjs, saga-manager.mjs, etc.).
// ═══════════════════════════════════════════════════════════════

/**
 * Atomically writes JSON data to file (tmp + rename pattern).
 *
 * Since rename within the same filesystem is atomic on POSIX, creates tmp files
 * in the same directory as the target to prevent cross-partition issues.
 *
 * @param {string} filePath - Absolute path of target file
 * @param {object|string} data - Object to serialize or pre-serialized string
 * @param {object} [options]
 * @param {boolean} [options.ensureDir=true] - Whether to create directories automatically
 * @param {number} [options.indent=2] - JSON.stringify indentation (ignored if data is string)
 * @returns {boolean} Whether write succeeded
 */
export function atomicWriteJson(filePath, data, options = {}) {
  const { ensureDir = true, indent = 2 } = options;
  const dir = dirname(filePath);
  const base = basename(filePath);
  const tmpPath = join(dir, `.${base}.${randomBytes(4).toString('hex')}.tmp`);

  try {
    if (ensureDir && !existsSync(dir)) mkdirSync(dir, { recursive: true });
    const content = typeof data === 'string' ? data : JSON.stringify(data, null, indent);
    writeFileSync(tmpPath, content);
    renameSync(tmpPath, filePath);
    return true;
  } catch {
    // Attempt cleaning temporary file
    try { if (existsSync(tmpPath)) unlinkSync(tmpPath); } catch { /* ignore */ }
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════
// Git Utilities (Centralized)
// ═══════════════════════════════════════════════════════════════

/**
 * Patience floor for `safeExec`, in milliseconds — raises a call-site timeout, never lowers it.
 *
 * Call-site budgets are **production decisions and stay untouched**: `commit-guard` resolves the
 * branch on a 2s budget so a guard cannot hang a tool call, and "git did not answer" correctly
 * becomes deny (R-CM-008 Rule 6). What breaks is a *test* asserting the happy path through that
 * budget — load-dependent by construction, because `safeExec` collapses a timeout and a genuine
 * failure into the same `null`. Measured 2026-08-25: three consecutive ship attempts failed
 * `r-cm-041-flaky-tests` on a 16-CPU machine at load 67→267 (external projects, not this suite),
 * each time on a *different* test — commit-guard passthrough 7,274ms against its 2,000ms budget,
 * `collectChurnByPath` 32,409ms against the 10,000ms default, then `mechanism-roi-auditor` target
 * scoping — while every one passed standalone.
 *
 * So the harness widens the wait and no assertion, threshold, or default moves: unset env means
 * byte-identical behaviour. A patience budget, not a quality bar — the same argument
 * `vitest.config.ts` records for `hookTimeout`, and the reason deleting or skipping these tests
 * would be the wrong answer (R-CM-041 Rule 5).
 *
 * Read per call rather than at module load: `vitest.setup.ts` re-applies env before every test,
 * and child processes inherit it through `{ ...process.env }`.
 *
 * @returns {number} Floor in ms, or 0 when unset/invalid (no effect)
 */
function execTimeoutFloorMs() {
  const raw = Number(process.env.HARNESS_EXEC_TIMEOUT_FLOOR_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : 0;
}

/**
 * Default ceiling on `safeExec` stdout, deliberately explicit.
 *
 * Node's default is 1MB; past it `execSync` throws `ENOBUFS` and the `catch` below turns it into a
 * `null` that is **indistinguishable from a command that failed**. Downstream that null becomes
 * policy: `worktree-shipping-guard#countUncommittedChanges`
 * reads `null` as `0` and lets the worktree past the Stop gate — so the dirtier the tree, the quieter
 * the guard. A guard that weakens as the thing it guards grows is pointed the wrong way.
 * This does not contradict R-CM-006 Rule 2 (fail-open): fail-open covers *git failing*, and here git
 * succeeded and we failed to read it.
 * 64MB matches the order of the explicit limits every other `execSync` caller in this repo already
 * sets (`ci-local-status` 32MB, `transplant-bundle` 64MB, `audit-overengineering` 128MB) — it is a
 * ceiling on a string this process is about to hold anyway, not a reservation.
 *
 * Contract: `tests/unit/safe-exec-maxbuffer.test.mjs`.
 */
export const SAFE_EXEC_MAX_BUFFER = 64 * 1024 * 1024;

/**
 * Repository pointers a session can export, which git reads *before* the `cwd` it was handed.
 *
 * Claude Code's EnterWorktree exports both, and worktrees created by older `worktree-init` carry them
 * in their CLI configs. Inherited, they steer every git a script starts at the session's repository:
 * `ops.mjs cleanup-worktree` read a target worktree's branch as `main`, and once the worktree they
 * named was removed every git failed (a transplant target, 2026-09). Only these two: `GIT_INDEX_FILE`
 * is set by git for its own hooks and must reach the git they run — `git commit <paths>` stages into a
 * temporary index, and a pre-commit hook whose git lost it would check the real index instead.
 */
export const INHERITED_REPOSITORY_POINTERS = ['GIT_DIR', 'GIT_WORK_TREE'];

/**
 * `env` without the repository pointers, so a child's git finds its repository from its `cwd`.
 *
 * @param {NodeJS.ProcessEnv} [env=process.env]
 * @returns {NodeJS.ProcessEnv} a copy; `env` is not modified
 */
export function withoutInheritedRepository(env = process.env) {
  const scrubbed = { ...env };
  for (const pointer of INHERITED_REPOSITORY_POINTERS) delete scrubbed[pointer];
  return scrubbed;
}

/**
 * Safely executes shell command (centralized).
 *
 * - Always pipes stdio to prevent stderr from leaking to parent process (Claude Code)
 * - Returns null on failure (never throws)
 * - All hook scripts must use this helper
 *
 * @param {string} cmd - Command string to execute
 * @param {string} cwd - Working directory
 * @param {object} [options]
 * @param {number} [options.timeout=10000] - Timeout in milliseconds, floored by `execTimeoutFloorMs`
 * @param {number} [options.maxBuffer=67108864] - Max stdout bytes before ENOBUFS (`SAFE_EXEC_MAX_BUFFER`)
 * @returns {string|null} Trimmed stdout or null
 */
export function safeExec(cmd, cwd, options = {}) {
  try {
    return execSync(cmd, {
      cwd,
      encoding: 'utf-8',
      timeout: Math.max(options.timeout ?? 10000, execTimeoutFloorMs()),
      maxBuffer: options.maxBuffer ?? SAFE_EXEC_MAX_BUFFER,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: withoutInheritedRepository(),
    }).trim();
  } catch {
    return null;
  }
}

/**
 * Safely executes git command.
 *
 * **No repo preflight, deliberately.** This used to call an `isGitRepo(cwd)` probe first, to "avoid a
 * fork when cwd is not a repo" — a fork spent to save a fork, whose only caller was this function.
 * It carried two defects that a plain `git` invocation does not have:
 *   1. Its own hardcoded 3s budget, ignoring the caller's `options.timeout` entirely.
 *   2. A `Map` that cached the *failure* too, so one transient timeout answered "not a git repo"
 *      for every later call on that cwd in the process.
 * Fault-injected 2026-09-01: a single 4s hiccup on the probe turned 4 consecutive calls into `null`
 * while git was healthy and the caller had asked for 20000ms. Non-repo cwd still yields null here —
 * git exits 128 and `safeExec` catches it — so the probe bought nothing and cost correctness.
 *
 * @param {string} gitArgs - Git subcommand + arguments (e.g., "status --porcelain")
 * @param {string} cwd - Working directory
 * @param {object} [options]
 * @param {number} [options.timeout=10000] - Timeout in milliseconds
 * @returns {string|null}
 */
export function safeGit(gitArgs, cwd, options = {}) {
  return safeExec(`git ${gitArgs}`, cwd, options);
}

/**
 * Single-quote a value before it is interpolated into a `safeGit` / `safeExec` shell string.
 *
 * `safeExec` hands its argument to /bin/sh, and neither it nor `safeGit` quotes anything — so every
 * `${...}` in a git command string is a shell metacharacter boundary. Any value that came from
 * configuration, a file, an environment variable or a branch name must go through this function
 * first (e.g. `base_branch` from the create-pr config, which `worktree-shipping-guard` interpolates
 * on every session Stop).
 *
 * It lives here, beside `safeGit`, on purpose: it used to live only in `test-lock.mjs`, which is how
 * a control the hazard-creating module does not export ends up unapplied elsewhere. Keep exactly one
 * copy — `test-lock.mjs` re-exports this one.
 *
 * @param {string} value
 * @returns {string} the value wrapped in single quotes, with embedded single quotes escaped
 */
export function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/**
 * Checks whether specified directory is inside a git repository.
 *
 * **Not cached, deliberately.** See `safeGit` above for the incident this answers.
 *
 * @param {string} cwd - Directory to check
 * @param {object} [options]
 * @param {number} [options.timeout=10000] - Timeout in milliseconds
 * @returns {boolean}
 */
export function isGitRepo(cwd, options = {}) {
  return safeExec('git rev-parse --is-inside-work-tree', cwd, options) === 'true';
}

/**
 * Resolves project root directory (Worktree-aware).
 * Priority: CLAUDE_PROJECT_DIR > hookData.cwd > process.cwd()
 * Resolves back to original project root when executed inside a worktree (.worktrees/...).
 *
 * **Normalization of trailing `.claude` segment**: Must never return a path ending in `.claude`
 * across any priority source (e.g., standalone execution with unset env where cwd happens to be under `.claude`).
 * Since real project roots cannot be named `.claude`, reusing such paths in `join(dir, '.claude', 'state')`
 * creates nested `.claude/.claude/state` paths. Removes trailing `.claude` segments via walk-up.
 *
 * @param {object} [hookData] - Hook stdin data (may contain data.cwd)
 * @returns {string} Absolute path to project root
 */
export function resolveProjectDir(hookData) {
  let dir = process.env.CLAUDE_PROJECT_DIR || hookData?.cwd || process.cwd();
  const wtIndex = dir.indexOf('/.worktrees/');
  if (wtIndex !== -1) {
    dir = dir.substring(0, wtIndex);
  }
  while (basename(dir) === '.claude') {
    dir = dirname(dir);
  }
  return dir;
}

/**
 * Payload whose `cwd` is the directory a Bash command starts in — the single place Bash guards get it.
 *
 * Antigravity's `cwd` is the workspace root (`workspacePaths[0]`); the directory `run_command` runs in
 * arrives separately as `toolCall.args.Cwd`, normalized to `commandCwd` by cli-adapter-utils. For a
 * Bash payload carrying it, returns a copy with `cwd: commandCwd`; otherwise (Claude / Codex, non-Bash)
 * returns `data` itself. Guards keep calling `resolveProjectDir` with the **original** payload so the
 * project root never follows the command around.
 *
 * @param {object} data - normalized hook payload
 * @returns {object}
 */
export function withCommandCwd(data) {
  const commandCwd = data?.commandCwd;
  if (data?.tool_name !== 'Bash' || typeof commandCwd !== 'string' || !commandCwd) return data;
  return { ...data, cwd: commandCwd };
}

/**
 * Absolute path with `..` / `.` folded, and the longest existing prefix resolved through symlinks
 * (the non-existent tail is kept as written). Used where a guard compares paths by worktree root:
 * `<wt>/../other` must count as `other`, and `/var/…` vs `/private/var/…` must not look like two
 * worktrees. Unresolvable → the lexical `resolve` result.
 *
 * @param {string} p absolute path
 * @returns {string}
 */
export function canonicalizePath(p) {
  if (!p || typeof p !== 'string') return p;
  const abs = resolve(p);
  const tail = [];
  let cur = abs;
  while (!existsSync(cur)) {
    const parent = dirname(cur);
    if (parent === cur) return abs;
    tail.unshift(basename(cur));
    cur = parent;
  }
  try {
    return join(realpathSync(cur), ...tail);
  } catch {
    return abs;
  }
}

/**
 * Reads JSON data from stdin.
 * Claude Code Hooks pass event data via stdin.
 *
 * @returns {Promise<object>}
 */
export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf-8');
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/**
 * Outputs JSON result to stdout.
 * Hook results must be delivered via stdout JSON.
 *
 * Additionally records **firing (numerator) telemetry** when result is deny/block.
 * Evaluation is handled by ledger format SSOT (`recordFiringIfDenyBlock`).
 * Since telemetry module is preloaded by `safeHookMainWithProfile`, invocation is synchronous.
 *
 * @param {object} data - Data to output
 */
export function output(data) {
  if (activeHookId && telemetryModule) {
    telemetryModule.recordFiringIfDenyBlock(activeHookId, data, currentHookEventName());
  }
  console.log(JSON.stringify(data));
}

/**
 * Detects Stop triggered by Context Limit.
 * Never blocks when context window is exhausted (prevents deadlock).
 * Evaluated from Stop input metadata in Claude Code Hooks.
 */
export function isContextLimitStop(data) {
  const reason = (data.stop_reason || data.stopReason || '').toLowerCase();
  const endTurnReason = (data.end_turn_reason || data.endTurnReason || '').toLowerCase();

  const patterns = [
    'context_limit',
    'context_window',
    'context_exceeded',
    'context_full',
    'max_context',
    'token_limit',
    'max_tokens',
    'conversation_too_long',
    'input_too_long',
  ];

  return patterns.some((p) => reason.includes(p) || endTurnReason.includes(p));
}

/**
 * Detects user abortion / cancellation.
 */
export function isUserAbort(data) {
  if (data.user_requested || data.userRequested) return true;

  const reason = (data.stop_reason || data.stopReason || '').toLowerCase();
  const exact = ['aborted', 'abort', 'cancel', 'interrupt'];
  const sub = ['user_cancel', 'user_interrupt', 'ctrl_c', 'manual_stop'];

  return exact.some((p) => reason === p) || sub.some((p) => reason.includes(p));
}

/**
 * Parses Markdown Plan file checkboxes.
 * - [ ] = unchecked, - [x] or - [X] = completed.
 * Ignores code blocks (```).
 *
 * @param {string} planFilePath
 * @returns {{ total: number, completed: number, uncheckedItems: string[] } | null}
 */
export function parsePlanProgress(planFilePath) {
  if (!existsSync(planFilePath)) return null;

  try {
    const content = readFileSync(planFilePath, 'utf-8');
    const lines = content.split('\n');
    let inCodeBlock = false;
    let total = 0;
    let completed = 0;
    const uncheckedItems = [];

    for (const line of lines) {
      if (line.trim().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        continue;
      }
      if (inCodeBlock) continue;

      const match = line.match(/^(\s*)- \[([ xX])\]\s+(.+)/);
      if (match) {
        total++;
        if (match[2].toLowerCase() === 'x') {
          completed++;
        } else {
          uncheckedItems.push(match[3].trim());
        }
      }
    }

    return { total, completed, uncheckedItems };
  } catch {
    return null;
  }
}

/**
 * Cross-validates pipeline artifact progress against actual file existence on disk.
 * Identifies items as mismatches when files exist but status remains "pending".
 *
 * Used in Stop Hooks to detect missing progress updates.
 *
 * @param {string} projectDir - Project root directory
 * @param {string} contextRelPath - Artifact JSON relative path
 * @returns {{ mismatches: number, details: Array<{stage: string, status: string, existingCount: number}> }}
 */
export function validatePipelineProgress(projectDir, contextRelPath) {
  const contextPath = join(projectDir, contextRelPath);
  if (!existsSync(contextPath)) return { mismatches: 0, details: [] };

  try {
    const context = JSON.parse(readFileSync(contextPath, 'utf-8'));
    const progressDetails = context?.progress?.details;
    if (!progressDetails || typeof progressDetails !== 'object') {
      return { mismatches: 0, details: [] };
    }

    const mismatches = [];

    for (const [stage, info] of Object.entries(progressDetails)) {
      if (typeof info !== 'object' || !info) continue;
      if (info.status === 'completed') continue;
      const files = info.files;
      if (!Array.isArray(files) || files.length === 0) continue;

      const existingCount = files.filter((f) => existsSync(join(projectDir, f))).length;

      if (existingCount > 0 && info.status !== 'completed') {
        mismatches.push({
          stage,
          status: info.status || 'pending',
          existingCount,
          totalFiles: files.length,
        });
      }
    }

    return { mismatches: mismatches.length, details: mismatches };
  } catch {
    return { mismatches: 0, details: [] };
  }
}

/**
 * Counts incomplete tasks in Claude Code Task system.
 * Task files are saved in ~/.claude/tasks/{sessionId}/.
 */
export function countIncompleteTasks(sessionId) {
  if (!sessionId || typeof sessionId !== 'string') return 0;
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,255}$/.test(sessionId)) return 0;

  const taskDir = join(homedir(), '.claude', 'tasks', sessionId);
  if (!existsSync(taskDir)) return 0;

  let count = 0;
  try {
    const files = readdirSync(taskDir).filter((f) => f.endsWith('.json') && f !== '.lock');
    for (const file of files) {
      try {
        const content = readFileSync(join(taskDir, file), 'utf-8');
        const task = JSON.parse(content);
        if (task.status === 'pending' || task.status === 'in_progress') count++;
      } catch {
        /* skip malformed */
      }
    }
  } catch {
    /* skip */
  }
  return count;
}

/**
 * Checks whether running inside a test runner — **Test Runner SSOT**.
 *
 * Accommodates both test runners: vitest (`tests/**`) and `node --test` (`npm test` → `.claude/scripts/test-hooks.mjs`).
 * If evaluation checked vitest only, `node --test` runs would be treated as non-tests, causing:
 *   1. Ledger isolation failure → Test fixtures polluting actual `governance-events.jsonl`
 *   2. `safeHookMain` fail-loud disabled → Hooks throwing errors would emit `{}` passthrough, masking crashes.
 *
 * `node --test` sets `NODE_TEST_CONTEXT` (e.g., `child-v8`). Spawning child hook processes with `{...process.env}`
 * ensures inherited evaluation across orchestrated runs.
 *
 * @returns {boolean}
 */
export function isTestRun() {
  return (
    process.env.NODE_ENV === 'test' || !!process.env.VITEST || !!process.env.NODE_TEST_CONTEXT
  );
}

/**
 * Safe wrapper for hook main functions.
 *
 * Required wrapper preventing unhandled rejections in Node.js 22+.
 * 1. Prevents deadlocks on exceptions (passthrough with empty JSON)
 * 2. Emits empty JSON (passthrough) without stderr output
 * 3. Handles broken stdout pipes safely
 *
 * Usage:
 *   import { safeHookMain } from './lib/utils.mjs';
 *   safeHookMain(main);
 *
 * @param {() => Promise<void>} fn - Async main function
 */
export function safeHookMain(fn) {
  // Every hook names its repository by cwd / `-C`; a pointer the session exports would override both.
  for (const pointer of INHERITED_REPOSITORY_POINTERS) delete process.env[pointer];
  fn().catch((err) => {
    if (isTestRun()) {
      console.error('[Fail-Loud in Test] Hook execution failed:', err);
      process.exit(1);
    }
    // NOTE: Do not use console.error — stderr outputs display as "hook error" in Claude Code
    try { console.log('{}'); } catch { /* ignore broken stdout pipes */ }
  });
}

/**
 * Determines whether module was **invoked directly** via `node <file>`. Returns false if imported.
 *
 * If a hook unconditionally calls its entry point at top level, **importing the file runs the hook**.
 * Wrapping production calls with this check preserves direct execution from settings.json while eliminating import side effects.
 * Orchestrated hooks called via `run()` exports do not invoke top-level entry points.
 *
 * @param {string} importMetaUrl - `import.meta.url` of caller
 * @returns {boolean}
 */
export function isDirectInvocation(importMetaUrl) {
  try {
    const entry = process.argv[1];
    if (!entry || typeof importMetaUrl !== 'string') return false;
    if (importMetaUrl === pathToFileURL(entry).href) return true;
    // Direct symlink execution (macOS /tmp → /private/tmp)
    return importMetaUrl === pathToFileURL(realpathSync(entry)).href;
  } catch {
    return false; // Non-direct execution on unevaluable (safe side effect-free default)
  }
}

// ═══════════════════════════════════════════════════════════════
// Execution Telemetry — Process Gate Independent of Dispatch Path
//
// Orchestrated hooks record evaluation (denominator) / firing (numerator) via orchestrator.
// However, events without dispatchers (SessionEnd / PermissionRequest), prefix glob matchers (`mcp__*`),
// `if` conditional registrations, and cliTargets adapter hooks were structurally excluded from orchestrator.
//
// All hooks pass through two functions in this file: entry via safeHookMainWithProfile and output via output.
// Placing telemetry here ensures unified measurement regardless of dispatch method.
// ═══════════════════════════════════════════════════════════════

/**
 * Loads telemetry module once (failures do not impact hook execution).
 *
 * Dynamic import prevents circular dependencies with governance-writer (which imports resolveProjectDir).
 * In scaffold (Perspective 2), `.claude/scripts/lib/` is not distributed, naturally acting as a no-op.
 *
 * @returns {Promise<object|null>}
 */
async function loadTelemetry() {
  if (telemetryModule) return telemetryModule;
  try {
    telemetryModule = await import('../../.claude/scripts/lib/governance-writer.mjs');
  } catch {
    telemetryModule = null; // Telemetry absence does not impact guard decisions
  }
  return telemetryModule;
}

/**
 * Current hook event name. Injected by Claude Code; returns empty string on absence — does not guess.
 * @returns {string}
 */
function currentHookEventName() {
  const raw = process.env.CLAUDE_HOOK_EVENT_NAME;
  return typeof raw === 'string' ? raw : '';
}

/**
 * Profile-aware safe hook main wrapper.
 * Combines safeHookMain with isHookEnabled checks.
 *
 * @param {string} hookId - Registry entry id
 * @param {() => Promise<void>} fn - Async main function
 * @param {{checkProfile?: boolean}} [opts] - `checkProfile: false` for unprofiled hooks (`profileChecked: false`).
 *   Telemetry is recorded regardless of profile gating.
 */
export function safeHookMainWithProfile(hookId, fn, opts) {
  if (opts?.checkProfile !== false && !isHookEnabled(hookId)) {
    try { console.log('{}'); } catch { /* ignore broken stdout pipes */ }
    return;
  }
  activeHookId = typeof hookId === 'string' && hookId ? hookId : null;
  safeHookMain(async () => {
    const telemetry = await loadTelemetry();
    // Evaluation (denominator) = "dispatch reached this hook". Recorded before fn execution.
    if (activeHookId && telemetry) {
      telemetry.recordHookEvaluations([{ id: activeHookId }], currentHookEventName());
    }
    await fn();
  });
}
