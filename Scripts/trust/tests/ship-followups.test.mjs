/**
 * A Japanese approval in the words of the offered choice is read as approval.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { normalizeApproval } from '../../../.cli/lib/approval-vocabulary.mjs';

test('承認して進める approves; anything added to it does not', () => {
  for (const yes of ['承認して進める', '承認して進めて', '承認して進めてください', '承認して。']) {
    assert.equal(normalizeApproval(yes), 'approve', yes);
  }
  for (const no of ['承認して進める?', '承認して進めないで', '承認して進めるがテスト追加']) {
    assert.notEqual(normalizeApproval(no), 'approve', no);
  }
});
