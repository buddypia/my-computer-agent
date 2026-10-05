/**
 * worktree-owner-lease.mjs — SSOT for treating the worktree ownership sidecar as an **expiring lease**.
 *
 * Two words used in this file:
 *   lease     — like a library loan card. It marks who is using a worktree, and it has a due date.
 *               Before the due date nobody else may use it; after it, the next session takes it over.
 *   heartbeat — the signal that the holder is still working. Every edit, commit, or Bash call in the
 *               worktree pushes the due date out. When the holder walks away the signal stops and the
 *               lease runs out.
 *
 * Why a lease (measured in practice):
 *   `worktree-session-owner-guard` Layer 2 used to deny whenever the owner id differed, advising
 *   "delegate to the session that created this worktree". When that session no longer existed there
 *   was nobody to delegate to, and the harness had **no takeover procedure** — the only way out was
 *   hand-editing line 1 of the sidecar.
 *
 *   The sidecar mtime could not serve as a liveness signal either: `worktree-owner-tracker` wrote the
 *   sidecar only on worktree **creation** commands, so the mtime was frozen at creation time.
 *
 *   So the sidecar becomes a lease with a heartbeat. `claimOwnerLease` rewrites the file (bumping its
 *   mtime) whenever the owning session touches the worktree. While the lease is fresh, foreign edits
 *   are still denied; once it expires, the next session adopts it automatically. No new command and
 *   no new doc — a design that relies on a human remembering a takeover procedure is what failed.
 *
 * Who may do what (two entry points, deliberately different):
 *   1. `claimOwnerLease` — renew **or adopt**. Called only where a session commits to working in the
 *      worktree: `worktree-session-owner-guard` (the **target** worktree of Edit/Write/MultiEdit/
 *      apply_patch and `git commit`) and the tracker's worktree-creation path.
 *   2. `renewOwnerLease` — renew **only a lease this session already holds**. Called by
 *      `worktree-owner-tracker` on every successful Bash call whose `commitDir` (`git -C <path>`
 *      first, then the session cwd) is inside a worktree. A read-only `git -C <other-worktree> log`
 *      must never adopt someone else's expired lease: the tracker has no Layer 1 cwd check, so an
 *      adopting heartbeat let a passing reader lock the real owner out for a full TTL.
 *   Without the Bash heartbeat, a live owner doing builds, gates, deploys, or waiting on human review
 *   for longer than the TTL lost its own worktree (reproduced by an adversarial review).
 *
 *   Remaining gaps:
 *   - A session whose cwd is the main clone root and that works for longer than the TTL using only
 *     Bash without `git -C`. The moment it uses an edit tool, (1) renews the lease.
 *   - Antigravity has **no Bash heartbeat**: its PostToolUse payload carries no `toolCall`, so the
 *     tracker cannot see the command or its directory (`.cli/docs/MULTI-CLI.md`, PostToolUse
 *     limitation). There, only edits and commits (PreToolUse guard) refresh the lease.
 *
 * Never creates a worktree: writes are skipped when the worktree root does not exist, so a heartbeat
 *   or claim racing `git worktree remove` cannot resurrect `.worktrees/<branch>/.tmp/...` and make a
 *   later `git worktree add` at that path fail. Only the `.tmp/worktree-<key>/` mailbox under an
 *   existing worktree is created.
 *
 * Mailbox key: every caller passes `branch = null`, so the sidecar path is always derived from the
 *   worktree path (`inferBranchFromWorktreePath`). Passing the real branch on one side only splits
 *   the sidecar in two for branches with more than two segments (`feature/a/b`).
 *
 * File format (only line 1 is the contract):
 *   line 1  : owning session id
 *   line 2+ : `#`-prefixed takeover audit lines (newest last, at most MAX_AUDIT_LINES)
 *   Readers have always read line 1 only, so the old single-line format stays valid as-is and the
 *   appended audit lines do not break older readers.
 *
 * Boundary: every error here is swallowed (R-CM-006 Rule 2). An unreadable lease reads as "no
 *   owner"; an unwritable one is retried on the next event. A full disk or a permission problem must
 *   never make the guard stop human work.
 */

import { existsSync, readFileSync, statSync } from 'node:fs';
import { atomicWriteJson } from './utils.mjs';
import { worktreeOwnerPath } from './worktree-plan-path.mjs';

/**
 * Lease lifetime. If the owning session does not touch the worktree for this long, the next session
 * takes it over.
 *
 * Why 2 hours: an active agent session edits, commits, and runs commands many times an hour, so two
 * idle hours effectively means "walked away from this worktree". Longer would stretch the original
 * failure (blocked by a dead owner) by the same amount. The cost of erring short is limited to a
 * human **deliberately** running a second session in the same worktree, and even then the session
 * that comes back late learns about it from the deny message.
 */
export const OWNER_LEASE_TTL_MS = 2 * 60 * 60 * 1000;

/** Upper bound on takeover audit lines kept in the sidecar (oldest dropped first). */
const MAX_AUDIT_LINES = 5;

/**
 * Reads the lease. A missing or unreadable file reads as "no owner".
 *
 * The recorded time can be in the **future** — the clock was moved back, or the file was restored
 * from a backup. The elapsed time is then negative; it is clamped to 0, which makes the lease look
 * just renewed, so it **never expires** — the very state the lease was meant to fix. Blocking is
 * still safer than declaring it expired and taking a worktree someone is using, so the verdict stays
 * and `skewed` only exposes the fact. That keeps the deny message from promising "it frees itself".
 *
 * @param {string} worktreeRoot absolute worktree path
 * @param {string|null} [branch] inferred from the path when omitted
 * @returns {{ owner: string|null, audit: string[], ageMs: number|null, fresh: boolean, skewed: boolean, path: string }}
 */
export function readOwnerLease(worktreeRoot, branch = null) {
  const path = worktreeOwnerPath(worktreeRoot, branch);
  const empty = { owner: null, audit: [], ageMs: null, fresh: false, skewed: false, path };
  try {
    if (!existsSync(path)) return empty;
    const lines = String(readFileSync(path, 'utf-8')).split('\n');
    const owner = (lines[0] || '').trim() || null;
    if (!owner) return empty;
    const audit = lines
      .slice(1)
      .map((l) => l.trim())
      .filter((l) => l.startsWith('#'));
    const rawAgeMs = Date.now() - statSync(path).mtimeMs;
    const ageMs = Math.max(0, rawAgeMs);
    return {
      owner,
      audit,
      ageMs,
      fresh: ageMs < OWNER_LEASE_TTL_MS,
      // One minute of slack: some filesystems record whole-second timestamps, so a file written a
      // moment ago can read as slightly in the future. Only a real clock shift is worth flagging.
      skewed: rawAgeMs < -60_000,
      path,
    };
  } catch {
    return empty;
  }
}

/** Human-readable remaining lease time. Empty string when `ageMs` is not a number. */
export function formatLeaseRemaining(ageMs) {
  if (!Number.isFinite(ageMs)) return '';
  const remainMs = OWNER_LEASE_TTL_MS - ageMs;
  if (remainMs <= 0) return 'already expired';
  const mins = Math.ceil(remainMs / 60000);
  return mins >= 60
    ? `expires in about ${Math.floor(mins / 60)}h ${mins % 60}m`
    : `expires in about ${mins}m`;
}

/**
 * Writes the lease file.
 *
 * Instead of truncating the file and writing it again, the whole content goes to a temp file which
 * is then renamed over the target (`atomicWriteJson` — despite the name it is an atomic file write
 * and passes string content through unchanged). Truncate-then-write has a short "erased but not yet
 * written" moment; a session reading right then sees **no owner** and takes a live lease. A rename
 * has no such intermediate state: a reader always sees either the old owner or the new one.
 */
function writeLease(worktreeRoot, path, sessionId, audit) {
  if (!worktreeRoot || !existsSync(worktreeRoot)) return false;
  return atomicWriteJson(path, [sessionId, ...audit.slice(-MAX_AUDIT_LINES)].join('\n') + '\n');
}

/**
 * Renews the lease, or adopts an expired one.
 *
 * Writes in exactly three cases: there is no owner, I am the owner, or the lease has expired.
 * **A fresh foreign lease is never taken.** Without that guarantee Layer 2 means nothing.
 *
 * Two sessions claiming at once:
 *   This function (1) reads the owner file, (2) decides whether it is empty or expired, and (3) writes
 *   my id. If another session runs (1)(2)(3) inside the gap between my (1) and (3), **both believe they
 *   own it and pass**; the file keeps whichever wrote last. The loser is denied from its next edit on —
 *   not once, but **for as long as the winner keeps working there** (each winner edit renews the lease).
 *
 *   An exclusive create ("only create if absent") would let the OS pick one winner. It is not used
 *   because the gap is milliseconds wide, hitting it requires a human to **deliberately** run two
 *   sessions in one worktree, and the cost is the loser seeing a deny message. Add it if that deny is
 *   ever actually observed.
 *
 * @returns {{ written: boolean, adopted: boolean, previousOwner: string|null }}
 */
export function claimOwnerLease(worktreeRoot, branch, sessionId) {
  const idle = { written: false, adopted: false, previousOwner: null };
  if (!sessionId || typeof sessionId !== 'string') return idle;

  const lease = readOwnerLease(worktreeRoot, branch);
  const mine = lease.owner === sessionId;
  if (lease.owner && !mine && lease.fresh) return { ...idle, previousOwner: lease.owner };

  const adopted = Boolean(lease.owner) && !mine;
  const audit = adopted
    ? [
        ...lease.audit,
        `# adopted ${new Date().toISOString()} from ${lease.owner} ` +
          `(lease expired after ${Math.round((lease.ageMs ?? 0) / 60000)}m idle)`,
      ]
    : lease.audit;
  const written = writeLease(worktreeRoot, lease.path, sessionId, audit);
  return { written, adopted: written && adopted, previousOwner: lease.owner };
}

/**
 * Heartbeat only: refreshes the lease when this session already holds it (fresh or expired — an
 * expired lease nobody else took is still mine). Never creates a lease and never adopts a foreign
 * one; that is reserved for `claimOwnerLease` on edit/commit/creation paths.
 *
 * @returns {boolean} whether the lease was rewritten
 */
export function renewOwnerLease(worktreeRoot, branch, sessionId) {
  if (!sessionId || typeof sessionId !== 'string') return false;
  const lease = readOwnerLease(worktreeRoot, branch);
  if (lease.owner !== sessionId) return false;
  return writeLease(worktreeRoot, lease.path, sessionId, lease.audit);
}
