#!/usr/bin/env node

/**
 * commit-guard.mjs - PreToolUse Bash Hook
 *
 * Protects AI git commit / branch creation / amend operations from direct main work.
 *
 * Jurisdiction: Governs only commands targeting this project's repository.
 * If the effective target of a command is an external repository, no blocking is performed (isForeignRepoTarget).
 *
 * Policy (protecting multi-terminal concurrent work environments — within jurisdiction only):
 *   - Direct commit on main   → Blocked (commits permitted only inside worktrees)
 *   - Opt-in `enforce_worktree_all_branches: true` (worktree-policy.json) → the same block on every
 *     branch of the non-worktree checkout (git-flow develop / release/*)
 *   - git commit --amend     → Always blocked (push conflicts + multi-terminal history rewrite risks)
 *   - Branch creation        → Always blocked (enforces using worktree add)
 *   - Worktree commit        → Permitted
 *   - git commit --dry-run   → Permitted (for verification)
 *   - Commit changing a locked regression test → Blocked (R-CM-002 Rule 10; lock = tests added by the
 *     fix/hotfix branch's own commits + manual ledger − recorded releases; `.cli/lib/test-lock.mjs`).
 *     The edit-time guard can be bypassed with shell edits — the commit cannot.
 *
 * Exceptions:
 *   - Permitted commit + branch creation when .tmp/create-pr-active file exists (amend remains always blocked)
 *
 * Block targets:
 *   - git commit (on main branch)
 *   - git commit --amend (across all branches)
 *   - git checkout -b/-B (new branch creation)
 *   - git switch -c / -C / --create / --force-create (new branch creation)
 *   - git branch <name> (new branch creation)
 *
 * Permitted exceptions:
 *   - git commit --dry-run (verification only, not actual commit)
 *   - git commit (on worktree branches)
 *   - cd <worktree> && git commit / git -C <worktree> commit (effective target is under .worktrees/)
 *   - git checkout <existing-branch> (branch switching, not creation)
 *   - git switch <existing-branch> (branch switching, not creation)
 *   - git branch --list / -a / -v / --show-current / -d / -D (query/deletion)
 *
 * Design (testability):
 *   - isGitCommit / isGitAmend / isGitBranchCreate: Pure functions inspecting command strings only
 *   - isWorktreeCommit: commit target (string) → realpath + git linked-worktree check (gitFn injectable)
 *   - decide({ command, branch, isCreatePrActive, isWorktree }): Pure function, policy decision SSOT
 *   - run(data): Performs I/O (branch detection, state file check), then invokes decide()
 */

import {
  readStdin,
  output,
  resolveProjectDir,
  safeHookMainWithProfile,
  safeGit,
  isDirectInvocation,
  withCommandCwd,
} from '../lib/utils.mjs';
import { HookOutput } from '../lib/hook-output.mjs';
import { anchoredPattern, stripGitGlobalOptions, joinLineContinuations } from '../lib/hook-anchors.mjs';
import { stripHeredocData } from '../lib/heredoc-strip.mjs';
// Worktree evaluation via common SSOT (R-CM-037): every directory the commit may land in (commitTargets)
// is checked against .worktrees/ via resolveWorktreeRoot (independent of session cwd/ENV).
import { commitTargets, everyCommitTarget, parenHashes, stripQuoted } from '../lib/git-commit-target.mjs';
import { resolveWorktreeRoot } from '../lib/worktree-path.mjs';
// Trunk (protected) branch evaluation via .cli/lib/trunk-branch.mjs SSOT — hardcoding 'main' previously disabled
// this guard silently in transplant targets where default branch is master (empirical reproduction 2026-08-01).
import {
  loadWorktreePolicy,
  requiresWorktree,
  trunkBranches as resolveTrunkBranches,
} from '../lib/trunk-branch.mjs';
// `.tmp/create-pr-active` is a time-boxed lease, not a permanent switch — reading it as mere
// existence left this guard disabled for three days after a killed /create-pr leaked the file
// (empirical reproduction 2026-08-23). Resolution SSOT: .cli/lib/create-pr-lease.mjs.
import { isCreatePrLeaseActive } from '../lib/create-pr-lease.mjs';
import { evaluateCommitTestLock, formatCommitLockDenial } from '../lib/test-lock.mjs';
// The string checks below cannot read eval / alias / merge / cherry-pick landings; the git-level
// reference-transaction guard can, but git hooks do not travel with a clone — this guard re-installs it.
import { ensureTrunkRefGuardInstalled } from '../lib/trunk-ref-guard.mjs';
import { existsSync, realpathSync } from 'fs';
import { join, resolve, sep } from 'path';

const PROJECT_DIR = resolveProjectDir();

// --- Pattern constants ---
// Anchors (matching only at command start / chain operator / immediate newline) via hook-anchors.mjs SSOT.
// Simple word boundaries `\b` previously triggered false positives on "git commit" strings inside diagnostic code/heredocs/grep/echo.
const GIT_COMMIT_PATTERN = anchoredPattern('git\\s+commit\\b', 'i');
const GIT_AMEND_PATTERN = anchoredPattern('git\\s+commit\\b.*\\B--amend\\b', 'i');
const GIT_CHECKOUT_NEWBRANCH_PATTERN = anchoredPattern('git\\s+checkout\\s+(-b|-B|--orphan)\\b');
const GIT_SWITCH_CREATE_PATTERN = anchoredPattern(
  'git\\s+switch\\s+.*(-c|--create|-C|--force-create)\\b',
  'i',
);
const GIT_BRANCH_PATTERN = anchoredPattern('git\\s+branch\\b', 'i');

// Patterns above require adjacency between `git` and subcommands, so stripGitGlobalOptions removes global options first.
// Rationale: R-CM-008 Rule 6 recommends `git -C <worktree-path>` to AI (avoiding chained `cd && git commit` blocking pitfalls).

/**
 * Reduces a raw command to the text that is actually *invocation surface*.
 *
 * Order matters and heredoc must come first: `stripHeredocData` needs the raw `<<'EOF'` opener to
 * find its delimiter, and `stripQuoted` would consume the quotes around it. Continuations are
 * folded next, before any pattern or split runs: `git \\<newline> commit -m x` is one `git commit`
 * to the shell, and until this fix the hook read it as a `git` with no subcommand and let a direct
 * trunk commit through unguarded (measured 2026-09-18). A heredoc body fed to a shell
 * (`bash <<'EOF'`) is a program, so `stripHeredocData` returns it for inspection.
 *
 * **Why heredoc stripping belongs here (empirical reproduction 2026-08-27)**: `hook-anchors.mjs`
 * states heredoc bodies are stripped by consumers, and `destructive-git-guard` /
 * `pre-ship-review-guard` do so — this hook was the one anchored consumer that never did, and both
 * failure directions were reachable through an ordinary `-F-` heredoc commit message:
 *   - **bypass**: the unanchored `--dry-run` test read the message body, so a body mentioning
 *     `--dry-run` made `isGitCommit` false and a direct trunk commit passed unguarded.
 *   - **false deny**: a body line *beginning* with `git commit --amend` / `git branch x` matched the
 *     newline arm of `CMD_ANCHOR_SRC` and denied a legitimate worktree commit.
 * `stripQuoted` alone could not cover either: a heredoc body carries no quotes.
 *
 * @param {string} command
 * @returns {string}
 */
function inspectableCommand(command) {
  return stripGitGlobalOptions(stripQuoted(joinLineContinuations(stripHeredocData(command))));
}

/**
 * Can an unsettled `)#` (git-commit-target#hasParenHash) hide a git operation? A misread either
 * drops the tail as a comment or keeps it as data, so the detectors run once more on a view where
 * every such `#` is data — the tail kept whole. That view alone cannot vouch for a tail holding a
 * quote, escape, backtick or redirection: as data it can swallow the *next* lines (an unpaired `'`,
 * a `<<EOF`) that the comment reading leaves live, so those deny as well. Denying every `)#` blocked
 * `echo $(date)# note` (review round 11).
 *
 * @param {string} command heredoc data already stripped
 * @returns {boolean}
 */
function parenHashMayHide(command) {
  const hashes = parenHashes(command);
  if (hashes.length === 0) return false;
  const tailAt = (at) => command.slice(at, command.indexOf('\n', at) + 1 || command.length);
  if (hashes.some((at) => /['"`\\<]/.test(tailAt(at)))) return true;
  const asData = hashes.reduceRight((cmd, at) => `${cmd.slice(0, at)}_${cmd.slice(at)}`, command);
  return isGitCommit(asData) || isGitAmend(asData) || isGitBranchCreate(asData);
}

/**
 * Detects git commit commands. Treats amend as commit as well (distinguished via isGitAmend).
 *
 * @param {string} command
 * @returns {boolean}
 */
export function isGitCommit(command) {
  if (!command || typeof command !== 'string') return false;
  // Normalise first — inspecting the raw command let *data* act as command surface in both
  // directions: a message merely containing "--dry-run" opened the trunk/amend gate (bypass), and a
  // message containing "; git commit" false-matched the anchored pattern (observed 2026-08-26).
  const inspectable = inspectableCommand(command);
  if (!GIT_COMMIT_PATTERN.test(inspectable)) {
    // No literal `git commit`, yet the shell may build one: `$(echo git) commit`, `env $(…) git
    // commit`, `S=com; git ${S}mit`, `gi""t com""mit` passed on main unguarded (2026-09-27/28). The
    // statement model names those. No word test in front of it: the shell joins *both* words out of
    // quotes and variables (`$A$B $C$D`), and the model costs ~10µs on an ordinary command.
    // What it can still skip: the model only ever names a commit through a command word that spells
    // `git` once quotes and escapes fall away, or through a `$` / backtick expansion. Text with
    // neither cannot commit, and on a 40k-line script the model alone took ~130ms against main's
    // 5ms — past its 500ms budget under a loaded test run (round 11).
    const bare = joinLineContinuations(command).replace(/["'\\]/g, '');
    if (!/git|[$`]/i.test(bare)) return false;
    return commitTargets(command, null) !== null;
  }
  // `git commit --dry-run` is verification, not a commit — but the exemption belongs to *that*
  // invocation only. Testing the whole string let a `--dry-run` on an unrelated chained command
  // exempt a real commit beside it: `git add . && git commit -m "x" && git push --dry-run` on trunk
  // returned false here, so `run()` took its fast path and the trunk commit went unguarded
  // (reproduced 2026-08-27). A real commit is one whose own segment carries no --dry-run.
  return inspectable
    .split(/[\n;&|]+/)
    .some((seg) => GIT_COMMIT_PATTERN.test(seg.trim()) && !/--dry-run\b/i.test(seg));
}

/**
 * Detects git commit --amend.
 *
 * amend introduces risks in multi-terminal environments:
 *   - Amending already pushed commits forces force-pushes (violates R-CM-008 Rule 3)
 *   - Causes conflicts when another worktree attempts to push to the same branch
 *
 * @param {string} command
 * @returns {boolean}
 */
export function isGitAmend(command) {
  if (!command || typeof command !== 'string') return false;
  // Matches git commit ... --amend format only (ignores incidental --amend in other commands).
  // Normalisation: an "--amend" inside the commit message must not trigger the always-deny (false deny).
  return GIT_AMEND_PATTERN.test(inspectableCommand(command));
}

/**
 * Detects git branch creation commands.
 *
 * @param {string} command
 * @returns {boolean}
 */
export function isGitBranchCreate(command) {
  if (!command || typeof command !== 'string') return false;

  // Normalisation: "; git branch x" inside a message body must not read as a branch creation.
  const normalized = inspectableCommand(command);

  // git checkout -b/-B <branch> (new branch creation, -B is force create)
  if (GIT_CHECKOUT_NEWBRANCH_PATTERN.test(normalized)) return true;

  // git switch -c / --create / -C / --force-create (new branch creation)
  if (GIT_SWITCH_CREATE_PATTERN.test(normalized)) return true;

  // git branch <name> (new branch creation).
  // Excluded: query/management flags like git branch -d/-D (deletion), --list, -a, -v, --show-current, -r, --merged
  if (GIT_BRANCH_PATTERN.test(normalized)) {
    // If query/deletion/management flags present → not branch creation
    if (
      /\bgit\s+branch\s+(-d\b|-D\b|--delete\b|--list\b|-a\b|--all\b|-v\b|--verbose\b|--show-current\b|-r\b|--remote\b|--merged\b|--no-merged\b|--contains\b|--sort\b|--column\b|--no-column\b|--format\b|-m\b|-M\b|--move\b|--copy\b|-c\b|-C\b)/i.test(
        normalized,
      )
    ) {
      return false;
    }
    // If arguments present without flags → branch creation (e.g., git branch my-feature)
    // `git branch` alone (no arguments) = list branches → permitted
    const stripped = normalized.replace(/\bgit\s+branch\b/i, '').trim();
    if (stripped.length > 0) return true;
  }

  return false;
}

/**
 * Policy decision SSOT. Pure function.
 *
 * Decision Priority:
 *   0. Foreign repository  → passthrough (including amend — external repos are outside jurisdiction)
 *   1. amend              → always deny (cannot be bypassed even with create-pr active)
 *   2. create-pr          → passthrough (permits commit + branch creation)
 *   3. branch create      → always deny
 *   4. unresolved branch + commit → deny (fail-closed; see below)
 *   5. trunk + commit     → deny (permits worktree commit). With opt-in
 *      `policy.enforce_worktree_all_branches` (worktree-policy.json) every branch except the
 *      `escape_hatch` ones (hotfix/*) — judged by trunk-branch.mjs#requiresWorktree, the same predicate
 *      worktree-policy-guard and trunk-start-warning use — counts as trunk here, so a commit outside a
 *      worktree is denied on develop / release/* too, while root hotfix/x can still commit what it may edit.
 *   6. otherwise          → passthrough
 *
 * Rationale for placing jurisdiction check before amend: The rationale for banning amend is concurrent
 * pushes to this repository. External repositories do not share this premise, so "always deny" applies
 * within *this repository*.
 *
 * **Unresolved branch fails closed (observed defect, 2026-08-24)**: `branch` was coerced with `|| ''`
 * at the call site, so a branch git could not report — `safeGit` returns null on the 2s timeout or on
 * any git failure, and detached HEAD yields '' — read as "not exactly trunk" and *opened the gate*.
 * Reproduced with a `git branch --show-current` shim sleeping past the budget: the same payload flipped
 * from `deny` to `{}`. That made the verdict a function of machine load (it surfaced as a retry-passed
 * test during a gate run running 2.5x slower than usual), and on a loaded machine trunk commits passed
 * unguarded. An unresolved signal is not evidence of safety, so a commit with no known branch is denied;
 * worktree / create-pr / foreign-repo commits short-circuit above and are unaffected.
 *
 * R-CM-028: Perspective 1 only, because the defect exists only here — the template `commit-guard`
 * (Perspective 2) resolves no branch at all and denies every direct commit.
 *
 * @param {{ command: string, branch: string, isCreatePrActive: boolean, isWorktree?: boolean,
 *           trunkBranches?: string[], policy?: object|null, isForeignRepo?: boolean }} ctx
 *   `policy` is the loaded worktree-policy.json; `trunkBranches` (when given) overrides its protected_branches.
 * @returns {{ action: 'deny' | 'passthrough',
 *             kind?: 'amend' | 'branch_create' | 'main_commit' | 'unresolved_branch' }}
 */
export function decide({
  command,
  branch,
  isCreatePrActive,
  isWorktree,
  trunkBranches,
  policy = null,
  isForeignRepo,
}) {
  if (isForeignRepo) {
    return { action: 'passthrough' };
  }
  if (isGitAmend(command)) {
    return { action: 'deny', kind: 'amend' };
  }
  if (isCreatePrActive || isWorktree) {
    return { action: 'passthrough' };
  }
  if (isGitBranchCreate(command)) {
    return { action: 'deny', kind: 'branch_create' };
  }
  if (isGitCommit(command) && !branch) {
    return { action: 'deny', kind: 'unresolved_branch' };
  }
  // Fallbacks handled by lib
  const effective = { ...policy, protected_branches: trunkBranches ?? policy?.protected_branches };
  if (isGitCommit(command) && requiresWorktree(branch, effective)) {
    return { action: 'deny', kind: 'main_commit' };
  }
  return { action: 'passthrough' };
}

/**
 * Whether `dir` is inside a **linked worktree** under `.worktrees/`: the path must exist, is compared
 * after realpath (a symlink or `..` cannot dress the trunk up as a worktree), and git must agree —
 * `--git-dir` differs from `--git-common-dir` only in a linked worktree. The `/.worktrees/` string
 * alone is not evidence (`Cwd=/nonexistent/.worktrees/x`, `<main>/.worktrees/` itself).
 *
 * @param {string|null} dir
 * @param {(args: string, cwd: string) => string|null} [gitFn]
 * @returns {boolean}
 */
export function isLinkedWorktreeDir(dir, gitFn = safeGit) {
  if (!dir || !existsSync(dir)) return false;
  let real;
  try {
    real = realpathSync(dir);
  } catch {
    return false;
  }
  if (resolveWorktreeRoot(real) === null) return false;
  const out = gitFn('rev-parse --path-format=absolute --git-dir --git-common-dir', real);
  const [gitDir, commonDir] = (out || '').split('\n').map((l) => l.trim());
  return Boolean(gitDir && commonDir && gitDir !== commonDir);
}

/**
 * Whether **every** directory the commit may land in is a linked worktree — the only worktree evidence
 * commit-guard accepts. `commitTargets` follows `git -C <path>` / `cd <path> && git commit` / variables
 * through the shell's statement order and falls back to the cwd the command starts in, so a bare commit
 * in a worktree still counts; a `git -C <main> commit`, a `cd <main> && git commit` started from a
 * worktree, or a target the model cannot name (`unknown`) does not.
 *
 * @param {string} command
 * @param {string|null} [cwd]
 * @param {string|null} [baseDir]
 * @param {(args: string, cwd: string) => string|null} [gitFn]
 * @returns {boolean}
 */
export function isWorktreeCommit(command, cwd, baseDir, gitFn = safeGit) {
  return everyCommitTarget(command, cwd || null, (dir) => isLinkedWorktreeDir(dir, gitFn));
}

/**
 * Evaluates whether effective target of command is *another* repository outside this project.
 *
 * Evaluation order (by cost):
 *   1. Target under projectDir → same repo (no git call needed, dominant path).
 *   2. Outside projectDir → reads and compares `--git-common-dir` from both sides.
 *      Worktrees return the same value as main, properly recognizing them as the same repo.
 *
 * **fail-closed**: If resolution fails on either side, treats as within jurisdiction (fail-closed).
 *
 * @param {string|null} targetBase Effective base path of command (a commit target or cwd)
 * @param {string} projectDir
 * @param {{ gitFn?: (args: string, cwd: string, opts?: object) => string|null }} [deps]
 * @returns {boolean}
 */
export function isForeignRepoTarget(targetBase, projectDir, { gitFn = safeGit } = {}) {
  if (!targetBase || !projectDir) return false;
  const target = resolve(targetBase);
  const project = resolve(projectDir);
  if (target === project || target.startsWith(project + sep)) return false;

  const commonDirOf = (dir) =>
    gitFn('rev-parse --path-format=absolute --git-common-dir', dir);
  let mine, theirs;
  try {
    mine = commonDirOf(project);
    theirs = commonDirOf(target);
  } catch {
    return false;
  }
  if (!mine || !theirs) return false;
  return resolve(mine.trim()) !== resolve(theirs.trim());
}

// Uses actual evaluated branch name in messages
function buildDenyMessage(kind, branch = 'main') {
  const trunk = typeof branch === 'string' && branch ? branch : 'main';
  if (kind === 'amend') {
    return (
      `[Commit Guard] git commit --amend has been blocked.\n\n` +
      `amend creates the following risks in multi-terminal environments:\n` +
      `  - Amending already pushed commits forces force-pushes (violates R-CM-008 Rule 3)\n` +
      `  - Causes conflicts when another worktree attempts to push to the same branch\n\n` +
      `Alternatives:\n` +
      `  - If only modifying message: git reset --soft HEAD~1 && git commit -m "<new msg>"\n` +
      `  - If adding new changes: Correct with a new commit (R-CM-008 Rule 1: new commits recommended)\n`
    );
  }
  if (kind === 'branch_create') {
    return (
      `[Branch Guard] Branch creation has been blocked.\n\n` +
      `Branch creation must be paired with worktrees to prevent multi-terminal conflicts.\n\n` +
      `Alternatives (standard entry point — based on fetch + ff main + worktree add origin/main):\n` +
      `  make wt.new BR=feature/<task>\n` +
      `  # Or: node .claude/scripts/worktree-new.mjs --branch feature/<task>\n` +
      `Or use the /create-pr skill — automatically handles feature branch + PR + squash merge.\n`
    );
  }
  if (kind === 'paren_hash') {
    return (
      `[Commit Guard] Blocked: an unquoted ')' is directly followed by '#'.\n\n` +
      `Whether that '#' starts a comment depends on which construct the ')' closes, and this guard\n` +
      `cannot settle it without a full shell parser — reading it wrong hides the rest of the line.\n\n` +
      `Rewrite the command: put a space before '#' for a comment, or quote it ('#') for data.\n`
    );
  }
  if (kind === 'unresolved_branch') {
    return (
      `[Commit Guard] Blocked because the current branch could not be resolved.\n\n` +
      `'git branch --show-current' returned nothing — it timed out, failed, or HEAD is detached.\n` +
      `Without a branch name this guard cannot tell a trunk commit from a feature commit, and an\n` +
      `unresolved signal is not treated as permission (it used to be, which let trunk commits through\n` +
      `on a loaded machine).\n\n` +
      `What to do:\n` +
      `  - Retry: transient load is the common cause and the retry usually resolves the branch\n` +
      `  - Check the state: git status / git branch --show-current\n` +
      `  - Commit inside a worktree instead: git -C .worktrees/feature/<task> commit -m "<msg>"\n`
    );
  }
  // main_commit
  return (
    `[Commit Guard] To commit inside a worktree, explicitly specify 'git -C <worktree-path> commit' (when an existing worktree is present).\n` +
    `  git -C .worktrees/feature/<task> add <files>\n` +
    `  git -C .worktrees/feature/<task> commit -m "<msg>"\n\n` +
    `Blocked due to direct commit on ${trunk} branch (purpose: prevent code conflicts during concurrent multi-terminal work).\n` +
    `Commits are permitted inside worktree branches. While 'cd <worktree> && git commit' is also allowed,\n` +
    `using 'git -C <worktree>' is recommended as it does not rely on hook evaluation-time cwd.\n\n` +
    `If a new worktree is needed (standard entry point — based on fetch + ff main + worktree add origin/main):\n` +
    `  make wt.new BR=feature/<task>\n` +
    `  # Or: node .claude/scripts/worktree-new.mjs --branch feature/<task>\n\n` +
    `Or use the /create-pr skill — automatically handles feature branch + PR + squash merge.\n`
  );
}

/**
 * Resolves inputs for `decide()` from hook payload (accesses git/fs — non-pure).
 *
 * @param {object} data Hook payload, `cwd` = where the command starts (`withCommandCwd`)
 * @param {string} command
 * @param {string} projectDir From the original payload — never moved by the command's cwd
 * @returns {{ command: string, branch: string, isCreatePrActive: boolean, isWorktree: boolean,
 *            trunkBranches: string[], policy: object|null, isForeignRepo: boolean }}
 */
function resolveDecisionContext(data, command, projectDir) {
  const baseDir = (typeof data?.cwd === 'string' && data.cwd) || projectDir;

  // Jurisdiction: foreign only when every commit target is known and foreign — one in-repo or unknown
  // target keeps the command under this guard (fail-closed).
  const targets = commitTargets(command, baseDir);
  const isForeignRepo = targets
    ? !targets.unknown &&
      targets.bases.length > 0 &&
      targets.bases.every((dir) => isForeignRepoTarget(dir, projectDir))
    : isForeignRepoTarget(baseDir, projectDir);
  const policy = loadWorktreePolicy(projectDir);

  return {
    command,
    baseDir,
    // No `|| ''` coercion: falsy stays falsy so `decide()` can tell "unresolved" from "not trunk".
    branch: safeGit('branch --show-current', projectDir),
    isCreatePrActive: isCreatePrLeaseActive(projectDir),
    // Worktree evaluation: the commit's actual target only (`git -C` / `cd … &&` / else the start cwd),
    // resolved to a real path and confirmed as a linked worktree by git (isWorktreeCommit).
    isWorktree: isWorktreeCommit(command, data?.cwd, baseDir),
    // Resolves trunk list from target project policy (fallback to main+master).
    trunkBranches: resolveTrunkBranches(policy),
    policy,
    isForeignRepo,
  };
}

/**
 * Orchestrator compatible entry point.
 */
export async function run(rawData) {
  const verdict = await judge(rawData);
  const notice = installTrunkRefGuard(rawData);
  // A deny already speaks to the model; the install notice only rides on a passthrough.
  return notice && Object.keys(verdict).length === 0 ? notice : verdict;
}

async function judge(rawData) {
  try {
    const toolName = rawData.tool_name || '';
    if (toolName !== 'Bash' && toolName !== 'run_shell_command') {
      return HookOutput.passthrough();
    }

    const command = rawData.tool_input?.command || '';

    // Checked before any detector: each one reads `)#` its own way, and a wrong read erases the
    // rest of the line from all of them at once (review round 9). Heredoc data is not shell text.
    if (parenHashMayHide(stripHeredocData(command))) {
      return HookOutput.deny(buildDenyMessage('paren_hash'));
    }

    // Fast path: Pass immediately if unrelated command (avoid branch detection cost).
    // isGitAmend sits here too: amend is "always blocked", so a false negative in isGitCommit alone
    // must not be able to skip decide() (review round 5, 2026-09-28).
    if (!isGitCommit(command) && !isGitAmend(command) && !isGitBranchCreate(command)) {
      return HookOutput.passthrough();
    }

    // Antigravity: the command's own directory (toolCall.args.Cwd) is where it starts.
    const data = withCommandCwd(rawData);
    const ctx = resolveDecisionContext(data, command, resolveProjectDir(rawData));
    const result = decide(ctx);

    if (result.action === 'deny') {
      return HookOutput.deny(buildDenyMessage(result.kind, ctx.branch));
    }
    const lockHit = testLockCommitVerdict({
      command,
      cwd: data?.cwd,
      baseDir: ctx.baseDir,
      isCreatePrActive: ctx.isCreatePrActive,
    });
    if (lockHit) {
      return HookOutput.deny(formatCommitLockDenial(lockHit));
    }
    return HookOutput.passthrough();
  } catch (_) {
    return HookOutput.passthrough();
  }
}

/**
 * Self-heals the git-level trunk guard on any git command. Never changes this guard's verdict; a foreign
 * reference-transaction hook is left untouched and surfaced to the user, since the trunk then has only the
 * string checks above.
 * @returns {object|null} passthrough output carrying a user notice, or null
 */
function installTrunkRefGuard(rawData) {
  const toolName = rawData?.tool_name || '';
  if (toolName !== 'Bash' && toolName !== 'run_shell_command') return null;
  if (!/\bgit\b/.test(rawData.tool_input?.command || '')) return null;
  try {
    const { status, path } = ensureTrunkRefGuardInstalled(resolveProjectDir(rawData));
    if (status !== 'conflict') return null;
    return {
      systemMessage:
        `[commit-guard] ${path} already holds a different hook, so the git-level trunk guard ` +
        '(.claude/scripts/trunk-ref-guard.mjs) is not installed. Chain it from that hook to restore it.',
    };
  } catch {
    return null;
  }
}

/**
 * Regression-test lock at the commit boundary (Playbook Stage 4 "protect the loop").
 *
 * Runs after `decide()` passes a worktree commit. Only worktrees carry locks (the ledger lives in the
 * worktree mailbox; the derived set needs a `fix/` / `hotfix/` branch), so a non-worktree target is
 * null without a git call. The create-pr lease is exempt: ship's merge commits are a human-approved path.
 * Git runs on `safeExec`'s default budget — a verdict hook must not narrow it (a loaded machine would turn a
 * timeout into a verdict; `tests/unit/safe-git-transient-failure.test.mjs`). A null from git fails open here.
 *
 * @param {{ command: string, cwd?: string|null, baseDir: string, isCreatePrActive?: boolean,
 *           gitFn?: (args: string, cwd: string, opts?: object) => string|null }} args
 * @returns {ReturnType<typeof evaluateCommitTestLock>}
 */
export function testLockCommitVerdict({ command, cwd, baseDir, isCreatePrActive = false, gitFn = safeGit }) {
  if (isCreatePrActive || !isGitCommit(command)) return null;
  const targets = commitTargets(command, cwd || baseDir);
  const dirs = targets ? [...targets.bases, ...(targets.unknown ? [baseDir] : [])] : [baseDir];
  const roots = new Set(dirs.map((dir) => resolveWorktreeRoot(dir)).filter(Boolean));
  for (const root of roots) {
    const hit = evaluateCommitTestLock({ root, gitFn: (args) => gitFn(args, root) });
    if (hit) return hit;
  }
  return null;
}

// Standalone fallback (when called directly via settings.json).
// Without the isDirectInvocation check, merely *importing* this file (as unit tests do) runs
// `readStdin()`. Where stdin reaches EOF (one-shot runs) that passes silently, which is why it hid
// for so long; where stdin is inherited open (e.g. `make q.check`) the test run hung forever
// (observed 2026-09-18). The dispatcher path is unaffected: it sets
// __HOOK_ORCHESTRATOR__ and calls run() itself.
if (!globalThis.__HOOK_ORCHESTRATOR__ && isDirectInvocation(import.meta.url)) {
  safeHookMainWithProfile('commit-guard', async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
