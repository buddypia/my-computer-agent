/**
 * ship-quality-ledger.mjs — Ship-time quality label cumulative ledger + consecutive cross-review skip detection
 *
 * Root problem (empirical): R-CM-030 Rule 8 requires both `/code-review --fix` + `code-reviewer` agent
 *   for substantial changes, allowing `pre-quality-gate` fallback + label downgrade (`agent_go` → `self_review_pass`)
 *   when agents cannot be used. However, that downgrade is recorded **only within that PR**.
 *   Nowhere could answer "how many consecutive PRs were merged without secondary review".
 *
 *   The risk is not hypothetical — in PR #1050, code-reviewer caught 1 HIGH finding (missing rename),
 *   and in PR #1057, it caught 1 HIGH finding (false clean on registry failure). Both were missed by self-review.
 *   Conversely, #1054 and #1056 were merged with downgraded labels, their continuity invisible until human audit
 *   (same structure as discovering DEBT-248 after "3 consecutive" misses).
 *
 * Solution: Append one line (jsonl) for every **successfully merged** ship + expose streak counts as warnings.
 *   Merge gating is caller's responsibility — `ops.mjs#shouldRecordShipQuality` (does not record on `--no-merge`
 *   or pending CI; recording on retries would inflate streak counts).
 *   Non-blocking — label downgrade is an explicitly permitted path in R-CM-030 and falls under user sovereignty (R-CM-016 Rule 10).
 *   The value of this mechanism is not *blocking*, but **making the normalization of deviance visible**.
 *
 * Trunk reconciliation: the ledger is written only by `ops.mjs` on its own
 *   successful merge, so it describes the compliant path and nothing else — five consecutive merges that
 *   bypassed ops.mjs left no row and the streak counter never saw them. Git is therefore the source of
 *   truth for *what landed* (`git log --first-parent origin/<base>`) and the ledger supplies only the
 *   label: `reconcileWithTrunk` joins landings to rows by `merge_sha` (legacy rows fall back to the PR
 *   number), and a landing with no row counts as `unrecorded`.
 *
 * Storage location: `.harness/system/ship-quality-ledger.jsonl` (system_persistent — shared across worktrees.
 *   R-CM-014 Rule 1 / R-CM-030 cross-ref. Via `resolveSystemFile` + atomic append).
 *
 * Boundary (R-CM-028): Perspective 1 only — R-CM-030 itself is never_deploy. Scaffold targets have their own review
 *   stack (`final-review`) and single-project scope where "consecutive PRs" carries a different meaning.
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolveSystemFile } from './layout-resolver.mjs';
import {
  ADVERSARIAL_REVIEW_MARKER,
  TRIVIAL_SKIP_LIMITS,
  formatReviewRemedy,
} from './quality-gate-labels.mjs';

export const LEDGER_FILENAME = 'ship-quality-ledger.jsonl';

/**
 * Labels recognized as actually performing secondary review. Others aggregated as skips.
 *
 * Rationale for including `skill_review_pass`: While this set contained `agent_go` only,
 *   the metric was measuring tool type (is tool an agent) rather than whether secondary review occurred.
 *   Because hooks cannot invoke subagents (R-CM-006 Rule 1) and some sessions lack Agent invocation permissions,
 *   proper reviews via `/code-review` / `code-standards-aligner` **skills** were downgraded to `self_review_pass`,
 *   indistinguishable from doing nothing.
 *
 *   Forgery prevention is handled on the PROOF evidence side rather than label vocabulary —
 *   `quality-gate-labels.mjs#checkLabelEvidence` refuses marker creation during `mark-pre-ship-confirmed`
 *   if gates[] lacks execution records.
 */
export const CROSS_REVIEWED_LABELS = new Set(['agent_go', 'skill_review_pass']);

/**
 * Streak threshold — warns when secondary review is skipped for this many consecutive PRs. Default 3.
 * Rationale: DEBT-248 was noticed by humans at 3 consecutive occurrences. 1–2 occurrences may be normal variation
 * (trivial / missing tools); 3 is sufficient signal that it has become the default.
 */
export const STREAK_THRESHOLD = 3;

/** Scale targets counted for streaks — trivial is exempt from Rule 8 and not counted. */
export const COUNTED_SCALES = new Set(['medium', 'large']);

/** Ledger absolute path (system_persistent). */
export function ledgerPath() {
  return resolveSystemFile(LEDGER_FILENAME);
}

/**
 * Reads ledger — skips corrupted lines (for advisory channels, partial progress is better than total failure).
 * @returns {Array<object>} Chronological order (oldest first)
 */
export function readLedger({ path = ledgerPath(), existsFn = existsSync, readFn = (p) => readFileSync(p, 'utf-8') } = {}) {
  if (!existsFn(path)) return [];
  let text;
  try {
    text = readFn(path);
  } catch {
    return [];
  }
  const out = [];
  for (const line of String(text).split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      const parsed = JSON.parse(t);
      if (parsed && typeof parsed === 'object') out.push(parsed);
    } catch {
      // Skip corrupted lines
    }
  }
  return out;
}

/**
 * Counts consecutive secondary review skips (pure).
 *   Traverses backward from latest, looking only at **counted scales**, stopping upon encountering reviewed labels.
 *   Skips trivial scale — counting them would trigger warnings from "3 trivial PRs".
 *   Counts each PR number once: a retried ship, or a ledger that outlived a repo re-creation (PR
 *   numbers restarting at #1), otherwise lists the same PR twice and inflates the streak.
 *
 * `unrecorded` entries (a trunk landing with no ledger row — see `reconcileWithTrunk`) are counted
 * regardless of scale. The scale filter excuses *trivial* changes from Rule 8; a landing that never
 * reached the gate made no such claim, and its size is unknown because nothing measured it.
 *
 * This counts only. The bypass census is `unrecordedSinceLastRecord`, deliberately not computed in
 * this walk: the walk stops at the first reviewed label, which would hide every bypass beneath one
 * properly reviewed ship.
 * @param {Array<object>} entries Chronological order (oldest first)
 * @returns {{streak: number, prs: Array<number|string|null>}}
 */
export function countCrossReviewSkipStreak(entries) {
  const prs = [];
  const seen = new Set();
  let streak = 0;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (!e || typeof e !== 'object') continue;
    if (!e.unrecorded && !COUNTED_SCALES.has(e.scale)) continue; // Ignore trivial/unclassified
    if (CROSS_REVIEWED_LABELS.has(e.quality_label)) break; // Stop streak at reviewed point
    if (e.pr != null) {
      if (seen.has(String(e.pr))) continue;
      seen.add(String(e.pr));
    }
    streak += 1;
    prs.push(e.pr ?? null);
  }
  return { streak, prs };
}

/**
 * Landings that reached the trunk with no ledger row since the newest landing that has one (pure).
 *
 * A streak and a census are different measurements and must not share a stopping rule: folded into
 * the streak walk, the census went silent the moment one reviewed ship landed on top, so bypasses were
 * reported only to teams that were *also* skipping review.
 *
 * The bound ("since the last recorded landing") applies to the named list only, so the alert does not
 * repeat pre-ledger history forever. `unrecordedInWindow` reports the total beside it — a rule that
 * shortens the list must not shorten the fact. Known limit: a bypass followed by a recorded ship drops
 * out of the list (it stays in the count).
 *
 * Names are deduplicated: two rowless landings claiming the same `(#N)` (the ambiguity case in
 * `reconcileWithTrunk`) are one PR to check, not two.
 *
 * @param {Array<object>} entries Chronological (oldest first), from `reconcileWithTrunk`
 * @returns {Array<number|string>} PR number when known, else the landing sha
 */
export function unrecordedSinceLastRecord(entries) {
  return namesSinceLastRecord(entries, (e) => e?.unrecorded);
}

/**
 * Bot-authored landings (dependabot and other `[bot]` accounts) since the last recorded one. Listed
 * separately and never counted: automation does not take the human pre-ship gate, so counting it as a
 * bypass would add one streak step per dependency bump and teach people to ignore the census.
 */
export function botLandingsSinceLastRecord(entries) {
  return namesSinceLastRecord(entries, (e) => e?.bot);
}

/** A real ledger row (neither a synthesised rowless landing nor a bot landing). */
const isRecorded = (e) => !e?.unrecorded && !e?.bot;

function namesSinceLastRecord(entries, pick) {
  const lastRecorded = entries.map(isRecorded).lastIndexOf(true);
  const names = entries
    .slice(lastRecorded + 1)
    .filter(pick)
    .map((e) => e.pr ?? e.merge_sha)
    .filter((v) => v !== null && v !== undefined);
  return [...new Set(names)];
}

/**
 * How many landings in the scanned window have no ledger row at all.
 * @param {Array<object>} entries from `reconcileWithTrunk`
 * @returns {number}
 */
export function unrecordedInWindow(entries) {
  return entries.filter((e) => e?.unrecorded).length;
}

/**
 * Parses `git log --first-parent --format=%H%x09%ct%x09%an%x09%s <ref>` into landing records (pure).
 * The two-field `%H%x09%s` shape is still accepted (no time / author).
 *
 * Every first-parent commit on the trunk is a landing — squash, merge commit, rebase merge or direct
 * push. They are not told apart: whether a landing went through the gate is answered by `merge_sha`,
 * not by the subject. The PR number (squash `(#N)` suffix or `Merge pull request #N`) only names the
 * landing and serves as the legacy match key; a miss yields `pr: null`, which reads as unrecorded —
 * the over-warning direction.
 *
 * @param {string} text
 * @returns {Array<{sha: string, subject: string, pr: number|null, time: number|null, bot: boolean}>}
 *          newest first, as git emits; `time` is the committer epoch in seconds
 */
export function parseTrunkLandings(text) {
  const out = [];
  for (const line of String(text ?? '').split('\n')) {
    const fields = line.split('\t');
    if (fields.length < 2) continue;
    const sha = fields[0].trim();
    if (!/^[0-9a-f]{7,40}$/i.test(sha)) continue;
    const full = fields.length >= 4 && /^\d+$/.test(fields[1]);
    const subject = (full ? fields.slice(3) : fields.slice(1)).join('\t');
    const m = subject.match(/\(#(\d+)\)\s*$/) || subject.match(/^Merge pull request #(\d+)\b/);
    out.push({
      sha,
      subject,
      pr: m ? Number(m[1]) : null,
      time: full ? Number(fields[1]) : null,
      bot: full ? isBotAuthor(fields[2]) : false,
    });
  }
  return out;
}

/** GitHub App / bot accounts (`dependabot[bot]`, `renovate[bot]`, ...), plus dependabot by name. */
export function isBotAuthor(name) {
  return /\[bot\]$/i.test(String(name ?? '').trim()) || /dependabot/i.test(String(name ?? ''));
}

const hasPr = (v) => v !== null && v !== undefined;

/**
 * Indexes ledger rows by `merge_sha` and by PR number. A row with a sha lives in **both** indexes
 * (sha consulted first): a sha that fails to match — force-push, merge queue rewrite — must still have
 * the PR number as a way home, or a gated ship is accused for as long as the window holds it.
 *
 * The PR index keeps the **newest** row per number, consistent with the PR dedup in
 * `countCrossReviewSkipStreak`: when a ledger outlives a repo re-creation (numbers restart at #1), the
 * newest row is the one describing the current trunk.
 */
function indexLedgerRows(ledger) {
  const bySha = new Map();
  const byPr = new Map();
  for (const row of ledger) {
    if (!row || typeof row !== 'object') continue;
    if (typeof row.merge_sha === 'string' && row.merge_sha) bySha.set(row.merge_sha, row);
    if (hasPr(row.pr)) byPr.set(String(row.pr), row);
  }
  return { bySha, byPr };
}

/**
 * How many *unresolved* landings claim each PR number. A landing whose sha is in `bySha` is claimed
 * by that sha and never by a number, so counting it would invent an ambiguity that falls on a real ship.
 */
function countPrClaimants(landings, bySha) {
  const claims = new Map();
  for (const l of landings) {
    if (!hasPr(l?.pr) || bySha.has(l.sha)) continue;
    claims.set(String(l.pr), (claims.get(String(l.pr)) ?? 0) + 1);
  }
  return claims;
}

/**
 * Joins what landed on the trunk with what the ledger claims was shipped (pure).
 *
 * Rules, each fixed after a reproduced failure:
 *   - Matching is by `merge_sha`; rows predating that field fall back to the PR number.
 *   - One row accounts for one landing — a match removes the row from both indexes, so a cherry-pick
 *     or issue reference ending in `(#82)` is not absorbed by #82's row and reported as gated.
 *   - The PR fallback stands down when the row's own sha is in the window: that landing is the row's,
 *     and no other may claim it by text.
 *   - An ambiguous PR number (row sha unavailable, more than one unresolved landing claiming the
 *     number) is not resolved by arrival order: no landing takes the row. Guessing yields a silent
 *     miss plus a false accusation; refusing yields one redundant warning.
 *
 * Known limit: `inWindow` is the scanned sample (`TRUNK_SCAN_DEPTH`), not the whole trunk, so a row
 * whose landing scrolled past the window reads like a rewritten one.
 *
 * @param {{ledger: Array<object>, landings: Array<{sha: string, pr: number|null}>}} input
 *        `landings` newest-first (git order); `ledger` chronological (oldest first)
 * @returns {Array<object>} chronological (oldest first), one entry per landing
 */
export function reconcileWithTrunk({ ledger = [], landings = [] }) {
  const { bySha, byPr } = indexLedgerRows(ledger);
  const inWindow = new Set(landings.map((l) => l?.sha).filter(Boolean));
  const claimsPerPr = countPrClaimants(landings, bySha);
  const claim = (landing) => {
    const bySa = bySha.get(landing.sha);
    if (bySa) {
      bySha.delete(landing.sha);
      if (hasPr(bySa.pr)) byPr.delete(String(bySa.pr));
      return bySa;
    }
    if (!hasPr(landing.pr)) return undefined;
    const byNumber = byPr.get(String(landing.pr));
    if (!byNumber || inWindow.has(byNumber.merge_sha)) return undefined;
    if ((claimsPerPr.get(String(landing.pr)) ?? 0) > 1) return undefined;
    byPr.delete(String(landing.pr));
    return byNumber;
  };
  // Oldest first: the census reads chronologically and `unrecordedSinceLastRecord` slices on it.
  return [...landings].reverse().map((landing) => claim(landing) ?? rowlessEntry(landing));
}

/**
 * The entry for a landing no row accounts for. A bot landing is marked `bot` rather than
 * `unrecorded`: listed, never counted (no scale, so the streak's scale filter skips it).
 */
function rowlessEntry(landing) {
  return {
    at: null,
    pr: landing.pr,
    branch: null,
    quality_label: null,
    scale: null,
    milestone_deck: false,
    merge_sha: landing.sha,
    time: landing.time ?? null,
    ...(landing.bot ? { bot: true } : { unrecorded: true }),
  };
}

/**
 * Drops rowless landings that predate the ledger (pure).
 *
 * Without a cutoff, a freshly transplanted target — or any repository whose history is older than its
 * ledger — named every landing in the window as a bypass (measured on harness with an empty ledger:
 * 100 named, streak 100). A landing is pre-ledger when it is older than the oldest landing a row
 * accounts for, or when its committer time is older than the oldest row's `at`.
 */
function dropPreLedger(landed, rows) {
  const firstClaimed = landed.findIndex(isRecorded);
  const times = rows.map((r) => Date.parse(r.at)).filter(Number.isFinite);
  const oldestAtSec = times.length ? Math.min(...times) / 1000 : null;
  return landed.filter((e, i) => {
    if (isRecorded(e)) return true;
    if (firstClaimed !== -1 && i < firstClaimed) return false;
    return !(oldestAtSec !== null && Number.isFinite(e.time) && e.time < oldestAtSec);
  });
}

/**
 * Ledger rows newer than the newest row the trunk accounted for, and not themselves on the trunk.
 *
 * GitHub squashes server-side and nothing fetches between a merge and the next reader, so the most
 * recent ships are routinely missing from the local `origin/<base>`. Dropping their rows (the
 * reconciliation is one entry per *landing*) would make recent skips vanish from the streak. With no
 * landing matched at all — including an unread trunk — this is the whole ledger, i.e. the
 * ledger-only behaviour that preceded reconciliation.
 */
function rowsNotYetOnTrunk(ledger, landed) {
  const claimed = new Set(landed);
  // A row refused as ambiguous is already represented by the rowless landings naming its number;
  // re-adding it would count (or break) the streak a second time for the same PR.
  const namedByLanding = new Set(landed.filter((e) => e.unrecorded && hasPr(e.pr)).map((e) => String(e.pr)));
  let newestClaimed = -1;
  ledger.forEach((row, i) => {
    if (claimed.has(row)) newestClaimed = i;
  });
  return ledger
    .slice(newestClaimed + 1)
    .filter((row) => !claimed.has(row) && !(hasPr(row.pr) && namedByLanding.has(String(row.pr))));
}

/**
 * One call for both consumers (ops.mjs after a merge, pre-ship-steps before one).
 *
 * `landings: null|undefined` means the trunk was not read. That is reported as `trunkRead: false`
 * rather than as zero bypasses, and the streak falls back to the ledger rows alone — an unreadable
 * trunk (no remote, never fetched) must neither invent bypasses nor erase the ledger's history.
 *
 * An empty ledger reports `noLedger: true` and counts nothing: with no row there is no cutoff between
 * pre-ledger history and a bypass, so every landing would be named.
 *
 * @param {{ledger: Array<object>|null, landings?: Array<object>|null}} input
 * @returns {{trunkRead: boolean, noLedger: boolean, entries: Array<object>, unrecorded: Array<number|string>,
 *            unrecordedTotal: number, bots: Array<number|string>}}
 *          `entries` chronological, for `countCrossReviewSkipStreak` (append the current ship after it).
 *          `unrecorded` / `unrecordedTotal` are computed over landings only, *before* any current-ship
 *          row is appended: a newest recorded entry would otherwise bury every bypass behind it.
 */
export function assessTrunk({ ledger, landings }) {
  const rows = (Array.isArray(ledger) ? ledger : []).filter((r) => r && typeof r === 'object');
  const trunkRead = Array.isArray(landings);
  if (rows.length === 0) {
    return { trunkRead, noLedger: true, entries: [], unrecorded: [], unrecordedTotal: 0, bots: [] };
  }
  const landed = dropPreLedger(reconcileWithTrunk({ ledger: rows, landings: trunkRead ? landings : [] }), rows);
  return {
    trunkRead,
    noLedger: false,
    entries: [...landed, ...rowsNotYetOnTrunk(rows, landed)],
    unrecorded: unrecordedSinceLastRecord(landed),
    unrecordedTotal: unrecordedInWindow(landed),
    bots: botLandingsSinceLastRecord(landed),
  };
}

/** Describes streak risks — tense-independent. */
const STREAK_RATIONALE =
  `R-CM-030 Rule 8 label downgrade is an allowed path, but consecutive occurrences normalize lowered standards as the default — ` +
  `empirical evidence: in #1050 and #1057, code-reviewer caught 1 HIGH finding each that self-review missed. `;

/**
 * Paths to break streaks — tense-independent, derived from `REPO_REVIEW_ASSETS`.
 *
 * Derived rather than written out because this string fires at the exact moment someone decides *how* to
 * break a streak. It previously offered `/code-review --fix`, a plugin absent from this environment, and
 * that unfollowable half of the advice is what talked #1221 into a needless downgrade (2026-08-26).
 * Computed per warning, not at import: it checks which assets exist in the project it runs in.
 */
const streakRemedyTools = () => formatReviewRemedy({ markup: true });

/**
 * Streak warning message (null when below threshold and no rowless landing is named).
 *
 * Rationale for tense branching (`projected`) (DEBT-259): Used at two distinct points —
 *   **After** merge (`ops.mjs`, immediately after ledger append: already occurred) and
 *   **Before** ship (`pre-ship-steps`, projection including current ship: not yet occurred).
 *   If phrasing is identical across different timings, pre-ship warnings read as "already too late", failing to prompt action.
 *   Tense branches while sharing risk explanation (STREAK_RATIONALE) and remedies (STREAK_REMEDY_TOOLS).
 *
 * A landing with no ledger row is reported on its **first** occurrence, unlike the streak: the threshold
 * measures whether an *allowed* path (label downgrade) has become the default, and a rowless landing
 * took no allowed path at all — waiting for three is how five accumulated.
 *
 * @param {{streak: number, prs: Array, unrecorded?: Array, unrecordedTotal?: number}} counted
 * @param {{projected?: boolean}} [opts] projected=true for "if this ship is merged" tense
 * @returns {string|null}
 */
export function formatStreakWarning(
  { streak, prs, unrecorded = [], unrecordedTotal = 0 },
  { projected = false } = {},
) {
  const bypassNote = formatBypassNote(unrecorded, unrecordedTotal);
  if (streak < STREAK_THRESHOLD) return bypassNote ? bypassNote.trim() : null;
  const list = (Array.isArray(prs) ? prs : [])
    .filter((p) => p !== null && p !== undefined)
    .map((p) => `#${p}`)
    .join(', ');
  const opening = projected
    ? `Merging this ship will result in ${streak} consecutive secondary review skips${list ? ` (previous: ${list})` : ''}. `
    : `Secondary review has been skipped for ${streak} consecutive PRs${list ? ` (${list})` : ''}. `;
  const tools = streakRemedyTools();
  const remedy = projected
    ? `Running ${tools} now and re-recording PROOF will break this streak here. ` +
      `The skill path is available even in sessions without Agent invocation permissions.`
    : `On the next substantial change, actually run ${tools}. ` +
      `The skill path is available even in sessions without Agent invocation permissions, ` +
      `and leaving execution records in PROOF gates[] will reset this streak.`;
  return opening + bypassNote + STREAK_RATIONALE + remedy;
}

/**
 * What the ledger could not credit on the ship just recorded ('' when nothing), so the reason sits
 * next to the count instead of being inferred from it.
 *
 * Why: the ledger reads the label from PROOF only. A ship with no PROOF label is recorded as a skip
 * even when a review really ran — observed 2026-09-24 in a transplant target, whose session ran an
 * adversarial review through a subagent, never wrote it to PROOF, and was told "35 consecutive
 * skips" with no hint that the missing record, not the missing review, was the cause. A
 * `trivial_skip` on a measured medium/large diff is the other silent case (a label that bypassed the
 * marker-time scale check, e.g. `--force`).
 *
 * @param {{quality_label: string|null, scale: string|null}} record the row just appended
 * @param {{proofPath?: string|null}} [opts]
 */
export function formatCurrentShipNote(record, { proofPath = null } = {}) {
  if (!record || !COUNTED_SCALES.has(record.scale)) return '';
  if (record.quality_label === null || record.quality_label === undefined) {
    return (
      `This ship was recorded with quality_label=null: no label was found in the PROOF` +
      `${proofPath ? ` (${proofPath})` : ''}, so it counts as a skipped secondary review whether or not ` +
      `one ran. Before the next ship, record the review in PROOF gates[] via ` +
      `\`node .claude/scripts/record-quality-gate.mjs\` (a review by any agent counts when its gate is ` +
      `named \`${ADVERSARIAL_REVIEW_MARKER}\`) and confirm with \`mark-pre-ship-confirmed.mjs --quality <label>\`.`
    );
  }
  if (record.quality_label === 'trivial_skip') {
    return (
      `This ship was labelled trivial_skip, but its measured scale is ${record.scale} — trivial_skip ` +
      `means ≤${TRIVIAL_SKIP_LIMITS.files} files and ≤${TRIVIAL_SKIP_LIMITS.loc} LOC. Check whatever ` +
      `passes that label (a ship wrapper with a hardcoded \`--quality\` is the observed cause).`
    );
  }
  return '';
}

/** Names a landing for humans: `#N` when a PR number is known, else the short sha. */
export function formatLandingName(v) {
  return typeof v === 'number' ? `#${v}` : String(v).slice(0, 7);
}

/**
 * The rowless-landing half of the warning ('' when there is none).
 *
 * The wording says what is known and no more: the code observes a missing row, and a row is also
 * missing when a human merges a `--no-merge` PR later, so it cannot claim the gate "did not run".
 */
function formatBypassNote(unrecorded, unrecordedTotal) {
  const named = (Array.isArray(unrecorded) ? unrecorded : []).filter(
    (v) => v !== null && v !== undefined,
  );
  if (named.length === 0) return '';
  const total =
    unrecordedTotal > named.length
      ? `(${unrecordedTotal} landings in the scanned window have no row in total; the list above is ` +
        `the part that landed since the last recorded ship.) `
      : '';
  return (
    `${named.length} landing(s) merged outside ship-worktree (UI or direct push) with NO ledger row since ` +
    `the last recorded ship (${named.map(formatLandingName).join(', ')}). A missing row means the ` +
    `pre-ship gate cannot be shown to have run — it does not prove it did not. Check those merges, and ship through ` +
    `\`node .claude/scripts/create-pr/ops.mjs ship-worktree\` so the label is recorded against the ` +
    `merged sha. ${total}`
  );
}

/**
 * Constructs one line for the ledger (pure — caller handles appending). Keeps schema tight: values needed for streak checks only.
 *
 * `merge_sha` is the commit the merge produced on the trunk and what `reconcileWithTrunk` matches on —
 * the only field that makes a row checkable against what actually landed. (An earlier version briefly also
 * recorded the PR `head`; nothing read it, so it was removed there and is not ported.)
 *
 * `approval` (`auto` | `human`) and `risk_tier` feed `approval-trust.mjs`: an escape is a fix that
 * lands on files an `auto` row last touched, so a row without them can never count as one.
 *
 * @param {{pr: number|string|null, branch: string, quality_label: string|null, scale: string|null,
 *          milestone_deck: boolean, at: string, merge_sha?: string|null,
 *          approval?: 'auto'|'human'|null, risk_tier?: string|null}} input
 */
export function buildShipRecord({
  pr,
  branch,
  quality_label,
  scale,
  milestone_deck,
  at,
  merge_sha = null,
  approval = null,
  risk_tier = null,
}) {
  return {
    at,
    pr: pr ?? null,
    branch: typeof branch === 'string' ? branch : null,
    // Missing label (PROOF unrecorded) is treated as review skipped — without records there is no basis for verification.
    quality_label: typeof quality_label === 'string' ? quality_label : null,
    scale: typeof scale === 'string' ? scale : null,
    milestone_deck: milestone_deck === true,
    // Empty strings are not shas: a row claiming '' would match nothing yet read as recorded.
    merge_sha: typeof merge_sha === 'string' && merge_sha ? merge_sha : null,
    approval: approval === 'auto' || approval === 'human' ? approval : null,
    risk_tier: typeof risk_tier === 'string' ? risk_tier : null,
  };
}

/** Bounds the trunk walk. The streak stops at the first reviewed label, so a healthy repository reads
 *  only a handful of landings; this cap only keeps the git call finite. */
export const TRUNK_SCAN_DEPTH = 100;

/**
 * The trunk ref for reconciliation: the remote-tracking copy of the configured ship base.
 *
 * `baseBranch` must come from `ship-base-branch.mjs` (`resolveShipBaseBranch` / the strict variant) —
 * never a literal, which is how a `develop`-based project got a confident census of `main`.
 *
 * Only `origin/<base>` — the first entry of `resolveShipBaseRefs` — is read, not its local-base or
 * `main` fallbacks. Those fallbacks keep *measurement* consumers alive, but here they are wrong:
 * without a remote no ship path can write a row (ops.mjs pushes and merges through GitHub), so
 * every landing on a local-only base would read as a bypass, and the `main` fallback is a different
 * trunk altogether. An unresolvable ref therefore yields "trunk not read" and the ledger-only streak.
 */
export function trunkRef(baseBranch) {
  return `origin/${baseBranch}`;
}

/** Arguments for the trunk landing log. Callers own the git invocation (this module never spawns). */
export function trunkLogArgs(baseBranch) {
  return [
    'log',
    '--first-parent',
    '--format=%H%x09%ct%x09%an%x09%s',
    '-n',
    String(TRUNK_SCAN_DEPTH),
    trunkRef(baseBranch),
  ];
}

/**
 * Arguments for when `origin/<base>` last **moved**. This is ref movement, not fetch time: the
 * remote-tracking reflog gains an entry only when the value changes, so a no-op fetch writes nothing.
 * An earlier version once printed "fetched 1h ago" about a trunk fetched seconds earlier. The number understates
 * freshness (the ref cannot have moved after the fetch that moved it), which is the allowed direction.
 */
export function trunkRefMovedArgs(baseBranch) {
  return ['reflog', 'show', '--date=unix', '-n', '1', `refs/remotes/${trunkRef(baseBranch)}`];
}

/**
 * @param {string} text output of `trunkRefMovedArgs`
 * @param {number} nowMs
 * @returns {number|null} seconds since the ref last moved, or null when git has no record
 */
export function parseTrunkRefMovedAge(text, nowMs = Date.now()) {
  const m = String(text ?? '').match(/@\{(\d+)\}/);
  if (!m) return null;
  return Math.max(0, Math.round(nowMs / 1000 - Number(m[1])));
}

/**
 * Human-readable qualifier. `null` renders as an explicit "no record" — an unqualified count reads as
 * current. Rounds first and promotes on overflow (picking the unit from raw seconds printed "60m" at
 * 3599s and "24h" at 86399s); rounds rather than truncates, since truncation understates staleness.
 */
export function formatTrunkRefMovedAge(seconds) {
  if (seconds === null || seconds === undefined) return 'last moved: no record';
  if (seconds < 90) return 'last moved just now';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `last moved ${minutes}m ago`;
  const hours = Math.round(seconds / 3600);
  if (hours < 24) return `last moved ${hours}h ago`;
  return `last moved ${Math.round(seconds / 86400)}d ago`;
}

/**
 * Reads trunk landings through an injected runner, or `null` when git could not answer.
 *
 * `null`, not `[]`: an empty list reconciles to "every landing accounted for", which is the one
 * answer this check must not give without having looked. One shared reader because the two callers
 * use opposite git calling conventions (`git(args, {cwd})` in ops.mjs, `gitFn(cwd, args)` in
 * pre-ship-steps); a flipped argument order throws inside a `try` and would silently degrade to a
 * permanent "not read". Each caller binds its own convention into `runGit(args) → string`.
 *
 * @param {string|null|undefined} baseBranch
 * @param {(args: string[]) => string} runGit
 * @returns {Array<{sha: string, subject: string, pr: number|null}>|null}
 */
export function readTrunkLandings(baseBranch, runGit) {
  if (typeof baseBranch !== 'string' || !baseBranch) return null;
  try {
    return parseTrunkLandings(runGit(trunkLogArgs(baseBranch)));
  } catch {
    return null;
  }
}

/** Seconds since `origin/<base>` last moved, or null (no record, or git could not answer). */
export function readTrunkRefMovedAge(baseBranch, runGit, nowMs = Date.now()) {
  if (typeof baseBranch !== 'string' || !baseBranch) return null;
  try {
    return parseTrunkRefMovedAge(runGit(trunkRefMovedArgs(baseBranch)), nowMs);
  } catch {
    return null;
  }
}
