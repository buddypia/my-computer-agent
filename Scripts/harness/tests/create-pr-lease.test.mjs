// The create-pr lease opens guards for the session that holds it and for no other: parallel sessions
// each work in their own worktree, and a lease shared by the repository opened every guard for all
// of them while one of them shipped (2026-10-21).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  CREATE_PR_ACTIVE_TTL_MS,
  createPrLeasePath,
  currentSessionId,
  isCreatePrLeaseActive,
  releaseCreatePrLease,
  touchCreatePrLease,
} from '../../../.cli/lib/create-pr-lease.mjs';
import { run as commitGuard } from '../../../.cli/hooks/commit-guard.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));

function repoOnMain() {
  const dir = mkdtempSync(join(tmpdir(), 'create-pr-lease-'));
  const g = (...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf-8' }).trim();
  g('init', '-q', '-b', 'main');
  const commit = (name) => {
    writeFileSync(join(dir, name), name);
    g('add', '-A');
    g('-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', name);
    return g('rev-parse', 'HEAD');
  };
  return { dir, commit };
}

test('lease: only the session that opened it, and only while fresh', () => {
  const { dir } = repoOnMain();
  assert.equal(touchCreatePrLease(dir, 'session-a'), createPrLeasePath(dir, 'session-a'));
  assert.equal(isCreatePrLeaseActive(dir, 'session-a'), true);
  assert.equal(isCreatePrLeaseActive(dir, 'session-b'), false, "another session's lease opens nothing");
  assert.equal(isCreatePrLeaseActive(dir, undefined), false, 'no session, no lease');

  const later = Date.now() + CREATE_PR_ACTIVE_TTL_MS + 1000;
  assert.equal(isCreatePrLeaseActive(dir, 'session-a', { now: later }), false, 'expired');

  releaseCreatePrLease(dir, 'session-b');
  assert.equal(isCreatePrLeaseActive(dir, 'session-a'), true, "releasing another session's lease is a no-op");
  releaseCreatePrLease(dir, 'session-a');
  assert.equal(isCreatePrLeaseActive(dir, 'session-a'), false);
});

test('lease: a session id that is not a plain name is no session', () => {
  const { dir } = repoOnMain();
  for (const id of ['../x', 'a/b', '', '.', 42]) {
    assert.equal(createPrLeasePath(dir, id), null, String(id));
    assert.equal(touchCreatePrLease(dir, id), null, String(id));
  }
  assert.equal(currentSessionId({ CLAUDE_CODE_SESSION_ID: 'f6872da6-7493' }), 'f6872da6-7493');
  assert.equal(currentSessionId({ CLAUDE_CODE_SESSION_ID: '../../etc' }), null);
  assert.equal(currentSessionId({}), null);
});

test('commit-guard: a commit on main passes only under the committing session own lease', async () => {
  const { dir } = repoOnMain();
  const saved = process.env.CLAUDE_PROJECT_DIR;
  process.env.CLAUDE_PROJECT_DIR = dir;
  try {
    const verdict = (session) =>
      commitGuard({ tool_name: 'Bash', tool_input: { command: 'git commit -m x' }, cwd: dir, session_id: session });
    const denied = (out) => out?.hookSpecificOutput?.permissionDecision === 'deny';

    assert.ok(denied(await verdict('session-b')), 'no lease: denied');
    touchCreatePrLease(dir, 'session-a');
    assert.ok(denied(await verdict('session-b')), "session-a's lease does not open the guard for session-b");
    assert.ok(!denied(await verdict('session-a')), 'the lease holder passes');
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR;
    else process.env.CLAUDE_PROJECT_DIR = saved;
  }
});

test('trunk-ref-guard: an unpublished trunk move passes only under the moving session own lease', () => {
  const { dir, commit } = repoOnMain();
  const head = commit('a');
  // A commit main does not point at yet and origin has never seen.
  const next = execFileSync('git', ['-C', dir, 'commit-tree', `${head}^{tree}`, '-p', head, '-m', 'next'], {
    encoding: 'utf-8',
    env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' },
  }).trim();
  const guard = (session) =>
    spawnSync(process.execPath, [join(ROOT, '.claude/scripts/trunk-ref-guard.mjs')], {
      cwd: dir,
      input: `${head} ${next} refs/heads/main\n`,
      env: { ...process.env, CLAUDECODE: '1', CLAUDE_CODE_SESSION_ID: session, CLAUDE_PROJECT_DIR: dir },
      encoding: 'utf-8',
    }).status;

  assert.equal(guard('session-b'), 1, 'no lease: rejected');
  touchCreatePrLease(dir, 'session-a');
  assert.equal(guard('session-b'), 1, "session-a's lease does not open the guard for session-b");
  assert.equal(guard('session-a'), 0, 'the lease holder passes');
  const stale = (Date.now() - CREATE_PR_ACTIVE_TTL_MS - 60_000) / 1000;
  utimesSync(createPrLeasePath(dir, 'session-a'), stale, stale);
  assert.equal(guard('session-a'), 1, 'an expired lease opens nothing');
});

test('every guard asks about a session: no call reads the lease without one', () => {
  const files = ['.cli/hooks', '.claude/scripts']
    .flatMap((d) => readdirSync(join(ROOT, d), { recursive: true }).map((f) => join(ROOT, d, String(f))))
    .filter((f) => f.endsWith('.mjs'));
  const calls = files.flatMap((f) =>
    [...readFileSync(f, 'utf-8').matchAll(/isCreatePrLeaseActive\(([^)]*)\)/g)].map((m) => ({ f, args: m[1] })),
  );
  assert.ok(calls.length >= 4, `the guards still read the lease (${calls.length} calls)`);
  for (const { f, args } of calls) assert.match(args, /,/, `${f}: isCreatePrLeaseActive(${args}) has no session`);
});
