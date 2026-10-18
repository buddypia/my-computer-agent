#!/usr/bin/env node

/**
 * harness-lint-guard.mjs — PostToolUse Edit/Write Hook (CLI-agnostic)
 *
 * Right after an edit to the agent harness — `AGENTS.md`, `CLAUDE.md`, `.agents/skills/**`, or a hooks file
 * (`.claude/settings.json`, `.codex/hooks.json`, `.agents/hooks.json`) — runs `Scripts/harness/check.mjs`
 * against the repository the file lives in, and blocks with the problems when it fails.
 *
 * Why a hook: the rules (AGENTS.md ≤ 8,000 chars, every skill named by a trigger line, a well-formed
 * hooks file) are the ones Google Research's harness2 found agents break most, and prose asking for them
 * is exactly what gets skipped. A skill without its trigger line is never opened, and a malformed hooks
 * file never fires — both fail silently, so the check has to sit where the write happens.
 * The gate (`Scripts/gate.sh`) runs the same check, so this is the early copy of it, not the only one.
 *
 * `run(data)` is exported and delegated to by `.cli/_cli-dispatch.mjs`.
 * Behavior: other paths / unresolved repository / check error → passthrough. Never blocks on its own failure.
 */

import { realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative } from 'node:path';
import { HookOutput } from '../lib/hook-output.mjs';
import { readStdin, output, safeHookMain, safeGit, resolveProjectDir } from '../lib/utils.mjs';
import { extractApplyPatchFilePaths } from '../lib/apply-patch-paths.mjs';
import { checkHarness } from '../../Scripts/harness/check.mjs';

const H = HookOutput.forPostToolUse();

/** Repository-relative paths that make up the harness surface. */
export function isHarnessPath(rel) {
  return (
    rel === 'AGENTS.md' ||
    rel === 'CLAUDE.md' ||
    rel === '.claude/settings.json' ||
    rel === '.codex/hooks.json' ||
    rel === '.agents/hooks.json' ||
    rel.startsWith('.agents/skills/') ||
    rel.startsWith('.claude/skills/')
  );
}

// The Codex adapter rewrites `apply_patch` into an Edit/Write carrying only the patch's first file in
// `file_path`, and keeps the patch in `tool_input.command` — so every file comes from the patch.
function editedPaths(data, projectDir) {
  const toolName = data?.tool_name || '';
  if (!['Edit', 'Write', 'MultiEdit', 'apply_patch'].includes(toolName)) return [];
  const input = data?.tool_input || {};
  const paths = extractApplyPatchFilePaths(input.command, projectDir);
  const raw = input.file_path;
  if (raw && typeof raw === 'string') paths.push(isAbsolute(raw) ? raw : join(projectDir, raw));
  return paths;
}

// git prints the resolved top level, so the file's directory is resolved too (`/tmp` → `/private/tmp`).
function realDir(file) {
  try {
    return realpathSync(dirname(file));
  } catch {
    return dirname(file);
  }
}

export async function run(data) {
  try {
    const projectDir = resolveProjectDir(data);
    const roots = new Set();
    for (const file of editedPaths(data, projectDir)) {
      const dir = realDir(file);
      const root = safeGit('rev-parse --show-toplevel', dir, { timeout: 3000 })?.trim();
      if (!root) continue;
      const rel = relative(root, join(dir, basename(file))).replace(/\\/g, '/');
      if (!rel.startsWith('..') && isHarnessPath(rel)) roots.add(root);
    }
    for (const root of roots) {
      const { errors } = checkHarness(root);
      if (errors.length === 0) continue;
      return H.block(
        `Scripts/harness/check.mjs failed for ${root} after this edit (${errors.length} problem(s)):\n` +
          errors.map((e) => `- ${e}`).join('\n') +
          '\nFix them in the same change. Rules: .agents/skills/harness-design/SKILL.md',
      );
    }
    return H.passthrough();
  } catch (_) {
    return H.passthrough();
  }
}

if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMain(async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
