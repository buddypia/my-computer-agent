/**
 * ship-worktree itself, retried over the base merge its stopped attempt left: it gets past the
 * up-front PROOF check when CI gates the merge, and refuses a dirty tree before anything else.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';

import { resolveReviewDiffId } from '../../../.claude/scripts/lib/pre-ship-steps.mjs';

const OPS = resolve(dirname(fileURLToPath(import.meta.url)), '../../../.claude/scripts/create-pr/ops.mjs');
const branch = `fix/ship-retry-${process.pid}`;
let root;
let wt;

const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf-8' }).trim();
const commit = (cwd, file, body = file) => {
  mkdirSync(dirname(join(cwd, file)), { recursive: true });
  writeFileSync(join(cwd, file), body);
  git(cwd, 'add', '-A');
  git(cwd, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'commit', '-qm', file);
  return git(cwd, 'rev-parse', 'HEAD');
};
const ship = () => {
  const env = { ...process.env, CLAUDE_PROJECT_DIR: root };
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  const r = spawnSync('node', [OPS, 'ship-worktree', '--worktree', wt, '--title', 't'], {
    cwd: root, env, encoding: 'utf-8', timeout: 60_000,
  });
  return `${r.stdout}\n${r.stderr}`;
};

before(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), 'ship-retry-')));
  git(root, 'init', '-q', '-b', 'main');
  commit(root, '.gitignore', '.tmp/\n.worktrees/\n');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  wt = join(root, '.worktrees', branch);
  git(root, 'worktree', 'add', '-q', '-b', branch, wt, 'main');
  commit(wt, '.github/workflows/ci.yml', 'on: push\n');
  const certified = commit(wt, 'feature.txt');
  const state = join(wt, '.tmp', `worktree-${branch.replace('/', '__')}`);
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, 'PLAN.md'), '# PLAN\n- [x] done\n');
  writeFileSync(join(state, 'quality-gate.json'), JSON.stringify({
    verdict: 'go', quality_label: 'agent_go', head_sha: certified, branch,
    recorded_at: new Date().toISOString(),
    gates: [{ name: 'gate', status: 'pass', detail: 'PASS' }],
  }));
  // The stopped attempt: main moved, ship merged it, then failed later. Only the base moved.
  commit(root, 'base.txt');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'main');
  git(wt, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'merge', '-q', '--no-edit', 'origin/main');
  const marker = join(root, '.tmp', `pre-ship-review-confirmed-${branch.replace('/', '__')}`);
  mkdirSync(dirname(marker), { recursive: true });
  writeFileSync(marker, JSON.stringify({ review_diff_id: resolveReviewDiffId(wt, 'main') }));
});

after(() => rmSync(root, { recursive: true, force: true }));

test('a retry over the leftover merge gets past the PROOF check when CI gates the merge', () => {
  const out = ship();
  assert.doesNotMatch(out, /PROOF is stale/);
  assert.match(out, /Only the base moved past the PROOF/); // reached the check, and passed it
});

test('a dirty tree is refused before the PROOF check', () => {
  rmSync(join(wt, '.github'), { recursive: true }); // dirty, and no longer CI-gated
  const out = ship();
  assert.match(out, /uncommitted changes/);
  assert.doesNotMatch(out, /PROOF is stale/);
});
