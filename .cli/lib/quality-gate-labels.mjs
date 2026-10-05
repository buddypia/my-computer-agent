/**
 * quality-gate-labels.mjs — Single SSOT for Quality Gate label enum + per-label PROOF evidence contracts
 *
 * Enum for marker JSON `quality_gate` field representing R-CM-030 Rule 8 (Pre-Ship Quality Gate)
 * environment branching + self-check fallback. Imported by both mark-pre-ship-confirmed.mjs (CLI emitter)
 * and pre-ship-review-guard.mjs (hook verifier).
 *
 * Label meanings:
 * - `agent_go`         : Both `/code-review --fix` + `code-reviewer` **agent** evaluated as Go (highest path).
 *                        Single entry point via `/code-review` after `/simplify` removal and `simplifit` skill deprecation on 2026-05-27  retired-ref-ok: simplifit deprecation records historical context — not an invocation instruction
 * - `skill_review_pass`: Agent not used. Independent 2nd review performed via a review **skill** + Go.
 *                        What to run is `REPO_REVIEW_ASSETS` (repo-shipped); what *counts* once run is
 *                        `LABEL_EVIDENCE_MARKERS` (wider — includes `/code-review` for environments that have it).
 * - `self_review_pass` : Pure self-review where 2nd review tools could not be run (Panel Decisions reason specified)
 * - `trivial_skip`     : R-CM-030 Rule 10 trivial exemption (≤2 files + ≤20 LOC + non-substantive)
 *
 * Rationale for creating `skill_review_pass` (empirical): Previous vocabulary recognized "cross-reviewed"
 *   only when agents were used (`ship-quality-ledger.mjs#CROSS_REVIEWED_LABELS = {agent_go}`).
 *   However, hooks cannot invoke subagents (prompt-type hooks are *instruction injections*, and prompt-type SubagentStop
 *   is prohibited by R-CM-006 Rule 1 to avoid output pollution), and some sessions lack Agent invocation permissions.
 *   When such sessions ran proper 2nd reviews via skills, labels were downgraded to `self_review_pass`, recording the **same
 *   value** in ledgers as doing nothing — measuring tool types rather than whether 2nd reviews were performed.
 *   Empirical: #1064–#1068 were all recorded as `self_review_pass`.
 *
 * Updating only this file when adding new labels reflects changes in both emitter / verifier — preventing mismatch regressions.
 */
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const VALID_QUALITY_LABELS = new Set([
  'agent_go',
  'skill_review_pass',
  'self_review_pass',
  'trivial_skip',
]);

/**
 * Tool-agnostic marker — names the *act* (an independent adversarial review), not a tool.
 *
 * Why: every other marker is a tool name, so a review run by any other agent could not be recorded.
 *   Observed 2026-09-24 in a transplant target (lottie-motion-studio): the `git-worktree-isolation`
 *   bundle does not ship `code-reviewer.md`, the session ran a real adversarial review through a
 *   general-purpose subagent, and no gate name it could honestly write satisfied `agent_go`. The ledger
 *   then reported that ship as the 35th consecutive skip. Accepted for both labels (the ledger counts
 *   them identically); the forgery bar is unchanged — a `pass`/`warn` gate in `name`/`command`.
 */
export const ADVERSARIAL_REVIEW_MARKER = 'adversarial-review';

/**
 * Per-label PROOF evidence markers — to claim a label, `name` or `command` in one of `gates[]`
 * must contain at least one of the markers below (case-insensitive; spaces/underscores read as `-`).
 *
 * Why: Adding labels without requiring evidence creates an additional escape hatch. Since declaring
 *   "reviewed via skill" breaks consecutive skip counts in the ledger, that declaration must be supported
 *   by execution records (isomorphic to R-CM-030 Rule 9 label inflation prevention).
 *
 * `agent_go` is required symmetrically — requiring evidence only for `skill_review_pass` creates a perverse incentive
 *   to declare a *stronger* label to avoid providing evidence. In practice, this imposes no extra burden:
 *   past `agent_go` PROOFs already recorded gate names as `code-reviewer agent` / `code-reviewer agent (verdict)`.
 *
 * `code-reviewer` ⊃ `code-review` (substring) — agent evidence automatically satisfies skill evidence.
 * Semantically sound (agent is a stronger 2nd review). The reverse does not hold: `code-review --fix` does not contain `code-reviewer`.
 *
 * Unlisted labels (`self_review_pass` / `trivial_skip`) require no evidence — they represent declarations that 2nd review
 *   was not performed, which the ledger aggregates as skips.
 *
 * Naming note: Using `TOKENS` in constant names triggers false positives in `secret-patterns.mjs#Env Secret Assignment`
 *   (`[A-Z0-9_]*TOKEN[A-Z0-9_]*\s*=\s*...`), blocking writes — use `MARKERS`.
 */
export const LABEL_EVIDENCE_MARKERS = Object.freeze({
  agent_go: Object.freeze(['code-reviewer', ADVERSARIAL_REVIEW_MARKER]),
  skill_review_pass: Object.freeze(['code-review', 'code-standards-aligner', ADVERSARIAL_REVIEW_MARKER]),
});

/**
 * `trivial_skip` limits — R-CM-030 Rule 10 (≤2 files + ≤20 LOC). The only label whose claim is a
 * measurement, so it is checked against one (`checkTrivialClaim`) instead of taken on trust.
 *
 * Why: nothing measured it. Observed 2026-09-24 — a transplant target's local ship wrapper hardcoded
 * `--quality trivial_skip`, and 34 of its 54 ledger rows were medium/large ships labelled trivial.
 */
export const TRIVIAL_SKIP_LIMITS = Object.freeze({ files: 2, loc: 20 });

/**
 * Whether a label's scale claim holds for the measured diff (pure).
 * @param {string|null|undefined} label
 * @param {{files: number, loc: number}|null|undefined} measured null = unmeasurable (fail-open)
 * @returns {{ok: boolean, files?: number, loc?: number}}
 */
export function checkTrivialClaim(label, measured) {
  if (label !== 'trivial_skip' || !measured) return { ok: true };
  const { files, loc } = measured;
  return { ok: files <= TRIVIAL_SKIP_LIMITS.files && loc <= TRIVIAL_SKIP_LIMITS.loc, files, loc };
}

/**
 * Review assets **this repo ships** — the only tools operator-facing advice may tell someone to run.
 *
 * Deliberately narrower than `LABEL_EVIDENCE_MARKERS`, because the two answer different questions.
 * Markers answer *what counts as evidence*, and may legitimately name tools the repo does not own: a
 * session that has `/code-review` installed and runs it did perform a secondary review, so the record
 * should count. This list answers *what do we tell the operator to run* — and an answer the repo does
 * not ship is not an answer.
 *
 * Conflating the two cost a ship cycle on 2026-08-26. Every advice site named `/code-review --fix` as a
 * primary path; `code-review@claude-plugins-official` was absent from `enabledPlugins`, so the command
 * did not exist for anyone in that environment. The operator read the marker rejection plus that advice
 * as "both admitted paths are closed" and downgraded #1221 to `self_review_pass` — while
 * `code-standards-aligner` sat in this repo, reachable, and had already earned the label on a two-file
 * change in #1212 and again in #1218. The advice was wrong, not the label rules.
 *
 * This is the same defect #1070 fixed one level down. That PR stopped the ledger from measuring *which
 * tool* instead of *whether review happened*; the `/code-review` reference it left in the prose
 * reintroduced the failure at the advice layer, where nothing checked it.
 *
 * Named `REPO_` and not `LOCAL_` on purpose: `local` already means *worktree-scoped* in this codebase
 * (`harness-layout.json` lifecycles `worktree_local` vs `system_persistent`), and "is it available on
 * this machine" is precisely the question this list refuses to answer. What it asserts is narrower and
 * checkable — this repository ships it.
 *
 * `path` is repo-relative and asserted to exist by `tests/unit/quality-gate-labels.test.mjs`. Advice
 * that names a vanished asset is this bug again, so it fails the suite rather than the next ship.
 *
 * `surfaces` declares which CLIs can run the asset (subset of `REVIEW_SURFACES`). The guards that print
 * this advice are registered for every CLI, so a Claude-only asset (subagents) must not be advertised
 * to a Codex or Antigravity session as if it could run it. Declared rather than detected: guessing the
 * current CLI would be a new way to be wrong, while an accurate annotation is right in every session.
 * An asset without `surfaces` is treated as reachable from every surface.
 *
 * "This repository" is wherever this file is running. Transplant bundles copy this module into
 * projects that do not receive the assets (`git-worktree-isolation` ships neither), so
 * `formatReviewRemedy` checks each path against the project it runs in rather than trusting the list.
 */
export const REPO_REVIEW_ASSETS = Object.freeze([
  Object.freeze({
    label: 'agent_go',
    tool: 'code-reviewer agent',
    path: '.claude/agents/code-reviewer.md',
    // Subagents are a Claude Code capability.
    surfaces: Object.freeze(['claude']),
  }),
  Object.freeze({
    label: 'skill_review_pass',
    tool: 'code-standards-aligner skill',
    path: '.claude/skills/code-standards-aligner/SKILL.md',
    // Skills live under `.agents/skills/` (mirrored to `.claude/skills/`), reachable from every CLI.
    surfaces: Object.freeze(['claude', 'codex', 'antigravity']),
  }),
]);

/** Every surface (CLI) a review asset may declare in `REPO_REVIEW_ASSETS[].surfaces`. */
export const REVIEW_SURFACES = Object.freeze(['claude', 'codex', 'antigravity']);

/**
 * Operator-facing remedy advice, derived from `REPO_REVIEW_ASSETS` so it cannot name an absent tool.
 *
 * Call sites interpolate this instead of hand-writing tool names — that is the actual fix, since a
 * hand-written copy is unguarded by construction and three of them rotted at once.
 *
 * @param {{markup?: boolean}} [opts] markup=true backticks tool and label names (markdown sinks);
 *   false emits bare text for terminal sinks. It governs *all* backticks — a half-marked string reads
 *   as broken markdown in one sink and as stray punctuation in the other.
 */
/** Project root of the running copy — this module lives at `<root>/.cli/lib/`. */
const RUNNING_PROJECT_ROOT = fileURLToPath(new URL('../..', import.meta.url));

export function formatReviewRemedy({
  markup = false,
  projectDir = RUNNING_PROJECT_ROOT,
  existsFn = existsSync,
} = {}) {
  const tick = markup ? '`' : '';
  const present = REPO_REVIEW_ASSETS.filter((asset) => existsFn(join(projectDir, asset.path)));
  // Always reachable: needs no shipped asset, only a reviewer that did not write the change.
  const agnostic =
    `an adversarial review by a separate agent or session, recorded as a gate named ` +
    `${tick}${ADVERSARIAL_REVIEW_MARKER}${tick} (${tick}agent_go${tick} or ${tick}skill_review_pass${tick})`;
  const shipped = present.map((asset, i) => {
    // An asset only some CLIs can reach says so, instead of being filtered out: filtering would need
    // to know which CLI is reading, and a wrong guess silently removes the stronger review path.
    const only =
      asset.surfaces && asset.surfaces.length < REVIEW_SURFACES.length
        ? `, ${asset.surfaces.join('/')} only`
        : '';
    return `${'①②③④'[i] ?? `(${i + 1})`} ${tick}${asset.tool}${tick} (${tick}${asset.label}${tick}${only})`;
  });
  const n = shipped.length;
  return [...shipped, `${'①②③④'[n] ?? `(${n + 1})`} ${agnostic}`].join(' or ');
}

/**
 * Gate statuses recognized as evidence — only those that **actually ran**.
 *
 * `skip` explicitly records "not run", while `fail` records failure to pass. Counting either
 * as evidence would allow claiming cross-review via a single line `{"name":"code-review --fix","status":"skip"}`,
 * reopening the bypass that evidence checks aim to close.
 * (While schemas prevent `verdict='go'` + `status='fail'` contradictions, `skip` is not blocked by schema — must filter here.)
 */
export const EVIDENCE_GATE_STATUSES = Object.freeze(['pass', 'warn']);

/** Extracts search target fields from 1 gate as lowercase string (name required / command optional). */
function gateSearchText(gate) {
  if (!gate || typeof gate !== 'object') return '';
  if (!EVIDENCE_GATE_STATUSES.includes(gate.status)) return '';
  const name = typeof gate.name === 'string' ? gate.name : '';
  const command = typeof gate.command === 'string' ? gate.command : '';
  // Spaces/underscores fold to '-' so `adversarial review` and `code_reviewer` read like the markers.
  return `${name} ${command}`.trim().toLowerCase().replace(/[\s_]+/g, '-');
}

/**
 * Determines whether PROOF evidence required by label exists in `gates[]` (pure — no fs access).
 *
 * `detail` / `finding` are excluded from search — descriptive fields may contain sentences like "did not run code-review",
 * which could be misidentified as evidence. Inspects only `name`/`command` containing *what was executed*.
 * Evaluates only gates where `status` is `pass`/`warn` (`EVIDENCE_GATE_STATUSES`).
 *
 * @param {string|null|undefined} label
 * @param {unknown} gates — Gates array from PROOF record (non-array/absence allowed)
 * @returns {{required: boolean, satisfied: boolean, markers: string[], matchedGate: string|null}}
 *   If `required=false`, satisfied is always true (simplifying caller branching).
 */
export function checkLabelEvidence(label, gates) {
  const markers = LABEL_EVIDENCE_MARKERS[label];
  if (!markers) return { required: false, satisfied: true, markers: [], matchedGate: null };

  const list = Array.isArray(gates) ? gates : [];
  for (const gate of list) {
    const text = gateSearchText(gate);
    if (!text.trim()) continue;
    if (markers.some((m) => text.includes(m))) {
      return {
        required: true,
        satisfied: true,
        markers: [...markers],
        matchedGate: typeof gate.name === 'string' ? gate.name : null,
      };
    }
  }
  return { required: true, satisfied: false, markers: [...markers], matchedGate: null };
}
