#!/usr/bin/env node

/**
 * heldout-guard.mjs — PreToolUse Read/Grep/Bash Hook (CLI-agnostic)
 *
 * Denies reading the System One heldout split (`Evals/system-one/heldout.jsonl`).
 *
 * Why: heldout only measures generalisation while the agent tuning triage / routing has never seen it.
 * Once its cases are in context, `hillclimb.mjs run` scores a change against answers the author already
 * read, and a KEEP verdict stops meaning anything — and that cannot be undone by deleting the transcript.
 * AGENTS.md says "do not open it"; a rule whose breach is silent and irreversible belongs in a hook.
 *
 * Allowed: `node Scripts/eval/hillclimb.mjs …` (it reads the file itself and prints only counts), `wc`, and
 * git commands that stage, commit or move the file without printing it.
 * A repository-wide search is kept out by `.ignore` (ripgrep, so the Grep tool and `rg`), not by this hook.
 * Not covered: `grep -r x .` from the root, and indirection (`cat $(ls …)`). This guards against the
 * accident, not against an adversary.
 *
 * `run(data)` is exported and delegated to by `.cli/_cli-dispatch.mjs`.
 */

import { HookOutput } from '../lib/hook-output.mjs';
import { readStdin, output, safeHookMain } from '../lib/utils.mjs';

const H = HookOutput.forPreToolUse();

// The file itself, or a glob over the directory that would include it.
const HELDOUT_RE = /(?:^|[^\w.-])heldout\.jsonl\b|system-one\/[^\s"'/]*\*/;
// The directory as a whole, to a reader that does not honour `.ignore` (`grep -r x Evals/`).
const DIR_RE = /(?:^|[\s"'=/])(?:\.\/)?Evals(?:\/system-one)?\/?(?=[\s"']|$)/;
const DIR_READER_RE = /\b(?:grep|rg|ag|ack|cat|head|tail|less|more|awk|sed|jq|xargs|find)\b/;
const ALLOWED_SEGMENT_RE =
  /^\s*(?:node\s+\S*Scripts\/eval\/hillclimb\.mjs\b|git\s+(?:-C\s+\S+\s+)?(?:add|commit|rm|mv|status|restore|stash)\b|wc\b)/;

const REASON =
  'Evals/system-one/heldout.jsonl is the heldout split: reading it makes every later hillclimb verdict ' +
  'meaningless. Score against it with `node Scripts/eval/hillclimb.mjs run` (prints counts only), and ' +
  'read Evals/system-one/train.jsonl for cases. Procedure: docs/evals/system-one.md';

const strings = (input) => Object.values(input ?? {}).filter((v) => typeof v === 'string');

/** True when a tool call would put heldout cases into context. */
export function readsHeldout(toolName, input = {}) {
  // Every string argument: the read tools of the three CLIs name the path under different keys.
  if (toolName === 'Read') return strings(input).some((v) => HELDOUT_RE.test(v));
  // Grep is ripgrep: `.ignore` already skips the file in a search of the repository or the directory.
  if (toolName === 'Grep') return strings(input).some((v) => HELDOUT_RE.test(v));
  if (toolName === 'Bash') {
    return String(input.command ?? '')
      .split(/&&|\|\||[;|\n]/)
      .some((seg) => !ALLOWED_SEGMENT_RE.test(seg) && (HELDOUT_RE.test(seg) || (DIR_RE.test(seg) && DIR_READER_RE.test(seg))));
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
