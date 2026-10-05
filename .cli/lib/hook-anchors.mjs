/**
 * hook-anchors.mjs - Hook command matching normalization SSOT (anchor + git global option)
 *
 * PreToolUse Bash hook patterns assume that "the command *looks like* `git push …`".
 * This file centralizes two axes that align that assumption with actual shell commands:
 *   - **anchor**: Matches only immediately following command start (`^`) / chain operator (`;` `&&` `||` `|`) / newline /
 *     command substitution (see CMD_ANCHOR_SRC below)
 *   - **git global option stripping**: `git -C <path> push` → `git push` (stripGitGlobalOptions)
 *
 * Simple word boundaries `\b` match trigger strings inside diagnostic code / quoted strings / heredoc bodies / grep / echo
 * as false positives (PR #493 root cause F1-F5).
 *
 * Consumers (verified 2026-08-09): commit-guard / destructive-git-guard / dev-server-guard / pre-ship-review-guard.
 * The purpose of a single SSOT is to prevent cluster regressions where modifying the anchor of one hook leaves others stale.
 */

/**
 * Environment variable assignments preceding commands (`FOO=1 git push`, `A=1 B=2 git push`) — 0 or more.
 *
 * **Why part of the anchor (empirical 2026-08-09, DEBT-272)**: `VAR=x <cmd>` is everyday POSIX shell syntax,
 * not an evasive technique. Yet adding even one assignment broke both `^` and chain operators, **silencing all anchored patterns** —
 * blocking `git push --no-verify` but passing `GIT_SSH_COMMAND="ssh …" git push --no-verify`. Beyond push bypasses,
 * 4 hooks were simultaneously pierced across `stash clear` / `reset --hard` / trunk commit / `--amend` / unpaneled ship.
 * Crucially, this is the exact pattern AI naturally adopts when SSH hangs, stripping protection without malicious intent.
 *
 * Value is `[^\s;&|]*` — swallowing chain operators would misinterpret subsequent commands as assignment values.
 * Quoted values (`GIT_SSH_COMMAND="ssh -o x"`) include whitespace and are handled via a dedicated branch.
 *
 * **Intentional exclusion (transparent statement)**: Wrapper commands like `env FOO=1 git …` / `timeout 60 git …` / `nohup`
 * are not covered. They are infinite and do not match observed failure modes. What is closed here is losing protection without evasive intent.
 */
const ENV_ASSIGN_PREFIX_SRC = '(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|[^\\s;&|]*)\\s+)*';

/**
 * Anchor matching only immediately after command start / chain operator / newline / command substitution.
 *
 * Boundary types:
 *   - `^`            Command start
 *   - `[;&|\n]\s*`   Chain operator (`;` `&&` `||` `|`) / newline
 *   - `\$\(\s*`      Command substitution `$(...)` — inner command actually executed by shell (DEBT-79)
 *   - `` `\s* ``     Legacy backtick substitution — identically executed in practice
 *
 * Each boundary may be followed by 0 or more environment variable assignments (see ENV_ASSIGN_PREFIX_SRC) —
 * `FOO=1 git push` remains a valid "command start".
 *
 * Git commands inside subshells/backticks are actually executed by the shell unlike literal arguments in `echo`,
 * making them valid inspection targets for destructive/commit/ship triggers (e.g., in `echo $(git stash clear)`,
 * stash clear is executed). Heredoc bodies are handled separately by `stripHeredocData`, which
 * routes them: a body a shell reads is a program and comes back for inspection, a body a data tool
 * reads is dropped. Either way it is orthogonal to this anchor.
 *
 * Note: `\\n` JS string literal → resolves to `\n` regex metachar (actual newline) when constructing RegExp.
 * Maintain JS string escape level to preserve newline matching.
 */
export const CMD_ANCHOR_SRC = `(?:^|[;&|\\n]\\s*|\\$\\(\\s*|\`\\s*)${ENV_ASSIGN_PREFIX_SRC}`;

/**
 * Command separators, for hooks that must *decide* something about a compound command
 * rather than merely anchor a match inside it.
 *
 * **Why these are separate from the anchor above (empirical 2026-09-06)**: the anchor uses the
 * loose class `[;&|\n]` because over-matching there is harmless — a spurious boundary only *permits*
 * a pattern to match, and the pattern itself still has to match. These two are used to answer
 * yes/no questions, so over-matching becomes a false positive (bare `&` would make `2>&1` a
 * "separator"). Both therefore spell out the operators instead of using a character class.
 *
 * **Why they live here**: this file's stated job is to stop one hook's boundary notion from drifting
 * away from another's. It had failed at exactly that — `pre-ship-review-guard` and
 * `bash-file-integrity-guard` each carried a private separator list and **both omitted the newline**,
 * while the anchor above knew about it. Bash treats a newline as a statement separator identically
 * to `;`, and multi-line commands are the normal shape of an agent tool call, so the omission was
 * not exotic: `sed -i` with any following line escaped the in-place integrity check entirely, and a
 * marker-then-ship call written across two lines was diagnosed as if it had never been chained.
 *
 * **Adoption is partial, stated plainly**: only `pre-ship-review-guard` and
 * `bash-file-integrity-guard` read these. `commit-guard.mjs` and `destructive-git-guard.mjs`
 * (5 sites) still split on their own `[\n;&|]+`. That spelling is *not* buggy — it includes the
 * newline — but it is a third convention, and it splits on a bare `&` where these two do not, so
 * migrating it changes what two security guards inspect. That belongs in its own change with its
 * own regressions, not smuggled into this one.
 *
 * The two sets differ **on purpose** — do not merge them:
 *   - SEQUENTIAL: "does an earlier command's side effect land before the next one runs?"
 *     A pipe does not qualify; it hands over stdout, it does not sequence a file write.
 *   - BOUNDARY: "where does one command end and the next begin?" A pipe does qualify.
 *
 * Known limitation (unchanged by this split, stated rather than hidden): a `;` or `&&` inside a
 * quoted script (`sed 's/a/b/;s/c/d/' f.txt`) is read as a separator. Splitting correctly there
 * needs quote-aware tokenization, not a richer regex.
 */
export const SEQUENTIAL_SEPARATOR_RE = /&&|\|\||;|\n/;
export const COMMAND_BOUNDARY_RE = /&&|\|\||;|\|(?!\|)|\n/;

/**
 * Folds `\<newline>` continuations back into one line, and trims the outer newlines that carry no
 * second command.
 *
 * **Call this before either separator above.** A backslash-continuation is the one place a newline
 * is *not* a separator — it is a single command wrapped for readability — so treating the two
 * alike breaks in both directions: `pre-ship-review-guard` reports a lone `ship \<newline> --title`
 * as chained (and a trailing newline, which most tool-call strings carry, made the hint fire on
 * nearly every denial), while `bash-file-integrity-guard` splits `sed -i … \<newline> file.txt`
 * into two segments and loses the target.
 *
 * **Only an odd-length run of backslashes continues the line.** `\\` is an escaped backslash, so
 * `echo a\\<newline>git reset --hard` is two commands to the shell; folding it produced one, and a
 * caller asking "is this chained?" was told no. The parity rule is POSIX, not a heuristic: each
 * pair is one literal backslash, and only a leftover single one can escape the newline.
 *
 * **The pair is removed, not replaced by a space, and the next line's indentation survives.** This
 * looks cosmetic and is not: `--branch=ma\<newline>in` is `--branch=main` to the shell, and folding
 * to `--branch=ma in` made a branch-checking guard read the branch as `ma` (measured
 * 2026-09-18). Whitespace that was already there stays there, so `git reset \<newline>  --hard`
 * still has its separating space.
 *
 * **Quotes and comments are respected, because bash respects them.** Inside single quotes (and
 * `$'…'`) a backslash is literal, so `\<newline>` there is two characters, not a continuation.
 * Inside a comment it is literal too: `# note \<newline>git reset --hard` is a comment followed by
 * a real `reset --hard`. A regex fold joined that line into the comment and the guards stopped
 * seeing the command (review of f222e205, 2026-09-23), so this is a small scanner, not a regex.
 */
export function joinLineContinuations(command) {
  if (typeof command !== 'string') return command;
  return foldContinuations(command).replace(/^\s*\n|\n\s*$/g, '');
}

/**
 * Unquoted, unescaped characters that end a word: bash's metacharacters. Its blanks are space and
 * tab only — JS `\s` also matched `\r` / `\v` / `\f` / NBSP / U+3000, which bash keeps inside the
 * word, so `echo hi\r#x; git commit --amend` read as a comment and hid the amend (review round 10).
 */
const WORD_BREAK_RE = /[ \t\n;&|()<>]/;

/**
 * Tracks whether the next character begins a word — bash opens a `#` comment only there. Shared by
 * the two raw-text scanners (fold below, git-commit-target#stripQuoted), whose private copies
 * drifted and each erased a real `commit` / `--amend` after a `#` that bash reads as data (review
 * rounds 6-8, 2026-09-28). bash-segments' Scanner#hash judges on segment text instead, where
 * substitutions are already lifted out. The paren stack is best effort — an unpaired `)` (`case`
 * pattern) misleads it — so commit-guard denies `)#` outright (git-commit-target#hasParenHash).
 * Measured in bash, the word continues after
 *   - an escape pair, even of a break character: `a\ #x` → `a #x`, `a\;#x` → `a;#x`
 *   - a quoted string
 *   - a `)` that closes `$( … )` / `<( … )` / `$(( … ))`: `$(true)#x` → `#x`
 * and a group `)` ends it: `(echo g)#x` drops `#x`.
 */
export class WordStart {
  #opens = []; // per open `(`: does it start a substitution?
  #at = true;

  /** Does the next character begin a word? */
  get at() {
    return this.#at;
  }

  /** An unquoted, unescaped character `c`, preceded by `prev`. */
  char(c, prev) {
    if (c === '(') this.#opens.push(prev === '$' || prev === '<' || prev === '>');
    const closesSubst = c === ')' && this.#opens.pop() === true;
    this.#at = WORD_BREAK_RE.test(c) && !closesSubst;
  }

  /** An escape pair or a quoted string — part of the current word whatever its characters. */
  word() {
    this.#at = false;
  }
}

/** Length of the newline starting at `i` (`\n` → 1, `\r\n` → 2), else 0. */
function newlineLength(text, i) {
  if (text[i] === '\n') return 1;
  return text[i] === '\r' && text[i + 1] === '\n' ? 2 : 0;
}

/**
 * Scanner state transition for an unquoted, uncommented character; feeds `ws`.
 *
 * `prev` is the previous *output* character (after folding), tracked by the caller: reading it
 * back from the accumulated output flattened the string on every `#`/`'` and made the fold
 * quadratic — 40k lines took seconds, long enough for a hook timeout (review, 2026-09-23).
 *
 * @returns {'n'|'sq'|'dq'|'ansi'|'comment'} the mode after `c`
 */
function nextUnquotedMode(c, prev, ws) {
  if (c === "'" || c === '"') {
    ws.word();
    if (c === '"') return 'dq';
    return prev === '$' ? 'ansi' : 'sq';
  }
  if (c === '#' && ws.at) return 'comment';
  ws.char(c, prev);
  return 'n';
}

/** Mode after `c` when already inside quotes / a comment, or `null` to stay. */
function closingMode(mode, c) {
  if (mode === 'comment') return c === '\n' ? 'n' : null;
  if (mode === 'dq') return c === '"' ? 'n' : null;
  return c === "'" ? 'n' : null; // sq / ansi
}

/**
 * At a backslash that escapes (unquoted, double-quoted, `$'…'`): returns the kept text and the
 * number of characters consumed. An unquoted / double-quoted `\\<newline>` is removed whole; any
 * other escape pair is kept verbatim and consumed together, which is what makes `\\\\<newline>`
 * a real line break.
 */
function escapeAt(text, i, mode) {
  const nl = mode === 'ansi' ? 0 : newlineLength(text, i + 1);
  return nl ? { kept: '', width: 1 + nl } : { kept: text.slice(i, i + 2), width: 2 };
}

/** Mode after scanning `c` in `mode`. */
function nextMode(mode, c, prev, ws) {
  if (mode === 'n') return nextUnquotedMode(c, prev, ws);
  const closed = closingMode(mode, c);
  if (!closed) return mode;
  if (mode === 'comment') ws.char(c, prev); // the newline ending a comment ends the word
  return closed;
}

function foldContinuations(text) {
  // Fast path: folding only ever removes a backslash-newline pair.
  if (!/\\\r?\n/.test(text)) return text;
  const out = [];
  const ws = new WordStart();
  let prev = '';
  let mode = 'n';
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '\\' && mode !== 'sq' && mode !== 'comment') {
      const { kept, width } = escapeAt(text, i, mode);
      if (kept) {
        out.push(kept);
        ws.word();
        prev = kept[kept.length - 1];
      }
      i += width;
      continue;
    }
    mode = nextMode(mode, c, prev, ws);
    out.push(c);
    prev = c;
    i += 1;
  }
  return out.join('');
}

/**
 * Generates a RegExp by prepending the anchor to the pattern source.
 *
 * Example:
 *   anchoredPattern('git\\s+commit\\b', 'i')
 *   → /(?:^|[;&|\n]\s*)git\s+commit\b/i
 *
 * @param {string} patternSrc - Regex source string to attach after anchor (string, not RegExp)
 * @param {string} [flags=''] - RegExp flags (i/g, etc.)
 * @returns {RegExp}
 */
export function anchoredPattern(patternSrc, flags = '') {
  return new RegExp(CMD_ANCHOR_SRC + patternSrc, flags);
}

/**
 * Strips git global options from `git <global-option...> <subcommand>` to normalize to `git <subcommand>`.
 *
 * Because anchored patterns require `git\s+<subcommand>` adjacency, global options like `-C <path>` / `-c k=v` /
 * `--git-dir=` / `--work-tree=` / `--no-pager` would otherwise bypass matching (e.g., `git -C x push --force`).
 * Cannot be stopped by anchors alone — this is an issue *between* `git` and its subcommand rather than command *boundaries*,
 * necessitating text normalization prior to applying patterns.
 * Subcommand options (e.g., -C in `git commit -C HEAD`) do not immediately follow `git` and remain unaffected.
 *
 * **Why located in lib (empirical 2026-08-09, DEBT-272)**: Previously existed only inside destructive-git-guard,
 * leaving commit-guard without this capability. As a result, `git -C <worktree> commit` (recommended to AI by R-CM-008 Rule 6)
 * allowed both direct trunk commits and `--amend` to slip through unhindered. Moved to shared lib to resolve this gap.
 * (`git-commit-target.mjs` already parsed `-C` correctly, but upstream patterns dropped out before reaching it.)
 *
 * @param {string} command
 * @returns {string}
 */
export function stripGitGlobalOptions(command) {
  if (!command || typeof command !== 'string') return command;
  // An option value is one shell word: an escape pair joins even a space to it (`-c a=\ b`), which
  // a plain `\S+` split into `a=\` + a bogus subcommand `b` (review round 8, 2026-09-28).
  const W = String.raw`(?:\\[\s\S]|[^\s\\])+`;
  const STEP = new RegExp(
    String.raw`\bgit\s+(?:-C\s+${W}|-C${W}|-c\s+${W}|--git-dir(?:=${W}|\s+${W})|--work-tree(?:=${W}|\s+${W})|--namespace(?:=${W}|\s+${W})|--no-pager|--paginate|--literal-pathspecs|--no-optional-locks|--bare)(\s+)`,
    'gi',
  );
  let prev;
  let out = command;
  do {
    prev = out;
    out = out.replace(STEP, 'git$1');
  } while (out !== prev);
  return out;
}
