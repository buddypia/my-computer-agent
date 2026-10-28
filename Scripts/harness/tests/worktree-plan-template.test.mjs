import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { test } from 'node:test';
import { ensureWorktreePlan, ensureWorktreeHandoff } from '../../../.claude/scripts/lib/worktree-plan-template.mjs';

const exec = promisify(execFile);
const helper = new URL('../../../.claude/scripts/lib/worktree-plan-template.mjs', import.meta.url).href;

test('concurrent plan creators have one winner and preserve its complete content', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'plan-concurrency-'));
  const results = await Promise.all(Array.from({ length: 8 }, (_, i) => exec(process.execPath, [
    '--input-type=module', '-e', `
      import { ensureWorktreePlan } from ${JSON.stringify(helper)};
      console.log(JSON.stringify(ensureWorktreePlan(process.argv[1], {
        branch: 'feature/shared', createdAt: process.argv[2]
      })));
    `, dir, `writer-${i}`,
  ]).then(({ stdout }) => ({ ...JSON.parse(stdout), writer: i }))));
  const winners = results.filter((r) => r.created);
  assert.equal(winners.length, 1);
  const body = readFileSync(winners[0].path, 'utf8');
  assert.ok(body.includes(`writer-${winners[0].writer}: Worktree initialized`));
  assert.ok(body.endsWith('\n'));
  writeFileSync(winners[0].path, 'user progress');
  assert.equal(ensureWorktreePlan(dir, { branch: 'feature/shared' }).created, false);
  assert.equal(readFileSync(winners[0].path, 'utf8'), 'user progress');
});

test('handoff creation also preserves existing state and propagates I/O failures', () => {
  const dir = mkdtempSync(join(tmpdir(), 'handoff-preserve-'));
  const result = ensureWorktreeHandoff(dir, { branch: 'feature/shared' });
  assert.equal(result.created, true);
  writeFileSync(result.path, 'handoff evidence');
  assert.equal(ensureWorktreeHandoff(dir, { branch: 'feature/shared' }).created, false);
  assert.equal(readFileSync(result.path, 'utf8'), 'handoff evidence');
  const file = join(dir, 'not-a-directory');
  writeFileSync(file, 'keep');
  assert.throws(() => ensureWorktreePlan(file, { branch: 'feature/failure' }), /ENOTDIR/);
});

test('a dangling mailbox symlink is never followed by creation', () => {
  const dir = mkdtempSync(join(tmpdir(), 'plan-symlink-'));
  const initial = ensureWorktreePlan(dir, { branch: 'feature/setup' });
  const target = join(dir, 'must-not-be-created');
  // Another directory entry can exist even when existsSync reports false.
  const path = initial.path.replace('PLAN.md', 'handoff.md');
  symlinkSync(target, path);
  assert.equal(existsSync(path), false);
  assert.equal(ensureWorktreeHandoff(dir, { branch: 'feature/setup' }).created, false);
  assert.equal(existsSync(target), false);
});
