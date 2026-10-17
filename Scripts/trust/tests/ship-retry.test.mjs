/**
 * ship-worktree itself, retried over the base merge its stopped attempt left: it refuses to run without
 * a Pre-Ship marker, and refuses a dirty tree before anything else.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';

import { resolveReviewDiffId } from '../../../.claude/scripts/lib/pre-ship-steps.mjs';

const OPS = resolve(dirname(fileURLToPath(import.meta.url)), '../../../.claude/scripts/create-pr/ops.mjs');
const branch = `fix/ship-retry-${process.pid}`;
let root;
let wt;
let marker;

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
  commit(wt, 'feature.txt');
  const state = join(wt, '.tmp', `worktree-${branch.replace('/', '__')}`);
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, 'PLAN.md'), '# PLAN\n- [x] done\n');
  // The stopped attempt: main moved, ship merged it, then failed later. Only the base moved.
  commit(root, 'base.txt');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'main');
  git(wt, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'merge', '-q', '--no-edit', 'origin/main');
  marker = join(root, '.tmp', `pre-ship-review-confirmed-${branch.replace('/', '__')}`);
  mkdirSync(dirname(marker), { recursive: true });
  writeFileSync(marker, JSON.stringify({ quality_gate: 'agent_go', review_diff_id: resolveReviewDiffId(wt, 'main') }));
});

after(() => rmSync(root, { recursive: true, force: true }));

// The hook only sees command text it recognizes; `$OPS ship-worktree` reached the merge unapproved.
test('ship-worktree refuses to run without a marker, even when the hook never fired', () => {
  renameSync(marker, `${marker}.off`);
  try {
    assert.match(ship(), /No Pre-Ship marker/);
  } finally {
    renameSync(`${marker}.off`, marker);
  }
});

test('an expired marker is refused with the re-create step, not the whole panel', () => {
  const old = new Date(Date.now() - 11 * 60_000);
  utimesSync(marker, old, old);
  try {
    const out = ship();
    assert.match(out, /marker expired \(11 min old, limit 10\)/);
    assert.match(out, /mark-pre-ship-confirmed\.mjs fix\/ship-retry-/);
  } finally {
    const now = new Date();
    utimesSync(marker, now, now);
  }
});

test('a dirty tree is refused before anything else', () => {
  rmSync(join(wt, '.github'), { recursive: true });
  const out = ship();
  assert.match(out, /uncommitted changes/);
  assert.doesNotMatch(out, /stale/);
});
