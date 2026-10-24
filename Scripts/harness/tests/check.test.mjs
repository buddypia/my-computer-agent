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

import { ALWAYS_ON_MAX, EXPERIENCE_REL, HINTS_REL, checkHarness } from '../check.mjs';

// Imported without this flag, a hook runs its standalone entry and waits on stdin.
globalThis.__HOOK_ORCHESTRATOR__ = true;
const { readsHeldout } = await import('../../../.cli/hooks/heldout-guard.mjs');
const { findRoot, isHarnessPath, run: lintRun } = await import('../../../.cli/hooks/harness-lint-guard.mjs');
const { loadHints, matchHints, run: hintRun } = await import('../../../.cli/hooks/error-hint.mjs');
const { runModulesBatch } = await import('../../../.cli/_cli-dispatch.mjs');
const { runWorktreeNew } = await import('../../../.claude/scripts/worktree-new.mjs');
const {
  findOverlappingWorktrees,
  hasVerificationStamp,
  removeWorktreeSnapshot,
  resolveCommonRepoRoot,
  resolveGitDirsPure,
  updateWorktreeSnapshot,
  writeVerificationStamp,
} = await import('../../../.cli/lib/agent-scratchpad.mjs');

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
  for (const rel of ['.claude/agents/scout.md', '.cli/hooks/error-hints.json', 'data/harness/experience.json']) {
    assert.equal(isHarnessPath(rel), true, rel);
  }
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
  // A session's project dir (main) must not replace the cwd the patch paths are relative to.
  const saved = process.env.CLAUDE_PROJECT_DIR;
  process.env.CLAUDE_PROJECT_DIR = scratch;
  try {
    const fromWorktree = await lintRun({ tool_name: 'Edit', tool_input: { command: patch }, cwd: root });
    assert.equal(fromWorktree.decision, 'block');
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR;
    else process.env.CLAUDE_PROJECT_DIR = saved;
  }
});

test('harness-lint-guard finds the nearest checkout, a linked worktree included, without spawning git', () => {
  const root = tree();
  mkdirSync(join(root, '.git'));
  const wt = join(root, '.worktrees/feature/x');
  write(wt, '.git', 'gitdir: ../../../.git/worktrees/x\n');
  mkdirSync(join(wt, '.agents/skills'), { recursive: true });
  assert.equal(findRoot(join(wt, '.agents/skills')), wt);
  assert.equal(findRoot(join(root, '.agents/skills/alpha')), root);
});

test('the repository keeps ripgrep out of the heldout split', () => {
  const ignore = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../../.ignore'), 'utf8');
  assert.match(ignore, /^Evals\/system-one\/heldout\.jsonl$/m);
});

test('a subagent without name or description fails', () => {
  const root = tree();
  write(root, '.claude/agents/scout.md', '---\nname: scout\ndescription: reads logs, returns a table\n---\n');
  assert.deepEqual(errors(root), []);
  assert.equal(checkHarness(root).census.subagents, 1);
  write(root, '.claude/agents/scout.md', '---\nname: scout\n---\n');
  assert.match(errors(root).join('\n'), /scout\.md needs `description:`/);
});

test('a prose line repeated verbatim in AGENTS.md and a skill fails; short lines and code do not', () => {
  const root = tree();
  const rule = 'Run the gate before ending a turn that touched code.';
  write(root, '.agents/skills/alpha/SKILL.md', `${skill('alpha')}\n- ok\n\n\`\`\`\n${rule}\n\`\`\`\n`);
  write(root, 'AGENTS.md', `# AGENTS.md\n\n${rule}\n\n- ok\n\n${trigger('alpha')}`);
  assert.deepEqual(errors(root), [], 'a fenced copy and a short line are not instructions');
  write(root, '.agents/skills/alpha/SKILL.md', `${skill('alpha')}\n1. ${rule}\n`);
  assert.match(errors(root).join('\n'), /alpha\/SKILL\.md repeats an AGENTS\.md line verbatim/);
});

test('a script under a skill directory named by its SKILL.md must exist', () => {
  const root = tree();
  write(root, '.agents/skills/alpha/SKILL.md', `${skill('alpha')}\nRun \`node .agents/skills/alpha/scripts/x.mjs\`.\n`);
  assert.match(errors(root).join('\n'), /invokes `\.agents\/skills\/alpha\/scripts\/x\.mjs` but that file does not exist/);
  write(root, '.agents/skills/alpha/scripts/x.mjs', '');
  assert.deepEqual(errors(root), []);
  write(root, 'AGENTS.md', `${readFileSync(join(root, 'AGENTS.md'), 'utf8')}Table: .cli/hooks/table.json\n`);
  assert.deepEqual(errors(root), [], 'a .json file is not a .js script');
});

const hint = (over = {}) => ({ id: 'h', signature: 'boom \\d+', hint: 'do x', evidence: 'seen 3 times', ...over });

test('an error hint needs a compiling signature, a hint and evidence of recurrence', () => {
  const root = tree();
  write(root, HINTS_REL, JSON.stringify({ hints: [hint()] }));
  assert.deepEqual(errors(root), []);
  write(root, HINTS_REL, JSON.stringify({ hints: [hint({ signature: '(' }), hint({ id: 'h' }), hint({ id: 'e', evidence: '' })] }));
  const out = errors(root).join('\n');
  assert.match(out, /`signature` must be a non-empty regular expression/);
  assert.match(out, /duplicate id/);
  assert.match(out, /\(e\) needs `evidence`/);
});

test('the hint table and the ledger may be absent, but not while the hook or skill that reads them exists', () => {
  const root = tree();
  assert.deepEqual(errors(root), []);
  write(root, '.cli/hooks/error-hint.mjs', '');
  write(root, '.agents/skills/harness-design/SKILL.md', skill('harness-design'));
  write(root, 'AGENTS.md', `# AGENTS.md\n\n## スキル\n\n${trigger('alpha')}${trigger('harness-design')}`);
  const out = errors(root).join('\n');
  assert.match(out, new RegExp(`${HINTS_REL} is missing but \\.cli/hooks/error-hint\\.mjs reads it`));
  assert.match(out, new RegExp(`${EXPERIENCE_REL} is missing but \\.agents/skills/harness-design/SKILL\\.md reads it`));
});

test('error-hint appends the hint whose signature is in the output, on success or failure', async () => {
  const hints = loadHints();
  assert.ok(hints.length > 0);
  const eza = { tool_name: 'Bash', tool_response: { stderr: "error: invalid value '/x' for '--time <FIELD>'" } };
  assert.deepEqual(matchHints(eza, hints).map((h) => h.id), ['eza-ls-time']);
  assert.deepEqual(matchHints({ tool_name: 'Bash', tool_response: { stdout: 'ok' } }, hints), []);
  const fail = await hintRun({ hook_event_name: 'PostToolUseFailure', error: eza.tool_response.stderr });
  assert.equal(fail.hookSpecificOutput.hookEventName, 'PostToolUseFailure');
  assert.match(fail.hookSpecificOutput.additionalContext, /^\[error-hint:eza-ls-time\] .*command ls -t/);
  assert.deepEqual(await hintRun({ tool_response: 'fine' }), {});
});

const row = (verdict, component = 'AGENTS.md') => ({ component, change: 'c', observed: 'o', verdict });
const entry = (over = {}) => ({ id: 'HX-001', at: '2026-10-18', change: '#1', edits: [row('helped')], lesson: null, ...over });
const lesson = (over = {}) => ({ cue: 'when x', lesson: 'in AGENTS.md, do y', evidence: [1], confidence: 'medium', ...over });

test('the experience ledger checks verdicts, and a lesson must cite a helped or hurt row and name its component', () => {
  const root = tree();
  const put = (entries) => write(root, EXPERIENCE_REL, JSON.stringify({ entries }));
  put([entry({ lesson: lesson() })]);
  assert.deepEqual(errors(root), []);
  assert.equal(checkHarness(root).census.experience_lessons, 1);

  put([entry({ edits: [row('worked')] })]);
  assert.match(errors(root).join('\n'), /`verdict` must be one of helped \/ hurt \/ no observed effect \/ confounded/);
  put([entry({ edits: [row('confounded'), row('no observed effect')], lesson: lesson({ evidence: [1, 2] }) })]);
  assert.match(errors(root).join('\n'), /rests only on confounded \/ no-observed-effect rows/);
  put([entry({ lesson: lesson({ evidence: [2] }) })]);
  assert.match(errors(root).join('\n'), /`evidence` must list the 1-based numbers/);
  put([entry({ lesson: lesson({ lesson: 'do y' }) })]);
  assert.match(errors(root).join('\n'), /must name the component it concerns \(one of: AGENTS\.md\)/);
  put([entry(), entry({ at: '18 Oct', lesson: lesson({ confidence: 'sure' }) })]);
  const out = errors(root).join('\n');
  assert.match(out, /duplicate id/);
  assert.match(out, /`at` must be YYYY-MM-DD/);
  assert.match(out, /`confidence` must start with high \/ medium \/ low/);
});

test('--base reports the always-on character delta against a git ref', () => {
  const root = tree();
  const git = (...a) => execFileSync('git', ['-C', root, ...a], { stdio: 'ignore' });
  git('init', '-q');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'empty');
  git('add', '-A');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'base');
  write(root, 'AGENTS.md', `${readFileSync(join(root, 'AGENTS.md'), 'utf8')}12345`);
  assert.equal(checkHarness(root, { base: 'HEAD' }).census.always_on_char_delta, 5);
  assert.match(checkHarness(root, { base: 'HEAD~1' }).errors.join('\n'), /could not be read at that ref/);
});

test('this repository\'s harness passes its own check', () => {
  const repo = join(dirname(fileURLToPath(import.meta.url)), '../../..');
  assert.deepEqual(checkHarness(repo).errors, []);
});

test('agent-scratchpad resolves common git dirs in pure FS and shares stamps and worktree snapshots', () => {
  const root = tree();
  mkdirSync(join(root, '.git', 'worktrees', 'wt1'), { recursive: true });
  write(root, '.git/config', '[core]\n\trepositoryformatversion = 0\n');
  write(root, '.git/worktrees/wt1/commondir', '../..\n');
  const wt = join(root, '.worktrees/feature/wt1');
  write(wt, '.git', `gitdir: ${join(root, '.git/worktrees/wt1')}\n`);

  const pureMain = resolveGitDirsPure(root);
  assert.equal(pureMain.mainRoot, root);
  assert.equal(pureMain.hasCustomHooksPath, false);
  const pureWt = resolveGitDirsPure(wt);
  assert.equal(pureWt.mainRoot, root);
  assert.equal(resolveCommonRepoRoot(wt), root);

  const hash = 'a'.repeat(40);
  assert.equal(hasVerificationStamp(wt, 'harness', hash), false);
  assert.equal(writeVerificationStamp(root, 'harness', hash), true);
  assert.equal(hasVerificationStamp(wt, 'harness', hash), true, 'worktree sees stamp written on main');

  updateWorktreeSnapshot(wt, 'feature/wt1', { worktree_path: wt, changed_files: ['Sources/A.swift', 'README.md'] });
  const wt2 = join(root, '.worktrees/feature/wt2');
  mkdirSync(wt2, { recursive: true });
  updateWorktreeSnapshot(wt2, 'feature/wt2', { worktree_path: wt2, changed_files: ['Sources/A.swift'] });
  const overlaps = findOverlappingWorktrees(root, 'feature/wt1', ['Sources/A.swift', 'README.md']);
  assert.equal(overlaps.length, 1);
  assert.equal(overlaps[0].branch, 'feature/wt2');
  assert.deepEqual(overlaps[0].overlapping_files, ['Sources/A.swift']);

  removeWorktreeSnapshot(root, 'feature/wt2');
  assert.deepEqual(findOverlappingWorktrees(root, 'feature/wt1', ['Sources/A.swift']), []);
});

test('_cli-dispatch runModulesBatch runs multiple hooks in-process and short-circuits on deny', async () => {
  const root = tree();
  write(root, '.cli/hooks/allow1.mjs', 'export async function run() { return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "w1" } }; }\n');
  write(root, '.cli/hooks/allow2.mjs', 'export async function run() { return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "w2" } }; }\n');
  write(root, '.cli/hooks/deny1.mjs', 'export async function run() { return { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "stop" } }; }\n');

  const merged = await runModulesBatch([join(root, '.cli/hooks/allow1.mjs'), join(root, '.cli/hooks/allow2.mjs')], {});
  assert.equal(merged.hookSpecificOutput.permissionDecision, 'allow');
  assert.equal(merged.hookSpecificOutput.permissionDecisionReason, 'w1\n\nw2');

  const denied = await runModulesBatch([join(root, '.cli/hooks/allow1.mjs'), join(root, '.cli/hooks/deny1.mjs'), join(root, '.cli/hooks/allow2.mjs')], {});
  assert.equal(denied.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(denied.hookSpecificOutput.permissionDecisionReason, 'stop');
});

test('runWorktreeNew succeeds in non-dry-run mode and records the worktree snapshot without throwing', () => {
  const root = tree();
  const git = (...a) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('add', '-A');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'init');

  const res = runWorktreeNew({
    branch: 'feature/test-wt-non-dry',
    base: 'main',
    dryRun: false,
    cwd: root,
    existsFn: () => false,
  });
  assert.equal(res.ok, true, JSON.stringify(res.errors));
  assert.ok(res.base_sha);
});
