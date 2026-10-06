import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { answerStorePath, recordAnswer, resolveReviewDiffId } from '../../../.claude/scripts/lib/pre-ship-steps.mjs';
import { checksVerdict, reconcileTrustLedger, waitChecks } from '../../../.claude/scripts/create-pr/ops.mjs';
import { parseArgs as parsePreShipArgs } from '../../../.claude/scripts/pre-ship-steps.mjs';
import { categoryOf, classifyChange, globToRegExp, validatePolicy } from '../lib/classify.mjs';
import { decide, REQUIRED_EVIDENCE } from '../lib/decide.mjs';
import { checkIncidents } from '../lib/incidents.mjs';
import { breakerState, summarize } from '../lib/ledger.mjs';
import { validateReview } from '../lib/review.mjs';
import { normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';
import { ciEvidenceFromReport, diffIdOf, humanAnswer, isEntryPoint, recordTrustApproval } from '../trust.mjs';

const policy = JSON.parse(readFileSync(new URL('../../../data/trust/policy.json', import.meta.url), 'utf-8'));
const file = (path, loc = 10, lines = {}) => ({ path, added: loc, removed: 0, ...lines });

// ------------------------------------------------------------------ classify

test('glob: ** spans directories, * stays in one segment', () => {
  assert.ok(globToRegExp('Sources/MCAPresentation/**').test('Sources/MCAPresentation/a/b.swift'));
  assert.ok(globToRegExp('**/*.entitlements').test('mca.entitlements'));
  assert.ok(globToRegExp('**/*.entitlements').test('a/b/mca.entitlements'));
  assert.ok(!globToRegExp('docs/architecture_*.md').test('docs/x/architecture_a.md'));
});

test('ordinary logic change is eligible, not escalated', () => {
  const c = classifyChange({ files: [file('Sources/MCAReasoning/Loop.swift'), file('Tests/MCAReasoningTests/LoopTests.swift')] }, policy);
  assert.deepEqual(c.escalations, []);
  assert.deepEqual(c.categories, ['src:MCAReasoning', 'tests']);
});

test('the evaluator itself always escalates as governance', () => {
  for (const p of ['Scripts/gate.sh', 'data/trust/policy.json', 'Scripts/trust/lib/decide.mjs', '.claude/settings.json', 'AGENTS.md']) {
    const c = classifyChange({ files: [file(p)] }, policy);
    assert.deepEqual(c.escalations.map((e) => e.id), ['governance'], p);
  }
});

test('persistence escalates only when a schema statement changes', () => {
  const plain = classifyChange({ files: [file('Sources/MCAMemory/SQLite.swift', 5, { addedLines: ['let x = 1'] })] }, policy);
  assert.deepEqual(plain.escalations, []);
  const schema = classifyChange(
    { files: [file('Sources/MCAMemory/SQLite.swift', 5, { addedLines: ['"ALTER TABLE ctx ADD COLUMN y"'] })] },
    policy,
  );
  assert.deepEqual(schema.escalations.map((e) => e.id), ['persistence']);
});

test('UI escalates only above min_loc; scale escalates above the cap', () => {
  assert.deepEqual(classifyChange({ files: [file('Sources/MCAPresentation/A.swift', 40)] }, policy).escalations, []);
  assert.deepEqual(
    classifyChange({ files: [file('Sources/MCAPresentation/A.swift', 200)] }, policy).escalations.map((e) => e.id),
    ['ui_major'],
  );
  const many = Array.from({ length: 10 }, (_, i) => file(`Sources/MCACore/F${i}.swift`, 1));
  assert.deepEqual(classifyChange({ files: many }, policy).escalations.map((e) => e.id), ['scale']);
  assert.deepEqual(classifyChange({ files: many.slice(0, 9) }, policy).escalations, []);
  assert.deepEqual(classifyChange({ files: [file('Sources/MCACore/A.swift', 300)] }, policy).escalations.map((e) => e.id), ['scale']);
});

test('INC-017: irreversible effects escalate: every schema object kind, and any edit to a file that deletes', () => {
  const sql = classifyChange({ files: [file('Sources/MCAMemory/Other.swift', 2, { addedLines: ['db.exec("create table t(x)")'] })] }, policy);
  assert.deepEqual(sql.escalations.map((e) => [e.id, e.axis]), [['persistence', 'irreversible']]);
  const del = classifyChange({ files: [file('Sources/MCACore/Cache.swift', 1, { addedLines: ['try FileManager.default.removeItem(at: url)'] })] }, policy);
  assert.deepEqual(del.escalations.map((e) => e.id), ['destructive']);
  // A file that performs deletion escalates on any edit: changing a path on another line changes what is deleted.
  const retarget = classifyChange(
    { files: [file('Sources/MCACore/Cache.swift', 1, { addedLines: ['let dir = home'], before: 'let dir = tmp\ntry FileManager.default.removeItem(at: dir)\n', after: 'let dir = home\ntry FileManager.default.removeItem(at: dir)\n' })] },
    policy,
  );
  assert.deepEqual(retarget.escalations.map((e) => e.id), ['destructive']);
  assert.deepEqual(classifyChange({ files: [file('Sources/MCACore/Cache.swift', 1, { addedLines: ['let a = 1'], before: 'let a = 0\n', after: 'let a = 1\n' })] }, policy).escalations, []);
  for (const stmt of ['CREATE VIRTUAL TABLE f USING fts5(x)', 'CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END', 'create unique index i on a(x)', 'DROP VIEW v']) {
    const c = classifyChange({ files: [file('Sources/MCAMemory/New.swift', 1, { addedLines: [`let s = "${stmt}"`] })] }, policy);
    assert.deepEqual(c.escalations.map((e) => e.id), ['persistence'], stmt);
  }
});

test('security and pivot paths escalate', () => {
  assert.deepEqual(classifyChange({ files: [file('Sources/MCAReasoning/SafetyGuardrails.swift', 1)] }, policy).escalations.map((e) => e.id), ['security']);
  assert.deepEqual(classifyChange({ files: [file('docs/features/x/SPEC.md', 1)] }, policy).escalations.map((e) => e.id), ['pivot']);
});

test('categoryOf buckets', () => {
  assert.equal(categoryOf('Sources/mca/main.swift'), 'src:mca');
  assert.equal(categoryOf('README.md'), 'docs');
  assert.equal(categoryOf('Scripts/run.sh'), 'scripts');
});

// ------------------------------------------------------------------ review

const DIFF = 'a'.repeat(64);
const goodReview = { diff_id: DIFF, reviewer: 'fresh-context subagent', verdict: 'go', findings: [{ severity: 'LOW', file: 'a', summary: 's' }] };

test('review must be bound to the current diff', () => {
  assert.equal(validateReview(goodReview, DIFF).ok, true);
  assert.equal(validateReview({ ...goodReview, diff_id: 'b'.repeat(64) }, DIFF).ok, false);
  assert.equal(validateReview(goodReview, null).ok, false);
  assert.equal(validateReview(null, DIFF).ok, false);
});

test('unresolved HIGH blocks; resolved HIGH does not; unknown severity is malformed', () => {
  const high = { severity: 'HIGH', file: 'a', summary: 's' };
  assert.equal(validateReview({ ...goodReview, findings: [high] }, DIFF).ok, false);
  assert.equal(validateReview({ ...goodReview, findings: [{ ...high, resolved: true }] }, DIFF).ok, true);
  assert.equal(validateReview({ ...goodReview, findings: [{ severity: 'IMPORTANT' }] }, DIFF).ok, false);
  assert.equal(validateReview({ ...goodReview, verdict: 'no-go' }, DIFF).ok, false);
});

// ------------------------------------------------------------------ ledger

const assessment = (id, decision, escalations = []) => ({ type: 'assessment', diff_id: id, decision, categories: ['src:MCACore'], escalations, at: '2026-09-27T00:00:00Z' });
const human = (id, decision) => ({ type: 'human', diff_id: id, decision, at: '2026-09-27T01:00:00Z' });
const escape = (at, categories = ['src:MCACore']) => ({ type: 'escape', categories, incident: 'INC-001', at });
const breakerCfg = { since: '2026-09-26T00:00:00Z', max_escapes: 2 };

test('one escape freezes its categories; max_escapes stops everything; escapes before `since` do not count', () => {
  assert.deepEqual(breakerState([], breakerCfg), { escapes: 0, tripped: false, frozen: [] });
  const one = breakerState([escape('2026-09-27T00:00:00Z')], breakerCfg);
  assert.deepEqual(one, { escapes: 1, tripped: false, frozen: ['src:MCACore'] });
  const two = breakerState([escape('2026-09-27T00:00:00Z'), escape('2026-09-28T00:00:00Z', ['tests'])], breakerCfg);
  assert.equal(two.tripped, true);
  assert.deepEqual(breakerState([escape('2026-09-25T00:00:00Z')], breakerCfg).frozen, []);
});

test('summary separates over-escalation from revisions; a revise stays sticky over a later approve', () => {
  const s = summarize([
    assessment('1', 'auto_merge'),
    assessment('2', 'human', ['ui_major']),
    human('2', 'approve'),
    assessment('3', 'human', ['ui_major']),
    human('3', 'revise'),
    human('3', 'approve'),
  ]);
  assert.equal(s.auto_merge, 1);
  assert.equal(s.human, 2);
  assert.equal(s.over_escalation, 1);
  assert.equal(s.revised, 1);
  assert.deepEqual(s.by_rule.ui_major, { approved_unchanged: 1, revised: 1 });
});

// ------------------------------------------------------------------ decide

const green = REQUIRED_EVIDENCE.map((id) => ({ id, ok: true, detail: '' }));
const eligible = { escalations: [], categories: ['src:MCACore'] };
const open = { tripped: false, frozen: [], escapes: 0 };

test('INC-003: decision ladder (fatal risk, breaker and missing evidence each stop auto-merge)', () => {
  const run = (over) => decide({ classification: eligible, evidence: green, policy, breaker: open, ...over });
  assert.equal(run({}).decision, 'auto_merge');
  const fatal = { escalations: [{ id: 'security', axis: 'blast_radius', if_wrong: 'x', paths: [] }], categories: ['src:MCACore'] };
  assert.equal(run({ classification: fatal }).decision, 'human');
  assert.match(run({ classification: fatal }).reasons[0], /fatal:blast_radius\/security/);
  assert.equal(run({ evidence: [...green, { id: 'bar_move', ok: false, detail: '' }] }).decision, 'human');
  assert.equal(run({ breaker: { tripped: true, frozen: [], escapes: 2 } }).decision, 'human');
  assert.equal(run({ breaker: { tripped: false, frozen: ['src:MCACore'], escapes: 1 } }).decision, 'human');
  assert.equal(run({ breaker: { tripped: false, frozen: ['tests'], escapes: 1 } }).decision, 'auto_merge');
  assert.equal(run({ policy: { ...policy, mode: 'off' } }).decision, 'human');
});

test('an empty or reason-less policy never means "merge everything"', () => {
  const run = (p) => decide({ classification: eligible, evidence: green, policy: p, breaker: open });
  assert.equal(run({ ...policy, fatal_risk: [] }).decision, 'human');
  assert.equal(run({ ...policy, version: 1 }).decision, 'human');
  assert.equal(run({ ...policy, fatal_risk: policy.fatal_risk.map((r) => ({ ...r, if_wrong: '' })) }).decision, 'human');
  assert.equal(run({ ...policy, fatal_risk: policy.fatal_risk.filter((r) => r.id !== 'governance') }).decision, 'human');
  assert.equal(run({ ...policy, undetectable: {} }).decision, 'human');
});

test('the checked-in policy is valid and auto-merges; every rule says why being wrong is fatal', () => {
  assert.deepEqual(validatePolicy(policy), []);
  assert.equal(policy.mode, 'auto_merge');
  for (const r of policy.fatal_risk) assert.ok(r.if_wrong.length >= 10, r.id);
  // Auto-merge must stay below the ship pipeline's "large change" line (files >= 10 or LOC >= 300),
  // where a visual review deck for a human is mandatory.
  assert.ok(policy.undetectable.max_files < 10 && policy.undetectable.max_loc < 300);
});

// ------------------------------------------------------------------ incidents

const fsOf = (files) => ({ exists: (p) => p in files, read: (p) => files[p] });
const inc = (id, cls, guards) => ({ id, class: cls, summary: 'summary long enough', root_cause: 'root cause long enough', guards });
const T = 'Scripts/trust/tests/x.test.mjs';
const errs = (guards, files) => checkIncidents({ incidents: [inc('INC-001', 'x', guards)] }, fsOf(files)).errors;

test('an incident without a guard, or with a vanished / hollowed guard, fails', () => {
  const files = { [T]: "test('INC-001 regression', () => { assert.ok(1); })" };
  assert.equal(errs([], files).length, 1);
  assert.equal(errs([{ kind: 'test', path: 'Scripts/trust/tests/gone.test.mjs', contains: 'INC-001' }], files).length, 1);
  assert.equal(errs([{ kind: 'test', path: T, contains: 'INC-999' }], files).length, 1);
  assert.deepEqual(errs([{ kind: 'test', path: T, contains: 'INC-001' }], files), []);
});

test('INC-004: a test guard must name a live test declaration, not a comment or a skipped test', () => {
  const g = [{ kind: 'test', path: T, contains: 'INC-001' }];
  assert.equal(errs(g, { [T]: '// INC-001 regression' }).length, 1);
  assert.equal(errs(g, { [T]: "test.skip('INC-001 regression', () => {})" }).length, 1);
  assert.equal(errs(g, { [T]: "test('INC-001 regression', { skip: true }, () => {})" }).length, 1);
});

test('INC-004: a gate guard must be an executable line of gate.sh', () => {
  const g = [{ kind: 'gate', path: 'Scripts/gate.sh', contains: 'run_stage 2 trust' }];
  assert.equal(errs(g, { 'Scripts/gate.sh': '# run_stage 2 trust (header comment)' }).length, 1);
  assert.deepEqual(errs(g, { 'Scripts/gate.sh': 'run_stage 2 trust  trust_checks || exit 1' }), []);
});

test('INC-004: guard kind is checked against location; traversal and missing anchors are rejected', () => {
  const files = { 'README.md': 'x', 'docs/c.md': 'item', [T]: "test('abc', () => { assert.ok(1); })" };
  assert.equal(errs([{ kind: 'gate', path: 'README.md', contains: 'xxx' }], files).length, 1);
  assert.equal(errs([{ kind: 'test', path: 'docs/c.md', contains: 'item' }], files).length, 1);
  assert.equal(errs([{ kind: 'test', path: '../outside.test.mjs', contains: 'abc' }], files).length, 1);
  assert.equal(errs([{ kind: 'test', path: T }], files).length, 1);
  assert.deepEqual(errs([{ kind: 'checklist', path: 'docs/c.md', contains: 'item' }], files), []);
});

test('a recurring class must climb the guard ladder', () => {
  const fs = fsOf({ 'docs/c.md': 'item', [T]: "test('INC-002 x', () => { assert.ok(1); })" });
  const cl = [{ kind: 'checklist', path: 'docs/c.md', contains: 'item' }];
  const weak = { incidents: [inc('INC-001', 'x', cl), inc('INC-002', 'x', cl)] };
  assert.equal(checkIncidents(weak, fs, policy.guard_ladder).errors.length, 1);
  const strong = { incidents: [weak.incidents[0], inc('INC-002', 'x', [{ kind: 'test', path: T, contains: 'INC-002' }])] };
  assert.deepEqual(checkIncidents(strong, fs, policy.guard_ladder).errors, []);
});

test('the checked-in registry passes its own check', () => {
  const registry = JSON.parse(readFileSync(new URL('../../../data/trust/incidents.json', import.meta.url), 'utf-8'));
  const root = new URL('../../../', import.meta.url);
  const fs = { exists: (p) => { try { readFileSync(new URL(p, root)); return true; } catch { return false; } }, read: (p) => readFileSync(new URL(p, root), 'utf-8') };
  assert.deepEqual(checkIncidents(registry, fs, policy.guard_ladder).errors, []);
});

// ------------------------------------------------------------------ drift lock

test('diffIdOf matches pre-ship-steps resolveReviewDiffId (assessment ↔ human answer pairing)', () => {
  const patch = 'diff --git a/x b/x\n+y\n';
  assert.equal(resolveReviewDiffId('/wt', 'main', () => patch), diffIdOf(patch));
});

test('INC-006: commented-out and no-op anchors do not satisfy a guard', () => {
  const tg = [{ kind: 'test', path: T, contains: 'INC-001' }];
  assert.equal(errs(tg, { [T]: "// test('INC-001 regression', () => {})" }).length, 1);
  assert.equal(errs(tg, { [T]: "/*\ntest('INC-001 regression', () => {})\n*/" }).length, 1);
  const gg = (line) => errs([{ kind: 'gate', path: 'Scripts/gate.sh', contains: 'run_stage 2 trust' }], { 'Scripts/gate.sh': line });
  assert.equal(gg(': run_stage 2 trust  trust_checks').length, 1);
  assert.equal(gg('true || run_stage 2 trust  trust_checks').length, 1);
  assert.deepEqual(gg('run_stage 2 trust  trust_checks || exit 1  # comment'), []);
});

test('INC-006: with TAP from the run, a test guard must be seen passing', () => {
  const files = { [T]: "test('INC-001 regression', () => { assert.ok(1); })" };
  const run = (tap) => checkIncidents({ incidents: [inc('INC-001', 'x', [{ kind: 'test', path: T, contains: 'INC-001' }])] }, fsOf(files), {}, { tap }).errors;
  assert.deepEqual(run('ok 3 - INC-001 regression\n'), []);
  assert.equal(run('ok 3 - INC-001 regression # SKIP\n').length, 1);
  assert.equal(run('not ok 3 - INC-001 regression\n').length, 1);
  assert.equal(run('ok 3 - something else\n').length, 1);
  // TAP escapes '#' in names; a real directive is unescaped
  const hashFiles = { [T]: "test('INC-001 #if regression', () => { assert.ok(1); })" };
  const tapFor = (tap) => checkIncidents({ incidents: [inc('INC-001', 'x', [{ kind: 'test', path: T, contains: 'INC-001 #if' }])] }, fsOf(hashFiles), {}, { tap }).errors;
  assert.deepEqual(tapFor('ok 1 - INC-001 \\#if regression\n'), []);
  assert.equal(tapFor('ok 1 - INC-001 \\#if regression # SKIP\n').length, 1);
});

test('INC-007: the decision never reads the environment, so no variable can lift it', () => {
  for (const lib of ['decide', 'classify', 'ledger', 'review']) {
    const src = readFileSync(new URL(`../lib/${lib}.mjs`, import.meta.url), 'utf-8');
    assert.doesNotMatch(src, /process\.env/, lib);
  }
  // trust.mjs touches the environment only to hand it to the gate it runs.
  const src = readFileSync(new URL('../trust.mjs', import.meta.url), 'utf-8');
  const uses = src.split('\n').filter((l) => l.includes('process.env'));
  assert.deepEqual(uses.map((l) => l.trim()), ["const env = { ...process.env, MCA_GATE: 'on', MCA_GATE_NO_CACHE: '1' };"]);
});

test('INC-010: a guard test whose body no longer asserts anything fails', () => {
  const g = [{ kind: 'test', path: T, contains: 'INC-001' }];
  assert.equal(errs(g, { [T]: "test('INC-001 regression', () => {\n  const x = 1;\n});\ntest('other', () => { assert.ok(1); });" }).length, 1);
  assert.deepEqual(errs(g, { [T]: "test('INC-001 regression', () => {\n  assert.equal(1, 1);\n});" }), []);
});

test('INC-010: a Swift guard must be passed in this run\'s xUnit, and an enabled-if trait on the declaration is not live', () => {
  const S = 'Tests/MCACoreTests/RegressionTests.swift';
  const files = { [S]: '@Test func inc001Regression() { #expect(true) }' };
  const run = (xunit) => checkIncidents({ incidents: [inc('INC-001', 'x', [{ kind: 'test', path: S, contains: 'inc001Regression' }])] }, fsOf(files), {}, { xunit }).errors;
  assert.deepEqual(run('<testcase classname="MCACoreTests.R" name="inc001Regression()" time="0.1" />'), []);
  assert.equal(run('<testcase classname="MCACoreTests.R" name="inc001Regression()" time="0.1"><skipped /></testcase>').length, 1);
  assert.equal(run('<testcase classname="MCACoreTests.R" name="other()" time="0.1" />').length, 1);
  // the class name must not vouch for the guard
  assert.equal(run('<testcase classname="MCACoreTests.inc001Regression" name="other()" time="0.1" />').length, 1);
  const enabled = { [S]: '@Test(.enabled(if: false)) func inc001Regression() { #expect(true) }' };
  assert.equal(checkIncidents({ incidents: [inc('INC-001', 'x', [{ kind: 'test', path: S, contains: 'inc001Regression' }])] }, fsOf(enabled)).errors.length, 1);
});

test('INC-012: invoked through a symlinked path, the CLI still runs instead of exiting 0 silently', () => {
  const dir = mkdtempSync(join(tmpdir(), 'trust-link-'));
  const link = join(dir, 'trust.mjs');
  symlinkSync(fileURLToPath(new URL('../trust.mjs', import.meta.url)), link);
  const r = spawnSync(process.execPath, [link, 'approve'], { encoding: 'utf-8' });
  assert.equal(r.status, 1, `exit ${r.status}: ${r.stdout}${r.stderr}`);
  assert.match(r.stderr, /--review|--worktree/);
  assert.equal(isEntryPoint(link, new URL('../trust.mjs', import.meta.url).href), true);
  assert.equal(isEntryPoint(undefined, new URL('../trust.mjs', import.meta.url).href), false);
});

// ------------------------------------------------------------------ review round 5 (INC-014..016)

test('INC-015: missing evidence, an unreadable breaker or unreadable escape times never mean auto-merge', () => {
  const run = (over) => decide({ classification: eligible, evidence: green, policy, breaker: open, ...over });
  assert.equal(run({ evidence: [] }).decision, 'human');
  assert.match(run({ evidence: green.filter((e) => e.id !== 'executed_tests') }).reasons[0], /executed_tests/);
  for (const since of ['2026/09/26', 'soon', 20260926, '2026-09-26']) {
    assert.equal(run({ policy: { ...policy, breaker: { ...policy.breaker, since } } }).decision, 'human', String(since));
  }
  assert.equal(run({ policy: { ...policy, breaker: { ...policy.breaker, max_escapes: 'two' } } }).decision, 'human');
  assert.equal(run({ policy: { ...policy, breaker: { ...policy.breaker, since: '2099-01-01T00:00:00Z' } } }).decision, 'human');
  // Instants, not strings: a +09:00 escape that is after `since` counts; an unreadable time counts too.
  const cfg = { since: '2026-09-26T00:00:00Z', max_escapes: 2 };
  assert.equal(breakerState([escape('2026-09-26T08:00:00+09:00')], cfg).escapes, 0);
  assert.equal(breakerState([escape('2026-09-26T10:00:00+09:00')], cfg).escapes, 1);
  assert.equal(breakerState([escape('not a time')], cfg).escapes, 1);
});

function fakeSteps(dir, { existing, recorded = {}, ok = true } = {}) {
  const path = join(dir, 'pre-ship-answers.json');
  return {
    path,
    answerStorePath: () => path,
    readAnswerStore: () => (existing ? { approval: existing } : {}),
    normalizeApproval,
    recordAnswer: ({ writeFn }) => {
      if (!ok) return { ok: false, error: 'Sequence violation' };
      const store = { approval: { value: 'approve', head_sha: 'h'.repeat(40), review_diff_id: DIFF, at: 't', ...recorded } };
      writeFn(path, store);
      return { ok: true, path, store };
    },
  };
}
const approveArgs = (steps) => ({ steps, worktreeAbs: '/wt', branch: 'feature/x', diffId: DIFF, head: 'h'.repeat(40), reasons: ['r'], projectDir: '/main' });

test('INC-014: approve records a tagged approval in one write, bound to the assessed diff and head', () => {
  const steps = fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')));
  assert.deepEqual(recordTrustApproval(approveArgs(steps)), { ok: true, path: steps.path });
  const a = JSON.parse(readFileSync(steps.path, 'utf-8')).approval;
  assert.equal(a.source, 'trust');
  assert.equal(a.review_diff_id, DIFF);
  assert.deepEqual(a.reasons, ['r']);
});

test('INC-014: approve never overwrites a human veto and writes nothing when the tree moved', () => {
  for (const value of ['abort', '修正が必要', 'revise']) {
    const steps = fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')), { existing: { value } });
    const r = recordTrustApproval(approveArgs(steps));
    assert.equal(r.ok, false, value);
    assert.equal(existsSync(steps.path), false, value);
  }
  // A human approval or an earlier trust record may be superseded.
  assert.equal(recordTrustApproval(approveArgs(fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')), { existing: { value: '承認' } }))).ok, true);
  assert.equal(recordTrustApproval(approveArgs(fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')), { existing: { value: 'abort', source: 'trust' } }))).ok, true);
  for (const recorded of [{ review_diff_id: 'b'.repeat(64) }, { head_sha: 'x'.repeat(40) }]) {
    const steps = fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')), { recorded });
    assert.equal(recordTrustApproval(approveArgs(steps)).ok, false);
    assert.equal(existsSync(steps.path), false, 'no untagged or mis-bound approval may be left on disk');
  }
  assert.equal(recordTrustApproval(approveArgs(fakeSteps(mkdtempSync(join(tmpdir(), 'trust-approve-')), { ok: false }))).ok, false);
});

test('INC-014: reconcile accepts only human answers', () => {
  assert.deepEqual(humanAnswer({ value: '承認' }, normalizeApproval), { ok: true, decision: 'approve' });
  assert.equal(humanAnswer({ value: 'approve', source: 'trust' }, normalizeApproval).ok, false);
  assert.equal(humanAnswer(undefined, normalizeApproval).ok, false);
});

test('ship reconciles a human answer into the ledger while the worktree still exists (PR #11)', () => {
  const wt = mkdtempSync(join(tmpdir(), 'trust-reconcile-'));
  const branch = 'fix/x';
  const store = answerStorePath(wt, branch);
  const calls = [];
  const opts = { mainRoot: '/main', existsFn: () => true, run: (...args) => calls.push(args) };
  const write = (approval) => {
    mkdirSync(dirname(store), { recursive: true });
    writeFileSync(store, JSON.stringify({ approval }));
  };

  assert.equal(reconcileTrustLedger(wt, branch, opts), 'no_answer');
  write({ value: 'approve', source: 'trust' });
  assert.equal(reconcileTrustLedger(wt, branch, opts), 'trust_answer', 'trust approve already wrote the ledger');
  assert.equal(calls.length, 0);

  write({ value: '承認' });
  assert.equal(reconcileTrustLedger(wt, branch, opts), 'recorded');
  assert.deepEqual(calls[0][1], ['/main/Scripts/trust/trust.mjs', 'reconcile', '--worktree', wt], "the main checkout's evaluator, not the branch's");

  // Fail closed: it runs before the push, so throwing stops the ship before cleanup can lose the answer.
  const failing = () => { throw Object.assign(new Error('x'), { stderr: Buffer.from('boom') }); };
  assert.throws(() => reconcileTrustLedger(wt, branch, { ...opts, run: failing }), /reconcile failed.*boom/);
  assert.equal(reconcileTrustLedger(wt, branch, { ...opts, existsFn: () => false }), 'no_trust_cli');
});

test('a Pre-Ship answer cannot overwrite the human veto of the same diff', () => {
  const wt = mkdtempSync(join(tmpdir(), 'trust-veto-'));
  const branch = 'fix/x';
  const store = answerStorePath(wt, branch);
  mkdirSync(dirname(store), { recursive: true });
  const prior = (approval) => writeFileSync(store, JSON.stringify({ approval }));
  const answer = (reviewDiffId, headSha = 'h1') =>
    recordAnswer({
      worktreeAbs: wt, branch, stepId: 'approval', value: 'approve',
      evaluation: { next: { id: 'approval' }, headSha, reviewDiffId }, writeFn: () => {},
    });

  prior({ value: 'Abort', review_diff_id: 'd1', head_sha: 'h1' });
  assert.match(answer('d1').error ?? '', /cannot overwrite that veto/, 'same diff: the veto stands');
  assert.equal(answer('d2').ok, true, 'a revised diff is answered afresh');
  assert.equal(answer(null, 'h1').ok, false, 'current diff id unresolvable: falls back to head_sha');

  prior({ value: 'Revision required', head_sha: 'h1' });
  assert.equal(answer(null, 'h1').ok, false, 'no diff id: bound by head_sha, as staleness is');
  assert.equal(answer(null, 'h2').ok, true, 'a new commit after the revision is answered afresh');

  prior({ value: 'approve if tests pass', review_diff_id: 'd1' });
  assert.equal(answer('d1').ok, true, 'an unreadable answer is re-asked by design, not a veto');
});

test('pre-ship-steps CLI: rejects unknown or value-less flags and paths outside .worktrees/', () => {
  assert.deepEqual(parsePreShipArgs(['next', '--worktree', 'w']), { command: 'next', opts: { worktree: 'w' } });
  assert.match(parsePreShipArgs(['next', '--worktree', 'w', '--force', 'x']).error, /Unknown argument for next: --force/);
  assert.match(parsePreShipArgs(['answer', '--worktree', 'w', '--step', '--value', 'v']).error, /--step needs a value/);
  assert.match(parsePreShipArgs(['answer', '--worktree', 'w']).error, /Missing --step, --value/);
  assert.ok(parsePreShipArgs(['approve']).error, 'unknown command');

  // The main checkout is a git root but not a worktree: an answer there would land where ship never reads it.
  const repo = fileURLToPath(new URL('../../..', import.meta.url));
  const commonDir = spawnSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: repo, encoding: 'utf-8' }).stdout.trim();
  const cli = fileURLToPath(new URL('../../../.claude/scripts/pre-ship-steps.mjs', import.meta.url));
  const run = (wt) => spawnSync(process.execPath, [cli, 'next', '--worktree', wt], { cwd: repo, encoding: 'utf-8' });
  const outside = run(dirname(commonDir));
  assert.equal(outside.status, 1, outside.stderr);
  assert.match(outside.stderr, /not a worktree of this repository/);
  const missing = run(join(tmpdir(), 'no-such-worktree-for-pre-ship-steps'));
  assert.equal(missing.status, 1, missing.stderr);
  assert.match(missing.stderr, /worktree does not exist/);
});

test('gate: a clean merge or root commit is gated on what it brought in, not skipped as unchanged', () => {
  const repo = mkdtempSync(join(tmpdir(), 'gate-merge-'));
  const git = (...args) => {
    const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', ...args], { cwd: repo, encoding: 'utf-8' });
    assert.equal(r.status, 0, r.stderr);
  };
  // --stage 0 runs no toolchain stage, so this checks G0's classification alone.
  const gate = () => spawnSync('bash', [join(repo, 'Scripts/gate.sh'), '--stage', '0'], { encoding: 'utf-8', env: { ...process.env, MCA_GATE: 'on', MCA_GATE_NO_CACHE: '1' } });
  mkdirSync(join(repo, 'Scripts'));
  writeFileSync(join(repo, 'Scripts/gate.sh'), readFileSync(new URL('../../gate.sh', import.meta.url)));
  writeFileSync(join(repo, '.gitignore'), '.tmp/\n');
  git('init', '-q', '-b', 'main');
  git('add', '-A');
  git('commit', '-q', '-m', 'root');
  // A commit with no parent: a root commit, or the tip of a depth-1 clone.
  assert.match(gate().stdout, /GATE RUN +2 changed path/);
  git('checkout', '-q', '-b', 'branch');
  writeFileSync(join(repo, 'b.swift'), 'b\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'branch work');
  git('checkout', '-q', 'main');
  writeFileSync(join(repo, 'a.swift'), 'a\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'main moved');
  git('checkout', '-q', 'branch');
  git('merge', '-q', '--no-edit', 'main');
  const r = gate();
  assert.equal(r.status, 0, r.stdout + r.stderr);
  // Against each parent: a.swift came from main, b.swift from the branch.
  assert.match(r.stdout, /GATE RUN +2 changed path/);
  // A staged rename lists its old path too, so moving source into docs/ is not docs-only.
  mkdirSync(join(repo, 'docs'));
  git('mv', 'b.swift', 'docs/b.txt');
  assert.match(gate().stdout, /GATE RUN +2 changed path/);
});

test('ship merges only after the PR checks finished and passed (PRs #5, #9-#17 merged before CI)', () => {
  // PR #1's real rollup: a re-run leaves the cancelled run next to its success.
  const run = (name, workflowName, conclusion, startedAt, status = 'COMPLETED') =>
    ({ __typename: 'CheckRun', name, workflowName, status, conclusion, startedAt });
  const rerun = [
    run('Build & Test (macOS)', 'CI', 'CANCELLED', '2026-10-03T15:25:56Z'),
    run('Build & Test (macOS)', 'CI', 'SUCCESS', '2026-10-03T15:26:02Z'),
    run('gitleaks', 'Secret Scan', 'SUCCESS', '2026-10-03T15:25:58Z'),
  ];
  assert.equal(checksVerdict(rerun).state, 'passed');
  assert.equal(checksVerdict([]).state, 'pending', 'no checks yet is not a pass');
  assert.equal(checksVerdict([run('gitleaks', 'Secret Scan', '', '2026-10-05T00:00:00Z', 'IN_PROGRESS')]).state, 'pending');
  assert.deepEqual(checksVerdict([...rerun, run('gitleaks', 'Secret Scan', 'FAILURE', '2026-10-05T00:00:00Z')]).failed, ['Secret Scan/gitleaks']);
  assert.equal(checksVerdict([{ __typename: 'StatusContext', context: 'ext', state: 'ERROR' }]).state, 'failed');
  // A queued re-run has no startedAt yet; it is the newest run, not the oldest.
  assert.equal(checksVerdict([...rerun, run('gitleaks', 'Secret Scan', '', undefined, 'QUEUED')]).state, 'pending');

  const replay = (...prs) => {
    const calls = { n: 0 };
    const ghFn = () => JSON.stringify(prs[Math.min(calls.n++, prs.length - 1)]);
    return { calls, opts: { ghFn, sleepFn: () => {} } };
  };
  const at = (headRefOid, statusCheckRollup) => ({ headRefOid, statusCheckRollup });
  const ok = replay(at('h', []), at('h', [run('gitleaks', 'Secret Scan', '', 'x', 'QUEUED')]), at('h', rerun));
  assert.deepEqual(waitChecks(1, 'o/r', 'h', ok.opts), { passed: true, state: 'CHECKS_PASSED' });
  assert.equal(ok.calls.n, 3);
  // Green checks of the previous head say nothing about the head being merged.
  const stale = replay(at('old', rerun), at('h', rerun));
  assert.equal(waitChecks(1, 'o/r', 'h', stale.opts).passed, true);
  assert.equal(stale.calls.n, 2);
  assert.equal(waitChecks(1, 'o/r', 'h', replay(at('old', rerun)).opts).state, 'CHECKS_TIMEOUT');
  const bad = replay(at('h', [run('gitleaks', 'Secret Scan', 'FAILURE', 'x')]));
  assert.equal(waitChecks(1, 'o/r', 'h', bad.opts).passed, false);
  assert.equal(bad.calls.n, 1, 'a failed check stops the wait at once');
  assert.deepEqual(waitChecks(1, 'o/r', 'h', replay(at('h', [])).opts), { passed: false, state: 'CHECKS_TIMEOUT' });
});

// ------------------------------------------------------------------ CI evidence (--ci)

test('CI evidence: a report bound to this head, diff and merge base is taken as is', () => {
  const expected = { head: 'h1', diff_id: 'd1', merge_base: 'm1' };
  const report = { ...expected, evidence: [{ id: 'gate', ok: true, detail: 'GATE PASS' }, { id: 'executed_tests', ok: false, detail: 'X failed' }] };
  const ev = ciEvidenceFromReport(report, expected, 7);
  assert.deepEqual(ev.map((e) => [e.id, e.ok]), [['gate', true], ['executed_tests', false]]);
  assert.match(ev[0].detail, /^CI run 7: GATE PASS/);
});

test('CI evidence: a report about another tree fails every runtime item', () => {
  const expected = { head: 'h1', diff_id: 'd1', merge_base: 'm1' };
  const ok = [{ id: 'gate', ok: true, detail: '' }, { id: 'executed_tests', ok: true, detail: '' }];
  for (const key of ['head', 'diff_id', 'merge_base']) {
    const ev = ciEvidenceFromReport({ ...expected, [key]: 'other', evidence: ok }, expected, 1);
    assert.deepEqual(ev.map((e) => e.ok), [false, false], key);
  }
});

test('CI evidence: missing items and truthy-but-not-true ok are failures', () => {
  const expected = { head: 'h1', diff_id: 'd1', merge_base: 'm1' };
  const ev = ciEvidenceFromReport({ ...expected, evidence: [{ id: 'gate', ok: 'yes', detail: '' }] }, expected, 1);
  assert.deepEqual(ev.map((e) => [e.id, e.ok]), [['gate', false], ['executed_tests', false]]);
  assert.deepEqual(ciEvidenceFromReport(null, expected, 1).map((e) => e.ok), [false, false]);
});
