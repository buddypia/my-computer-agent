// The Stop hook gates the worktrees its session owns, not only the checkout it was registered from:
// a session started in the main checkout edits in its worktree, and that tree was never built.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));

// A repo with the real hook and owner-lease lib, and a gate that fails where a FAIL file exists.
function fixture() {
  const repo = realpathSync(mkdtempSync(join(tmpdir(), 'gate-stop-')));
  const g = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf-8' });
  mkdirSync(join(repo, '.claude', 'hooks'), { recursive: true });
  cpSync(join(ROOT, '.claude', 'hooks', 'gate-stop.sh'), join(repo, '.claude', 'hooks', 'gate-stop.sh'));
  cpSync(join(ROOT, '.cli', 'lib'), join(repo, '.cli', 'lib'), { recursive: true });
  mkdirSync(join(repo, 'Scripts'));
  const gate = join(repo, 'Scripts', 'gate.sh');
  writeFileSync(gate, '#!/bin/bash\nroot="$(cd "$(dirname "$0")/.." && pwd)"\n[ -f "$root/FAIL" ] && { echo "G1 build FAIL"; exit 1; }\necho "GATE PASS"\n');
  chmodSync(gate, 0o755);
  writeFileSync(join(repo, '.gitignore'), '.tmp/\n.worktrees/\nFAIL\n');
  g(repo, 'init', '-q', '-b', 'main');
  g(repo, 'add', '-A');
  g(repo, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'init');
  const wt = join(repo, '.worktrees', 'fix', 'x');
  g(repo, 'worktree', 'add', '-q', '-b', 'fix/x', wt);
  return { repo, wt };
}

async function own(wt, session) {
  const { claimOwnerLease } = await import(join(ROOT, '.cli/lib/worktree-owner-lease.mjs'));
  claimOwnerLease(wt, null, session);
}

const stop = (repo, session) => {
  const r = spawnSync(join(repo, '.claude', 'hooks', 'gate-stop.sh'), [], {
    input: JSON.stringify({ session_id: session }),
    encoding: 'utf-8',
  });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim() ? JSON.parse(r.stdout) : null;
};

test('gate-stop: a red worktree owned by the session blocks the turn', async () => {
  const { repo, wt } = fixture();
  await own(wt, 'session-a');
  writeFileSync(join(wt, 'FAIL'), '');
  const out = stop(repo, 'session-a');
  assert.equal(out?.decision, 'block');
  assert.match(out.reason, /\[worktree \.worktrees\/fix\/x\]/);
  assert.match(out.reason, /G1 build FAIL/);
});

test("gate-stop: another session's red worktree is not this turn's to fix", async () => {
  const { repo, wt } = fixture();
  await own(wt, 'session-a');
  writeFileSync(join(wt, 'FAIL'), '');
  assert.equal(stop(repo, 'session-b'), null);
});

test('gate-stop: green trees let the turn end', async () => {
  const { repo, wt } = fixture();
  await own(wt, 'session-a');
  assert.equal(stop(repo, 'session-a'), null);
});
