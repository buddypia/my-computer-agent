/**
 * heredoc-strip.mjs - Heredoc body classification (lib SSOT)
 *
 * A heredoc body is *data* when a data reader consumes it (`cat`, `tee`, a redirection into a
 * file) and *a program* when a shell consumes it (`bash <<'EOF' … EOF`). The original version of
 * this file dropped every body unconditionally, which was right for the first case and a hole in
 * the second: `bash <<'EOF'` + `git reset --hard origin/main` + `EOF` is a real `reset --hard`,
 * and `destructive-git-guard` returned `{blocked:false}` for it. Measured 2026-09-18: destructive-git and other command
 * guards were all invisible through a shell heredoc.
 *
 * So the body is not dropped by default; it is routed:
 *   - read by a shell interpreter → kept, appended as a separate statement to inspect
 *   - read by anything else       → dropped, exactly as before (`cat <<EOF > file` stays allowed)
 *
 * Supported opener variants:
 *   `<<EOF` · `<<-EOF` · `<<'EOF'` · `<<"EOF"` · multiple heredocs in one command
 *
 * Regressions for both directions live in `tests/unit/shell-grammar-continuations.test.mjs`.
 *
 * `stripHeredocBodies` is kept as an alias of `stripHeredocData`: several hooks and tests (and
 * transplant targets) import the old name, and the rename must not silently change what they get —
 * they get the routed behaviour under either name.
 *
 * Excluded (R-CM-029 Rule 4 Surgical):
 *   - Triggers inside quoted strings — handled by hook-anchors.mjs (CMD_ANCHOR_SRC)
 *   - `sh -c <arg>` / `eval <args>` nesting — the caller that needs it expands it; it is not a
 *     heredoc concern
 *
 * Consuming hooks: commit-guard, destructive-git-guard, pre-ship-review-guard,
 * bash-file-integrity-guard, dev-server-guard. Kept in lib rather than in a hook to avoid
 * cross-hook circular execution — importing a hook module directly runs its top-level main guard.
 */

/**
 * A heredoc opener: `<<` / `<<-`, an optionally quoted or backslash-escaped delimiter, then the
 * rest of the opener's *logical* line (group 3), which may be continued with `\<newline>` — the
 * body only starts after it (`cat <<'EOF' \<newline>| bash` pipes the body into bash). The rest is
 * kept in the output: `cat <<EOF && git reset --hard` runs that reset, and dropping the whole
 * opener line used to hide it.
 *
 * The body ends at the **first** line equal to the delimiter (POSIX). Reproduced 2026-08-27: a
 * body regex that could not match an empty body skipped that line and swallowed real commands up
 * to a later `EOF` (`cat <<EOF\nEOF\ngit reset --hard origin/main\nEOF`). The terminator is now
 * looked up in a line index instead of a lazy `[\s\S]*?` scan, which was quadratic for many
 * unterminated openers (`x << y1`, `x << y2`, …: 20k lines took ~9s; review 2026-09-23).
 */
const OPENER_AT = /<<-?[ \t]*\\?(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1((?:\\\r?\n|\\.|[^\\\n])*)\n/y;

/**
 * Line index of `text`: delimiter-candidate content (leading blanks and a trailing `\r` removed)
 * → ascending list of `[lineStart, contentEnd]`. Built once per command.
 */
function indexLines(text) {
  const index = new Map();
  let start = 0;
  while (start <= text.length) {
    const nl = text.indexOf('\n', start);
    const lineEnd = nl < 0 ? text.length : nl;
    const line = text.slice(start, lineEnd);
    const content = line.replace(/^[ \t]+/, '').replace(/\r$/, '');
    const contentEnd = start + line.replace(/\r$/, '').length;
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(content)) {
      if (!index.has(content)) index.set(content, []);
      index.get(content).push([start, contentEnd]);
    }
    if (nl < 0) break;
    start = nl + 1;
  }
  return index;
}

/** First `[lineStart, contentEnd]` in the ascending `lines` with `lineStart >= from`. */
function firstLineFrom(lines, from) {
  let lo = 0;
  let hi = lines.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid][0] < from) lo = mid + 1;
    else hi = mid;
  }
  return lines[lo];
}

/**
 * Commands that execute their standard input as a shell script.
 *
 * Matched on the basename of the **command word** of a pipeline stage (after wrappers such as
 * `env`, `sudo`, `nohup`, `timeout 60`, `busybox`), never on arguments: an argument that happens to
 * be spelled `bash` (`--title "Fix bash completion"`, `cat <<EOF > scripts/sh`) is data, and
 * matching every token denied those (review of f222e205, 2026-09-23).
 */
export const SHELL_INTERPRETERS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'mksh', 'ash']);

/**
 * Programs that run their operand as the command, mapped to their options that consume the next
 * word (`sudo -u root bash`, `timeout -s KILL 5 bash`). Per wrapper, because the same letter means
 * different things: `env -i` takes no value, `stdbuf -i` does.
 */
const WRAPPERS = new Map([
  ['env', new Set(['-u', '-C', '-S', '--chdir', '--unset', '--split-string'])],
  ['sudo', new Set(['-u', '-g', '-C', '-D', '-h', '-p', '-U', '-r', '-t'])],
  ['doas', new Set(['-u', '-C'])],
  ['exec', new Set(['-a'])],
  ['nohup', new Set()],
  ['timeout', new Set(['-s', '-k'])],
  ['command', new Set()],
  ['nice', new Set(['-n'])],
  ['time', new Set(['-f', '-o'])],
  ['stdbuf', new Set(['-i', '-o', '-e'])],
  ['busybox', new Set()],
  ['xargs', new Set(['-I', '-n', '-P', '-L', '-d', '-s', '-E', '-a'])],
]);
/** Reserved words / grouping that can precede the command word without being it. */
const PREFIX_WORDS = new Set(['{', '}', '!', 'then', 'do', 'else', 'elif', 'if', 'while', 'until']);

/** Private-use character standing in for a removed heredoc opener in the skeleton. */
const OPENER = '\uE000';

const END = { op: 'end' };
const PIPE = { op: 'pipe' };
const REDIR = { op: 'redir' };
const REDIR_OP_RE = /(?:<<<|<<-?|<>|<&|>>|>&|>\||&>>?|<|>)/y;

/**
 * Minimal quote-aware lexer for the heredoc skeleton (bodies already removed).
 *
 * Produces words and the operators that matter for "who reads this heredoc": pipeline ends,
 * pipes, redirections and heredoc openers. `$(…)` / backticks are lexed as separate streams (their
 * heredocs belong to the inner command, e.g. `git commit -m "$(cat <<'EOF' … )"`) and show up in
 * the outer stream as a dynamic word. `( … )` is spliced in place so `(bash) <<EOF` still names
 * bash. Comments are skipped. It is not a full shell parser and does not try to be.
 */
class SkeletonLexer {
  constructor(text) {
    this.text = text;
    this.i = 0;
    this.streams = [];
    this.nextId = 0;
  }

  lex(close) {
    const tokens = [];
    const cur = { word: '', inWord: false };
    const flush = () => {
      if (cur.inWord) tokens.push({ w: cur.word });
      cur.word = '';
      cur.inWord = false;
    };
    while (this.i < this.text.length) {
      const c = this.text[this.i];
      if (close && c === close) {
        this.i += 1;
        break;
      }
      this.step(c, cur, tokens, flush);
    }
    flush();
    return tokens;
  }

  step(c, cur, tokens, flush) {
    const { text } = this;
    if (c === OPENER) {
      flush();
      tokens.push({ op: 'heredoc', id: this.nextId++ });
      this.i += 1;
    } else if (c === '\\') {
      this.escape(cur);
    } else if (c === "'" || c === '"') {
      this.quoted(c, cur);
    } else if (c === '$' && text[this.i + 1] === '(') {
      this.i += 2;
      this.substitution(')', cur);
    } else if (c === '`') {
      this.i += 1;
      this.substitution('`', cur);
    } else if (c === '(') {
      flush();
      this.i += 1;
      tokens.push(...this.lex(')'));
    } else if (c === '#' && !cur.inWord) {
      while (this.i < text.length && text[this.i] !== '\n') this.i += 1;
    } else {
      this.operatorOrChar(c, cur, tokens, flush);
    }
  }

  escape(cur) {
    const nl = this.text[this.i + 1] === '\n' ? 1 : this.text.startsWith('\r\n', this.i + 1) ? 2 : 0;
    if (!nl) {
      cur.word += this.text[this.i + 1] ?? '';
      cur.inWord = true;
    }
    this.i += nl ? 1 + nl : 2;
  }

  quoted(q, cur) {
    const { text } = this;
    this.i += 1;
    cur.inWord = true;
    while (this.i < text.length && text[this.i] !== q) {
      if (q === '"' && text[this.i] === '$' && text[this.i + 1] === '(') {
        this.i += 2;
        this.substitution(')', cur);
        continue;
      }
      if (q === '"' && text[this.i] === '\\') this.i += 1;
      cur.word += text[this.i] ?? '';
      this.i += 1;
    }
    this.i += 1;
  }

  substitution(close, cur) {
    this.streams.push(this.lex(close));
    cur.word += '$(…)';
    cur.inWord = true;
  }

  operatorOrChar(c, cur, tokens, flush) {
    if (this.redirection(c, cur, tokens, flush) || this.separator(c, tokens, flush)) return;
    if (/\s/.test(c)) {
      flush();
    } else {
      cur.word += c;
      cur.inWord = true;
    }
    this.i += 1;
  }

  redirection(c, cur, tokens, flush) {
    // Sticky match at the cursor — slicing the rest of the text here made the lexer quadratic.
    if (c !== '<' && c !== '>' && !(c === '&' && this.text[this.i + 1] === '>')) return false;
    REDIR_OP_RE.lastIndex = this.i;
    const redir = REDIR_OP_RE.exec(this.text);
    if (!redir) return false;
    // `2>&1`: a bare fd number in front of the operator belongs to the redirection.
    if (cur.inWord && /^\d+$/.test(cur.word)) cur.inWord = false;
    flush();
    tokens.push(REDIR);
    this.i += redir[0].length;
    return true;
  }

  separator(c, tokens, flush) {
    const two = this.text.slice(this.i, this.i + 2);
    const isPipe = c === '|' && two !== '||';
    if (!isPipe && !(two === '&&' || two === '||' || c === ';' || c === '&' || c === '\n')) {
      return false;
    }
    flush();
    tokens.push(isPipe ? PIPE : END);
    this.i += two === '&&' || two === '||' || two === '|&' ? 2 : 1;
    // A pipe at end of line continues the pipeline on the next line (after any heredoc body).
    if (isPipe) while (/\s/.test(this.text[this.i] ?? '')) this.i += 1;
    return true;
  }
}

/** Skips a wrapper's options (and their values / a timeout duration) starting at `i`. */
function skipWrapperArgs(words, i, valueOpts) {
  let j = i;
  while (j < words.length) {
    const w = words[j];
    if (valueOpts.has(w)) j += 2;
    else if (w.startsWith('-') || /^\d+(?:\.\d+)?[smhd]?$/.test(w) || /^\w+=/.test(w)) j += 1;
    else break;
  }
  return j;
}

/**
 * The command word of one pipeline stage, or `null` when it has none.
 *
 * @param {Array<{w?: string, op?: string}>} stage
 * @returns {string|null}
 */
function commandWord(stage) {
  const words = [];
  for (let k = 0; k < stage.length; k += 1) {
    const t = stage[k];
    if (t.op === 'redir') k += 1; // the redirection target is not a word of the command
    else if (t.w !== undefined) words.push(t.w);
  }
  return stripCommandPrefix(words)[0] ?? null;
}

/**
 * The words of one simple command from its command word on: leading reserved words, env
 * assignments and wrappers (with their options) removed — `sudo -u x env A=1 cargo build` →
 * `['cargo', 'build']`. Empty when nothing but prefixes remains. Shared with bash-segments.mjs so
 * both "who reads this heredoc" and the trunk Bash allowlist unwrap the same wrapper list.
 *
 * @param {string[]} words
 * @returns {string[]}
 */
export function stripCommandPrefix(words) {
  let i = 0;
  while (i < words.length) {
    const w = words[i];
    if (PREFIX_WORDS.has(w) || /^[A-Za-z_][A-Za-z0-9_]*\+?=/.test(w)) {
      i += 1;
    } else if (WRAPPERS.has(w.split('/').pop())) {
      i = skipWrapperArgs(words, i + 1, WRAPPERS.get(w.split('/').pop()));
    } else {
      return words.slice(i);
    }
  }
  return [];
}

/**
 * `$SHELL` / `${SHELL}` name the user's shell. Other dynamic words (`"$PY" - <<'EOF'`) are not
 * assumed to be shells: doing so denied Python heredocs whose body merely mentions git commands.
 */
const SHELL_VARIABLE_RE = /^\$(?:SHELL|\{SHELL\})$/;

function isShellWord(word) {
  if (word === null) return false;
  if (SHELL_VARIABLE_RE.test(word)) return true;
  return SHELL_INTERPRETERS.has(word.split('/').pop());
}

/**
 * Adds to `programs` the ids of heredocs in `tokens` that a shell reads.
 *
 * A heredoc in stage *i* reaches every later stage through the pipe, so it is a program when the
 * command of stage *i* or of any later stage in the **same pipeline** is a shell. `bash x.sh | cat
 * <<EOF` (bash is upstream) and `cat <<EOF ; bash x` (a new pipeline) do not count.
 */
function collectPrograms(tokens, programs) {
  let stages = [[]];
  const settle = () => {
    let downstreamShell = false;
    for (let s = stages.length - 1; s >= 0; s -= 1) {
      downstreamShell = downstreamShell || isShellWord(commandWord(stages[s]));
      if (!downstreamShell) continue;
      for (const t of stages[s]) if (t.op === 'heredoc') programs.add(t.id);
    }
    stages = [[]];
  };
  for (const t of tokens) {
    if (t === END) settle();
    else if (t === PIPE) stages.push([]);
    else stages[stages.length - 1].push(t);
  }
  settle();
}

/** Characters after which a `#` starts a comment (bash: `#` must begin a word). */
const COMMENT_START_RE = /[\s;&|()<>]/;

/** One step inside quotes or a comment. Returns the next index. */
function quotedStep(text, i, stack) {
  const top = stack[stack.length - 1];
  const c = text[i];
  if (top.mode === 'comment' || top.mode === 'sq') {
    if (c === (top.mode === 'sq' ? "'" : '\n')) stack.pop();
    return i + 1;
  }
  if (c === '\\') return i + 2; // dq / ansi escape
  if (top.mode === 'dq' && c === '$' && text[i + 1] === '(') {
    stack.push({ mode: 'n', close: ')' });
    return i + 2;
  }
  if (c === (top.mode === 'dq' ? '"' : "'")) stack.pop();
  return i + 1;
}

/** The mode an unquoted character opens, if any. */
function openedMode(text, i) {
  const c = text[i];
  const prev = i === 0 ? '' : text[i - 1];
  if (c === "'") return prev === '$' ? 'ansi' : 'sq';
  if (c === '"') return 'dq';
  if (c === '#' && (prev === '' || COMMENT_START_RE.test(prev))) return 'comment';
  return null;
}

/** At an unquoted `<<`: records the heredoc and returns the index past its body. */
function heredocStep(text, i, found, lineIndex) {
  if (text[i + 2] === '<') return i + 3; // here-string, not a heredoc
  OPENER_AT.lastIndex = i;
  const m = OPENER_AT.exec(text);
  if (!m) return i + 2;
  const bodyStart = OPENER_AT.lastIndex;
  const terminator = firstLineFrom(lineIndex().get(m[2]) ?? [], bodyStart);
  if (!terminator) return i + 2; // unterminated: not a heredoc we can route
  const [termStart, termEnd] = terminator;
  // An unquoted, unescaped delimiter makes the shell expand `$( … )` / backticks in the body.
  const expands = m[1] === '' && !/^<<-?[ \t]*\\/.test(m[0]);
  found.push({ start: i, end: termEnd, rest: m[3], body: text.slice(bodyStart, termStart), expands });
  return termEnd;
}

/** One unquoted step. Records a heredoc and jumps past its body when one opens here. */
function unquotedStep(text, i, stack, found, lineIndex) {
  const top = stack[stack.length - 1];
  const c = text[i];
  if (c === '\\') return i + 2;
  if (top.close && c === top.close) {
    stack.pop();
    return i + 1;
  }
  if (c === '<' && text[i + 1] === '<') return heredocStep(text, i, found, lineIndex);
  if (c === '(' || c === '`' || (c === '$' && text[i + 1] === '(')) {
    stack.push({ mode: 'n', close: c === '`' ? '`' : ')' });
    return c === '$' ? i + 2 : i + 1;
  }
  const mode = openedMode(text, i);
  if (mode) stack.push({ mode, close: '' });
  return i + 1;
}

/**
 * Finds the heredoc openers the shell honours, in order, each with its rest-of-line and body.
 *
 * Only an unquoted `<<` outside a comment opens a heredoc. Matching the pattern anywhere took
 * `echo '<<EOF'` or `# see <<EOF` for an opener and dropped the real commands on the following
 * lines as "body" (review, 2026-09-23). `$( … )` inside double quotes is a new unquoted context,
 * so `git commit -m "$(cat <<'EOF' … )"` is still found. A matched body is skipped whole, so its
 * apostrophes cannot desynchronise the quote state. Linear: every step advances the cursor.
 *
 * @param {string} text
 * @returns {Array<{start: number, end: number, rest: string, body: string|undefined}>}
 */
function findHeredocs(text) {
  const found = [];
  const stack = [{ mode: 'n', close: '' }];
  let index = null;
  const lineIndex = () => (index ??= indexLines(text));
  let i = 0;
  while (i < text.length) {
    const inQuotes = stack[stack.length - 1].mode !== 'n';
    i = inQuotes ? quotedStep(text, i, stack) : unquotedStep(text, i, stack, found, lineIndex);
  }
  return found;
}

/**
 * Removes heredoc bodies that are data and re-emits heredoc bodies that are programs.
 *
 * The returned string is not the command the shell runs — it is every piece of text the shell will
 * treat as a command, concatenated. Program bodies are appended after a newline so any caller that
 * splits on separators sees them as their own statements.
 *
 * Known limits (not heredocs, or not modelled): here-strings (`bash <<< "…"`), `eval`, `xargs`,
 * `source /dev/stdin`, `python -c`, `echo … | sh -s`, a script written then run, a shell under a
 * name outside `SHELL_INTERPRETERS`, a shell reached through a dynamic word other than `$SHELL`
 * (`$(command -v bash) <<EOF`), a heredoc on a compound command (`{ bash; } <<EOF`,
 * `while read l; do bash; done <<EOF`), and quoted delimiters containing spaces (`<<"E O"`).
 *
 * @param {string} command - Bash command
 * @returns {string} Inspection-safe command text (non-string inputs returned as-is)
 */
export function stripHeredocData(command) {
  if (typeof command !== 'string') return command;
  const { stripped, programBodies } = splitHeredocs(command);
  return programBodies.length === 0 ? stripped : `${stripped}\n${programBodies.join('\n')}`;
}

/**
 * Bodies of heredocs read by a program that runs them as commands (`bash <<EOF`). `stripHeredocData`
 * appends these after the command, so a caller that needs statement *order* (which directory a
 * body's `git commit` runs in) cannot trust the flattened text and has to treat them as opaque.
 *
 * @param {string} command
 * @returns {string[]}
 */
export function heredocProgramBodies(command) {
  return typeof command === 'string' ? splitHeredocs(command).programBodies : [];
}

/** Heredoc-free skeleton + bodies read as programs (shared by the two exports above). */
function splitHeredocs(command) {
  // Fast path — bypass the regex when no heredoc opener is present. 95%+ of PreToolUse Bash hook
  // calls (simple git/ls/npm) contain none, and `.includes` is far cheaper than backtracking.
  if (!command.includes('<<')) return { stripped: command, programBodies: [] };

  const heredocs = findHeredocs(command);
  if (heredocs.length === 0) return { stripped: command, programBodies: [] };
  const bodies = heredocs.map((h) => h.body);
  let skeleton = '';
  let last = 0;
  for (const h of heredocs) {
    skeleton += command.slice(last, h.start) + OPENER + h.rest;
    last = h.end;
  }
  skeleton += command.slice(last);

  const lexer = new SkeletonLexer(skeleton);
  const programs = new Set();
  collectPrograms(lexer.lex(null), programs);
  for (const stream of lexer.streams) collectPrograms(stream, programs);

  const stripped = skeleton.replaceAll(OPENER, '');
  const programBodies = bodies.filter((body, id) => body && programs.has(id));
  return { stripped, programBodies };
}

/**
 * Bodies of heredocs whose delimiter is unquoted (`<<EOF`, not `<<'EOF'` / `<<\EOF`). The shell
 * expands `$( … )` and backticks in those bodies before any reader sees them, so a data body
 * (`cat <<EOF` + `$(rm x)`) still runs commands. `stripHeredocData` drops data bodies whole;
 * callers that must see every command (bash-segments.mjs) scan these for substitutions.
 *
 * @param {string} command
 * @returns {string[]}
 */
export function expandingHeredocBodies(command) {
  if (typeof command !== 'string' || !command.includes('<<')) return [];
  return findHeredocs(command)
    .filter((h) => h.expands && h.body)
    .map((h) => h.body);
}

/**
 * Backward-compatible name. Same function, same routing — see the header for why it is kept.
 */
export const stripHeredocBodies = stripHeredocData;
