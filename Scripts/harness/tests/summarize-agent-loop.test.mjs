import assert from 'node:assert/strict';
import { test } from 'node:test';
import { summarize } from '../../eval/summarize-agent-loop.mjs';

const row = (task, variant, run, passed) => ({
  task, variant, run, passed, failures: passed ? [] : ['wrong final state'],
  seconds: 3, tools: ['inspect', 'click'],
});
const grid = () => [
  row('a', 'folded', 1, true), row('a', 'folded', 2, false),
  row('a', 'tool', 1, true), row('a', 'tool', 2, true),
  row('b', 'folded', 1, false), row('b', 'folded', 2, false),
  row('b', 'tool', 1, false), row('b', 'tool', 2, false),
];
const run = (rows) => summarize(rows, ['a', 'b'], ['folded', 'tool'], 2);

test('keeps every failed cell and repeat instead of hiding them behind an average', () => {
  const result = run(grid().reverse());
  assert.equal(result.grid[0].variants.folded.outcomes, 'PF');
  assert.deepEqual(result.totals.folded.mixedTasks, ['a']);
  assert.equal(result.grid[1].variants.tool.failures.length, 2);
  assert.deepEqual(result.totals.tool, {
    passed: 2, total: 4, meanSeconds: 3, meanToolCalls: 2, mixedTasks: [],
  });
});

test('rejects missing entire tasks, variants, repeats and duplicate cells', () => {
  for (const rows of [[], grid().filter((r) => r.task !== 'b'),
    grid().filter((r) => r.variant !== 'tool'), grid().slice(1), [...grid(), grid()[0]]]) {
    assert.throws(() => run(rows), /Missing|Duplicate/);
  }
});

test('rejects contradictory pass claims, invalid metrics and unexpected cells', () => {
  for (const change of [{ passed: false }, { seconds: null }, { seconds: -1 }, { tools: null },
    { run: 0 }, { run: 3 }, { task: 'unexpected' }, { variant: 'unknown' }, { failures: [42] }]) {
    const rows = grid();
    Object.assign(rows[0], change);
    assert.throws(() => run(rows), /Invalid/);
  }
  assert.throws(() => summarize([], [], ['folded'], 2), /manifest/);
  assert.throws(() => summarize([], ['a'], ['folded'], NaN), /manifest/);
});

test('finite durations retain a finite numeric mean even when their sum would overflow', () => {
  const rows = [1, 2].map((n) => ({ ...row('a', 'folded', n, true), seconds: Number.MAX_VALUE }));
  const mean = () => summarize(rows, ['a'], ['folded'], 2).totals.folded.meanSeconds;
  assert.equal(mean(), Number.MAX_VALUE);
  assert.equal(JSON.parse(JSON.stringify({ mean: mean() })).mean, Number.MAX_VALUE);
  rows[1].seconds = 0;
  assert.equal(mean(), Number.MAX_VALUE / 2);
  rows.reverse();
  assert.equal(mean(), Number.MAX_VALUE / 2);
});
