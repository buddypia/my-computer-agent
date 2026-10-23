#!/usr/bin/env node

/**
 * _cli-dispatch.mjs — Single universal multi-CLI hook dispatcher (R-CM-006 Rule 4 extension)
 *
 * Dynamically loads `run(data)` of one or more main hooks (comma-separated module paths) and delegates to
 * `runAdapter`. Running multiple guards for the same event in a single Node process avoids spawning 5–6
 * separate Node VMs and `git rev-parse` subshells per tool call under parallel multi-agent load.
 *
 * Usage: node _cli-dispatch.mjs <module[,module2,...]> <claude|codex|antigravity> [eventName] [hookId]
 *   - module    : Module path(s) relative to repo-root, comma-separated (e.g.,
 *                 `.cli/hooks/commit-guard.mjs,.cli/hooks/destructive-git-guard.mjs`).
 *                 Allowed boundary: `.cli/` + `.claude/hooks/` + `.claude/scripts/`.
 *   - cli       : 'claude' | 'codex' | 'antigravity' (selects normalizePayload / wire transformation)
 *   - eventName : 'PreToolUse' | 'PostToolUse' | 'PostToolUseFailure' | 'UserPromptSubmit' | 'SessionStart' | 'Stop'
 *   - hookId    : Registry `entry.id`
 */
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, sep } from 'node:path';
import { runAdapter } from './lib/cli-adapter-utils.mjs';
import { resolveCommonRepoRoot } from './lib/agent-scratchpad.mjs';
import { INHERITED_REPOSITORY_POINTERS, isDirectInvocation } from './lib/utils.mjs';

/**
 * Runs a list of resolved hook module paths sequentially in a single Node VM.
 * Short-circuits immediately on `deny` (PreToolUse) or `block` (PostToolUse/Stop).
 * Merges `allow` warnings, `additionalContext`, and `systemMessage` across passing hooks.
 *
 * @param {string[]} targets - Absolute module paths
 * @param {object} data - Normalized hook input payload
 * @param {string} [defaultEventName]
 * @returns {Promise<object>}
 */
export async function runModulesBatch(targets, data, defaultEventName) {
  const allowReasons = [];
  let updatedInput;
  const contexts = [];
  let contextEventName = defaultEventName;
  const systemMessages = [];

  for (const target of targets) {
    let run;
    try {
      ({ run } = await import(pathToFileURL(target).href));
    } catch {
      continue; // fail-open for individual missing/broken module
    }
    if (typeof run !== 'function') continue;

    let res;
    try {
      res = await run(data);
    } catch {
      continue; // fail-open
    }
    if (!res || typeof res !== 'object' || Object.keys(res).length === 0) continue;

    const hso = res.hookSpecificOutput;
    if (hso?.permissionDecision === 'deny' || res.decision === 'block') {
      return res;
    }

    if (hso?.permissionDecision === 'allow') {
      if (hso.permissionDecisionReason) allowReasons.push(hso.permissionDecisionReason);
      if (hso.updatedInput !== undefined) updatedInput = hso.updatedInput;
    }
    if (typeof hso?.additionalContext === 'string' && hso.additionalContext) {
      contexts.push(hso.additionalContext);
      if (hso.hookEventName) contextEventName = hso.hookEventName;
    }
    if (typeof res.systemMessage === 'string' && res.systemMessage) {
      systemMessages.push(res.systemMessage);
    }
  }

  if (allowReasons.length > 0 || updatedInput !== undefined) {
    return {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        ...(allowReasons.length > 0 ? { permissionDecisionReason: allowReasons.join('\n\n') } : {}),
        ...(updatedInput !== undefined ? { updatedInput } : {}),
      },
    };
  }

  if (contexts.length > 0) {
    return {
      hookSpecificOutput: {
        hookEventName: contextEventName || 'PostToolUse',
        additionalContext: contexts.join('\n\n'),
      },
    };
  }

  if (systemMessages.length > 0) {
    return { systemMessage: systemMessages.join('\n\n') };
  }

  return {};
}

async function main() {
  const [, , rawModule, cli, eventName, hookId] = process.argv;
  const mods = String(rawModule || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (mods.length === 0 || !cli) process.exit(0);

  const cliDir = resolve(fileURLToPath(new URL('.', import.meta.url))); // .../.cli
  const repoRoot = resolve(cliDir, '..'); // repo root
  const allowedRoots = [cliDir, resolve(repoRoot, '.claude', 'hooks'), resolve(repoRoot, '.claude', 'scripts')];

  const targets = [];
  for (const mod of mods) {
    if (!mod.endsWith('.mjs')) continue;
    const target = resolve(repoRoot, mod);
    const inBounds = allowedRoots.some((root) => target === root || target.startsWith(root + sep));
    if (inBounds) targets.push(target);
  }
  if (targets.length === 0) process.exit(0);

  globalThis.__HOOK_ORCHESTRATOR__ = true;
  for (const pointer of INHERITED_REPOSITORY_POINTERS) delete process.env[pointer];

  if (!process.env.CLAUDE_PROJECT_DIR) {
    process.env.CLAUDE_PROJECT_DIR = resolveCommonRepoRoot(repoRoot) || repoRoot;
  }

  if (targets.length === 1) {
    let run;
    try {
      ({ run } = await import(pathToFileURL(targets[0]).href));
    } catch {
      process.exit(0);
    }
    if (typeof run !== 'function') process.exit(0);
    await runAdapter(run, { cli, eventName, hookId });
    return;
  }

  await runAdapter((data) => runModulesBatch(targets, data, eventName), { cli, eventName, hookId });
}

if (isDirectInvocation(import.meta.url)) {
  main();
}
