/**
 * debt-resolution.mjs — Makes follow-up debt **resolution criteria** (when it can be closed) machine-readable.
 *
 * Why (Root Cause): Among 126 open debt ledger items, exactly **0 items** had resolution criteria.
 *   Because nobody recorded "what condition must become true for this debt to be resolved" at registration time,
 *   closing any debt required a human to manually read and evaluate the original description. Consequently,
 *   items only accumulated into an uninspected list — creating the temptation for age-based batch closure.
 *
 *   Attaching criteria yields two benefits simultaneously:
 *   1. Items that can be machine-evaluated are automatically closed by `sweep`.
 *   2. Items that cannot be evaluated by machine are explicitly designated as "requires human judgment",
 *      making their count visible. Silent debt becomes a measurable metric.
 *
 * Boundary (R-CM-028): boundary-uniform — Debt tracking holds identical meaning across both perspectives (R-CM-033 compliance).
 */

import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';

/**
 * Kinds of resolution criteria.
 * - `file_absent` / `file_present`: Has the file disappeared / appeared? (deletion / creation debt)
 * - `text_absent` / `text_present`: Has the string disappeared / appeared in file? (TODO removal / guard addition)
 * - `manual`: Cannot be evaluated by machine — **reason is required**. Selecting this is an honest disclosure.
 */
export const RESOLUTION_KINDS = ['file_absent', 'file_present', 'text_absent', 'text_present', 'manual'];

const TEXT_KINDS = new Set(['text_absent', 'text_present']);

/**
 * CLI string -> resolution criteria object.
 *   "file_absent:.claude/scripts/x.mjs"
 *   "text_absent:docs/a.md::92 skills"      <- Pattern follows `::` (avoids collision with path `:`)
 *   "manual:Requires human architectural decision"
 * @returns {{kind: string, target?: string, pattern?: string, reason?: string} | null} null on malformed syntax
 */
export function parseResolutionSpec(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return null;
  const sep = s.indexOf(':');
  if (sep < 0) return null;
  const kind = s.slice(0, sep).trim();
  const rest = s.slice(sep + 1).trim();
  if (!RESOLUTION_KINDS.includes(kind)) return null;

  if (kind === 'manual') return rest ? { kind, reason: rest } : null;
  if (!TEXT_KINDS.has(kind)) return rest ? { kind, target: rest } : null;

  const patIdx = rest.indexOf('::');
  if (patIdx < 0) return null;
  const target = rest.slice(0, patIdx).trim();
  const pattern = rest.slice(patIdx + 2).trim();
  return target && pattern ? { kind, target, pattern } : null;
}

/** Checks whether criteria object is usable. @returns {string|null} Problem description or null */
export function validateResolution(res) {
  if (!res || typeof res !== 'object') return 'Resolution criteria is missing';
  if (!RESOLUTION_KINDS.includes(res.kind)) return `Unknown kind: ${res.kind}`;
  if (res.kind === 'manual') {
    return typeof res.reason === 'string' && res.reason.trim().length >= 10
      ? null
      : 'manual requires at least 10 characters for reason (why it cannot be closed by machine)';
  }
  if (!res.target) return `${res.kind} requires target path`;
  if (TEXT_KINDS.has(res.kind) && !res.pattern) return `${res.kind} requires pattern`;
  return null;
}

/** Determines whether criteria is machine-checkable (non-manual and well-formed). */
export function isMachineCheckable(res) {
  return Boolean(res) && res.kind !== 'manual' && validateResolution(res) === null;
}

/**
 * Evaluates criteria against the current system state.
 * @returns {{resolved: boolean, evidence: string}}
 */
export function evaluateResolution(res, { root = process.cwd(), existsFn = existsSync, readFn = readFileSync } = {}) {
  const problem = validateResolution(res);
  if (problem) return { resolved: false, evidence: `Evaluation impossible: ${problem}` };
  if (res.kind === 'manual') return { resolved: false, evidence: `Human judgment required: ${res.reason}` };

  const abs = isAbsolute(res.target) ? res.target : join(root, res.target);
  const present = existsFn(abs);

  if (res.kind === 'file_absent') return { resolved: !present, evidence: `${res.target} ${present ? 'present' : 'absent'}` };
  if (res.kind === 'file_present') return { resolved: present, evidence: `${res.target} ${present ? 'present' : 'absent'}` };

  if (!present) {
    // If file is completely gone, strings inside are also gone — text_absent is satisfied, text_present is not.
    return { resolved: res.kind === 'text_absent', evidence: `${res.target} file itself is absent` };
  }

  let body;
  try {
    body = String(readFn(abs, 'utf-8'));
  } catch (err) {
    return { resolved: false, evidence: `Read failed: ${err.message}` };
  }
  // Search pattern as raw literal string (no regex interpretation — prevents meta-character collisions).
  const hit = body.includes(res.pattern);
  const label = `"${res.pattern}" ${hit ? 'found' : 'not found'} in ${res.target}`;
  return { resolved: res.kind === 'text_absent' ? !hit : hit, evidence: label };
}

/**
 * Sweeps open items and filters those resolvable by machine evaluation (caller handles writes).
 * @returns {{resolvable: Array, pending: Array, unspecified: Array}}
 */
export function sweepResolutions(items, opts = {}) {
  const resolvable = [];
  const pending = [];
  const unspecified = [];
  for (const item of items) {
    if (!item || item.status !== 'open') continue;
    if (!item.resolution) {
      unspecified.push(item);
      continue;
    }
    if (!isMachineCheckable(item.resolution)) {
      pending.push({ item, evidence: evaluateResolution(item.resolution, opts).evidence });
      continue;
    }
    const verdict = evaluateResolution(item.resolution, opts);
    (verdict.resolved ? resolvable : pending).push({ item, evidence: verdict.evidence });
  }
  return { resolvable, pending, unspecified };
}
