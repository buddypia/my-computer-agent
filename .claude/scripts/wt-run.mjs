#!/usr/bin/env node
/**
 * wt-run.mjs — Redirect command execution to the active worktree.
 *
 * Automatically locates the active worktree and executes verification/check
 * commands inside it when the AI session CWD resets to the main repository root.
 */

import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { resolve, join, dirname, sep } from 'node:path';
import { spawnSync, execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = resolve(__dirname, '../..');

function parseArgs(args) {
  let worktree = null;
  const cmdArgs = [];

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--worktree' || arg === '-w') {
      worktree = args[++i] || null;
    } else {
      cmdArgs.push(arg);
    }
  }

  return { worktree, cmdArgs };
}

/**
 * Is `p` the repository root or somewhere beneath it?
 *
 * `resolve()` follows `..` without complaint, so `--worktree ../../other-project` used to hand an
 * arbitrary cwd to `spawnSync(cmd, {shell: true})` — wt-run exists to run verification *inside* the
 * worktree (R-CM-034 Rule 10), and a target outside the repo voids that whole premise.
 *
 * Three details the obvious one-liner gets wrong:
 *   - Compared with a trailing separator, not `startsWith(REPO_ROOT)`: the bare prefix test also
 *     accepts the sibling `<repo>-evil`.
 *   - Resolved through `realpathSync` first: a symlink *inside* the repo may point outside it, and
 *     the lexical path alone says nothing about where the command would actually run (measured —
 *     `.tmp/<link→/tmp/x>` passed and `pwd` printed `/private/tmp/...`).
 *   - `REPO_ROOT` is already real: Node resolves module paths through the filesystem, so the two
 *     sides of the comparison are canonicalized the same way (this is what makes macOS
 *     `/tmp`→`/private/tmp` a non-issue rather than a false rejection).
 *
 * A path that does not exist yet cannot be canonicalized and is judged lexically; it is also a path
 * nothing can be executed in, so the weaker answer costs nothing.
 */
function isInsideRepo(p) {
  let real = p;
  try {
    real = realpathSync(p);
  } catch {
    // Does not exist — fall back to the lexical form.
  }
  return real === REPO_ROOT || real.startsWith(REPO_ROOT + sep);
}

/**
 * Which worktree did we pick, and where did the value come from?
 *
 * Source selection only — deliberately no validation here. Containment is enforced once, at the single
 * point where these three branches rejoin (`resolveActiveWorktree`), because a check attached per branch
 * is a check the *fourth* source will be added without.
 *
 * @returns {{ raw: string, source: string } | null}
 */
function pickWorktree(explicitWt) {
  if (explicitWt) return { raw: explicitWt, source: '--worktree' };

  // 1. Detect active worktree from CONTEXT.json
  const ctxPath = join(REPO_ROOT, 'CONTEXT.json');
  if (existsSync(ctxPath)) {
    try {
      const ctx = JSON.parse(readFileSync(ctxPath, 'utf-8'));
      if (ctx.execution?.worktree?.worktree_path) {
        return {
          raw: ctx.execution.worktree.worktree_path,
          source: 'CONTEXT.json#execution.worktree.worktree_path',
        };
      }
    } catch {
      // ignore
    }
  }

  // 2. Detect worktrees under .worktrees/ from git worktree list
  try {
    const stdout = execSync('git worktree list --porcelain', { cwd: REPO_ROOT, encoding: 'utf-8' });
    const lines = stdout.split('\n');
    const wtPaths = [];
    for (const line of lines) {
      if (line.startsWith('worktree ')) {
        const p = line.slice('worktree '.length).trim();
        // check if it is under .worktrees/
        if (p.includes('/.worktrees/')) {
          wtPaths.push(p);
        }
      }
    }

    if (wtPaths.length > 1) {
      console.warn(`[wt-run] Warning: Multiple active worktrees found. Using the first one (${wtPaths[0]}).`);
    }
    if (wtPaths.length > 0) {
      return { raw: wtPaths[0], source: 'git worktree list' };
    }
  } catch {
    // ignore
  }

  return null;
}

function resolveActiveWorktree(explicitWt) {
  const picked = pickWorktree(explicitWt);
  if (!picked) return null;

  const target = resolve(REPO_ROOT, picked.raw);
  if (!isInsideRepo(target)) {
    console.error(
      `❌ wt-run: the target worktree must stay inside the repository.\n` +
        `   source:      ${picked.source}\n` +
        `   given:       ${picked.raw}\n` +
        `   resolved to: ${target}\n` +
        `   repo root:   ${REPO_ROOT}`,
    );
    process.exit(2);
  }
  return target;
}

const { worktree: explicitWt, cmdArgs } = parseArgs(process.argv.slice(2));

if (cmdArgs.length === 0) {
  console.error('❌ wt-run: Command required. Example: node .claude/scripts/wt-run.mjs npm run test');
  process.exit(2);
}

const targetCwd = resolveActiveWorktree(explicitWt) || REPO_ROOT;

if (targetCwd === REPO_ROOT) {
  console.warn(`[wt-run] Warning: No active worktree found. Executing at main repository root (${targetCwd}).`);
} else {
  console.log(`[wt-run] CWD redirection: ${targetCwd}`);
}

const cmdString = cmdArgs.join(' ');
console.log(`[wt-run] Executing command: ${cmdString}`);

const child = spawnSync(cmdString, {
  cwd: targetCwd,
  stdio: 'inherit',
  shell: true,
});

process.exit(child.status ?? 0);
