#!/usr/bin/env node
// Read-only evidence summary, not an acceptance gate or a replacement grader.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const VARIANTS = ['handoff', 'folded', 'tool'];

export function summarize(rows, taskIDs, variants = VARIANTS, runs = 2) {
  const uniqueStrings = (xs) => Array.isArray(xs) && xs.length > 0
    && xs.every((x) => typeof x === 'string' && x.trim()) && new Set(xs).size === xs.length;
  if (!uniqueStrings(taskIDs) || !uniqueStrings(variants) || variants.some((v) => !VARIANTS.includes(v))
      || !Number.isSafeInteger(runs) || runs < 1) throw new Error('Invalid task/variant/run manifest');
  if (!Array.isArray(rows)) throw new Error('Report must be an array');
  const cells = new Map();
  for (const row of rows) {
    if (!row || !taskIDs.includes(row.task) || !variants.includes(row.variant)
        || !Number.isSafeInteger(row.run) || row.run < 1 || row.run > runs
        || typeof row.passed !== 'boolean' || !Array.isArray(row.failures)
        || !row.failures.every((f) => typeof f === 'string')
        || row.passed !== (row.failures.length === 0)
        || !Number.isFinite(row.seconds) || row.seconds < 0
        || !Array.isArray(row.tools) || !row.tools.every((t) => typeof t === 'string')) {
      throw new Error('Invalid or unexpected report row');
    }
    const key = JSON.stringify([row.task, row.variant, row.run]);
    if (cells.has(key)) throw new Error(`Duplicate cell: ${key}`);
    cells.set(key, row);
  }
  const expectedCells = taskIDs.length * variants.length * runs;
  if (cells.size !== expectedCells) throw new Error(`Missing cells: expected ${expectedCells}, got ${cells.size}`);
  const grid = taskIDs.map((task) => ({
    task,
    variants: Object.fromEntries(variants.map((variant) => {
      const values = Array.from({ length: runs }, (_, i) => {
        const row = cells.get(JSON.stringify([task, variant, i + 1]));
        if (!row) throw new Error(`Missing cell: ${task}/${variant}#${i + 1}`);
        return row;
      });
      return [variant, {
        outcomes: values.map((r) => r.passed ? 'P' : 'F').join(''),
        mixed: values.some((r) => r.passed) && values.some((r) => !r.passed),
        failures: values.flatMap((r) => r.failures.map((gap) => ({ run: r.run, gap }))),
      }];
    })),
  }));
  return {
    grid,
    totals: Object.fromEntries(variants.map((variant) => {
      const values = rows.filter((r) => r.variant === variant);
      return [variant, {
        passed: values.filter((r) => r.passed).length,
        total: values.length,
        // Incremental mean avoids overflowing the sum of valid finite durations.
        meanSeconds: values.reduce((mean, r, i) => mean + (r.seconds - mean) / (i + 1), 0),
        meanToolCalls: values.reduce((s, r) => s + r.tools.length, 0) / values.length,
        mixedTasks: grid.filter((r) => r.variants[variant].mixed).map((r) => r.task),
      }];
    })),
  };
}

function main(args) {
  const [report, ...rest] = args;
  if (!report) throw new Error('Usage: summarize-agent-loop.mjs <report.json> [--runs N] [--variants handoff,folded,tool]');
  const options = new Map();
  for (let i = 0; i < rest.length; i += 2) {
    if (!['--runs', '--variants'].includes(rest[i]) || !rest[i + 1] || options.has(rest[i])) {
      throw new Error('Unknown, duplicate or missing option');
    }
    options.set(rest[i], rest[i + 1]);
  }
  const tasksURL = new URL('../../Evals/agent-loop/tasks.jsonl', import.meta.url);
  const ids = readFileSync(tasksURL, 'utf8').split('\n').filter((s) => s.trim()).map((s) => JSON.parse(s).id);
  const summary = summarize(JSON.parse(readFileSync(report, 'utf8')), ids,
    options.has('--variants') ? options.get('--variants').split(',') : VARIANTS,
    options.has('--runs') ? Number(options.get('--runs')) : 2);
  process.stdout.write(JSON.stringify(summary, null, 2) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(`EVIDENCE ERROR: ${error.message}`); process.exitCode = 2; }
}
