import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { evaluateSteps } from '../../../.claude/scripts/lib/pre-ship-steps.mjs';

// The trust evaluator records approval through these steps, so a step that only a hand-written,
// unverified file can satisfy would make every author fabricate that file to ship.
test('a committed worktree with a finished PLAN reaches approval without a self-reported PROOF', () => {
  const branch = 'feature/x';
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'pre-ship-steps-')));
  const worktree = join(root, '.worktrees', branch);
  mkdirSync(worktree, { recursive: true });
  const g = (...args) => execFileSync('git', args, { cwd: worktree, encoding: 'utf-8' }).trim();
  const commit = (file) => {
    writeFileSync(join(worktree, file), file);
    g('add', '-A');
    g('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', file);
  };
  try {
    g('init', '-q', '-b', branch);
    writeFileSync(join(worktree, '.gitignore'), '.tmp/\n');
    commit('base');
    g('update-ref', 'refs/remotes/origin/main', 'HEAD');
    commit('change');
    const state = join(worktree, '.tmp', `worktree-${branch.replace('/', '__')}`);
    mkdirSync(state, { recursive: true });
    writeFileSync(join(state, 'PLAN.md'), '# PLAN\n\n- [x] done\n');

    const result = evaluateSteps({
      worktreeAbs: worktree, branch, projectDir: root, baseBranch: 'main',
      readLedgerFn: () => [], landings: [],
    });

    assert.equal(result.next?.id, 'approval', JSON.stringify(result.next));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
