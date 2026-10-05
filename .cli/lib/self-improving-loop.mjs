/**
 * self-improving-loop.mjs — Single SSOT for evaluating two failure modes of self-improving loops degrading their own standards
 *
 * Fundamental problem: In this repository, the *proposer of improvements* (AI) and the *evaluator of improvements*
 *   (rules, gates, tests) share the same permissions. If the proposer can edit evaluation files, whether score increases
 *   stem from improvements or lowered standards cannot be distinguished post-hoc. Google Cloud's
 *   "7 rules for self-improving agent loops" (2026-08-11) identifies this as the blind spot of loops —
 *   *"Give it a shallow target and it will optimize your agent into something that scores well and works worse. Then it reports success."*
 *
 *   This is not hypothetical. Three empirical cases in this repository:
 *     - #1140: Tests re-implemented production functions as copies, passing independently of real behavior
 *     - #1141: Full `vi.mock` replacements swallowed real behavior while passing
 *     - #1086: Strings from a CI channel with 0 runs in 78 days were used as passing evidence in 25 places
 *   All three represented "green gates but actually worse", remaining invisible until human audit.
 *
 * This module evaluates both modes (both pure functions — no I/O, test isolated):
 *   - `detectBarMove(diffText)`  — Rule 6 "Never let the proposer move the bar"
 *   - `detectFlakyTests(report)` — Rule 5 "Treat a flaky case as a finding"
 *
 * Design Decision — **Non-blocking (advisory)**: Lowering standards can be legitimate
 *   (cleaning dead tests, correcting invalid thresholds). Because intent cannot be evaluated algorithmically,
 *   only facts are surfaced, leaving decisions to the user (isomorphic to R-CM-016 Rule 10 User Sovereignty,
 *   R-CM-008 Rule 9 superset detection).
 *
 * Design Decision — **Input is a single unified diff text**: Querying separate git calls per signal causes N+1 spawns
 *   (`.claude/scripts/AGENTS.md` Convention 5) and fragments evaluation logic across callers.
 *   A single `git diff <base>..HEAD` output extracts all five signals.
 *
 * R-CM-028 boundary: **boundary-uniform (evaluation) / boundary-divergent (entry points)**.
 *   "Has the proposer lowered their own scoring criteria" carries the identical meaning in Perspective 1 (harness itself)
 *   and Perspective 2 (scaffolded projects) — this file is the SSOT for evaluation. Conversely, *when to measure* diverges:
 *   Perspective 1 runs at local ship time (`ops.mjs#shipWorktree`), Perspective 2 runs in CI/PR (scaffolded projects receive Actions).
 *   Because Perspective 2 cannot import `.cli/`, it maintains a copy whose behavioral equivalence is enforced by
 *   `tests/unit/self-improving-loop-ssot.test.mjs` (isomorphic to `trunk-branch.mjs` precedent).
 */

/** Types of bar-move signals. Values are used directly in ledgers and warning strings; tests prevent renaming. */
export const BAR_MOVE = Object.freeze({
  TEST_FILE_DELETED: 'test_file_deleted',
  SKIP_ADDED: 'skip_added',
  ONLY_ADDED: 'only_added',
  ASSERTION_REMOVED: 'assertion_removed',
  THRESHOLD_LOWERED: 'threshold_lowered',
  // A deleted test whose subject module was retired in the same diff — cleanup, not relaxation.
  // Kept as a distinct, non-blocking *info* signal (never folded into TEST_FILE_DELETED) so callers
  // can still see the deletion happened without it inflating the "goalposts moved" count.
  TEST_RETIRED_WITH_SUBJECT: 'test_retired_with_subject',
});

/**
 * Vocabulary of keys indicating thresholds. Why whitelisted: numeric decreases signify relaxing criteria
 * only for "higher is stricter" metrics. Catching values where decreases mean stricter requirements
 * (such as `max_bytes` / `timeout` / `warn_bytes`) would trigger permanent alarms that are ignored
 * (isomorphic to learning `metric-write-path-...`: "an alarm always on is worse than no alarm").
 */
// `min` must not use `\bmin\b` — because `_` is a word character, `min_files` / `coverage_min`
// fail boundary matching. Conversely, simple substring matching catches `admin` / `minute`.
// Explicit delimiters are specified (string start/end or `_` / `.` / `-`).
const RATCHET_KEY_WORDS = /threshold|coverage|minimum|(?:^|[_.\-])min(?:$|[_.\-])|baseline|health_score|required|floor|streak/i;

/** Tests whether path is a test file — extension convention (`*.test.*` / `*.spec.*`) or inside tests/ tree. */
export function isTestPath(path) {
  if (typeof path !== 'string' || !path) return false;
  return /(^|\/)tests?\//.test(path) || /\.(test|spec)\.[a-z]+$/i.test(path);
}

/**
 * `it.skip(` / `test.todo(` / `xdescribe(` unconditional skips. `skipIf(` is intentionally excluded —
 * conditional skips are legitimate patterns for missing environments (empirical 2026-08-11:
 * vast majority of 31 skips were `skipIf`), and flagging them dilutes warnings.
 */
const SKIP_PATTERN = /\b(?:it|test|describe)\.(?:skip|todo)\s*\(|\bx(?:it|describe)\s*\(/g;
const ONLY_PATTERN = /\b(?:it|test|describe)\.only\s*\(/g;
const ASSERT_PATTERN = /\bexpect\s*\(|\bassert\s*[.(]/g;

/**
 * Determines whether match position is inside a string literal. Tracks open quote type
 * and closes only on matching quote — count-only approaches fail when quotes nest inside different types
 * like `'... \`it.skip(\` ...'` (empirical 2026-08-11: count approach left this as a false positive).
 *
 * Not a full JS parser (does not distinguish quotes in comments or regex literals). However, the failure mode
 * leans toward *emitting fewer warnings* (safe — in advisory signals, false positives are worse than misses).
 */
function insideStringLiteral(line, index) {
  let openQuote = null;
  for (let i = 0; i < index; i += 1) {
    const ch = line[i];
    if (ch === '\\') {
      i += 1; // Skip escaped character without counting as delimiter
      continue;
    }
    if (openQuote) {
      if (ch === openQuote) openQuote = null;
    } else if (ch === "'" || ch === '"' || ch === '`') {
      openQuote = ch;
    }
  }
  return openQuote !== null;
}

/**
 * Counts pattern occurrences in diff line array. Counts only syntax used as code, excluding occurrences inside string literals.
 *
 * Why needed (empirical 2026-08-11): Self-tests of this evaluator contain patterns like `it.skip(` in fixture strings;
 * counting those as real skip additions produced 5 false positives on its own PR.
 */
function countMatches(lines, pattern) {
  let count = 0;
  for (const line of lines) {
    for (const match of line.matchAll(pattern)) {
      if (!insideStringLiteral(line, match.index)) count += 1;
    }
  }
  return count;
}

/** Applies diff line to current block. Ignores file header lines (not content). */
function applyDiffLine(block, line) {
  if (line.startsWith('deleted file mode')) {
    block.deleted = true;
    return;
  }
  // `+++ b/x` / `--- a/x` are file headers, not content (distinguished by 3-char prefix).
  if (line.startsWith('+++') || line.startsWith('---')) return;
  if (line.startsWith('+')) block.added.push(line.slice(1));
  else if (line.startsWith('-')) block.removed.push(line.slice(1));
}

/**
 * Splits unified diff into file blocks. Headers follow `diff --git a/<old> b/<new>` format.
 * Renames/mode-only changes have empty bodies and pass through with 0 signals naturally.
 * @param {string} diffText
 * @returns {Array<{path: string, deleted: boolean, added: string[], removed: string[]}>}
 */
export function parseUnifiedDiff(diffText) {
  if (typeof diffText !== 'string' || !diffText.trim()) return [];
  const blocks = [];
  let current = null;

  for (const line of diffText.split('\n')) {
    const header = line.match(/^diff --git a\/(.+?) b\/(.+)$/);
    if (header) {
      if (current) blocks.push(current);
      // Uses b-side path — name after rename represents current reality. In deletions, a==b.
      current = { path: header[2], deleted: false, added: [], removed: [] };
    } else if (current) {
      applyDiffLine(current, line);
    }
  }
  if (current) blocks.push(current);
  return blocks;
}

/**
 * Extracts numbers for ratchet vocabulary keys in `key: 12` / `"key" = 3.5` formats.
 * If the same key appears multiple times in a block, takes the **minimum value** —
 * comparing minimum of removed vs minimum of added is conservative (fewer false alarms).
 * @param {string[]} lines
 * @returns {Map<string, number>}
 */
export function collectRatchetValues(lines) {
  const out = new Map();
  for (const line of lines) {
    const m = line.match(/["']?([A-Za-z_][A-Za-z0-9_.-]*)["']?\s*[:=]\s*["']?(-?\d+(?:\.\d+)?)["']?/);
    if (!m) continue;
    const [, key, rawValue] = m;
    if (!RATCHET_KEY_WORDS.test(key)) continue;
    const value = Number(rawValue);
    if (!Number.isFinite(value)) continue;
    const prev = out.get(key);
    out.set(key, prev === undefined ? value : Math.min(prev, value));
  }
  return out;
}

/** Delta in pattern occurrences: added vs removed. Positive means "increased". */
function patternDelta(block, pattern, { countRemovals = false } = {}) {
  const plus = countMatches(block.added, pattern);
  const minus = countMatches(block.removed, pattern);
  return countRemovals ? minus - plus : plus - minus;
}

/** Three signals relevant only to test files (deleted files are filtered first by caller). */
function testFileSignals(block) {
  const candidates = [
    [BAR_MOVE.SKIP_ADDED, patternDelta(block, SKIP_PATTERN),
      (n) => `Unconditional skip/todo net increase +${n} (skipIf conditional excluded)`],
    [BAR_MOVE.ONLY_ADDED, patternDelta(block, ONLY_PATTERN),
      (n) => `.only() net increase +${n} — remaining test cases in same file are silently excluded from execution`],
    // For assertions, *disappearance* is the signal, so count direction is inverted.
    [BAR_MOVE.ASSERTION_REMOVED, patternDelta(block, ASSERT_PATTERN, { countRemovals: true }),
      (n) => `Assertion (expect/assert) net decrease -${n}`],
  ];
  return candidates
    .filter(([, n]) => n > 0)
    .map(([signal, n, toDetail]) => ({ signal, path: block.path, detail: toDetail(n) }));
}

/**
 * Basename stem used to pair a deleted test with a deleted subject module: strips the
 * `.test.<ext>` / `.spec.<ext>` suffix first (test-file convention), otherwise falls back to
 * stripping a plain extension (subject-module convention). A retired hook's test and its
 * production file typically share this stem (`foo.mjs` deleted alongside `foo.test.mjs`).
 */
function stemOf(path) {
  const base = String(path).split('/').pop() || '';
  return base.replace(/\.(test|spec)\.[a-z0-9]+$/i, '').replace(/\.[a-z0-9]+$/i, '');
}

const IMPORT_SPECIFIER_RE = /(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*)['"]([^'"]+)['"]/g;

/** POSIX-joins a relative specifier onto the directory of `fromFile` (diff paths are repo-relative). */
function resolveRelative(fromFile, spec) {
  const parts = fromFile.split('/').slice(0, -1);
  for (const seg of spec.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') parts.pop();
    else parts.push(seg);
  }
  return parts.join('/');
}

/**
 * True when the deleted test's own source referenced `subjectPath` — a relative import/require that
 * resolves to it, or its repo-relative path as a literal (spawned scripts). A matching stem alone is
 * not enough: basename collisions across directories let an unrelated deleted file launder the
 * deletion of a test whose real subject still ships.
 */
function testReferencesSubject(testBlock, subjectPath) {
  for (const line of testBlock.removed) {
    if (line.includes(subjectPath)) return true;
    for (const match of line.matchAll(IMPORT_SPECIFIER_RE)) {
      const spec = match[1];
      if (spec.startsWith('.') && resolveRelative(testBlock.path, spec) === subjectPath) return true;
    }
  }
  return false;
}

/** The deleted non-test subject this deleted test was retired with, or null. */
function retiredSubjectOf(testBlock, deletedSubjects) {
  const stem = stemOf(testBlock.path);
  return (
    deletedSubjects.find((b) => stemOf(b.path) === stem && testReferencesSubject(testBlock, b.path))?.path || null
  );
}

/** Signal relevant across any file — decrease in ratchet vocabulary key values. */
function thresholdSignals(block) {
  const before = collectRatchetValues(block.removed);
  const after = collectRatchetValues(block.added);
  const out = [];
  for (const [key, oldValue] of before) {
    const newValue = after.get(key);
    if (newValue === undefined || newValue >= oldValue) continue;
    out.push({
      signal: BAR_MOVE.THRESHOLD_LOWERED,
      path: block.path,
      detail: `${key} ${oldValue} → ${newValue} (lowered)`,
    });
  }
  return out;
}

/**
 * Evaluates five signals of "proposer lowering criteria" from diff (pure function).
 *
 * Each finding is `{signal, path, detail}` — `detail` contains facts for human evaluation.
 * Returns empty array on unevaluable/missing input (fail-open, R-CM-006 Rule 2).
 *
 * @param {string} diffText Output of `git diff <base>..HEAD`
 * @returns {Array<{signal: string, path: string, detail: string}>}
 */
export function detectBarMove(diffText) {
  const findings = [];
  const blocks = parseUnifiedDiff(diffText);

  // Deleted non-test files in the same diff. A deleted test that shares a stem with one of these
  // *and* referenced it was retired alongside its subject (e.g. a hook removed together with its
  // test), not relaxed — see TEST_RETIRED_WITH_SUBJECT below.
  const deletedSubjects = blocks.filter((b) => b.deleted && !isTestPath(b.path));

  for (const block of blocks) {
    const isTest = isTestPath(block.path);

    // Report only 1 deletion for deleted files — total removal causes all other signals to trail.
    if (isTest && block.deleted) {
      const subject = retiredSubjectOf(block, deletedSubjects);
      if (subject) {
        findings.push({
          signal: BAR_MOVE.TEST_RETIRED_WITH_SUBJECT,
          path: block.path,
          detail: `Test file deleted alongside its subject module (${subject}) — retirement, not relaxation`,
        });
      } else {
        findings.push({
          signal: BAR_MOVE.TEST_FILE_DELETED,
          path: block.path,
          detail: `Test file deleted (removed lines ${block.removed.length})`,
        });
      }
      continue;
    }

    if (isTest) findings.push(...testFileSignals(block));
    findings.push(...thresholdSignals(block));
  }

  return findings;
}

/** Returns empty array if not an array — absorbs report structural anomalies without caller branching. */
function asArray(value) {
  return Array.isArray(value) ? value : [];
}

/** Tests whether case passed on retry (passed + contains failure messages). */
function isRetryPass(testCase) {
  return testCase?.status === 'passed' && asArray(testCase.failureMessages).length > 0;
}

/**
 * Identifies flaky cases (passed after retry) from vitest json reports (pure function).
 *
 * Based on empirical measurement (vitest 4.1.10, 2026-08-11): Cases that passed after `--retry` have
 * `status: "passed"` while `failureMessages` is non-empty. Cases passing on first attempt have
 * empty `failureMessages` arrays. Because both states are distinguished in the report, no separate runs are required.
 *
 * **Limitations (transparent statement)**: Reports generated without `--retry` always yield empty arrays —
 * without retries, first failures are immediately recorded as failures. This function does not prove
 * "no flaky tests exist"; it reports only what the report observed. Callers should indicate whether `--retry` was used.
 *
 * @param {object|null} report vitest `--reporter=json` output
 * @returns {Array<{file: string, name: string, message: string}>}
 */
export function detectFlakyTests(report) {
  const flaky = [];

  for (const suite of asArray(report?.testResults)) {
    const file = typeof suite?.name === 'string' ? suite.name : '(unknown)';
    for (const testCase of asArray(suite?.assertionResults).filter(isRetryPass)) {
      const name = testCase.fullName ?? testCase.title ?? '';
      flaky.push({
        file,
        name: String(name),
        message: String(asArray(testCase.failureMessages)[0] ?? '').split('\n')[0],
      });
    }
  }

  return flaky;
}

/**
 * Multiple of CPU count above which the machine is treated as unable to give any test a fair shot.
 *
 * Derived, not picked: the suite runs `cpus - 1` vitest workers, so **we ourselves occupy roughly one
 * machine**. Crossing two machines' worth therefore means at least a full machine of *external*
 * contention. Measured on a 16-CPU box across six full-gate runs (2026-08-25 → 09-02): load 26
 * (1.6x) ran clean, while 33 / 74 / 86 / 134 / 267 (2.1x - 16.7x) each produced retry-passes — every
 * one in a *different* test, every one outside the branch's own changeset, every one passing 3/3
 * standalone. `2x` is the only cut that separates all six observations.
 */
export const LOAD_SATURATION_MULTIPLE = 2;

/**
 * Decides whether a retry-pass verdict can be trusted, given how loaded the machine was (pure function).
 *
 * Why this exists: "this test passed only on retry, therefore it is defective" is a valid inference
 * *only if the test was given a fair shot*. A saturated box starves whichever test happens to lose
 * the scheduling race, so the same gate condemns a different innocent test each run. That is not
 * flakiness detection — it is noise wearing a verdict's clothing, and it blocked shipping four times
 * in one session while the real defects it named lived in unrelated files.
 *
 * This does **not** soften the bar. `measured: false` already exists in this loop's vocabulary for a
 * missing or unparseable report, and the CLI deliberately exits 0 on it: *unmeasured is distinct from
 * a violation*. Machine saturation is simply another reason the run could not be measured. Findings
 * stay visible either way — the caller is expected to print them as observations rather than drop them.
 *
 * `loadAvg` takes the max across the 1/5/15-minute windows: any window being saturated means part of
 * the run happened on a contended box. Platforms that do not implement load average (Windows reports
 * zeros) yield `saturated: false`, i.e. exactly today's behaviour — silent, but honest, since we then
 * have no evidence of contention to report.
 *
 * @param {{loadAvg?: number[], cpuCount?: number, multiple?: number}} [env]
 * @returns {{saturated: boolean, load: number, cpuCount: number, ratio: number, threshold: number}}
 */
export function classifyLoadMeasurability({
  loadAvg = [],
  cpuCount = 0,
  multiple = LOAD_SATURATION_MULTIPLE,
} = {}) {
  const windows = asArray(loadAvg).filter((n) => typeof n === 'number' && Number.isFinite(n) && n > 0);
  const load = windows.length > 0 ? Math.max(...windows) : 0;
  const cpus = Number.isFinite(cpuCount) && cpuCount > 0 ? cpuCount : 0;
  const threshold = cpus * multiple;
  const ratio = cpus > 0 ? load / cpus : 0;
  return { saturated: cpus > 0 && load > threshold, load, cpuCount: cpus, ratio, threshold };
}

/**
 * Formats findings into a ship warning string. Returns null on empty input (prevents caller pushing empty entries).
 * Conforms to Rule 2 "Make judges explain themselves" — provides actionable reasons rather than raw numbers.
 *
 * @param {Array<{signal: string, path: string, detail: string}>} findings
 * @returns {string|null}
 */
export function formatBarMoveWarning(findings) {
  if (!Array.isArray(findings) || findings.length === 0) return null;
  // TEST_RETIRED_WITH_SUBJECT is informational (retirement, not relaxation) — surfaced via
  // detectBarMove()'s return value for callers that want it, but never counted toward the
  // "baseline relaxation" warning below (that would misrepresent legitimate cleanup as goalpost-moving).
  const relaxations = findings.filter((f) => f.signal !== BAR_MOVE.TEST_RETIRED_WITH_SUBJECT);
  if (relaxations.length === 0) return null;
  const lines = relaxations.map((f) => `  - [${f.signal}] ${f.path}: ${f.detail}`);
  return (
    `Self-scoring baseline relaxation detected (${relaxations.length} findings) — this PR includes changes that lower evaluation standards.\n`
    + `${lines.join('\n')}\n`
    + 'If this relaxation is intentional, record the rationale under Trade-offs in the Pre-Ship Panel and proceed '
    + '(non-blocking). If unintentional, revert the changes before shipping again (R-CM-041 Rule 6).'
  );
}
