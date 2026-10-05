/**
 * End-to-end over real `git diff` output (INC-002). Unit tests fed hand-written diff strings passed
 * while the real pipeline was blind to `.gitattributes -diff`, NUL bytes, `diff.noprefix` and quoted
 * non-ASCII paths — each case below reproduces one of those against a throwaway repository whose
 * local git config is deliberately hostile.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';

import { classifyChange } from '../lib/classify.mjs';
import { detectSwiftBarMove } from '../lib/swift-bar-move.mjs';
import { analyzeBranch, loadTrunkPolicy, reviewDiffId } from '../trust.mjs';

const ROOT = new URL('../../../', import.meta.url);
const REAL_TEST = readFileSync(new URL('Tests/MCACoreTests/ScreenWatchPolicyTests.swift', ROOT), 'utf-8');
const POLICY = readFileSync(new URL('data/trust/policy.json', ROOT), 'utf-8');

let repo;
const g = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] });
const write = (rel, text) => {
  mkdirSync(dirname(join(repo, rel)), { recursive: true });
  writeFileSync(join(repo, rel), text);
};
const commit = (msg) => {
  g('add', '-A');
  g('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', msg);
};
function branch(name, mutate) {
  g('checkout', '-q', 'main');
  g('checkout', '-qb', name);
  mutate();
  commit(name);
  const { policy } = loadTrunkPolicy(repo, 'main');
  const a = analyzeBranch(repo, 'main');
  return { ...a, classification: classifyChange({ files: a.files }, policy), barMove: detectSwiftBarMove(a.testFiles).map((f) => f.signal) };
}
const ids = (r) => r.classification.escalations.map((e) => e.id).sort();

before(() => {
  repo = mkdtempSync(join(tmpdir(), 'trust-it-'));
  g('init', '-q', '-b', 'main');
  // Hostile local config: every one of these used to blind the parser.
  g('config', 'core.quotepath', 'true');
  g('config', 'diff.noprefix', 'true');
  g('config', 'diff.mnemonicPrefix', 'true');
  write('data/trust/policy.json', POLICY);
  write('Tests/MCACoreTests/ScreenWatchPolicyTests.swift', REAL_TEST);
  write('Tests/MCACoreTests/Tëst.swift', REAL_TEST);
  write('Sources/MCAMemory/SQLite.swift', 'let schema = "CREATE TABLE a(x)"\n');
  write('Sources/MCAPresentation/View.swift', Array.from({ length: 50 }, (_, i) => `let v${i} = ${i}`).join('\n') + '\n');
  write('Sources/MCACore/Logic.swift', 'let a = 1\n');
  write('Sources/MCAMemory/Store.swift', 'let schema = """\n  CREATE TABLE t (\n    a INTEGER\n  )\n  """\n');
  commit('base');
});

after(() => rmSync(repo, { recursive: true, force: true }));

test('baseline: an ordinary logic change is eligible and clean', () => {
  const r = branch('ok', () => write('Sources/MCACore/Logic.swift', 'let a = 2\n'));
  assert.deepEqual(ids(r), []);
  assert.deepEqual(r.barMove, []);
  assert.deepEqual(r.classification.categories, ['src:MCACore']);
});

test('INC-002: .gitattributes -diff cannot hide schema, UI size or assertion removal', () => {
  const r = branch('attrs', () => {
    write('.gitattributes', 'Tests/** -diff\nSources/** -diff\n');
    write('Sources/MCAMemory/SQLite.swift', 'let schema = "CREATE TABLE a(x, y)"\n');
    write('Sources/MCAPresentation/View.swift', Array.from({ length: 400 }, (_, i) => `let w${i} = ${i}`).join('\n') + '\n');
    write('Tests/MCACoreTests/ScreenWatchPolicyTests.swift', REAL_TEST.replace(/^.*#expect.*\n/m, ''));
  });
  for (const id of ['governance', 'persistence', 'ui_major']) assert.ok(ids(r).includes(id), `${id} missing: ${ids(r)}`);
  assert.ok(r.barMove.includes('assertion_removed'), r.barMove.join());
});

test('INC-002: a NUL byte does not turn a test file into an unmeasured binary', () => {
  const r = branch('nul', () => write('Tests/MCACoreTests/ScreenWatchPolicyTests.swift', REAL_TEST.replace(/^.*#expect.*\n/m, '') + '// \0\n'));
  assert.ok(r.barMove.includes('assertion_removed'), r.barMove.join());
  assert.ok(r.files.every((f) => f.added + f.removed > 0), JSON.stringify(r.files));
});

test('INC-008: a file the reviewer is shown as "Binary files differ" escalates as unmeasurable', () => {
  const r = branch('hidden', () => write('Sources/MCACore/Logic.swift', 'let a = 3 // \0\n'));
  assert.ok(ids(r).includes('unmeasurable'), ids(r).join());
  const real = branch('realbin', () => write('Sources/MCACore/blob.bin', Buffer.from([0, 1, 2, 10, 0, 255]).toString('latin1')));
  assert.ok(ids(real).includes('unmeasurable'), ids(real).join());
});

test('INC-002: non-ASCII path deletion is seen despite core.quotepath=true', () => {
  const r = branch('nonascii', () => rmSync(join(repo, 'Tests/MCACoreTests/Tëst.swift')));
  assert.deepEqual(r.files.map((f) => f.path), ['Tests/MCACoreTests/Tëst.swift']);
  assert.deepEqual(r.barMove, ['test_file_deleted']);
});

test('moving a test out of Tests/ counts as a deletion', () => {
  const r = branch('move', () => {
    execFileSync('git', ['-C', repo, 'mv', 'Tests/MCACoreTests/ScreenWatchPolicyTests.swift', 'Sources/MCACore/Moved.swift']);
  });
  assert.ok(r.barMove.includes('test_file_deleted'), r.barMove.join());
});

test('lowercase SQL still escalates persistence', () => {
  const r = branch('lower', () => write('Sources/MCAMemory/SQLite.swift', 'let schema = "create table a(x, y)"\n'));
  assert.deepEqual(ids(r), ['persistence']);
});

test('INC-003: policy comes from the trunk, not from the branch', () => {
  const r = branch('relax', () => {
    const p = JSON.parse(POLICY);
    p.fatal_risk = [];
    write('data/trust/policy.json', JSON.stringify(p));
    write('Sources/MCAMemory/SQLite.swift', 'let schema = "ALTER TABLE a ADD y"\n');
  });
  assert.ok(ids(r).includes('persistence') && ids(r).includes('governance'), ids(r).join());
});

test('reviewDiffId is stable under the hostile config and changes with the branch', () => {
  g('checkout', '-q', 'ok');
  const a = reviewDiffId(repo, 'main');
  g('checkout', '-q', 'lower');
  assert.notEqual(reviewDiffId(repo, 'main'), a);
  assert.match(a, /^[0-9a-f]{64}$/);
});

test('INC-016: editing a column inside an existing CREATE TABLE escalates persistence', () => {
  const r = branch('column', () => write('Sources/MCAMemory/Store.swift', 'let schema = """\n  CREATE TABLE t (\n    a TEXT\n  )\n  """\n'));
  assert.deepEqual(ids(r), ['persistence']);
});

test('INC-015: a trunk policy that does not parse is an error, not a reason to use the branch copy', () => {
  g('checkout', '-q', 'main');
  g('checkout', '-qb', 'broken-trunk');
  write('data/trust/policy.json', '{ not json');
  commit('broken');
  assert.throws(() => loadTrunkPolicy(repo, 'broken-trunk'));
});
