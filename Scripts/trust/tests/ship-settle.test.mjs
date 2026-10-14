/**
 * ship merges only after this head's required checks finished: GitHub reports BLOCKED while they run,
 * and a fast workflow going green first must not read as "all checks passed".
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

const { checksVerdict, settleMergeable } = await import('../../../.claude/scripts/create-pr/ops.mjs');

const REQUIRED = ['Build & Test (macOS)'];
const run = (name, conclusion) => ({
  __typename: 'CheckRun', name, startedAt: '2026-10-14T00:00:00Z',
  status: conclusion ? 'COMPLETED' : 'IN_PROGRESS', conclusion: conclusion ?? null,
});

test('a required check that has not reported keeps the verdict pending', () => {
  assert.equal(checksVerdict([run('gitleaks', 'SUCCESS')], REQUIRED).state, 'pending');
  assert.equal(checksVerdict([run('gitleaks', 'SUCCESS'), run(REQUIRED[0], 'SUCCESS')], REQUIRED).state, 'passed');
  assert.equal(checksVerdict([run('gitleaks', 'SUCCESS'), run(REQUIRED[0], 'FAILURE')], REQUIRED).state, 'failed');
});

test("mergeability is read only after the head's checks finish", () => {
  let polls = 0;
  const asked = [];
  const ghFn = (args) => {
    if (args.includes('headRefOid,statusCheckRollup')) {
      polls += 1;
      asked.push('checks');
      return JSON.stringify({ headRefOid: 'H', statusCheckRollup: [run(REQUIRED[0], polls < 3 ? null : 'SUCCESS')] });
    }
    asked.push('mergeable');
    return polls < 3 ? 'BLOCKED' : 'CLEAN'; // GitHub's view while the required check runs
  };
  const result = settleMergeable({
    prNumber: 1, repo: 'o/r', headSha: 'H', ciGated: true, required: REQUIRED, ghFn, sleepFn: () => {},
  });
  assert.deepEqual(result, { mergeable: true, state: 'CLEAN' });
  assert.deepEqual(asked, ['checks', 'checks', 'checks', 'mergeable']);
});

test('a failed required check defers the merge without asking for mergeability', () => {
  const asked = [];
  const ghFn = (args) => {
    asked.push(args.includes('headRefOid,statusCheckRollup') ? 'checks' : 'mergeable');
    return args.includes('headRefOid,statusCheckRollup')
      ? JSON.stringify({ headRefOid: 'H', statusCheckRollup: [run(REQUIRED[0], 'FAILURE')] })
      : 'CLEAN';
  };
  const result = settleMergeable({
    prNumber: 1, repo: 'o/r', headSha: 'H', ciGated: true, required: REQUIRED, ghFn, sleepFn: () => {},
  });
  assert.equal(result.mergeable, false);
  assert.match(result.state, /CHECKS_FAILED/);
  assert.deepEqual(asked, ['checks']);
});
