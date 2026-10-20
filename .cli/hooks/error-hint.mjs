#!/usr/bin/env node

/**
 * error-hint.mjs — PostToolUse / PostToolUseFailure Bash Hook (CLI-agnostic)
 *
 * When a command's output carries an error signature listed in `.cli/hooks/error-hints.json`, appends that
 * entry's hint to the agent's context. Nothing is blocked.
 *
 * Why a hook: Google Research's harness2 names "appending a targeted hint after an error signature that keeps
 * recurring" as a tool-loop lever — it costs nothing until the error happens, where the same advice in
 * AGENTS.md would be paid for on every turn. The table only holds errors that recurred across sessions
 * (each entry records that in `evidence`, checked by `Scripts/harness/check.mjs`).
 *
 * `run(data)` is exported and delegated to by `.cli/_cli-dispatch.mjs`.
 * Behavior: no match / unreadable table → passthrough.
 */

import { readFileSync } from 'node:fs';
import { context, passthrough } from '../lib/hook-output.mjs';
import { readStdin, output, safeHookMain } from '../lib/utils.mjs';

const TABLE = new URL('./error-hints.json', import.meta.url);

export function loadHints(url = TABLE) {
  return JSON.parse(readFileSync(url, 'utf8')).hints.map((h) => ({ ...h, re: new RegExp(h.signature) }));
}

/** The hints whose signature appears in the tool's output (PostToolUse) or error (PostToolUseFailure). */
export function matchHints(data, hints) {
  const text = [data?.tool_response, data?.error]
    .map((v) => (typeof v === 'string' ? v : JSON.stringify(v ?? '')))
    .join('\n');
  return hints.filter((h) => h.re.test(text));
}

export async function run(data) {
  try {
    const hits = matchHints(data, loadHints());
    if (hits.length === 0) return passthrough();
    const event = data?.hook_event_name === 'PostToolUseFailure' ? 'PostToolUseFailure' : 'PostToolUse';
    return context(hits.map((h) => `[error-hint:${h.id}] ${h.hint}`).join('\n'), event);
  } catch (_) {
    return passthrough();
  }
}

if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMain(async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
