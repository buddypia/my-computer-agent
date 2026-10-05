/**
 * cli-adapter-utils.mjs — Multi-CLI Hook Adapter Utilities
 *
 * Normalizes stdin JSON payloads from Codex CLI and Antigravity CLI (agy — Google Antigravity)
 * to main hook format (Claude Code shape `{ tool_name, tool_input, cwd }`), and converts
 * main results into wire formats expected by each CLI.
 *
 * Because main hook `run(data)` functions assume Claude stdin format, adapters are only
 * responsible for stdin schema conversion + calling main run() + CLI-specific response conversion.
 *
 * This library contains no guard domain logic (schema/IO only). Guard decisions rely on
 * exported pure functions of main hooks (`.claude/hooks/<name>.mjs`) as the SSOT.
 *
 * Antigravity hook spec source (official priority, R-CM-029 Rule 6 — re-verified 2026-07-09):
 *   - **PRIMARY (Empirical, latest)**: Full text of official documentation embedded in the installed
 *     `agy` v1.1.0 binary (`# Lifecycle Hooks (\`hooks.json\`)`, confirmed via `strings` extraction) —
 *     since the antigravity.google/docs/hooks web page is a JS SPA that could not be auto-fetched
 *     (WebFetch attempt, 2026-07-09), and 3rd-party blogs (danicat.dev / antigravitylab.net) claim
 *     conflicting schemas (paths `.antigravity/settings.json` vs `.agents/hooks.json`, matchers
 *     `run_shell_command` vs `run_command`, etc.), compiled documentation text in the binary serves
 *     as the authoritative primary source.
 *   - Cross-verification (paths only): Official repo CHANGELOG https://github.com/google-antigravity/antigravity-cli
 *     v1.0.8 — `~/.gemini/config/hooks.json` (existence of global option path is valid).
 *   Antigravity uses its own events distinct from Claude — only 5 types: **PreToolUse / PostToolUse /
 *   PreInvocation / PostInvocation / Stop** (`SessionStart` is not an official event — confirmed empirically
 *   on 2026-07-09, correcting earlier incorrect assumptions). **Structure also differs by event**:
 *   PreToolUse/PostToolUse are GROUPED (`[{matcher, hooks:[...]}]`), while Stop/PreInvocation/PostInvocation
 *   are FLAT (handler objects listed directly in event array without matcher/hooks wrapper) — previous
 *   implementations incorrectly applied GROUPED to Stop as well, likely causing `.claude/hooks.json`
 *   to be ignored due to schema invalidity (fixed in codegen: `.cli/lib/cli-hooks-codegen.mjs` `flatEvents`).
 *   stdin (`toolCall.name`/`toolCall.args`), stdout (`{decision, reason}`), and tool names (`run_command`/
 *   `write_to_file`/`replace_file_content`) were already accurate in existing implementation (re-verified empirically).
 *   (Former implementation assumed Antigravity used Gemini CLI hooks (BeforeTool/run_shell), but was corrected
 *   due to mismatch with official spec. Legacy Gemini tool aliases are retained purely for backwards-compatibility.)
 *
 * Boundary: Perspective 1 (harness itself) only — R-CM-028.
 */

import { readFileSync } from 'node:fs';
import { join, dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { downgradeStopBlock } from './hook-output.mjs';

// Defect 6 (contract-reconciliation-harness): this out-of-process dispatch path (Codex/Antigravity, via
// `_cli-dispatch.mjs` → dynamic `import()`) reads its own `harness-budget.json` rather than
// `resolveProjectDir()`'s cwd/env-derived main root — same bug class as `ecosystem-health-guard.mjs`/
// `hook-orchestrator.mjs` (Defect 7): the tree this allowlist check audits must be the tree it runs
// from. `.cli/lib/cli-adapter-utils.mjs` → repo root is two levels up.
const PROJECT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..'); // @resolve-project-dir-allow

/**
 * Stop hooks allowed to block (`harness-budget.json#stop_block_allowlist.ids`).
 *
 * Duplicated from `hook-orchestrator.mjs#loadStopBlockAllowlist` (the Claude in-process dispatch path)
 * rather than shared, because that file is a script entry point (`main()` invoked at import time via
 * top-level `main();`) and cannot be imported as a library without re-running it. Unreadable budget →
 * empty set → every Stop block downgrades (R-CM-006 Rule 2 fail-open in the direction that cannot trap
 * a session).
 */
function loadStopBlockAllowlist(projectDir) {
  try {
    const budget = JSON.parse(readFileSync(join(projectDir, 'data', 'registry', 'harness-budget.json'), 'utf-8'));
    const ids = budget?.stop_block_allowlist?.ids;
    return new Set(Array.isArray(ids) ? ids : []);
  } catch {
    return new Set();
  }
}

/**
 * Defect 6: mirrors `hook-orchestrator.mjs`'s in-process Stop-advisory downgrade for this
 * out-of-process path, which does not share that logic (`_cli-dispatch.mjs` spawns a fresh process per
 * invocation and never touches `hook-orchestrator.mjs`). Without this, a non-allowlisted guard
 * returning `decision:'block'` on Stop/SubagentStop reached `buildCliEmission` unfiltered: Codex
 * received the raw block (re-prompting the model, against the P1 stop-advisory policy) and Antigravity's
 * `toAntigravityWire` silently remapped `block`→`continue` (§Stop contract) with no allowlist check at
 * all — both bypassed `harness-budget.json#stop_block_allowlist` entirely. Applying the same
 * `downgradeStopBlock` used by `hook-orchestrator.mjs` here, before either wire conversion, closes both
 * gaps with one check; a legitimately allowlisted block still reaches `toAntigravityWire`'s
 * block→continue mapping unchanged.
 *
 * `opts.hookId` is undefined for hand-invoked commands that predate the codegen change (`renderEntry`
 * now emits the registry id as a 4th dispatcher argument) — treated as not-allowlisted (fail-safe: an
 * unresolved id downgrades rather than silently permits a block).
 */
function applyStopAdvisoryPolicy(result, opts) {
  if (opts.eventName !== 'Stop' && opts.eventName !== 'SubagentStop') return result;
  if (result?.decision !== 'block') return result;
  const allow = loadStopBlockAllowlist(PROJECT_DIR);
  if (opts.hookId && allow.has(opts.hookId)) return result;
  return downgradeStopBlock(result, opts.hookId || 'unknown-hook');
}

const STDIN_DEADLINE_MS = 1500;

/**
 * Read JSON from stdin. Returns empty object on timeout or parse failure (fail-open).
 *
 * @returns {Promise<object>}
 */
export async function readStdinJson() {
  return new Promise((resolve) => {
    let buf = '';
    const timer = setTimeout(() => resolve({}), STDIN_DEADLINE_MS);
    process.stdin.setEncoding('utf-8');
    process.stdin.on('data', (chunk) => {
      buf += chunk;
    });
    process.stdin.on('end', () => {
      clearTimeout(timer);
      try {
        resolve(JSON.parse(buf || '{}'));
      } catch {
        resolve({});
      }
    });
    process.stdin.on('error', () => {
      clearTimeout(timer);
      resolve({});
    });
  });
}

/**
 * Antigravity tool name → Claude tool name mapping table (table-driven — minimizes cyclomatic complexity).
 *
 * Official Antigravity tool names (antigravity.google/docs + danicat.dev "Mastering Hooks"):
 *   run_command / write_to_file / replace_file_content / multi_replace_file_content / view_file.
 * Legacy Gemini CLI aliases (backwards-compat — prevents regression in older environments. UNVERIFIED for Antigravity native):
 *   run_shell / shell / run_shell_command / write_file / replace / multi_replace.
 */
const ANTIGRAVITY_TOOL_MAP = {
  // Official Antigravity tool names
  run_command: 'Bash',
  write_to_file: 'Write',
  replace_file_content: 'Edit',
  multi_replace_file_content: 'MultiEdit',
  view_file: 'Read',
  // legacy Gemini CLI aliases (backwards-compat)
  run_shell: 'Bash',
  shell: 'Bash',
  run_shell_command: 'Bash',
  write_file: 'Write',
  replace: 'Edit',
  multi_replace: 'MultiEdit',
};

/**
 * Maps Antigravity tool names to Claude format. Unregistered names pass through as-is
 * (passthrough in main hook tool name branches). Empty values default to Bash.
 */
export function mapAntigravityToolName(name) {
  if (!name) return 'Bash';
  // Object.hasOwn gate — prevents Object.prototype keys like 'constructor' from leaking as functions.
  return Object.hasOwn(ANTIGRAVITY_TOOL_MAP, name) ? ANTIGRAVITY_TOOL_MAP[name] : name;
}

/**
 * Reverse mapping SSOT — Claude tool name → CLI matcher tokens (Codex / Antigravity).
 *
 * Inverse of `ANTIGRAVITY_TOOL_MAP` (CLI→Claude). Shared between `TOOL_MATCH` in `scaffold-multi-cli-hook.mjs`
 * and multi-CLI registration parity tests (`tests/unit/multi-cli-parity.test.mjs`) — eliminates duplication.
 *
 * Codex: Official canonical is Bash / apply_patch (references/codex-cli-hooks.md). shell / run_shell /
 *   run_shell_command / exec_command are defensive variants from harness convention (UNVERIFIED).
 *   apply_patch absorbs Edit / Write / MultiEdit into a single file tool.
 * Antigravity: Official tool names run_command / write_to_file / replace_file_content /
 *   multi_replace_file_content / view_file (antigravity.google/docs/hooks — inverse of ANTIGRAVITY_TOOL_MAP).
 */
export const CLAUDE_TO_CLI_MATCHERS = Object.freeze({
  Bash: {
    codex: ['Bash', 'shell', 'run_shell', 'run_shell_command', 'exec_command'],
    antigravity: ['run_command'],
  },
  Write: { codex: ['Write', 'apply_patch'], antigravity: ['write_to_file'] },
  Edit: { codex: ['Edit', 'apply_patch'], antigravity: ['replace_file_content'] },
  MultiEdit: {
    codex: ['MultiEdit', 'apply_patch'],
    antigravity: ['multi_replace_file_content'],
  },
  Read: { codex: ['Read'], antigravity: ['view_file'] },
});

/**
 * Claude tool name array → matcher token array for a given CLI (order-preserving deduplication).
 * Unregistered Claude tools pass through as-is (defensive — when main matchers contain non-standard tools).
 *
 * @param {string[]} claudeTools - Tool names from Claude matchers (e.g., ['Edit','Write'])
 * @param {'codex'|'antigravity'} cli
 * @returns {string[]}
 */
export function cliMatcherTokens(claudeTools, cli) {
  const out = [];
  for (const t of claudeTools || []) {
    const tokens = CLAUDE_TO_CLI_MATCHERS[t]?.[cli] || [t];
    for (const tok of tokens) if (!out.includes(tok)) out.push(tok);
  }
  return out;
}

/**
 * Codex tool name → Claude tool name normalization map (reverse indexed from CLAUDE_TO_CLI_MATCHERS — single matcher SSOT source).
 *
 * Background (preventing drift): Codex matchers fire dispatch for tokens in `CLAUDE_TO_CLI_MATCHERS[*].codex`
 * (including defensive variants for Bash: shell / run_shell / run_shell_command / exec_command).
 * However, normalizePayload previously normalized tool names only for Antigravity, leaving Codex as passthrough —
 * matchers received variants but normalizers did not collapse them to canonical Bash, causing main guards
 * (`tool_name === 'Bash'` branches) to fail-open by not recognizing Codex variant commands (e.g., `git push --force` in `run_shell`).
 * Reverse deriving normalization map from matcher SSOT structurally guarantees matcher ⟺ normalizer symmetry.
 *
 * apply_patch is mapped to 3 tools simultaneously (Write / Edit / MultiEdit — ambiguous) and cannot collapse
 * into a single canonical name, so it is excluded from the map — handled separately by normalizePayload via expandCodexApplyPatch.
 */
function buildCodexToolNameMap() {
  const map = Object.create(null);
  const ambiguous = new Set();
  for (const [claudeTool, perCli] of Object.entries(CLAUDE_TO_CLI_MATCHERS)) {
    for (const token of perCli.codex || []) {
      if (token in map && map[token] !== claudeTool) ambiguous.add(token);
      else map[token] = claudeTool;
    }
  }
  for (const token of ambiguous) delete map[token];
  return Object.freeze(map);
}
const CODEX_TOOL_MAP = buildCodexToolNameMap();

/**
 * Maps Codex tool names to Claude format. Unregistered names and empty values pass through as-is (passthrough
 * in main hook tool name branches). Unlike Antigravity (empty value → Bash default), Codex passes empty values
 * through to preserve existing behavior — normalization applies only to *known tokens* fired by matchers (avoiding over-mapping).
 */
export function mapCodexToolName(name) {
  if (!name) return name;
  return CODEX_TOOL_MAP[name] || name;
}

/**
 * Raw tool name → Claude canonical tool name (single entry point for per-CLI normalization).
 *   - antigravity: mapAntigravityToolName (empty value → Bash default + includes legacy aliases)
 *   - codex:       mapCodexToolName (reverse derived from matcher SSOT, empty value passthrough)
 *   - other (claude, etc.): passthrough
 */
export function normalizeCliToolName(name, cli) {
  if (cli === 'antigravity') return mapAntigravityToolName(name);
  if (cli === 'codex') return mapCodexToolName(name);
  return name;
}

/**
 * Picks directly if in Claude-compatible payload format (contains `tool_name` key).
 * Returns null if absent — caller processes alternate schema.
 */
function pickClaudeShape(data) {
  if (!data?.tool_name) return null;
  return {
    tool_name: data.tool_name,
    tool_input: data.tool_input || {},
    cwd: data.cwd || process.cwd(),
    session_id: data.session_id,
    stop_hook_active: data.stop_hook_active,
    hook_event_name: data.hook_event_name,
    // Used by PostToolUse adapter (worktree-owner-tracker) for exit_code gating. Undefined for PreToolUse.
    tool_response: data.tool_response,
  };
}

/**
 * Non-tool event fields that prompt/session hooks need after CLI normalization.
 * Tool guards ignore these keys, but UserPromptSubmit hooks lose their only
 * useful input if the adapter only returns tool_name/tool_input.
 */
function pickNonToolEventShape(data) {
  const out = {};
  // agent_id/agent_type: SubagentStart/SubagentStop guards (subagent-limit-guard/subagent-cleanup)
  // track and remove active agents by id. Missing agent_id prevents cleanup from locating filter targets,
  // accumulating ghost entries until TTL (orphans) — preserves agent_id from Codex SubagentStart/Stop payloads.
  for (const key of ['prompt', 'user_prompt', 'message', 'parts', 'source', 'turn_id', 'agent_id', 'agent_type']) {
    if (data?.[key] !== undefined) out[key] = data[key];
  }
  return out;
}

/**
 * Extracts tool name from nested/alternate payloads of each CLI.
 *   - Antigravity: `toolCall.name` (official)
 *   - Codex:       `tool.name` (nested fallback) or flat `tool_name`
 */
function extractToolName(data) {
  return data?.toolCall?.name || data?.tool?.name || data?.tool_name || '';
}

/**
 * Extracts tool input object. Prioritizes Antigravity `toolCall.args` / Codex `tool.input` / flat `input`.
 */
function extractToolInput(data) {
  return data.toolCall?.args || data.tool?.input || data.input || {};
}

/**
 * Antigravity `toolCall.args` *command* field → Claude `tool_input.command` (VERIFIED, additive).
 *
 * Antigravity passes command string of run_command as `CommandLine` (different from Gemini's `tool_input.command`) —
 * verified via Galloro migration guide + danicat.dev on 2026-06-20 (hook-specific source).
 * Because main guards (commit-guard / destructive-git-guard reading `tool_input.command`) read command,
 * missing mapping causes main guards to miss commands and fail-open (failing to block `git push --force`).
 * Key-existence additive: preserves original key (`CommandLine`) and adds Claude key (`command`) only if absent.
 */
const ANTIGRAVITY_ARG_MAP = Object.freeze({ CommandLine: 'command' });

/**
 * Candidates for *file path* field names in Antigravity write/edit tools (VERIFIED 1st priority + defensive remaining candidates).
 *
 * **`TargetFile` is finalized via official manual** (2026-07-11): Official hooks documentation §Supported Tools —
 * write_to_file / replace_file_content / multi_replace_file_content all specify `TargetFile` in Arguments
 * (antigravity-cli-hooks.md L91-95, source https://antigravity.google/docs/hooks).
 * This resolves the path aspect of DEBT-203 — 1st first-match candidate promoted to verified mapping.
 * Remaining candidates (snake_case, etc.) are maintained for defense-in-depth against future schema drift.
 *
 * Order: Specificity descending (more specific candidates prioritized in first-match). Gated only to tools
 * normalized as Write/Edit/MultiEdit — avoiding false positives on generic `path` args in run_command.
 * Args of write_to_file/replace_file_content are inherently file targets, minimizing false positive risks.
 */
const ANTIGRAVITY_PATH_FIELD_CANDIDATES = Object.freeze([
  'TargetFile', // Official finalized (antigravity-cli-hooks.md §Supported Tools, 2026-07-11)
  'target_file', // snake_case variant
  'filePath', // camelCase variant
  'absolute_path', // absolute path convention variant
  'path', // generic — applied only under edit-class tool gate (minimal false positives)
]);

/**
 * File-path probe eligibility for each *normalized* Claude tool name (SSOT).
 *
 * All normalized values (Claude names) in `ANTIGRAVITY_TOOL_MAP` must be categorized here:
 * file-edit (write/edit) tools = `true` → probe targets since path guards must inspect `file_path`.
 * command/read tools = `false` → excluded from probe to avoid false positives on generic path args in run_command.
 *
 * **Preventing drift (isomorphic to 2026-06-24 coverage-claim-scope-drift retrospective)**: Previously,
 * `PATH_PROBE_TOOLS` was an independent hardcoded set; adding a new Antigravity write tool to `ANTIGRAVITY_TOOL_MAP`
 * while omitting probe set update left that write tool without probes, risking security fail-open recurrence.
 * *Deriving* `PATH_PROBE_TOOLS` from this categorization SSOT structurally eliminates that drift,
 * while `unclassifiedProbeTools()` invariant marks unclassified additions as RED (regression: `tests/unit/cli-adapter-utils.test.mjs`).
 */
const TOOL_PATH_DISPOSITION = Object.freeze({
  Bash: false, // command — avoids false positives on generic path args
  Read: false, // read-only — not a path guard target
  Write: true, // file-edit
  Edit: true, // file-edit
  MultiEdit: true, // file-edit
});

/**
 * Tools targeted for file path probing (Claude *normalized* names). *Derived* from `TOOL_PATH_DISPOSITION` —
 * cannot drift from tool-map categorization (structurally eliminated). Includes file-edit classified tools only.
 *
 * Transparent note: If Antigravity introduces an *unregistered* write tool *in the future* (raw name not normalized
 * to any Claude tool), it will bypass the gate without probe application → fail-open remains. This cannot be closed
 * via code (no external spec available); the resolution path is registering new tools in `ANTIGRAVITY_TOOL_MAP`
 * (→ automatically normalized and probed). Documented explicitly in tripwire tests.
 */
const PATH_PROBE_TOOLS = Object.freeze(
  new Set(
    Object.entries(TOOL_PATH_DISPOSITION)
      .filter(([, isFileEdit]) => isFileEdit)
      .map(([toolName]) => toolName),
  ),
);

/**
 * Detects missing classifications (drift) — returns names in `ANTIGRAVITY_TOOL_MAP` values unclassified in `TOOL_PATH_DISPOSITION`.
 * Empty array = no drift. Adding a new write tool to tool-map without categorization returns that name,
 * causing invariant tests to fail RED → structurally blocking security fail-open recurrence.
 *
 * @param {Record<string,string>} [toolMap] - Test stub injection (default: actual ANTIGRAVITY_TOOL_MAP)
 * @returns {string[]} Unclassified normalized tool names (deduplicated, order of appearance)
 */
export function unclassifiedProbeTools(toolMap = ANTIGRAVITY_TOOL_MAP) {
  if (!toolMap || typeof toolMap !== 'object' || Array.isArray(toolMap)) return [];
  const out = [];
  const seen = new Set();
  for (const claudeName of Object.values(toolMap)) {
    if (typeof claudeName !== 'string' || seen.has(claudeName)) continue;
    seen.add(claudeName);
    if (!Object.hasOwn(TOOL_PATH_DISPOSITION, claudeName)) out.push(claudeName);
  }
  return out;
}

/**
 * Returns first non-empty string value among candidate fields (or undefined if none). Core of defensive file path probing.
 */
function probeAntigravityFilePath(args) {
  for (const cand of ANTIGRAVITY_PATH_FIELD_CANDIDATES) {
    const v = args[cand];
    if (typeof v === 'string' && v.trim().length > 0) return v;
  }
  return undefined;
}

/**
 * Candidates for *new content* field names in Antigravity write/edit tools (VERIFIED 1st/2nd priority + defensive remaining candidates).
 *
 * **Finalized via official manual** (2026-07-11, antigravity-cli-hooks.md §Supported Tools L91-95 — source https://antigravity.google/docs/hooks):
 *   - write_to_file          → `CodeContent` (corresponds to Claude Write content)
 *   - replace_file_content   → `ReplacementContent` (after edit = corresponds to Claude Edit new_string)
 *                              + `TargetContent` (before edit = corresponds to old_string, separate constant below)
 *   - multi_replace_file_content → `ReplacementChunks` (array — handled specifically in probeAntigravityChunks)
 * Previous candidate set (Contents/FileText/code/text) contained zero actual field names, leaving content scanners
 * (secret-leak-guard, etc.) fail-open on Antigravity file edits — closed via this finalization (resolving DEBT-203 content aspect).
 * Remaining generic candidates retained for defense against future schema drift.
 */
const ANTIGRAVITY_CONTENT_FIELD_CANDIDATES = Object.freeze([
  'CodeContent', // Official finalized — write_to_file (antigravity-cli-hooks.md L91)
  'ReplacementContent', // Official finalized — replace_file_content after edit (L93)
  'content', // Claude Write key — preserved in {...args} but explicit (consistent probe core)
  'new_string', // Claude Edit key — same as above
  'Contents', // PascalCase variant candidate (drift defense)
  'FileText', // Variant candidate (drift defense)
  'code', // Variant candidate (drift defense)
  'text', // Generic — applied only under edit-class tool gate
]);

/**
 * Content field *before edit* for Antigravity replace_file_content (official finalized — corresponds to Claude Edit old_string).
 * Enables coverage-threshold-guard, which requires both old and new, to operate fully in Antigravity
 * (previously partially operational as old_string was UNVERIFIED without probing).
 */
const ANTIGRAVITY_OLD_CONTENT_FIELD_CANDIDATES = Object.freeze([
  'TargetContent', // Official finalized — replace_file_content before edit (antigravity-cli-hooks.md L93)
]);

/**
 * Returns first non-empty string value among candidate fields (or undefined if none). Core of defensive content probing.
 * Unlike file_path probe, this does not trim (preserves whitespace-only as content — faithful input for scanners).
 */
function probeFirstStringField(args, candidates) {
  for (const cand of candidates) {
    const v = args[cand];
    if (typeof v === 'string' && v.length > 0) return v;
  }
  return undefined;
}

function probeAntigravityContent(args) {
  return probeFirstStringField(args, ANTIGRAVITY_CONTENT_FIELD_CANDIDATES);
}

/**
 * Extracts new/old content pair in a single pass from `ReplacementChunks` array in multi_replace_file_content.
 *
 * Official manual (L95) specifies only "array of chunks" leaving chunk internal fields undocumented —
 * probes using same candidate set under assumption that chunks are isomorphic to replace_file_content (TargetContent/ReplacementContent)
 * (UNVERIFIED — narrow once chunk fields are empirically measured). Because single-string first-match probe
 * is structurally unsuitable for array structures, chunk iteration + '\n' join passes full content to scanners.
 * Extracts new/old together in a single pass — eliminating duplicate passes over the array.
 *
 * @param {object} args - raw toolCall.args
 * @returns {{ newContent: string|undefined, oldContent: string|undefined }}
 */
function probeAntigravityChunks(args) {
  const chunks = args.ReplacementChunks;
  if (!Array.isArray(chunks) || chunks.length === 0) {
    return { newContent: undefined, oldContent: undefined };
  }
  const news = [];
  const olds = [];
  for (const chunk of chunks) {
    if (!chunk || typeof chunk !== 'object') continue;
    const n = probeFirstStringField(chunk, ANTIGRAVITY_CONTENT_FIELD_CANDIDATES);
    if (n !== undefined) news.push(n);
    const o = probeFirstStringField(chunk, ANTIGRAVITY_OLD_CONTENT_FIELD_CANDIDATES);
    if (o !== undefined) olds.push(o);
  }
  return {
    newContent: news.length > 0 ? news.join('\n') : undefined,
    oldContent: olds.length > 0 ? olds.join('\n') : undefined,
  };
}

/**
 * Normalizes Antigravity args → Claude tool_input (all additive, preserving original keys).
 *   1. command: `CommandLine` → `command` (VERIFIED, key-existence based).
 *   2. file_path: first-match probe on candidate fields for write/edit tools (`TargetFile` official finalized).
 *   3. content/new_string: content probe for write/edit tools (`CodeContent`/`ReplacementContent`
 *      official finalized + `ReplacementChunks` array handling).
 *   4. old_string: content before edit for replace tools (`TargetContent` official finalized) — allows
 *      coverage-threshold-guard's old/new comparison to function in Antigravity.
 *
 * @param {object} args - raw toolCall.args
 * @param {string} [normalizedToolName] - Normalized Claude tool name (for probe gating)
 * @returns {object}
 */
function mapAntigravityArgs(args, normalizedToolName) {
  if (!args || typeof args !== 'object') return {};
  const mapped = { ...args };
  // 1. command (VERIFIED) — only when key exists, does not overwrite existing command
  for (const [agKey, claudeKey] of Object.entries(ANTIGRAVITY_ARG_MAP)) {
    if (agKey in args && !(claudeKey in mapped)) mapped[claudeKey] = args[agKey];
  }
  // 2~4. file_path + content + old_string probe — edit-class tools only
  if (PATH_PROBE_TOOLS.has(normalizedToolName)) applyAntigravityEditProbes(args, mapped);
  return mapped;
}

/**
 * Applies file_path/content/old_string probes for edit-class tools (separated helper for mapAntigravityArgs —
 * reduces cyclomatic complexity). Enriches mapped in-place (additive — does not overwrite existing keys).
 */
function applyAntigravityEditProbes(args, mapped) {
  if (!('file_path' in mapped)) {
    const probedPath = probeAntigravityFilePath(args);
    if (probedPath !== undefined) mapped.file_path = probedPath;
  }
  // Populate both content (read by Write main) and new_string (read by Edit main) if absent — avoids tool branching.
  // Single string fields take priority, falling back to ReplacementChunks array (multi_replace_file_content, single pass).
  const chunkProbe = probeAntigravityChunks(args);
  const probedContent = probeAntigravityContent(args) ?? chunkProbe.newContent;
  if (probedContent !== undefined) {
    if (!('content' in mapped)) mapped.content = probedContent;
    if (!('new_string' in mapped)) mapped.new_string = probedContent;
  }
  const probedOld =
    probeFirstStringField(args, ANTIGRAVITY_OLD_CONTENT_FIELD_CANDIDATES) ?? chunkProbe.oldContent;
  if (probedOld !== undefined && !('old_string' in mapped)) mapped.old_string = probedOld;
}

/**
 * Resolves invocation cwd: explicit cwd → session.cwd → Antigravity workspacePaths[0] → process.cwd().
 */
function resolveCwd(data) {
  if (data.cwd) return data.cwd;
  if (data.session?.cwd) return data.session.cwd;
  if (Array.isArray(data.workspacePaths) && data.workspacePaths[0]) return data.workspacePaths[0];
  return process.cwd();
}

/**
 * Directory an Antigravity `run_command` executes in (`toolCall.args.Cwd`), as `commandCwd`.
 *
 * Kept apart from `cwd` on purpose: `cwd` feeds `resolveProjectDir` (project root), while `Cwd` is
 * wherever the command runs — often a linked worktree. Folding it into `cwd` (an earlier fork
 * did) moves the project root with every command. Bash guards that judge where a command
 * starts (commit-guard, worktree-policy-guard, worktree-session-owner-guard) read it through the
 * shared `withCommandCwd` (lib/utils.mjs). A relative `Cwd` resolves against `cwd`. Claude / Codex
 * payloads never carry it (undefined → field omitted). Lowercase `args.cwd` is not read: the
 * Antigravity manual documents only `Cwd`, and no captured payload uses the lowercase form.
 */
function deriveAntigravityCommandCwd(data, cwd, cli) {
  const raw = cli === 'antigravity' ? data.toolCall?.args?.Cwd : undefined;
  if (typeof raw !== 'string' || raw.length === 0) return undefined;
  return resolvePath(cwd, raw);
}

/**
 * Parses Codex `apply_patch` command string to extract { op, filePath, newContent, oldContent }.
 *
 * In Codex file editing, tool_name is always `apply_patch` and the patch body is contained in tool_input.command
 * (official: references/codex-cli-hooks.md L464/L473 — "apply_patch use tool_input.command",
 * "hook input still reports tool_name: 'apply_patch'"). Without this function, main guards gating Edit|Write
 * via tool_name or reading new_string/old_string/content (secret-leak-guard / coverage-threshold-guard, etc.)
 * resulted in PASSTHROUGH (disabled) in Codex apply_patch — empirically confirmed (2026-06-26).
 *
 * apply_patch format (OpenAI/Codex standard):
 *   *** Begin Patch
 *   *** (Add|Update|Delete) File: <path>
 *   @@ <optional context>
 *    unchanged line
 *   -removed line   (→ oldContent, Edit old_string)
 *   +added line     (→ newContent, Edit new_string / Write content)
 *   *** End Patch
 *
 * Collects first file path as file_path, and +/- lines from entire patch as content (in multi-file patches,
 * first file path + all added/removed — for content scanners, over-scanning is safer than under-scanning; single file is common case).
 * `+++`/`---` diff headers are excluded from content (prefix is not a single `+`/`-`). Returns null on unparseable input (fail-open).
 *
 * @param {string} command - apply_patch body string
 * @returns {{op:string, filePath:string, newContent:string, oldContent:string}|null}
 */
export function parseApplyPatch(command) {
  if (typeof command !== 'string' || command.length === 0) return null;
  const lines = command.split(/\r?\n/);
  let filePath = '';
  let op = '';
  const added = [];
  const removed = [];
  for (const line of lines) {
    const m = /^\*\*\*\s+(Add|Update|Delete)\s+File:\s*(.+?)\s*$/.exec(line);
    if (m) {
      if (!filePath) {
        op = m[1].toLowerCase();
        filePath = m[2];
      }
      continue;
    }
    // Diff headers (`+++ b/path` / `--- a/path`) always have spaces following the markers → matching up to space
    // avoids mis-filtering content lines (e.g., added lines starting with `++` like `+++x`).
    if (line.startsWith('+++ ') || line.startsWith('--- ')) continue;
    if (line.startsWith('+')) added.push(line.slice(1));
    else if (line.startsWith('-')) removed.push(line.slice(1));
  }
  if (!filePath) return null;
  return { op, filePath, newContent: added.join('\n'), oldContent: removed.join('\n') };
}

/**
 * Expands Codex apply_patch payload into Claude Edit/Write shape (remapping tool_name + extracting content).
 *   - Add File    → Write (tool_input.content = newContent)
 *   - Update File → Edit  (tool_input.new_string = newContent, old_string = oldContent)
 *   - Delete File → Edit  (file_path only; no content)
 * Preserves original tool_input.command (additive). Retains original shape on unparseable input (fail-open — preserves apply_patch).
 *
 * Side effect (intended improvement): By populating file_path, existing Codex Edit|Write ports (worktree-policy-guard /
 * worktree-session-owner-guard) resolve latent gaps where they were previously ineffective due to missing file_path.
 *
 * @param {object} shape - Result of pickClaudeShape (where tool_name==='apply_patch')
 * @returns {object}
 */
export function expandCodexApplyPatch(shape) {
  const parsed = parseApplyPatch(shape.tool_input?.command);
  if (!parsed) return shape;
  const isWrite = parsed.op === 'add';
  const toolInput = { ...shape.tool_input, file_path: parsed.filePath };
  if (isWrite) {
    toolInput.content = parsed.newContent;
  } else {
    toolInput.new_string = parsed.newContent;
    toolInput.old_string = parsed.oldContent;
  }
  return { ...shape, tool_name: isWrite ? 'Write' : 'Edit', tool_input: toolInput };
}

/**
 * Normalizes stdin payload of each CLI to Claude Code format.
 *
 * Schema (cross-checked official documentation):
 *   - Claude Code:   { tool_name, tool_input: { command, file_path, ... }, cwd, session_id, ... }
 *   - Codex CLI:     same schema (flat) + turn_id / permission_mode extensions
 *                    (https://developers.openai.com/codex/hooks)
 *   - Antigravity:   { toolCall: { name: 'run_command'|'write_to_file'|..., args: {...} },
 *                    workspacePaths: [...], transcriptPath }
 *                    (https://antigravity.google/docs/hooks, danicat.dev cross-check)
 *
 * Codex `tool.name` (nested) fallback is a safety net against schema drift — currently a dead path by spec but retained for future-proofing.
 *
 * Field name mapping: Field names in Antigravity `toolCall.args` differ from Claude `tool_input`:
 *   - run_command: `CommandLine` → `command` (VERIFIED — re-verified in official manual §Supported Tools
 *     2026-07-11). `mapAntigravityArgs` applies additive mapping so main guards read commands.
 *     Without mapping, main guards failed open (failing to block `git push --force`).
 *   - File path & content fields for write/edit tools (official manual finalized 2026-07-11 — antigravity-cli-hooks.md
 *     §Supported Tools): `TargetFile` (path) / `CodeContent` (write_to_file) / `ReplacementContent`·
 *     `TargetContent` (replace_file_content new/old) / `ReplacementChunks` (multi_* array).
 *     `mapAntigravityArgs` applies additive mapping to file_path/content/new_string/old_string — enabling
 *     content scanners (secret-leak-guard) and old/new comparison guards (coverage-threshold-guard) in Antigravity.
 *
 * @param {object} data - raw stdin JSON
 * @param {'claude'|'codex'|'antigravity'} cli
 * @returns {object} Normalized payload in Claude Code format
 */
/**
 * Derives session identifier for Antigravity payloads (official manual finalized, 2026-07-11).
 *
 * While Antigravity lacks a *field named* `session_id`, common inputs across all 5 events contain
 * `conversationId` (unique UUID of active conversation) serving an equivalent role — antigravity-cli-hooks.md
 * §Common Input Fields L154 (source https://antigravity.google/docs/hooks). Previous implementation did not read
 * this field, making Layer 2 (session_id sidecar) in worktree-owner-tracker a no-op in Antigravity.
 * Mapping conversationId to session_id activates Layer 2 ownership tracking in Antigravity.
 */
function deriveSessionId(data, cli) {
  const explicit = data.session_id || data.session?.id;
  if (explicit) return explicit;
  // conversationId is an Antigravity-specific common field — gated by cli to prevent mis-deriving
  // session_id if another CLI happens to introduce a field with the same name.
  return cli === 'antigravity' ? data.conversationId : undefined;
}

/**
 * Derives stop_hook_active for Antigravity Stop payloads.
 *
 * Claude passes `stop_hook_active=true` on Stop events following resumptions triggered by stop hooks to break
 * infinite blocking loops. Antigravity lacks this field and provides only `executionNum` ("The sequence number of the execution
 * attempt" — antigravity-cli-hooks.md §Stop L348). Given example payload (L366) shows `executionNum: 1` on what appears
 * to be the initial stop, baseline is assumed to be 1, deriving `>= 2` (= re-entry after 1+ continues) as equivalent
 * to stop_hook_active — bounding blocking to at most 2 attempts even if baseline is 0 (prioritizing loop prevention,
 * exact semantics UNVERIFIED — to be finalized via smoke testing, DEBT-204).
 */
function deriveAntigravityStopHookActive(data, cli) {
  if (cli !== 'antigravity' || typeof data.executionNum !== 'number') return undefined;
  return data.executionNum >= 2;
}

/**
 * Synthesizes Claude `tool_response` from Antigravity PostToolUse `error` field.
 *
 * Antigravity PostToolUse inputs lack Claude's `tool_response` and contain only `error` (string) with detail messages
 * on failure — antigravity-cli-hooks.md §PostToolUse. Because hooks like worktree-owner-tracker filter failed commands
 * via `tool_response.exit_code !== 0` gate, `{exit_code: 1}` is synthesized only when error is non-empty
 * (undefined on success/absence — gate passes = identical semantics to Claude absence).
 */
function deriveAntigravityToolResponse(data, cli) {
  if (cli !== 'antigravity' || typeof data.error !== 'string' || data.error.trim().length === 0) {
    return undefined;
  }
  // stepIdx is an input field exclusive to Pre/PostToolUse (Stop uses executionNum — antigravity-cli-hooks.md §Stop).
  // Event-shape gate prevents mis-synthesizing Stop system errors into tool failures (tool_response).
  if (typeof data.stepIdx !== 'number') return undefined;
  return { exit_code: 1, error: data.error };
}

export function normalizePayload(data, cli) {
  if (!data || typeof data !== 'object') return { tool_name: '', tool_input: {} };

  const claudeShape = pickClaudeShape(data);
  if (claudeShape) {
    // Codex file editing sends tool_name='apply_patch' + patch body in tool_input.command — expand into Edit/Write shape
    // (otherwise Edit|Write gates and content guards remain ineffective). Other tools/CLIs pass through as-is.
    if (cli === 'codex' && claudeShape.tool_name === 'apply_patch') {
      return expandCodexApplyPatch(claudeShape);
    }
    // Codex variant tool names (flat shape — shell/run_shell/run_shell_command/exec_command) → canonical Bash.
    // Collapses to canonical Claude names via normalizeCliToolName (reverse derived from matcher SSOT) so main guard
    // branches like tool_name==='Bash' recognize them. Same processing as nested shape.
    if (cli === 'codex') {
      const canonical = normalizeCliToolName(claudeShape.tool_name, cli);
      if (canonical !== claudeShape.tool_name) return { ...claudeShape, tool_name: canonical };
    }
    return claudeShape;
  }

  const toolName = extractToolName(data);
  const normalizedName = normalizeCliToolName(toolName, cli);
  const rawInput = extractToolInput(data);
  const toolInput = cli === 'antigravity' ? mapAntigravityArgs(rawInput, normalizedName) : rawInput;
  const cwd = resolveCwd(data);
  const commandCwd = deriveAntigravityCommandCwd(data, cwd, cli);

  return {
    tool_name: normalizedName,
    tool_input: toolInput,
    cwd,
    ...(commandCwd ? { commandCwd } : {}),
    // Antigravity maps conversationId (common field, session UUID) instead of session_id — deriveSessionId mapping.
    // Transparent note: This mapping enables Layer 2 on the *comparison* side (worktree-session-owner-guard)
    // for events carrying the field (PreToolUse, etc.). The sidecar *recording* side (owner-tracker, PostToolUse)
    // remains a no-op because Antigravity PostToolUse payload lacks toolCall entirely (§PostToolUse — stepIdx/error/common fields only),
    // making commands invisible — Antigravity-created worktrees remain orphaned.
    session_id: deriveSessionId(data, cli),
    stop_hook_active: data.stop_hook_active ?? deriveAntigravityStopHookActive(data, cli),
    hook_event_name: data.hook_event_name,
    // Normalize Antigravity transcriptPath / Claude transcript_path (preserved if present).
    transcript_path: data.transcriptPath || data.transcript_path,
    tool_response: data.tool_response ?? deriveAntigravityToolResponse(data, cli),
    ...pickNonToolEventShape(data),
  };
}

/**
 * Converts main hook Claude format results into Antigravity wire format (per-event decision vocabulary branching).
 *
 * Antigravity stdout contract (official manual antigravity-cli-hooks.md, finalized 2026-07-11 — source
 * https://antigravity.google/docs/hooks):
 *   - PreToolUse: `{ "decision": "allow"|"deny"|"ask"|"force_ask", "reason": "..." }`
 *   - Stop: `decision` **recognizes only `"continue"` to prevent stopping** — "Set to \"continue\" to prevent the
 *     agent from stopping and re-enter the execution loop. Any other value allows the stop." (§Stop
 *     L358). Emitting Claude/Codex convention `"block"` is treated as "any other value" and allows stopping —
 *     previous implementations ("block honoring UNVERIFIED — emit as-is") effectively disabled all Stop guards.
 *     Corrected by mapping `block` → `continue` (main hooks maintain Claude vocabulary — SSOT unchanged).
 *   - PreInvocation (SessionStart fallback registration): Output is `{ injectSteps: [...] }` — each step is
 *     one of `toolCall`/`userMessage`/`ephemeralMessage` (§PreInvocation L275-281). Converts main hook's
 *     `hookSpecificOutput.additionalContext` into `ephemeralMessage` (transient system message).
 *   - Empty output = passthrough (allow). reason is optional.
 *
 * @param {object} result - Return value of main hook (HookOutput.deny/passthrough/block/context)
 * @param {string} [eventName] - Claude event name passed by dispatcher (for Stop/SessionStart branching)
 * @returns {object} Antigravity wire object
 */
export function toAntigravityWire(result, eventName) {
  if (!result || Object.keys(result).length === 0) return {};

  const hso = result.hookSpecificOutput;
  // SessionStart (→PreInvocation registration) context injection: additionalContext → injectSteps.ephemeralMessage.
  if (eventName === 'SessionStart' && typeof hso?.additionalContext === 'string' && hso.additionalContext) {
    return { injectSteps: [{ ephemeralMessage: hso.additionalContext }] };
  }
  // PreToolUse: Claude permissionDecision (allow|deny|ask) → Antigravity top-level decision.
  if (hso && typeof hso.permissionDecision === 'string') {
    const wire = { decision: hso.permissionDecision };
    const reason = hso.permissionDecisionReason;
    if (reason) wire.reason = reason;
    return wire;
  }
  if (typeof result.decision === 'string') {
    // Stop: Antigravity recognizes only "continue" to prevent stopping (contract comment above) — map block → continue.
    const decision = eventName === 'Stop' && result.decision === 'block' ? 'continue' : result.decision;
    const wire = { decision };
    if (result.reason) wire.reason = result.reason;
    return wire;
  }
  // Other shapes — return as-is (harmless even if ignored by Antigravity).
  return result;
}

/**
 * Main hook Claude format result → Codex PermissionRequest wire conversion (defense-in-depth).
 *
 * Codex PermissionRequest contract (official manual codex-cli-hooks.md §PermissionRequest L563-575 — source
 * https://developers.openai.com/codex/hooks): deny is recognized only as nested `hookSpecificOutput.decision:{behavior:
 * "deny", message}`. Flat `hookSpecificOutput.permissionDecision: "deny"` emitted by Claude guards is a PreToolUse schema
 * and is **ignored** in PermissionRequest events (failing to convert leaks policy violations into normal approval, failing open).
 * Therefore, converts only deny into nested shape.
 *
 * Defense-in-depth principle: Approval stage guards emit **deny only** and return null for allow/ask/passthrough to
 * delegate to Codex's normal approval flow ("If no matching hook decides, Codex uses the normal approval flow" — L579).
 * Having guards automatically approve at the approval stage bypasses user approval gates and is prohibited — reinforces
 * only *blocking* escalations like unified_exec missed by Codex PreToolUse.
 *
 * @param {object} result - Main hook return value (HookOutput.deny/passthrough, etc.)
 * @returns {object|null} Nested deny wire, or null (not conversion target → empty output = normal approval)
 */
export function toCodexPermissionRequestWire(result) {
  const hso = result?.hookSpecificOutput;
  if (hso?.permissionDecision !== 'deny') return null;
  const message = hso.permissionDecisionReason || 'Blocked by repository policy.';
  return {
    hookSpecificOutput: {
      hookEventName: 'PermissionRequest',
      decision: { behavior: 'deny', message },
    },
  };
}

/**
 * @deprecated Replaced by toAntigravityWire. Retained for backwards compatibility with existing callers (augments deny reason only).
 * Use toAntigravityWire for canonical Antigravity wire conversions.
 */
export function augmentAntigravityDenyReason(result) {
  if (result?.hookSpecificOutput?.permissionDecision !== 'deny') return result;
  if (result.reason) return result;
  const detailReason = result.hookSpecificOutput.permissionDecisionReason;
  if (!detailReason) return result;
  return { ...result, reason: detailReason };
}

/**
 * Converts main hook result (Claude format JSON) into CLI-specific wire output.
 *
 * Codex hook spec allows two modes for block/deny:
 *   1. exit 0 + stdout JSON (recommended — maintains structured response across all events)
 *   2. exit 2 + stderr reason (legacy/plain-text fallback)
 * Mixing the two as `exit 2 + stdout JSON + empty stderr` triggers a runtime error on Stop hooks:
 * "did not write a continuation prompt to stderr".
 * Therefore, adapter always uses exit 0 + stdout JSON.
 *
 * Antigravity reads top-level `{ decision, reason }` instead of Claude's `hookSpecificOutput.permissionDecision`,
 * so it is emitted after conversion via toAntigravityWire.
 *
 * @param {object} result - Main hook return value (HookOutput.deny/passthrough/block/context)
 * @param {{ cli: 'codex'|'antigravity', eventName?: string }} opts
 * @returns {{ stdout: string, stderr: string, exitCode: number }}
 */
export function buildCliEmission(result, opts = {}) {
  if (!result || Object.keys(result).length === 0) {
    return { stdout: '', stderr: '', exitCode: 0 };
  }

  if (opts.cli === 'antigravity') {
    const wire = toAntigravityWire(result, opts.eventName);
    if (!wire || Object.keys(wire).length === 0) {
      return { stdout: '', stderr: '', exitCode: 0 };
    }
    return { stdout: JSON.stringify(wire) + '\n', stderr: '', exitCode: 0 };
  }

  // Codex PermissionRequest: conversion dedicated to nested decision schema (flat permissionDecision is
  // ignored in this event). Converts only deny to nested deny; others (allow/ask/passthrough) yield empty output → normal approval flow delegation.
  if (opts.eventName === 'PermissionRequest') {
    const wire = toCodexPermissionRequestWire(result);
    if (!wire) return { stdout: '', stderr: '', exitCode: 0 };
    return { stdout: JSON.stringify(wire) + '\n', stderr: '', exitCode: 0 };
  }

  // Codex (and others): Claude format JSON passthrough + eventName label rewriting.
  let out = result;
  if (opts.eventName && result.hookSpecificOutput) {
    out = {
      ...result,
      hookSpecificOutput: {
        ...result.hookSpecificOutput,
        hookEventName: opts.eventName,
      },
    };
  }

  return {
    stdout: JSON.stringify(out) + '\n',
    stderr: '',
    exitCode: 0,
  };
}

/**
 * Emits main hook result (Claude format JSON) per CLI.
 *
 * @param {object} result - Main hook return value (HookOutput.deny/passthrough/block/context)
 * @param {{ cli: 'codex'|'antigravity', eventName?: string }} opts
 */
export function emit(result, opts = {}) {
  const emission = buildCliEmission(result, opts);
  if (emission.stdout) process.stdout.write(emission.stdout);
  if (emission.stderr) process.stderr.write(emission.stderr);
  process.exit(emission.exitCode);
}

/**
 * Standard entry point for adapters. Calls main hook's run(data) function.
 *
 * @param {Function} runFn - Main hook exported run(data) async function
 * @param {{ cli: 'codex'|'antigravity', eventName?: string, hookId?: string }} opts - `hookId` (Defect 6)
 *   is the registry id, used by `applyStopAdvisoryPolicy` to check `stop_block_allowlist` on Stop events.
 */
export async function runAdapter(runFn, opts) {
  try {
    const raw = await readStdinJson();
    // Because Antigravity lacks an official SessionStart event, registration falls back to PreInvocation (codegen
    // eventNameMap). Since PreInvocation fires on every model invocation, execute only once on `invocationNum === 0`
    // (0-indexed first invocation — antigravity-cli-hooks.md §PreInvocation L267). Skip if invocationNum is absent
    // (schema drift) — for advisory context injection hooks, no-fire is safer than duplicate injection per invocation (noise).
    if (opts.cli === 'antigravity' && opts.eventName === 'SessionStart' && raw.invocationNum !== 0) {
      process.exit(0);
    }
    const normalized = normalizePayload(raw, opts.cli);
    normalized.hook_event_name = normalized.hook_event_name || opts.eventName;
    normalized._cli = opts.cli;
    const result = applyStopAdvisoryPolicy(await runFn(normalized), opts);
    emit(result, opts);
  } catch {
    // fail-open (R-CM-006 Rule 2 conformance) — adapter failure does not block main flow
    process.exit(0);
  }
}
