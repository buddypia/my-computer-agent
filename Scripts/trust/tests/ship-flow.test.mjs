/**
 * The two places ship meets trust: a base merge that only moved the base is certified by the CI run
 * the merge waits for, and a trust-recorded approval gets the short marker hint, not the Panel.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';

globalThis.__HOOK_ORCHESTRATOR__ = true; // import the hook without running its stdin main
const { assertQualityGateFreshAfterBaseMerge, shipReviewMarkerPath } = await import(
  '../../../.claude/scripts/create-pr/ops.mjs'
);
const { run: guard } = await import('../../../.cli/hooks/pre-ship-review-guard.mjs');

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
  const certified = commit('a');
  writeState('quality-gate.json', {
    verdict: 'go', quality_label: 'agent_go', head_sha: certified, branch,
    recorded_at: new Date().toISOString(),
    gates: [{ name: 'gate', status: 'pass', detail: 'PASS' }],
  });
  commit('b'); // stands in for ship's `git merge origin/main`: HEAD moves past the PROOF
  markerPath = shipReviewMarkerPath(worktree);
  mkdirSync(dirname(markerPath), { recursive: true });
  writeFileSync(markerPath, JSON.stringify({ review_diff_id: 'D' }));
});

after(() => {
  rmSync(markerPath, { force: true });
  rmSync(root, { recursive: true, force: true });
});

test('a base-only merge is left to the CI run the merge waits for', () => {
  assert.doesNotThrow(() =>
    assertQualityGateFreshAfterBaseMerge(worktree, false, { diffIdFn: () => 'D', ciGated: true }));
});

test('without CI or a re-verification runner, the stale PROOF still blocks', () => {
  assert.throws(
    () => assertQualityGateFreshAfterBaseMerge(worktree, false, { diffIdFn: () => 'D', ciGated: false }),
    /stale|HEAD/i,
  );
});

test('a merge that changed the branch diff is not waved through by CI', () => {
  assert.throws(
    () => assertQualityGateFreshAfterBaseMerge(worktree, false, { diffIdFn: () => 'other', ciGated: true }),
    /stale|HEAD/i,
  );
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
