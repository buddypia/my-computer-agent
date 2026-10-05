#!/usr/bin/env node
/**
 * trunk-ref-guard.mjs — git reference-transaction hook 진입점 (shim 이 prepared 단계에서 호출)
 *
 * 근거 · 불변식 · 한계 · 설치 방식: `.cli/lib/trunk-ref-guard.mjs` 머리 주석.
 * stdin 은 `<old> <new> <ref>` 줄이다. 0 이 아닌 종료 코드가 ref 갱신 전체를 abort 한다.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname } from 'node:path';

import { loadWorktreePolicy } from '../../.cli/lib/trunk-branch.mjs';
import { isCreatePrLeaseActive } from '../../.cli/lib/create-pr-lease.mjs';
import {
  findTrunkViolations,
  formatDenial,
  makeIsPublished,
  makeIsUnmoved,
  parseRefUpdates,
} from '../../.cli/lib/trunk-ref-guard.mjs';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();

function isAncestor(oid, ref) {
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', oid, ref], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function main() {
  if (!process.env.CLAUDECODE) return 0;
  const updates = parseRefUpdates(readFileSync(0, 'utf8'));
  // lease 와 policy 는 main checkout 에 산다 — linked worktree 에서도 같은 곳을 본다.
  const commonDir = git('rev-parse', '--path-format=absolute', '--git-common-dir');
  const projectDir = dirname(commonDir);
  const violations = findTrunkViolations({
    updates,
    policy: loadWorktreePolicy(projectDir),
    leaseActive: isCreatePrLeaseActive(projectDir),
    isPublished: makeIsPublished({ updates, isAncestor }),
    isUnmoved: makeIsUnmoved(commonDir),
  });
  if (violations.length === 0) return 0;
  process.stderr.write(formatDenial(violations));
  return 1;
}

// 저장소를 읽지 못하면 판정 불능 — 닫되 stack trace 대신 이유를 한 줄로 말한다 (trunk-commit-backstop 과 같은 이유).
try {
  process.exitCode = main();
} catch (err) {
  process.stderr.write(`[trunk-ref-guard] 저장소 상태를 읽지 못해 ref 갱신을 거부했다 (${String(err.message).split('\n')[0]}).\n`);
  process.exitCode = 1;
}
