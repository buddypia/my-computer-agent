/**
 * governance-writer.mjs — governance-events.jsonl append SSOT
 *
 * Appends governance events (guard deny/block triggers, secret_detected, etc.)
 * line-by-line to `.claude/state/governance-events.jsonl`.
 *
 * Design principles:
 *   - fail-safe: Write failures never impact callers (orchestrator dispatch / guard decisions).
 *   - call-time path resolution: Reads CLAUDE_PROJECT_DIR at call time for accurate multi-worktree paths.
 *   - Format: { ts: ISO8601, eventType, ...payload }.
 *
 * 2 channels (numerator/denominator):
 *   - **Firing (numerator)**: `recordFiringIfDenyBlock` → deny_fired/block_fired/notice_fired in governance-events.jsonl
 *   - **Evaluation (denominator)**: `recordHookEvaluations` → hook-eval-counters.json (dispatch reach count + errors)
 *
 * 3rd channel (skills):
 *   - **Invocation**: `recordSkillInvocation` → skill_invoked in governance-events.jsonl
 *
 * @boundary harness-only (Perspective 1).
 */

import { existsSync, mkdirSync, appendFileSync, readFileSync, realpathSync } from 'fs';
import { join, dirname } from 'path';
import { tmpdir } from 'os';
import { resolveProjectDir, isTestRun } from '../../../.cli/lib/utils.mjs';
import { writeJsonAtomicSync } from './atomic-fs.mjs';

/**
 * Temp root candidates.
 * @type {ReadonlyArray<string>}
 */
const TMP_ROOTS = Object.freeze([
  ...new Set([
    tmpdir(),
    (() => {
      try {
        return realpathSync(tmpdir());
      } catch {
        return tmpdir();
      }
    })(),
  ]),
]);

/**
 * Checks if path is under temp directory.
 * @param {string} p
 * @returns {boolean}
 */
function isUnderTmp(p) {
  return TMP_ROOTS.some((root) => p.startsWith(`${root}/`));
}

/**
 * Production ledger path.
 * @returns {string}
 */
export function productionGovernanceEventsPath() {
  return join(resolveProjectDir(), '.claude', 'state', 'governance-events.jsonl');
}

/**
 * Resolves governance-events.jsonl path relative to CLAUDE_PROJECT_DIR.
 *
 * @returns {string}
 */
export function governanceEventsPath() {
  const resolved = productionGovernanceEventsPath();
  if (isTestRun() && !isUnderTmp(resolved)) {
    return join(tmpdir(), 'harness-governance-events.test.jsonl');
  }
  return resolved;
}

/**
 * Production evaluation counter path.
 * @returns {string}
 */
export function productionHookEvalCountersPath() {
  return join(resolveProjectDir(), '.claude', 'state', 'hook-eval-counters.json');
}

/**
 * Hook evaluation counter path.
 *
 * @returns {string}
 */
export function hookEvalCountersPath() {
  const resolved = productionHookEvalCountersPath();
  if (isTestRun() && !isUnderTmp(resolved)) {
    return join(tmpdir(), 'harness-hook-eval-counters.test.json');
  }
  return resolved;
}

/** Max hookIds tracked in counter file */
export const MAX_TRACKED_HOOK_IDS = 500;

/**
 * Reads evaluation counters. Returns empty structure on missing/corrupt file (fail-safe).
 * @param {string} [path]
 * @returns {{schema_version: number, window_started_at: string|null, updated_at: string|null, hooks: Record<string, {evaluated: number, errors: number, last_evaluated_at: string, last_event: string}>}}
 */
export function readHookEvalCounters(path) {
  const empty = { schema_version: 1, window_started_at: null, updated_at: null, hooks: {} };
  try {
    const p = path || hookEvalCountersPath();
    if (!existsSync(p)) return empty;
    const parsed = JSON.parse(readFileSync(p, 'utf-8'));
    if (!parsed || typeof parsed !== 'object' || !parsed.hooks || typeof parsed.hooks !== 'object') {
      return empty;
    }
    return {
      schema_version: typeof parsed.schema_version === 'number' ? parsed.schema_version : 1,
      window_started_at: typeof parsed.window_started_at === 'string' ? parsed.window_started_at : null,
      updated_at: typeof parsed.updated_at === 'string' ? parsed.updated_at : null,
      hooks: parsed.hooks,
    };
  } catch {
    return empty;
  }
}

/**
 * In-place increment of a single counter entry.
 *
 * @param {Record<string, object>} hooks
 * @param {{id?: string, error?: boolean}} entry
 * @param {string} now - ISO timestamp
 * @param {string} hookEvent
 */
function bumpHookCounter(hooks, entry, now, hookEvent) {
  const id = entry && typeof entry.id === 'string' ? entry.id : '';
  if (!id) return;
  if (!hooks[id] && Object.keys(hooks).length >= MAX_TRACKED_HOOK_IDS) return;
  const prev = hooks[id];
  const evaluated = prev && Number.isFinite(prev.evaluated) ? prev.evaluated : 0;
  const errors = prev && Number.isFinite(prev.errors) ? prev.errors : 0;
  hooks[id] = {
    evaluated: evaluated + 1,
    errors: errors + (entry.error ? 1 : 0),
    last_evaluated_at: now,
    last_event: typeof hookEvent === 'string' ? hookEvent.slice(0, 100) : '',
  };
}

/**
 * Records cumulative hook evaluations (dispatch reach).
 *
 * @param {Array<{id: string, error?: boolean}>} entries - List of evaluated hooks in this dispatch
 * @param {string} hookEvent - PreToolUse / Stop etc.
 * @param {string} [path] - For testing injection
 * @returns {boolean} Success status
 */
export function recordHookEvaluations(entries, hookEvent, path) {
  try {
    if (!Array.isArray(entries) || entries.length === 0) return false;
    const p = path || hookEvalCountersPath();
    const now = new Date().toISOString();
    const state = readHookEvalCounters(p);
    const hooks = state.hooks;
    for (const entry of entries) bumpHookCounter(hooks, entry, now, hookEvent);
    const dir = dirname(p);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeJsonAtomicSync(p, {
      schema_version: 1,
      window_started_at: state.window_started_at || now,
      updated_at: now,
      hooks,
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * Appends a single governance event.
 * @param {{eventType: string, [key: string]: unknown}} event - eventType required. ts auto-assigned.
 * @returns {boolean} Success status
 */
export function appendGovernanceEvent(event) {
  try {
    if (!event || typeof event !== 'object' || typeof event.eventType !== 'string' || !event.eventType) {
      return false;
    }
    const eventsPath = governanceEventsPath();
    const dir = dirname(eventsPath);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const record = { ts: new Date().toISOString(), ...event };
    appendFileSync(eventsPath, JSON.stringify(record) + '\n', 'utf-8');
    return true;
  } catch {
    return false;
  }
}

/**
 * Normalizes skill name stripping prefixes (e.g. `plugin:deploy` -> `deploy`).
 * @param {unknown} raw
 * @returns {string}
 */
function normalizeSkillName(raw) {
  if (typeof raw !== 'string') return '';
  const tail = raw.trim().split(':').pop() || '';
  return /^[A-Za-z0-9._-]{1,80}$/.test(tail) ? tail : '';
}

/**
 * Records a single skill invocation.
 *
 * @param {unknown} skillName - tool_input.skill
 * @returns {boolean} Success status
 */
export function recordSkillInvocation(skillName) {
  const skill = normalizeSkillName(skillName);
  if (!skill) return false;
  return appendGovernanceEvent({ eventType: 'skill_invoked', skill });
}

/**
 * Records governance event if hook result is deny or block.
 *
 * @param {string} hookId - registry entry id
 * @param {unknown} result - hook run() return value
 * @param {string} hookEvent - PreToolUse / Stop etc.
 * @returns {boolean}
 */
/**
 * Classifies a hook result as a recordable firing (deny > block > notice), or null for a
 * plain passthrough. Advisory Stop notices (HookOutput.notice → systemMessage) count too,
 * otherwise advisory hooks are invisible to the ROI ledger and cannot be audited for liveness.
 */
function classifyFiring(result) {
  const pre = result.hookSpecificOutput;
  if (pre && pre.permissionDecision === 'deny') {
    return { eventType: 'deny_fired', reason: pre.permissionDecisionReason };
  }
  if (result.decision === 'block') return { eventType: 'block_fired', reason: result.reason };
  if (typeof result.systemMessage === 'string' && result.systemMessage.length > 0) {
    return { eventType: 'notice_fired', reason: result.systemMessage };
  }
  return null;
}

export function recordFiringIfDenyBlock(hookId, result, hookEvent) {
  try {
    if (!result || typeof result !== 'object') return false;
    const firing = classifyFiring(result);
    if (!firing) return false;
    return appendGovernanceEvent({
      eventType: firing.eventType,
      hookId: typeof hookId === 'string' ? hookId : 'unknown',
      hookEvent: typeof hookEvent === 'string' ? hookEvent.slice(0, 100) : '',
      reason: typeof firing.reason === 'string' ? firing.reason.slice(0, 500) : '',
    });
  } catch {
    return false;
  }
}

/**
 * Reads guard denials triggered within the session window (sinceMs onwards).
 *
 * @param {number|null} sinceMs - epoch ms.
 * @returns {Array<{hookId: string, hookEvent: string, ts: string}>}
 */
export function readGuardDenialsSince(sinceMs) {
  try {
    if (typeof sinceMs !== 'number' || !Number.isFinite(sinceMs)) return [];
    const eventsPath = governanceEventsPath();
    if (!existsSync(eventsPath)) return [];
    const out = [];
    for (const line of readFileSync(eventsPath, 'utf-8').split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let ev;
      try { ev = JSON.parse(trimmed); } catch { continue; }
      if (!ev || ev.eventType !== 'deny_fired') continue;
      const at = Date.parse(ev.ts);
      if (!Number.isFinite(at) || at < sinceMs) continue;
      out.push({
        hookId: typeof ev.hookId === 'string' ? ev.hookId : 'unknown',
        hookEvent: typeof ev.hookEvent === 'string' ? ev.hookEvent : '',
        ts: ev.ts,
      });
    }
    return out;
  } catch {
    return [];
  }
}
