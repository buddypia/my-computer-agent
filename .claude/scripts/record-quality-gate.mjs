#!/usr/bin/env node

/**
 * record-quality-gate.mjs — Pre-Ship Quality Gate PROOF persistence CLI
 * (teamwork-preview transplant Phase 2, R-CM-030 Rule 8/9).
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Quality Gate verdict PROOF (command / actual result / finding / verdict)
 *       exists only in chat — auditability is lost after session termination and R-CM-030 Rule 9
 *       No-Go enforcement relies solely on prompt-level discipline.
 *   (b) Existing gap: mark-pre-ship-confirmed.mjs marker only persists label + confirmed_at
 *       — No-Go re-verification at ship time was impossible without detailed PROOF.
 *   (c) Simpler alternative: Writing quality-gate.json directly via AI Write tool risks
 *       silently dead data on consumer fail-open due to missing schema validation. This CLI
 *       guarantees the contract via write-time validation + atomic write.
 *
 * Usage (Immediately after verdict — prior to Pre-Ship Human Review Panel):
 *   node .claude/scripts/record-quality-gate.mjs <branch|worktree-path> --json '<record>'
 *   node .claude/scripts/record-quality-gate.mjs feature/foo --from <record.json>
 *
 *   Record example (branch / recorded_at are stamped by CLI and can be omitted):
 *   {
 *     "verdict": "go",
 *     "quality_label": "agent_go",
 *     "gates": [
 *       { "name": "code-review --fix", "status": "pass",
 *         "command": "/code-review --fix", "detail": "0 correctness issues, applied 2 cleanups" },
 *       { "name": "code-reviewer agent", "status": "pass",
 *         "detail": "Go — 0 CRITICAL/HIGH", "finding": "LOW 1 item (fixed)" }
 *     ]
 *   }
 *
 * Behavior:
 *   - Schema validation: worktree-quality-gate.mjs#validateQualityGateRecord (SSOT), run here with
 *     `rejectUnknownKeys` — this is the only producer, so a mistyped key must fail here or it is
 *     lost for good. Key allowlists: `RECORD_KEYS` / `GATE_ENTRY_KEYS`.
 *   - Record location: <worktree>/.tmp/worktree-<safeBranch>/quality-gate.json
 *     (worktree-plan-path.mjs#resolveWorktreeQualityGatePath SSOT, atomic write).
 *   - Automatic stamp of branch / recorded_at (overrides user inputs to prevent tampering).
 *
 * Exit codes:
 *   0 — Successfully recorded (stdout: record path + verdict summary)
 *   1 — Missing args / worktree absent / JSON parse failure / schema violation
 *
 * Boundary (R-CM-028): Perspective 1 (harness itself) only.
 * Regression tests: `tests/unit/worktree-quality-gate.test.mjs`.
 */

import { readFileSync } from 'node:fs';
import { resolveWorktreeQualityGatePath } from '../../.cli/lib/worktree-plan-path.mjs';
import { validateQualityGateRecord, resolveHeadShaResult } from './lib/worktree-quality-gate.mjs';
import { writeJsonAtomicSync } from './lib/atomic-fs.mjs';
import {
  resolveMainRoot,
  resolveBranch,
  resolveWorktreeDir,
  isMainModule,
} from './mark-pre-ship-confirmed.mjs';

const USAGE =
  'Usage: node .claude/scripts/record-quality-gate.mjs <branch | worktree-path> ' +
  "(--json '<record>' | --from <record.json>)\n";

/**
 * Records PROOF record (validation + stamp + atomic write). Pure-ish — caller pre-computes paths.
 * Defensively copies gates array to prevent mutation of caller's record.
 *
 * A PROOF whose `head_sha` is missing can never be found stale — `checkQualityGateStaleness`
 * returns `checked: false` for it forever. So a record written while HEAD lookup timed out is a
 * record with no binding at all, and writing it silently is the very defect this guards. Timeouts
 * refuse the write; a genuinely non-git directory still records without a binding (fail-open).
 *
 * @param {string} worktreePath
 * @param {string} branch
 * @param {object} record — User/AI provided record (branch/recorded_at/head_sha are stamped)
 * @param {(worktreePath: string) => string} [execFn] — Test-injectable HEAD resolver
 * @returns {{ ok: boolean, path?: string, errors?: string[], headSha?: string|null }}
 */
export function recordQualityGate(worktreePath, branch, record, execFn = undefined) {
  const { sha: headSha, timedOut } = execFn
    ? resolveHeadShaResult(worktreePath, execFn)
    : resolveHeadShaResult(worktreePath);
  if (!headSha && timedOut) {
    return {
      ok: false,
      errors: [
        'git HEAD lookup timed out, so this PROOF would carry no head_sha and could never be ' +
          'detected as stale. Re-run once the machine is less loaded.',
      ],
    };
  }
  const stamped = {
    ...record,
    gates: Array.isArray(record?.gates)
      ? record.gates.map((g) => (g && typeof g === 'object' && !Array.isArray(g) ? { ...g } : g))
      : record?.gates,
    branch,
    recorded_at: new Date().toISOString(),
  };
  if (headSha) {
    stamped.head_sha = headSha;
  } else {
    delete stamped.head_sha;
  }
  const { ok, errors } = validateQualityGateRecord(stamped, { rejectUnknownKeys: true });
  if (!ok) return { ok: false, errors };
  const path = resolveWorktreeQualityGatePath(worktreePath, branch);
  writeJsonAtomicSync(path, stamped);
  return { ok: true, path, headSha };
}

function fail(message) {
  process.stderr.write(`[record-quality-gate] ${message}\n`);
  process.exit(1);
}

function parseCliRecord(args) {
  const jsonIdx = args.indexOf('--json');
  const fromIdx = args.indexOf('--from');
  if (jsonIdx >= 0 && fromIdx >= 0) fail('--json and --from cannot be used simultaneously');
  let raw = null;
  let label = null;
  if (jsonIdx >= 0) {
    raw = args[jsonIdx + 1];
    label = '--json';
    if (!raw) fail('Record JSON string required after --json');
  } else if (fromIdx >= 0) {
    const filePath = args[fromIdx + 1];
    label = `--from ${filePath}`;
    if (!filePath) fail('Record JSON file path required after --from');
    try {
      raw = readFileSync(filePath, 'utf-8');
    } catch (e) {
      fail(`--from file read failed: ${e.message}`);
    }
  } else {
    fail(USAGE.trim());
  }
  if (raw === null || raw === undefined) return null;
  try {
    return JSON.parse(raw);
  } catch (e) {
    fail(`${label} JSON parse failed: ${e.message}`);
  }
  return null;
}

function main(argv) {
  const args = argv.slice(2);
  const target = args[0];
  if (!target) fail(USAGE.trim());
  if (target === '--staged' || target === 'staged') {
    fail('--staged (ship-feature) mode is not a PROOF record target — PROOF is only recorded on real worktrees');
  }
  if (target.startsWith('--')) fail(USAGE.trim());

  const mainRoot = resolveMainRoot();
  if (!mainRoot) fail('git common-dir resolve failed (not a git repo?)');

  const branch = resolveBranch(target);
  if (!branch) fail(`branch resolve failed: ${target}`);

  const worktreePath = resolveWorktreeDir(mainRoot, branch);
  if (!worktreePath) {
    fail(`worktree does not exist: .worktrees/${branch} — PROOF is only recorded on real worktrees`);
  }

  const record = parseCliRecord(args);
  const result = recordQualityGate(worktreePath, branch, record);
  if (!result.ok) {
    // A HEAD-lookup timeout is not a schema violation — labelling it as one sends the reader to
    // rewrite a record that was already valid.
    const isTimeout = result.errors?.some((e) => e.includes('timed out'));
    fail(
      isTimeout
        ? `${result.errors.join('\n  - ')}`
        : `Schema violation:\n  - ${result.errors.join('\n  - ')}`,
    );
  }
  const verdict = record.verdict;
  process.stdout.write(`${result.path}\n`);
  process.stderr.write(
    `[record-quality-gate] verdict=${verdict} gates=${record.gates.length} successfully recorded` +
      (verdict === 'no_go' ? ' — mark-pre-ship-confirmed will reject marker creation (fix → re-run verdict → re-record)' : '') +
      '\n',
  );
  if (!result.headSha) {
    process.stderr.write(
      '[record-quality-gate] warning: failed to resolve worktree HEAD sha — head_sha not recorded, staleness detection disabled\n',
    );
  }
}

if (isMainModule(import.meta.url, process.argv[1])) {
  main(process.argv);
}
