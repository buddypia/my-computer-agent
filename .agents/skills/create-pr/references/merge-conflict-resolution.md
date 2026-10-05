# Merge Conflict Resolution (5-Step Protocol)

## When to Use

When conflicts occur during `create-pr` synchronization with `main` or when reconciling multiple concurrent worktrees. Specifically applies when `R-CM-008 Rule 9` (Multi-worktree superset detection) flags overlapping modified files in `warnings[]` and the user proceeds with reconciliation.

## 5-Step Protocol

### 1. Understand Current State

```bash
git status
git diff --name-only --diff-filter=U   # List conflicted files
git log --oneline --graph -10          # Inspect recent history
```

Confirm whether a merge or rebase is already in progress, and identify the source and target branches.

### 2. Investigate Original Intent for Each Conflict Hunk

**Do NOT guess.** Inspect the commit history to understand *why* each side made its changes:

```bash
git log -p --follow -- <conflicted-file>       # History of the file
git log <ours-branch>..<theirs-branch> --oneline -- <conflicted-file>
git show <commit-sha>                          # Specific commit diff + message
gh pr view <number> --json body,commits         # PR context if available
```

If both changes modified the same lines for different reasons, determine which reflects the updated requirements based on commit messages and PR discussions.

### 3. Resolve Each Hunk — Preserve Both Intents

- **Preserve both intents** whenever possible (integrate rather than making a mechanical either/or choice).
- If mutually exclusive, select the approach that aligns with the stated goal (e.g., modernizing `main`, adopting a specific feature) and **document the trade-off in the commit message or PR comment**.
- **Never invent new behavior** — do not introduce arbitrary third-party logic unrelated to the original changes.
- **Always resolve; never flee** — do not evade the conflict via `git merge --abort`. Aborting forces future merges to re-analyze the same conflicts from scratch.

### 4. Execute Automated Verification Checks

Discover and run the project's automated verification suite (typically typecheck → test → format). Refer first to `project-config.json#commands` (R-CM-009 SSOT) or detect `Makefile` targets dynamically.

```bash
# If project-config.json exists:
# Run commands.typecheck / commands.test / commands.format_check in sequence
```

Ensure the resolution not only clears conflict markers but also avoids breaking existing test suites.

### 5. Complete Merge

```bash
git add <resolved-files>
git commit    # If completing a merge
```

## harness Caveat: `git rebase --continue` Cannot Be Executed by AI

`destructive-git-guard` blocks all commands starting with `git rebase` (`.cli/hooks/destructive-git-guard.mjs`). If a conflict occurs during a rebase, the AI can perform hunk resolutions (Steps 2–4), but **`git rebase --continue` must be executed manually by the user**. Since harness uses standard GitHub Flow (squash merges, R-CM-008 Rule 4), conflicts almost always arise in `git merge` contexts, which the AI can execute directly.

## Multi-worktree Reconciliation Context (R-CM-034 / R-CM-008 Rule 9)

When `detectExternalSupersetRisk()` detects overlapping files modified in origin/main within the last 24h, it adds a warning to `warnings[]` without blocking. If the user decides to reconcile:

1. `git fetch origin` to retrieve latest origin/main.
2. `git merge origin/main` into the current worktree branch — apply this 5-step protocol if conflicts occur.
3. **Do NOT use `git reset --hard`, `git checkout .`, or `git clean -f` to clear conflicts** — these are blocked by `destructive-git-guard` and violate the core principle of intent preservation.
4. After resolution, re-run `Pre-Ship Quality Gate` to confirm verification checks pass.

## Do Not (Prohibited Actions)

- Do NOT evade conflicts via `git merge --abort`.
- Do NOT suggest `git reset --hard`, `git checkout .`, `git clean -f/-d`, `git push --force`, or `git rebase` as solutions (all blocked by guards).
- Do NOT mechanically pick one side without investigating the underlying intent.

## Sources

- `.cli/hooks/destructive-git-guard.mjs`
- harness's common rules this protocol derives from: git-workflow (R-CM-008 Rule 3/4/5/9), worktree-workflow (R-CM-034), command-portability (R-CM-009). They live in harness and are not transplanted, so they are named by rule id rather than by path.
