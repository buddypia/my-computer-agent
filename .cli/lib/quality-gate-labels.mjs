/**
 * quality-gate-labels.mjs — Single SSOT for the Quality Gate label enum
 *
 * Enum for marker JSON `quality_gate` field representing R-CM-030 Rule 8 (Pre-Ship Quality Gate)
 * environment branching + self-check fallback. Imported by both mark-pre-ship-confirmed.mjs (CLI emitter)
 * and pre-ship-review-guard.mjs (hook verifier).
 *
 * Label meanings:
 * - `agent_go`         : Both `/code-review --fix` + `code-reviewer` **agent** evaluated as Go (highest path).
 *                        Single entry point via `/code-review` after `/simplify` removal and `simplifit` skill deprecation on 2026-05-27  retired-ref-ok: simplifit deprecation records historical context — not an invocation instruction
 * - `skill_review_pass`: Agent not used. Independent 2nd review performed via a review **skill** + Go.
 *                        What to run is `REPO_REVIEW_ASSETS` (repo-shipped).
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
 * It answers *what do we tell the operator to run* — and an answer the repo does not ship is not an
 * answer.
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
    `an adversarial review by a separate agent or session ` +
    `(${tick}agent_go${tick} or ${tick}skill_review_pass${tick})`;
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
