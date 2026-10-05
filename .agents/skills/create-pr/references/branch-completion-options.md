# Branch Completion Options

## Core Principle

Completing a development branch is an integration decision point rather than simply "stopping work." Confirm verification evidence first, then clearly present available completion options to the user.

## Completion Options

| Option | harness Action | Worktree Handling | Safety Rule |
|---|---|---|---|
| **Create PR** | `create-pr ship-worktree` | Auto-cleanup (default), or retain via `--no-cleanup` | Halts if uncommitted changes exist |
| **Local Merge** | High-risk action outside standard flow | Requires manual cleanup after merge | Must not claim completion before main sync and verification check |
| **Keep / Archive** | No automated cleanup performed | Retain worktree as-is | Document paused status and next actions in `PLAN.md` |
| **Discard** | Destructive operation | Deletes worktree and branch | Requires explicit typed user confirmation |

## Before Presenting Options

1. Verify current branch and worktree path.
2. Check `PLAN.md` for any remaining uncompleted checkboxes.
3. Confirm all changes are committed.
4. Review latest verification evidence and test results.
5. Confirm base branch is `main` or specify alternative base.

## Recommended Prompt Shape

Present options aligned with harness automation:

```text
The worktree is verified. Choose an action:

1. Create PR: Push + create PR via create-pr Mode B
2. Keep: Preserve worktree and branch as-is with PLAN.md handoff
3. Discard: Delete worktree/branch after typed confirmation

(If local merge to main is required, request it separately.)
```

## Do Not

- Do NOT present completion options without verifying tests or `PLAN.md`.
- Do NOT perform discard operations implicitly.
- Do NOT clean up using `git reset --hard`, `git clean`, or `git checkout --`.

## Mapping to Existing Automation

| Option | harness Mapping |
|---|---|
| Verify tests | `make q.check`, `npm run validate`, or task proving command |
| Push and create PR | `node .claude/scripts/create-pr/ops.mjs ship-worktree ...` |
| Keep branch as-is | Preserve worktree + `PLAN.md` handoff |
| Discard | Handled under destructive guard rules following typed user confirmation |
