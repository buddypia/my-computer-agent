#!/usr/bin/env node
/**
 * followup-debt-tracker.mjs
 *
 * R-CM-033 (followup-debt-tracking) SSOT management tool.
 *
 * Purpose: Tracks deferred follow-up tasks intentionally marked in PR descriptions
 * ("separate PR", "follow-up PR", "follow-up", "deferred", etc.) to prevent silent quality omission.
 *
 * SSOT: .harness/system/followup-debt.json
 * Schema: data/registry/followup-debt.schema.json
 *
 * Subcommands:
 *   register --pr <num> [--from-text "..."] [--from-file <path>] [--json]
 *     Parses PR description and registers follow-up debt items.
 *
 *   list [--status open|addressed|wontfix] [--severity HIGH|MEDIUM|LOW] [--json]
 *     Lists registered debt items.
 *
 *   close --id DEBT-<n> [--addressed-pr <num>] [--wontfix --reason "..."]
 *     Marks a debt item as addressed or wontfix.
 *
 *   audit [--max-age-days N] [--json]
 *     Exits with code 1 if any HIGH/CRITICAL items have been open longer than N days (default 30).
 *
 *   sweep [--write] [--json]
 *     Automatically closes items whose resolution criteria are met (default preview).
 *
 *   set-resolution --id DEBT-<n> --resolution <kind>:<target>[::<pattern>]
 *     Backfills resolution criteria for an existing open debt item.
 *
 * Resolution criteria (`--resolution`):
 *   file_absent:<path> / file_present:<path> / text_absent:<path>::<string> /
 *   text_present:<path>::<string> / manual:<why machine sweep cannot close (min 10 chars)>
 *
 * Environment variables:
 *   HARNESS_FOLLOWUP_DEBT_PATH  SSOT file path override (for tests)
 *   GH_TOKEN                       gh API token for fetching PR description
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { resolveSystemFile } from '../../.cli/lib/layout-resolver.mjs';
import { writeJsonAtomicSync } from './lib/atomic-fs.mjs';
import {
  RESOLUTION_KINDS,
  parseResolutionSpec,
  sweepResolutions,
  validateResolution,
} from './lib/debt-resolution.mjs';

const DEFAULT_MAX_AGE_DAYS = 30;
const COMPACT_CLOSED_DAYS = 30; // Archive threshold for closed (addressed|wontfix) items
const LAPSE_OPEN_LOW_DAYS = 90; // Dormancy threshold for untouched open LOW items
const CATEGORIES = new Set(['code_review_finding', 'code_reviewer_finding', 'general_followup']);
const SEVERITIES = new Set(['LOW', 'MEDIUM', 'HIGH', 'CRITICAL']);

/**
 * Non-blocking advisory aggregation (F6).
 * Surfaces maintenance backlogs separately from HIGH/CRITICAL exit-1 gates.
 * Pure function — isolated for testing.
 *
 * @param {Array} items
 * @param {number} now - Reference timestamp in ms
 * @returns {{ open_total:number, escalated_open:number, drain_pending:number,
 *   drain_pending_lapse:number, drain_pending_compact:number, warn:boolean }}
 */
export function computeDebtAdvisory(
  items,
  now,
  { lapseDays = LAPSE_OPEN_LOW_DAYS, compactDays = COMPACT_CLOSED_DAYS } = {},
) {
  const list = Array.isArray(items) ? items : [];
  const open = list.filter((it) => it && it.status === 'open');
  const lapse = selectLapsableDebt(list, now, { days: lapseDays }).length;
  const compact = selectCompactableDebt(list, now, { days: compactDays }).length;
  const pending = lapse + compact;
  return {
    open_total: open.length,
    escalated_open: open.filter((it) => it.severity !== 'LOW').length,
    drain_pending: pending,
    drain_pending_lapse: lapse,
    drain_pending_compact: compact,
    warn: pending > 0,
  };
}

/**
 * Selects debt IDs eligible for compaction (archiving).
 * Targets closed items (status in {addressed, wontfix}) older than `days`.
 * Open items are strictly excluded (no auto-triage of open items).
 * Pure function returning an array of IDs.
 *
 * @param {Array} items
 * @param {number} now - Reference timestamp in ms
 * @param {{ days?: number }} [opts]
 * @returns {string[]} Compaction candidate debt IDs
 */
function isCompactableClosedItem(it, now, days) {
  if (!it || typeof it.id !== 'string' || it.id.length === 0) return false;
  if (it.status !== 'addressed' && it.status !== 'wontfix') return false;
  const t = Date.parse(it.addressed_at || it.added_at || '');
  if (Number.isNaN(t)) return true;
  return Math.floor((now - t) / 86400000) >= days;
}

export function selectCompactableDebt(items, now, { days = COMPACT_CLOSED_DAYS } = {}) {
  const list = Array.isArray(items) ? items : [];
  return list.filter((it) => isCompactableClosedItem(it, now, days)).map((it) => it.id);
}

/**
 * Selects debt IDs eligible for dormancy lapse (open LOW backlog management).
 * Targets open items with severity LOW where age >= days.
 *
 * Exemptions:
 *   - status !== 'open'
 *   - severity !== 'LOW' (MEDIUM/HIGH/CRITICAL are escalated and kept intentionally)
 *   - unparseable or missing added_at
 *
 * @param {Array} items
 * @param {number} now - Reference timestamp in ms
 * @param {{ days?: number }} [opts]
 * @returns {string[]} Lapsable debt IDs
 */
function isLapsableOpenItem(it, now, days) {
  if (!it || typeof it.id !== 'string' || it.id.length === 0) return false;
  if (it.status !== 'open') return false;
  if (it.severity !== 'LOW') return false;
  const t = Date.parse(it.added_at || '');
  if (Number.isNaN(t)) return false;
  return Math.floor((now - t) / 86400000) >= days;
}

export function selectLapsableDebt(items, now, { days = LAPSE_OPEN_LOW_DAYS } = {}) {
  const list = Array.isArray(items) ? items : [];
  return list.filter((it) => isLapsableOpenItem(it, now, days)).map((it) => it.id);
}

// PR bodies in this repo are written in Korean, and `범위 밖` is the natural Korean heading for a
// deferred section. The English (`out of scope`) and mixed (`scope 외`) forms were listed while the
// pure-Korean one was not — an asymmetry, since four other keywords already carry Korean forms. A
// Korean-only section parsed to zero and every bullet under it was dropped with no warning. Keep
// each keyword paired with its Korean form.
//
// PR #1213 is NOT evidence for this: its `count: 0` came from `ops.mjs` discarding `--body-file`,
// so the body never reached GitHub and there was nothing to parse (measured 2026-08-25, corrected
// in the PR that added this paragraph). The gap here is real but was found by reading, not by that
// incident.
const KEYWORDS = [
  /후속\s*PR/i,
  /별도\s*PR/i,
  /후속\s*과제/i,
  /후속\s*작업/i,
  /scope\s*외/i,
  /범위\s*밖/i,
  /separate\s*PR/i,
  /follow[-\s]?up\s*PR/i,
  /follow[-\s]?up/i,
  /out\s*of\s*scope/i,
  /follow[-\s]?up\s*tasks?/i,
  /deferred/i,
];

function getSsotPath() {
  if (process.env.HARNESS_FOLLOWUP_DEBT_PATH) {
    return resolve(process.env.HARNESS_FOLLOWUP_DEBT_PATH);
  }
  return resolveSystemFile('followup-debt.json');
}

export function loadDebt() {
  const path = getSsotPath();
  if (!existsSync(path)) {
    return { version: '1.0.0', updated_at: new Date().toISOString(), items: [] };
  }
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    throw new Error(`followup-debt.json parse failed: ${e.message}`);
  }
}

/**
 * Updates SSOT. Throws on atomic write failure so caller can handle fail-open/fail-closed.
 */
function saveDebt(debt) {
  const path = getSsotPath();
  debt.updated_at = new Date().toISOString();
  writeJsonAtomicSync(path, debt);
}

/**
 * Closes a single debt item (open → addressed | wontfix).
 *
 * @param {string} id - DEBT-N
 * @param {{ reason?: string, addressedPr?: number, now?: string }} [opts]
 * @returns {object} Updated item
 */
export function closeDebt(id, opts = {}) {
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error('closeDebt: id required');
  }
  const debt = loadDebt();
  const item = (debt.items || []).find((it) => it.id === id);
  if (!item) throw new Error(`closeDebt: debt not found: ${id}`);
  if (item.status && item.status !== 'open') {
    throw new Error(`closeDebt: debt already ${item.status}: ${id}`);
  }
  const now = opts.now || new Date().toISOString();
  if (opts.reason) {
    if (String(opts.reason).trim().length < 10) {
      throw new Error('closeDebt: wontfix reason ≥10 chars (R-CM-033 #8)');
    }
    item.status = 'wontfix';
    item.wontfix_reason = String(opts.reason).trim();
  } else {
    item.status = 'addressed';
    item.addressed_pr = opts.addressedPr || null;
  }
  item.addressed_at = now;
  saveDebt(debt);
  return item;
}

/**
 * Removes a debt item from SSOT for archiving/hard-deletion.
 *
 * @param {string} id - DEBT-N
 * @returns {object|null} Removed item
 */
export function removeDebtItem(id) {
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error('removeDebtItem: id required');
  }
  const debt = loadDebt();
  const items = debt.items || [];
  const idx = items.findIndex((it) => it.id === id);
  if (idx === -1) return null;
  const [removed] = items.splice(idx, 1);
  debt.items = items;
  saveDebt(debt);
  return removed;
}

/**
 * Restores a debt item from archive back into SSOT.
 * Idempotent: avoids adding duplicate if id already exists.
 *
 * @param {object} item
 * @returns {object} Restored item
 */
export function restoreDebtItem(item) {
  if (!item || typeof item !== 'object' || typeof item.id !== 'string' || item.id.length === 0) {
    throw new Error('restoreDebtItem: item with id required');
  }
  const debt = loadDebt();
  const items = debt.items || [];
  if (!items.some((it) => it.id === item.id)) {
    items.push(item);
    debt.items = items;
    saveDebt(debt);
  }
  return item;
}

function nextId(items) {
  let max = 0;
  for (const item of items) {
    const m = /^DEBT-(\d+)$/.exec(item.id);
    if (m) max = Math.max(max, parseInt(m[1], 10));
  }
  return `DEBT-${max + 1}`;
}

/**
 * Dedup key for a description (Rule 2: one row per identical description within a `source_pr`).
 *
 * A leading severity marker is stripped here as well as from the stored text, because rows written
 * before `extractInlineSeverity` existed kept theirs verbatim. Without this, re-registering the same
 * PR body compares `"[MEDIUM] foo"` (stored) against `"foo"` (parsed), never matches, and files a
 * second row — observed for real on PR #1262, which produced 4 duplicates. Normalizing the *key*
 * rather than rewriting stored rows keeps Rule 6.3's ban on bulk backfill intact: nothing on disk
 * changes, the two spellings just stop looking like different debts.
 *
 * Only severity markers are stripped. Action-scale markers (`[P1]`) are deliberately left in the
 * description by the parser, so both sides already carry them and the keys already agree.
 */
function normalizeDescription(value) {
  return String(value ?? '')
    .replace(LEADING_MARKER, (full, token) => (SEVERITIES.has(token.toUpperCase()) ? '' : full))
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

/**
 * A description's citations of debts that are still open.
 *
 * Why: a PR's follow-up section said `(DEBT-21, still open)` in so many words, and the registrar
 * filed a new row anyway. Dedup is scoped to `source_pr` (Rule 2 is "one row per identical
 * description *within a PR*"), so a debt carried across PRs gets a fresh row every time. The ledger
 * inflates, "N open items" stops meaning anything, and an agent reading `list` counts one debt twice.
 *
 * Suppressing the row was rejected. A genuinely new debt may cite an old id for context ("like
 * DEBT-10 but a different failure"), and merging those loses work. A duplicate is visible to whoever
 * reads the ledger; a silently dropped debt is not. So the row is written and the relationship is
 * stated loudly, at the one moment someone is looking: the ship report.
 *
 * @param {string} description
 * @param {Set<string>} openIds - DEBT-N ids currently in `open` status
 * @returns {string[]} cited open ids, in first-seen order, deduplicated
 */
export function citedOpenDebts(description, openIds) {
  const cited = [];
  for (const m of String(description ?? '').matchAll(/\bDEBT-\d+\b/g)) {
    if (openIds.has(m[0]) && !cited.includes(m[0])) cited.push(m[0]);
  }
  return cited;
}

function readOption(args, name) {
  const idx = args.indexOf(name);
  return idx >= 0 ? args[idx + 1] : null;
}

/**
 * The Actions scale from R-CM-030 Rule 14. Deliberately NOT mapped onto `severity`.
 *
 * Rule 14 defines both scales side by side — Actions as `P0`/`P1`/`P2`, Findings as the severity
 * enum this ledger is keyed on — and warns that "a second vocabulary forks the ledgers". Translating
 * `P1` into `MEDIUM` here would be exactly that translation, invented by this file rather than
 * stated by the author. Folding it silently into the LOW default is no better: it is the same
 * dropped-severity defect one slot over. So it is named back to the author instead.
 */
const ACTION_SCALE = new Set(['P0', 'P1', 'P2']);

/**
 * A leading `[TOKEN]`. Anchored at line start so prose like "roughly [MEDIUM] weight" is untouched.
 *
 * The trailing whitespace is `\s*`, not `\s+`. Requiring a space made `- [HIGH]로그인 실패…` — no
 * space, ordinary in Korean prose and a one-keystroke typo in any language — fall through to the
 * leave-it-alone branch: filed LOW, marker still embedded, and no warning on either channel. That
 * is the very defect this parser exists to end, reached by a different door. Anchoring is what
 * keeps mid-sentence brackets safe; the space never contributed to that.
 */
const LEADING_MARKER = /^\[([A-Za-z0-9-]+)\]\s*/;

/**
 * Extracts an inline severity marker from a leading `[SEVERITY]` on bullet lines.
 *
 * R-CM-030 Rule 14 states that a Panel finding "transcribes into `followup-debt-tracker register`
 * untranslated" because both use the same enum. That was not true: `cmdRegister` applied one
 * `--severity` to every item, and the automatic path (`ops.mjs#registerFollowupDebtFromPr`) never
 * passes the flag, so every auto-registered item landed LOW no matter what the body said. Measured
 * on PR #1260 and #1262 (2026-09-06) — 3 of #1262's 7 items were written `[MEDIUM]`, one of them
 * "L3 guard has zero executable coverage", and all 7 were filed LOW.
 *
 * Severity is not decoration: the 30-day audit gate only looks at HIGH/CRITICAL and the 90-day
 * dormancy lapse only seals LOW, so a flattened ledger quietly sleeps its heaviest items.
 *
 * Case is normalized rather than rejected — dropping `[Medium]` because of its casing would be the
 * same silent discard this function exists to end, and the token set is closed so nothing else can
 * be confused for it. An unrecognized leading bracket (`[DEBT-42]`, a date, a link label) is left
 * strictly alone: only the Actions scale gets a warning, because only it is a plausible mix-up
 * between two scales the same rule defines.
 *
 * @returns {{body: string, severity: string|null, misusedScale: string|null}}
 */
export function extractInlineSeverity(line) {
  const raw = String(line ?? '');
  const m = raw.match(LEADING_MARKER);
  if (!m) return { body: raw.trim(), severity: null, misusedScale: null };
  const token = m[1].toUpperCase();
  if (SEVERITIES.has(token)) {
    return { body: raw.slice(m[0].length).trim(), severity: token, misusedScale: null };
  }
  // Marker kept verbatim in both remaining cases — see the `extractInlineResolution` note: a
  // stripped marker leaves the author's stated intent nowhere, and `list` is where a typo is seen.
  if (ACTION_SCALE.has(token)) return { body: raw.trim(), severity: null, misusedScale: token };
  return { body: raw.trim(), severity: null, misusedScale: null };
}

/**
 * Extracts inline resolution spec from trailing `[resolution: <spec>]` on bullet lines.
 *
 * @returns {{body: string, resolution: object|null}}
 */
export function extractInlineResolution(line) {
  const raw = String(line ?? '');
  const m = raw.match(/\s*\[resolution:\s*([^\]]+)\]\s*$/);
  if (!m) return { body: raw.trim(), resolution: null };
  const spec = parseResolutionSpec(m[1]);
  const resolution = spec && validateResolution(spec) === null ? spec : null;
  // A malformed marker keeps its text. Stripping it discarded the author's stated criteria *and*
  // recorded none, so the item landed indistinguishable from one that never named a resolution —
  // the `sweep` ledger then counted it as unspecified-resolution with no trace of why. Leaving the
  // marker in the description makes the typo visible in `list`, where `set-resolution` fixes it.
  if (!resolution) return { body: raw.trim(), resolution: null };
  return { body: raw.slice(0, m.index).trim(), resolution };
}

/**
 * Section-state transition for one line. Returns the state unchanged for non-headings.
 *
 * A heading matching a deferral keyword opens the section and records its depth; a later heading at
 * that depth or shallower closes it, while deeper ones are subsections and stay inside.
 *
 * @param {string} line
 * @param {{inSection: boolean, depth: number}} state
 * @returns {{inSection: boolean, depth: number}}
 */
function advanceSection(line, state) {
  if (!/^#+\s/.test(line)) return state;
  const depth = (line.match(/^#+/) || [''])[0].length;
  const matchesKeyword = KEYWORDS.some((rx) => {
    rx.lastIndex = 0;
    return rx.test(line);
  });
  if (matchesKeyword) return { inSection: true, depth };
  if (state.inSection && depth <= state.depth) return { inSection: false, depth: state.depth };
  return state;
}

/** The item text of a `-`/`*` or `1.`/`1)` list line, or null when the line is not one. */
function listItemText(line) {
  const m = line.match(/^\s*[-*]\s+(.+)/) || line.match(/^\s*\d+[.)]\s+(.+)/);
  return m ? m[1] : null;
}

/**
 * Extracts follow-up debt items from PR description text.
 *
 * @param {string} text PR description body
 * @param {{onDropped?: (info: {line: string, body: string}) => void}} [opts]
 *   `onDropped` fires for a bullet that only fell under the length floor **because** the markers
 *   were stripped off it. Passed as a callback rather than a second return value so the array
 *   contract every existing caller relies on stays exactly as it was.
 * @returns {Array<{description: string, files: string[], resolution: object|null, severity: string|null, misusedScale: string|null}>}
 */
export function parsePrDescription(text, { onDropped } = {}) {
  if (!text || typeof text !== 'string') return [];

  const items = [];
  let section = { inSection: false, depth: 0 };

  for (const line of text.split(/\r?\n/)) {
    section = advanceSection(line, section);
    if (!section.inSection) continue;

    const raw = listItemText(line);
    if (!raw) continue;

    // Severity leads, resolution trails — independent ends of the line. Severity is stripped
    // first so the length floor below measures the actual description, not the marker.
    const { body: afterSeverity, severity, misusedScale } = extractInlineSeverity(raw.trim());
    const { body: trimmed, resolution } = extractInlineResolution(afterSeverity);
    if (trimmed.length >= 10) {
      items.push({
        description: trimmed,
        files: extractFiles(trimmed),
        resolution,
        severity,
        misusedScale,
      });
    } else if (onDropped && raw.trim().length >= 10) {
      // Stripping the markers is what pushed this under the floor — the author did write a
      // substantive line. Dropping it stays correct (`description` is `minLength: 10` in
      // followup-debt.schema.json), but doing it *silently* is not: every other drop path in
      // this file says something, and a debt that vanishes between the PR body and the ledger
      // is the exact class of loss the DEBT-326 note below was written about.
      onDropped({ line: raw.trim(), body: trimmed });
    }
  }

  const seen = new Set();
  return items.filter((it) => {
    const key = normalizeDescription(it.description);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** Source extensions recognized in prose. Order is irrelevant — see the boundary note below. */
const SOURCE_EXT_SRC = 'mjs|js|ts|tsx|jsx|json|md|py|go|rs';
const SPLIT_AFTER_EXT = new RegExp(`(?<=\\.(?:${SOURCE_EXT_SRC}))/`);

function extractFiles(text) {
  const files = [];
  const addFile = (file) => {
    if (files.includes(file)) return;
    if (!file.startsWith('.') && files.includes(`.${file}`)) return;
    if (file.startsWith('.')) {
      const bare = file.slice(1);
      const bareIdx = files.indexOf(bare);
      if (bareIdx >= 0) {
        files.splice(bareIdx, 1, file);
        return;
      }
    }
    files.push(file);
  };
  const patterns = [
    /`([^\s`]+\.[a-z0-9]+)`/g,
    // The two lookaheads close the extension. Alternation in JS is first-match, not longest-match,
    // so without a terminator `js` won a race against `json` and `ts` against `tsx` — every
    // unbackticked `package.json` was filed as `package.js`, a path that does not exist. Four debt
    // records had already been written that way before this was noticed (2026-09-06). Ordering the
    // list longest-first would also fix today's cases, but silently re-breaks the moment someone
    // adds an extension in the wrong slot; a boundary holds regardless of order.
    //
    // They are two, not one: `(?![\w.])` would also reject a *sentence-ending* period, so prose as
    // ordinary as `…see foo.json.` extracted nothing at all. `(?!\.\w)` rejects only a dot that
    // continues into more extension (`foo.js.map`, `a.md.bak`), which is the case worth rejecting.
    // Regexes are built per call so this function keeps no `lastIndex` between calls; it runs a
    // handful of times per PR body, where the compile cost is not worth trading purity for.
    new RegExp(`([a-zA-Z_][\\w./-]*\\.(?:${SOURCE_EXT_SRC})(?!\\w)(?!\\.\\w))`, 'g'),
  ];
  for (const rx of patterns) {
    let m;
    while ((m = rx.exec(text))) {
      // `a.mjs/b.mjs` in prose is two files. A path segment already carrying a source extension
      // cannot also be a directory, so the slash after it is a list separator (DEBT-237).
      for (const part of m[1].split(SPLIT_AFTER_EXT)) addFile(part);
    }
  }
  return files;
}

function fetchPrBody(prNumber) {
  try {
    const json = execFileSync('gh', ['pr', 'view', String(prNumber), '--json', 'body', '--jq', '.body'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return json.trim();
  } catch (e) {
    throw new Error(`gh pr view ${prNumber} failed: ${e.message}`);
  }
}

function resolveRepoUrl() {
  try {
    const url = execFileSync('gh', ['repo', 'view', '--json', 'url', '--jq', '.url'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return url.trim() || null;
  } catch {
    return null;
  }
}

function cmdRegister(args) {
  const prIdx = args.indexOf('--pr');
  if (prIdx < 0 || !args[prIdx + 1]) {
    console.error('Error: --pr <num> required');
    process.exit(1);
  }
  const prNumber = parseInt(args[prIdx + 1], 10);
  if (!Number.isInteger(prNumber) || prNumber < 1) {
    console.error('Error: --pr must be a positive integer');
    process.exit(1);
  }

  let body = '';
  const fromTextIdx = args.indexOf('--from-text');
  const fromFileIdx = args.indexOf('--from-file');
  if (fromTextIdx >= 0 && args[fromTextIdx + 1]) {
    body = args[fromTextIdx + 1];
  } else if (fromFileIdx >= 0 && args[fromFileIdx + 1]) {
    body = readFileSync(args[fromFileIdx + 1], 'utf8');
  } else {
    body = fetchPrBody(prNumber);
  }

  const dropped = [];
  const parsed = parsePrDescription(body, { onDropped: (d) => dropped.push(d) });
  const droppedWarnings = dropped.map(
    ({ line, body: rest }) =>
      `dropped: "${line}" — after removing its markers only "${rest}" was left, under the ` +
      `10-character floor \`followup-debt.schema.json\` requires. Nothing was recorded. ` +
      `Write the item out in full, or keep the grade and say more.`,
  );
  // Emitted here too: a body whose only bullet was dropped never reaches the tail of this function,
  // and reporting `registered: 0, warnings: []` for it would be the same silent loss twice over.
  for (const w of droppedWarnings) console.error(`[followup-debt] ${w}`);

  if (parsed.length === 0) {
    if (args.includes('--json')) {
      console.log(
        JSON.stringify({ ok: true, registered: 0, items: [], warnings: droppedWarnings }),
      );
    } else {
      console.log(`PR #${prNumber}: no follow-up items detected`);
    }
    return 0;
  }

  const debt = loadDebt();
  const now = new Date().toISOString();
  const repoUrl = resolveRepoUrl();
  const sourceUrl = repoUrl ? `${repoUrl}/pull/${prNumber}` : null;
  const category = readOption(args, '--category') || 'general_followup';
  const severity = readOption(args, '--severity') || 'LOW';

  if (!CATEGORIES.has(category)) {
    console.error(`Error: --category must be one of ${Array.from(CATEGORIES).join(', ')}`);
    process.exit(1);
  }
  if (!SEVERITIES.has(severity)) {
    console.error(`Error: --severity must be one of ${Array.from(SEVERITIES).join(', ')}`);
    process.exit(1);
  }

  const resolutionSpec = readOption(args, '--resolution');
  let resolution = null;
  if (resolutionSpec) {
    resolution = parseResolutionSpec(resolutionSpec);
    const problem = resolution ? validateResolution(resolution) : `invalid format: ${resolutionSpec}`;
    if (problem) {
      console.error(`Error: --resolution ${problem}`);
      console.error(`  format: <${RESOLUTION_KINDS.join('|')}>:<target>[::<pattern>]`);
      process.exit(1);
    }
  }

  const existingDescriptions = new Set(
    debt.items
      .filter((it) => it.source_pr === prNumber)
      .map((it) => normalizeDescription(it.description)),
  );

  // Snapshotted before the loop: ids minted in this run cannot be cited by it, and letting the set
  // grow would make item B "continue" a row item A just created.
  const openIds = new Set(debt.items.filter((it) => it.status === 'open').map((it) => it.id));

  const registered = [];
  // Collected here rather than stored on the entry: `misusedScale` is a fact about the *line that
  // was read*, not about the debt, and the record schema has no field for it.
  const misusedScales = [];
  const continuations = [];
  for (const item of parsed) {
    const key = normalizeDescription(item.description);
    if (existingDescriptions.has(key)) continue;
    const entry = {
      id: nextId(debt.items),
      source_pr: prNumber,
      ...(sourceUrl ? { source_pr_url: sourceUrl } : {}),
      category,
      // Per-item marker beats the run-wide flag: the more specific statement wins, same precedence
      // as `resolution` below. R-CM-033 Rule 5's LOW stays the default for an unmarked line.
      severity: item.severity ?? severity,
      description: item.description,
      files: item.files,
      added_at: now,
      status: 'open',
      addressed_pr: null,
      addressed_at: null,
      wontfix_reason: null,
      resolution: item.resolution ?? resolution,
    };
    debt.items.push(entry);
    registered.push(entry);
    if (item.misusedScale) misusedScales.push({ id: entry.id, token: item.misusedScale });
    const cited = citedOpenDebts(item.description, openIds);
    if (cited.length) continuations.push({ id: entry.id, cited });
  }

  saveDebt(debt);

  // Emitted on **both** channels on purpose. stderr serves a human at a terminal; `--json` stdout
  // serves `ops.mjs#registerFollowupDebtFromPr`, the only production caller — and it pipes the
  // child's stderr, reads it solely on the failure path, and discards it on success. That is how
  // DEBT-326 (a marker written with a leading position and an unknown `fix:` kind) was registered
  // in the 2026-09-05 ship with no warning visible anywhere, and was found only by reading the
  // ledger afterwards — precisely the outcome this warning exists to prevent.
  const warnings = [
    ...registered
      .filter((e) => !e.resolution && /\[resolution:/.test(e.description))
      .map((it) => `${it.id}: malformed [resolution: ...] marker kept verbatim — fix with \`set-resolution --id ${it.id}\``),
    ...continuations.map(
      ({ id, cited }) =>
        `${id}: continues ${cited.join(', ')}, which ${cited.length > 1 ? 'are' : 'is'} still open — ` +
        `dedup is per-PR, so this was filed as a new row rather than dropped. If it is the same debt, ` +
        `fold it back: \`close --id ${id} --wontfix --reason "same debt as ${cited[0]}; tracked there"\`. ` +
        `If it is genuinely distinct, leave both and say how they differ.`,
    ),
    ...misusedScales.map(
      ({ id, token }) =>
        `${id}: [${token}] is the Actions scale (P0/P1/P2), not a severity — this ledger is keyed on ` +
        `CRITICAL/HIGH/MEDIUM/LOW (R-CM-030 Rule 14). Recorded as ${severity} and the marker was ` +
        `left in the text; no mapping was invented. Restate it as a severity, or escalate with ` +
        `\`register --severity\`.`,
    ),
  ];
  // `droppedWarnings` are already on stderr from the early path above; only the JSON channel below
  // still needs them, so they are appended rather than re-printed.
  for (const w of warnings) console.error(`[followup-debt] ${w}`);
  warnings.push(...droppedWarnings);

  if (args.includes('--json')) {
    console.log(
      JSON.stringify({ ok: true, registered: registered.length, items: registered, warnings }),
    );
  } else {
    console.log(`PR #${prNumber}: registered ${registered.length} follow-up debt items`);
    for (const it of registered) {
      console.log(`  ${it.id}: ${it.description.slice(0, 80)}${it.description.length > 80 ? '...' : ''}`);
    }
  }
  return 0;
}

function cmdList(args) {
  const debt = loadDebt();
  let items = debt.items;

  const statusIdx = args.indexOf('--status');
  if (statusIdx >= 0 && args[statusIdx + 1]) {
    items = items.filter((it) => it.status === args[statusIdx + 1]);
  }
  const sevIdx = args.indexOf('--severity');
  if (sevIdx >= 0 && args[sevIdx + 1]) {
    items = items.filter((it) => it.severity === args[sevIdx + 1]);
  }

  if (args.includes('--json')) {
    console.log(JSON.stringify({ ok: true, count: items.length, items }));
  } else {
    if (items.length === 0) {
      console.log('No follow-up debt items found.');
      return 0;
    }
    console.log(`Found ${items.length} follow-up debt item(s):`);
    for (const it of items) {
      const ageDays = Math.floor(
        (Date.now() - new Date(it.added_at).getTime()) / (1000 * 60 * 60 * 24),
      );
      console.log(
        `  ${it.id} [${it.status}/${it.severity}] PR #${it.source_pr} (${ageDays}d ago)`,
      );
      console.log(`    ${it.description.slice(0, 100)}${it.description.length > 100 ? '...' : ''}`);
    }
  }
  return 0;
}

function cmdClose(args) {
  const idIdx = args.indexOf('--id');
  if (idIdx < 0 || !args[idIdx + 1]) {
    console.error('Error: --id DEBT-<n> required');
    process.exit(1);
  }
  const id = args[idIdx + 1];

  const debt = loadDebt();
  const item = debt.items.find((it) => it.id === id);
  if (!item) {
    console.error(`Error: ${id} not found`);
    process.exit(1);
  }
  if (item.status !== 'open') {
    console.error(`Error: ${id} already ${item.status}`);
    process.exit(1);
  }

  const now = new Date().toISOString();
  if (args.includes('--wontfix')) {
    const reasonIdx = args.indexOf('--reason');
    if (reasonIdx < 0 || !args[reasonIdx + 1] || args[reasonIdx + 1].length < 10) {
      console.error('Error: --reason "..." required (min 10 chars) for --wontfix');
      process.exit(1);
    }
    item.status = 'wontfix';
    item.wontfix_reason = args[reasonIdx + 1];
    item.addressed_at = now;
  } else {
    const prIdx = args.indexOf('--addressed-pr');
    if (prIdx < 0 || !args[prIdx + 1]) {
      console.error('Error: --addressed-pr <num> required (or use --wontfix)');
      process.exit(1);
    }
    item.status = 'addressed';
    item.addressed_pr = parseInt(args[prIdx + 1], 10);
    item.addressed_at = now;
  }

  saveDebt(debt);
  console.log(`${id} → ${item.status}`);
  return 0;
}

/**
 * Backfills resolution criteria for an existing open debt item.
 */
function cmdSetResolution(args) {
  const id = readOption(args, '--id');
  const spec = readOption(args, '--resolution');
  if (!id || !spec) {
    console.error('Error: both --id DEBT-<n> and --resolution <kind>:<target>[::<pattern>] required');
    return 1;
  }

  const resolution = parseResolutionSpec(spec);
  const problem = resolution ? validateResolution(resolution) : `invalid format: ${spec}`;
  if (problem) {
    console.error(`Error: --resolution ${problem}`);
    console.error(`  format: <${RESOLUTION_KINDS.join('|')}>:<target>[::<pattern>]`);
    return 1;
  }

  const debt = loadDebt();
  const item = debt.items.find((it) => it.id === id);
  if (!item) {
    console.error(`Error: ${id} not found`);
    return 1;
  }
  if (item.status !== 'open') {
    console.error(`Error: ${id} is already ${item.status} — resolution criteria cannot be set for closed debt`);
    return 1;
  }

  const previous = item.resolution;
  item.resolution = resolution;
  saveDebt(debt);

  if (previous) console.log(`${id} criteria updated: ${JSON.stringify(previous)} → ${JSON.stringify(resolution)}`);
  else console.log(`${id} criteria set: ${JSON.stringify(resolution)}`);
  return 0;
}

/**
 * Closes open items whose resolution criteria are met. Defaults to preview mode.
 */
function cmdSweep(args) {
  const debt = loadDebt();
  const root = resolve(process.cwd());
  const { resolvable, pending, unspecified } = sweepResolutions(debt.items, { root });
  const write = args.includes('--write');

  if (write && resolvable.length > 0) {
    const now = new Date().toISOString();
    for (const { item, evidence } of resolvable) {
      item.status = 'addressed';
      item.addressed_at = now;
      item.resolved_by = 'sweep';
      item.resolution_evidence = evidence;
    }
    saveDebt(debt);
  }

  const payload = {
    ok: true,
    written: write,
    resolved: resolvable.map((r) => ({ id: r.item.id, evidence: r.evidence })),
    pending: pending.length,
    unspecified: unspecified.length,
  };
  if (args.includes('--json')) {
    console.log(JSON.stringify(payload, null, 2));
    return 0;
  }
  console.log(`Resolution criteria met: ${resolvable.length} item(s)${write ? ' (closed)' : ' (preview — use --write to apply)'}`);
  for (const r of resolvable) console.log(`  ${r.item.id}: ${r.evidence}`);
  console.log(`Unmet: ${pending.length} item(s) / No criteria: ${unspecified.length} item(s)`);
  return 0;
}

function cmdAudit(args) {
  const maxIdx = args.indexOf('--max-age-days');
  const maxAge =
    maxIdx >= 0 && args[maxIdx + 1] ? parseInt(args[maxIdx + 1], 10) : DEFAULT_MAX_AGE_DAYS;
  if (!Number.isInteger(maxAge) || maxAge < 0) {
    console.error('Error: --max-age-days must be a non-negative integer');
    process.exit(1);
  }

  const debt = loadDebt();
  const now = Date.now();
  const stale = debt.items.filter((it) => {
    if (it.status !== 'open') return false;
    const ageDays = Math.floor((now - new Date(it.added_at).getTime()) / (1000 * 60 * 60 * 24));
    return ageDays >= maxAge && (it.severity === 'HIGH' || it.severity === 'CRITICAL');
  });

  const violations = stale.length;
  const advisory = computeDebtAdvisory(debt.items, now);
  const unspecified = debt.items.filter((it) => it.status === 'open' && !it.resolution).length;
  if (args.includes('--json')) {
    console.log(
      JSON.stringify({
        ok: violations === 0,
        violations,
        max_age_days: maxAge,
        items: stale,
        advisory,
        unspecified_resolution: unspecified,
      }),
    );
  } else if (violations > 0) {
    console.error(
      `[followup-debt-audit] ${violations} stale HIGH/CRITICAL item(s) > ${maxAge} days:`,
    );
    for (const it of stale) {
      const ageDays = Math.floor((now - new Date(it.added_at).getTime()) / (1000 * 60 * 60 * 24));
      console.error(`  ${it.id} [${it.severity}] PR #${it.source_pr} (${ageDays}d): ${it.description.slice(0, 80)}`);
    }
  } else {
    console.log(`[followup-debt-audit] OK (no stale HIGH/CRITICAL items, max_age_days=${maxAge})`);
  }
  if (advisory.warn) {
    console.error(
      `[followup-debt-advisory] Pending cleanup ${advisory.drain_pending} item(s) ` +
        `(dormant open LOW ${advisory.drain_pending_lapse} / closed ${advisory.drain_pending_compact}) — ` +
        `resolve via: make q.debt-compact ARGS='--apply'`,
    );
    console.error(
      `  Note (informational): open ${advisory.open_total} item(s), including ${advisory.escalated_open} escalated (MEDIUM+) item(s)`,
    );
  }
  return violations === 0 ? 0 : 1;
}

function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];

  switch (cmd) {
    case 'register':
      return cmdRegister(args.slice(1));
    case 'list':
      return cmdList(args.slice(1));
    case 'close':
      return cmdClose(args.slice(1));
    case 'audit':
      return cmdAudit(args.slice(1));
    case 'sweep':
      return cmdSweep(args.slice(1));
    case 'set-resolution':
      return cmdSetResolution(args.slice(1));
    default:
      console.error(
        'Usage: followup-debt-tracker.mjs <register|list|close|audit|sweep|set-resolution> [options]',
      );
      console.error('  register --pr <num> [--from-text "..." | --from-file <path>] [--json]');
      console.error('           [--category code_review_finding|code_reviewer_finding|general_followup]');
      console.error('           [--severity LOW|MEDIUM|HIGH|CRITICAL]');
      console.error(`           [--resolution <${RESOLUTION_KINDS.join('|')}>:<target>[::<pattern>]]`);
      console.error('  list [--status open|addressed|wontfix] [--severity HIGH|MEDIUM|LOW] [--json]');
      console.error('  close --id DEBT-<n> (--addressed-pr <num> | --wontfix --reason "...")');
      console.error('  audit [--max-age-days N] [--json]');
      console.error('  sweep [--write] [--json]   Automatically closes items whose resolution criteria are met (default preview)');
      console.error(
        `  set-resolution --id DEBT-<n> --resolution <${RESOLUTION_KINDS.join('|')}>:<target>[::<pattern>]`,
      );
      return 1;
  }
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  process.exitCode = main();
}
