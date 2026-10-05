import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';

import { evalCondition } from '../lib/swift-bar-move.mjs';
import { readFileSync } from 'node:fs';
import { compareRuns, parseEventStream, runCompleted, testKey } from '../lib/test-run.mjs';

// Real Swift Testing 6.3 output (scrubbed of paths/backtraces) from a scratch package covering: a
// plain test, an *unnamed* parameterized test, a named one, `arguments: 0..<0`, a failure, a known
// issue and `.disabled` — INC-011: the parser is proven on what swift test actually emits.
const REAL = readFileSync(new URL('./fixtures/swift-testing-events-v0.jsonl', import.meta.url), 'utf-8');
const k = (fn, line) => `LibTests.S/${fn}/T.swift`;

test('INC-011: parseEventStream reads status and case counts from real event-stream output', () => {
  const m = parseEventStream(REAL);
  assert.deepEqual(m.get(k('plain()')), { status: 'passed', cases: 0 });
  assert.deepEqual(m.get(k('unnamed(_:)')), { status: 'passed', cases: 3 });
  assert.deepEqual(m.get(k('named(_:)')), { status: 'passed', cases: 2 });
  assert.equal(m.get(k('empty(_:)')).status, 'skipped');
  assert.equal(m.get(k('fails()')).status, 'failed');
  assert.equal(m.get(k('known()')).status, 'passed', 'a known issue is not a failure');
  assert.equal(m.get(k('off()')).status, 'skipped');
  assert.equal(m.has('LibTests.S'), false, 'suites are not tests');
});

test('runCompleted distinguishes a finished run (even with failures) from a crashed one', () => {
  assert.equal(runCompleted(REAL), true, 'the real fixture contains a failing test and still completed');
  assert.equal(runCompleted(REAL.split('\n').filter((l) => !l.includes('runEnded')).join('\n')), false);
});

test('testKey drops line:col so moving a test inside its file is not a change', () => {
  assert.equal(testKey('M.S/f()/A.swift:10:6'), 'M.S/f()/A.swift');
  assert.equal(testKey('M.S'), null);
});

const ev = (kind, id, extra = {}) => JSON.stringify({ kind: 'event', version: 0, payload: { kind, testID: id, ...extra } });
const runOf = (...lines) => parseEventStream(lines.join('\n'));
const passedWith = (id, cases) => [ev('testStarted', id), ...Array.from({ length: cases }, () => ev('testCaseStarted', id)), ev('testEnded', id)];

test('INC-009: tests that passed on the trunk but did not pass on the branch are found, however they were switched off', () => {
  const base = runOf(...passedWith('M.S/a()/A.swift:1:1', 0), ...passedWith('M.S/b()/A.swift:2:1', 0), ...passedWith('M.S/c(_:)/A.swift:3:1', 3));
  const head = runOf(ev('testSkipped', 'M.S/a()/A.swift:1:1'), ...passedWith('M.S/c(_:)/A.swift:9:1', 1));
  const got = compareRuns(base, head).map((f) => `${f.signal}:${f.id}`).sort();
  assert.deepEqual(got, ['cases_reduced:M.S/c(_:)/A.swift', 'test_not_run:M.S/b()/A.swift', 'test_skipped:M.S/a()/A.swift']);
});

test('INC-011: unnamed tests and duplicate display names are compared per test id', () => {
  // Two suites each with a test displayed as "roundtrip": ids differ, so a drop in one is not hidden.
  const base = runOf(...passedWith('M.A/roundtrip(_:)/A.swift:1:1', 3), ...passedWith('M.B/roundtrip(_:)/B.swift:1:1', 3));
  const head = runOf(...passedWith('M.A/roundtrip(_:)/A.swift:1:1', 3), ...passedWith('M.B/roundtrip(_:)/B.swift:1:1', 1));
  assert.deepEqual(compareRuns(base, head).map((f) => f.id), ['M.B/roundtrip(_:)/B.swift']);
});

test('INC-011: overloads sharing a key are merged worst-first, so a passing one cannot hide a skipped one', () => {
  const base = runOf(...passedWith('M.S/r(_:)/A.swift:1:1', 0), ...passedWith('M.S/r(_:)/A.swift:5:1', 0));
  const head = runOf(ev('testSkipped', 'M.S/r(_:)/A.swift:1:1'), ...passedWith('M.S/r(_:)/A.swift:5:1', 0));
  assert.deepEqual(compareRuns(base, head).map((f) => f.signal), ['test_skipped']);
});

test('INC-009: a parameterized test that now runs zero cases is flagged; identical runs are clean', () => {
  const base = parseEventStream(REAL);
  const head = new Map(base);
  head.set(k('unnamed(_:)'), { status: 'skipped', cases: 0 }); // what `arguments: 0..<0` looks like
  assert.deepEqual(compareRuns(base, head).map((f) => f.signal), ['test_skipped']);
  assert.deepEqual(compareRuns(base, base), []);
});

test('INC-009: #if conditions are compared, not assumed true', () => {
  assert.equal(evalCondition('swift(<5.0)'), false);
  assert.equal(evalCondition('swift(>=5.9)'), true);
  assert.equal(evalCondition('compiler(<6.0)'), false);
  assert.equal(evalCondition('canImport(NoSuchModule)'), false);
  assert.equal(evalCondition('canImport(AppKit)'), true);
  assert.equal(evalCondition('canImport(MCACore)'), true);
  assert.equal(evalCondition(`arch(${process.arch === 'arm64' ? 'x86_64' : 'arm64'})`), false);
});

test('the Swift version the evaluator assumes matches the installed toolchain', () => {
  let out;
  try {
    out = execFileSync('swift', ['--version'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch {
    return; // no toolchain in this environment: nothing to drift against
  }
  const [, major, minor] = /Swift version (\d+)\.(\d+)/.exec(out) ?? [];
  assert.equal(evalCondition(`swift(>=${major}.${minor})`), true);
  assert.equal(evalCondition(`swift(>=${major}.${Number(minor) + 1})`), false, 'update TARGET.swift in swift-bar-move.mjs');
});
