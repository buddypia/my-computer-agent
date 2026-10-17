/**
 * The two places ship meets trust: a base merge that rewrote the branch's diff invalidates the
 * approval, and a trust-recorded approval gets the short marker hint, not the Panel.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';

globalThis.__HOOK_ORCHESTRATOR__ = true; // import the hook without running its stdin main
const { assertApprovalFreshAfterBaseMerge, shipReviewMarkerPath } = await import(
  '../../../.claude/scripts/create-pr/ops.mjs'
);
const { run: guard } = await import('../../../.cli/hooks/pre-ship-review-guard.mjs');
const { shipMarkerProblem } = await import('../../../.cli/lib/quality-gate-labels.mjs');
const { checkPreShipSteps } = await import('../../../.claude/scripts/mark-pre-ship-confirmed.mjs');

let root;
let worktree;
let markerPath;
const branch = `fix/ship-flow-${process.pid}`;
const g = (...args) => execFileSync('git', ['-C', worktree, ...args], { encoding: 'utf-8' }).trim();
const commit = (file) => {
  writeFileSync(join(worktree, file), file);
  g('add', '-A');
  g('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', file);
  return g('rev-parse', 'HEAD');
};
const stateDir = () => join(worktree, '.tmp', `worktree-${branch.replace('/', '__')}`);
const writeState = (name, value) => {
  mkdirSync(stateDir(), { recursive: true });
  writeFileSync(join(stateDir(), name), JSON.stringify(value));
};

before(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'ship-flow-')));
  worktree = join(root, '.worktrees', branch);
  mkdirSync(worktree, { recursive: true });
  g('init', '-q', '-b', branch);
  commit('a');
  commit('b'); // stands in for ship's `git merge origin/main`
  markerPath = shipReviewMarkerPath(worktree);
  mkdirSync(dirname(markerPath), { recursive: true });
  writeFileSync(markerPath, JSON.stringify({ review_diff_id: 'D' }));
});

after(() => {
  rmSync(markerPath, { force: true });
  rmSync(root, { recursive: true, force: true });
});

test('a base-only merge keeps the approval; the CI run the merge waits for certifies the tree', () => {
  assert.doesNotThrow(() => assertApprovalFreshAfterBaseMerge(worktree, () => 'D'));
});

test('a merge that changed the branch diff invalidates the approval', () => {
  assert.throws(() => assertApprovalFreshAfterBaseMerge(worktree, () => 'other'), /approval is stale/);
});

test('an unmeasurable diff does not block (markers predating the stamp)', () => {
  assert.doesNotThrow(() => assertApprovalFreshAfterBaseMerge(worktree, () => null));
});

async function denyText(approval) {
  writeState('pre-ship-answers.json', approval ? { approval } : {});
  const saved = process.env.CLAUDE_PROJECT_DIR;
  process.env.CLAUDE_PROJECT_DIR = root; // no marker exists under this project's .tmp
  try {
    const out = await guard({
      tool_name: 'Bash',
      cwd: root,
      tool_input: { command: `node .claude/scripts/create-pr/ops.mjs ship-worktree --worktree ${worktree} --title t` },
    });
    return JSON.stringify(out);
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR;
    else process.env.CLAUDE_PROJECT_DIR = saved;
  }
}

test('ship without a marker after a trust approval gets the marker hint, not the Panel', async () => {
  const text = await denyText({ value: 'approve', source: 'trust' });
  assert.match(text, /trust recorded the approval/);
  assert.match(text, /mark-pre-ship-confirmed\.mjs/);
  assert.doesNotMatch(text, /Review template/);
});

test('a human-path approval still gets the full Panel instructions', async () => {
  const text = await denyText({ value: 'Approve and proceed', source: 'human' });
  assert.doesNotMatch(text, /trust recorded the approval/);
  assert.match(text, /Review template/);
  assert.match(await denyText(null), /Review template/);
});

test('an expired marker after a human approval gets the re-create step, not the Panel again', async () => {
  const marker = join(root, '.tmp', `pre-ship-review-confirmed-${branch.replace('/', '__')}`);
  mkdirSync(dirname(marker), { recursive: true });
  writeFileSync(marker, JSON.stringify({ quality_gate: 'agent_go' }));
  const old = new Date(Date.now() - 12 * 60_000);
  utimesSync(marker, old, old);
  try {
    const text = await denyText({ value: 'Approve and proceed', source: 'human' });
    assert.match(text, /marker expired \(12 min old, limit 10\)/);
    assert.doesNotMatch(text, /Review template/);
  } finally {
    rmSync(marker, { force: true });
  }
});

test('shipMarkerProblem: missing, unlabelled, expired, fresh', () => {
  const p = join(root, 'marker-probe');
  assert.deepEqual(shipMarkerProblem(p), { reason: 'missing' });
  writeFileSync(p, JSON.stringify({ quality_gate: 'nope' }));
  assert.deepEqual(shipMarkerProblem(p), { reason: 'label' });
  writeFileSync(p, JSON.stringify({ quality_gate: 'agent_go' }));
  assert.equal(shipMarkerProblem(p), null);
  assert.deepEqual(shipMarkerProblem(p, { now: Date.now() + 10 * 60_000 + 61_000 }), { reason: 'stale', ageMin: 11 });
});

test('a --force marker is not recorded as a human approval', () => {
  assert.equal(checkPreShipSteps(root, branch, true).approval.mode, 'forced');
});
