/**
 * layout-resolver.mjs — R-CM-026 harness .harness/ Layout Resolver (Single SSOT Helper)
 *
 * Resolves categories from data/registry/harness-layout.json into deterministic paths.
 * All hooks/scripts must use helpers from this module instead of hardcoding `.harness/` directly.
 *
 * Responsibilities:
 *   - Resolves system category (registry.json, learnings.jsonl, ...) paths
 *   - Resolves run category (active-run state) paths
 *   - Resolves system/session-history directory paths
 *   - Resolves run-scoped category (stage-output, handoff, reports, references) directories
 *   - Queries active run_id (prioritizing .harness/run/active.json)
 *
 * Design Principles:
 *   - Pure functions (read-only side effects — fs.existsSync/readFileSync only)
 *   - Does not throw — returns safe defaults on absence/error
 *   - Deterministic — identical input + identical filesystem state → always identical path
 */

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, relative, resolve, dirname, basename } from 'node:path';
import { resolveMainRepoRoot } from './worktree-path.mjs';
import { withoutInheritedRepository } from './utils.mjs';

/**
 * Project root (CLAUDE_PROJECT_DIR prioritized) — process actual root (immutable baseline for system/governance/scan).
 * Normalizes trailing `.claude` segment: identical guard to `.cli/lib/utils.mjs#resolveProjectDir`
 * (since an actual project root cannot be named `.claude`, joining `.harness` directly if env/cwd was
 * inadvertently inside `.claude` would create an erroneous `.claude/.harness` path).
 */
let PROJECT_DIR = process.env.CLAUDE_PROJECT_DIR
  ? resolve(process.env.CLAUDE_PROJECT_DIR)
  : process.cwd();
while (basename(PROJECT_DIR) === '.claude') {
  PROJECT_DIR = dirname(PROJECT_DIR);
}

/**
 * Synchronous scope override for worktree_local resolution base (R-CM-035 Exception 5 — loom cross-worktree run mutation).
 *
 * When webui server (main process) archives/deletes a run from *another worktree*, ensures worktree_local
 * assets (`run/active.json`, `runs/<id>/`) are resolved relative to that worktree. system_persistent
 * (`getArchivesRoot`/`resolveSystemFile` → `resolveSystemPersistentRoot` git-common-dir) remains unaffected,
 * ensuring archive snapshots/registry/indexes always accumulate on main (R-CM-026 / R-CM-030 conformance).
 *
 * **Synchronous only**: `fn` must be a synchronous function (restored via try/finally). To prevent overrides
 * from leaking between async calls, archive cores use sync fs exclusively. As webui is single-process and single-user,
 * module variables + sync scopes suffice without AsyncLocalStorage (avoiding over-engineering).
 */
let _projectDirOverride = null;

/**
 * Base for worktree_local resolution (override > PROJECT_DIR). Used in getPipelineDataRoot + saga state dir, etc.
 * system_persistent resolution (resolveSystemPersistentRoot) does not use this function and remains unaffected by overrides.
 * @returns {string} Absolute path
 */
export function getProjectDir() {
  return _projectDirOverride || PROJECT_DIR;
}

/**
 * Executes synchronous function `fn` with `dir` overriding worktree_local base, returning the result.
 * Always restores previous override after execution (including on throw) (re-entrant safe — preserves previous value).
 *
 * @template T
 * @param {string} dir - Worktree absolute/relative path. Falsy value clears override.
 * @param {() => T} fn - Synchronous callback
 * @returns {T}
 */
export function withProjectDirOverride(dir, fn) {
  const prev = _projectDirOverride;
  _projectDirOverride = dir ? resolve(dir) : null;
  try {
    return fn();
  } finally {
    _projectDirOverride = prev;
  }
}

/**
 * Cache for system_persistent root (determined via 1 git call).
 * null = not yet resolved, false = resolution failed (PROJECT_DIR fallback finalized).
 */
let _systemPersistentRootCache = null;

/**
 * Returns single SSOT root for system_persistent category (R-CM-030 worktree unification).
 *
 * Priority:
 *   1. Explicit process.env.HARNESS_SYSTEM_ROOT (test isolation / override)
 *   2. Parent of git rev-parse --git-common-dir (= main worktree root)
 *   3. PROJECT_DIR fallback (outside git / non-worktree / git call failure)
 *
 * Return value is parent directory path of `.harness` (absolute path). Caller assembles
 * `.harness/system/...` via join.
 *
 * **Caution on pitfall**: Despite the name "system_persistent root", this is *not the system file path*.
 * Returns only `<root>`, requiring caller to assemble `.harness/system/<filename>`.
 * For direct access to system files, `resolveSystemFile(filename)` is recommended — automatically
 * computing `.harness/system/<filename>` absolute path + handling new vs legacy path fallbacks.
 * Directly joining raw root (e.g., `join(root, 'learnings.jsonl')`) is an anti-pattern appending files to main root.
 *
 * This function never throws — degrades gracefully to fallback on git failures.
 *
 * @param {object} [opts]
 * @param {string} [opts.cwd=PROJECT_DIR] - Git invocation cwd (for test isolation)
 * @param {boolean} [opts.bustCache=false] - Cache invalidation (for testing)
 * @returns {string} Absolute path
 */
export function resolveSystemPersistentRoot(opts = {}) {
  const { cwd = PROJECT_DIR, bustCache = false } = opts;

  if (process.env.HARNESS_SYSTEM_ROOT) {
    return resolve(process.env.HARNESS_SYSTEM_ROOT);
  }

  // R-CM-030: vitest sandbox isolation. Uses CLAUDE_PROJECT_DIR as system_persistent root
  // when HARNESS_TEST_SANDBOX=1 (ignoring git common-dir). Enforces not mutating main repo system
  // even when running vitest inside worktrees.
  if (process.env.HARNESS_TEST_SANDBOX === '1' && process.env.CLAUDE_PROJECT_DIR) {
    return resolve(process.env.CLAUDE_PROJECT_DIR);
  }

  if (!bustCache && _systemPersistentRootCache !== null) {
    return _systemPersistentRootCache || PROJECT_DIR;
  }

  try {
    const out = execFileSync('git', ['rev-parse', '--git-common-dir'], {
      cwd,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
      // An inherited GIT_DIR would override `cwd` and fork the shared system root.
      env: withoutInheritedRepository(),
    }).trim();
    if (!out) {
      _systemPersistentRootCache = false;
      return PROJECT_DIR;
    }
    const absGitDir = resolve(cwd, out);
    const mainWorktreeRoot = dirname(absGitDir);
    _systemPersistentRootCache = mainWorktreeRoot;
    return mainWorktreeRoot;
  } catch {
    _systemPersistentRootCache = false;
    return PROJECT_DIR;
  }
}

/**
 * Checks whether an arbitrary path is a project using harness pipeline (contains `.harness/` marker).
 * Unlike other functions such as resolveSystemPersistentRoot(), this is used to check **arbitrary external paths
 * outside the current process root** (e.g., other worktrees, transplant-bundle target projects) —
 * e.g., when create-pr/ops.mjs determines preservation candidates for run artifacts from another worktree.
 * @param {string} root - Absolute or relative path to check
 * @returns {boolean}
 */
export function hasHarnessMarker(root) {
  return existsSync(join(root, '.harness'));
}

/**
 * Runtime data root (e.g., `.harness/` or artifact `docs/discovery/`) — env-aware + project-config-aware (lazy lookup).
 *
 * Priority (evaluated on each invocation):
 *   1. String in <PROJECT_DIR>/project-config.json#pipeline_data_root → join(PROJECT_DIR, path)
 *   2. fallback → join(PROJECT_DIR, '.harness')
 *
 * **Lazy lookup (User decision 2026-05-25 Option 3)**: Function rather than const — reads project-config.json
 * synchronously on every invocation. R-CM-026 Rule 8 single entry point SSOT: Only this module contains `.harness` literal;
 * other modules like pipeline-config import and delegate to this function.
 *
 * **Security guard**: Silent fallback if pipeline_data_root contains absolute paths (`/...`) or path traversals (`..`)
 * (conforming to R-CM-006 Rule 2 fail-open). Provides defense-in-depth even though artifact project-config.json is generated by scaffold-deploy.
 *
 * **Performance**: Performs disk I/O on each call. Recommended for callers in hot loops to cache results in local variables.
 *
 * @returns {string} Absolute path
 */
export function getPipelineDataRoot() {
  // worktree_local base — relative to that worktree when withProjectDirOverride is applied (R-CM-035 Exception 5).
  const base = getProjectDir();
  const configPath = join(base, 'project-config.json');
  if (existsSync(configPath)) {
    try {
      const config = JSON.parse(readFileSync(configPath, 'utf-8'));
      const raw = config?.pipeline_data_root;
      if (typeof raw === 'string') {
        const trimmed = raw.trim();
        // Security guard (intentionally strict): empty string / absolute path / path containing `..` substring → silent fallback.
        // Rejects paths like `docs..v2` — assumes `pipeline_data_root` is a simple directory name (e.g., `docs/discovery`).
        if (trimmed.length > 0 && !trimmed.startsWith('/') && !trimmed.includes('..')) {
          return join(base, trimmed);
        }
      }
    } catch {
      // Silent fallback on JSON parse failure, etc.
    }
  }
  return join(base, '.harness');
}

/**
 * `.harness/system/` — System persistent assets (registry, learnings, etc.).
 *
 * **Lazy lookup**: Follows lookup result of getPipelineDataRoot().
 *
 * @returns {string} Absolute path
 */
export function getSystemRoot() {
  return join(getPipelineDataRoot(), 'system');
}

/**
 * `.harness/runs/` — Run-scoped artifact root.
 *
 * @returns {string} Absolute path
 */
export function getRunsRoot() {
  return join(getPipelineDataRoot(), 'runs');
}

/**
 * `.harness/governance/` — Governance persistent assets (handoff/retrospectives/audits).
 *
 * @returns {string} Absolute path
 */
export function getGovernanceRoot() {
  return join(getPipelineDataRoot(), 'governance');
}

/**
 * `.harness/inbox/` — Staging reference materials before pipeline execution.
 *
 * @returns {string} Absolute path
 */
export function getInboxRoot() {
  return join(getPipelineDataRoot(), 'inbox');
}

/**
 * `.harness/transplants/` — transplant system (separate layout).
 *
 * @returns {string} Absolute path
 */
export function getTransplantsRoot() {
  return join(getPipelineDataRoot(), 'transplants');
}

/**
 * `.harness/archives/` — Root for sealed idea archive snapshots.
 *
 * **Based on system_persistent root** (main worktree, user decision 2026-05-14). Ensures archive-and-reset
 * outputs from each worktree sync to main, preserving cross-idea archive accumulation. While `.harness/run/active.json`
 * is worktree-local (isolated per session), archives are shared across worktrees.
 *
 * Independent of getPipelineDataRoot() lookup — based on system_persistent root, unaffected by project-config.json
 * `pipeline_data_root`. Has no meaning in artifacts (Perspective 2). **Exclusive cross-idea asset for main framework (Perspective 1)**.
 *
 * @returns {string} Absolute path
 */
export function getArchivesRoot() {
  return join(resolveSystemPersistentRoot(), '.harness', 'archives');
}

/**
 * `.harness/_archive/` — Governance / raw history archive root.
 *
 * @returns {string} Absolute path
 */
export function getArchiveRoot() {
  return join(getPipelineDataRoot(), '_archive');
}

// ═══════════════════════════════════════════════════════════════
// system category (system_persistent lifecycle)
// ═══════════════════════════════════════════════════════════════

/**
 * `.harness` root for system_persistent lookups, given an optional explicit project root.
 *
 * **One resolution rule regardless of how the root arrives**: a worktree always resolves to the
 * main worktree that owns it. Previously an explicit `projectDir` skipped
 * `resolveSystemPersistentRoot()` outright, so the SSOT guarantee (R-CM-014 Rule 1 / R-CM-034
 * Rule 4) held only through the `<wt>/.harness/system → <main>/.harness/system` symlink —
 * a worktree missing that symlink forked system_persistent silently on write. That failure is
 * unattended, not merely unlikely: `worktree-system-symlink-guard` inspects **only the cwd's own
 * worktree** and returns passthrough when cwd is the main worktree
 * (`worktree-system-symlink-guard.mjs:81-82`), which is where sessions actually run — measured
 * 2026-09-05, `{}` at cwd=main versus a correct `absent` report at cwd=<symlink-less worktree>.
 * So the symlink was the sole load-bearing layer while its verifier never looked at it.
 *
 * Derivation is **pure path** (R-CM-037): no git call, no cache. That is what keeps test
 * isolation intact — sandbox roots live outside `.worktrees/`, resolve to themselves, and never
 * leak into the real repo the way a git-based lookup would when it fails and falls back to
 * PROJECT_DIR.
 *
 * @param {string} [projectDir] - Explicit project root. Absent → system_persistent root.
 * @returns {string} Absolute path to the `.harness` directory
 */
function systemRootFor(projectDir) {
  if (!projectDir) return join(resolveSystemPersistentRoot(), '.harness');
  const abs = resolve(projectDir);
  return join(resolveMainRepoRoot(abs) ?? abs, '.harness');
}

/**
 * Resolves system category file path.
 *
 * Priority (R-CM-030 worktree unification):
 *   1. New path exists at the resolved system_persistent root → that path
 *   2. Legacy path (.harness/<filename>) exists there + new path absent → legacy path (P3 legacy fallback)
 *   3. Both absent: new path (write target)
 *
 * @param {string} filename - Filename (e.g., "learnings.jsonl", "registry.json")
 * @param {string} [projectDir] - Explicit project root (test isolation). A worktree path resolves to
 *   its main worktree, so this narrows *which repo*, never *which worktree* — see `systemRootFor`.
 *   **Caution**: If `filename === 'active-run.json'`, this argument is ignored and delegated to `getActiveRunPath()`
 *   (worktree_local lifecycle, R-CM-026 2026-05-14). Callers requiring worktree isolation of active-run state should use `getActiveRunPath()` directly.
 * @returns {string} Absolute path
 */
export function resolveSystemFile(filename, projectDir) {
  // Automatically delegated as active-run.json was separated into worktree_local (R-CM-026 `run` category).
  // Explicit projectDir is ignored — getActiveRunPath automatically resolves PROJECT_DIR (worktree-local).
  if (filename === 'active-run.json') return getActiveRunPath();
  const root = systemRootFor(projectDir);
  const newPath = join(root, 'system', filename);
  const oldPath = join(root, filename);
  if (existsSync(newPath)) return newPath;
  if (existsSync(oldPath)) return oldPath;
  return newPath;
}

/**
 * Resolves system/session-history/ directory path.
 *
 * @param {string} [projectDir] - Explicit project root (test isolation). Defaults to system_persistent root.
 * @returns {string} Absolute path
 */
export function resolveSessionHistoryDir(projectDir) {
  return join(systemRootFor(projectDir), 'system', 'session-history');
}

// ═══════════════════════════════════════════════════════════════
// active run query
// ═══════════════════════════════════════════════════════════════

/**
 * Returns active-run state file path (worktree-local).
 *
 * **User decision 2026-05-14 per-worktree run isolation**: active-run state is
 * isolated per worktree (multi-session safe). Unlike shared system assets (pipeline-memory, etc.),
 * resolves to `.harness/run/active.json` relative to PROJECT_DIR.
 *
 * Legacy fallback (incremental migration + test fixture compatibility):
 *   1. `<wt>/.harness/run/active.json` exists → that path
 *   2. `system/active-run.json` exists at system_persistent root → that path (P3 legacy)
 *   3. `.harness/active-run.json` flat path exists at system_persistent root → that path (P3 flat)
 *   4. All absent: new path (write target)
 *
 * @returns {string} Absolute path
 */
export function getActiveRunPath() {
  const newPath = join(getPipelineDataRoot(), 'run', 'active.json');
  if (existsSync(newPath)) return newPath;
  const systemRoot = resolveSystemPersistentRoot();
  const systemLegacy = join(systemRoot, '.harness', 'system', 'active-run.json');
  if (existsSync(systemLegacy)) return systemLegacy;
  const flatLegacy = join(systemRoot, '.harness', 'active-run.json');
  if (existsSync(flatLegacy)) return flatLegacy;
  return newPath;
}

/**
 * Collects active-run.json candidate paths across main + all worktrees (.worktrees/**).
 * Because active-run is worktree_local (R-CM-026 `run` category, user decision 2026-05-14),
 * cross-worktree running guards must check active status in each worktree individually.
 * Caller determines path existence (returns candidates regardless of presence — fail-open).
 *
 * @param {string} [projectDir=PROJECT_DIR] Project root
 * @returns {string[]} List of active-run.json absolute paths (main 1 + worktree N)
 */
export function listAllActiveRunPaths(projectDir = PROJECT_DIR) {
  // Worktree-local isolated scan: inspects each worktree's .harness/run/active.json directly.
  const paths = [join(projectDir, '.harness', 'run', 'active.json')];
  const worktreesRoot = join(projectDir, '.worktrees');
  if (!existsSync(worktreesRoot)) return paths;
  // Filters directories only via withFileTypes — prevents misinterpreting files (.DS_Store, etc.)
  // as branch segments or over-scanning worktree internals (node_modules/src, etc.).
  let level1 = [];
  try {
    level1 = readdirSync(worktreesRoot, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
  } catch {
    return paths;
  }
  for (const entry of level1) {
    const entryPath = join(worktreesRoot, entry);
    paths.push(join(entryPath, '.harness', 'run', 'active.json'));
    // 2-depth branches like feature/foo, fix/bar explored one level deeper (directories only)
    let level2 = [];
    try {
      level2 = readdirSync(entryPath, { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => d.name);
    } catch {
      continue;
    }
    for (const sub of level2) {
      paths.push(join(entryPath, sub, '.harness', 'run', 'active.json'));
    }
  }
  return paths;
}

/**
 * Returns run_id from active-run.json (or null if idle/absent).
 *
 * @returns {string|null}
 */
export function getActiveRunId() {
  try {
    const path = getActiveRunPath();
    if (!existsSync(path)) return null;
    const data = JSON.parse(readFileSync(path, 'utf-8'));
    if (!data || data.status === 'idle') return null;
    return data.run_id || null;
  } catch {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════
// run-scoped category (run_scoped lifecycle)
// ═══════════════════════════════════════════════════════════════

/**
 * Resolves run-scoped category directory path.
 *
 * @param {string} subdir - Subdirectory (e.g., "stage-output", "handoff", "reports", "references")
 * @returns {string} Absolute path
 */
export function resolveRunScopedDir(subdir) {
  const runId = getActiveRunId();
  if (runId) {
    return join(getRunsRoot(), runId, subdir);
  }
  // New path if active is absent (mkdir required at write time)
  return join(getRunsRoot(), '_unassigned', subdir);
}

/**
 * Run-scoped category directory (specifying a particular run_id).
 *
 * @param {string} runId - run_id (e.g., "harness-20260428-104115")
 * @param {string} subdir
 * @returns {string} Absolute path
 */
export function resolveRunScopedDirFor(runId, subdir) {
  if (!runId) return resolveRunScopedDir(subdir);
  return join(getRunsRoot(), runId, subdir);
}

/**
 * Returns root directory of the current active run.
 * Used to determine locations of run-level assets (inbox-manifest.json, etc.) rather than category subdirectories.
 *
 * Priority:
 *   1. Active run_id present → .harness/runs/<run_id>/
 *   2. Active absent → null
 *
 * @returns {string|null} Absolute path or null
 */
export function resolveActiveRunDir() {
  const runId = getActiveRunId();
  if (!runId) return null;
  return join(getRunsRoot(), runId);
}

/**
 * Returns idea-memory.json file path (R-CM-014 P3, 2026-05-06).
 *
 * `runs/{active}/idea-memory.json` category in R-CM-026 layout SSOT (lifecycle: run_scoped).
 * Applies R-CM-028 Two-Perspective Boundary data separation — per-idea fact store isolated
 * from system pipeline-memory.json. Sealed together during archive-and-reset Phase 7.
 *
 * Priority:
 *   1. runId specified → .harness/runs/<runId>/idea-memory.json (usable as write target)
 *   2. runId omitted + active run_id present → idea-memory of active run
 *   3. runId omitted + active absent → null (idea-memory absent in idle state)
 *
 * @param {string} [runId] - Explicit run_id. Uses active if null or undefined.
 * @returns {string|null} Absolute path or null (when idle and runId omitted)
 */
export function resolveIdeaMemoryPath(runId) {
  if (runId) return join(getRunsRoot(), runId, 'idea-memory.json');
  const active = getActiveRunId();
  if (!active) return null;
  return join(getRunsRoot(), active, 'idea-memory.json');
}

// ═══════════════════════════════════════════════════════════════
// governance category (permanent lifecycle)
// ═══════════════════════════════════════════════════════════════

/**
 * Returns governance subdirectory path.
 *
 * @param {string} subdir - "handoff" | "retrospectives" | "audits" | other governance category
 * @param {string} [projectDir=PROJECT_DIR] - Project root override (for test isolation)
 * @returns {string} Absolute path
 */
export function resolveGovernanceDir(subdir, projectDir = PROJECT_DIR) {
  const root =
    resolve(projectDir) === PROJECT_DIR
      ? getGovernanceRoot()
      : join(resolve(projectDir), relative(PROJECT_DIR, getGovernanceRoot()));
  return join(root, subdir);
}

/**
 * Returns archive subdirectory path.
 *
 * @param {string} subdir - Subdirectory inside archive
 * @param {string} [projectDir=PROJECT_DIR] - Project root override (for test isolation)
 * @returns {string} Absolute path
 */
export function resolveArchiveDir(subdir, projectDir = PROJECT_DIR) {
  const root =
    resolve(projectDir) === PROJECT_DIR
      ? getArchiveRoot()
      : join(resolve(projectDir), relative(PROJECT_DIR, getArchiveRoot()));
  return join(root, subdir);
}
