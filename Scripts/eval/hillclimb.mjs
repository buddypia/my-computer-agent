#!/usr/bin/env node
// Scripts/eval/hillclimb.mjs — driver for the System One eval (docs/evals/system-one.md).
//
//   split <pool.jsonl>   assign new cases to train / heldout by a stable hash of the id
//   run [--note "..."]   run the eval, show train failures, judge against the baseline
//   accept [--force]     make the last run the new baseline (floor enforced by swift test)
//
// The verdict follows one rule: a change is kept only when BOTH train and heldout
// improve. A train-only gain is treated as overfitting and reverted.

import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const EVAL_DIR = join(ROOT, 'Evals/system-one');
const REPORT = join(ROOT, '.tmp/eval/system-one.json');
const BASELINE = join(EVAL_DIR, 'baseline.json');
const HISTORY = join(EVAL_DIR, 'history.jsonl');
const HELDOUT_PERCENT = 30;
const STALL_ROUNDS = 3;

// FNV-1a: stable across machines and Node versions, so a case never changes split.
function heldoutBucket(id) {
    let h = 0x811c9dc5;
    for (const ch of Buffer.from(id, 'utf8')) {
        h ^= ch;
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h % 100 < HELDOUT_PERCENT;
}

function readJsonl(path) {
    if (!existsSync(path)) return [];
    return readFileSync(path, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
}

function split(poolPath) {
    const existing = new Set([...readJsonl(join(EVAL_DIR, 'train.jsonl')), ...readJsonl(join(EVAL_DIR, 'heldout.jsonl'))].map((c) => c.id));
    const counts = { train: 0, heldout: 0 };
    for (const c of readJsonl(resolve(poolPath))) {
        if (existing.has(c.id)) throw new Error(`duplicate case id: ${c.id}`);
        existing.add(c.id);
        const target = heldoutBucket(c.id) ? 'heldout' : 'train';
        appendFileSync(join(EVAL_DIR, `${target}.jsonl`), JSON.stringify(c) + '\n');
        counts[target] += 1;
    }
    console.log(`split: +${counts.train} train, +${counts.heldout} heldout`);
}

function runEval() {
    mkdirSync(dirname(REPORT), { recursive: true });
    if (existsSync(REPORT)) writeFileSync(REPORT, '');
    const r = spawnSync('swift', ['test', '--filter', 'SystemOneEval'], {
        cwd: ROOT,
        env: { ...process.env, MCA_EVAL_REPORT: REPORT },
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
    });
    const raw = existsSync(REPORT) ? readFileSync(REPORT, 'utf8') : '';
    if (!raw.trim()) {
        // No report means the harness broke, which says nothing about System One.
        process.stdout.write((r.stdout + r.stderr).split('\n').slice(-60).join('\n'));
        console.error('\nINFRA ERROR: the eval did not produce a report (build failure or harness error).');
        process.exit(2);
    }
    return JSON.parse(raw);
}

function verdict(report, base) {
    if (!base) return 'NO BASELINE (run accept --force)';
    if (report.nondeterministic.length) return 'REVERT (non-deterministic cases: deltas are not trustworthy)';
    // Counts alone let a new failure hide behind an unrelated gain; check train case by case.
    const newlyFailing = base.trainFailures
        ? report.train.failures.map((f) => f.id).filter((id) => !base.trainFailures.includes(id))
        : [];
    if (newlyFailing.length) return `REVERT (regression: ${newlyFailing.join(', ')})`;
    const dt = report.train.passed - base.train;
    const dh = report.heldout.passed - base.heldout;
    if (dt < 0 || dh < 0) return 'REVERT (regression)';
    if (dt > 0 && dh > 0) return 'KEEP (train and heldout both improved)';
    if (dt > 0) return 'REVERT (train-only gain: likely overfit to train)';
    if (dh > 0) return 'REVIEW (heldout-only gain: check the change is principled, then keep)';
    return 'NO CHANGE';
}

function pct(s) {
    return s.total ? `${((100 * s.passed) / s.total).toFixed(1)}%` : 'n/a';
}

function run(note) {
    const report = runEval();
    const base = existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : null;

    console.log(`\n== train failures (${report.train.total - report.train.passed}) ==`);
    for (const f of report.train.failures) {
        console.log(`- ${f.id} [${f.kind}] ${f.source}\n    input: ${f.input}\n    ${f.mismatch}`);
        if (f.observed.reasoning) console.log(`    reasoning: ${f.observed.reasoning}`);
    }

    console.log(`\n== scores (${report.mode}) ==`);
    console.log(`train   ${report.train.passed}/${report.train.total} (${pct(report.train)})  baseline ${base?.train ?? '-'}`);
    console.log(`heldout ${report.heldout.passed}/${report.heldout.total} (${pct(report.heldout)})  baseline ${base?.heldout ?? '-'}`);
    for (const [kind, [p, t]] of Object.entries(report.heldout.byKind)) console.log(`  heldout ${kind}: ${p}/${t}`);

    if (report.nondeterministic.length) {
        console.log(`\nNOISE: non-deterministic cases ${report.nondeterministic.join(', ')} — fix before trusting any delta.`);
    } else {
        console.log('noise: 0 (every case ran twice with identical output); smallest actionable gain = 1 case');
    }
    if (report.heldout.total && report.heldout.passed / report.heldout.total >= 0.95) {
        console.log('HEADROOM: heldout >= 95% — add harder production-derived cases or change the objective (latency, escalation rate).');
    }

    const v = verdict(report, base);
    console.log(`\nVERDICT: ${v}`);

    const history = readJsonl(HISTORY);
    const entry = { at: new Date().toISOString(), train: report.train.passed, heldout: report.heldout.passed, total: [report.train.total, report.heldout.total], verdict: v.split(' ')[0], note: note ?? '' };
    appendFileSync(HISTORY, JSON.stringify(entry) + '\n');
    const recent = [...history, entry].slice(-STALL_ROUNDS);
    if (recent.length === STALL_ROUNDS && recent.every((e) => e.verdict !== 'KEEP')) {
        console.log(`STALLED: no kept change in ${STALL_ROUNDS} rounds. Classify remaining train failures by root cause (ambiguous task, grader bug, harness error, real gap) before trying again.`);
    }
}

function accept(force) {
    const raw = existsSync(REPORT) ? readFileSync(REPORT, 'utf8') : '';
    if (!raw.trim()) throw new Error('no report: run first');
    const report = JSON.parse(raw);
    const base = existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : null;
    const v = verdict(report, base);
    if (!force && !v.startsWith('KEEP')) {
        console.error(`refusing to accept: ${v}. Use --force only when the case set or grader changed (and say why in the note).`);
        process.exit(1);
    }
    const trainFailures = report.train.failures.map((f) => f.id).sort();
    writeFileSync(BASELINE, JSON.stringify({ train: report.train.passed, heldout: report.heldout.passed, trainFailures }, null, 2) + '\n');
    console.log(`baseline -> train ${report.train.passed}, heldout ${report.heldout.passed}`);
}

const [cmd, ...rest] = process.argv.slice(2);
const flag = (name) => {
    const i = rest.indexOf(name);
    return i >= 0 ? rest[i + 1] : undefined;
};
switch (cmd) {
    case 'split':
        split(rest[0] ?? join(EVAL_DIR, 'pool.jsonl'));
        break;
    case 'run':
        run(flag('--note'));
        break;
    case 'accept':
        accept(rest.includes('--force'));
        break;
    default:
        console.log('usage: hillclimb.mjs split <pool.jsonl> | run [--note "..."] | accept [--force]');
        process.exit(cmd ? 1 : 0);
}
