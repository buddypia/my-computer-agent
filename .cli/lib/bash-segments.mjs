/**
 * bash-segments.mjs - Quote-aware split of a Bash tool command into the simple commands it runs,
 * plus the directories and paths each one acts on.
 *
 * Consumers: worktree-policy-guard (opt-in `trunk_bash_allowlist`) and worktree-session-owner-guard
 * (opt-in `session_owner_scope: "all_bash"`). Both answer a per-command question ("is this command
 * allowed on trunk?", "which worktree does this command touch?"), so both need every command, not
 * the first match. An earlier version of these checks matched `cd`/`-C` with
 * one regex over the whole string and only saw the first occurrence (`cd a && cd .worktrees/b`).
 *
 * Why a scanner and not `COMMAND_BOUNDARY_RE` (hook-anchors.mjs): that regex reads a `;` inside
 * quotes as a separator and does not split on a bare `&` (background). For an *allowlist* both are
 * holes, not just noise: `ls & cargo build` would be judged by `ls` alone. The scanner splits on
 * `; && || | & newline ( )` outside quotes, lifts `$( … )`, backticks and `<( … )`/`>( … )` bodies
 * into their own segments (the shell runs them), and flags an output redirect to a file.
 *
 * Pre-processing reuses the shared shell-grammar helpers: `joinLineContinuations` (a `\<newline>` is
 * not a separator), `stripHeredocData` (a heredoc body read by a data tool is dropped; a body read
 * by a shell comes back as commands), `expandingHeredocBodies` (substitutions inside an
 * unquoted-delimiter body run even when the body is data) and `stripCommandPrefix` (wrappers such
 * as `env` / `sudo` / `command` / `time` / `xargs` are unwrapped to the command they run).
 *
 * Working directory semantics (`walkSegments`):
 *   - `cd` moves later commands only while every separator since the `cd` is `&&`. After `;`,
 *     `||`, `|`, `&` or a newline the `cd` may have failed, so the directory is marked uncertain
 *     (`cwdCertain: false`) — consumers that exempt worktree commands must not trust it.
 *   - A `cd` inside `( … )` or a substitution does not outlive it.
 *   - `git -C` / `make -C` fold cumulatively (`-C a -C ../b` → `b`); `effectiveDir` is the result.
 *
 * Nesting deeper than MAX_NESTING (`$(` / `<(` / backticks) throws ShellParseError instead of
 * recursing until the stack overflows — an opted-in guard fails closed on it.
 *
 * Prefix effects (`prefixEffects`): `NAME=value` assignment names, `env -C <dir>` (a one-command
 * cd, folded into `dirs`), `time -o <file>` (a file write, reported as `redirect`) and
 * `env -S '<cmd>'` (a string run as the command, reported as `opaque`).
 *
 * Threat model: an honest agent that over-generalises, not a malicious one — a static scanner cannot
 * fence a shell completely. Known limits (stated rather than hidden): `for`/`case`/`while` loop
 * headers, `eval`, interpreter payloads and scripts (`bash -c`, `node -e`, `python -c`, a script path)
 * are opaque — the segment is judged by its command word only; write-by-argument tools (`dd of=`)
 * are not modelled as writes; tools that execute project config (make targets, cargo build
 * scripts) run whatever the config says; an inherited `CDPATH` (not assigned in the command) changes
 * where `cd` goes; paths are resolved textually here (callers realpath where it matters).
 */

import { isAbsolute, join, relative } from 'node:path';
import { joinLineContinuations, stripGitGlobalOptions } from './hook-anchors.mjs';
import {
  expandingHeredocBodies,
  stripCommandPrefix,
  stripHeredocData,
} from './heredoc-strip.mjs';

/** Placeholder left in the outer segment where a command substitution was lifted out. */
export const SUBST = '__SUBST__';

/** Deepest `$(` / `<(` / backtick nesting scanned before giving up (ShellParseError). */
export const MAX_NESTING = 64;

/** Scope ids are per `splitShellSegments` call: a counter kept on the output array itself. */
const SCOPE_SEQ = Symbol('scopeSeq');
function nextScope(out) {
  out[SCOPE_SEQ] = (out[SCOPE_SEQ] ?? 0) + 1;
  return out[SCOPE_SEQ];
}

/** The command could not be scanned safely; opted-in guards deny on it. */
export class ShellParseError extends Error {}

/** Segments made only of these words run nothing (`fi`, `done` after a `;`). */
const CLOSING_RESERVED = new Set(['}', 'fi', 'done', 'esac']);

/** Index just past the quoted string opening at `i` (backslash escapes only inside "…"). */
function skipQuoted(text, i) {
  const q = text[i];
  for (let j = i + 1; j < text.length; j++) {
    if (q === '"' && text[j] === '\\') j++;
    else if (text[j] === q) return j + 1;
  }
  return text.length;
}

/**
 * Index just past the `)` closing the `(` at `open`, respecting quotes and nesting.
 * Unbalanced input returns text.length (the rest is taken as the body — conservative).
 */
function closeParen(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; ) {
    const c = text[i];
    if (c === "'" || c === '"') {
      i = skipQuoted(text, i);
      continue;
    }
    if (c === '\\') {
      i += 2;
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return i + 1;
    i++;
  }
  return text.length;
}

/** Index of the backtick closing the one at `open` (escape-aware), or text.length. */
function closeBacktick(text, open) {
  for (let i = open + 1; i < text.length; i++) {
    if (text[i] === '\\') i++;
    else if (text[i] === '`') return i;
  }
  return text.length;
}

/**
 * Does the `>` at `i` write to a file? `2>&1` / `>&2` (fd duplication) and `/dev/null` do not.
 * `>(…)` is process substitution, handled by the caller.
 */
function redirectWritesFile(text, i) {
  let j = i + 1;
  if (text[j] === '>' || text[j] === '|') j++;
  while (text[j] === ' ' || text[j] === '\t') j++;
  if (text[j] === '&' && /[0-9-]/.test(text[j + 1] || '')) return false;
  const target = /^[^\s;&|()]*/.exec(text.slice(j))[0].replace(/^["']|["']$/g, '');
  return target !== '/dev/null';
}

/**
 * Last characters of a segment's text after which a `#` starts a comment. No `(` / `)`: a group
 * paren starts a fresh segment, and the only `)` left in segment text closes `$(( … ))`.
 */
const WORD_BREAK_RE = /[ \t\n;&|<>]/; // bash blanks only: see hook-anchors#WORD_BREAK_RE

/**
 * Core scanner (no pre-processing). Appends segments of `text` to `out`.
 * Each segment: { raw, redirect, depth, group, sep, scope, parentScope, scopeKind }
 *   - depth > 0: ran inside a substitution
 *   - group > 0: ran inside a `( … )` subshell
 *   - sep: the separator before it at the same scan level (`''` for the first)
 *   - scope: id of the shell it ran in — each substitution and each `( … )` gets a fresh one, so
 *     `(cd a) && git commit` and `(cd a && git commit)` differ (they share depth/group numbers).
 *     parentScope: the enclosing scope (null at the top); scopeKind: 'top' | 'subst' | 'group'.
 * Every step method takes the current index and returns the next one.
 */
class Scanner {
  constructor(text, out, depth, group = 0, parentScope = null, scopeKind = 'top') {
    if (depth > MAX_NESTING) throw new ShellParseError(`nesting deeper than ${MAX_NESTING}`);
    this.text = text;
    this.out = out;
    this.depth = depth;
    this.group = group;
    this.scope = nextScope(out);
    this.parentScope = parentScope;
    this.scopeKind = scopeKind;
    this.scopeStack = [];
    this.sep = '';
    this.mode = 'n'; // n | sq | dq | comment
    this.cur = this.fresh();
  }

  fresh() {
    const { depth, group, scope, parentScope, scopeKind } = this;
    return { raw: '', redirect: false, depth, group, scope, parentScope, scopeKind };
  }

  push() {
    const raw = this.cur.raw.trim();
    if (raw) this.out.push({ ...this.cur, raw, sep: this.sep });
    this.cur = this.fresh();
  }

  run() {
    let i = 0;
    while (i < this.text.length) i = this.step(i);
    this.push();
    return this.out;
  }

  step(i) {
    const c = this.text[i];
    if (this.mode === 'comment') {
      if (c === '\n') {
        this.mode = 'n';
        return this.separator(i, 1);
      }
      return i + 1;
    }
    if (this.mode === 'sq') return this.quoted(i, "'");
    if (c === '\\') {
      this.cur.raw += this.text.slice(i, i + 2);
      this.escapeEnd = { seg: this.cur, at: this.cur.raw.length };
      return i + 2;
    }
    // Command substitution runs in both unquoted and double-quoted context.
    if (c === '$' && this.text[i + 1] === '(') return this.dollarParen(i);
    if (c === '`') {
      const end = closeBacktick(this.text, i);
      return this.lift(end + 1, i + 1, end);
    }
    if (this.mode === 'dq') return this.quoted(i, '"');
    return this.unquoted(i);
  }

  quoted(i, close) {
    this.cur.raw += this.text[i];
    if (this.text[i] === close) this.mode = 'n';
    return i + 1;
  }

  /** Scans a substitution body as its own segments and leaves a placeholder in this one. */
  lift(resume, bodyStart, bodyEnd) {
    new Scanner(this.text.slice(bodyStart, bodyEnd), this.out, this.depth + 1, this.group, this.scope, 'subst').run();
    this.cur.raw += SUBST;
    return resume;
  }

  dollarParen(i) {
    const end = closeParen(this.text, i + 1);
    if (this.text[i + 2] !== '(') return this.lift(end, i + 2, end - 1);
    this.cur.raw += this.text.slice(i, end); // `$(( … ))` arithmetic runs no command
    return end;
  }

  /** Unquoted character: a special-character handler may consume it, else it is plain text. */
  unquoted(i) {
    const c = this.text[i];
    const handler = UNQUOTED_HANDLERS[c];
    const next = handler ? handler.call(this, i) : null;
    if (next !== null) return next;
    if (c === '>' && redirectWritesFile(this.text, i)) this.cur.redirect = true;
    this.cur.raw += c;
    return i + 1;
  }

  openQuote(i) {
    this.mode = this.text[i] === "'" ? 'sq' : 'dq';
    this.cur.raw += this.text[i];
    return i + 1;
  }

  /**
   * `#` starts a comment only at the start of a word. Judged on the segment built so far, not the
   * source text: a `)` closing `$( … )` / `<( … )` / `$(( … ))` continues the word (`$(true)#x` →
   * `#x`), while a group `)` already started a fresh segment (review round 7, 2026-09-28). An escape
   * pair continues the word even when it escapes a break character (`a\ #x` → `a #x`, round 8).
   */
  hash(i) {
    const raw = this.cur.raw;
    const escaped = this.escapeEnd?.seg === this.cur && this.escapeEnd.at === raw.length;
    if (escaped || (/[^ \t\n]/.test(raw) && !WORD_BREAK_RE.test(raw[raw.length - 1]))) return null;
    this.mode = 'comment';
    return i + 1;
  }

  /** `<( … )` / `>( … )` process substitution runs its body; a bare `<` / `>` is a redirect. */
  angle(i) {
    if (this.text[i + 1] !== '(') return null;
    const end = closeParen(this.text, i + 1);
    return this.lift(end, i + 2, end - 1);
  }

  /** Ends the current segment; `op` is recorded as the next segment's `sep`. */
  separator(i, width) {
    this.push();
    this.sep = this.text.slice(i, i + width);
    return i + width;
  }

  pipe(i) {
    const next = this.text[i + 1];
    return this.separator(i, next === '|' || next === '&' ? 2 : 1);
  }

  subshell(i) {
    const delta = this.text[i] === '(' ? 1 : -1;
    this.push();
    this.group = Math.max(0, this.group + delta);
    if (delta > 0) {
      this.scopeStack.push([this.scope, this.parentScope, this.scopeKind]);
      [this.scope, this.parentScope, this.scopeKind] = [nextScope(this.out), this.scope, 'group'];
    } else if (this.scopeStack.length) {
      [this.scope, this.parentScope, this.scopeKind] = this.scopeStack.pop();
    }
    this.cur = this.fresh();
    return i + 1;
  }

  /** `&&` separates, `>&` / `<&` / `&>` are redirections, a lone `&` backgrounds (separates). */
  ampersand(i) {
    const next = this.text[i + 1];
    if (next === '&') return this.separator(i, 2);
    const prev = this.text[i - 1];
    if (prev === '>' || prev === '<' || next === '>') {
      this.cur.raw += '&';
      return i + 1;
    }
    return this.separator(i, 1);
  }
}

/** Special unquoted characters → Scanner method; a method returning null leaves the char as text. */
const P = Scanner.prototype;
function singleSeparator(i) {
  return this.separator(i, 1);
}
const UNQUOTED_HANDLERS = {
  "'": P.openQuote,
  '"': P.openQuote,
  '#': P.hash,
  '<': P.angle,
  '>': P.angle,
  '(': P.subshell,
  ')': P.subshell,
  '\n': singleSeparator,
  ';': singleSeparator,
  '|': P.pipe,
  '&': P.ampersand,
};

/**
 * Lifts `$( … )` / backtick bodies out of an expanding heredoc body. The body itself is data; only
 * the substitutions in it run.
 */
function liftBodySubstitutions(body, out) {
  for (let i = 0; i < body.length; i++) {
    if (body[i] === '\\') {
      i++;
    } else if (body[i] === '$' && body[i + 1] === '(' && body[i + 2] !== '(') {
      const end = closeParen(body, i + 1);
      new Scanner(body.slice(i + 2, end - 1), out, 1, 0, null, 'subst').run();
      i = end - 1;
    } else if (body[i] === '`') {
      const end = closeBacktick(body, i);
      new Scanner(body.slice(i + 1, end), out, 1, 0, null, 'subst').run();
      i = end;
    }
  }
}

/**
 * Splits a Bash command into the simple commands the shell runs.
 * Throws ShellParseError when nesting exceeds MAX_NESTING.
 *
 * @param {string} command
 * @returns {Array<{raw: string, redirect: boolean, depth: number, group: number, sep: string}>}
 */
export function splitShellSegments(command) {
  if (typeof command !== 'string' || !command.trim()) return [];
  const joined = joinLineContinuations(command);
  const out = new Scanner(stripHeredocData(joined), [], 0).run();
  for (const body of expandingHeredocBodies(joined)) liftBodySubstitutions(body, out);
  return out;
}

/** One shell word: runs of plain characters, escapes, and quoted strings with no whitespace between. */
const WORD_RE = /(?:[^\s'"\\]+|\\.?|'[^']*'?|"(?:\\.|[^"\\])*"?)+/g;
/** Pieces of one word, for unquoting: a quoted string, an escape, or plain text. */
const PIECE_RE = /'([^']*)'?|"((?:\\.|[^"\\])*)"?|\\(.?)|([^'"\\]+)/g;

/** Quote-aware word split; quotes are removed, escapes resolved. */
export function shellWords(raw) {
  return (raw.match(WORD_RE) || []).map((word) =>
    word.replace(PIECE_RE, (_, sq, dq, esc, plain) =>
      sq ?? (dq !== undefined ? dq.replace(/\\(.)/g, '$1') : (esc ?? plain)),
    ),
  );
}

/**
 * Splits a segment into its prefix (env assignments, reserved words, wrappers and their options)
 * and the words from the command word on (`[]` when nothing runs).
 */
function splitPrefix(raw) {
  const all = shellWords(raw);
  const rest = stripCommandPrefix(all);
  const prefix = all.slice(0, all.length - rest.length);
  return { prefix, words: rest.every((w) => CLOSING_RESERVED.has(w)) ? [] : rest };
}

/**
 * Words from the command word on: env assignments, reserved words (`then`, `if` …) and wrappers
 * (`env`, `sudo`, `command`, `time`, `xargs` …, via heredoc-strip's list) removed.
 */
export function commandWords(raw) {
  return splitPrefix(raw).words;
}

/** Wrapper options that change the directory (`env -C d`) or write a file (`time -o f`). */
const WRAPPER_EFFECTS = {
  env: { short: '-C', long: '--chdir', effect: 'chdir' },
  time: { short: '-o', long: '--output', effect: 'writes' },
};

/** Value of `short`/`long` at prefix[i] (`-C d`, `-Cd`, `--chdir d`, `--chdir=d`), or undefined. */
function optionValue(prefix, i, { short, long }) {
  const w = prefix[i];
  if (w === short || w === long) return prefix[i + 1] ?? '';
  if (w.startsWith(`${long}=`)) return w.slice(long.length + 1);
  if (w.length > 2 && w.startsWith(short)) return w.slice(2);
  return undefined;
}

/**
 * What a segment's prefix does besides naming the command:
 *   - assigns: names of `NAME=value` assignments (`GIT_DIR=x git …`, `env GIT_WORK_TREE=x …`)
 *   - chdir:   `env -C <dir>` / `--chdir` — the command runs there (last one wins); null if none
 *   - writes:  a wrapper option that writes a file (`time -o f`)
 */
export function prefixEffects(prefix) {
  const out = { assigns: [], chdir: null, writes: false, opaque: envSplitString(prefix) };
  let wrapper = null;
  for (let i = 0; i < prefix.length; i++) {
    const w = prefix[i];
    const assign = /^([A-Za-z_][A-Za-z0-9_]*)\+?=/.exec(w);
    if (assign) {
      out.assigns.push(assign[1]);
      continue;
    }
    wrapper = WRAPPER_EFFECTS[w.split('/').pop()] ?? wrapper;
    const value = wrapper ? optionValue(prefix, i, wrapper) : undefined;
    if (value !== undefined && wrapper.effect === 'chdir') out.chdir = value;
    else if (value !== undefined) out.writes = true;
  }
  return out;
}

/** `env -S '<cmd>'` / `--split-string` runs a string as the command — opaque to this scanner. */
function envSplitString(prefix) {
  const envAt = prefix.findIndex((w) => w.split('/').pop() === 'env');
  return envAt >= 0 && prefix.slice(envAt + 1).some((w) => /^-S/.test(w) || w.startsWith('--split-string'));
}

/**
 * Command text for pattern matching: words re-joined (quotes removed) with git global options
 * stripped, so `git -C /x --no-pager log` is judged as `git log`.
 */
export function commandText(words) {
  return stripGitGlobalOptions(words.join(' '));
}

/** A word to resolve as a path: path-like, or something that expands (`$X`, `~`). */
function isPathCandidate(value) {
  return looksLikePath(value) || value.includes('$') || value.startsWith('~');
}

/** Brace / glob expansion can turn `..` into anything (`{.,../..}`, `../*`): not resolvable. */
const EXPANDING_UP_RE = /\.\..*[{}[\]*?]|[{}[\]*?].*\.\./;

function toAbs(raw, base) {
  if (!raw || raw.includes(SUBST) || raw.startsWith('~') || raw.includes('$')) return null;
  if (EXPANDING_UP_RE.test(raw)) return null;
  if (isAbsolute(raw)) return join(raw);
  return base ? join(base, raw) : null;
}

/** Value of a directory option at words[i], or undefined when words[i] is not one. */
function dirOptionAt(words, i, attachedPrefix, longName) {
  const w = words[i];
  if (w === attachedPrefix || w === longName) return { dir: words[i + 1], width: 2 };
  if (longName && w.startsWith(`${longName}=`)) return { dir: w.slice(longName.length + 1), width: 1 };
  if (w.length > attachedPrefix.length && w.startsWith(attachedPrefix)) {
    return { dir: w.slice(attachedPrefix.length), width: 1 };
  }
  return undefined;
}

/** git global options that take a separate value (skipped while looking for `-C`). */
const GIT_VALUE_OPTIONS = new Set(['-c', '--git-dir', '--work-tree', '--namespace']);

/**
 * Folds directory options cumulatively (each relative to the previous, as git and make do).
 * Returns every intermediate directory; the last one is where the command runs. An unresolvable
 * value makes the rest unknown (`[..., null]`).
 */
function foldDirs(words, cwd, { onlyLeadingOptions, longName }) {
  const out = [];
  let base = cwd;
  for (let i = 1; i < words.length; ) {
    if (onlyLeadingOptions && !words[i].startsWith('-')) break;
    const opt = dirOptionAt(words, i, '-C', longName);
    if (opt) {
      base = base === null ? null : toAbs(opt.dir, base);
      out.push(base);
      i += opt.width;
    } else {
      i += onlyLeadingOptions && GIT_VALUE_OPTIONS.has(words[i]) ? 2 : 1;
    }
  }
  return out;
}

/**
 * Directories a command explicitly acts on (`git -C` global options, `make -C` / `--directory`
 * anywhere), folded cumulatively. `null` entries mean "could not resolve".
 */
export function directoryOptions(words, cwd) {
  if (words[0] === 'git') return foldDirs(words, cwd, { onlyLeadingOptions: true, longName: null });
  if (words[0] === 'make') return foldDirs(words, cwd, { onlyLeadingOptions: false, longName: '--directory' });
  return [];
}

/** A redirect operator word (`>`, `2>>`, `&>`, `<`), whose next word is its target. */
const REDIRECT_OP_RE = /^\d*(?:&>>?|>>?|>\||<)$/;
/** A redirect with its target attached (`>out`, `2>>log`). */
const REDIRECT_ATTACHED_RE = /^\d*(?:&>>?|>>?|>\||<)([^&].*)$/;

function looksLikePath(w) {
  return w.includes('/') || w === '.' || w === '..';
}

/**
 * Path-valued arguments of one command, resolved to absolute paths:
 *   - redirect targets, relative to the shell's working directory (`cwd`)
 *   - every other word that looks like a path (contains `/`, or is `.` / `..`), and the value
 *     after `=` in `--opt=<value>`, relative to where the command runs (`dir`)
 * `unresolved` is true when some path-like word could not be resolved (`$VAR/…`, `~/…`, a
 * substitution, or an unknown base directory) — callers that exempt must not.
 *
 * @returns {{paths: string[], unresolved: boolean}}
 */
export function pathArgs(words, cwd, dir) {
  const paths = [];
  let unresolved = false;
  const add = (raw, base) => {
    const abs = toAbs(raw, base);
    if (abs) paths.push(abs);
    else unresolved = true;
  };
  for (let i = 1; i < words.length; i++) {
    const w = words[i];
    const attached = REDIRECT_ATTACHED_RE.exec(w);
    if (REDIRECT_OP_RE.test(w)) {
      if (i + 1 < words.length) add(words[++i], cwd);
    } else if (attached) {
      add(attached[1], cwd);
    } else {
      const value = w.startsWith('-') && w.includes('=') ? w.slice(w.indexOf('=') + 1) : w;
      if (isPathCandidate(value)) add(value, dir);
    }
  }
  return { paths, unresolved };
}

/**
 * Directories one command runs in: `env -C d cmd` runs cmd in d (a one-command cd), folded before
 * git / make `-C`.
 */
function runDirs(chdir, words, dir) {
  if (chdir === null) return directoryOptions(words, dir);
  const base = dir && toAbs(chdir, dir);
  return [base, ...directoryOptions(words, base)];
}

/** Is `abs` inside `root` (or equal to it)? */
export function isInside(abs, root) {
  const rel = relative(root, abs);
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

/**
 * Walks the segments in order, tracking the working directory (see the header for the rules).
 * An unresolvable `cd` (`cd`, `cd -`, `cd $X`) leaves the directory unknown (null).
 * Throws ShellParseError (from splitShellSegments).
 *
 * @param {string} command
 * @param {string|null} cwd
 * @returns {Array<{raw: string, redirect: boolean, depth: number, sep: string, words: string[],
 *   cwd: string|null, cwdCertain: boolean, cdTo: string|null, isCd: boolean,
 *   dirs: Array<string|null>, effectiveDir: string|null}>}
 */
export function walkSegments(command, cwd) {
  // states[g] = directory state inside subshell nesting level g (level 0 = the command itself).
  const states = [{ dir: cwd || null, certain: true, cdPending: false }];
  let level = 0;
  return splitShellSegments(command).map((seg) => {
    for (; level < seg.group; level++) states[level + 1] = { ...states[level] };
    level = seg.group;
    const st = states[level];
    if (seg.depth === 0 && st.cdPending && seg.sep !== '&&') st.certain = false;
    const { prefix, words } = splitPrefix(seg.raw);
    const effects = prefixEffects(prefix);
    const ctx = {
      ...seg,
      redirect: seg.redirect || effects.writes,
      words,
      assigns: effects.assigns,
      opaque: effects.opaque,
      cwd: st.dir,
      cwdCertain: st.certain,
      cdTo: null,
      isCd: words[0] === 'cd',
      dirs: [],
      effectiveDir: st.dir,
    };
    if (ctx.isCd) {
      ctx.cdTo = words[1] && words[1] !== '-' ? toAbs(words[1], st.dir) : null;
      if (seg.depth === 0) Object.assign(st, { dir: ctx.cdTo, cdPending: true });
    } else {
      ctx.dirs = runDirs(effects.chdir, words, st.dir);
      if (ctx.dirs.length) ctx.effectiveDir = ctx.dirs[ctx.dirs.length - 1];
    }
    return ctx;
  });
}
