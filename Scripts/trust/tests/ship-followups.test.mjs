/**
 * A retried ship starts from the merge commit its earlier attempt left behind, and a Japanese
 * approval in the words of the offered choice is read as approval.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';

import { normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';

const { assertQualityGateFreshAfterBaseMerge, shipReviewMarkerPath } = await import(
  '../../../.claude/scripts/create-pr/ops.mjs'
);

let root;
let worktree;
let markerPath;
const branch = `fix/ship-followups-${process.pid}`;
const g = (...args) => execFileSync('git', ['-C', worktree, ...args], { encoding: 'utf-8' }).trim();
const commit = (file) => {
  writeFileSync(join(worktree, file), file);
  g('add', '-A');
  g('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', file);
  return g('rev-parse', 'HEAD');
};

before(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'ship-followups-')));
  worktree = join(root, '.worktrees', branch);
  mkdirSync(worktree, { recursive: true });
  g('init', '-q', '-b', branch);
  const certified = commit('a');
  const stateDir = join(worktree, '.tmp', `worktree-${branch.replace('/', '__')}`);
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, 'quality-gate.json'), JSON.stringify({
    verdict: 'go', quality_label: 'agent_go', head_sha: certified, branch,
    recorded_at: new Date().toISOString(),
    gates: [{ name: 'gate', status: 'pass', detail: 'PASS' }],
  }));
  commit('b'); // the merge commit a stopped attempt left: HEAD is past the PROOF before ship starts
  markerPath = shipReviewMarkerPath(worktree);
  mkdirSync(dirname(markerPath), { recursive: true });
  writeFileSync(markerPath, JSON.stringify({ review_diff_id: 'D' }));
});

after(() => {
  rmSync(markerPath, { force: true });
  rmSync(root, { recursive: true, force: true });
});

test('a retry over a leftover base merge is left to CI', () => {
  assert.doesNotThrow(() =>
    assertQualityGateFreshAfterBaseMerge(worktree, false, { diffIdFn: () => 'D', ciGated: true }, null));
});

test('the up-front check without CI still blocks, without claiming this run merged the base', () => {
  assert.throws(
    () => assertQualityGateFreshAfterBaseMerge(worktree, false, { diffIdFn: () => 'D', ciGated: false }, null),
    (err) => /stale/i.test(err.message) && !/ship merged origin/.test(err.message),
  );
});

test('承認して進める approves; anything added to it does not', () => {
  for (const yes of ['承認して進める', '承認して進めて', '承認して進めてください', '承認して。']) {
    assert.equal(normalizeApproval(yes), 'approve', yes);
  }
  for (const no of ['承認して進める?', '承認して進めないで', '承認して進めるがテスト追加']) {
    assert.notEqual(normalizeApproval(no), 'approve', no);
  }
});
