/**
 * test-lock.mjs — Regression-test lock for fix tasks (AI-Native SDLC Playbook, Stage 4 "protect the loop").
 *
 * The playbook's rule: for a bug fix, write the failing test first, commit it, and only then let the
 * agent make it pass — "with the test-file hook enforcing the restriction. A test that existed before
 * the fix, and that the agent couldn't rewrite, is proof the bug is gone."
 *
 * **The lock is git history, not a file the agent can edit** (adversarial review 2026-09-07). On a
 * `fix/*` / `hotfix/*` branch every test file *added* by a commit on that branch (`git log --diff-filter=A
 * <trunk>..HEAD`) is locked — there is no state to forge, delete or forget to write. The only file this
 * module owns is a *ledger* in the worktree mailbox (R-CM-034 Rule 2), `.tmp/worktree-<safeBranch>/test-lock.json`:
 *
 *   {
 *     version: 1,
 *     locked_at, branch, head_sha, reason,   // manual lock metadata (feature branches, tests that were not new)
 *     files: string[],                       // manual locks — worktree-relative
 *     all_tests: boolean,                    // manual: lock every test file
 *     released: [{ at, reason, head_sha, files: string[], all_tests: boolean }]   // append-only release log
 *   }
 *
 * Up to three enforcement points read the same effective set (derived ∪ manual − released):
 *   - edit time    `.cli/hooks/coverage-threshold-guard.mjs` PreToolUse Write|Edit|MultiEdit → DENY —
 *                  **only where that hook is installed** (harness itself). The transplant bundle does not
 *                  ship it, so in a transplanted repo the first enforcement point is commit time.
 *                  Where installed it also denies Write/Edit/MultiEdit on the ledger itself; a Bash write
 *                  to it is caught at ship time instead — see `shipTestLockFindings`.
 *                  `isEditLockEnforced(root)` answers which case applies; anything that tells the agent
 *                  what is blocked asks it rather than assuming.
 *   - commit time  `.cli/hooks/commit-guard.mjs` PreToolUse Bash `git commit` → DENY when a locked file
 *                  is modified / deleted / renamed in the index or working tree, **or when the test runner
 *                  config would stop running it**. This is what closes the `sed -i` / `rm` / `git mv` hole
 *                  and the "leave the file alone, exclude it from the run" hole: whatever tool did it, it
 *                  cannot be committed (adversarial review finding #3, 2026-09-07).
 *   - ship time    `create-pr/ops.mjs#cmdShipWorktree` → warnings for every release, for any locked
 *                  file whose content differs from its red commit, and for any locked file the runner
 *                  config no longer runs (the human sees it in the Panel).
 *
 * Release is `regression-test-lock.mjs unlock <file> --reason "<why>"`: it is *recorded*, never silent.
 * Writers: `.claude/scripts/regression-test-lock.mjs` (manual lock / release). Announcer:
 * `.cli/hooks/worktree-owner-tracker.mjs` (PostToolUse Bash) tells the agent which files a commit just locked.
 *
 * Git access is injected (`gitFn(args) → string|null`, bound to a directory by the caller) so every
 * function here is unit-testable with a stub and with a real scratch repository. No global state.
 *
 * Which root owns the lock is decided from the **target file path** first (R-CM-037 — a session in
 * worktree A must not read worktree B's lock) and only then from the caller's project dir.
 *
 * Boundary (R-CM-028): boundary-uniform in meaning — a locked regression test means the same thing
 * in harness and in a generated project. Deployment is Perspective 1 only for now; the Perspective 2
 * port is tracked as follow-up debt in the PR that introduced this file.
 */

import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

import { loadWorktreePolicy, trunkBranches } from './trunk-branch.mjs';
import { atomicWriteJson, shellQuote } from './utils.mjs';
import { resolveWorktreeRoot } from './worktree-path.mjs';
import { inferBranchFromWorktreePath, resolveWorktreeTestLockPath } from './worktree-plan-path.mjs';

export const TEST_LOCK_VERSION = 1;

/** Branches whose commits lock the test files they add. Feature branches edit tests continuously. */
export const DERIVED_LOCK_BRANCH_RE = /^(fix|hotfix)\//;

/** The ledger itself (mailbox slot). Write/Edit is denied; a Bash forge still lands and is surfaced at ship time. */
export const LOCK_FILE_RE = /(^|\/)\.tmp\/worktree-[^/]+\/test-lock\.json$/;

/** The edit-time enforcer (see the header). Installed in harness; not shipped by the transplant bundle. */
export const EDIT_LOCK_GUARD_MODULE = '.cli/hooks/coverage-threshold-guard.mjs';

/** Files a CLI reads its hook wiring from (Claude Code / Codex / Antigravity). */
const HOOK_WIRING_FILES = Object.freeze(['.claude/settings.json', '.codex/hooks.json', '.agents/hooks.json']);

/**
 * Whether edits to a locked test are denied in `root` — i.e. whether anything may promise it.
 *
 * True only when the guard module exists **and** some CLI wiring reaches it: a wiring file names the
 * module, or `.claude/settings.json` sends PreToolUse Edit/Write to `hook-orchestrator.mjs` (which
 * dispatches `hook-registry.mjs`, where the catalog registers the guard on Edit|Write).
 * Existence alone is not enough (a copied but unwired hook fires nowhere) and neither is wiring alone
 * (the orchestrator skips a module that is not there). Anything unreadable → false: an announcement
 * that under-promises costs nothing, one that over-promises is the defect this exists to prevent
 * (`harness-wiring.test.mjs`, 2026-09-19: the agent was told edits were blocked in a
 * repo that had no edit guard).
 *
 * @param {string} root Repository (or worktree) root.
 * @param {{existsFn?: typeof existsSync, readFn?: typeof readFileSync}} [io] Test-injectable.
 * @returns {boolean}
 */
export function isEditLockEnforced(root, { existsFn = existsSync, readFn = readFileSync } = {}) {
  if (typeof root !== 'string' || !root) return false;
  try {
    if (!existsFn(resolve(root, EDIT_LOCK_GUARD_MODULE))) return false;
    for (const rel of HOOK_WIRING_FILES) {
      const abs = resolve(root, rel);
      if (!existsFn(abs)) continue;
      const raw = String(readFn(abs, 'utf8'));
      if (raw.includes(EDIT_LOCK_GUARD_MODULE)) return true;
      if (rel === HOOK_WIRING_FILES[0] && orchestratesEditHooks(JSON.parse(raw))) return true;
    }
  } catch {
    // unreadable / malformed wiring → do not promise
  }
  return false;
}

function orchestratesEditHooks(settings) {
  return (settings?.hooks?.PreToolUse ?? []).some(
    (g) =>
      /(^|\|)(Edit|Write)(\||$)/.test(g?.matcher ?? '') &&
      (g.hooks ?? []).some((h) => typeof h?.command === 'string' && h.command.includes('hook-orchestrator.mjs')),
  );
}

/**
 * Test-file classification. Mirrors the `paths:` frontmatter of `.claude/rules/common/testing.md`
 * (R-CM-002) so "what counts as a test" has one shape across the rule and the guard.
 */
export const TEST_FILE_PATTERNS = Object.freeze([
  /(^|\/)(tests?|__tests__)\//,
  /\.(test|spec)\.[cm]?[jt]sx?$/,
  /_test\.(py|go|rs|dart)$/,
  /Test\.(java|kt|swift|cs|php)$/,
]);

/** @param {string} relPath worktree-relative, forward slashes */
export function isTestFilePath(relPath) {
  if (!relPath || typeof relPath !== 'string') return false;
  const norm = relPath.replace(/\\/g, '/');
  return TEST_FILE_PATTERNS.some((p) => p.test(norm));
}

/** @param {string} filePath absolute or relative; forward or back slashes */
export function isProtectedLockFile(filePath) {
  if (!filePath || typeof filePath !== 'string') return false;
  return LOCK_FILE_RE.test(filePath.replace(/\\/g, '/'));
}

// `shellQuote` lives in `.cli/lib/utils.mjs`, beside the `safeGit` whose shell string creates the
// obligation. Re-exported so existing importers keep working with exactly one implementation.
export { shellQuote };

/**
 * Resolves which root's mailbox holds the lock for a given target path.
 *
 * A *relative* `filePath` with no `fallbackRoot` cannot be placed anywhere and returns null — i.e.
 * fails open. Claude Code always passes absolute `tool_input.file_path`, so this branch is a
 * documented edge, not a live path.
 *
 * @param {string} filePath - absolute or relative target path
 * @param {string|null} fallbackRoot - project dir used when the path is not under `.worktrees/`
 * @returns {{root: string, lockPath: string}|null}
 */
export function resolveLockScope(filePath, fallbackRoot) {
  const abs = filePath && fallbackRoot && !isAbsolute(filePath) ? resolve(fallbackRoot, filePath) : filePath;
  const root = resolveWorktreeRoot(abs) ?? fallbackRoot ?? null;
  if (!root) return null;
  return { root, lockPath: resolveWorktreeTestLockPath(root) };
}

function normalizeReleases(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((r) => r && typeof r === 'object')
    .map((r) => ({
      at: r.at ?? null,
      reason: typeof r.reason === 'string' ? r.reason : '',
      head_sha: r.head_sha ?? null,
      files: Array.isArray(r.files) ? r.files.filter((f) => typeof f === 'string' && f) : [],
      all_tests: r.all_tests === true,
    }));
}

/**
 * Reads and shape-checks the ledger. Anything unreadable or malformed is `null` — the guard is
 * fail-open (R-CM-006 Rule 2), so a corrupt ledger must never turn into a silent deny. Note that a
 * missing or corrupt ledger does **not** unlock anything on a fix branch: the derived set needs no file.
 *
 * @param {string} lockPath
 * @returns {object|null}
 */
export function readTestLock(lockPath) {
  try {
    if (!lockPath || !existsSync(lockPath)) return null;
    const parsed = JSON.parse(readFileSync(lockPath, 'utf-8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    if (!Array.isArray(parsed.files)) return null;
    return {
      version: parsed.version ?? TEST_LOCK_VERSION,
      locked_at: parsed.locked_at ?? null,
      branch: parsed.branch ?? null,
      head_sha: parsed.head_sha ?? null,
      reason: typeof parsed.reason === 'string' ? parsed.reason : '',
      files: parsed.files.filter((f) => typeof f === 'string' && f.length > 0),
      all_tests: parsed.all_tests === true,
      released: normalizeReleases(parsed.released),
    };
  } catch {
    return null;
  }
}

/**
 * Worktree-relative, forward-slash path for a locked entry or a target path.
 * Returns null when the path escapes the root (`..`) — an escaped path is never "locked".
 */
export function toRootRelative(root, p) {
  if (!root || !p) return null;
  const abs = isAbsolute(p) ? p : resolve(root, p);
  const rel = relative(root, abs).replace(/\\/g, '/');
  if (!rel || rel === '..' || rel.startsWith('../')) return null;
  return rel;
}

/** Files released by `unlock` (root-relative). */
export function releasedFileSet(lock) {
  const out = new Set();
  for (const r of lock?.released ?? []) for (const f of r.files) out.add(f.replace(/\\/g, '/'));
  return out;
}

/** `all_tests` stays in force until a release entry carries `all_tests: true`. */
export function effectiveAllTests(lock) {
  return lock?.all_tests === true && !(lock.released ?? []).some((r) => r.all_tests);
}

/**
 * Manual-lock membership (ledger `files` / `all_tests`), ignoring releases.
 * @param {object} lock - output of readTestLock
 */
export function isLockedFile(lock, root, filePath) {
  if (!lock) return false;
  const rel = toRootRelative(root, filePath);
  if (!rel) return false;
  if (lock.all_tests && isTestFilePath(rel)) return true;
  return lock.files.some((f) => toRootRelative(root, f) === rel);
}

/* ------------------------------------------------------------------------------------------------
 * Derived lock — git history
 * ---------------------------------------------------------------------------------------------- */

function trunksFor(root) {
  try {
    return trunkBranches(loadWorktreePolicy(root));
  } catch {
    return trunkBranches(null);
  }
}

/**
 * The ref the branch is compared against: `origin/<trunk>` when fetched, else the local trunk.
 * @param {(args: string) => string|null} gitFn
 * @param {string[]} trunks
 * @returns {string|null}
 */
export function resolveDerivedBase(gitFn, trunks) {
  for (const t of trunks) {
    for (const ref of [`origin/${t}`, t]) {
      if (gitFn(`rev-parse --verify -q ${shellQuote(ref)}`)) return ref;
    }
  }
  return null;
}

/** Parses `git log --diff-filter=A --name-only --format=%H` into `[{path, sha}]`. */
export function parseAddedLog(text) {
  const out = [];
  let sha = null;
  for (const raw of String(text ?? '').split('\n')) {
    const line = raw.trim();
    if (!line) continue;
    if (/^[0-9a-f]{40}$/.test(line)) sha = line;
    else out.push({ path: line.replace(/\\/g, '/'), sha });
  }
  return out;
}

/**
 * Test files added by commits on this branch since it left the trunk. Empty outside `fix/*` / `hotfix/*`,
 * without git, or when no trunk ref can be found (fail-open — the manual ledger still applies).
 *
 * @param {{branch: string|null, gitFn?: (args: string) => string|null, trunks?: string[], pathspec?: string|null}} args
 * @returns {{path: string, sha: string|null}[]}
 */
export function derivedLockedFiles({ branch, gitFn, trunks = trunkBranches(null), pathspec = null }) {
  if (!branch || !DERIVED_LOCK_BRANCH_RE.test(branch) || typeof gitFn !== 'function') return [];
  const base = resolveDerivedBase(gitFn, trunks);
  if (!base) return [];
  const spec = pathspec ? ` -- ${shellQuote(pathspec)}` : '';
  const out = gitFn(`log --diff-filter=A --name-only --format=%H ${shellQuote(base)}..HEAD${spec}`);
  return parseAddedLog(out).filter((e) => isTestFilePath(e.path));
}

/**
 * The set every enforcement point agrees on: derived (git) ∪ manual (ledger) − released.
 *
 * @param {{root: string, branch?: string|null, lock?: object|null, gitFn?: (args: string) => string|null}} args
 * @returns {{files: Map<string, {source: 'commit'|'manual', sha: string|null}>, all_tests: boolean,
 *            released: object[], branch: string|null}}
 */
export function effectiveTestLock({ root, branch = null, lock = null, gitFn = null }) {
  const br = branch ?? lock?.branch ?? inferBranchFromWorktreePath(root);
  const released = releasedFileSet(lock);
  const files = new Map();
  addDerivedLocks(files, released, { branch: br, gitFn, trunks: trunksFor(root) });
  addManualLocks(files, released, root, lock);
  return { files, all_tests: effectiveAllTests(lock), released: lock?.released ?? [], branch: br };
}

function addDerivedLocks(files, released, args) {
  for (const e of derivedLockedFiles(args)) {
    if (!released.has(e.path)) files.set(e.path, { source: 'commit', sha: e.sha });
  }
}

function addManualLocks(files, released, root, lock) {
  if (!lock) return;
  for (const f of lock.files) {
    const rel = toRootRelative(root, f);
    if (rel && !released.has(rel) && !files.has(rel)) files.set(rel, { source: 'manual', sha: lock.head_sha ?? null });
  }
}

/* ------------------------------------------------------------------------------------------------
 * Runner reachability — "the file is intact but it never runs again"
 *
 * Adversarial review #3 (2026-09-07): every check above watches the *test file*. Adding its path to
 * `test.exclude` in `vitest.config.ts` leaves the file byte-for-byte untouched and satisfies all of them,
 * while the test never executes — so a fix, correct or not, ships green. Closed the same way as the shell
 * edits: read the config from the working tree (tool-independent) and refuse the commit.
 * ---------------------------------------------------------------------------------------------- */

/**
 * Test-runner configs whose `test.include` / `test.exclude` decide whether a locked test still runs.
 * Workspace files hold one `test:` block per project; every one of them is read (see `parseRunnerScope`).
 *
 * Known gaps, documented rather than half-parsed (delta review, 2026-09-07):
 *   - **Jest.** Its scope keys are `testMatch` (globs) and `testPathIgnorePatterns` (*regexes*), and
 *     `package.json#jest` is a valid config location. Listing jest files for a glob parser would buy
 *     false assurance, not coverage — Perspective 1 runs vitest. The Perspective 2 port (follow-up
 *     debt) must add them with jest's own semantics.
 *   - A `--exclude` / `--testPathIgnorePatterns` flag added to a `package.json` test script.
 * Both still appear in the diff the human reads at ship time; neither is caught here.
 */
export const RUNNER_CONFIG_FILES = Object.freeze([
  'vitest.config.ts', 'vitest.config.js', 'vitest.config.mts', 'vitest.config.mjs', 'vitest.config.cts',
  'vitest.workspace.ts', 'vitest.workspace.js', 'vitest.workspace.mts', 'vitest.workspace.mjs',
]);

/**
 * Minimal glob → RegExp for runner include/exclude entries: `**` any depth, `*` within a segment,
 * `?` one char, `{a,b}` alternation. A bare directory or prefix (`node_modules`, `.claude`) matches
 * anything under it, which is how vitest treats these entries.
 */
export function globToRegExp(glob) {
  const g = String(glob).replace(/\\/g, '/').replace(/^\.\//, '');
  let out = '';
  for (let i = 0; i < g.length; i += 1) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') {
        out += '.*';
        i += 1;
        if (g[i + 1] === '/') i += 1;
      } else out += '[^/]*';
    } else if (c === '?') out += '[^/]';
    else if (c === '{') out += '(';
    else if (c === '}') out += ')';
    else if (c === ',') out += '|';
    else out += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
  }
  // No glob metacharacter at all → a plain prefix (directory) entry, as vitest reads it.
  const prefixOnly = !/[*?{]/.test(g);
  return new RegExp(`^${out}${prefixOnly ? '(/.*)?' : ''}$`);
}

/** `key: [ 'a', "b" ]` inside `source` → the string entries. Comments and trailing commas tolerated. */
export function parseGlobList(source, key) {
  const re = new RegExp(`(?:^|[^\\w$])${key}\\s*:\\s*\\[`, 'g');
  const out = [];
  let m;
  while ((m = re.exec(source))) {
    const start = source.indexOf('[', m.index);
    let depth = 0;
    let end = -1;
    for (let i = start; i < source.length; i += 1) {
      if (source[i] === '[') depth += 1;
      else if (source[i] === ']') {
        depth -= 1;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end === -1) continue;
    const body = source.slice(start + 1, end);
    out.push([...body.matchAll(/['"`]([^'"`]+)['"`]/g)].map((x) => x[1]));
  }
  return out;
}

/** Body between the delimiters of the balanced pair opening at `openIdx`, or `null` if unterminated. */
function balancedBody(src, openIdx, open, close) {
  let depth = 0;
  for (let i = openIdx; i < src.length; i += 1) {
    if (src[i] === open) depth += 1;
    else if (src[i] === close) {
      depth -= 1;
      if (depth === 0) return src.slice(openIdx + 1, i);
    }
  }
  return null;
}

/** First `key: {` at or after `from` → the index of the key and of its opening brace. */
function findObjectKey(src, key, from = 0) {
  const re = new RegExp(`(^|[^\\w$])(${key})\\s*:\\s*\\{`, 'g');
  re.lastIndex = from;
  const m = re.exec(src);
  if (!m) return null;
  const keyAt = m.index + m[1].length;
  return { keyAt, braceAt: src.indexOf('{', keyAt) };
}

/** Drops every nested `key: { ... }` sub-object so its own lists can never be read as the test scope. */
function stripNestedObject(body, key) {
  let out = body;
  for (let hit = findObjectKey(out, key); hit; hit = findObjectKey(out, key)) {
    const inner = balancedBody(out, hit.braceAt, '{', '}');
    if (inner === null) return out.slice(0, hit.keyAt); // unterminated → nothing after it is readable
    out = `${out.slice(0, hit.keyAt)}${out.slice(hit.braceAt + inner.length + 2)}`;
  }
  return out;
}

/** Every `test: { ... }` block body, each with its nested `coverage: { ... }` removed. */
function testBlockBodies(src) {
  const out = [];
  for (let at = 0; ; ) {
    const hit = findObjectKey(src, 'test', at);
    if (!hit) return out;
    const body = balancedBody(src, hit.braceAt, '{', '}');
    if (body === null) return out;
    out.push(stripNestedObject(body, 'coverage'));
    at = hit.braceAt + body.length + 2;
  }
}

/** Accumulates one `test:` block's lists; a key present without a literal array is named, not read as empty. */
function collectScope(body, acc) {
  for (const key of ['include', 'exclude']) {
    const lists = parseGlobList(body, key);
    if (lists.length === 0) {
      if (new RegExp(`(^|[^\\w$])${key}\\s*:`).test(body)) acc.unverified.add(key);
      if (key === 'include') acc.everyBlockIncludes = false;
      continue;
    }
    acc[key].push(...lists.flat());
  }
}

/**
 * `test.include` / `test.exclude` of the runner config.
 *
 * Scoped by brace span, never by textual position. `coverage` is excised only where it is a nested
 * sub-object *inside* a `test:` block (its lists select instrumented sources, not which tests run), so
 * a config that writes coverage options above its own `exclude` — an ordinary layout — is still read.
 * The previous version cut the whole file at the first textual `coverage:` and went blind on exactly
 * that layout, defeating the commit gate with no attack involved (delta review, 2026-09-07).
 *
 * Every `test:` block is read, which is what a `vitest.workspace.*` file needs. `exclude` is the union
 * across projects. `include` is reported only when *every* block sets one, because a block that omits it
 * runs the runner's default and could still reach the file — reporting otherwise would deny honest work.
 *
 * `unverified` names keys present but not written as literal arrays (`exclude: sharedExcludes`). They
 * cannot be resolved without evaluating the config, so they never block a commit; they are reported at
 * ship time for a human.
 *
 * `fragment: true` is for the edit guard, which sees only the replacement text of an Edit — a bare
 * `exclude: [...]` with no enclosing `test: {` around it. Without it that text parses to nothing and the
 * edit-time nudge goes silent. Full files are never parsed this way: a real config always has a `test:`
 * block, so the strict path stays strict.
 *
 * @returns {{include: string[]|null, exclude: string[], unverified: string[]}}
 */
export function parseRunnerScope(source, { fragment = false } = {}) {
  const src = String(source ?? '');
  const found = testBlockBodies(src);
  const bodies = found.length === 0 && fragment ? [stripNestedObject(src, 'coverage')] : found;
  const acc = { include: [], exclude: [], unverified: new Set(), everyBlockIncludes: bodies.length > 0 };
  for (const body of bodies) collectScope(body, acc);
  return {
    include: acc.everyBlockIncludes && acc.include.length ? [...new Set(acc.include)] : null,
    exclude: [...new Set(acc.exclude)],
    unverified: [...acc.unverified],
  };
}

/**
 * Locked files the runner config would no longer run: matched by an `exclude` glob, or left out by a
 * present `include` list. A config that cannot be read or parsed yields `[]` (fail-open, R-CM-006 Rule 2).
 *
 * @param {{root: string, files: string[], readFile?: (abs: string) => string|null,
 *          configs?: string[]}} args
 * @returns {{path: string, config: string, why: 'excluded'|'not_included', glob: string|null}[]}
 */
export function unreachableLockedFiles({ root, files, readFile = defaultReadFile, configs = RUNNER_CONFIG_FILES }) {
  const out = [];
  if (!root || files.length === 0) return out;
  for (const cfg of configs) {
    const source = readFile(resolve(root, cfg));
    if (!source) continue;
    const { include, exclude, unverified } = parseRunnerScope(source);
    for (const key of unverified) out.push({ path: null, config: cfg, why: 'unverifiable', glob: key });
    const excludeRes = exclude.map((g) => [g, globToRegExp(g)]);
    const includeRes = include ? include.map((g) => globToRegExp(g)) : null;
    for (const f of files) {
      const hit = excludeRes.find(([, re]) => re.test(f));
      if (hit) out.push({ path: f, config: cfg, why: 'excluded', glob: hit[0] });
      else if (includeRes && !includeRes.some((re) => re.test(f))) {
        out.push({ path: f, config: cfg, why: 'not_included', glob: null });
      }
    }
  }
  return out;
}

function defaultReadFile(abs) {
  try {
    return existsSync(abs) ? readFileSync(abs, 'utf-8') : null;
  } catch {
    return null;
  }
}

export function formatUnreachableLine({ path, config, why, glob }) {
  if (why === 'unverifiable') {
    return `${config} — \`${glob}\` is not a literal list, so what it removes cannot be read here`;
  }
  return why === 'excluded'
    ? `${path} — excluded by ${config} (${glob})`
    : `${path} — no include pattern in ${config} matches it`;
}

/* ------------------------------------------------------------------------------------------------
 * Edit-time verdict (coverage-threshold-guard, where installed)
 * ---------------------------------------------------------------------------------------------- */

const NONE = Object.freeze({ locked: false, kind: null, root: null, lockPath: null, rel: null, lock: null, source: null, sha: null });

function derivedHit(root, branch, rel, gitFn) {
  if (typeof gitFn !== 'function' || !isTestFilePath(rel)) return null;
  const [hit] = derivedLockedFiles({ branch, gitFn, trunks: trunksFor(root), pathspec: rel });
  return hit ?? null;
}

/**
 * One-call verdict for the edit guard.
 *
 * @param {{filePath: string, fallbackRoot?: string|null, gitFn?: ((args: string, cwd: string) => string|null)|null}} args
 *   `gitFn(args, cwd)` — the guard passes `safeGit`; it is bound to the resolved root here on the default budget.
 * @returns {{locked: boolean, kind: 'lock_file'|'test'|null, root: string|null, lockPath: string|null,
 *            rel: string|null, lock: object|null, source: 'commit'|'manual'|null, sha: string|null}}
 */
export function evaluateTestLock({ filePath, fallbackRoot = null, gitFn = null }) {
  if (!filePath || typeof filePath !== 'string') return { ...NONE };
  if (isProtectedLockFile(filePath)) return { ...NONE, locked: true, kind: 'lock_file', lockPath: filePath };
  const scope = resolveLockScope(filePath, fallbackRoot);
  if (!scope) return { ...NONE };
  const lock = readTestLock(scope.lockPath);
  const rel = toRootRelative(scope.root, filePath);
  const base = { ...NONE, root: scope.root, lockPath: scope.lockPath, rel, lock };
  if (!rel || releasedFileSet(lock).has(rel)) return base;
  if (manualHit(lock, scope.root, rel)) return { ...base, locked: true, kind: 'test', source: 'manual', sha: lock.head_sha };
  const bound = gitFn ? (args) => gitFn(args, scope.root) : null; // default budget — never narrower than safeExec
  const hit = derivedHit(scope.root, lock?.branch ?? inferBranchFromWorktreePath(scope.root), rel, bound);
  return hit ? { ...base, locked: true, kind: 'test', source: 'commit', sha: hit.sha } : base;
}

/** Manual-ledger hit for an already root-relative path (releases handled by the caller). */
function manualHit(lock, root, rel) {
  if (!lock) return false;
  if (lock.files.some((f) => toRootRelative(root, f) === rel)) return true;
  return effectiveAllTests(lock) && isTestFilePath(rel);
}

const RELEASE_ROUTE =
  `Route: fix the code under test instead. If the test itself is wrong, say so to the user, then\n` +
  `  node .claude/scripts/regression-test-lock.mjs unlock <file> --reason "<why>"\n` +
  `  (the release is recorded in the ledger and listed in the Pre-Ship Panel — it is never silent)`;

/**
 * Deny text. A block must explain itself and name the route out (Playbook Stage 5 "Hooks as approval
 * gates": "when a hook stops an action the reason and the route to approval appear in Claude's output").
 */
export function formatTestLockDenial({ rel, lock, lockPath, kind, source, sha }) {
  if (kind === 'lock_file') {
    return (
      `[Test Lock] The test-lock ledger is not edited by hand\n` +
      `File: ${lockPath}\n\n` +
      `Why: on fix/hotfix branches the lock is git history (tests added by your commits); this file only records\n` +
      `manual locks and releases. Editing it by hand would hide a release from the Pre-Ship Panel.\n\n` +
      `Route: node .claude/scripts/regression-test-lock.mjs lock <file>... | unlock <file>... --reason "<why>" | status`
    );
  }
  const short = sha || lock?.head_sha ? String(sha || lock.head_sha).slice(0, 12) : null;
  const origin =
    source === 'commit'
      ? `added by commit ${short} on this fix branch (git history is the lock)`
      : `manual lock${short ? ` (committed at ${short})` : ''} — ${lock?.reason || 'no reason recorded'}`;
  return (
    `[Test Lock] Editing a locked regression test is blocked during a fix task\n` +
    `File: ${rel}\n` +
    `Lock: ${origin}\n` +
    `Ledger: ${lockPath}\n\n` +
    `Why: the failing test was committed before the fix so that it proves the bug is gone. ` +
    `Making it pass by rewriting it proves nothing (Playbook Stage 4 "protect the loop", R-CM-002 Rule 10).\n\n` +
    RELEASE_ROUTE
  );
}

/* ------------------------------------------------------------------------------------------------
 * Commit-time verdict (commit-guard) and ship-time findings (create-pr/ops.mjs)
 * ---------------------------------------------------------------------------------------------- */

/**
 * Parses `git status --porcelain=v1` (`XY path` / `XY old -> new`).
 *
 * Column-tolerant on purpose: `safeGit` trims its output, so the first line loses the leading space of
 * a worktree-only change (` M path` → `M path`). The X/Y distinction is not needed here — any status
 * letter means "changed", and a new file is recognised by `A` in either column — so the code is read as
 * the run of status letters before the first blank.
 */
export function parseStatusPorcelain(text) {
  const out = [];
  for (const raw of String(text ?? '').split('\n')) {
    const m = /^([MADRCUT?!]{1,2}) +(.+)$/.exec(raw.trim());
    if (!m) continue;
    const [, xy, rest] = m;
    const arrow = rest.indexOf(' -> ');
    if (arrow >= 0) out.push({ xy, from: rest.slice(0, arrow).replace(/\\/g, '/'), path: rest.slice(arrow + 4).replace(/\\/g, '/') });
    else out.push({ xy, from: null, path: rest.replace(/\\/g, '/') });
  }
  return out;
}

/**
 * Locked files with pending changes in the index or working tree. A *new* file (index `A`, or untracked)
 * is never dirty — that is the red commit being staged, which the lock exists to protect, not to block.
 *
 * @param {{files: string[], allTests?: boolean, gitFn: (args: string) => string|null}} args
 * @returns {{path: string, status: string}[]}
 */
export function dirtyLockedFiles({ files, allTests = false, gitFn }) {
  if (typeof gitFn !== 'function' || (!allTests && files.length === 0)) return [];
  const spec = allTests ? '' : ` -- ${files.map(shellQuote).join(' ')}`;
  const out = gitFn(`status --porcelain=v1 --untracked-files=no${spec}`);
  if (out === null) return [];
  const isLocked = (p) => (allTests ? isTestFilePath(p) : files.includes(p));
  return parseStatusPorcelain(out)
    .filter((e) => !e.xy.includes('A') && (isLocked(e.path) || (e.from && isLocked(e.from))))
    .map((e) => ({ path: e.from ?? e.path, status: e.xy.trim() || '??' }));
}

/**
 * Commit-time verdict: null when the commit may proceed.
 *
 * @param {{root: string, gitFn: (args: string) => string|null, lock?: object|null}} args
 * @returns {{dirty: {path: string, status: string}[], branch: string|null,
 *            files: Map<string, {source: string, sha: string|null}>}|null}
 */
export function evaluateCommitTestLock({ root, gitFn, lock = undefined, readFile = undefined }) {
  const ledger = lock === undefined ? readTestLock(resolveWorktreeTestLockPath(root)) : lock;
  const eff = effectiveTestLock({ root, lock: ledger, gitFn });
  if (eff.files.size === 0 && !eff.all_tests) return null;
  const locked = [...eff.files.keys()];
  const dirty = dirtyLockedFiles({ files: locked, allTests: eff.all_tests, gitFn });
  const found = unreachableLockedFiles({ root, files: locked, ...(readFile ? { readFile } : {}) });
  const unreachable = found.filter((u) => u.why !== 'unverifiable'); // unresolvable ≠ proven broken
  if (dirty.length === 0 && unreachable.length === 0) return null;
  return { dirty, unreachable, branch: eff.branch, files: eff.files };
}

export function formatCommitLockDenial({ dirty = [], unreachable = [], branch, files }) {
  const parts = [`[Commit Guard] This commit would neutralize a locked regression test${branch ? ` on ${branch}` : ''}`];
  if (dirty.length) {
    parts.push(
      'Changed:',
      ...dirty.map((d) => {
        const meta = files.get(d.path);
        const via = meta?.source === 'commit' ? `red commit ${String(meta.sha).slice(0, 12)}` : 'manual lock';
        return `  ${d.status.padEnd(2)} ${d.path}  (${via})`;
      }),
    );
  }
  if (unreachable.length) {
    parts.push('Would no longer run:', ...unreachable.map((u) => `  ${formatUnreachableLine(u)}`));
  }
  parts.push(
    '',
    'Why: the test was committed before the fix to prove the bug is gone. Rewriting it, deleting it, moving it, or',
    'leaving it intact while the runner stops running it all prove the same thing: nothing (Playbook Stage 4',
    '"protect the loop", R-CM-002 Rule 10). An edit guard (where installed) is bypassable by shell edits — the commit is not.',
    '',
    'Route: restore the test (git restore <file>) or the runner config, and fix the code. If the test itself is',
    'wrong, tell the user and release it:',
    '  node .claude/scripts/regression-test-lock.mjs unlock <file> --reason "<why>"   # recorded, shown in the Pre-Ship Panel',
  );
  return parts.join('\n');
}

/**
 * Ship-time findings (strings) — every release, and every locked file whose content moved after its red
 * commit (or is dirty). Non-blocking by design: the human is the judge, this makes sure they see it.
 *
 * @param {{root: string, gitFn: (args: string) => string|null, lock?: object|null}} args
 * @returns {string[]}
 */
export function shipTestLockFindings({ root, gitFn, lock = undefined }) {
  const ledger = lock === undefined ? readTestLock(resolveWorktreeTestLockPath(root)) : lock;
  const out = [];
  for (const r of ledger?.released ?? []) {
    const what = r.all_tests ? 'all test files' : r.files.join(', ');
    out.push(`regression-test lock released: ${what} — "${r.reason || 'no reason'}" (${r.at ?? 'unknown time'})`);
  }
  const eff = effectiveTestLock({ root, lock: ledger, gitFn });
  for (const [path, meta] of eff.files) {
    if (!meta.sha) continue;
    const moved = gitFn(`diff --name-only ${shellQuote(meta.sha)} HEAD -- ${shellQuote(path)}`);
    if (moved) out.push(`locked regression test changed after its red commit ${String(meta.sha).slice(0, 12)}: ${path}`);
  }
  for (const d of dirtyLockedFiles({ files: [...eff.files.keys()], allTests: eff.all_tests, gitFn })) {
    out.push(`locked regression test has uncommitted changes (${d.status}): ${d.path}`);
  }
  for (const u of unreachableLockedFiles({ root, files: [...eff.files.keys()] })) {
    out.push(`locked regression test would not run: ${formatUnreachableLine(u)}`);
  }
  return out;
}

/* ------------------------------------------------------------------------------------------------
 * Ledger writers (CLI only)
 * ---------------------------------------------------------------------------------------------- */

/** Union that preserves order and reports what was new. Pure. */
export function mergeLockedFiles(existing, incoming) {
  const merged = [...existing];
  const added = [];
  for (const f of incoming) {
    if (typeof f !== 'string' || !f || merged.includes(f)) continue;
    merged.push(f);
    added.push(f);
  }
  return { merged, added };
}

const EMPTY_LEDGER = Object.freeze({ files: [], all_tests: false, branch: null, head_sha: null, reason: '', released: [] });

/**
 * Manual lock. Unions `files` into the ledger, never *removes* a file (release is `unlock` only), and
 * re-locking a released file takes it out of the release entries so the lock is active again.
 * Metadata precedence: explicit argument → existing ledger → empty.
 *
 * @param {{lockPath: string, files?: string[], allTests?: boolean, reason?: string,
 *          headSha?: string|null, branch?: string|null, now?: () => string}} args
 * @returns {{lock: object, added: string[]}}
 */
export function upsertTestLock(args) {
  const existing = readTestLock(args.lockPath) ?? EMPTY_LEDGER;
  const { merged, added } = mergeLockedFiles(existing.files, args.files ?? []);
  const relocked = new Set(args.files ?? []);
  const lock = {
    version: TEST_LOCK_VERSION,
    locked_at: (args.now ?? (() => new Date().toISOString()))(),
    branch: args.branch ?? existing.branch,
    head_sha: args.headSha ?? existing.head_sha,
    reason: args.reason || existing.reason,
    files: merged,
    all_tests: args.allTests === true || existing.all_tests === true,
    released: existing.released.map((r) => ({
      ...r,
      files: r.files.filter((f) => !relocked.has(f)),
      all_tests: r.all_tests && args.allTests !== true,
    })),
  };
  atomicWriteJson(args.lockPath, lock);
  return { lock, added };
}

/**
 * Release. Appends to `released[]` — the ledger is never deleted, so the release is visible at ship time.
 *
 * @param {{lockPath: string, files: string[], allTests?: boolean, reason: string, headSha?: string|null,
 *          branch?: string|null, now?: () => string}} args
 * @returns {{lock: object, entry: object}}
 */
export function recordTestLockRelease(args) {
  if (!args.reason || typeof args.reason !== 'string') throw new Error('release reason is required');
  const existing = readTestLock(args.lockPath) ?? EMPTY_LEDGER;
  const entry = {
    at: (args.now ?? (() => new Date().toISOString()))(),
    reason: args.reason,
    head_sha: args.headSha ?? null,
    files: [...new Set((args.files ?? []).filter((f) => typeof f === 'string' && f))],
    all_tests: args.allTests === true,
  };
  const lock = {
    version: TEST_LOCK_VERSION,
    locked_at: existing.locked_at ?? null,
    branch: args.branch ?? existing.branch,
    head_sha: existing.head_sha,
    reason: existing.reason,
    files: existing.files,
    all_tests: existing.all_tests,
    released: [...existing.released, entry],
  };
  atomicWriteJson(args.lockPath, lock);
  return { lock, entry };
}
