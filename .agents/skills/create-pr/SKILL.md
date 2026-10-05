---
name: create-pr
model: sonnet
effort: low
description: "Worktree-isolated GitHub Flow (8 commands, v2 response contract). Mode A (staged isolation → Feature PR → base branch sync) + Mode B (PLAN.md-based worktree shipping). 100% preservation of unstaged/untracked files via stash backup."
argument-hint: "[additional instructions (optional)]"
---

## `/create-pr` — Worktree-Isolated GitHub Flow

Automates the process of turning parallel AI modifications into Feature PRs and synchronizing them into the configured base branch (`base_branch` in `.claude/skills/create-pr/config.json`, default `main`; "base" below always means this branch). Supports two operating modes, executing autonomously without unnecessary questioning.

### Core Invariants + Prohibitions

**Invariant**: Unstaged and untracked files remain strictly identical before and after execution.
- Mode A Phase 1: Worktree isolation → Original `HEAD` remains unchanged.
- Mode A Phase 2: A dirty base branch checkout is not auto-stashed; synchronization halts (`sync_status: local_changes`). The original working tree is untouched, prompting manual user commit/stash before retrying.

**Worktree Commit Requirement**: Mode B `ship-worktree` will not deploy a dirty worktree.
- Before PR creation / merge, `git status --porcelain --untracked-files=all` must be clean.
- If uncommitted tracked/untracked changes exist, execution fails with `code: "commit_required"`.
- The AI stages/commits only its authored changes before re-running `ship-worktree`.
- If the user explicitly requested WIP retention or prohibited commits, report worktree status and halt instead of running `ship-worktree`.

**Prohibitions**: Modifying original working tree directly · `git reset --hard` · `git checkout .` · `git restore .` · `git clean -f` · `git stash clear` (R-CM-008 Rule 7 — `clear` is blocked; standard `stash` permitted) · `--force` push · Deleting the base branch · Automated conflict resolution without human inspection.

### v2 Response Contract (Common Across All Commands)

```jsonc
{
  "ok": true | false,
  "mode": "staged" | "worktree" | null,    // AI branch indicator
  "command": "init" | "verify-plan" ...,
  "sync_status"?: "synced" | "fetch_failed" | "local_changes" | "ff_failed",
  "changed_files"?: ["a.md", "b/c.mjs"],   // Returned upon successful ship-feature / ship-worktree merge
  "changed_files_tree"?: "└── ...",         // Human-readable markdown box-drawing tree
  "completion_report_markdown"?: "# Post-Approval Completion Report\n...", // User report template after ship-worktree
  "warnings"?: ["..."],
  "error"?: "...",     // When ok: false
  "hint"?: "..."       // Recovery guidance when ok: false
}
```

**Fail-Loud Semantics** (Aligned with R-CM-010): Failures in `finalize` or `cleanup-worktree` (fetch, local_changes, ff failure) return `ok: false` + `sync_status`. They are never treated as silent warnings. A dirty base branch checkout halts with `sync_status: local_changes` without modifying the working tree.

**Post-Merge Tree Reporting Obligation (`changed_files_tree`)**: When `ship-feature` or `ship-worktree` returns `merged: true`, it includes `changed_files` (path array) and `changed_files_tree` (markdown box-drawing tree). The AI must print the `changed_files_tree` directly to the user.

**Approval Source + Escape Warnings (Perspective 1)**: The approval before `ship-worktree` is a human's for T2 one-way doors and automatic for independently reviewed T0/T1 diffs (R-CM-030 Rule 13.1); the ledger records which. An `approval escape(s) detected` entry in `warnings[]` means an earlier auto-approved ship needed a fix — relay it verbatim: those areas stay on human approval until a prevention guard is registered.

**Post-Approval Completion Report Obligation (`completion_report_markdown`)**: `ship-worktree` includes `completion_report_markdown` after PR/cleanup. The AI must present this report to the user upon shipping after approval, detailing PR URL, merge commit, CI status, cleanup details, and remaining action items. Its headings and field labels (and the pre-ship panel's sections, approval choices and line budget) can be localized per project in `.claude/config/pre-ship-review-panel-sections.json`; without that file they are the built-in English.

### ops.mjs Usage

```
node .claude/scripts/create-pr/ops.mjs <command> [--key value ...]
```

Configuration: `.claude/skills/create-pr/config.json` — `github_account`, `base_branch` (the PR base and sync target; default `main`), `enforce_ssh_remote` (default false), `superset_check_local_branches` (default true; `false` drops the unpushed-local-branch superset warning at ship time), `milestone_waiver_short_reason` (`warn` | `block`, default `warn` — whether a too-short `cp-milestone-deck` waiver reason blocks the pre-ship step runner). `ops.mjs` automatically injects `GH_TOKEN` via `gh auth token -u`.

| Command | Mode | Arguments | Role |
|---|---|---|---|
| `init` | staged | — | Verifies base branch + concurrency lock (30min mtime) + CI Mirror Gate (60min stamp) + extracts staged diff + blocks secrets + checks gh auth |
| `isolate` | staged | `--branch <b>` | Creates worktree + feature branch + applies staged diff via `apply --index` |
| `commit` | staged | `--message <m> [--files <f1,f2>]` | Commits changes inside worktree |
| `ship-feature` | staged | `--title <t> [--body <b> \| --body-file <p>] [--no-merge]` | Push → Idempotent PR → Squash merge → Delete remote branch |
| `finalize` | staged | — | Removes worktree + synchronizes the original base branch checkout (aborts if dirty, fail-loud) |
| `verify-plan` | worktree | `--worktree <p> [--force]` | Validates uncompleted PLAN.md checkboxes (strips code blocks/HTML comments, recognizes cancelled markers) |
| `ship-worktree` | worktree | `--worktree <p> --title <t> [--body <b> \| --body-file <p>] [--force-plan] [--no-merge] [--no-cleanup]` | Validates PLAN.md + validates committed/clean worktree + push + idempotent PR + auto full cleanup (default: delegates to cleanup-worktree) |
| `cleanup-worktree` | worktree | `--worktree <p>` | Removes worktree + deletes branch + drops auto-checkpoint stash + cleans CONTEXT.json + syncs the base branch (fail-loud) |

### AI Execution Sequence — Mode A (Staged Isolation)

If any command returns `ok: false`, halt immediately, report the error, and invoke `finalize`.

```bash
OPS="node .claude/scripts/create-pr/ops.mjs"

$OPS init                                             # Step 1
$OPS isolate --branch "$BRANCH"                       # Step 2 (AI determines BRANCH name)
$OPS commit --message "$MSG"                          # Step 3 (use --files multiple times if needed)
$OPS ship-feature --title "$FT" --body "$FB"          # Step 4 (waits up to 5 mins for CI completion)
$OPS finalize                                         # Step 5
# → If finalize returns sync_status !== 'synced', follow recovery guidance
#   (local_changes: dirty base branch checkout → manually commit/stash and retry)
```

### AI Execution Sequence — Mode B (Worktree)

Used when shipping and cleaning up features developed inside `.worktrees/<branch>`. Validates `PLAN.md` checkboxes before proceeding.

> **Handling Cancelled PLAN.md Items**: Unchecked boxes (`- [ ]`) marked with `(cancelled)`, `(dropped)`, or `~~strikethrough~~` are ignored and passed. Checklists inside code blocks (```` ``` ````) and HTML comments (`<!-- -->`) are automatically stripped to eliminate false positives. Bypassed via `--force` / `--force-plan`.

```bash
OPS="node .claude/scripts/create-pr/ops.mjs"
WT_PATH=".worktrees/feature/add-login"

# 1. Validate PLAN.md (optional; auto-validated within ship-worktree)
$OPS verify-plan --worktree "$WT_PATH"

# 2. Quality check and commit (mandatory: uncommitted changes trigger commit_required error)
# cd $WT_PATH && $QUALITY_GATE_CMD && git add . && git commit -m "..." && cd -

# 3. Push and create PR (squash merge; reuses existing PR idempotently)
# Default: On merge success, delegates to cleanup-worktree to remove worktree/branch,
# drop auto-checkpoint stashes, clean CONTEXT.json, and sync the base branch.
$OPS ship-worktree --worktree "$WT_PATH" --title "$FT" --body "$FB"

# 4. (Only required if shipped with --no-cleanup) Cleanup worktree, branch, stash, and sync the base branch
$OPS cleanup-worktree --worktree "$WT_PATH"
```

AI Decision Scope: BRANCH name (Conventional Commits, ≤30 characters), commit messages, PR title/body, evaluating cancelled PLAN.md items.

## Hook Integration (commit-guard / destructive-git-guard)

Flags in `.tmp/create-pr-active` (30-minute mtime freshness) automatically grant temporary exceptions for two guards:
- **commit-guard**: Blocks manual `git commit` / branch creations outside `/create-pr` → Allowed while active flag is fresh.
- **destructive-git-guard**: Allows `git merge --ff-only` and `git worktree remove` exclusively (all other destructive commands remain blocked).
- Flag is automatically removed upon completion of `finalize` / `cleanup-worktree`.

**Concurrency Lock**: `init` rejects execution if an active flag exists within 30 seconds, preventing multi-session collisions and state corruption.

## Branch Completion Options

When work on a worktree is complete and deciding whether to create a PR, keep, or discard the branch, refer to `.claude/skills/create-pr/references/branch-completion-options.md`.

## Merge Conflict Resolution

If conflicts occur during base branch synchronization or worktree reconciliation, refer to `.claude/skills/create-pr/references/merge-conflict-resolution.md` for the 5-step non-aborting protocol.

## Not For / Boundaries

| Scenario | Handling |
|---|---|
| Executing `init` on a feature branch | Error (base branch checkout required) |
| Local base is **ahead** of `origin/<base>` | Error (auto-pushing unverified commits is prohibited) |
| Local base is **behind** `origin/<base>` | Warning; `finalize` synchronizes via fast-forward merge |
| `gh` CLI unauthenticated | Error |
| `git fetch` failure (offline) | Warning; flow continues |
| Incomplete PLAN.md on ship-worktree | Error (bypass via `--force-plan` or cancellation markers) |
| Uncommitted changes in worktree on ship-worktree | Error (`code: "commit_required"`; stage/commit own changes first) |
| Flag not listed in the command's Arguments column | Error (`code: "unknown_flag"`, before any push/merge). Flags used to be discarded silently — `--body-file` shipped empty PR bodies that way |
| `--body` and `--body-file` both passed | Error (mutually exclusive) |
| Re-running PR creation | Idempotent (reuses open PR + updates title/body) |
| BLOCKED / BEHIND mergeStateStatus | Returns `pending: true` (graceful non-error) |
| Concurrent create-pr session active | `init` rejected (30min mtime lock) |

## Pre-flight Checklist

| ID | Item | Required | Owner |
|---|---|:---:|---|
| PF-001 | init: base branch freshness + staged changes + secret check + gh auth + concurrency lock | ✅ | ops.mjs |
| PF-002 | init: CI Mirror Gate (make q.ci-mirror, 60min stamp) | ✅ | ops.mjs |
| PF-003 | ship-worktree: PLAN.md validation + clean worktree check (`commit_required`) | ✅ | ops.mjs |

## Post-flight Checklist

| ID | Item | Required |
|---|---|:---:|
| POF-001 | ship-feature completed (`merged === true` or graceful `pending === true`) | ✅ |
| POF-002 | finalize completed (`sync_status === 'synced'` or intended fail-loud response) | ✅ |
| POF-003 | cleanup-worktree completed (`sync_status === 'synced'` or intended fail-loud response) | ✅ |

## Maintenance

- **Boundary (R-CM-028)**: Boundary-uniform — applies identically across Perspective 1 (harness repo modifications) and Perspective 2 (scaffolded target projects).
- **Sources**: R-CM-008 (git-workflow), R-CM-010 (verification-before-completion), R-CM-028 (two-perspective-boundary), `git-worktree(1)`, GitHub REST `PUT /repos/{owner}/{repo}/pulls/{n}/merge`.
- **Scripts**: `.claude/scripts/create-pr/ops.mjs`
- **Hooks**: `.cli/hooks/commit-guard.mjs`, `.cli/hooks/destructive-git-guard.mjs`
- **Tests**: `tests/unit/create-pr-ops.test.mjs`, `tests/unit/create-pr-spec.test.mjs`
- **Last updated**: 2026-09-23
