/**
 * atomic-fs.mjs — Atomic file writes + jsonl append helper for system_persistent files.
 *
 * Part of R-CM-030 worktree unification (PLAN.md S1). Prevents read-modify-write
 * race conditions when system_persistent SSOT is shared across worktrees with minimal cost
 * (assuming single-user CLI + low contention).
 *
 * Design principles:
 *   - Relies on same-directory atomicity of POSIX rename(2) (avoids external libraries)
 *   - Partial write artifacts (`<file>.tmp`) are created in the same directory before rename
 *   - jsonl uses fs.appendFile with O_APPEND (POSIX guarantees atomic writes under PIPE_BUF)
 *   - Fail-soft: Attempts tmp file cleanup on write failure
 *
 * R-CM-029 Rule 6 (Source-Driven):
 *   - Node.js fs.rename: Guarantees atomic rename within the same filesystem
 *     (Node.js docs nodejs.org/api/fs.html, accessed 2026-05-11)
 *   - POSIX write(2) O_APPEND: Guarantees atomicity for single writes under PIPE_BUF (Linux=4096)
 *     (Linux man-pages, accessed 2026-05-11)
 *   - External lockfile libraries (proper-lockfile, etc.) are over-engineering for single-user CLI —
 *     the two stdlib guarantees are sufficient.
 */

import { writeFile, rename, appendFile, mkdir, unlink } from 'node:fs/promises';
import {
  writeFileSync,
  renameSync,
  mkdirSync,
  unlinkSync,
  existsSync,
  appendFileSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { randomBytes } from 'node:crypto';

/**
 * Atomically writes a JSON object to a file.
 *
 * Operations:
 *   1. mkdir -p target directory
 *   2. Write temporary file `.<basename>.tmp.<rand>` in the same directory
 *   3. Atomic replacement via fs.rename
 *   4. Cleanup temporary file on failure
 *
 * @param {string} path - Absolute target path
 * @param {unknown} data - Serialization target (must be JSON.stringify-able)
 * @param {object} [opts]
 * @param {number} [opts.spaces=2] - spaces argument for JSON.stringify
 * @returns {Promise<void>}
 */
export async function writeJsonAtomic(path, data, opts = {}) {
  const { spaces = 2 } = opts;
  const dir = dirname(path);
  const base = path.slice(dir.length + 1);
  const rand = randomBytes(6).toString('hex');
  const tmp = join(dir, `.${base}.tmp.${rand}`);

  await mkdir(dir, { recursive: true });
  try {
    const payload = JSON.stringify(data, null, spaces) + '\n';
    await writeFile(tmp, payload, 'utf-8');
    await rename(tmp, path);
  } catch (err) {
    await unlink(tmp).catch(() => {});
    throw err;
  }
}

/**
 * Appends a line to a JSONL file.
 *
 * Since JSONL is line-oriented, it is append-only rather than read-modify-write.
 * POSIX O_APPEND mode guarantees atomicity of single writes under PIPE_BUF.
 * harness learning entries are typically under 1KB -> operates well within PIPE_BUF (Linux 4096),
 * ensuring no risk of line interleaving even under concurrent appends.
 *
 * @param {string} path - Absolute target path
 * @param {unknown} entry - Object to serialize as one line
 * @returns {Promise<void>}
 */
export async function appendJsonlAtomic(path, entry) {
  const dir = dirname(path);
  await mkdir(dir, { recursive: true });
  const line = JSON.stringify(entry) + '\n';
  await appendFile(path, line, 'utf-8');
}

/**
 * Appends a line to a JSONL file (sync version).
 *
 * Guarantees identical to appendJsonlAtomic (async sibling):
 *   - O_APPEND single write — practically atomic on Linux ext4/xfs. On macOS APFS/NFS/Windows guarantees
 *     are weaker, but harness runs single-user single-process synchronous calls without line interleaving risk.
 *   - Automatic mkdir -p for target directory
 *   - Throw on failure (prevents silent failures — R-CM-010 compliance)
 *
 * Usage locations (sync call sites — WebUI delegated mutator audit append, etc.):
 *   - decision-mutator.mjs#answerDecision (decision-answer audit trail)
 *
 * @param {string} path - Absolute target path
 * @param {unknown} entry - Object to serialize as one line
 * @returns {void}
 */
export function appendJsonlAtomicSync(path, entry) {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true });
  const line = JSON.stringify(entry) + '\n';
  appendFileSync(path, line, 'utf-8');
}

/**
 * Atomically writes a JSON object to a file (sync version).
 *
 * Guarantees identical to writeJsonAtomic:
 *   - POSIX rename(2) atomic replacement
 *   - randomBytes(6) unique tmp name — prevents multi-worktree concurrent call races
 *   - Temporary file cleanup on failure
 *   - Throw on failure (prevents silent failures — R-CM-010 compliance)
 *
 * Usage locations (sync call sites — child_process calls / CLI scripts, etc.):
 *   - followup-debt-tracker.mjs#saveDebt
 *   - archive-and-reset.mjs#writeMeta / updateArchiveIndex
 *
 * @param {string} path - Absolute target path
 * @param {unknown} data - Serialization target (must be JSON.stringify-able)
 * @param {object} [opts]
 * @param {number} [opts.spaces=2] - spaces argument for JSON.stringify
 * @returns {void}
 */
export function writeJsonAtomicSync(path, data, opts = {}) {
  const { spaces = 2 } = opts;
  const dir = dirname(path);
  const base = path.slice(dir.length + 1);
  const rand = randomBytes(6).toString('hex');
  const tmp = join(dir, `.${base}.tmp.${rand}`);

  mkdirSync(dir, { recursive: true });
  try {
    const payload = JSON.stringify(data, null, spaces) + '\n';
    writeFileSync(tmp, payload, 'utf-8');
    renameSync(tmp, path);
  } catch (err) {
    try {
      if (existsSync(tmp)) unlinkSync(tmp);
    } catch {
      /* tmp cleanup best-effort */
    }
    throw err;
  }
}

/**
 * Atomically writes plain text (markdown, etc.) to a file (sync version).
 *
 * Same guarantees as writeJsonAtomicSync, but writes raw string directly without serialization.
 *   - POSIX rename(2) atomic replacement
 *   - randomBytes(6) unique tmp name — prevents multi-worktree concurrent call races
 *   - Temporary file cleanup on failure
 *   - Throw on failure (prevents silent failures — R-CM-010 compliance)
 *
 * Caller is responsible for trailing newline (not automatically appended like JSON).
 *
 * Usage locations (sync call sites — CLI scripts replacing partial markdown outputs):
 *   - docs-index-build.mjs#writeIndex (docs/index.md AUTO section replacement)
 *
 * @param {string} path - Absolute target path
 * @param {string} text - Raw text to write (written as-is)
 * @returns {void}
 */
export function writeTextAtomicSync(path, text) {
  const dir = dirname(path);
  const base = path.slice(dir.length + 1);
  const rand = randomBytes(6).toString('hex');
  const tmp = join(dir, `.${base}.tmp.${rand}`);

  mkdirSync(dir, { recursive: true });
  try {
    writeFileSync(tmp, String(text), 'utf-8');
    renameSync(tmp, path);
  } catch (err) {
    try {
      if (existsSync(tmp)) unlinkSync(tmp);
    } catch {
      /* tmp cleanup best-effort */
    }
    throw err;
  }
}
