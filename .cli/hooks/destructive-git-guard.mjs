#!/usr/bin/env node

/**
 * destructive-git-guard.mjs - PreToolUse Bash Hook
 *
 * Blocks destructive git commands in Claude Code's Bash tool.
 *
 * Defense-in-depth architecture:
 * ┌──────────────────────────────────────────────────────────────┐
 * │ L1: settings.json deny rules → depends on defaultMode        │
 * │ L2: This Hook                → Command parsing at PreToolUse │
 * │ L3: .git/hooks/              → Native git level block        │
 * └──────────────────────────────────────────────────────────────┘
 *
 * Even if L1 (deny) is disabled via bypassPermissions or CLI flags,
 * this Hook (L2) independently blocks destructive commands.
 *
 * Block targets (working tree destructive commands only):
 * - git reset --hard/--merge/--keep (destroys working tree — any option order within the segment)
 * - git checkout . / unbounded pathspec / -f · git switch -f/--discard-changes (destroys working tree;
 *   bounded explicit-file checkout passes — mirrors the restore relaxation below)
 * - git restore . / glob / <dir>/ / :magic / missing pathspec (broad working tree destruction)
 * - git clean -f/-d (deletes untracked files)
 * - git stash clear (deletes all stash snapshots in batch — unrecoverable)
 * - git push --force / -f / +<refspec> (destroys remote history)
 * - git rebase (modifies history)
 * - git push --no-verify (bypasses pre-push verification hook)
 * - raw git worktree add/remove (bypasses standard entry points)
 * - rm -rf <.worktrees/...> (forced deletion of worktree directories via tokenizer classifyRmWorktree)
 *
 * Permitted (inherently safe — preserves working tree):
 * - git reset --soft (moves HEAD only)
 * - git reset HEAD <files> / git reset HEAD -- <files> (unstage, index only)
 * - git reset (bare, --mixed) (full unstage, index only)
 * - git restore --staged (unstage, index only)
 * - git restore <explicit file> (bounded blast radius — user decision 2026-06-16)
 * - git stash push/save/drop/apply/pop/list/show/branch / git stash with no args (all stashes except clear)
 * - git checkout <branch-name> (branch switching)
 */

import { readStdin, output, safeHookMainWithProfile, isDirectInvocation } from '../lib/utils.mjs';
// `.tmp/create-pr-active` resolution SSOT — this guard used to carry its own TTL constant and
// freshness helper, one of four divergent readings of the same lease (see the lib header).
import { isCreatePrLeaseActive } from '../lib/create-pr-lease.mjs';
import { HookOutput } from '../lib/hook-output.mjs';
// Route heredoc bodies — a body `cat` reads is data (resolves false-positive blocks on destructive
// strings inside data contexts, e.g. `cat <<EOF\ngit stash clear\nEOF`), while a body a shell reads
// is a program and stays inspectable (`bash <<EOF\ngit reset --hard origin/main\nEOF` was invisible
// here until this fix).
import { stripHeredocData } from '../lib/heredoc-strip.mjs';
import { anchoredPattern, stripGitGlobalOptions, joinLineContinuations } from '../lib/hook-anchors.mjs';

/**
 * Destructive git command patterns definition.
 * Each pattern follows { regex, description, allowIf? }
 */
const DESTRUCTIVE_PATTERNS = [
  {
    // git reset --hard (HEAD + index + working tree reset = data destruction)
    // git reset --merge, --keep (conditional working tree mutation = dangerous)
    //
    // Permitted (preserves working tree, inherently safe):
    //   --soft             → moves HEAD only
    //   --mixed (default)  → resets index, preserves working tree
    //   HEAD <files>       → unstages specific files (index only)
    //   HEAD -- <files>    → same as above (-- delimiter)
    //   (bare)             → unstages all (index only)
    // Anywhere within the command segment — git accepts free option order, so requiring adjacency
    // (`reset --hard`) let `git reset -q --hard` / `git reset HEAD~1 --hard` pass unblocked
    // (empirical reproduction 2026-08-26). The char class stops at segment separators.
    regex: anchoredPattern('git\\s+reset\\b(?:[^\\n;&|]*\\s)?--(hard|merge|keep)\\b', 'i'),
    description: 'git reset --hard/--merge/--keep deletes uncommitted changes in the working tree',
    allowIf: null,
  },
  // git checkout / git switch working-tree discards are handled by tokenizer-based
  // classifyCheckoutDiscard() below — the former regex (`checkout (\.|--\s)`) required the discard
  // form as the *first* token, so `git checkout HEAD -- .` / `checkout -f` / `switch --discard-changes`
  // all passed unblocked (empirical reproduction 2026-08-26).
  // git push +<refspec> is handled by tokenizer-based classifyForcePushRefspec() below — a raw
  // regex over the command text false-blocked `+` inside quoted push-option values.
  // git restore is handled by tokenizer-based classifyRestore() below.
  {
    // git clean -f, -fd, -fx, etc.
    regex: anchoredPattern('git\\s+clean\\s+.*-[fdxX]', 'i'),
    description: 'git clean permanently deletes untracked files',
    allowIf: null,
  },
  {
    // git stash clear (deletes all stash entries — unrecoverable without reflogs).
    // All other stash subcommands permitted.
    regex: anchoredPattern('git\\s+stash\\s+clear\\b', 'i'),
    description: 'git stash clear deletes all stash snapshots in batch (unrecoverable)',
    allowIf: null,
  },
  {
    // git push --force, git push -f
    regex: anchoredPattern('git\\s+push\\s+.*(-f\\b|--force\\b)', 'i'),
    description: 'git push --force destroys history on the remote repository',
    allowIf: null,
  },
  {
    // git rebase
    regex: anchoredPattern('git\\s+rebase\\b', 'i'),
    description: 'git rebase modifies commit history',
    allowIf: null,
  },
  {
    // git push --no-verify (bypasses pre-push/pre-commit verification hooks)
    regex: anchoredPattern('git\\s+push\\s+.*--no-veri(?:f(?:y)?)?\\b', 'i'),
    description: 'git push --no-verify bypasses pre-push verification hooks',
    allowIf: null,
  },
  // git config core.hooksPath / core.worktree writes are decided by classifyProtectedConfigWrite
  // (argv parsing), not a regex here — a lookahead for `--get` was satisfied by a value or a
  // comment (`git config core.hooksPath /dev/null # --get`).
  {
    // raw git worktree add/remove (bypasses standard entry points)
    //
    // Naming ship-worktree alone left a real gap: it removes a worktree only as the tail of a
    // merge, so a worktree with zero unmerged commits — already shipped, or abandoned empty —
    // has no path in that sentence. Observed 2026-08-25: two such husks sat in .worktrees/ and
    // the AI, told only about ship-worktree, escalated the raw command to the human instead of
    // reaching for cleanup-worktree, which had existed all along (ops.mjs#cmdCleanupWorktree).
    // A deny that names no applicable alternative reads as "no alternative exists".
    regex: anchoredPattern('git\\s+worktree\\s+(add|remove)\\b', 'i'),
    description:
      'raw git worktree add/remove is blocked — creation: make wt.new BR=<branch> · ' +
      'removal with unmerged commits: /create-pr ship-worktree · ' +
      'removal of an already-merged or abandoned worktree: ' +
      'node .claude/scripts/create-pr/ops.mjs cleanup-worktree --worktree <path>',
    allowIf: null,
  },
];

// ── create-pr Safe Command Allowlist ──
const CREATE_PR_SAFE_PATTERNS = [
  /\bgit\s+merge\s+--ff-only\b/i,
  /\bgit\s+worktree\s+remove\b/i,
];

const WORKTREE_SHIPPING_BRANCH_PREFIXES = [
  'feature',
  'fix',
  'chore',
  'docs',
  'refactor',
  'test',
  'perf',
  'ci',
  'build',
  'style',
  'hotfix',
  'release',
];

function isCreatePrSafeCommand(command) {
  return CREATE_PR_SAFE_PATTERNS.some(p => p.test(command));
}


/**
 * Strips commit message body in `git commit -m <body>` from inspection.
 *
 * @param {string} command
 * @returns {string} stripped command
 */
export function stripCommitMessageBody(command) {
  let result = command;
  result = result.replace(
    /-m\s+"\$\(cat\s+<<\s*['"]?(\w+)['"]?\s*[\r\n][\s\S]*?[\r\n]\1\s*\)"/g,
    '-m ""'
  );
  result = result.replace(/-m\s+'(?:[^'\\]|\\.)*'/g, "-m ''");
  result = result.replace(/-m\s+"(?:[^"\\]|\\.)*"/g, '-m ""');
  return result;
}

/**
 * Reduces a raw command to the text this guard inspects.
 *
 * Six call sites below each spelled this chain out by hand, so any correction had to be made six
 * times. Order is load-bearing:
 *   1. heredoc routing needs the raw `<<'EOF'` opener to find its delimiter
 *   2. continuations are folded *before* any pattern or segment split, because a `\<newline>` is
 *      the one newline that is not a separator — `git reset \<newline> --hard origin/main` is a
 *      real `reset --hard` that this guard read as a bare `git reset`
 *   3. the commit message body is dropped last, once quotes are the only thing left to find
 *
 * @param {string} command
 * @returns {string}
 */
function inspectableCommand(command) {
  return stripCommitMessageBody(joinLineContinuations(stripHeredocData(command)));
}

function shellishTokens(commandSegment) {
  const tokens = [];
  const tokenPattern = /"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|(\S+)/g;
  for (const match of commandSegment.matchAll(tokenPattern)) {
    tokens.push(match[1] ?? match[2] ?? match[3]);
  }
  return tokens;
}

/**
 * Extracts merge target from `git merge --ff-only <target>` formats.
 *
 * @param {string} command
 * @returns {string|null}
 */
export function extractFastForwardMergeTarget(command) {
  if (!command || typeof command !== 'string') return null;

  const inspectable = inspectableCommand(command);
  const commandSegments = inspectable.split(/[\n;&|]+/);

  for (const segment of commandSegments) {
    const args = shellishTokens(segment);
    const gitIndex = args.findIndex(arg => arg === 'git');
    if (gitIndex < 0) continue;

    let mergeIndex = -1;
    for (let i = gitIndex + 1; i < args.length; i += 1) {
      const arg = args[i];
      if (arg === 'merge') {
        mergeIndex = i;
        break;
      }
      if (arg === '-C' || arg === '-c' || arg === '--git-dir' || arg === '--work-tree') {
        i += 1;
        continue;
      }
      if (
        arg.startsWith('-C') ||
        arg.startsWith('-c') ||
        arg.startsWith('--git-dir=') ||
        arg.startsWith('--work-tree=') ||
        arg === '--no-pager' ||
        arg === '--literal-pathspecs' ||
        arg === '--no-optional-locks'
      ) {
        continue;
      }
    }

    if (mergeIndex < 0) continue;

    const mergeArgs = args.slice(mergeIndex + 1);
    if (!mergeArgs.includes('--ff-only')) continue;

    const target = mergeArgs.find(arg => arg !== '--ff-only' && arg !== '--no-edit' && !arg.startsWith('-'));
    if (target) return target;
  }

  return null;
}

function normalizeBranchTarget(target) {
  return target
    .replace(/^refs\/heads\//, '')
    .replace(/^refs\/remotes\/[^/]+\//, '')
    .replace(/^[^/]+\/(?=(feature|fix|chore|docs|refactor|test|perf|ci|build|style|hotfix|release)\/)/, '');
}

/**
 * Detects shipping bypass where worktree branches are fast-forward merged directly to main outside create-pr.
 *
 * @param {string} command
 * @returns {boolean}
 */
export function isDirectWorktreeShippingMerge(command) {
  const target = extractFastForwardMergeTarget(command);
  if (!target) return false;

  const normalized = normalizeBranchTarget(target);
  return WORKTREE_SHIPPING_BRANCH_PREFIXES.some(prefix => normalized.startsWith(`${prefix}/`));
}

/**
 * Determines whether single pathspec is bounded (specific file paths only).
 *
 * @param {string} p
 * @returns {boolean}
 */
function isBoundedPathspec(p) {
  if (!p) return false;
  const u = p.replace(/\\(.)/g, '$1'); // Unescape shell backslashes (\. → . , \* → *)
  if (/[*?[\]{}$`]/.test(u)) return false;
  if (u.startsWith(':')) return false; // Magic pathspec (:/ , :(top) broad repo-root)
  if (u.startsWith('~')) return false; // Home expansion
  if (u.endsWith('/')) return false; // Explicit directory (recursive)
  if (u.split('/').some(seg => seg === '.' || seg === '..')) return false;
  return true; // Specific file path
}

/**
 * Evaluates whether all pathspecs in restore arguments are bounded.
 *
 * @param {string[]} args - Tokens after 'restore'
 * @returns {boolean}
 */
function isBoundedRestoreArgs(args) {
  const VALUE_OPTS = new Set(['--source', '-s']);
  let sawDashDash = false;
  const pathspecs = [];

  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (!sawDashDash && a === '--') {
      sawDashDash = true;
      continue;
    }
    if (!sawDashDash && a.startsWith('-')) {
      if (a === '--pathspec-from-file' || a.startsWith('--pathspec-from-file=')) return false;
      if (VALUE_OPTS.has(a)) {
        i += 1;
        continue;
      }
      continue;
    }
    pathspecs.push(a);
  }

  if (pathspecs.length === 0) return false;
  return pathspecs.every(isBoundedPathspec);
}

function hasShellSubstitution(s) {
  return /\$[({]/.test(s) || s.includes('`');
}

function findSubcommandIndex(tokens, names) {
  const gitIndex = tokens.findIndex(t => t === 'git');
  if (gitIndex < 0) return -1;
  for (let i = gitIndex + 1; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (names.includes(t)) return i;
    if (t === '-C' || t === '-c' || t === '--git-dir' || t === '--work-tree') {
      i += 1;
      continue;
    }
    if (t.startsWith('-')) continue;
    return -1;
  }
  return -1;
}

function findRestoreIndex(tokens) {
  return findSubcommandIndex(tokens, ['restore']);
}

function isUnstageOnly(args) {
  let staged = false;
  let worktree = false;
  for (const a of args) {
    if (a === '--') break;
    if (a === '--staged') staged = true;
    if (a === '--worktree') worktree = true;
  }
  return staged && !worktree;
}

/**
 * Classifies `git restore` calls: 'block' | 'allow' | 'none'.
 *
 * @param {string} command
 * @returns {'block'|'allow'|'none'}
 */
export function classifyRestore(command) {
  if (!command || typeof command !== 'string') return 'none';

  const inspectable = inspectableCommand(command);
  const segments = inspectable.split(/[\n;&|]+/);

  let sawRestore = false;
  for (const segment of segments) {
    if (hasShellSubstitution(segment) && /\brestore\b/i.test(segment)) {
      return 'block';
    }

    const tokens = shellishTokens(segment);
    const restoreIndex = findRestoreIndex(tokens);
    if (restoreIndex < 0) continue;

    sawRestore = true;
    const args = tokens.slice(restoreIndex + 1);
    if (isUnstageOnly(args)) continue; // --staged (working tree untouched) → allowed
    if (isBoundedRestoreArgs(args)) continue; // explicit file → allowed
    return 'block'; // broad blast radius
  }

  return sawRestore ? 'allow' : 'none';
}

/**
 * Detects working-tree-discarding forms of `git checkout` / `git switch` (tokenizer-based,
 * mirroring classifyRestore — regex adjacency assumptions are how the previous pattern leaked
 * `git checkout HEAD -- .`).
 *
 * Blocked:  checkout with `--` pathspec form / explicit `.` / 2+ non-flag args (tree-ish + pathspec)
 *           / -f|--force / --pathspec-from-file; switch with -f|--force|--discard-changes.
 * Permitted: branch switching (`checkout <branch>`, `switch <branch>`), branch creation
 *           (`-b/-B/--orphan` — commit-guard's domain), conflict-side checkout without pathspec form.
 *
 * @param {string} command
 * @returns {boolean}
 */
export function classifyCheckoutDiscard(command) {
  if (!command || typeof command !== 'string') return false;
  const inspectable = inspectableCommand(command);
  for (const segment of inspectable.split(/[\n;&|]+/)) {
    const tokens = shellishTokens(segment);
    const idx = findSubcommandIndex(tokens, ['checkout', 'switch']);
    if (idx < 0) continue;
    if (checkoutArgsDiscard(tokens[idx], tokens.slice(idx + 1))) return true;
  }
  return false;
}

/** Whether one `checkout`/`switch` invocation's own args discard working-tree state. */
function checkoutArgsDiscard(sub, args) {
  if (sub === 'switch') {
    return args.some(a => a === '-f' || a === '--force' || a === '--discard-changes');
  }
  if (args.includes('-b') || args.includes('-B') || args.includes('--orphan')) return false;
  if (args.some(a => a === '-f' || a === '--force')) return true;
  if (args.some(a => a === '--pathspec-from-file' || a.startsWith('--pathspec-from-file='))) return true;
  // Pathspec forms mirror the restore relaxation (user decision 2026-06-16): explicit bounded
  // files are targeted restores (`checkout --ours -- f.txt`, `checkout main -- f.txt`) and pass;
  // broad blast radius (`.`, globs, dirs, missing pathspec after `--`) blocks. Blocking every
  // `--` form here would regress conflict-resolution flows the old regex never matched.
  const ddIdx = args.indexOf('--');
  let pathspecs;
  if (ddIdx >= 0) {
    pathspecs = args.slice(ddIdx + 1);
    if (pathspecs.length === 0) return true;
  } else {
    const nonFlags = args.filter(a => !a.startsWith('-'));
    // First non-flag is the tree-ish/branch (switch target) — unless it is itself `.`.
    pathspecs = nonFlags[0] === '.' ? nonFlags : nonFlags.slice(1);
  }
  if (pathspecs.length === 0) return false; // pure branch switch
  return !pathspecs.every(isBoundedPathspec);
}

/**
 * Detects `git push` with a `+`-prefixed refspec — per-ref force update, equivalent to --force
 * for that ref; the --force/-f flag pattern never sees it (empirical reproduction 2026-08-26).
 * Tokenizer-based so `+` inside quoted option values (`-o "title=has +x"`) does not false-block;
 * option values of value-taking flags are skipped, only refspec-position args are inspected.
 *
 * @param {string} command
 * @returns {boolean}
 */
export function classifyForcePushRefspec(command) {
  if (!command || typeof command !== 'string') return false;
  const inspectable = inspectableCommand(command);
  const VALUE_OPTS = new Set(['-o', '--push-option', '--receive-pack', '--exec', '--repo']);
  for (const segment of inspectable.split(/[\n;&|]+/)) {
    const tokens = shellishTokens(segment);
    const idx = findSubcommandIndex(tokens, ['push']);
    if (idx < 0) continue;
    const args = tokens.slice(idx + 1);
    for (let i = 0; i < args.length; i += 1) {
      const a = args[i];
      if (a.startsWith('-')) {
        if (VALUE_OPTS.has(a)) i += 1;
        continue;
      }
      if (a.startsWith('+')) return true;
    }
  }
  return false;
}

function rmHasRecursiveForce(args) {
  let recursive = false;
  let force = false;
  for (const t of args) {
    if (!t.startsWith('-') || t === '--') continue;
    if (t === '--recursive' || /^-[a-zA-Z]*[rR][a-zA-Z]*$/.test(t)) recursive = true;
    if (t === '--force' || /^-[a-zA-Z]*f[a-zA-Z]*$/.test(t)) force = true;
  }
  return recursive && force;
}

function rmTargetsWorktree(args) {
  const WT = /(^|\/)\.worktrees(\/|$)/;
  return args.some((t) => !t.startsWith('-') && WT.test(t.replace(/\\(.)/g, '$1')));
}

/**
 * Detects `rm -rf <.worktrees/...>` (blocking forced deletion of worktree directories).
 *
 * @param {string} command
 * @returns {boolean}
 */
export function classifyRmWorktree(command) {
  if (!command || typeof command !== 'string') return false;
  const inspectable = inspectableCommand(command);
  for (const segment of inspectable.split(/[\n;&|]+/)) {
    const tokens = shellishTokens(segment);
    const rmIdx = tokens.indexOf('rm');
    if (rmIdx < 0) continue;
    const args = tokens.slice(rmIdx + 1);
    if (rmHasRecursiveForce(args) && rmTargetsWorktree(args)) return true;
  }
  return false;
}

/**
 * Config keys whose mutation disables or misroutes the harness, with the reason shown on denial.
 *
 * - `core.hookspath`: changing/unsetting it permanently disables verification hooks for all
 *   subsequent commits/pushes (use worktree-init.mjs if normalization is needed).
 * - `core.worktree`: set on the shared repository config it redirects
 *   the main checkout's working tree, so every later git command in the root operates elsewhere.
 */
const PROTECTED_CONFIG_KEYS = new Map([
  [
    'core.hookspath',
    'Changing/unsetting git config core.hooksPath permanently disables verification hooks for all subsequent commits/pushes (use worktree-init.mjs if normalization is needed)',
  ],
  [
    'core.worktree',
    'Mutating git config core.worktree corrupts repository routing and redirects the main checkout to a worktree',
  ],
]);

/** `git config` options that take a separate value word. */
const CONFIG_VALUE_OPTS = new Set(['-f', '--file', '--blob', '-t', '--type', '--default', '--comment', '--value']);
/** Legacy action flags that only read. */
const CONFIG_READ_FLAGS = /^(?:--get(?:-all|-regexp|-urlmatch|-color|-colorbool)?|--list|-l|-e|--edit)$/;
/** Legacy action flags that write the named key. */
const CONFIG_WRITE_FLAGS = /^(?:--unset(?:-all)?|--add|--replace-all)$/;
/** Git 2.46+ subcommands. */
const CONFIG_WRITE_SUBCOMMANDS = new Set(['set', 'unset']);
const CONFIG_READ_SUBCOMMANDS = new Set(['get', 'list', 'edit', 'get-color', 'get-colorbool']);

/**
 * Tokens of one command segment, ending at an unquoted comment. The same quoting as
 * `shellishTokens`, but a word starting with `#` outside quotes ends the command.
 */
function segmentWordsUntilComment(segment) {
  const words = [];
  const tokenPattern = /"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|(\S+)/g;
  for (const match of segment.matchAll(tokenPattern)) {
    if (match[3]?.startsWith('#')) break;
    words.push(match[1] ?? match[2] ?? match[3]);
  }
  return words;
}

/** Splits `git config` arguments into action flags and positional words. */
function parseConfigArgs(args) {
  const flags = [];
  const positional = [];
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (a === '--') {
      positional.push(...args.slice(i + 1));
      break;
    }
    if (CONFIG_VALUE_OPTS.has(a)) i += 1;
    else if (a.startsWith('-')) flags.push(a);
    else positional.push(a);
  }
  return { flags, positional };
}

/**
 * Does this `git config` argv write `key`? Reads — `--get*`, `--list`, the `get`/`list`
 * subcommands, and the bare one-argument form `git config <key>` — do not.
 */
function configArgsWriteKey(args) {
  const { flags, positional } = parseConfigArgs(args);
  let [first, ...rest] = positional;
  if (CONFIG_READ_SUBCOMMANDS.has(first)) return null;
  const subcommandWrite = CONFIG_WRITE_SUBCOMMANDS.has(first);
  if (subcommandWrite) [first, ...rest] = rest;
  const key = (first ?? '').toLowerCase();
  if (!PROTECTED_CONFIG_KEYS.has(key)) return null;
  if (subcommandWrite || flags.some((f) => CONFIG_WRITE_FLAGS.test(f))) return key;
  if (flags.some((f) => CONFIG_READ_FLAGS.test(f))) return null;
  return rest.length > 0 ? key : null;
}

/**
 * Returns the protected config key a command writes via `git config`, or `null`.
 *
 * Parses argv instead of pattern-matching, so a value or comment that merely contains `--get`
 * (`git config core.worktree /tmp/--get`, `… # --get`) is not taken for a read, and real reads
 * (`git config core.worktree`, `git config get core.worktree`) are not taken for writes.
 *
 * @param {string} command
 * @returns {string|null}
 */
export function classifyProtectedConfigWrite(command) {
  if (!command || typeof command !== 'string') return null;
  for (const segment of inspectableCommand(command).split(/[\n;&|]+/)) {
    const tokens = segmentWordsUntilComment(segment);
    const idx = findSubcommandIndex(tokens, ['config']);
    if (idx < 0) continue;
    const key = configArgsWriteKey(tokens.slice(idx + 1));
    if (key) return key;
  }
  return null;
}

/**
 * Inspects command for destructive git patterns.
 * @param {string} command - Bash command string
 * @returns {{ blocked: boolean, description?: string, matched?: string }}
 */
export function checkDestructiveGit(command) {
  if (!command || typeof command !== 'string') {
    return { blocked: false };
  }

  const inspectable = inspectableCommand(command);

  if (isDirectWorktreeShippingMerge(command)) {
    return {
      blocked: true,
      kind: 'worktree-shipping',
      description: 'worktree branch fast-forward merge must only be performed via the create-pr ship-worktree path',
      matched: extractFastForwardMergeTarget(command),
    };
  }

  if (classifyRestore(command) === 'block') {
    return {
      blocked: true,
      description:
        'git restore . / glob / directory / substitution / broad pathspec broadly deletes working tree changes (explicit single file restore is permitted)',
      matched: 'git restore',
    };
  }

  if (classifyCheckoutDiscard(command)) {
    return {
      blocked: true,
      description:
        'git checkout with unbounded pathspec (./glob/dir) or -f, and git switch -f/--discard-changes, delete uncommitted changes in the working tree (branch switching and bounded explicit-file checkout are permitted)',
      matched: 'git checkout/switch (working-tree discard form)',
    };
  }

  if (classifyForcePushRefspec(command)) {
    return {
      blocked: true,
      description: 'git push +<refspec> force-updates the remote ref (equivalent to --force)',
      matched: 'git push +<refspec>',
    };
  }

  if (classifyRmWorktree(command)) {
    return {
      blocked: true,
      description:
        'Deleting worktree directories with rm -rf is blocked (removal: /create-pr ship-worktree cleanup or git worktree remove in create-pr flow)',
      matched: 'rm -rf .worktrees',
    };
  }

  const protectedKey = classifyProtectedConfigWrite(command);
  if (protectedKey) {
    return {
      blocked: true,
      description: PROTECTED_CONFIG_KEYS.get(protectedKey),
      matched: `git config ${protectedKey}`,
    };
  }

  const hooksPathOverride = inspectable.match(
    anchoredPattern('git\\b[^\\n;&|]*\\s-c\\s*core\\.hooksPath\\s*=', 'i'),
  );
  if (hooksPathOverride) {
    return {
      blocked: true,
      description: 'git -c core.hooksPath=... disables pre-push/pre-commit verification hooks',
      matched: hooksPathOverride[0],
    };
  }

  const normalized = stripGitGlobalOptions(inspectable);
  for (const pattern of DESTRUCTIVE_PATTERNS) {
    const match = normalized.match(pattern.regex);
    if (match) {
      if (pattern.allowIf && pattern.allowIf(command)) {
        continue;
      }
      return {
        blocked: true,
        description: pattern.description,
        matched: match[0],
      };
    }
  }

  return { blocked: false };
}

/**
 * Orchestrator compatible entry point.
 */
export async function run(data) {
  try {
    const toolName = data.tool_name || '';
    if (toolName !== 'Bash') {
      return HookOutput.passthrough();
    }

    const command = data.tool_input?.command || '';

    const projectDir = process.env.CLAUDE_PROJECT_DIR || '';
    if (isCreatePrLeaseActive(projectDir) && isCreatePrSafeCommand(command)) {
      return HookOutput.passthrough();
    }

    const result = checkDestructiveGit(command);

    if (result.blocked) {
      if (result.kind === 'worktree-shipping') {
        return HookOutput.deny(
          `[Destructive Git Guard] Direct worktree branch fast-forward merge has been blocked.\n\n` +
          `Blocked merge target: ${result.matched}\n` +
          `Reason: ${result.description}\n\n` +
          `For worktree shipping, use only /create-pr ship-worktree or ` +
          `node .claude/scripts/create-pr/ops.mjs ship-worktree --worktree <path>.`
        );
      }

      return HookOutput.deny(
        `[Destructive Git Guard] Destructive git command detected and blocked.\n\n` +
        `Blocked command: ${result.matched}\n` +
        `Reason: ${result.description}\n\n` +
        `This command can permanently destroy uncommitted work.\n` +
        `Please obtain user confirmation before proceeding.`
      );
    }

    return HookOutput.passthrough();
  } catch {
    return HookOutput.passthrough();
  }
}

// Standalone fallback (when called directly via settings.json).
// Without the isDirectInvocation check, merely *importing* this file (as unit tests do) runs
// `readStdin()`. Where stdin reaches EOF (one-shot runs) that passes silently, which is why it hid
// for so long; where stdin is inherited open (e.g. `make q.check`) the test run hung forever
// (observed 2026-09-18). The dispatcher path is unaffected: it sets
// __HOOK_ORCHESTRATOR__ and calls run() itself.
if (!globalThis.__HOOK_ORCHESTRATOR__ && isDirectInvocation(import.meta.url)) {
  safeHookMainWithProfile('destructive-git-guard', async () => {
    const data = await readStdin();
    return output(await run(data));
  });
}
