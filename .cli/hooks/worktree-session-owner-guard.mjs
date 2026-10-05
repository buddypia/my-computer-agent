#!/usr/bin/env node

/**
 * worktree-session-owner-guard.mjs - PreToolUse Edit|Write|MultiEdit|Bash Hook
 *
 * In multi-session environments, enforces that an AI session **only edits and commits files
 * within worktrees created by its own session**. If the `.session-owner` sidecar of the worktree
 * where target file/commit belongs mismatches current session (`data.session_id`), denies execution.
 *
 * Policy SSOT: R-CM-036 (worktree-session-ownership.md).
 * Sidecar recording: worktree-owner-tracker.mjs (PostToolUse Bash).
 *
 * 2-Layer Defense (R-CM-036):
 *   Layer 1 — cwd-confinement (deterministic, orphan-proof, session_id agnostic, PRIMARY):
 *     Target worktree ≠ cwd worktree → deny. No sidecar required → no orphan loopholes.
 *     cwd is main repo (outside worktree) while target is worktree → deny.
 *   Layer 2 — ownership **lease** (SECONDARY, defends against another *live* session in the same worktree):
 *     `.session-owner` holds a different session id **and the lease is still fresh** → deny.
 *     An expired lease is adopted here (`claimOwnerLease`) and the edit proceeds.
 *
 * Why Layer 2 is a lease:
 *   The old Layer 2 denied whenever the owner differed and advised "delegate to the session that
 *   created this worktree". Once that session was gone there was nobody to delegate to, and the only
 *   way out was hand-editing the sidecar — the worktree stayed blocked forever. With a lease a live
 *   session is still blocked, and an abandoned worktree frees itself after the TTL.
 *   TTL and renewal rules SSOT: `.cli/lib/worktree-owner-lease.mjs`.
 *
 *   Deleting Layer 2 would be a smaller change, but it would leave the **default setup unguarded**:
 *   Layer 1 only denies when `cwdWt !== null`, so it decides nothing for a session whose cwd is the
 *   main clone root (the usual starting point). In that setup Layer 2 is the only thing standing
 *   between a session and another session's worktree.
 *
 * Behavior:
 *   - tool is not Edit|Write|MultiEdit|Bash → passthrough
 *   - target not under .worktrees/ (main repo file) → passthrough (worktree-policy-guard domain)
 *   - `.tmp/create-pr-active` exists → passthrough (ship/create-pr carve-out)
 *   - Bash is not `git commit` / is `--dry-run` → passthrough (default `session_owner_scope: "commit"`)
 *   - opt-in `session_owner_scope: "all_bash"` (worktree-policy.json): every Bash command is checked
 *     against every worktree it touches (see `bashTargets`):
 *       · where it runs — cwd, each `cd`, cumulative `git -C` / `make -C` → Layer 1 + Layer 2
 *       · path arguments and redirect targets resolving into a worktree (`../other/src`,
 *         `--manifest-path`, absolute paths) → Layer 2 only (a live foreign lease denies; reading
 *         another worktree from your own is not a Layer 1 violation)
 *       · the `git commit` target → exactly as in the `commit` scope
 *     all_bash never claims, renews or adopts a lease for non-commit commands — only the commit /
 *     edit paths (and worktree-owner-tracker) do, so `ls .worktrees/other` from trunk cannot take
 *     over a worktree. A command the scanner cannot parse is denied (fail closed when opted in).
 *   - Bash "where it runs" starts from `commandCwd` when the adapter provides it (Antigravity
 *     `toolCall.args.Cwd`), else `cwd` — shared `withCommandCwd` (lib/utils.mjs)
 *   - Layer 1: cwd worktree ≠ target worktree → **deny**
 *   - Layer 2: same worktree, foreign owner, **fresh lease** → **deny**; expired → adopt + passthrough
 *   - error → passthrough (R-CM-006 Rule 2 fail-open)
 */

import { join, relative, isAbsolute } from 'node:path';
import {
  readStdin,
  output,
  safeHookMainWithProfile,
  resolveProjectDir,
  withCommandCwd,
  canonicalizePath,
} from '../lib/utils.mjs';
import {
  claimOwnerLease,
  formatLeaseRemaining,
  readOwnerLease,
} from '../lib/worktree-owner-lease.mjs';
import { HookOutput } from '../lib/hook-output.mjs';
// Worktree root evaluation SSOT (R-CM-037).
import { resolveWorktreeRoot } from '../lib/worktree-path.mjs';
import { extractApplyPatchFilePaths } from '../lib/apply-patch-paths.mjs';
import { commitTargets } from '../lib/git-commit-target.mjs';
import { pathArgs, walkSegments } from '../lib/bash-segments.mjs';
import { loadWorktreePolicy } from '../lib/trunk-branch.mjs';
// The create-pr carve-out below is a lease with a TTL, not a permanent switch (R-CM-008 Rule 6).
import { isCreatePrLeaseActive } from '../lib/create-pr-lease.mjs';

/**
 * Reads first line (session_id) of worktree's `.session-owner`. Returns null on failure/absence/empty.
 * Thin alias kept for callers that only need the id — freshness lives in `readOwnerLease`.
 */
export function readSessionOwner(worktreeRoot) {
  return readOwnerLease(worktreeRoot).owner;
}

function toAbs(raw, baseDir) {
  if (!raw || typeof raw !== 'string') return null;
  return isAbsolute(raw) ? raw : (baseDir ? join(baseDir, raw) : raw);
}

/**
 * Resolves absolute file path for Edit|Write|MultiEdit target (single).
 */
export function editTargetPath(toolName, toolInput, baseDir) {
  if (toolName === 'apply_patch') {
    const paths = extractApplyPatchFilePaths(toolInput?.command, baseDir);
    return paths.find((p) => resolveWorktreeRoot(p)) || paths[0] || null;
  }
  if (!['Edit', 'Write', 'MultiEdit'].includes(toolName)) return null;
  return toAbs(toolInput?.file_path, baseDir);
}

/** Bash scope from worktree-policy.json: 'commit' (default) or 'all_bash' (opt-in). */
export function sessionOwnerScope(policy) {
  return policy?.session_owner_scope === 'all_bash' ? 'all_bash' : 'commit';
}

/** A target of the commit / edit paths: both layers, and the lease is claimed on pass. */
const OWNING = { layer1: true, claim: true };

/**
 * Every path a Bash command touches, for the opt-in `all_bash` scope (semantics in the header).
 * Unlike an earlier version — which returned the first `cd` / `-C` match — this
 * walks every simple command, so `cd .worktrees/mine && git -C .worktrees/theirs status` reports
 * both worktrees. Throws ShellParseError.
 *
 * @returns {Array<{path: string, layer1: boolean, claim: boolean, action: string}>}
 */
export function bashTargets(cmd, cwd, baseDir) {
  const out = [];
  const add = (path, layer1) => path && out.push({ path, layer1, claim: false, action: 'command' });
  for (const seg of walkSegments(cmd, baseDir)) {
    for (const dir of [seg.cwd, seg.cdTo, ...seg.dirs]) add(dir, true);
    for (const p of pathArgs(seg.words, seg.cwd, seg.effectiveDir).paths) add(p, false);
  }
  out.push(...commitOwnership(cmd, cwd, baseDir));
  return out;
}

/**
 * Every directory the command's commit may land in, as owning targets. An unknown target adds the
 * start directory: that is the worktree a commit the model cannot follow most plausibly lands in.
 */
function commitOwnership(cmd, cwd, baseDir) {
  const start = cwd || baseDir;
  const t = commitTargets(cmd, start);
  if (!t) return [];
  const dirs = t.unknown ? [...t.bases, start] : t.bases;
  return dirs.map((path) => ({ path, ...OWNING, action: 'commit' }));
}

/**
 * Targets of a Bash call under the configured scope. The scope switch costs one small JSON read per
 * Bash call; the default ('commit') then decides exactly as before — a non-commit command has no
 * target and passes through.
 */
function bashCommandTargets(data, projectDir, baseDir) {
  const cmd = data.tool_input?.command;
  if (sessionOwnerScope(loadWorktreePolicy(projectDir)) === 'all_bash') {
    return bashTargets(cmd, data.cwd, baseDir);
  }
  return commitOwnership(cmd, data.cwd, baseDir);
}

function withCanonicalCwd(data) {
  return typeof data?.cwd === 'string' && data.cwd ? { ...data, cwd: canonicalizePath(data.cwd) } : data;
}

/** Groups targets by worktree root; flags are OR-ed (any owning use of a worktree owns it). */
function byWorktree(targets) {
  const map = new Map();
  for (const t of targets) {
    const root = t.path ? resolveWorktreeRoot(canonicalizePath(t.path)) : null;
    if (!root) continue; // main repo files / non-worktree targets are worktree-policy-guard's domain
    const prev = map.get(root);
    map.set(
      root,
      prev
        ? { layer1: prev.layer1 || t.layer1, claim: prev.claim || t.claim, action: prev.claim ? prev.action : t.action }
        : { ...t },
    );
  }
  return map;
}

export async function run(rawData) {
  try {
    const toolName = rawData?.tool_name || '';
    if (!['Edit', 'Write', 'MultiEdit', 'apply_patch', 'Bash'].includes(toolName)) {
      return HookOutput.passthrough();
    }
    // Bash starts where the command runs (commandCwd); the start dir is canonical (`..` folded,
    // symlinks resolved) so `<wt>/../other` is judged as `other`, and matches canonical targets.
    const data = withCanonicalCwd(withCommandCwd(rawData));

    const sessionId = data?.session_id;

    const projectDir = resolveProjectDir(rawData);
    // Ship / create-pr flows legitimately manipulate worktree paths → carve-out
    if (isCreatePrLeaseActive(projectDir)) {
      return HookOutput.passthrough();
    }

    const baseDir = data?.cwd || canonicalizePath(projectDir);
    let targets;
    if (toolName === 'Bash') {
      try {
        targets = bashCommandTargets(data, projectDir, baseDir);
      } catch (err) {
        // Only the opted-in all_bash scope parses the command; fail closed there.
        return HookOutput.deny(
          `[Session Owner Guard] Could not analyse this command (${err?.message || err}), so ` +
            `session_owner_scope "all_bash" denies it. Simplify the command.`,
        );
      }
    } else {
      targets = [{ path: editTargetPath(toolName, data.tool_input, baseDir), ...OWNING, action: 'edit' }];
    }

    for (const [wtRoot, t] of byWorktree(targets)) {
      const denied = checkWorktree(wtRoot, { data, projectDir, sessionId, ...t });
      if (denied) return denied;
    }
    return HookOutput.passthrough();
  } catch {
    return HookOutput.passthrough();
  }
}

/**
 * Layer 1 (when `layer1`) + Layer 2 for one worktree root. Returns a deny output, or null to
 * continue. The lease is claimed on pass only when `claim` (commit / edit targets).
 */
function checkWorktree(wtRoot, { data, projectDir, sessionId, action, layer1, claim }) {
  const relRoot = relative(canonicalizePath(projectDir), wtRoot).replace(/\\/g, '/') || wtRoot;

  // ── Layer 1: cross-worktree confinement (deny only when cwd is *another* worktree) ──
  const cwdWt = resolveWorktreeRoot(data?.cwd || '');
  if (layer1 && cwdWt !== null && cwdWt !== wtRoot) {
    return HookOutput.deny(
      `[Session Owner Guard] Cross-worktree ${action} blocked: ${relRoot}\n\n` +
        `Current cwd is a different worktree (${relative(canonicalizePath(projectDir), cwdWt).replace(/\\/g, '/')}), ` +
        `but target is worktree ${relRoot}.\n` +
        `Each session may only ${action === 'command' ? 'run commands in' : 'edit/commit files in'} its own worktree (R-CM-036 Layer 1).\n` +
        `  → Work in your own worktree, or use the standard shipping flow (/create-pr ship-worktree).`
    );
  }

  // ── Layer 2: ownership lease (defends against another *live* session in the same worktree) ──
  if (!sessionId || typeof sessionId !== 'string') return null;
  const lease = readOwnerLease(wtRoot);
  if (lease.owner && lease.owner !== sessionId && lease.fresh) {
    return HookOutput.deny(liveLeaseDenyMessage(lease, { relRoot, action, sessionId }));
  }
  // Mine, unowned, or expired: renew or adopt, then pass. A takeover is recorded in the sidecar
  // as a `# adopted …` line below line 1.
  if (claim) claimOwnerLease(wtRoot, null, sessionId);
  return null;
}

function liveLeaseDenyMessage(lease, { relRoot, action, sessionId }) {
  // A future mtime (clock moved back, file restored) never expires. Saying "wait and it frees
  // itself" would be false there, so the advice differs.
  const escape = lease.skewed
    ? `  → This lease's recorded time is in the future. The clock is off or the file was restored, ` +
      `so it will not expire by waiting. Check the system time first.`
    : `  → Work in your own worktree. If that session has stopped, the lease expires on its own and ` +
      `this worktree becomes editable here with no manual step — do not hand-edit .session-owner.`;
  return (
    `[Session Owner Guard] Live foreign-session lease on worktree — ${action} blocked: ${relRoot}\n\n` +
    `This worktree is leased by another session (owner=${lease.owner.slice(0, 12)}…), ` +
    `and that lease is still active (${lease.skewed ? 'recorded time is in the future — will not expire' : formatLeaseRemaining(lease.ageMs)}).\n` +
    `The current session (${sessionId.slice(0, 12)}…) may only edit/commit worktrees whose lease it holds (R-CM-036 Layer 2).\n` +
    escape
  );
}

if (!globalThis.__HOOK_ORCHESTRATOR__) {
  safeHookMainWithProfile('worktree-session-owner-guard', async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
