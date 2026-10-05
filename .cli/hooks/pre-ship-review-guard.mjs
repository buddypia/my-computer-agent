#!/usr/bin/env node

/**
 * pre-ship-review-guard.mjs - PreToolUse Bash Hook
 *
 * Verifies freshness of Pre-Ship Human Review Panel confirmation marker
 * immediately prior to `/create-pr ship-worktree` / `ship-feature` calls.
 * Denies and provides panel obligation instructions if absent.
 *
 * Policy SSOT: R-CM-030 "Pre-Ship Human Review Panel"
 *
 * Behavior:
 *   - tool_name != Bash → passthrough
 *   - command not matching ops.mjs ship-worktree / ship-feature pattern → passthrough
 *   - Fresh marker (.tmp/pre-ship-review-confirmed-<branch>) within 10 min → passthrough (allow)
 *   - Missing/stale marker → deny + instruct AI on Human Review Panel + user confirmation + marker creation
 *   - error before the command is classified as a ship → passthrough (R-CM-006 Rule 2 fail-open);
 *     error after classification → deny (fail-closed — see run())
 *
 * Marker creation responsibility:
 *   AI presents the full Human Review Panel, completes every step of `pre-ship-steps`
 *   (including recording answers for human judgement steps ⑦⑧), then runs `mark-pre-ship-confirmed.mjs <branch> --quality <label>`.
 *   Marker CLI rejects incomplete steps (R-CM-030 Rule 13) — this hook inspects the resulting marker.
 */

import { existsSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import {
  readStdin,
  output,
  safeHookMainWithProfile,
  resolveProjectDir,
} from '../lib/utils.mjs';
import { HookOutput } from '../lib/hook-output.mjs';
import { VALID_QUALITY_LABELS, formatReviewRemedy } from '../lib/quality-gate-labels.mjs';
import {
  checkShipDeckFreshness,
  defaultGit,
  measureShipScale,
} from '../lib/ship-scale.mjs';
export { checkShipDeckFreshness };

const MARKER_TTL_MS = 10 * 60 * 1000; // 10 minutes — sufficient window between user confirmation and ship invocation
import {
  CMD_ANCHOR_SRC,
  SEQUENTIAL_SEPARATOR_RE,
  joinLineContinuations,
} from '../lib/hook-anchors.mjs';

// Matches `node ... ops.mjs ship-...` only at command start or immediately after chain operators.
const SHIP_PATTERN = new RegExp(
  CMD_ANCHOR_SRC + '(?:cd\\s+\\S+\\s+&&\\s+)?\\s*node\\s+\\S*ops\\.mjs\\s+ship-(?:worktree|feature)\\b',
);
const WORKTREE_ARG = /--worktree[\s=]+["']?([^"'\s]+)["']?/;
// Sequential composition (&& / || / ; / newline) — SSOT in hook-anchors.mjs.
// A pipe is deliberately excluded: the hint below is about a marker *file write* being invisible
// at hook-evaluation time, and `ship | tail` composes no such write.
const CHAIN_PATTERN = SEQUENTIAL_SEPARATOR_RE;

// Strip heredoc bodies — text inside `<<EOF...EOF` is data, not invocation context.
import { stripHeredocBodies } from '../lib/heredoc-strip.mjs';

export function isShipCommand(command) {
  return typeof command === 'string' && SHIP_PATTERN.test(stripHeredocBodies(command));
}

export function isChainedCommand(command) {
  return (
    typeof command === 'string' &&
    CHAIN_PATTERN.test(joinLineContinuations(stripHeredocBodies(command)))
  );
}

// Allowlist regex for --help exploration probes
const HELP_PROBE_RE =
  /^[ \t]*node[ \t]+[\w./-]*ops\.mjs[ \t]+ship-(?:worktree|feature)(?:[ \t]+--[\w-]+(?:[= \t][\w.=/@:-]+)?)*[ \t]*$/;

/**
 * Determines whether command is a --help probe (after heredoc stripping).
 */
export function isHelpProbe(stripped) {
  return /\s--help(?:\s|$)/.test(stripped) && HELP_PROBE_RE.test(stripped);
}

// SSOT: branch parsing + escape normalization + marker paths via worktree-plan-path.mjs.
import {
  safeBranchKey,
  inferBranchFromWorktreePath,
  preShipMarkerPath,
} from '../lib/worktree-plan-path.mjs';
import { loadReviewPanelConfig, renderReviewPanel } from '../lib/worktree-ship-report.mjs';
import { resolveShipBaseBranch } from '../lib/ship-base-branch.mjs';

export { safeBranchKey, inferBranchFromWorktreePath };

/**
 * Collects `NAME=value` / `NAME="value"` assignments appearing textually before `beforeIndex`
 * in the same command string (chain-local resolution — no shell is executed). Scoped to
 * assignment-position matches (start of string or right after a separator) so substrings like
 * `--foo=BAR=1` inside an unrelated flag are not mistaken for an assignment.
 */
function collectAssignmentsBefore(command, beforeIndex) {
  const out = {};
  const re = /(?:^|[;&|\n])\s*([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s;&|]*)/g;
  let m;
  while ((m = re.exec(command))) {
    if (m.index >= beforeIndex) break;
    let value = m[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[m[1]] = value;
  }
  return out;
}

/** Substitutes `$NAME` / `${NAME}` references using previously-collected assignments (best-effort, static text only). */
function substituteShellVars(value, assignments) {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (whole, braced, bare) => {
    const name = braced || bare;
    return Object.prototype.hasOwnProperty.call(assignments, name) ? assignments[name] : whole;
  });
}

/**
 * Resolves the `--worktree` argument, following same-command `NAME=value` assignments that
 * precede it (e.g. `W=.worktrees/fix/foo && ... --worktree "$W"`). Distinguishes "absent"
 * from "present but unresolvable" — the latter must deny with its own accurate message rather
 * than silently deriving a bogus marker key from the literal `$W` text (observed false deny).
 */
export function extractWorktreeArgInfo(command) {
  if (typeof command !== 'string') return { present: false, raw: null, value: null, unresolved: false };
  const m = command.match(WORKTREE_ARG);
  if (!m) return { present: false, raw: null, value: null, unresolved: false };
  const raw = m[1];
  const assignments = collectAssignmentsBefore(command, m.index);
  const resolvedValue = substituteShellVars(raw, assignments);
  const unresolved = resolvedValue.includes('$');
  return { present: true, raw, value: unresolved ? null : resolvedValue, unresolved };
}

export function extractBranch(command) {
  const info = extractWorktreeArgInfo(command);
  if (!info.present || info.unresolved) return null; // ship-feature mode, or unresolvable (handled separately in run())
  return inferBranchFromWorktreePath(info.value);
}

// Detects whether a chain actually creates the confirmation marker — the "hooks evaluate at
// command *start time*" rationale only applies when the chain touches marker creation. A chain
// with unrelated commands (`touch /tmp/x && ship ...`) never had a timing race to explain.
const MARKER_TOUCH_RE = /mark-pre-ship-confirmed\.mjs|\btouch\b[^\n;&|]*pre-ship-review-confirmed/;
export function commandTouchesMarker(command) {
  return typeof command === 'string' && MARKER_TOUCH_RE.test(command);
}

export function buildUnresolvedWorktreeDenyMessage(rawValue) {
  return [
    '[pre-ship-review-guard] ship call blocked: --worktree value not statically resolvable; pass a literal path',
    '',
    `Captured --worktree value: ${rawValue}`,
    'This hook resolves simple NAME=value / NAME="value" assignments appearing earlier in the same',
    'command text, but no matching assignment was found (or the assignment itself references another',
    'unresolved variable) — the value above still contains a literal $VAR after substitution.',
    '',
    'This is NOT a chained-command marker-touch timing issue (R-CM-030 Rule 1) — it is a static-text',
    'limitation of this hook: it cannot execute the shell to resolve variables assigned in a prior,',
    'separate Bash call.',
    '',
    'Fix: re-run with a literal worktree path, e.g.:',
    '  node .claude/scripts/create-pr/ops.mjs ship-worktree --worktree .worktrees/<branch> --title <t>',
  ].join('\n');
}

export const markerPath = preShipMarkerPath;

export function isFresh(absPath, ttlMs) {
  if (!existsSync(absPath)) return false;
  try {
    return Date.now() - statSync(absPath).mtime.getTime() <= ttlMs;
  } catch {
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────
// R-CM-030 Rule 12 Code Enforcement — Visual review deck obligation for large ships
// ─────────────────────────────────────────────────────────────────

/** Resolves --worktree argument of ship command as absolute path (null if missing — ship-feature mode) */
export function extractWorktreeAbsPath(command, projectDir) {
  const m = typeof command === 'string' ? command.match(WORKTREE_ARG) : null;
  if (!m) return null;
  return isAbsolute(m[1]) ? m[1] : join(projectDir, m[1]);
}

/**
 * Evaluates large-scale review deck gate — returns deny message or null (pass/unevaluable/inapplicable).
 */
export function evaluateDeckGate(command, projectDir, { gitFn = defaultGit } = {}) {
  const branch = extractBranch(command);
  const worktreeAbs = extractWorktreeAbsPath(command, projectDir);
  if (!branch || !worktreeAbs) return null; // ship-feature mode — not subject to deck gate
  const scale = measureShipScale(worktreeAbs, gitFn);
  if (scale?.scale !== 'large') return null; // Small/medium or unevaluable (fail-open)
  const deck = checkShipDeckFreshness(projectDir, safeBranchKey(branch), worktreeAbs, gitFn);
  if (deck.ok) return null;
  return buildDeckDenyMessage(branch, scale, deck, worktreeAbs);
}

export function buildDeckDenyMessage(branch, scale, deck, worktreeAbsPath) {
  const reasonLabel = deck.reason === 'deck_stale' ? 'stale (new commits exist since deck creation)' : 'missing';
  return [
    `[pre-ship-review-guard] ship call blocked: Large change but visual review deck is ${reasonLabel} (R-CM-030 Rule 12 code enforcement)`,
    '',
    `Measured scale: ${scale.reason}`,
    `Expected deck path: ${deck.deckPath}`,
    '',
    'Large ships turn human review into a formality when presenting full-panel prose alone (motivation for visual decks).',
    'Please complete the following steps before re-running ship:',
    `  1. node .claude/scripts/ship-deck.mjs --reach --worktree ${worktreeAbsPath} (what the gate demands),`,
    '     then author narrative JSON from `ship-deck.mjs --template` (human brief: for_whom / failure_modes /',
    '     tradeoffs[].cost / review_focus / known_gaps / rollback; exposure + data_change by reach) — fail-closed.',
    '     Plain language contract: Unlisted domain terms require "Term(explanation)" or',
    '     narrative.glossary registration, otherwise deck creation fails — R-CM-030 Rule 12)',
    `  2. node .claude/scripts/ship-deck.mjs --worktree ${worktreeAbsPath} --narrative-json <path>`,
    '  3. Open generated index.html and present to user (together with Panel Section 0 Decision Summary)',
    '  4. node .claude/scripts/pre-ship-steps.mjs next --worktree <path>',
    '     → Step through one by one; record user response verbatim on human judgement steps (Rule 13)',
    '  5. After every pre-ship-steps step passes, execute mark-pre-ship-confirmed.mjs → re-run ship',
    '',
    `Target branch: ${branch}`,
    'Limitation (stated honestly): This check verifies deck existence and mtime only — actually presenting',
    'the deck to the user is AI self-discipline (retroactive user discovery logs R-CM-024 audit).',
  ].join('\n');
}

/**
 * Extracts quality_gate label from marker file. JSON parse + enum verification.
 *
 * Fail-open policy (R-CM-006 Rule 2): Returns null on ENOENT. Throws on I/O errors.
 * Invalid JSON / unknown enum / empty are intentional deny conditions.
 *
 * @param {string} absPath
 * @returns {string|null} Valid label or null
 * @throws I/O errors (run() turns them into a fail-closed deny)
 */
export function readMarkerQualityLabel(absPath) {
  if (!existsSync(absPath)) return null; // ENOENT — normal absence
  const content = readFileSync(absPath, 'utf-8').trim();
  if (!content) return null; // empty marker (legacy) — intentional deny
  try {
    const parsed = JSON.parse(content);
    const label = parsed?.quality_gate;
    return typeof label === 'string' && VALID_QUALITY_LABELS.has(label) ? label : null;
  } catch {
    return null; // invalid JSON — intentional deny
  }
}

/**
 * Resolves appropriate absolute path for helper script (mark-pre-ship-confirmed.mjs).
 */
export function resolveHelperPath(projectDir, cwd) {
  const HELPER_REL = '.claude/scripts/mark-pre-ship-confirmed.mjs';
  const mainPath = join(projectDir, HELPER_REL);
  try {
    if (existsSync(mainPath)) return mainPath;
  } catch {
    return mainPath;
  }
  // Try worktree path if cwd is inside worktree
  if (cwd && cwd.includes('/.worktrees/')) {
    const idx = cwd.indexOf('/.worktrees/');
    const after = cwd.substring(idx + '/.worktrees/'.length);
    const segments = after.split('/').filter(Boolean);
    for (const len of [2, 1]) {
      if (segments.length >= len) {
        const worktreeRoot =
          cwd.substring(0, idx) + '/.worktrees/' + segments.slice(0, len).join('/');
        const wtPath = join(worktreeRoot, HELPER_REL);
        try {
          if (existsSync(wtPath)) return wtPath;
        } catch {
          // fall-through to next len or main default
        }
      }
    }
  }
  return mainPath;
}

export function buildDenyMessage(branch, safeKey, projectDir, cwd, showChainHint, reason = 'marker_absent') {
  const helperPath = resolveHelperPath(projectDir, cwd);
  // Project config (.claude/config/pre-ship-review-panel-sections.json) may localize/condense the
  // panel; absent → built-in sections and English labels, identical to before the extension point.
  const panel = loadReviewPanelConfig(projectDir);
  const sectionCount = panel.sections.length;
  const base = resolveShipBaseBranch(projectDir);
  // renderReviewPanel never throws (a broken config falls back to the built-in panel), so a bad
  // copy file cannot abort the panel (run() would deny as a guard error, but the panel is the useful answer).
  const rendered = renderReviewPanel(panel, {
    worktreePath: branch ? `.worktrees/${branch}` : '(staged / ship-feature)',
    branch: branch || 'staged',
    baseBranch: base,
    planPath: branch ? `.tmp/worktree-${safeKey}/PLAN.md` : '(staged mode)',
  });
  const reviewTemplate = rendered.text;
  const panelNotices = rendered.notices.map((n) => `     ${n}`);
  const header =
    reason === 'quality_label_missing'
      ? '[pre-ship-review-guard] ship call blocked: quality_gate label missing or invalid in marker'
      : '[pre-ship-review-guard] ship call blocked: Pre-Ship Human Review Panel unconfirmed';
  const lines = [
    header,
    '',
    ...(reason === 'quality_label_missing'
      ? [
          'R-CM-030 Rule 8 Pre-Ship Quality Gate: Persisting quality_gate label in marker file is mandatory.',
          'Blocks silent skips.',
          '',
          'Occurs when helper CLI --quality <label> argument is omitted.',
          '  Label types:',
          '    agent_go          — code-reviewer agent gives Go',
          '    skill_review_pass — Agent not used; independent secondary review via a review skill gives Go',
          '    self_review_pass  — Pure self-review without secondary review tools (specify reason in Panel Decisions)',
          '    trivial_skip      — R-CM-030 Rule 10 trivial (≤2 files + ≤20 LOC + non-substantive)',
          `  To earn one of the first two, run: ${formatReviewRemedy()}`,
          '  Both require execution records in PROOF gates[] before marker creation.',
          '',
          'To retry (marker CLI passes only after every pre-ship-steps step passes — R-CM-030 Rule 13):',
          `  node .claude/scripts/pre-ship-steps.mjs next --worktree <path>   # Check remaining steps`,
          `  node ${helperPath} ${branch || '--staged'} --quality <label>`,
          '',
        ]
      : []),
    ...(showChainHint
      ? [
          '⚠️ Chained command detected (&& / || / ; / newline). Hooks evaluate at command *start time*,',
          '   so marker touch inside the same chain is not reflected in hook evaluation.',
          '   → Separate marker creation (touch or mark-pre-ship-confirmed.mjs CLI) and ship invocation',
          '   **into separate Bash calls** and retry.',
          '',
        ]
      : []),
    ...(reason !== 'quality_label_missing'
      ? [
          `Per R-CM-030 "Pre-Ship Human Review Panel", you must provide a ${sectionCount}-section decision brief`,
          'enabling human review before calling ship-worktree / ship-feature.',
          'A standalone question ("Should I merge the PR with ship?") is not considered confirmation.',
          '',
          'Procedure:',
          `  1. Fill the ${sectionCount}-section Review template below with actual values and present to user:`,
          '',
          ...reviewTemplate.split('\n').map((line) => `     ${line}`),
          ...panelNotices,
          '',
          '     Recommended collection commands:',
          `       git log --oneline origin/${base}..HEAD`,
          `       git diff origin/${base}...HEAD --stat`,
          `       git diff origin/${base}...HEAD --name-status`,
          `       git diff origin/${base}...HEAD --numstat`,
          '  2. Check steps one-by-one with the step runner (R-CM-030 Rule 13 — no presumed approval):',
          `     node .claude/scripts/pre-ship-steps.mjs next --worktree ${branch ? `.worktrees/${branch}` : '<path>'}`,
          '     All automated check steps must pass before human judgement steps (deck review / approval) are presented.',
          '     During human judgement steps, pass questions to user and record response verbatim:',
          `     node .claude/scripts/pre-ship-steps.mjs answer --worktree ${branch ? `.worktrees/${branch}` : '<path>'} --step <id> --value "<what user actually said>"`,
          `     - Claude Code native: Select ${panel.approvalChoices.map((c) => `"${c}"`).join(' / ')} via AskUserQuestion`,
          '     - Codex/file mode: Confirm same 3 options via Decision Exchange or regular chat',
          '  3. After all steps pass (READY), generate marker (10 min freshness). Rejected before completion (exit 1):',
          `     node ${helperPath} ${branch || '--staged'} --quality <label>`,
          `     (Generates marker in main root's .tmp/ regardless of cwd. Helper path selected via fs inspection)`,
          `     Label types: agent_go / skill_review_pass / self_review_pass / trivial_skip (see helper --help or PR Decisions section)`,
          '  4. Then re-run ship command',
          '  5. Output completion_report_markdown from ship-worktree JSON response to user',
          '',
        ]
      : []),
    branch
      ? `Target branch: ${branch}`
      : 'Warning: --worktree argument omitted or in ship-feature mode (handled as branch=staged)',
    '',
    `marker key: ${safeKey}`,
    'To inspect argument specifications only, standalone --help invocations (without chains/quotes) are exempt from this gate:',
    '  node .claude/scripts/create-pr/ops.mjs ship-worktree --help',
    `Trivial changes (≤3 files / ≤50 LOC / zero code impact) retain all ${sectionCount} section headers — abbreviate content only.`,
    'Limitation: This hook checks marker existence + label validity only. AI can bypass by creating marker without panel.',
    '       → Retroactive user discovery reports R-CM-030 violation.',
  ];
  return lines.join('\n');
}

/** Returns `{ command, stripped }` for a real ship invocation, else null (not Bash / not ship / --help). */
function shipInvocationOf(data) {
  if (data?.tool_name !== 'Bash') return null;
  const command = data?.tool_input?.command || '';
  const stripped = stripHeredocBodies(command);
  if (!SHIP_PATTERN.test(stripped) || isHelpProbe(stripped)) return null;
  return { command, stripped };
}

/**
 * Fail-open only *before* classification: a hook that cannot even tell whether the command is a
 * ship must not block unrelated Bash. Once it is known to be a ship invocation, an exception means
 * the approval check did not run — passing it through would ship with no approval marker (a
 * malformed panel config did exactly that), so any error from here on denies (fail-closed).
 */
export async function run(data) {
  let invocation;
  try {
    invocation = shipInvocationOf(data);
  } catch {
    return HookOutput.passthrough();
  }
  if (!invocation) return HookOutput.passthrough();
  try {
    return evaluateShipInvocation(data, invocation);
  } catch (e) {
    return HookOutput.deny(buildGuardErrorDenyMessage(e));
  }
}

/** Short deny for an internal failure on a ship invocation — the approval check did not complete. */
export function buildGuardErrorDenyMessage(error) {
  const reason = String(error?.message ?? error ?? 'unknown error').split('\n')[0].slice(0, 200);
  return [
    '[pre-ship-review-guard] guard error, fail-closed — ship blocked because the approval check could not complete.',
    `  cause: ${reason}`,
    '  Fix the cause (often a malformed .claude/config/pre-ship-review-panel-sections.json), then retry.',
  ].join('\n');
}

function evaluateShipInvocation(data, { command, stripped }) {
  // Present-but-unresolvable `--worktree $VAR` must deny distinctly rather than silently
  // deriving a marker key from the literal `$VAR` text (observed false deny + misleading
  // "chained command" blame — see buildUnresolvedWorktreeDenyMessage).
  const worktreeArgInfo = extractWorktreeArgInfo(command);
  if (worktreeArgInfo.unresolved) {
    return HookOutput.deny(buildUnresolvedWorktreeDenyMessage(worktreeArgInfo.raw));
  }

  const projectDir = resolveProjectDir(data);
  const branch = extractBranch(command);
  const safeKey = safeBranchKey(branch);
  const path = markerPath(projectDir, branch);

  // R-CM-030 Rule 12 — Large deck obligation evaluated before marker check
  const deckDeny = evaluateDeckGate(command, projectDir);
  if (deckDeny) return HookOutput.deny(deckDeny);

  // The chain-timing rationale ("marker touch inside the same chain is invisible to this
  // hook") only applies when the chain actually creates the marker — an unrelated chained
  // command never had a timing race to explain.
  const showChainHint = isChainedCommand(stripped) && commandTouchesMarker(stripped);
  if (isFresh(path, MARKER_TTL_MS)) {
    const label = readMarkerQualityLabel(path);
    if (label) return HookOutput.passthrough();
    return HookOutput.deny(
      buildDenyMessage(
        branch,
        safeKey,
        projectDir,
        data?.cwd,
        showChainHint,
        'quality_label_missing',
      ),
    );
  }
  return HookOutput.deny(
    buildDenyMessage(branch, safeKey, projectDir, data?.cwd, showChainHint),
  );
}

if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMainWithProfile('pre-ship-review-guard', async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
