#!/usr/bin/env node

/**
 * heldout-guard.mjs — PreToolUse Read/Grep/Glob/Bash Hook (CLI-agnostic)
 *
 * Denies reading the System One heldout split (`Evals/system-one/heldout.jsonl`).
 *
 * Why: heldout only measures generalisation while the agent tuning triage / routing has never seen it.
 * Once its cases are in context, `hillclimb.mjs run` scores a change against answers the author already
 * read, and a KEEP verdict stops meaning anything — and that cannot be undone by deleting the transcript.
 * AGENTS.md says "do not open it"; a rule whose breach is silent and irreversible belongs in a hook.
 *
 * Allowed: `node Scripts/eval/hillclimb.mjs …` (it reads the file itself and prints only counts) and git
 * commands that stage, commit or move the file without printing it.
 * Not covered: a shell glob that expands to the file without naming it (`cat Evals/system-one/*.jsonl`
 * is caught; `cat $(ls …)` is not). This guards against the accident, not against an adversary.
 *
 * `run(data)` is exported and delegated to by `.cli/_cli-dispatch.mjs`.
 */

import { HookOutput } from '../lib/hook-output.mjs';
import { readStdin, output, safeHookMain } from '../lib/utils.mjs';

const H = HookOutput.forPreToolUse();

// The file itself, or a glob over the directory that would include it.
const HELDOUT_RE = /system-one\/(?:heldout\.jsonl|[^\s"'/]*\*[^\s"'/]*)/;
const ALLOWED_SEGMENT_RE = /^\s*(?:node\s+\S*Scripts\/eval\/hillclimb\.mjs\b|git\s+(?:add|commit|rm|mv|status|restore|stash)\b)/;

const REASON =
  'Evals/system-one/heldout.jsonl is the heldout split: reading it makes every later hillclimb verdict ' +
  'meaningless. Score against it with `node Scripts/eval/hillclimb.mjs run` (prints counts only), and ' +
  'read Evals/system-one/train.jsonl for cases. Procedure: docs/evals/system-one.md';

/** True when a tool call would put heldout cases into context. */
export function readsHeldout(toolName, input = {}) {
  if (toolName === 'Read') return HELDOUT_RE.test(String(input.file_path ?? ''));
  if (toolName === 'Grep' || toolName === 'Glob') {
    return [input.path, input.glob, input.pattern].some((v) => typeof v === 'string' && /heldout\.jsonl/.test(v));
  }
  if (toolName === 'Bash') {
    return String(input.command ?? '')
      .split(/&&|\|\||[;|\n]/)
      .some((seg) => HELDOUT_RE.test(seg) && !ALLOWED_SEGMENT_RE.test(seg));
  }
  return false;
}

export async function run(data) {
  try {
    return readsHeldout(data?.tool_name || '', data?.tool_input) ? H.deny(REASON) : H.passthrough();
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
