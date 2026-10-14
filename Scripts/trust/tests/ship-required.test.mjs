/**
 * Which checks a ship merge must see by name. Only GitHub's "none configured" (404) means none; any
 * other failure must stop the merge instead of falling back to "whatever is green".
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

const { requiredChecks } = await import('../../../.claude/scripts/create-pr/ops.mjs');

const failing = (stderr) => () => {
  const e = new Error(`gh failed: ${stderr}`);
  e.stderr = stderr;
  throw e;
};

test('the protection contexts become the required check names', () => {
  const ghFn = () => 'Build & Test (macOS)\nSecret Scan\n';
  assert.deepEqual(requiredChecks('o/r', 'main', { ghFn }), ['Build & Test (macOS)', 'Secret Scan']);
});

test('no protection (404) requires nothing', () => {
  assert.deepEqual(requiredChecks('o/r', 'main', { ghFn: failing('gh: Branch not protected (HTTP 404)') }), []);
});

test('any other failure stops instead of requiring nothing', () => {
  assert.throws(() => requiredChecks('o/r', 'main', { ghFn: failing('gh: Resource not accessible (HTTP 403)') }), /403/);
  assert.throws(() => requiredChecks('o/r', 'main', { ghFn: failing('error connecting to api.github.com') }), /connecting/);
});
