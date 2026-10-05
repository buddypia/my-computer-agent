/**
 * swift-bar-move.mjs — "Did the change lower its own bar?" for Swift Testing (pure).
 *
 * `.cli/lib/self-improving-loop.mjs#detectBarMove` is written for JS: its test-path rule is
 * case-sensitive `tests?/`, so `Tests/MCACoreTests/*.swift` is not a test to it, and its assertion
 * pattern knows `expect(` / `assert` but not `#require` or `.disabled` (INC-001).
 *
 * This module counts on the **whole file before and after**, not on diff lines (INC-002). Diff lines
 * can be hidden (`.gitattributes -diff`, a NUL byte, git config) and cannot see context: a `/*` or
 * `#if` added on one line deactivates tests on lines the diff never shows. Counting on the full text
 * with comments, string contents and inactive `#if` branches removed sees what the compiler sees.
 *
 * `#if` branches are *evaluated* for the one build these tests run in (macOS, debug `swift test`),
 * not merely dropped when literally `false` (INC-005): `#if os(Linux)`, `#if !DEBUG` and the `#else`
 * of `#if os(macOS)` compile tests out just as surely.
 *
 * Signals (per test file; a new file is measured against an empty one):
 *   test_file_deleted        file under Tests/ removed
 *   assertion_removed        net decrease of active #expect / #require / Issue.record / XCTAssert*
 *   test_removed             net decrease of active @Test
 *   disabled_added           net increase of .disabled / .enabled(if:) / ConditionTrait / withKnownIssue / XCTSkip
 *   conditional_compilation  net increase of `#if` on a custom flag (os/canImport/... are exempt)
 *   empty_arguments          net increase of parameterized tests fed an empty collection
 *
 * Known limit: detection is by count. Replacing a real assertion with `#expect(true)` keeps the
 * count; that is the reviewer's to catch, not this module's.
 */

export const SWIFT_BAR_MOVE = Object.freeze({
  TEST_FILE_DELETED: 'test_file_deleted',
  ASSERTION_REMOVED: 'assertion_removed',
  TEST_REMOVED: 'test_removed',
  DISABLED_ADDED: 'disabled_added',
  CONDITIONAL_COMPILATION: 'conditional_compilation',
  EMPTY_ARGUMENTS: 'empty_arguments',
});

export function isSwiftTestPath(path) {
  return /^Tests\/.+\.swift$/.test(path);
}

const ASSERT = /#expect\s*[({]|#require\s*[({]|\bIssue\.record\s*\(|\bXCTAssert\w*\s*\(/g;
const TEST_DECL = /@Test\b/g;
// `ConditionTrait` catches a custom trait that wraps `.enabled(if:)` in another file (INC-005).
// `TestScoping` / `provideScope` catch a trait that can decide not to run the body at all.
const DISABLED = /\.disabled\b|\.enabled\s*[({]|\bConditionTrait\b|\bTestScoping\b|\bprovideScope\b|\bwithKnownIssue\b|\bXCTSkip\w*\s*\(/g;
const EMPTY_ARGS = /\barguments\s*:\s*(?:\[\s*\]|\[\s*:\s*\]|\[[\w.<>, ]+\]\s*\(\s*\)|EmptyCollection\b|Array\s*<[^>]*>\s*\(\s*\))/g;
// Platform/toolchain conditions are legitimate in tests; anything else can be a switch-off.
const BENIGN_IF = /^#(?:if|elseif)\s*!?\s*(?:os|canImport|swift|compiler|arch|targetEnvironment|DEBUG\b)/;

/**
 * The build this repository's tests run in. Anything unlisted is false, like an undefined flag.
 * Imports are an allowlist (unknown module → false → the guarded tests count as removed): guessing
 * "true" is what let `canImport(NoSuchModule)` hide a test (INC-009). The same goes for versions and
 * architecture — they are compared, not assumed.
 */
const TARGET = {
  os: new Set(['macOS']),
  arch: new Set([process.arch === 'x64' ? 'x86_64' : process.arch]),
  flags: new Set(['DEBUG']),
  targetEnvironment: new Set([]),
  swift: [6, 3],
  canImport: new Set([
    'Foundation', 'Darwin', 'Dispatch', 'AppKit', 'SwiftUI', 'Combine', 'Observation', 'Testing', 'XCTest',
    'CoreGraphics', 'CoreFoundation', 'CoreText', 'CoreImage', 'CoreMedia', 'CoreVideo', 'CoreAudio',
    'ApplicationServices', 'Carbon', 'Vision', 'AVFoundation', 'ScreenCaptureKit', 'Speech', 'NaturalLanguage',
    'Security', 'OSLog', 'os', 'Network', 'CryptoKit', 'UniformTypeIdentifiers', 'FoundationModels',
  ]),
  localModulePrefix: /^MCA|^mca$/,
};

function versionHolds(arg) {
  const m = /^(>=|<)\s*(\d+)(?:\.(\d+))?/.exec(arg);
  if (!m) return false;
  const [have, want] = [TARGET.swift, [Number(m[2]), Number(m[3] ?? 0)]];
  const cmp = have[0] - want[0] || have[1] - want[1];
  return m[1] === '>=' ? cmp >= 0 : cmp < 0;
}

/** Evaluates a `#if` condition for TARGET: `!`, `&&`, `||`, parentheses; unknown atoms are false. */
export function evalCondition(expr) {
  const tokens = String(expr).match(/\w+\s*\([^()]*\)|&&|\|\||[!()]|[\w.]+/g) ?? [];
  let i = 0;
  const atom = (t) => {
    const call = /^(\w+)\s*\(\s*([^()]*?)\s*\)$/.exec(t ?? '');
    if (!call) return t === 'true' || t === '1' || TARGET.flags.has(t);
    const [, fn, arg] = call;
    if (fn === 'os') return TARGET.os.has(arg);
    if (fn === 'arch') return TARGET.arch.has(arg);
    if (fn === 'targetEnvironment') return TARGET.targetEnvironment.has(arg);
    if (fn === 'canImport') {
      const mod = arg.split(/[.,\s]/)[0];
      return TARGET.canImport.has(mod) || TARGET.localModulePrefix.test(mod);
    }
    if (fn === 'swift' || fn === 'compiler') return versionHolds(arg);
    return false;
  };
  const primary = () => {
    const t = tokens[i++];
    if (t === '!') return !primary();
    if (t === '(') {
      const v = or();
      i += 1; // ')'
      return v;
    }
    return atom(t);
  };
  const and = () => {
    let v = primary();
    while (tokens[i] === '&&') {
      i += 1;
      v = primary() && v;
    }
    return v;
  };
  const or = () => {
    let v = and();
    while (tokens[i] === '||') {
      i += 1;
      v = and() || v;
    }
    return v;
  };
  return or();
}

/**
 * Removes comments (line and nested block) and string literal contents — including raw strings
 * `#"..."#` — keeping line structure so `#if` lines stay on their own lines.
 */
export function stripNonCode(text) {
  const s = String(text ?? '');
  let out = '';
  let i = 0;
  const skipTo = (end) => {
    // Keep the newlines of whatever is skipped.
    out += s.slice(i, end).replace(/[^\n]/g, '');
    i = end;
  };
  while (i < s.length) {
    const two = s.slice(i, i + 2);
    if (two === '//') {
      const nl = s.indexOf('\n', i);
      skipTo(nl === -1 ? s.length : nl);
      continue;
    }
    if (two === '/*') {
      let depth = 0;
      let j = i;
      while (j < s.length) {
        if (s.startsWith('/*', j)) { depth += 1; j += 2; }
        else if (s.startsWith('*/', j)) { depth -= 1; j += 2; if (depth === 0) break; }
        else j += 1;
      }
      skipTo(j);
      continue;
    }
    const raw = /^(#*)("""|")/.exec(s.slice(i, i + 16));
    if (raw && (raw[1] || s[i] === '"')) {
      const [open, hashes, quote] = raw;
      const close = quote + hashes;
      let j = i + open.length;
      while (j < s.length) {
        if (!hashes && s[j] === '\\') { j += 2; continue; }
        if (s.startsWith(close, j)) { j += close.length; break; }
        if (quote === '"' && s[j] === '\n') break; // unterminated single-line string
        j += 1;
      }
      out += '""';
      skipTo(j);
      continue;
    }
    out += s[i];
    i += 1;
  }
  return out;
}

/**
 * Keeps only the lines the compiler sees for TARGET: each `#if` / `#elseif` / `#else` chain takes its
 * first true branch, and everything nested inside an inactive branch stays inactive.
 */
export function stripInactiveRegions(code) {
  const out = [];
  const stack = []; // { parentActive, taken, active }
  const active = () => (stack.length ? stack[stack.length - 1].active : true);
  for (const line of code.split('\n')) {
    const t = line.trim();
    let m;
    if ((m = /^#if\b(.*)$/.exec(t))) {
      const parentActive = active();
      const v = parentActive && evalCondition(m[1]);
      stack.push({ parentActive, taken: v, active: v });
      continue;
    }
    if ((m = /^#elseif\b(.*)$/.exec(t)) && stack.length) {
      const top = stack[stack.length - 1];
      top.active = top.parentActive && !top.taken && evalCondition(m[1]);
      top.taken ||= top.active;
      continue;
    }
    if (/^#else\b/.test(t) && stack.length) {
      const top = stack[stack.length - 1];
      top.active = top.parentActive && !top.taken;
      top.taken = true;
      continue;
    }
    if (/^#endif\b/.test(t)) {
      stack.pop();
      continue;
    }
    if (active()) out.push(line);
  }
  return out.join('\n');
}

const EMPTY = Object.freeze({ asserts: 0, tests: 0, disabled: 0, emptyArgs: 0, customIf: 0 });

export function measure(text) {
  if (text === null || text === undefined) return null;
  const code = stripNonCode(text);
  const active = stripInactiveRegions(code);
  const count = (re) => (active.match(re) ?? []).length;
  const customIf = code
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /^#(?:if|elseif)\b/.test(l) && !BENIGN_IF.test(l)).length;
  return { asserts: count(ASSERT), tests: count(TEST_DECL), disabled: count(DISABLED), emptyArgs: count(EMPTY_ARGS), customIf };
}

/**
 * @param {Array<{path: string, before: string|null, after: string|null}>} files  full contents at base / HEAD
 * @returns {Array<{signal: string, path: string, detail: string}>}
 */
export function detectSwiftBarMove(files) {
  const findings = [];
  for (const f of files) {
    if (!isSwiftTestPath(f.path)) continue;
    const before = measure(f.before) ?? EMPTY;
    const after = measure(f.after);
    if (!after) {
      findings.push({ signal: SWIFT_BAR_MOVE.TEST_FILE_DELETED, path: f.path, detail: `テストファイル削除 (${before.asserts} assertions, ${before.tests} @Test)` });
      continue;
    }
    const push = (signal, n, detail) => n > 0 && findings.push({ signal, path: f.path, detail: detail(n) });
    push(SWIFT_BAR_MOVE.ASSERTION_REMOVED, before.asserts - after.asserts, (n) => `有効な assertion 純減 -${n}`);
    push(SWIFT_BAR_MOVE.TEST_REMOVED, before.tests - after.tests, (n) => `有効な @Test 純減 -${n}`);
    push(SWIFT_BAR_MOVE.DISABLED_ADDED, after.disabled - before.disabled, (n) => `.disabled / .enabled(if:) / ConditionTrait / withKnownIssue 純増 +${n}`);
    push(SWIFT_BAR_MOVE.CONDITIONAL_COMPILATION, after.customIf - before.customIf, (n) => `独自フラグの #if 純増 +${n}（テストを無効化しうる）`);
    push(SWIFT_BAR_MOVE.EMPTY_ARGUMENTS, after.emptyArgs - before.emptyArgs, (n) => `空の arguments 純増 +${n}（0 ケースで実行される）`);
  }
  return findings;
}

/** True when some test file gains active assertions — the evidence a fix must carry. */
export function addsRegressionTest(files) {
  return files.some((f) => {
    if (!isSwiftTestPath(f.path) || f.after === null || f.after === undefined) return false;
    return measure(f.after).asserts > (measure(f.before)?.asserts ?? 0);
  });
}

/** Splits a unified diff into per-file blocks (used for content-scoped escalation rules). */
export function parseDiff(diffText) {
  const blocks = [];
  let cur = null;
  for (const line of String(diffText ?? '').split('\n')) {
    if (line.startsWith('diff --git ')) {
      const header = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
      // An unparseable header must not let its lines be attributed to the previous file.
      cur = header ? { path: header[2], deleted: false, added: [], removed: [] } : null;
      if (cur) blocks.push(cur);
      continue;
    }
    if (!cur) continue;
    if (line.startsWith('deleted file mode')) cur.deleted = true;
    else if (line.startsWith('+++') || line.startsWith('---')) continue;
    else if (line.startsWith('+')) cur.added.push(line.slice(1));
    else if (line.startsWith('-')) cur.removed.push(line.slice(1));
  }
  return blocks;
}
