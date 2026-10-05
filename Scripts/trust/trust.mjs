#!/usr/bin/env node
/**
 * trust.mjs — Auto-merge unless a wrong decision would be fatal. Design: docs/trust/auto-approval.md
 *
 *   diff-id    --worktree <p>                               id the reviewer must bind to
 *   assess     --worktree <p> [--review <json>] [--no-gate] [--no-runtime] [--dry-run] [--json]
 *   approve    --worktree <p> --review <json> [--json]      assess; on auto_merge, record the Pre-Ship approval
 *   reconcile  --worktree <p>                               pull the human's Pre-Ship answer into the ledger
 *   escape     --incident INC-NNN (--diff-id <id> | --categories a,b) [--note "..."]
 *   stats      [--json]
 *   incident   check [--tap <node TAP>] [--xunit <swift-testing xUnit>] | checklist
 *
 * The base is always the trunk (`main`). It is not a flag: whoever picks the base picks the policy
 * the branch is judged by, and which part of the change is judged at all.
 *
 * Exit codes: 0 ok / auto_merge; 1 usage or check failure; 3 decided `human`.
 */

import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { classifyChange } from './lib/classify.mjs';
import { decide } from './lib/decide.mjs';
import { checkIncidents, reviewerChecklist } from './lib/incidents.mjs';
import { breakerState, summarize } from './lib/ledger.mjs';
import { validateReview } from './lib/review.mjs';
import { addsRegressionTest, detectSwiftBarMove, parseDiff } from './lib/swift-bar-move.mjs';
import { compareRuns, parseEventStream, runCompleted } from './lib/test-run.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const TRUNK = 'main';

// ---------------------------------------------------------------------------- git

function git(cwd, args) {
  return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 << 20 });
}

/**
 * Diff output this module parses must not depend on the user's git config or the branch's
 * `.gitattributes` (INC-002): quoted non-ASCII paths, `noprefix`, external/textconv drivers and
 * `-diff` binary marking each made changed lines invisible to the rules.
 */
const DIFF_PINNED = [
  '-c', 'core.quotepath=false',
  '-c', 'diff.noprefix=false',
  '-c', 'diff.mnemonicPrefix=false',
  '-c', 'diff.relative=false',
  'diff', '--no-color', '--no-ext-diff', '--no-textconv', '--text', '--no-renames',
  '--src-prefix=a/', '--dst-prefix=b/',
];

/** Trunk ref that resolves, preferring the remote. */
export function resolveTrunk(wt) {
  for (const ref of [`origin/${TRUNK}`, TRUNK]) {
    try {
      git(wt, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]);
      return ref;
    } catch {
      /* next */
    }
  }
  return null;
}

/**
 * Must stay byte-compatible with pre-ship-steps.mjs#resolveReviewDiffId (plain `git diff`), so an
 * assessment and the human's Pre-Ship answer pair up on the same id — drift-locked by tests.
 */
export function diffIdOf(diff) {
  return typeof diff === 'string' ? createHash('sha256').update(diff).digest('hex') : null;
}

export function reviewDiffId(wt, ref) {
  return diffIdOf(git(wt, ['diff', `${ref}...HEAD`]));
}

function blobAt(wt, rev, path) {
  try {
    return git(wt, ['cat-file', 'blob', `${rev}:${path}`]);
  } catch {
    return null;
  }
}

/**
 * Everything the rules look at, measured from git with a pinned format.
 * @returns {{mergeBase: string, files: Array<object>, testFiles: Array<{path: string, before: string|null, after: string|null}>}}
 */
export function analyzeBranch(wt, ref) {
  const mergeBase = git(wt, ['merge-base', ref, 'HEAD']).trim();
  const range = `${mergeBase}..HEAD`;

  // What the reviewer and the human are shown is the plain diff (the one diff_id hashes). A file it
  // renders as "Binary files ... differ" was approved unseen, however well the machine measured it
  // (INC-006) — so it is unmeasurable for the purposes of approval.
  const hidden = new Set();
  for (const line of git(wt, ['-c', 'core.quotepath=false', 'diff', '--no-color', '--no-ext-diff', '--no-renames', '--src-prefix=a/', '--dst-prefix=b/', range]).split('\n')) {
    const m = /^Binary files (?:a\/(.+?)|\/dev\/null) and (?:b\/(.+)|\/dev\/null) differ$/.exec(line);
    if (m) hidden.add(m[2] ?? m[1]);
  }
  const blocks = new Map(parseDiff(git(wt, [...DIFF_PINNED, range])).map((b) => [b.path, b]));

  // numstat supplies the file list only. Its counts ignore `--text` and report a NUL-bearing or
  // `-diff` file as `-`, i.e. zero lines, so counts come from the parsed `--text` patch instead.
  const records = git(wt, [...DIFF_PINNED, '--numstat', '-z', range]).split('\0').filter(Boolean);
  const files = records.map((rec) => {
    const [, , ...rest] = rec.split('\t');
    const path = rest.join('\t');
    const b = blocks.get(path);
    return {
      path,
      binary: !b || hidden.has(path), // no patch text, or none the reviewer was shown
      added: b?.added.length ?? 0,
      removed: b?.removed.length ?? 0,
      addedLines: b?.added ?? [],
      removedLines: b?.removed ?? [],
      // Whole-file text for `content_scope: file` rules (a schema edit need not touch the line that
      // names the statement). Binary files carry none; they escalate as unmeasurable anyway.
      before: b ? blobAt(wt, mergeBase, path) : null,
      after: b ? blobAt(wt, 'HEAD', path) : null,
    };
  });

  const testFiles = files
    .filter((f) => /^Tests\/.+\.swift$/.test(f.path))
    .map((f) => ({ path: f.path, before: blobAt(wt, mergeBase, f.path), after: blobAt(wt, 'HEAD', f.path) }));

  return { mergeBase, files, testFiles };
}

/** Managed JS detector, for the .mjs tests in this repo. Swift is covered by swift-bar-move.mjs. */
async function managedBarMove(wt, mergeBase) {
  try {
    const mod = await import(join(REPO, '.cli/lib/self-improving-loop.mjs'));
    return mod
      .detectBarMove(git(wt, [...DIFF_PINNED, `${mergeBase}..HEAD`]))
      .filter((f) => f.signal !== mod.BAR_MOVE.TEST_RETIRED_WITH_SUBJECT);
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------- executed tests (INC-009)

/**
 * Runs `swift test` in `dir` and returns what actually executed, or null when no complete run exists
 * (build failure, crash). A run that *completed* with failing tests is still a result: only tests
 * that passed on the trunk are compared, so one flaky trunk test must not make the whole comparison
 * unavailable. Failing branch tests are caught by the gate and, when they passed on the trunk, here.
 */
function runSwiftTests(dir) {
  const events = join(mkdtempSync(join(tmpdir(), 'trust-run-')), 'events.jsonl');
  const r = spawnSync(
    'swift',
    ['test', '--package-path', dir, '--event-stream-output-path', events, '--event-stream-version', '0'],
    { encoding: 'utf-8', maxBuffer: 256 << 20 },
  );
  if (!existsSync(events)) return null;
  const text = readFileSync(events, 'utf-8');
  if (!runCompleted(text)) return null;
  return parseEventStream(text);
}

/** Toolchain identity: a baseline measured by another compiler is not the same baseline. */
function toolchainId() {
  const r = spawnSync('swift', ['--version'], { encoding: 'utf-8' });
  return createHash('sha256').update(`${r.stdout}${r.stderr}`).digest('hex').slice(0, 12);
}

const LOCK_STALE_MS = 30 * 60 * 1000;

/**
 * Serializes use of the shared trunk build directory. Parallel agents assessing against different
 * trunk commits would otherwise overwrite each other's sources mid-build and cache the result under
 * the wrong commit (INC-011). `mkdir` is atomic; a lock older than LOCK_STALE_MS is taken over.
 */
function withLock(lockDir, fn) {
  try {
    mkdirSync(lockDir);
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    const age = Date.now() - statSync(lockDir).mtimeMs;
    if (age < LOCK_STALE_MS) return { busy: true };
    rmSync(lockDir, { recursive: true, force: true });
    mkdirSync(lockDir);
  }
  try {
    return { value: fn() };
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
}

/**
 * The trunk side of the comparison, cached per merge-base sha and toolchain (it only changes when
 * either does). The trunk tree is exported with `git archive` into `<main>/.tmp/trust/base-src/`
 * rather than checked out as a worktree: this repository routes worktree creation through
 * `make wt.new` and its guards, and a comparison cache is not a place to work. `.build/` is kept
 * between exports so the build stays incremental. The exported commit is stamped and re-read after
 * the run, so a result is only ever cached under the tree that produced it.
 *
 * @returns {{run: Map|null, busy?: boolean}}
 */
function trunkRun(wt, mergeBase) {
  const dir = join(mainRoot(wt), '.tmp', 'trust');
  const cache = join(dir, 'runs', `${mergeBase}-${toolchainId()}.json`);
  if (existsSync(cache)) return { run: new Map(readJson(cache)) };
  mkdirSync(dir, { recursive: true });
  const locked = withLock(join(dir, 'base-src.lock'), () => {
    const baseSrc = join(dir, 'base-src');
    const stamp = join(baseSrc, '.trust-tree');
    mkdirSync(baseSrc, { recursive: true });
    for (const entry of readdirSync(baseSrc)) {
      if (entry !== '.build') rmSync(join(baseSrc, entry), { recursive: true, force: true });
    }
    const tar = execFileSync('git', ['-C', wt, 'archive', '--format=tar', mergeBase], { maxBuffer: 1 << 30 });
    if (spawnSync('tar', ['-x', '-C', baseSrc], { input: tar }).status !== 0) return null;
    writeFileSync(stamp, mergeBase);
    const run = runSwiftTests(baseSrc);
    if (!run || readFileSync(stamp, 'utf-8') !== mergeBase) return null;
    mkdirSync(dirname(cache), { recursive: true });
    writeFileSync(cache, JSON.stringify([...run]));
    return run;
  });
  return locked.busy ? { run: null, busy: true } : { run: locked.value };
}

function executedTestsEvidence(wt, mergeBase) {
  const { run: base, busy } = trunkRun(wt, mergeBase);
  if (busy) return { id: 'executed_tests', ok: false, detail: '別の assess が trunk 側をビルド中（しばらくして再実行）' };
  if (!base) return { id: 'executed_tests', ok: false, detail: 'trunk 側の swift test が失敗・未取得（比較できない）' };
  const head = runSwiftTests(wt);
  if (!head) return { id: 'executed_tests', ok: false, detail: 'branch 側の swift test が失敗' };
  const findings = compareRuns(base, head);
  const passed = (r) => [...r.values()].filter((v) => v.status === 'passed').length;
  return {
    id: 'executed_tests',
    ok: findings.length === 0,
    detail:
      findings.length === 0
        ? `trunk で pass した ${passed(base)} 件はすべて branch でも pass（branch ${passed(head)} 件）`
        : findings.slice(0, 5).map((f) => `${f.id}: ${f.detail}`).join('; ') + (findings.length > 5 ? ` …他 ${findings.length - 5} 件` : ''),
  };
}

// ---------------------------------------------------------------------------- ledger & config

/** Main checkout root — the ledger outlives any single worktree. */
function mainRoot(cwd) {
  return dirname(git(cwd, ['rev-parse', '--path-format=absolute', '--git-common-dir']).trim());
}

const ledgerPath = (cwd) => join(mainRoot(cwd), '.harness', 'trust', 'ledger.jsonl');

export function readLedger(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf-8')
    .split('\n')
    .filter(Boolean)
    .flatMap((l) => {
      try {
        return [JSON.parse(l)];
      } catch {
        return [];
      }
    });
}

function append(path, event) {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`);
}

const readJson = (p) => JSON.parse(readFileSync(p, 'utf-8'));
const loadIncidents = (root) => readJson(join(root, 'data/trust/incidents.json'));

/**
 * The policy a branch is judged by is the trunk's, never the one it carries: otherwise a branch could
 * relax `fatal_risk` and be judged by the relaxed copy. The branch's own copy is used only while the
 * trunk has none (the PR introducing it) — and that PR escalates as `governance` anyway.
 */
export function loadTrunkPolicy(wt, ref) {
  let text = null;
  try {
    text = git(wt, ['cat-file', 'blob', `${ref}:data/trust/policy.json`]);
  } catch {
    /* the trunk has no policy yet */
  }
  // A trunk policy that exists but does not parse is an error, never a reason to use the branch's copy.
  if (text !== null) return { policy: JSON.parse(text), source: ref };
  const own = join(wt, 'data/trust/policy.json');
  if (existsSync(own)) return { policy: readJson(own), source: 'worktree (trunk has no policy yet)' };
  return { policy: readJson(join(REPO, 'data/trust/policy.json')), source: 'evaluator checkout (trunk has no policy yet)' };
}

// ---------------------------------------------------------------------------- commands

class UsageError extends Error {}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) out._.push(a);
    else if (argv[i + 1] === undefined || argv[i + 1].startsWith('--')) out[a.slice(2)] = true;
    else out[a.slice(2)] = argv[(i += 1)];
  }
  if (out.base) throw new UsageError('--base は廃止: base は常に main');
  return out;
}

function requireWorktree(args) {
  if (!args.worktree) throw new UsageError('--worktree <path> が必要');
  const wt = resolve(String(args.worktree));
  const ref = resolveTrunk(wt);
  if (!ref) throw new UsageError(`trunk (${TRUNK}) を解決できない`);
  return { wt, ref };
}

const snapshot = (wt) => ({ head: git(wt, ['rev-parse', 'HEAD']).trim(), dirty: git(wt, ['status', '--porcelain']).trim() });

function runGate(wt) {
  // No cache: a pass file is just a file, and anyone who can compute its key can write it.
  const env = { ...process.env, MCA_GATE: 'on', MCA_GATE_NO_CACHE: '1' };
  const r = spawnSync(join(wt, 'Scripts/gate.sh'), ['--force'], { cwd: wt, env, encoding: 'utf-8' });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  const last = out.trim().split('\n').pop() ?? '';
  // The trust stage must have actually run, not merely the gate as a whole (INC-006).
  const ok = r.status === 0 && /GATE PASS  stages/.test(out) && /G2 trust\s+PASS/.test(out) && /G2 guards\s+PASS/.test(out) && !/cached/.test(out);
  return { id: 'gate', ok, detail: ok ? last : `gate failed (exit ${r.status}) ${last}` };
}

async function assessBranch(args) {
  const { wt, ref } = requireWorktree(args);
  const branch = git(wt, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();
  const before = snapshot(wt);
  const diffId = reviewDiffId(wt, ref);
  const { policy, source: policySource } = loadTrunkPolicy(wt, ref);

  const { mergeBase, files, testFiles } = analyzeBranch(wt, ref);
  const classification = classifyChange({ files }, policy);

  const evidence = [];
  evidence.push({ id: 'clean', ok: before.dirty === '', detail: before.dirty ? '未コミットの変更がある（diff_id に含まれない）' : 'working tree clean' });
  evidence.push(args['no-gate'] ? { id: 'gate', ok: false, detail: '--no-gate: ゲート未実行' } : runGate(wt));

  evidence.push(args['no-runtime'] ? { id: 'executed_tests', ok: false, detail: '--no-runtime: 実行比較なし' } : executedTestsEvidence(wt, mergeBase));

  const barMove = [...detectSwiftBarMove(testFiles), ...(await managedBarMove(wt, mergeBase))];
  evidence.push({
    id: 'bar_move',
    ok: barMove.length === 0,
    detail: barMove.length === 0 ? 'テスト基準の引き下げなし' : barMove.map((f) => `${f.path}: ${f.detail}`).join('; '),
  });

  let review = null;
  let reviewError = null;
  if (args.review) {
    try {
      review = readJson(resolve(String(args.review)));
    } catch (e) {
      reviewError = e.message;
    }
  }
  const rv = validateReview(review, diffId);
  evidence.push({ id: 'review', ok: rv.ok, detail: reviewError ? `review 読み込み失敗: ${reviewError}` : rv.detail });

  if (/^(fix|hotfix)[/-]/.test(branch)) {
    const ok = addsRegressionTest(testFiles);
    evidence.push({ id: 'regression_test', ok, detail: ok ? '有効な assertion の追加あり' : 'fix ブランチなのに回帰テストがない' });
  }

  // Evidence is only about the tree it was gathered on.
  const after = snapshot(wt);
  const stable = after.head === before.head && after.dirty === before.dirty && reviewDiffId(wt, ref) === diffId;
  evidence.push({ id: 'stable', ok: stable, detail: stable ? '証拠収集中にツリーは不変' : '証拠収集中に HEAD / tree が変わった' });

  const ledger = ledgerPath(wt);
  const breaker = breakerState(readLedger(ledger), policy.breaker);
  const result = decide({ classification, evidence, policy, breaker });

  if (!args['dry-run']) {
    append(ledger, {
      type: 'assessment',
      branch,
      diff_id: diffId,
      head: before.head,
      base_ref: ref,
      mode: policy.mode,
      policy_version: policy.version,
      policy_source: policySource,
      categories: classification.categories,
      scale: classification.scale,
      escalations: classification.escalations.map((e) => e.id),
      evidence: evidence.map(({ id, ok }) => ({ id, ok })),
      decision: result.decision,
    });
  }

  const report = { branch, diff_id: diffId, policy_source: policySource, ...classification.scale, categories: classification.categories, evidence, breaker, ...result };
  return { wt, branch, diffId, head: before.head, policy, policySource, classification, evidence, result, report };
}

function printAssessment(a, args) {
  const { result, classification, evidence, policy, policySource, branch, diffId } = a;
  console.log(`TRUST ${result.decision.toUpperCase()}  ${branch}  diff ${diffId.slice(0, 12)}  (${policy.mode}, policy from ${policySource})`);
  console.log(`  categories: ${classification.categories.join(', ')}  files ${classification.scale.files} / loc ${classification.scale.loc}`);
  for (const e of evidence) console.log(`  ${e.ok ? 'ok  ' : 'FAIL'} ${e.id.padEnd(16)} ${e.detail}`);
  for (const r of result.reasons) console.log(`  → ${r}`);
  if (args['dry-run']) console.log('  (dry-run: 台帳に記録していない)');
}

async function cmdAssess(args) {
  const a = await assessBranch(args);
  if (args.json) console.log(JSON.stringify(a.report, null, 2));
  else printAssessment(a, args);
  return a.result.decision === 'auto_merge' ? 0 : 3;
}

/**
 * The Pre-Ship `approval` step is the one place the ship pipeline asks for a go. On `auto_merge`
 * this records that go — through the step runner's own `recordAnswer`, so the sequence and the
 * diff binding are enforced exactly as for a human answer — and marks it `source: trust`, so
 * nobody reading the answer store mistakes it for a human's words.
 */
/**
 * Records the Pre-Ship approval for an auto_merge decision. Exported for tests; `steps` is the
 * pre-ship step runner module (injected).
 *
 * - A human answer that is not an approval is never overwritten: a human "abort" or "revise" on this
 *   branch keeps it with the human, whatever the machine decides later.
 * - The write goes through the runner's own `recordAnswer` (sequence and diff binding as for a human
 *   answer), but with a `writeFn` that checks the binding *before* anything is written and writes the
 *   `source: trust` tag in the same atomic write. No untagged or mis-bound approval can be left on
 *   disk, even if the tree moved after the assessment or the process dies mid-way.
 *
 * @returns {{ok: true, path: string} | {ok: false, error: string}}
 */
export function recordTrustApproval({ steps, worktreeAbs, branch, diffId, head, reasons, projectDir }) {
  const path = steps.answerStorePath(worktreeAbs, branch);
  const existing = steps.readAnswerStore(path).approval;
  if (existing?.value && existing.source !== 'trust' && steps.normalizeApproval(existing.value) !== 'approve') {
    return { ok: false, error: `人間の回答 "${existing.value}" がある。人間が止めたブランチは自動マージしない` };
  }
  let bindError = null;
  const writeFn = (target, store) => {
    const a = store.approval;
    if (a?.review_diff_id !== diffId || a?.head_sha !== head) {
      bindError = `記録しようとした承認 (diff ${String(a?.review_diff_id).slice(0, 12)}, head ${String(a?.head_sha).slice(0, 7)}) が判定した diff ${diffId.slice(0, 12)} / head ${head.slice(0, 7)} と違う（判定後にツリーが動いた）`;
      return;
    }
    const tagged = { ...store, approval: { ...a, source: 'trust', decided_by: 'Scripts/trust/trust.mjs approve', reasons } };
    const tmp = `${target}.tmp-${process.pid}`;
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(tmp, `${JSON.stringify(tagged, null, 2)}\n`);
    renameSync(tmp, target);
  };
  const rec = steps.recordAnswer({ worktreeAbs, branch, stepId: 'approval', value: 'approve', projectDir, writeFn });
  if (!rec.ok) return { ok: false, error: `${rec.error}（先に Pre-Ship の他のステップを完了する）` };
  if (bindError) return { ok: false, error: bindError };
  return { ok: true, path: rec.path };
}

async function cmdApprove(args) {
  if (args['dry-run']) throw new UsageError('approve に --dry-run は使えない（判定を記録せずに承認はできない）');
  if (!args.review) throw new UsageError('--review <json> が必要（独立レビューなしに自動マージはしない）');
  const a = await assessBranch(args);
  if (args.json) console.log(JSON.stringify(a.report, null, 2));
  else printAssessment(a, args);
  if (a.result.decision !== 'auto_merge') {
    console.log('  → 自動マージしない。Pre-Ship Panel に上の理由を添えて人間の承認を求める');
    return 3;
  }

  const steps = await import(join(REPO, '.claude/scripts/lib/pre-ship-steps.mjs'));
  const rec = recordTrustApproval({
    steps, worktreeAbs: a.wt, branch: a.branch, diffId: a.diffId, head: a.head, reasons: a.result.reasons, projectDir: mainRoot(a.wt),
  });
  if (!rec.ok) {
    console.log(`  → 承認を記録できない: ${rec.error}`);
    return 3;
  }
  append(ledgerPath(a.wt), { type: 'auto_approval', branch: a.branch, diff_id: a.diffId, head: a.head });
  console.log(`  → Pre-Ship approval を trust として記録した: ${rec.path}`);
  return 0;
}

/** A human answer the ledger may record, or why not. Exported for tests. */
export function humanAnswer(answer, normalizeApproval) {
  if (!answer?.value) return { ok: false, error: 'Pre-Ship の approval 回答がまだない' };
  if (answer.source === 'trust') return { ok: false, error: 'この approval は trust approve が記録したもので、人間の回答ではない' };
  const decision = normalizeApproval(answer.value);
  if (!decision) return { ok: false, error: `回答を解釈できない: "${answer.value}"` };
  return { ok: true, decision };
}

async function cmdReconcile(args) {
  const { wt, ref } = requireWorktree(args);
  const branch = git(wt, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();
  const steps = await import(join(REPO, '.claude/scripts/lib/pre-ship-steps.mjs'));
  const answer = steps.readAnswerStore(steps.answerStorePath(wt, branch)).approval;
  const h = humanAnswer(answer, steps.normalizeApproval);
  if (!h.ok) throw new UsageError(h.error);
  const { decision } = h;
  const diffId = answer.review_diff_id ?? reviewDiffId(wt, ref);
  append(ledgerPath(wt), { type: 'human', branch, diff_id: diffId, decision, source: 'pre-ship-answers', answered_at: answer.at });
  console.log(`recorded human ${decision} for ${branch} (${diffId?.slice(0, 12)})`);
  return 0;
}

function cmdEscape(args) {
  const inc = (loadIncidents(REPO).incidents ?? []).find((i) => i.id === args.incident);
  // No incident, no escape: the guard has to exist before the breaker moves, or the freeze becomes
  // a ritual that changes nothing about the next occurrence.
  if (!inc) throw new UsageError(`--incident ${args.incident ?? '(未指定)'} が data/trust/incidents.json にない。先に guard 付きで登録する`);
  const ledger = ledgerPath(REPO);
  let categories = args.categories ? String(args.categories).split(',') : null;
  if (!categories && args['diff-id']) {
    categories = readLedger(ledger).filter((e) => e.type === 'assessment' && e.diff_id === args['diff-id']).pop()?.categories ?? null;
  }
  if (!categories?.length) throw new UsageError('--diff-id（台帳にある）か --categories が必要');
  append(ledger, { type: 'escape', diff_id: args['diff-id'] ?? null, categories, incident: inc.id, note: args.note ?? null });
  console.log(`escape recorded: ${categories.join(', ')} → 自動マージを凍結 (${inc.id})。再開は policy.json の breaker.since を人間の承認で進める`);
  return 0;
}

function cmdStats(args) {
  const { policy } = loadTrunkPolicy(REPO, resolveTrunk(REPO) ?? 'HEAD');
  const events = readLedger(ledgerPath(REPO));
  const breaker = breakerState(events, policy.breaker);
  const summary = summarize(events);
  if (args.json) {
    console.log(JSON.stringify({ mode: policy.mode, breaker, ...summary }, null, 2));
    return 0;
  }
  console.log(`mode=${policy.mode}  auto_merge ${summary.auto_merge}  human ${summary.human}  (revised ${summary.revised}, over-escalation ${summary.over_escalation})`);
  console.log(
    `breaker: escapes ${breaker.escapes}/${policy.breaker?.max_escapes} since ${policy.breaker?.since}` +
      `${breaker.tripped ? '  TRIPPED — 自動マージ停止中' : ''}${breaker.frozen.length ? `  frozen: ${breaker.frozen.join(', ')}` : ''}`,
  );
  for (const [id, r] of Object.entries(summary.by_rule).sort()) {
    console.log(`  ${id.padEnd(14)} approved unchanged ${String(r.approved_unchanged).padStart(3)}  revised ${String(r.revised).padStart(3)}`);
  }
  return 0;
}

function cmdIncident(args) {
  const registry = loadIncidents(REPO);
  if (args._[1] === 'checklist') {
    console.log(reviewerChecklist(registry).join('\n'));
    return 0;
  }
  if (args._[1] !== 'check') throw new UsageError('incident check | checklist');
  const fs = { exists: (p) => existsSync(join(REPO, p)), read: (p) => readFileSync(join(REPO, p), 'utf-8') };
  const policy = readJson(join(REPO, 'data/trust/policy.json'));
  // TAP from the run that just happened (gate.sh passes it): test guards must be seen *passing*.
  const tap = args.tap ? readFileSync(resolve(String(args.tap)), 'utf-8') : null;
  const xunit = args.xunit ? readFileSync(resolve(String(args.xunit)), 'utf-8') : null;
  const { errors, classes } = checkIncidents(registry, fs, policy.guard_ladder, { tap, xunit });
  if (errors.length > 0) {
    console.log(`TRUST incident check FAIL (${errors.length})`);
    for (const e of errors) console.log(`  - ${e}`);
    return 1;
  }
  console.log(`TRUST incident check PASS  ${registry.incidents.length} incident(s), classes: ${JSON.stringify(classes)}`);
  return 0;
}

function cmdDiffId(args) {
  const { wt, ref } = requireWorktree(args);
  console.log(reviewDiffId(wt, ref));
  return 0;
}

const COMMANDS = { assess: cmdAssess, approve: cmdApprove, reconcile: cmdReconcile, escape: cmdEscape, stats: cmdStats, incident: cmdIncident, 'diff-id': cmdDiffId };

async function main(argv) {
  try {
    const args = parseArgs(argv);
    const cmd = COMMANDS[args._[0]];
    if (!cmd) {
      console.error(readFileSync(fileURLToPath(import.meta.url), 'utf-8').split('\n').slice(2, 16).join('\n'));
      return 1;
    }
    return await cmd(args);
  } catch (e) {
    console.error(`trust: ${e instanceof UsageError ? e.message : e.stack}`);
    return 1;
  }
}

/**
 * Entry-point check on real paths. Comparing the raw argv path missed any invocation through a
 * symlink (`/tmp` → `/private/tmp` on macOS): the module loaded, ran nothing and exited 0 — and for
 * `approve`, 0 means "auto-merge" (INC-012).
 */
export function isEntryPoint(argv1, moduleUrl) {
  if (!argv1) return false;
  try {
    return realpathSync(resolve(argv1)) === realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}

if (isEntryPoint(process.argv[1], import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
