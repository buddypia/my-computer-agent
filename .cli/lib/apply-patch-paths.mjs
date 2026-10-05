/**
 * apply-patch-paths.mjs — Extract target file paths for Codex `apply_patch` (pure lib SSOT)
 *
 * Codex CLI always sends `tool_name: "apply_patch"` during file editing, and the patch body
 * is contained in the `tool_input.command` string (official Codex spec: "Bash and apply_patch use
 * tool_input.command" — https://developers.openai.com/codex/hooks). This lib extracts target file
 * paths from that patch string.
 *
 * Shared by worktree-policy-guard (blocks direct editing on main) and worktree-session-owner-guard
 * (blocks cross-worktree editing). Conforms to R-CM-037 Rule 5 (no direct imports between hooks,
 * pure lib SSOT) — both hooks import this library.
 *
 * Reference: trip-jarvis `.agents/hooks/lib/worktree-policy-core.mjs#extractApplyPatchFilePaths`
 * (production-verified implementation). Parses `*** Add|Update|Delete File:` / `*** Move to:`
 * lines from apply_patch heredoc + invocation fallback.
 *
 * Boundary: Perspective 1 (harness itself) only — worktree guard hooks are not deployed to scaffolds (R-CM-028).
 */

import { isAbsolute, join } from 'path';

/**
 * Extract an array of target file absolute paths from apply_patch command string.
 *
 * @param {string} command - apply_patch patch body (tool_input.command)
 * @param {string} [baseDir] - Base directory for normalizing relative paths (kept as-is if absolute)
 * @returns {string[]} Deduplicated array of absolute paths (empty array on invalid input)
 */
export function extractApplyPatchFilePaths(command, baseDir = '') {
  if (typeof command !== 'string' || !command.trim()) return [];

  const paths = [];
  const addPath = (raw) => {
    if (!raw || typeof raw !== 'string') return;
    const p = raw.trim();
    if (!p) return;
    paths.push(isAbsolute(p) ? p : (baseDir ? join(baseDir, p) : p));
  };

  // CRLF safety: strip trailing \r after split('\n'). Since JS regex `.` does not match \r,
  // without removing \r, `(.+)$` on CRLF patch lines fails entirely → 0 paths → guard bypass (CRITICAL).
  for (const rawLine of command.split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    const hunk = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/);
    if (hunk) {
      addPath(hunk[1]);
      continue;
    }
    const move = line.match(/^\*\*\* Move to: (.+)$/);
    if (move) addPath(move[1]);
  }

  // Removed invocation fallback (blocks HIGH false positives): `(?:apply_patch|patch)\s+...` regex
  // extracted false positive paths from 'patch' keywords in patch diff lines → policy-guard false deny.
  // Since Codex apply_patch is always heredoc (`*** ... File:` markers), 0 File lines failing open
  // (empty array → passthrough, R-CM-006 Rule 2) is safer than footgun fallbacks.

  return [...new Set(paths)];
}
