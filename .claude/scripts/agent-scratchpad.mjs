#!/usr/bin/env node

/**
 * agent-scratchpad.mjs — CLI for the cross-worktree shared scratchpad & stamp cache.
 *
 * Usage:
 *   node .claude/scripts/agent-scratchpad.mjs status [--root <path>]
 *   node .claude/scripts/agent-scratchpad.mjs check-stamp --kind <harness|trust> --hash <sha> [--root <path>]
 *   node .claude/scripts/agent-scratchpad.mjs write-stamp --kind <harness|trust> --hash <sha> [--root <path>]
 *   node .claude/scripts/agent-scratchpad.mjs record-gate --worktree <path> --stage <N> --status <pass|fail> [--fp <fp>]
 */

import { existsSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import {
  findOverlappingWorktrees,
  hasVerificationStamp,
  listActiveWorktreeSnapshots,
  resolveCommonRepoRoot,
  scratchpadDir,
  updateWorktreeSnapshot,
  writeVerificationStamp,
} from '../../.cli/lib/agent-scratchpad.mjs';
import { inferBranchFromWorktreePath } from '../../.cli/lib/worktree-plan-path.mjs';

function parseArgs(argv) {
  const [command = 'status', ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = rest[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        opts[key] = next;
        i += 1;
      } else {
        opts[key] = 'true';
      }
    }
  }
  return { command, opts };
}

function main() {
  const { command, opts } = parseArgs(process.argv.slice(2));
  const rootArg = opts.root || opts.worktree || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const mainRoot = resolveCommonRepoRoot(rootArg) || resolve(rootArg);

  if (command === 'check-stamp') {
    const ok = hasVerificationStamp(mainRoot, opts.kind, opts.hash);
    process.exit(ok ? 0 : 1);
  }

  if (command === 'write-stamp') {
    const ok = writeVerificationStamp(mainRoot, opts.kind, opts.hash, {
      worktree: opts.worktree || rootArg,
    });
    process.exit(ok ? 0 : 1);
  }

  if (command === 'record-gate') {
    const wt = resolve(opts.worktree || rootArg);
    const branch = opts.branch || inferBranchFromWorktreePath(wt);
    if (!branch) process.exit(0);
    updateWorktreeSnapshot(mainRoot, branch, {
      worktree_path: wt,
      gate_stage: Number(opts.stage || 1),
      gate_status: opts.status || 'pass',
      gate_fingerprint: opts.fp || null,
    });
    process.exit(0);
  }

  if (command === 'status') {
    const base = scratchpadDir(mainRoot);
    const worktrees = listActiveWorktreeSnapshots(mainRoot);
    const overlaps = [];
    for (const wt of worktrees) {
      const ov = findOverlappingWorktrees(mainRoot, wt.branch, wt.changed_files || []);
      if (ov.length > 0) {
        overlaps.push({ branch: wt.branch, conflicts_with: ov });
      }
    }
    let stamps = [];
    try {
      const stampDir = base ? join(base, 'stamps') : null;
      if (stampDir && existsSync(stampDir)) {
        stamps = readdirSync(stampDir)
          .filter((f) => /\.(json|ok|txt)$/.test(f))
          .map((f) => f.replace(/\.(json|ok|txt)$/, ''));
      }
    } catch {
      stamps = [];
    }
    process.stdout.write(
      JSON.stringify(
        {
          main_root: mainRoot,
          scratchpad_dir: base,
          active_worktrees: worktrees,
          file_overlaps: overlaps,
          verified_stamps: stamps,
        },
        null,
        2,
      ) + '\n',
    );
    process.exit(0);
  }

  process.stderr.write(`Unknown command: ${command}\n`);
  process.exit(1);
}

main();
