import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { detectBarMove } from '../../../.cli/lib/self-improving-loop.mjs';
import { addsRegressionTest, detectSwiftBarMove, measure, SWIFT_BAR_MOVE, stripInactiveRegions, stripNonCode } from '../lib/swift-bar-move.mjs';

// A real test file from this repository, so the detector is proven on what it will actually see.
const REAL_PATH = 'Tests/MCACoreTests/ScreenWatchPolicyTests.swift';
const REAL = readFileSync(new URL(`../../../${REAL_PATH}`, import.meta.url), 'utf-8');

const signals = (before, after, path = REAL_PATH) => detectSwiftBarMove([{ path, before, after }]).map((f) => f.signal).sort();

test('INC-001: managed detectBarMove does not see Swift test deletion (why this module exists)', () => {
  const diff = `diff --git a/${REAL_PATH} b/${REAL_PATH}\ndeleted file mode 100644\n--- a/${REAL_PATH}\n+++ /dev/null\n@@ -1 +0,0 @@\n-#expect(a == b)\n`;
  assert.deepEqual(detectBarMove(diff), []);
  assert.deepEqual(signals(REAL, null), [SWIFT_BAR_MOVE.TEST_FILE_DELETED]);
});

test('the real file measures non-zero and unchanged content is not a bar move', () => {
  const m = measure(REAL);
  assert.ok(m.asserts > 0 && m.tests > 0, JSON.stringify(m));
  assert.deepEqual(signals(REAL, REAL), []);
});

test('removing one assertion from the real file is flagged', () => {
  const idx = REAL.indexOf('#expect');
  const lineEnd = REAL.indexOf('\n', idx);
  const weakened = REAL.slice(0, idx) + REAL.slice(lineEnd + 1);
  assert.deepEqual(signals(REAL, weakened), [SWIFT_BAR_MOVE.ASSERTION_REMOVED]);
});

test('INC-002: block comment around a test is seen even though the diff only shows /* and */', () => {
  const at = REAL.indexOf('@Test');
  const commented = `${REAL.slice(0, at)}/*\n${REAL.slice(at)}\n*/\n`;
  const s = signals(REAL, commented);
  assert.ok(s.includes(SWIFT_BAR_MOVE.ASSERTION_REMOVED) && s.includes(SWIFT_BAR_MOVE.TEST_REMOVED), s.join());
});

test('INC-002: #if false region disables tests; #else branch stays active', () => {
  const at = REAL.indexOf('@Test');
  const dead = `${REAL.slice(0, at)}#if false\n${REAL.slice(at)}\n#endif\n`;
  assert.ok(signals(REAL, dead).includes(SWIFT_BAR_MOVE.TEST_REMOVED));
  assert.equal(stripInactiveRegions('#if false\na\n#else\nb\n#endif\nc'), 'b\nc');
  assert.equal(stripInactiveRegions('#if false\n#if os(macOS)\na\n#endif\nb\n#endif\nc'), 'c');
});

test('INC-002: custom-flag #if, .enabled(if:), .disabled and withKnownIssue are flagged', () => {
  const at = REAL.indexOf('@Test');
  assert.ok(signals(REAL, `${REAL.slice(0, at)}#if SKIP_THESE\n${REAL.slice(at)}\n#endif\n`).includes(SWIFT_BAR_MOVE.CONDITIONAL_COMPILATION));
  assert.ok(signals(REAL, REAL.replace('@Test', '@Test(.enabled(if: false))')).includes(SWIFT_BAR_MOVE.DISABLED_ADDED));
  assert.ok(signals(REAL, REAL.replace('@Test', '@Test(.disabled("flaky"))')).includes(SWIFT_BAR_MOVE.DISABLED_ADDED));
  assert.ok(signals(REAL, `${REAL}\nfunc x() { withKnownIssue { } }\n`).includes(SWIFT_BAR_MOVE.DISABLED_ADDED));
  // platform conditions are legitimate
  assert.deepEqual(signals(REAL, `${REAL}\n#if os(macOS)\n#endif\n`), []);
});

test('patterns in comments and strings never count; nested block comments are handled', () => {
  assert.equal(measure('// #expect(a)\nlet s = "#expect(x)"\n/* a /* #expect(b) */ still comment #expect(c) */').asserts, 0);
  assert.equal(measure('let s = """\n#expect(x)\n"""\n#expect(y)').asserts, 1);
  assert.equal(stripNonCode('a // b\nc').split('\n').length, 2);
});

test('rewriting an assertion in place is not a bar move', () => {
  assert.deepEqual(signals('@Test func a() { #expect(a == 1) }', '@Test func a() { #expect(a == 2) }', 'Tests/X/A.swift'), []);
});

test('non-test Swift files and new test files are ignored', () => {
  assert.deepEqual(signals('#expect(a)', null, 'Sources/MCACore/A.swift'), []);
  assert.deepEqual(signals(null, '@Test func a() {}', 'Tests/X/New.swift'), []);
});

test('addsRegressionTest requires a net gain of active assertions under Tests/', () => {
  assert.equal(addsRegressionTest([{ path: 'Tests/X/A.swift', before: null, after: '#expect(fixed)' }]), true);
  assert.equal(addsRegressionTest([{ path: 'Tests/X/A.swift', before: '#expect(a)', after: '#expect(b)' }]), false);
  assert.equal(addsRegressionTest([{ path: 'Tests/X/A.swift', before: null, after: '// #expect(fixed)' }]), false);
  assert.equal(addsRegressionTest([{ path: 'Sources/X/A.swift', before: null, after: '#expect(fixed)' }]), false);
});

test('INC-005: platform #if branches are evaluated for the macOS debug build', () => {
  const at = REAL.indexOf('@Test');
  const wrap = (open, close = '#endif') => `${REAL.slice(0, at)}${open}\n${REAL.slice(at)}\n${close}\n`;
  assert.ok(signals(REAL, wrap('#if os(Linux)')).includes(SWIFT_BAR_MOVE.TEST_REMOVED));
  assert.ok(signals(REAL, wrap('#if !DEBUG')).includes(SWIFT_BAR_MOVE.TEST_REMOVED));
  assert.ok(signals(REAL, `${REAL.slice(0, at)}#if os(macOS)\n#else\n${REAL.slice(at)}\n#endif\n`).includes(SWIFT_BAR_MOVE.TEST_REMOVED));
  // the active branch of a platform check is not a bar move
  assert.deepEqual(signals(REAL, wrap('#if os(macOS)')), []);
  assert.deepEqual(signals(REAL, wrap('#if canImport(AppKit)')), []);
});

test('INC-005: a new file defining a disabling ConditionTrait is flagged', () => {
  const after = 'import Testing\nextension Trait where Self == ConditionTrait {\n  static var nightly: Self { .enabled(if: false) }\n}\n';
  assert.ok(signals(null, after, 'Tests/MCACoreTests/Traits.swift').includes(SWIFT_BAR_MOVE.DISABLED_ADDED));
});

test('INC-005: parameterized tests fed an empty collection are flagged', () => {
  const before = '@Test(arguments: [1, 2]) func a(x: Int) { #expect(x > 0) }';
  for (const empty of ['[Int]()', '[]', 'Array<Int>()', 'EmptyCollection<Int>()']) {
    assert.ok(signals(before, before.replace('[1, 2]', empty), 'Tests/X/A.swift').includes(SWIFT_BAR_MOVE.EMPTY_ARGUMENTS), empty);
  }
});

test('raw strings do not count as code', () => {
  assert.equal(measure('let s = #"x" #expect(2 == 2) "#\n#expect(1)').asserts, 1);
  assert.equal(measure('let s = ##"a"# #expect(x) "##\n').asserts, 0);
});
