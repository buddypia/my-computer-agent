/**
 * Scripts/harness/check.mjs and the two hooks built on the same rules, against scratch harness trees.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { ALWAYS_ON_MAX, checkHarness } from '../check.mjs';

// Imported without this flag, a hook runs its standalone entry and waits on stdin.
globalThis.__HOOK_ORCHESTRATOR__ = true;
const { readsHeldout } = await import('../../../.cli/hooks/heldout-guard.mjs');
const { isHarnessPath, run: lintRun } = await import('../../../.cli/hooks/harness-lint-guard.mjs');

let scratch;
let n = 0;

const write = (root, rel, body) => {
  mkdirSync(dirname(join(root, rel)), { recursive: true });
  writeFileSync(join(root, rel), body);
};
const skill = (name, extra = '') => `---\n${extra}description: does ${name}\n---\n\n# ${name}\n`;
const trigger = (name) => `- When it applies, read .agents/skills/${name}/SKILL.md and follow it.\n`;

/** A valid harness: AGENTS.md with one triggered skill, CLAUDE.md as a symlink, a Codex hooks file. */
const tree = () => {
  const root = join(scratch, `t${n++}`);
  write(root, 'AGENTS.md', `# AGENTS.md\n\n## スキル\n\n${trigger('alpha')}`);
  symlinkSync('AGENTS.md', join(root, 'CLAUDE.md'));
  write(root, '.agents/skills/alpha/SKILL.md', skill('alpha'));
  write(root, '.cli/hooks/g.mjs', '');
  write(root, '.codex/hooks.json', JSON.stringify({
    hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'node .cli/hooks/g.mjs' }] }] },
  }));
  return root;
};
const errors = (root) => checkHarness(root).errors;

before(() => { scratch = realpathSync(mkdtempSync(join(tmpdir(), 'harness-check-'))); });
after(() => rmSync(scratch, { recursive: true, force: true }));

test('a valid harness passes and is counted', () => {
  const r = checkHarness(tree());
  assert.deepEqual(r.errors, []);
  assert.equal(r.census.skills, 1);
  assert.equal(r.census.hook_commands, 1);
});

test('AGENTS.md over the cap fails, counted in characters rather than bytes', () => {
  const root = tree();
  write(root, 'AGENTS.md', trigger('alpha') + 'あ'.repeat(ALWAYS_ON_MAX - 200));
  assert.deepEqual(errors(root), [], 'multi-byte text under the cap in characters must pass');
  write(root, 'AGENTS.md', trigger('alpha') + 'x'.repeat(ALWAYS_ON_MAX));
  assert.match(errors(root).join('\n'), /over the 8000 cap/);
});

test('an empty or missing AGENTS.md fails', () => {
  const root = tree();
  write(root, 'AGENTS.md', '  \n');
  assert.match(errors(root).join('\n'), /AGENTS\.md is empty/);
  rmSync(join(root, 'AGENTS.md'));
  assert.match(errors(root).join('\n'), /AGENTS\.md is missing/);
});

test('a skill without a trigger line naming its SKILL.md path fails', () => {
  const root = tree();
  write(root, '.agents/skills/beta/SKILL.md', skill('beta'));
  assert.match(errors(root).join('\n'), /skill 'beta' has no trigger line/);
  // The bare name is not a trigger: the agent needs the path it is told to read.
  write(root, 'AGENTS.md', `${trigger('alpha')}Use beta when needed.\n`);
  assert.match(errors(root).join('\n'), /skill 'beta' has no trigger line/);
  write(root, 'AGENTS.md', `${trigger('alpha')}See .agents/skills/beta/SKILL.md for details.\n`);
  assert.match(errors(root).join('\n'), /skill 'beta' has no trigger line/);
  write(root, 'AGENTS.md', trigger('alpha') + trigger('beta'));
  assert.deepEqual(errors(root), []);
});

test('a skill frontmatter without description, or with a name that differs from its directory, fails', () => {
  const root = tree();
  write(root, '.agents/skills/alpha/SKILL.md', '---\nname: alpha\n---\n');
  assert.match(errors(root).join('\n'), /needs a `description:`/);
  write(root, '.agents/skills/alpha/SKILL.md', skill('alpha', 'name: other\n'));
  assert.match(errors(root).join('\n'), /OVERRIDES the directory name/);
  write(root, '.agents/skills/alpha/SKILL.md', skill('alpha', 'name: "alpha"\n'));
  assert.deepEqual(errors(root), []);
});

test('CLAUDE.md that duplicates AGENTS.md fails; a symlink or `@AGENTS.md` passes', () => {
  const root = tree();
  rmSync(join(root, 'CLAUDE.md'));
  write(root, 'CLAUDE.md', '# copy of the rules\n');
  assert.match(errors(root).join('\n'), /CLAUDE\.md must be a symlink/);
  write(root, 'CLAUDE.md', '@AGENTS.md\n');
  assert.deepEqual(errors(root), []);
});

test('a malformed hooks file fails with the reason it would never fire', () => {
  const root = tree();
  const hooks = (h) => write(root, '.codex/hooks.json', JSON.stringify({ hooks: h }));
  write(root, '.codex/hooks.json', '{ not json');
  assert.match(errors(root).join('\n'), /not valid JSON/);
  hooks({ preToolUse: [] });
  assert.match(errors(root).join('\n'), /unknown event "preToolUse"/);
  hooks({ PreToolUse: { matcher: 'Bash' } });
  assert.match(errors(root).join('\n'), /must map to a LIST/);
  hooks({ PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'prompt', prompt: 'x' }] }] });
  assert.match(errors(root).join('\n'), /hook type "prompt" is not run here/);
  hooks({ PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: ' ' }] }] });
  assert.match(errors(root).join('\n'), /empty `command`/);
});

test('a script named by AGENTS.md, a skill or a hook command must exist', () => {
  const root = tree();
  write(root, 'AGENTS.md', `${trigger('alpha')}Run \`Scripts/missing.sh\`.\n`);
  assert.match(errors(root).join('\n'), /AGENTS\.md invokes `Scripts\/missing\.sh`/);
  write(root, 'AGENTS.md', trigger('alpha'));
  write(root, '.agents/skills/alpha/SKILL.md', `${skill('alpha')}node .claude/scripts/gone.mjs <arg>\n`);
  assert.match(errors(root).join('\n'), /alpha\/SKILL\.md invokes `\.claude\/scripts\/gone\.mjs`/);
  write(root, '.agents/skills/alpha/SKILL.md', skill('alpha'));
  write(root, '.claude/settings.json', JSON.stringify({
    hooks: { Stop: [{ hooks: [{ type: 'command', command: 'node "${CLAUDE_PROJECT_DIR}/.cli/hooks/nope.mjs"' }] }] },
  }));
  assert.match(errors(root).join('\n'), /invokes `\.cli\/hooks\/nope\.mjs`/);
});

test('heldout-guard denies reading the heldout split and allows scoring and staging it', () => {
  const heldout = 'Evals/system-one/heldout.jsonl';
  assert.equal(readsHeldout('Read', { file_path: `/repo/${heldout}` }), true);
  assert.equal(readsHeldout('Read', { file_path: '/repo/Evals/system-one/train.jsonl' }), false);
  assert.equal(readsHeldout('Read', { AbsolutePath: `/repo/${heldout}` }), true, 'Antigravity names the path differently');
  assert.equal(readsHeldout('Grep', { pattern: 'route', path: heldout }), true);
  assert.equal(readsHeldout('Grep', { pattern: 'route', path: 'Evals/system-one' }), false, '.ignore keeps ripgrep out');
  assert.equal(readsHeldout('Bash', { command: `head -5 ${heldout}` }), true);
  assert.equal(readsHeldout('Bash', { command: 'cd Evals/system-one && cat heldout.jsonl' }), true);
  assert.equal(readsHeldout('Bash', { command: 'grep -rn route Evals/' }), true);
  assert.equal(readsHeldout('Bash', { command: 'ls Evals/system-one' }), false);
  assert.equal(readsHeldout('Bash', { command: `wc -l ${heldout}` }), false);
  assert.equal(readsHeldout('Bash', { command: `git -C /repo add ${heldout}` }), false);
  assert.equal(readsHeldout('Bash', { command: 'cat Evals/system-one/*.jsonl' }), true);
  assert.equal(readsHeldout('Bash', { command: `git status && jq . ${heldout} | head` }), true);
  assert.equal(readsHeldout('Bash', { command: 'node Scripts/eval/hillclimb.mjs run' }), false);
  assert.equal(readsHeldout('Bash', { command: `git add ${heldout} && git commit -m split` }), false);
});

test('harness-lint-guard blocks an edit that leaves the harness invalid, and ignores other files', async () => {
  assert.equal(isHarnessPath('AGENTS.md'), true);
  assert.equal(isHarnessPath('.agents/skills/x/SKILL.md'), true);
  assert.equal(isHarnessPath('Sources/A.swift'), false);

  const root = tree();
  execFileSync('git', ['-C', root, 'init', '-q']);
  const edit = (rel) => lintRun({ tool_name: 'Write', tool_input: { file_path: join(root, rel) }, cwd: root });
  assert.deepEqual(await edit('AGENTS.md'), {});
  write(root, '.agents/skills/beta/SKILL.md', skill('beta'));
  const r = await edit('.agents/skills/beta/SKILL.md');
  assert.equal(r.decision, 'block');
  assert.match(r.reason, /skill 'beta' has no trigger line/);
  write(root, 'Sources/A.swift', '');
  assert.deepEqual(await edit('Sources/A.swift'), {});
  // Codex: the adapter keeps only the patch's first file in file_path; the second must still be checked.
  const patch = '*** Begin Patch\n*** Update File: Sources/A.swift\n*** Update File: .agents/skills/beta/SKILL.md\n*** End Patch\n';
  const codex = await lintRun({ tool_name: 'Edit', tool_input: { file_path: join(root, 'Sources/A.swift'), command: patch }, cwd: root });
  assert.equal(codex.decision, 'block');
});

test('the repository keeps ripgrep out of the heldout split', () => {
  const ignore = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../../.ignore'), 'utf8');
  assert.match(ignore, /^Evals\/system-one\/heldout\.jsonl$/m);
});
