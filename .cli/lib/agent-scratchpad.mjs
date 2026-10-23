/**
 * agent-scratchpad.mjs — Cross-worktree shared scratchpad, verification stamp cache, and Pure-FS git resolver.
 *
 * Parallel AI sessions each work in their own `.worktrees/<branch>` checkout, but they share the same
 * underlying repository (`<main>/.git`), the same immutable base commits (`origin/main`), and the same
 * machine CPU/disk. Without a shared coordination layer:
 *   1. Every tool call in `.agents/hooks.json` / `.codex/hooks.json` / `trunk-ref-guard` spawned
 *      `git rev-parse --git-common-dir` subprocesses just to locate the main repo root.
 *   2. Every worktree independently re-ran `Scripts/harness/tests/*.test.mjs` and
 *      `Scripts/trust/tests/*.test.mjs` against identical unchanged harness/trust trees.
 *   3. `pre-ship-steps.mjs`, `mark-pre-ship-confirmed.mjs`, and `ops.mjs` re-computed the same
 *      `git diff origin/main...HEAD` (for `review_diff_id`, `measureShipScale`, `myChangedFiles`)
 *      up to 8 times for the exact same `(head_sha, base_sha)` commit pair.
 *   4. Sibling worktrees had no lightweight shared board of touched files or active gate status.
 *
 * All state lives under `<main-repo-root>/.tmp/agent-scratchpad/` (gitignored, Tier-exempt).
 * Every helper here is fail-open: any I/O error returns `null`/`false` so callers fall back cleanly.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { atomicWriteJson } from './utils.mjs';
import { resolveMainRepoRoot } from './worktree-path.mjs';
import { safeBranchKey } from './worktree-plan-path.mjs';

const DEFAULT_STAMP_TTL_MS = 24 * 60 * 60 * 1000; // 24h for content-addressed tree hashes
const DEFAULT_WORKTREE_TTL_MS = 6 * 60 * 60 * 1000; // 6h for active worktree status entries

/**
 * Resolves `{ mainRoot, commonDir, gitDir, hooksDir }` using pure filesystem reads (0 subprocesses).
 *
 * Handles both the main checkout (`.git` is a directory) and linked git worktrees (`.git` is a file
 * containing `gitdir: <path>` and `<gitdir>/commondir` points back to the main `.git` directory).
 * Returns `null` if no git repository is found or if a custom `core.hooksPath` is configured in
 * `.git/config` that requires `git` config expansion.
 *
 * @param {string} startDir
 * @returns {{ mainRoot: string, commonDir: string, gitDir: string, hooksDir: string, hasCustomHooksPath: boolean } | null}
 */
export function resolveGitDirsPure(startDir) {
  if (!startDir || typeof startDir !== 'string') return null;
  try {
    let cur = resolve(startDir);
    for (let depth = 0; depth < 32; depth += 1) {
      const dotGit = join(cur, '.git');
      if (existsSync(dotGit)) {
        const st = statSync(dotGit);
        let gitDir;
        let commonDir;
        if (st.isDirectory()) {
          gitDir = dotGit;
          commonDir = dotGit;
        } else if (st.isFile()) {
          const raw = readFileSync(dotGit, 'utf-8').trim();
          const m = /^gitdir:\s*(.+)$/i.exec(raw);
          if (!m) return null;
          gitDir = isAbsolute(m[1]) ? resolve(m[1]) : resolve(cur, m[1]);
          const commonDirFile = join(gitDir, 'commondir');
          if (existsSync(commonDirFile)) {
            const relCommon = readFileSync(commonDirFile, 'utf-8').trim();
            commonDir = isAbsolute(relCommon) ? resolve(relCommon) : resolve(gitDir, relCommon);
          } else {
            commonDir = gitDir;
          }
        } else {
          return null;
        }

        const mainRoot = dirname(commonDir);
        const configPath = join(commonDir, 'config');
        let hasCustomHooksPath = false;
        if (existsSync(configPath)) {
          const cfg = readFileSync(configPath, 'utf-8');
          if (/^\s*hooksPath\s*=/im.test(cfg)) {
            hasCustomHooksPath = true;
          }
        }
        const hooksDir = join(commonDir, 'hooks');
        return { mainRoot, commonDir, gitDir, hooksDir, hasCustomHooksPath };
      }
      const parent = dirname(cur);
      if (parent === cur) break;
      cur = parent;
    }
  } catch {
    // Fall through
  }
  return null;
}

/**
 * Resolves the main checkout root directory without spawning `git`.
 *
 * @param {string} [startDir]
 * @returns {string | null}
 */
export function resolveCommonRepoRoot(startDir) {
  if (!startDir || typeof startDir !== 'string') return null;
  const fromWtPath = resolveMainRepoRoot(startDir);
  if (fromWtPath && existsSync(fromWtPath)) return fromWtPath;
  return resolveGitDirsPure(startDir)?.mainRoot ?? null;
}

/**
 * Root directory for the shared scratchpad under the main repository's `.tmp/`.
 *
 * @param {string} pathOrMainRoot
 * @returns {string | null}
 */
export function scratchpadDir(pathOrMainRoot) {
  const mainRoot = resolveCommonRepoRoot(pathOrMainRoot) || pathOrMainRoot;
  if (!mainRoot || typeof mainRoot !== 'string') return null;
  return join(mainRoot, '.tmp', 'agent-scratchpad');
}

/**
 * Checks whether a content-addressed verification stamp (`harness` or `trust`) has already been
 * verified by any worktree or `main`.
 *
 * @param {string} pathOrMainRoot
 * @param {'harness'|'trust'|string} kind
 * @param {string} treeHash
 * @param {{ ttlMs?: number }} [opts]
 * @returns {boolean}
 */
export function hasVerificationStamp(pathOrMainRoot, kind, treeHash, { ttlMs = DEFAULT_STAMP_TTL_MS } = {}) {
  if (!kind || !treeHash || !/^[a-f0-9]{12,64}$/i.test(treeHash)) return false;
  const base = scratchpadDir(pathOrMainRoot);
  if (!base) return false;
  const stampPath = join(base, 'stamps', `${kind}-${treeHash}.json`);
  try {
    if (!existsSync(stampPath)) return false;
    const ageMs = Date.now() - statSync(stampPath).mtimeMs;
    return ageMs >= -60_000 && ageMs < ttlMs;
  } catch {
    return false;
  }
}

/**
 * Records a content-addressed verification stamp so sibling worktrees with the identical
 * harness/trust tree hash can skip re-running slow test suites.
 *
 * @param {string} pathOrMainRoot
 * @param {'harness'|'trust'|string} kind
 * @param {string} treeHash
 * @param {object} [meta]
 * @returns {boolean}
 */
export function writeVerificationStamp(pathOrMainRoot, kind, treeHash, meta = {}) {
  if (!kind || !treeHash || !/^[a-f0-9]{12,64}$/i.test(treeHash)) return false;
  const base = scratchpadDir(pathOrMainRoot);
  if (!base) return false;
  const stampPath = join(base, 'stamps', `${kind}-${treeHash}.json`);
  try {
    mkdirSync(dirname(stampPath), { recursive: true });
    return atomicWriteJson(stampPath, {
      kind,
      tree_hash: treeHash,
      verified_at: new Date().toISOString(),
      pid: process.pid,
      ...meta,
    });
  } catch {
    return false;
  }
}

function worktreeSnapshotPath(pathOrMainRoot, branch) {
  const base = scratchpadDir(pathOrMainRoot);
  if (!base || !branch) return null;
  const key = safeBranchKey(branch);
  if (!key) return null;
  return join(base, 'worktrees', `${key}.json`);
}

/**
 * Reads the shared snapshot for a worktree branch.
 *
 * @param {string} pathOrMainRoot
 * @param {string} branch
 * @returns {object | null}
 */
export function readWorktreeSnapshot(pathOrMainRoot, branch) {
  const filePath = worktreeSnapshotPath(pathOrMainRoot, branch);
  if (!filePath) return null;
  try {
    if (!existsSync(filePath)) return null;
    return JSON.parse(readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

/**
 * Merges and writes a worktree's shared snapshot (diff ID, scale, changed files, gate status).
 *
 * @param {string} pathOrMainRoot
 * @param {string} branch
 * @param {object} patch
 * @returns {boolean}
 */
export function updateWorktreeSnapshot(pathOrMainRoot, branch, patch) {
  const filePath = worktreeSnapshotPath(pathOrMainRoot, branch);
  if (!filePath) return false;
  try {
    mkdirSync(dirname(filePath), { recursive: true });
    const prev = readWorktreeSnapshot(pathOrMainRoot, branch) || {};
    const next = {
      ...prev,
      ...patch,
      branch,
      updated_at: new Date().toISOString(),
    };
    return atomicWriteJson(filePath, next);
  } catch {
    return false;
  }
}

/**
 * Removes a worktree's snapshot when the worktree is cleaned up or shipped.
 *
 * @param {string} pathOrMainRoot
 * @param {string} branch
 */
export function removeWorktreeSnapshot(pathOrMainRoot, branch) {
  const filePath = worktreeSnapshotPath(pathOrMainRoot, branch);
  if (!filePath) return;
  try {
    rmSync(filePath, { force: true });
  } catch {
    // ignore
  }
}

/**
 * Lists all active worktree snapshots in the shared scratchpad whose directories still exist.
 *
 * @param {string} pathOrMainRoot
 * @param {{ ttlMs?: number }} [opts]
 * @returns {object[]}
 */
export function listActiveWorktreeSnapshots(pathOrMainRoot, { ttlMs = DEFAULT_WORKTREE_TTL_MS } = {}) {
  const base = scratchpadDir(pathOrMainRoot);
  if (!base) return [];
  const dir = join(base, 'worktrees');
  try {
    if (!existsSync(dir)) return [];
    const entries = [];
    for (const name of readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      const full = join(dir, name);
      try {
        const st = statSync(full);
        if (Date.now() - st.mtimeMs > ttlMs) continue;
        const data = JSON.parse(readFileSync(full, 'utf-8'));
        if (data?.worktree_path && !existsSync(data.worktree_path)) {
          rmSync(full, { force: true });
          continue;
        }
        entries.push(data);
      } catch {
        // skip unreadable entry
      }
    }
    return entries;
  } catch {
    return [];
  }
}

/**
 * Finds sibling worktrees that have overlapping modified files with `myFiles`.
 *
 * @param {string} pathOrMainRoot
 * @param {string} myBranch
 * @param {string[]} myFiles
 * @returns {{ branch: string, worktree_path?: string, overlapping_files: string[] }[]}
 */
export function findOverlappingWorktrees(pathOrMainRoot, myBranch, myFiles = []) {
  if (!Array.isArray(myFiles) || myFiles.length === 0) return [];
  const mySet = new Set(myFiles);
  const siblings = listActiveWorktreeSnapshots(pathOrMainRoot);
  const overlaps = [];
  for (const sib of siblings) {
    if (!sib?.branch || sib.branch === myBranch) continue;
    const files = Array.isArray(sib.changed_files) ? sib.changed_files : [];
    const shared = files.filter((f) => mySet.has(f));
    if (shared.length > 0) {
      overlaps.push({
        branch: sib.branch,
        worktree_path: sib.worktree_path,
        overlapping_files: shared,
      });
    }
  }
  return overlaps;
}
