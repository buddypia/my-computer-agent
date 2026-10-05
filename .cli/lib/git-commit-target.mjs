/**
 * git-commit-target.mjs — "Where does this Bash command's `git commit` land?" SSOT
 *
 * Consumers:
 *   - commit-guard (R-CM-008 blocks direct commit on main — deny direction)
 *   - worktree-session-owner-guard (R-CM-036 commit ownership — deny direction)
 *   - milestone-deck-warning (R-CM-030 Rule 12 commit-time reminder — advisory direction)
 *
 * v4 (2026-09-27): the answer is a *set* of directories the commit may run in, plus `unknown` when
 * the command can reach a directory this model cannot name. v1–v3 matched one `git … commit` and one
 * `cd`/assignment with regexes over the whole string and returned a single path. A regex has no idea
 * which statements actually ran before the commit, so every one of these was read as a worktree
 * commit while the shell committed on main (adversarial probe, 2026-09-27):
 *   `false && cd <wt>; git commit`    `cd <wt>-typo; git commit`    `true | W=<wt>; git -C $W commit`
 *   `if …; then W=<wt>; fi`           `W=<wt>; unset W`             `git -C <wt> commit; git commit`
 *   `git -C <wt> -C ../.. commit`     `GIT_DIR=<main>/.git git -C <wt> commit`   `pushd … popd`
 * The fix is a model, not more patterns: walk the statements the shell scanner (bash-segments.mjs)
 * already splits, and track what each one can do to the working directory and variables.
 *
 * Model (over-approximation — every uncertainty widens the set, so deny guards fail closed):
 *   - Per shell scope (top level, each `( … )`, each `$( … )`): `any` = states possible here,
 *     `ok` = states possible if the previous statement succeeded. `a && b` runs b from `ok`;
 *     `;` / newline / `||` / `&` run it from `any`.
 *   - `cd x` may fail: afterwards `any` holds both the old and the new directory, `ok` only the new.
 *   - Effects inside `if`/`while`/`for`/`{ }` may or may not happen (merged into the old state).
 *     A pipeline stage or a backgrounded statement runs in a subshell: its effects are dropped.
 *   - Variables: `NAME=value` / `export NAME=value` in order, `$NAME` expanded from earlier ones.
 *     Anything else that can set variables (`unset`, `read`, `declare -x`, `${X:=}`, `eval`, `source`, a
 *     `for` loop …) makes values unknown. A variable never assigned in the command is inherited → unknown.
 *   - Directory changes it cannot follow (`cd` with no/`-`/`~` target, `pushd`, `popd`, `source`, `eval`)
 *     make the directory unknown. So do `--git-dir` / `--work-tree` / `GIT_DIR`-family env (they move
 *     the repository independently of the directory).
 *   - A command word built at run time (`$(…)`, a backtick, bare `$X`) runs what it expands to: the
 *     directory and variables become unknown, and with a `commit` word (in it or in the substitution
 *     feeding it) it is a commit of unknown target. A git subcommand word is expanded; unknown = commit.
 *   - Whole-command unknowns: a heredoc body read by a shell (the scanner appends it out of order),
 *     `$( … )` inside an expanding heredoc body (same), function definitions, `trap`, `alias`, `case`.
 *   - Every `git … commit` invocation counts; `--dry-run` (as a real flag, not a message) excludes one.
 *
 * Known limits (threat model: an honest agent, not an adversary — a static model cannot fence a shell):
 * commands run through a string (`bash -c '…'`, `ssh`, `xargs sh -c`), scripts, an inherited `CDPATH`
 * or exported `GIT_DIR` from the parent environment. A quoted `'$X'` is read like `"$X"` (the shell
 * would pass the literal and git would fail — never a successful commit elsewhere).
 */

import { isAbsolute, join } from 'node:path';
import {
  prefixEffects,
  shellWords,
  splitShellSegments,
  ShellParseError,
  SUBST,
} from './bash-segments.mjs';
import {
  expandingHeredocBodies,
  heredocProgramBodies,
  stripCommandPrefix,
  stripHeredocData,
} from './heredoc-strip.mjs';
import { joinLineContinuations, WordStart } from './hook-anchors.mjs';

const QSTR = '__QSTR__';

/**
 * Replaces quoted strings with placeholder tokens — excludes data (message bodies) from evaluation.
 * Exported for commit-guard: flag/subcommand detection on the raw command let a commit *message*
 * containing "--dry-run" open the trunk/amend gate (guard bypass, observed 2026-08-26).
 */
export function stripQuoted(cmd) {
  // Escape-awareness is applied to double quotes ONLY, because that asymmetry is the shell's:
  // inside "..." a backslash escapes the quote, so the naive `"[^"]*"` stopped at \" and re-exposed
  // the rest of the message as command surface. Inside '...' POSIX gives backslash no meaning at all —
  // the next ' always terminates. Applying the escape-aware form to single quotes therefore
  // *over-consumed*: `git commit -m 'wip\' && git commit --amend` swallowed the chained amend into the
  // placeholder and the always-block amend gate passed it through (regression, caught in review 2026-08-26).
  // Outside quotes a backslash escapes one character, so it is its own alternative in the same
  // left-to-right scan: without it the escaped ' of the standard `'don'\''t'` idiom (shlex.quote)
  // opened a bogus quote pair and leaked the message tail — a `--dry-run` there opened the trunk and
  // amend gates (review round 5, 2026-09-28). Inside '...' the scan never reaches this alternative.
  // `$'...'` is ANSI-C quoting, where \' does not terminate.
  // A `#` at the start of a word opens a comment to end of line. Without it the `'` of `# don't`
  // paired with the next line's `# what's` and swallowed the command between them — `git checkout
  // -b` and `--amend` vanished from the gate (review round 6). The comment is dropped, the newline
  // kept. "Start of a word" is the shared WordStart rule (hook-anchors) — it needs paren nesting and
  // escape tracking, which is why this is a scan and not one regex (review rounds 7-8, 2026-09-28).
  let out = '';
  const ws = new WordStart();
  for (let i = 0; i < cmd.length; ) {
    const c = cmd[i];
    if (c === '\\') {
      out += cmd.slice(i, i + 2);
      if (!/[\r\n]/.test(cmd[i + 1] ?? '')) ws.word(); // a line continuation is not part of any word
      i += 2;
      continue;
    }
    if (c === '#' && ws.at) {
      const eol = cmd.indexOf('\n', i);
      i = eol === -1 ? cmd.length : eol;
      continue;
    }
    const quoted = quotedAt(cmd, i);
    if (quoted) {
      out += QSTR;
      ws.word();
      i += quoted;
      continue;
    }
    ws.char(c, cmd[i - 1]);
    out += c;
    i++;
  }
  return out;
}

/**
 * Is there an unquoted, unescaped `)` directly followed by `#`? Whether that `#` opens a comment
 * depends on which construct the `)` closes — a group ends the word, `$( … )` does not — and an
 * unpaired `)` (a `case` pattern `a)`, extglob `@(…)`) throws paren tracking off, so no scan short of
 * a parser can settle it (review round 9: `x=$(case y in a) : ;; esac)#foo; git commit --amend`).
 * Every other `#` is lexically certain: it follows a word character, an escape or a quote (data), or
 * a blank / operator (comment). A line continuation is invisible to the shell, so `)\<newline>#` counts.
 */
export function hasParenHash(cmd) {
  return parenHashes(cmd).length > 0;
}

/**
 * Indexes of every such `#`. Past one the scan reads it as data, which can only find more of them.
 */
export function parenHashes(cmd) {
  const found = [];
  let prev = '';
  let i = 0;
  while (i < cmd.length) {
    if (cmd[i] === '#') {
      if (prev === ')') found.push(i);
      else if (prev === '' || /[ \t\n;&|(<>]/.test(prev)) {
        const eol = cmd.indexOf('\n', i);
        if (eol === -1) return found;
        i = eol;
        continue;
      }
    }
    const [width, last] = lexeme(cmd, i);
    if (last !== null) prev = last;
    i += width;
  }
  return found;
}

/**
 * Width of the lexeme at `i` and the character it leaves as `prev`: an escape pair or quoted string
 * is word text ('w'); a `\<newline>` continuation leaves `prev` untouched (null).
 */
function lexeme(cmd, i) {
  if (cmd[i] === '\\') {
    const nl = /^\r?\n/.exec(cmd.slice(i + 1, i + 3));
    return nl ? [1 + nl[0].length, null] : [2, 'w'];
  }
  const quoted = quotedAt(cmd, i);
  return quoted ? [quoted, 'w'] : [1, cmd[i]];
}

const QUOTED_RES = [/\$'(?:\\.|[^'\\])*'/y, /"(?:\\.|[^"\\])*"/y, /'[^']*'/y];

/** Length of the complete quoted string starting at `i`, or 0 (an unterminated quote stays text). */
function quotedAt(cmd, i) {
  for (const re of QUOTED_RES) {
    re.lastIndex = i;
    const m = re.exec(cmd);
    if (m) return m[0].length;
  }
  return 0;
}

/** A directory or value this model cannot name. */
const UNK = Symbol('unknown');
const UNK_SET = new Set([UNK]);
/** Past this many alternatives a set collapses to unknown (keeps the product of variables bounded). */
const MAX_ALTERNATIVES = 16;

const OPENERS = new Set(['if', 'while', 'until', 'for', 'select', '{']);
const CLOSERS = new Set(['fi', 'done', '}']);
const RESERVED_LEAD = new Set([...OPENERS, ...CLOSERS, 'then', 'do', 'else', 'elif', '!']);
const DECLARERS = new Set(['export', 'readonly', 'declare', 'typeset', 'local']);
const VAR_WRITERS = new Set(['read', 'readarray', 'mapfile', 'getopts', 'let']);
const STATE_RUNNERS = new Set(['source', '.', 'eval']);
const REPO_ENV = new Set(['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR']);
/** git global options whose value is the next word. */
const GIT_VALUE_OPTS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env']);
/** `git commit` options whose value is the next word (so a `--dry-run` there is a message, not a flag). */
const COMMIT_VALUE_OPTS = new Set([
  '-m', '-F', '-C', '-c', '-t', '--message', '--file', '--template', '--reuse-message',
  '--reedit-message', '--author', '--date', '--fixup', '--squash', '--cleanup', '--trailer',
  '--pathspec-from-file',
]);
const ASSIGN_WORD_RE = /^([A-Za-z_]\w*)(\+?)=([\s\S]*)$/;
const VAR_REF_RE = /\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))/g;
const DEFAULT_ASSIGN_RE = /\$\{[A-Za-z_]\w*:?=/;
const FUNCTION_DEF_RE = /(?:^|[\s;&|(){}])(?:function\s+([A-Za-z_][\w.:-]*)|([A-Za-z_][\w.:-]*)\s*\(\s*\))/g;
const OPAQUE_WORDS = new Set(['trap', 'alias', 'shopt', 'case']);
const ANSI_C_RE = /\$'((?:\\.|[^'\\])*)'/g;
const ANSI_C_ESCAPES = { n: '\n', t: '\t', r: '\r', a: '\x07', b: '\b', e: '\x1b', E: '\x1b', f: '\f', v: '\v' };

function capped(set) {
  return set.has(UNK) || set.size > MAX_ALTERNATIVES ? UNK_SET : set;
}

function state(dirs, vars = new Map(), repoEnv = false) {
  return { dirs, vars, repoEnv };
}

/** Forgets every variable value: an unassigned variable already reads as unknown (inherited). */
function forgetVars(st, repoEnv = st.repoEnv) {
  return { ...st, vars: new Map(), repoEnv };
}

function merge(a, b) {
  if (a === b) return a;
  const vars = new Map();
  for (const name of new Set([...a.vars.keys(), ...b.vars.keys()])) {
    // Absent on one side = not assigned there = inherited, i.e. unknown.
    vars.set(name, capped(new Set([...(a.vars.get(name) ?? UNK_SET), ...(b.vars.get(name) ?? UNK_SET)])));
  }
  return state(capped(new Set([...a.dirs, ...b.dirs])), vars, a.repoEnv || b.repoEnv);
}

function withVar(st, name, values) {
  const vars = new Map(st.vars);
  vars.set(name, values);
  return { ...st, vars, repoEnv: st.repoEnv || REPO_ENV.has(name) };
}

/** All values a word can take in `st`, or UNK_SET. */
function expandWord(word, st) {
  if (word === undefined || word.includes(SUBST) || word.includes('`')) return UNK_SET;
  let outs = [''];
  let last = 0;
  for (const m of word.matchAll(VAR_REF_RE)) {
    const literal = word.slice(last, m.index);
    const values = st.vars.get(m[1] ?? m[2]) ?? UNK_SET;
    if (literal.includes('$') || values.has(UNK)) return UNK_SET;
    outs = outs.flatMap((o) => [...values].map((v) => o + literal + v));
    if (outs.length > MAX_ALTERNATIVES) return UNK_SET;
    last = m.index + m[0].length;
  }
  const tail = word.slice(last);
  return tail.includes('$') ? UNK_SET : new Set(outs.map((o) => o + tail));
}

/** Directories `word` names when resolved from each of `dirs`. */
function resolveDirs(word, dirs, st) {
  const out = new Set();
  for (const value of expandWord(word, st)) {
    if (value === UNK || value === '' || /^~|[*?[\]{}]/.test(value)) return UNK_SET;
    if (isAbsolute(value)) out.add(join(value));
    else for (const dir of dirs) out.add(dir === UNK ? UNK : join(dir, value));
  }
  return capped(out);
}

/** Applies leading assignment words (`A=1 B=$A`) in order. */
function assignAll(st, words) {
  let next = st;
  for (const word of words) {
    const m = ASSIGN_WORD_RE.exec(word);
    if (!m) continue;
    let values = expandWord(m[3], next);
    if (m[2] === '+') {
      const old = next.vars.get(m[1]) ?? UNK_SET;
      values = old.has(UNK) || values.has(UNK)
        ? UNK_SET
        : capped(new Set([...old].flatMap((o) => [...values].map((v) => o + v))));
    }
    next = withVar(next, m[1], values);
  }
  return next;
}

/** git global options up to the subcommand: `-C` values, whether the repository is moved, subcommand index. */
function gitGlobals(words) {
  const cs = [];
  let repoOverride = false;
  let i = 1;
  for (; i < words.length && words[i].startsWith('-'); i++) {
    const w = words[i];
    if (w === '--bare' || /^--(?:git-dir|work-tree)=?/.test(w)) repoOverride = true;
    if (!GIT_VALUE_OPTS.has(w)) continue;
    if (w === '-C') cs.push(words[i + 1]);
    i++;
  }
  return { cs, repoOverride, sub: i };
}

/** `--dry-run` as a flag of its own — not the value of `-m` & co., not after `--`. */
function isDryRun(args) {
  for (let j = 0; j < args.length && args[j] !== '--'; j++) {
    if (args[j] === '--dry-run') return true;
    if (COMMIT_VALUE_OPTS.has(args[j]) || /^-[a-zA-Z]*[mFCct]$/.test(args[j])) j++;
  }
  return false;
}

/**
 * `git [globals] commit [args]` → { cs: [-C values], repoOverride } or null (not a real commit).
 * The subcommand word is expanded like any other (`S=commit; git $S`), and one this model cannot
 * name (`git $(echo commit)`, an inherited `$S`) counts as a commit.
 */
function parseGitCommit(words, st) {
  if (words[0]?.split('/').pop() !== 'git') return null;
  const { cs, repoOverride, sub } = gitGlobals(words);
  if (words[sub] === undefined) return null;
  const subs = expandWord(words[sub], st);
  const commits = [...subs].some((v) => v === UNK || v.trim().split(/\s+/)[0] === 'commit');
  if (!commits || isDryRun(words.slice(sub + 1))) return null;
  return { cs, repoOverride };
}

/** Leading reserved words: how many blocks open/close here, and whether a `for`/`select` loop starts. */
function reservedLead(all) {
  let open = 0;
  let close = 0;
  let loopVar = false;
  for (const w of all) {
    if (!RESERVED_LEAD.has(w)) break;
    if (OPENERS.has(w)) open++;
    if (CLOSERS.has(w)) close++;
    if (w === 'for' || w === 'select') loopVar = true;
  }
  return { open, close, loopVar };
}

/** `cd [-LPe@] [--] dir`: may fail, so the old directory survives on the failure side. */
function cdEffect(args, st, temp) {
  let rest = args;
  while (/^-[LPe@]+$/.test(rest[0] ?? '')) rest = rest.slice(1);
  if (rest[0] === '--') rest = rest.slice(1);
  const to = rest[0];
  const relativeCdpath = temp.vars.has('CDPATH') && to && !isAbsolute(to);
  const dirs = !to || to === '-' || relativeCdpath ? UNK_SET : resolveDirs(to, st.dirs, st);
  return { ok: { ...st, dirs }, fail: st };
}

const same = (next) => ({ ok: next, fail: next });

/** Builtins that change the directory or variables, by name → (args, st, temp) → { ok, fail }. */
const BUILTIN_EFFECTS = new Map([
  ['cd', cdEffect],
  ['pushd', (_args, st) => ({ ok: { ...st, dirs: UNK_SET }, fail: st })],
  ['popd', (_args, st) => ({ ok: { ...st, dirs: UNK_SET }, fail: st })],
  ...[...STATE_RUNNERS].map((name) => [name, (_args, st) => same({ ...forgetVars(st, true), dirs: UNK_SET })]),
  ...[...DECLARERS].map((name) => [
    name,
    (args, st) => {
      const plain = args.every((w) => ASSIGN_WORD_RE.test(w) || /^[A-Za-z_]\w*$/.test(w));
      return same(plain ? assignAll(st, args) : forgetVars(st, true));
    },
  ]),
  [
    'unset',
    (args, st) => same(args.filter((w) => /^[A-Za-z_]\w*$/.test(w)).reduce((n, w) => withVar(n, w, UNK_SET), st)),
  ],
  ...[...VAR_WRITERS].map((name) => [name, (_args, st) => same(forgetVars(st))]),
  ['printf', (args, st) => same(args.includes('-v') ? forgetVars(st) : st)],
]);

/**
 * A command word built at run time: a substitution, or an expansion in the name itself (`$X`, `$A$B`,
 * `"$@"`). `$HOME/bin/tool` stays a path — the expansion is in the directory, the name is literal.
 */
function isDynamicCommand(word) {
  return word !== undefined && (word.includes(SUBST) || word.split('/').pop().includes('$'));
}

/**
 * `$'...'` rewritten as the plain quote the shell reads it as: `gi$'t'` is `git`, `$'\x63ommit'` is
 * `commit`. The scanner knows only '…' and "…", so it kept the `$` and hid the name. A value holding
 * a quote is left alone — rewriting it would change where the word ends.
 */
function decodeAnsiC(text) {
  return text.replace(ANSI_C_RE, (whole, body) => {
    const value = body.replace(/\\(x[\da-fA-F]{1,2}|u[\da-fA-F]{1,4}|[0-7]{1,3}|.)/g, (_, e) => {
      if (/^[xu]/.test(e)) return String.fromCodePoint(parseInt(e.slice(1), 16));
      if (/^[0-7]/.test(e)) return String.fromCodePoint(parseInt(e, 8));
      return ANSI_C_ESCAPES[e] ?? e;
    });
    return value.includes("'") ? whole : `'${value}'`;
  });
}

/** Names of the shell functions the command defines — calling one runs a body this model does not follow. */
function definedFunctions(text) {
  return new Set([...text.matchAll(FUNCTION_DEF_RE)].map((m) => m[1] ?? m[2]));
}

/** A statement's words without a leading `function NAME [()]`, so its `{ body` is read as statements. */
function statementWords(raw) {
  const all = shellWords(decodeAnsiC(raw));
  if (all[0] !== 'function' || all.length < 2) return all;
  return all.slice(all[2] === '()' ? 3 : 2);
}

/** Whether `word` is, or expands in `st` to something holding, the word `commit`. */
function namesCommit(word, st) {
  if (word === 'commit') return true;
  return [...expandWord(word, st)].some((v) => v !== UNK && v.split(/\s+/).includes('commit'));
}

/** Where `git commit` runs: the statement's directories moved by each `-C`, unknown if the repo moves. */
function commitDirs(commit, dirs, st, temp, prefix) {
  const moved = commit.repoOverride || temp.repoEnv || prefix.some((w) => REPO_ENV.has(w.split('=')[0]));
  if (moved) return UNK_SET;
  return commit.cs.reduce((targets, c) => resolveDirs(c, targets, st), dirs);
}

/** How many `$( … )` / backticks a word holds. */
const substCount = (word) => word.split(SUBST).length - 1;
/** A word that is only substitutions or one bare variable — it may expand to nothing at all. */
const PURE_DYNAMIC_RE = new RegExp(`^(?:(?:${SUBST})+|\\$(?:\\{[A-Za-z_]\\w*\\}|[A-Za-z_]\\w*))$`);

/**
 * Text of the substitutions that build the command name: the first word, and — while the words before
 * it may expand to nothing (`$(true) $(echo git commit)`) — the ones after it. A substitution in an
 * argument (`$(npm bin)/eslint "$(echo fix commit)"`) is data, not the command.
 */
function commandSubstText(all, words, substs) {
  let skip = 0;
  for (const w of all.slice(0, all.length - words.length)) skip += substCount(w);
  let take = 0;
  for (const w of words) {
    take += substCount(w);
    if (!PURE_DYNAMIC_RE.test(w)) break;
  }
  return substs.slice(skip, skip + take).join('\n');
}

/** A name whose value is known is that command (`G=git; $G -C <wt> commit`), word-split like the shell. */
function resolveCommandName(words, st) {
  if (!isDynamicCommand(words[0])) return words;
  const values = expandWord(words[0], st);
  if (values.size !== 1 || values.has(UNK)) return words;
  return [...[...values][0].split(/\s+/).filter(Boolean), ...words.slice(1)];
}

/**
 * The shell runs whatever the word expands to: `$(echo cd /m)` moves this shell, `$(echo git) commit` /
 * `$(echo git commit)` / a function wrapping git commit. None is nameable, so directory and variables are
 * lost and a `commit` word — here or in the substitution feeding it — is a commit. The repository is
 * *not* presumed moved: that stuck for the rest of the command and denied `$PY x && git -C <wt> commit`,
 * a form the rules recommend. Only a statement that names a GIT_DIR-family variable can move it.
 */
function runDynamic(seg, all, words, input, substs) {
  const text = [seg.raw, ...substs].join('\n');
  const repoEnv = input.repoEnv || [...REPO_ENV].some((name) => text.includes(name));
  const lost = { ...forgetVars(input, repoEnv), dirs: UNK_SET };
  const commits =
    words.some((w) => namesCommit(w, input)) || /\bcommit\b/.test(commandSubstText(all, words, substs));
  return { ok: lost, fail: lost, targets: commits ? UNK_SET : null };
}

/**
 * What one statement does when it runs from `input`: `ok` (it succeeded), `fail` (it failed, or null
 * when it cannot fail), `targets` (commit directories, or null when it is not a commit).
 */
function runStatement(seg, input, substs, fns) {
  const all = statementWords(seg.raw);
  let words = stripCommandPrefix(all);
  const prefix = all.slice(0, all.length - words.length);
  while (words[0] === 'builtin') words = words.slice(1);
  const st = reservedLead(all).loopVar || DEFAULT_ASSIGN_RE.test(seg.raw) ? forgetVars(input) : input;
  words = resolveCommandName(words, st);
  if (isDynamicCommand(words[0]) || fns.has(words[0])) return runDynamic(seg, all, words, input, substs);
  // `A=1 cmd`: A is in cmd's environment only. The shell expands cmd's own words *before* that, so
  // `R=<wt> git -C $R commit` passes the inherited R — words resolve against `st`, never `temp`.
  const temp = assignAll(st, prefix);
  if (!words.length) return { ok: temp, fail: null, targets: null }; // bare assignments persist

  const commit = parseGitCommit(words, st);
  if (commit) {
    const effects = prefixEffects(prefix);
    let dirs = effects.chdir === null ? st.dirs : resolveDirs(effects.chdir, st.dirs, st);
    if (effects.opaque) dirs = UNK_SET;
    return { ok: st, fail: st, targets: commitDirs(commit, dirs, st, temp, prefix) };
  }
  const effect = BUILTIN_EFFECTS.get(words[0].split('/').pop());
  return { ...(effect ? effect(words.slice(1), st, temp) : same(st)), targets: null };
}

/** Index of the next statement in the same scope, per statement (`-1` when none). */
function nextInScope(segs) {
  const next = new Array(segs.length).fill(-1);
  const pending = new Map();
  segs.forEach((seg, i) => {
    if (pending.has(seg.scope)) next[pending.get(seg.scope)] = i;
    pending.set(seg.scope, i);
  });
  return next;
}

const isPipe = (sep) => sep === '|' || sep === '|&';

/** The state of the scope `seg` runs in, created from its parent on the scope's first statement. */
function scopeOf(seg, top, scopes) {
  if (seg.scopeKind === 'top') return top;
  let sc = scopes.get(seg.scope);
  if (sc) return sc;
  // A substitution in the first statement of a scope arrives before that scope's own statements:
  // its parent state is then the top level's (a superset of what the parent would have had).
  const parent = scopes.get(seg.parentScope) ?? top;
  const chained = seg.scopeKind === 'group' && seg.sep === '&&';
  // A `( … )` is one statement of its parent: after it, "previous succeeded" says nothing more.
  if (seg.scopeKind === 'group' && !chained) parent.ok = parent.any;
  const from = chained ? parent.ok : parent.any;
  sc = { any: from, ok: from, blocks: 0 };
  scopes.set(seg.scope, sc);
  return sc;
}

/** Moves a scope past one statement that ran from `input` with result `run`. */
function advance(sc, sep, nextSep, input, run, maybe) {
  if (isPipe(sep) || isPipe(nextSep) || nextSep === '&') {
    // Pipeline stage / background job: runs in a subshell and leaves this shell as it was. The
    // pipeline is one statement of the chain — its first stage decides where it ran from.
    if (!isPipe(sep)) sc.ok = input;
    return;
  }
  const conditional = sep === '&&' || sep === '||' || maybe;
  const after = run.fail ? merge(run.ok, run.fail) : run.ok;
  const ok = sep === '||' ? merge(run.ok, sc.ok) : run.ok;
  sc.any = conditional ? merge(after, sc.any) : after;
  sc.ok = maybe ? merge(ok, sc.any) : ok;
}

/**
 * Every directory the command's `git commit` invocations may run in.
 *
 * @param {string} cmd Bash command
 * @param {string|null} cwd Directory the command starts in (unknown when absent)
 * @returns {{bases: string[], unknown: boolean} | null} null when the command runs no `git commit`
 */
export function commitTargets(cmd, cwd) {
  if (!cmd || typeof cmd !== 'string') return null;
  let segs;
  try {
    segs = splitShellSegments(cmd);
  } catch (err) {
    if (!(err instanceof ShellParseError)) throw err;
    return /\bcommit\b/.test(stripQuoted(cmd)) ? { bases: [], unknown: true } : null;
  }

  const start = state(cwd ? new Set([cwd]) : UNK_SET);
  const top = { any: start, ok: start, blocks: 0 };
  const scopes = new Map(); // scope id → { any, ok, blocks }
  const next = nextInScope(segs);
  const targets = new Set();
  let commits = 0;
  let opaque = false;
  // Substitutions reach the scanner before the statement they feed. Per substitution scope: its parent
  // scope and its text; a statement's own are the ones whose parent is its scope, in order.
  let substScopes = new Map();
  // Heredoc data is a message, not code: `fix getUser()` in a commit body defines nothing.
  const code = stripHeredocData(joinLineContinuations(cmd));
  const fns = definedFunctions(stripQuoted(code));
  const substTextOf = (scope) =>
    [substScopes.get(scope).text, ...[...substScopes].filter(([, s]) => s.parent === scope).map(([id]) => substTextOf(id))].join('\n');

  segs.forEach((seg, i) => {
    const sc = scopeOf(seg, top, scopes);
    const all = statementWords(seg.raw);
    if (OPAQUE_WORDS.has(stripCommandPrefix(all)[0])) opaque = true;
    const lead = reservedLead(all);
    sc.blocks += lead.open;
    const maybe = sc.blocks > 0;
    sc.blocks = Math.max(0, sc.blocks - lead.close);

    const input = seg.sep === '&&' && !maybe ? sc.ok : sc.any;
    const own = [...substScopes].filter(([, s]) => s.parent === seg.scope).map(([id]) => substTextOf(id));
    const run = runStatement(seg, input, own, fns);
    if (seg.scopeKind !== 'subst') substScopes = new Map();
    else {
      const s = substScopes.get(seg.scope) ?? { parent: seg.parentScope, text: '' };
      substScopes.set(seg.scope, { ...s, text: `${s.text}\n${seg.raw}` });
    }
    if (run.targets) {
      commits++;
      for (const t of run.targets) targets.add(t);
    }
    advance(sc, seg.sep, next[i] >= 0 ? segs[next[i]].sep : '', input, run, maybe);
  });

  // A body this walk did not reach as statements (a definition inside `if`/`while`, or nested in
  // another) still runs when called: with a function defined, any `commit` word is a commit.
  if (commits === 0) {
    const words = decodeAnsiC(code).replace(/["'\\]/g, '');
    return fns.size > 0 && /\bcommit\b/.test(words) ? { bases: [], unknown: true } : null;
  }
  const joined = joinLineContinuations(cmd);
  const unordered =
    heredocProgramBodies(joined).length > 0 ||
    expandingHeredocBodies(joined).some((body) => /\$\(|`/.test(body));
  const unknown = opaque || unordered || fns.size > 0 || targets.has(UNK);
  return { bases: [...targets].filter((t) => t !== UNK), unknown };
}

/**
 * Whether every place the command commits satisfies `predicate` — false when it may commit somewhere
 * this model cannot name, and false when it commits nowhere. The deny guards' "is this a worktree
 * commit" question.
 */
export function everyCommitTarget(cmd, cwd, predicate) {
  const t = commitTargets(cmd, cwd);
  return Boolean(t && !t.unknown && t.bases.length > 0 && t.bases.every(predicate));
}
