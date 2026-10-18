/**
 * Scripts/gate.sh itself, in a scratch repo with a stand-in `swift` on PATH: which clean trees G0
 * sends to the build, and which build failures G1 retries.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';

const GATE = resolve(dirname(fileURLToPath(import.meta.url)), '../../gate.sh');
let scratch;
let bin;

const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf-8' }).trim();
const commit = (cwd, file) => {
  mkdirSync(dirname(join(cwd, file)), { recursive: true });
  writeFileSync(join(cwd, file), file);
  git(cwd, 'add', '-A');
  git(cwd, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'commit', '-qm', file);
};

/** A repo carrying this gate.sh and passing trust stand-ins, with `main` pushed to origin/main. */
const repo = (name) => {
  const root = join(scratch, name);
  mkdirSync(join(root, 'Scripts/trust/tests'), { recursive: true });
  git(root, 'init', '-q', '-b', 'main');
  copyFileSync(GATE, join(root, 'Scripts/gate.sh'));
  // A docs-only change still runs the trust checks; without these it fails before it can skip.
  writeFileSync(join(root, 'Scripts/trust/trust.mjs'), '');
  writeFileSync(join(root, 'Scripts/trust/tests/ok.test.mjs'), "import { test } from 'node:test';\ntest('ok', () => {});\n");
  // The harness check runs before G0 classifies anything; a passing stand-in keeps it out of these cases.
  mkdirSync(join(root, 'Scripts/harness/tests'), { recursive: true });
  writeFileSync(join(root, 'Scripts/harness/check.mjs'), '');
  writeFileSync(join(root, 'Scripts/harness/tests/ok.test.mjs'), "import { test } from 'node:test';\ntest('ok', () => {});\n");
  writeFileSync(join(root, '.gitignore'), '.tmp/\n');
  commit(root, 'Sources/A.swift');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  return root;
};

/** Runs G0..G1 with `swift` answering per `mode`; returns the output and how often swift ran. */
const gate = (root, mode) => {
  const count = join(root, '.tmp/swift-count');
  mkdirSync(dirname(count), { recursive: true });
  rmSync(count, { force: true });
  // Inherited, it turns the gate's own `node --test` into a silent child of this run: no TAP, exit 0.
  const { NODE_TEST_CONTEXT, ...env } = process.env;
  const r = spawnSync(join(root, 'Scripts/gate.sh'), ['--stage', '1'], {
    encoding: 'utf-8',
    timeout: 60_000, // a retry loop that lost its bound fails here instead of hanging the suite
    env: {
      ...env, PATH: `${bin}:${process.env.PATH}`, FAKE_SWIFT_MODE: mode, FAKE_SWIFT_COUNT: count,
      MCA_GATE: 'on', MCA_GATE_NO_CACHE: '1', MCA_GATE_LOCK_RETRY_SECONDS: '0',
    },
  });
  let runs = 0;
  try { runs = Number(readFileSync(count, 'utf-8')); } catch { /* never ran */ }
  return { out: `${r.stdout}${r.stderr}`, status: r.status, runs };
};

before(() => {
  scratch = realpathSync(mkdtempSync(join(tmpdir(), 'gate-g0-')));
  bin = join(scratch, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'swift'), `#!/bin/sh
n=$(( $(cat "$FAKE_SWIFT_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_SWIFT_COUNT"
locked='error: unable to attach DB: error: accessing build database "x/build.db": database is locked'
case "$FAKE_SWIFT_MODE" in
  ok) echo 'Build complete!' ;;
  locked-once) [ "$n" -gt 1 ] || { echo "$locked"; exit 1; }; echo 'Build complete!' ;;
  locked-long-once) [ "$n" -gt 1 ] || { echo "$locked"; yes 'Compiling MyComputerAgent SomeFile.swift' | head -n 5000; exit 1; }; echo 'Build complete!' ;;
  locked) echo "$locked"; exit 1 ;;
  broken) echo "error: cannot find 'x' in scope"; exit 1 ;;
esac
`);
  chmodSync(join(bin, 'swift'), 0o755);
});

after(() => rmSync(scratch, { recursive: true, force: true }));

test('a clean branch whose last commit is docs-only still builds the code it committed before', () => {
  const root = repo('stacked');
  git(root, 'switch', '-q', '-c', 'fix/x');
  commit(root, 'Sources/B.swift');
  commit(root, 'docs/notes.md');
  const r = gate(root, 'ok');
  assert.match(r.out, /GATE RUN/);
  assert.equal(r.runs, 1);
  assert.equal(r.status, 0);
});

test('on main, a clean tree is still classified by its HEAD commit alone', () => {
  const root = repo('main');
  commit(root, 'docs/notes.md');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  const r = gate(root, 'ok');
  assert.doesNotMatch(r.out, /GATE RUN/);
  assert.match(r.out, /GATE SKIP\s+docs-only change/, r.out);
  assert.equal(r.runs, 0);
  assert.equal(r.status, 0, r.out);
});

test('a docs-only change that skips the build still fails on a failing trust check', () => {
  const root = repo('trust-red');
  writeFileSync(join(root, 'Scripts/trust/trust.mjs'), 'process.exit(1);\n');
  commit(root, 'Scripts/trust/trust.mjs');
  commit(root, 'docs/notes.md');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  const r = gate(root, 'ok');
  assert.match(r.out, /GATE FAIL\s+trust checks \(docs-only change\)/, r.out);
  assert.equal(r.status, 1);
  assert.equal(r.runs, 0);
});

test('an AGENTS.md-only change still fails on a failing harness check, before anything is built', () => {
  const root = repo('harness-red');
  writeFileSync(join(root, 'Scripts/harness/check.mjs'), "console.log('HARNESS FAIL  1 problem(s)'); process.exit(1);\n");
  git(root, 'add', '-A');
  git(root, '-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'red check');
  git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  commit(root, 'AGENTS.md');
  const r = gate(root, 'ok');
  assert.match(r.out, /GATE FAIL\s+harness checks/, r.out);
  assert.match(r.out, /HARNESS FAIL/);
  assert.equal(r.status, 1);
  assert.equal(r.runs, 0);
});

test('G1 retries a build that found the build database locked, and passes when it frees', () => {
  const root = repo('locked-once');
  const r = gate(root, 'locked-once');
  assert.equal(r.status, 0, r.out);
  assert.equal(r.runs, 2);
});

// Real swift output runs to hundreds of KB, past a pipe buffer: `printf | grep -q` under pipefail
// would fail on SIGPIPE once grep quits at the first match, and the lock would never be retried.
test('G1 still recognises the lock in a build log longer than a pipe buffer', () => {
  const r = gate(repo('locked-long-once'), 'locked-long-once');
  assert.equal(r.status, 0, r.out.slice(-2000));
  assert.equal(r.runs, 2);
});

test('G1 gives up after three locked attempts, and never retries a real build failure', () => {
  const locked = gate(repo('locked'), 'locked');
  assert.equal(locked.status, 1);
  assert.equal(locked.runs, 3);
  assert.match(locked.out, /G1 build\s+FAIL/);
  const broken = gate(repo('broken'), 'broken');
  assert.equal(broken.status, 1);
  assert.equal(broken.runs, 1);
});
