#!/usr/bin/env node

/**
 * worktree-policy-guard.mjs - PreToolUse Edit|Write (+ Bash, opt-in) Hook
 *
 * Blocks direct modifications on the main branch using tier-based allowlists.
 * Opt-in (`trunk_bash_allowlist.enabled: true` in the policy): on trunk, also blocks Bash commands
 * that are not on the target's allowlist (see "Trunk Bash allowlist" below). Default off — without
 * the key, Bash calls return before any git call.
 *
 * Policy SSOT: .claude/config/worktree-policy.json
 *
 * Behavior:
 *   - branch != main → passthrough (automatic pass when working inside worktrees)
 *   - hotfix/* / hotfix-* branch → passthrough (escape hatch)
 *   - main + Tier 1 (allowed) → passthrough
 *   - main + Tier 2 (worktree smoke test recommendation) → allowWithWarning
 *   - main + Tier 3 (others) → deny
 *   - unresolved branch (safeGit timeout / detached HEAD) → evaluate tiers as protected (fail-closed —
 *     mirrors commit-guard unresolved_branch, R-CM-008: the verdict must not be a function of machine
 *     load. Worktree-path targets and Tier 1 remain unaffected because they are exempted per-file below)
 *   - error or missing policy file → passthrough (fail-open to prevent self-blocking, R-CM-006 Rule 2)
 *
 * Reference pattern: destructive-git-guard.mjs
 */

import { basename, dirname, join, relative, isAbsolute } from 'path';
import {
  readStdin,
  output,
  safeHookMainWithProfile,
  safeGit,
  safeReadJson,
  resolveProjectDir,
  withCommandCwd,
} from '../lib/utils.mjs';
import { HookOutput } from '../lib/hook-output.mjs';
import { extractApplyPatchFilePaths } from '../lib/apply-patch-paths.mjs';
import { isEscapeHatch, matchesGlob, requiresWorktree } from '../lib/trunk-branch.mjs';
import { existsSync, realpathSync } from 'fs';
import { commandText, isInside, pathArgs, walkSegments } from '../lib/bash-segments.mjs';
import { resolveWorktreeRoot } from '../lib/worktree-path.mjs';

// Glob + escape-hatch matching live in trunk-branch.mjs (shared with commit-guard / trunk-start-warning
// through `requiresWorktree`); re-exported here for existing importers.
export { matchesGlob, isEscapeHatch };

export function classifyTier(relPath, policy) {
  const tier1Patterns = policy?.tiers?.tier1_main_allowed?.patterns ?? [];
  if (tier1Patterns.some((p) => matchesGlob(relPath, p))) return 1;

  const tier2Patterns = policy?.tiers?.tier2_worktree_code_main_verify?.patterns ?? [];
  if (tier2Patterns.some((p) => matchesGlob(relPath, p))) return 2;

  return 3;
}

/**
 * Extracts and normalizes file_path from Edit/Write/MultiEdit tools.
 *   - Relative path → joined with projectDir (guarantees absolute path)
 *   - Empty string / unsupported tools → empty array
 */
export function extractFilePaths(toolName, toolInput, projectDir = '') {
  if (!toolInput) return [];
  // Codex sends tool_name="apply_patch" + tool_input.command (patch text) on edits.
  if (toolName === 'apply_patch') {
    return extractApplyPatchFilePaths(toolInput.command, projectDir);
  }
  if (!['Edit', 'Write', 'MultiEdit'].includes(toolName)) return [];
  const raw = toolInput.file_path;
  if (!raw || typeof raw !== 'string') return [];
  const abs = isAbsolute(raw) ? raw : (projectDir ? join(projectDir, raw) : raw);
  return [abs];
}

/**
 * Validates whether policy object is in usable form.
 *   - Missing tiers / missing both pattern arrays → unusable (fail-open passthrough in run())
 */
export function isPolicyUsable(policy) {
  if (!policy || !policy.tiers) return false;
  const t1 = policy.tiers.tier1_main_allowed?.patterns;
  const t2 = policy.tiers.tier2_worktree_code_main_verify?.patterns;
  return Array.isArray(t1) || Array.isArray(t2);
}

/**
 * Determines whether file is under .worktrees/.
 *
 * @param {string} relPath - Normalized relative path based on projectDir
 * @returns {boolean}
 */
export function isWorktreeRelPath(relPath) {
  return typeof relPath === 'string' && relPath.startsWith('.worktrees/');
}

/**
 * Branch-level gate: should per-file tier evaluation run at all?
 *
 * Unresolved branch (null — safeGit 2s timeout or detached HEAD '') evaluates tiers, i.e. fails
 * closed. commit-guard fixed the identical class on 2026-08-24 (`unresolved_branch` → deny): an
 * unresolved signal is not evidence of safety, and passthrough made trunk protection a function of
 * machine load. This sibling guard shares the same trunk-protection purpose, so it mirrors the
 * policy. Worktree files and Tier 1 paths stay unaffected (per-file exemptions in run()).
 *
 * Opt-in `enforce_worktree_all_branches: true` widens "protected" from trunk to every branch
 * (`requiresWorktree`); escape-hatch branches (hotfix/*) still pass.
 */
export function shouldEvaluateTiers(branch, policy) {
  if (!branch) return true;
  if (!requiresWorktree(branch, policy)) return false;
  if (isEscapeHatch(branch, policy)) return false;
  return true;
}

function buildDenyMessage(relPath, branch = 'main') {
  return (
    `[Worktree Policy] Direct editing on ${branch} branch blocked: ${relPath}\n\n` +
    `This file must be worked on within a worktree.\n` +
    `  → Create worktree (standard entry point, based on fetch + ff + latest base):\n` +
    `      make wt.new BR=feature/<task>\n` +
    `      # Or: node .claude/scripts/worktree-new.mjs --branch feature/<task>\n` +
    `  → Emergency escape hatch: All blocks are waived on hotfix/* branches\n` +
    `Policy SSOT: .claude/config/worktree-policy.json`
  );
}

// ── Trunk Bash allowlist (opt-in) ────────────────────────────────────────────────────────────
//
// The trunk allowlist is configurable rather than hard-coded in this file.
// The mechanism lives here; the list is the target's, in `.claude/config/worktree-policy.json`:
//
//   "trunk_bash_allowlist": { "enabled": true, "patterns": ["git\\s+status", "make\\s+wt\\.[\\w.-]+", …] }
//
// Each pattern is a regex *source* judged against one simple command at a time, after env
// assignments, reserved words (`then` …), wrappers (`env`, `sudo`, `command`, `time`, `xargs` …)
// and git global options are removed. The guard anchors it on both sides — `^(?:<pattern>)(?=\s|$)`
// — so a pattern names whole command words: `ls` does not admit `lsof`, and a pattern cannot match
// in the middle of a command. An earlier version left patterns unanchored at the end
// (`node\s+\S*ops` admitted any script whose name ends in "ops").
//
// Exempt regardless of patterns (not trunk work):
//   - `cd` itself
//   - a command whose effective directory (cwd after a `&&`-chained `cd`, then cumulative
//     `git -C` / `make -C`) is inside an existing linked worktree under `.worktrees/`, **and** none
//     of its path-valued arguments or redirect targets resolves into the trunk checkout (the
//     project root outside `.worktrees/`) or fails to resolve. `cd .worktrees/x && rm -rf ../..`,
//     `git -C .worktrees/x -C ../.. reset --hard`, `git -C .worktrees/x --work-tree=../.. …` and
//     `make -C .worktrees/x -f ../../Makefile` are therefore judged as trunk commands.
//   - After `;` / `||` / `|` / `&` the preceding `cd` may have failed, so it no longer exempts.
//   - `env -C <dir>` counts as a cd for that one command. Directories and path arguments are
//     compared after realpath, so a symlink inside a worktree that points at the trunk does not
//     exempt. A path word with `..` plus brace/glob characters is unresolvable (not exempt).
// Denied regardless of patterns: an output redirect into a file (anything but /dev/null or an fd),
// `time -o <file>`, any `GIT_*=` / `CDPATH=` assignment (they move what git / cd act on), and
// `env -S '<cmd>'`.
// What is *not* enforced: file-writing options of a listed command (`find -delete`,
// `git log --output=f`). Exclude those in the pattern itself (negative lookahead).
// Commands inside `$( … )`, backticks and unquoted-delimiter heredoc bodies are judged as their
// own segments. A command the scanner cannot parse safely (nesting deeper than MAX_NESTING) is
// denied — fail closed, because the target opted in.
//
// Threat model: an honest agent that over-generalises ("just run it here"), not a malicious one.
// A static allowlist cannot fence a shell completely, and does not try to. Known limits: interpreter
// payloads and scripts (`bash -c`, `node -e`, `python -c`, a script path) are opaque; so are write-by-
// argument tools (`dd of=`); allowlisted tools that execute project config (make targets, cargo
// build scripts) run whatever that config says; an inherited `CDPATH` (set outside the command)
// changes `cd`. Keep such commands off the allowlist rather than relying on the guard to see
// inside them.

/**
 * Compiles the opt-in allowlist. Returns null when the target has not opted in (the default), so
 * the caller can pass through without doing any work. Invalid regex sources are dropped (stricter,
 * never looser).
 * @returns {RegExp[]|null}
 */
export function compileTrunkBashAllowlist(policy) {
  const cfg = policy?.trunk_bash_allowlist;
  if (!cfg || cfg.enabled !== true) return null;
  const out = [];
  for (const src of Array.isArray(cfg.patterns) ? cfg.patterns : []) {
    if (typeof src !== 'string' || !src.trim()) continue;
    try {
      out.push(new RegExp(`^(?:${src})(?=\\s|$)`));
    } catch {
      /* invalid pattern — ignored */
    }
  }
  return out;
}

/** A linked worktree has a `.git` file (or directory) at its root. */
function hasGitEntry(wtRoot) {
  return existsSync(join(wtRoot, '.git'));
}

/**
 * Does `abs` reach the trunk checkout? True inside the project root outside `.worktrees/`, and for
 * any ancestor of the project root (`rm -rf` of a parent removes the trunk too).
 */
function isTrunkPath(abs, projectDir) {
  if (isInside(projectDir, abs)) return true;
  return isInside(abs, projectDir) && !isWorktreeRelPath(relative(projectDir, abs).replace(/\\/g, '/'));
}

/**
 * Symlink-resolved path: the nearest existing ancestor goes through realpath, the not-yet-existing
 * remainder is appended. `.worktrees/x/link -> <trunk>` therefore resolves to the trunk.
 */
export function realPath(abs) {
  let head = abs;
  let tail = '';
  for (;;) {
    try {
      return join(realpathSync(head), tail);
    } catch {
      const parent = dirname(head);
      if (parent === head) return abs;
      tail = join(basename(head), tail);
      head = parent;
    }
  }
}

/** Is this segment worktree work that cannot touch the trunk checkout? (see header) */
export function isWorktreeSegment(seg, projectDir, linked = hasGitEntry) {
  if (!seg.cwdCertain || !seg.effectiveDir || seg.dirs.includes(null)) return false;
  const root = realPath(projectDir);
  const dir = realPath(seg.effectiveDir);
  if (!isInside(dir, root) || !isWorktreeRelPath(relative(root, dir).replace(/\\/g, '/'))) return false;
  const wtRoot = resolveWorktreeRoot(dir);
  if (!wtRoot || !linked(wtRoot) || !existsSync(dir)) return false;
  const { paths, unresolved } = pathArgs(seg.words, seg.cwd, dir);
  return !unresolved && !paths.some((p) => isTrunkPath(realPath(p), root));
}

/** GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE … and CDPATH redirect what a command acts on. */
const LOCATION_ENV_RE = /^(?:GIT_[A-Z_]+|CDPATH)$/;

/**
 * Returns the first simple command of `cmd` that is not allowed on trunk, or null if all are.
 * No git calls — the branch decision is made by the caller. Throws ShellParseError.
 */
export function findDisallowedTrunkSegment(cmd, cwd, projectDir, allowlist, linked = hasGitEntry) {
  for (const seg of walkSegments(cmd, cwd || projectDir)) {
    // Checked before the exemption and before the empty-command skip: a bare `GIT_DIR=x` statement
    // or `env -S '…'` changes or hides what later commands do, wherever it runs.
    if (seg.opaque || seg.assigns.some((n) => LOCATION_ENV_RE.test(n))) return seg.raw;
    if (seg.isCd || seg.words.length === 0) continue;
    if (isWorktreeSegment(seg, projectDir, linked)) continue;
    if (seg.redirect) return seg.raw;
    const text = commandText(seg.words);
    if (!allowlist.some((re) => re.test(text))) return seg.raw;
  }
  return null;
}

/**
 * Current branch of the main checkout, with a budget deliberately tighter than safeExec's 10s
 * default, unlike the commit/merge/shipping guards which were raised to it on 2026-09-01. Two
 * reasons this one keeps a short budget: its PreToolUse Edit|Write group has a 15s ceiling shared
 * with several other hooks (the Bash dispatcher group shares 45s), and a null here fails *closed*
 * (shouldEvaluateTiers(null) === true), so load costs a visible retry, not a silent pass.
 */
function queryBranch(projectDir) {
  return safeGit('branch --show-current', projectDir, { timeout: 2000 });
}

function buildTrunkBashDenyMessage(segment, branch) {
  return (
    `[Worktree Policy] Command not on the trunk allowlist on ${branch}: ${segment.slice(0, 120)}\n\n` +
    `This project opted in to trunk_bash_allowlist: on the trunk branch only listed commands run; ` +
    `development happens in a worktree.\n` +
    `  → Create worktree: make wt.new BR=feature/<task>, then run the command there ` +
    `(cd <worktree> && …, or git -C / make -C <worktree>) without paths that reach back into the trunk checkout.\n` +
    `  → An output redirect into a file (other than /dev/null) is never allowlisted on trunk.\n` +
    `  → Emergency escape hatch: hotfix/* branches are exempt.\n` +
    `Policy SSOT: .claude/config/worktree-policy.json#trunk_bash_allowlist`
  );
}

async function runTrunkBash(data, projectDir) {
  const policy = safeReadJson(join(projectDir, '.claude/config/worktree-policy.json'), null);
  const allowlist = compileTrunkBashAllowlist(policy);
  if (!allowlist) return HookOutput.passthrough(); // not opted in (default)

  const cmd = data?.tool_input?.command;
  if (typeof cmd !== 'string' || !cmd.trim()) return HookOutput.passthrough();

  const branch = queryBranch(projectDir);
  if (!shouldEvaluateTiers(branch, policy)) return HookOutput.passthrough();
  const branchLabel = branch || 'unresolved branch (query failed/timed out — fail-closed; retry)';

  let segment;
  try {
    segment = findDisallowedTrunkSegment(cmd, data?.cwd || projectDir, projectDir, allowlist);
  } catch (err) {
    // Opted in → fail closed: an unparsable command is not evidence of an allowed one.
    return HookOutput.deny(
      `[Worktree Policy] Could not analyse this command on ${branchLabel} (${err?.message || err}), ` +
        `so trunk_bash_allowlist denies it. Simplify the command or run it inside a worktree.`,
    );
  }
  if (segment === null) return HookOutput.passthrough();
  return HookOutput.deny(buildTrunkBashDenyMessage(segment, branchLabel));
}


/**
 * Orchestrator compatible entry point.
 */
export async function run(data) {
  try {
    const toolName = data?.tool_name || '';
    // Bash starts where the command runs (Antigravity toolCall.args.Cwd); the project root does not move.
    if (toolName === 'Bash') return await runTrunkBash(withCommandCwd(data), resolveProjectDir(data));
    if (!['Edit', 'Write', 'MultiEdit', 'apply_patch'].includes(toolName)) {
      return HookOutput.passthrough();
    }

    const projectDir = resolveProjectDir(data);
    const branch = queryBranch(projectDir); // short budget — rationale at queryBranch

    const policy = safeReadJson(
      join(projectDir, '.claude/config/worktree-policy.json'),
      null
    );
    if (!isPolicyUsable(policy)) return HookOutput.passthrough();

    // Non-protected / escape-hatch branches pass; unresolved branch falls through (fail-closed).
    if (!shouldEvaluateTiers(branch, policy)) return HookOutput.passthrough();

    const filePaths = extractFilePaths(toolName, data.tool_input, projectDir);
    if (filePaths.length === 0) return HookOutput.passthrough();

    for (const filePath of filePaths) {
      const relPath = relative(projectDir, filePath).replace(/\\/g, '/');
      // Exempt paths outside project root
      if (relPath.startsWith('..')) continue;
      // .worktrees/ files are worktrees by definition (not main)
      if (isWorktreeRelPath(relPath)) continue;
      const tier = classifyTier(relPath, policy);
      if (tier === 1) continue;
      // tier === 3 (tier 2 has been abolished)
      return HookOutput.deny(
        buildDenyMessage(relPath, branch || 'unresolved (branch query failed/timed out — fail-closed; retry)'),
      );
    }

    return HookOutput.passthrough();
  } catch (_) {
    return HookOutput.passthrough();
  }
}

// Standalone fallback (when called directly via settings.json)
if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMainWithProfile('worktree-policy-guard', async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
