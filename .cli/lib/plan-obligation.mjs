/**
 * plan-obligation.mjs — Primitive promoting volatile reminders to PLAN.md checkbox **obligations**.
 *
 * Why (Root cause, empirical): Reminders passed via `additionalContext` in hooks exist only for that turn.
 * Once turns advance or compaction occurs, the obligation vanishes, returning only as retroactive warnings
 * at ship time — a point where actionable remediation is no longer feasible. Across #1050, #1054, #1056,
 * #1057, and #1063 (**5 consecutive** large ships), CP-MILESTONE decks remained 0, and in #1063,
 * quality-gate PROOF was missed through the same mechanism (`ship-quality-ledger` quality_label empty).
 *
 * In contrast, PLAN.md checkboxes represent an already **persistent and gated** channel —
 * `worktree-plan-status.mjs#parseUncheckedPlanItems` parses incomplete items, caught on both sides
 * by Stop hooks (`worktree-shipping-guard` planBlocked) and `create-pr verify-plan`, while recognizing
 * `(dropped: …)` / `(deferred: …)` / `(cancelled)` / `~~strikethrough~~` escapes.
 * This module merely plants reminders into that channel without **creating new blocking points**.
 *
 * Impact: Silent omission → *Recorded explicit decision*. To waive, append a cancellation marker to the line,
 * leaving the decision documented in PLAN.md for review.
 *
 * Design decisions:
 *   - **Dedicated Section**: `## Verify` is human-authored space; machine insertions blur ownership.
 *     A dedicated section allows clean recognition, movement, or deletion as a whole.
 *   - **HTML Comment Anchors**: `stripIgnoredPlanSections` strips HTML comments, preventing anchors
 *     from polluting checkbox parsing while enabling raw text duplicate checks.
 *   - **No escape examples on checkbox lines (Pitfall)**: Because negative lookaheads in `UNCHECKED_RE`
 *     operate per line, putting strings like `(dropped …)` inside item guidance prevents the item
 *     from **ever being parsed as unchecked**. Guidance belongs exclusively in section headers (regression: `plan-obligation.test.mjs`).
 *
 * Boundary (R-CM-028): perspective1-only — harness internal worktree workflow (R-CM-030/034 are never_deploy).
 * Not deployed to scaffold targets.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { hasCancelMarker } from './worktree-plan-status.mjs';

/** Heading for automatically inserted section (users may move freely as anchors determine duplicates). */
export const OBLIGATION_SECTION_HEADING = '## Pre-Ship Obligations (Automated)';

/**
 * Header guidance text for the section. **Since this is not a checkbox line**, cancellation marker examples
 * can safely reside here without triggering negative lookahead suppression.
 */
export const OBLIGATION_SECTION_NOTE =
  'Below are obligations automatically inserted upon detecting large changes. If not applicable, ' +
  'append `(dropped: reason)` to the end of that line to explicitly waive — do not simply delete and skip.';

/** Anchor string (idempotency key). */
export function obligationAnchor(id) {
  return `<!-- plan-obligation:${id} -->`;
}

/**
 * Normalizes content for duplicate scanning — strips fenced code blocks and inline code spans.
 *   If rules/docs quote anchor syntax *as examples*, raw searches misidentify them as "already present",
 *   permanently suppressing obligations. Since real anchors are plain text outside code, stripping code suffices.
 *   (HTML comments are preserved — the anchor itself is an HTML comment.)
 */
export function stripCodeForAnchorScan(content) {
  return String(content ?? '')
    .replace(/```[\s\S]*?```/g, '')
    .replace(/`[^`\n]*`/g, '');
}

/** Checks whether obligation is already planted (anchor based, excluding code quotes). */
export function hasObligation(content, id) {
  return stripCodeForAnchorScan(content).includes(obligationAnchor(id));
}

/**
 * Minimum reason length for waivers — symmetrical with existing escape precedents
 * (`retired-ref-ok: <reason 10+ chars>`, `_audit.fatigue_acknowledged` ≥10 chars).
 *
 * Transparent note: Length is merely a lower bound on *sincerity*, not proof of validity.
 * The real defense is **factual refutation** on the consumer side of `parseObligationDecisions`
 * (milestone-deck / quality-gate-proof steps in pre-ship-steps).
 */
export const OBLIGATION_MIN_REASON_LENGTH = 10;

const ANCHOR_LINE_RE = /^\s*<!--\s*plan-obligation:([A-Za-z0-9_-]+)\s*-->\s*$/;
const CHECKBOX_LINE_RE = /^\s*[-*]\s\[([ xX])\]/;
const REASON_RE = /\((?:dropped|Dropped|deferred|Deferred|cancelled|Cancelled|취소됨)\s*[:：]?\s*([^)]*)\)/;

/**
 * Reads decision status of **automatically inserted obligations** (anchor-bearing items) from PLAN.md.
 *
 * Human-written checkboxes without anchors are not collected — waivers in human zones remain human judgments;
 * the machine refutes only machine-planted obligations (authority boundary).
 *
 * @param {string} content Raw PLAN.md text
 * @returns {Map<string, {id: string, checked: boolean, dropped: boolean,
 *                        reason: string|null, reason_too_short: boolean, line: string}>}
 */
export function parseObligationDecisions(content) {
  const out = new Map();
  if (typeof content !== 'string' || !content) return out;
  // Because anchors are HTML comments, stripIgnoredPlanSections cannot be used (it removes comments).
  // stripCodeForAnchorScan (stripping only code quotes) is the appropriate tool here.
  const lines = stripCodeForAnchorScan(content).split(/\r?\n/);
  let pendingId = null;
  for (const line of lines) {
    const anchor = ANCHOR_LINE_RE.exec(line);
    if (anchor) {
      pendingId = anchor[1];
      continue;
    }
    if (!pendingId) continue;
    const box = CHECKBOX_LINE_RE.exec(line);
    if (!box) continue; // Skip blank lines/prose to find first checkbox after anchor
    const dropped = hasCancelMarker(line);
    const reason = dropped ? (REASON_RE.exec(line)?.[1] ?? '').trim() || null : null;
    out.set(pendingId, {
      id: pendingId,
      checked: box[1].toLowerCase() === 'x',
      dropped,
      reason,
      reason_too_short: dropped && (reason?.length ?? 0) < OBLIGATION_MIN_REASON_LENGTH,
      line: line.trim(),
    });
    pendingId = null;
  }
  return out;
}

/** Markdown block for a single obligation (anchor + unchecked checkbox). */
function renderObligation({ id, text }) {
  return `${obligationAnchor(id)}\n- [ ] ${text}`;
}

/**
 * Returns result of idempotently appending obligations to PLAN.md text (pure function — no fs access).
 *
 * @param {string} content Existing PLAN.md text (null/undefined treated as empty doc)
 * @param {Array<{id: string, text: string}>} obligations
 * @returns {{content: string, added: string[], skipped: string[], changed: boolean}}
 */
export function appendObligations(content, obligations) {
  const base = String(content ?? '');
  const list = Array.isArray(obligations) ? obligations : [];
  const added = [];
  const skipped = [];
  const blocks = [];

  for (const o of list) {
    const id = o?.id;
    const text = o?.text;
    if (typeof id !== 'string' || !id || typeof text !== 'string' || !text) continue;
    if (hasObligation(base, id)) {
      skipped.push(id);
      continue;
    }
    added.push(id);
    blocks.push(renderObligation({ id, text }));
  }

  if (added.length === 0) return { content: base, added, skipped, changed: false };

  const sectionExists = base.includes(OBLIGATION_SECTION_HEADING);
  const head = sectionExists ? '' : `${OBLIGATION_SECTION_HEADING}\n\n${OBLIGATION_SECTION_NOTE}\n\n`;
  // Clean whitespace/newlines at end of existing text and join with 2 blank lines.
  const body = base.replace(/\s+$/, '');
  const joined = `${body}${body ? '\n\n' : ''}${head}${blocks.join('\n\n')}\n`;
  return { content: joined, added, skipped, changed: true };
}

/**
 * Idempotently records obligations into PLAN.md file.
 *
 * fail-open (R-CM-006 Rule 2): Missing PLAN.md / read-write errors do not throw and return
 * `planted: false` + `reason` — calling hook continues delivering advisory messages.
 * Missing PLAN.md is caught separately by `plan_missing` channel in `worktree-shipping-guard`.
 *
 * @returns {{planted: boolean, added: string[], skipped: string[], reason: string|null}}
 */
export function plantObligations(
  planPath,
  obligations,
  {
    existsFn = existsSync,
    readFn = (p) => readFileSync(p, 'utf-8'),
    writeFn = atomicWrite,
  } = {},
) {
  const fail = (reason) => ({ planted: false, added: [], skipped: [], reason });
  if (typeof planPath !== 'string' || !planPath) return fail('plan_path_missing');
  try {
    if (!existsFn(planPath)) return fail('plan_absent');
    const result = appendObligations(readFn(planPath), obligations);
    if (!result.changed) {
      return { planted: false, added: [], skipped: result.skipped, reason: 'already_present' };
    }
    writeFn(planPath, result.content);
    return { planted: true, added: result.added, skipped: result.skipped, reason: null };
  } catch {
    return fail('write_failed');
  }
}

/** Atomic write via temp → rename (prevents partial writes during concurrent edits). */
function atomicWrite(path, text) {
  const tmp = `${path}.${randomBytes(6).toString('hex')}.tmp`;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}
