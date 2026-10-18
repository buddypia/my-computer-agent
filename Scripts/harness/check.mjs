#!/usr/bin/env node
// Scripts/harness/check.mjs — validate the agent harness (AGENTS.md, skills, hooks) mechanically.
//
// The rules come from Google Research's harness2 (harness2/core/tree.py#validate and the Codex surface in
// harness2/core/prompts.py), where a harness that breaks one of them is discarded before any rollout:
//   - AGENTS.md is the only always-on text. Every character of it competes with the agent's own output
//     budget on every turn, so it is capped (8,000 characters for Codex) and must not be empty.
//   - a skill is only opened when AGENTS.md names it, so every .agents/skills/<name>/SKILL.md needs a
//     trigger line naming `.agents/skills/<name>/SKILL.md`, a `description:`, and no `name:` that differs
//     from its directory (it overrides the directory and the trigger stops matching).
//   - a hooks file that is malformed never fires rather than erroring, so its shape is checked here.
//   - every script AGENTS.md, a skill or a hook invokes must exist.
// CLAUDE.md must stay a pointer to AGENTS.md (a symlink or the single line `@AGENTS.md`), so the same
// instruction is never kept in two places.
//
// Usage:
//   node Scripts/harness/check.mjs [--root <dir>] [--json]
// Exit codes: 0 valid, 1 one or more problems (listed on stdout).

import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ALWAYS_ON_MAX = 8_000;

const CLAUDE_EVENTS = new Set([
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SubagentStart', 'SubagentStop',
  'SessionStart', 'SessionEnd', 'PreCompact', 'UserPromptSubmit', 'Notification', 'PermissionRequest',
  'TaskCreated', 'TaskCompleted', 'FileChanged', 'ConfigChange', 'WorktreeCreate', 'WorktreeRemove',
]);
const CLAUDE_HOOK_TYPES = new Set(['command', 'prompt', 'agent', 'http']);

// Each hooks file, the events its framework dispatches, and the hook types it runs. Codex runs only
// "command" hooks; anything else is skipped as "not supported yet".
const HOOK_FILES = [
  { rel: '.claude/settings.json', events: CLAUDE_EVENTS, types: CLAUDE_HOOK_TYPES, groups: false },
  { rel: '.codex/hooks.json', events: new Set(['PreToolUse', 'PostToolUse', 'SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop', 'PermissionRequest']), types: new Set(['command']), groups: false },
  // Antigravity: { "<group>": { "enabled": bool, "<Event>": [...] } }
  { rel: '.agents/hooks.json', events: new Set(['PreToolUse', 'PostToolUse', 'SessionStart', 'UserPromptSubmit', 'Stop']), types: new Set(['command']), groups: true },
];

// A repository script named in always-on text, a skill, or a hook command. Placeholders and globs
// (`<name>`, `*`) are not concrete paths and are skipped.
const SCRIPT_REF = /(?<![\w.-]|[\w.-]\/)((?:Scripts|\.claude\/scripts|\.claude\/hooks|\.cli)\/[\w./-]+\.(?:mjs|js|sh|py))/g;

const chars = (s) => [...s].length;

function skillNames(root) {
  const dir = join(root, '.agents/skills');
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => (e.isDirectory() || e.isSymbolicLink()) && existsSync(join(dir, e.name, 'SKILL.md')))
    .map((e) => e.name)
    .sort();
}

function frontmatter(src) {
  const m = src.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return m ? m[1] : '';
}

function checkAlwaysOn(root, errs) {
  const path = join(root, 'AGENTS.md');
  if (!existsSync(path)) {
    errs.push('AGENTS.md is missing — it is the only always-on file, so a harness without it does not exist');
    return '';
  }
  const body = readFileSync(path, 'utf8');
  if (!body.trim()) errs.push('AGENTS.md is empty — it is the only always-on file, so an empty one is a harness that does not exist');
  const n = chars(body);
  if (n > ALWAYS_ON_MAX) {
    errs.push(
      `AGENTS.md is ${n} chars, over the ${ALWAYS_ON_MAX} cap; every character is in context on every turn and ` +
        'competes with the output budget — move a procedure with a recognisable trigger into a skill, a deterministic ' +
        'step into a script, or an ignored rule into a hook (see .agents/skills/harness-design/SKILL.md)',
    );
  }

  const claude = join(root, 'CLAUDE.md');
  if (existsSync(claude)) {
    const pointsAtAgents = lstatSync(claude).isSymbolicLink()
      ? realpathSync(claude) === realpathSync(path)
      : readFileSync(claude, 'utf8').trim() === '@AGENTS.md';
    if (!pointsAtAgents) errs.push('CLAUDE.md must be a symlink to AGENTS.md or the single line `@AGENTS.md`; keep instructions in AGENTS.md only');
  }
  return body;
}

function checkSkills(root, body, errs) {
  const skills = skillNames(root);
  for (const name of skills) {
    const rel = `.agents/skills/${name}/SKILL.md`;
    const fm = frontmatter(readFileSync(join(root, rel), 'utf8'));
    if (!/^description:\s*\S/m.test(fm)) {
      errs.push(`${rel} needs a \`description:\` in its frontmatter, or the skill is dropped SILENTLY at load`);
    }
    const m = fm.match(/^name:\s*(\S+)\s*$/m);
    if (m && m[1].replace(/^["']|["']$/g, '') !== name) {
      errs.push(
        `${rel} frontmatter \`name: ${m[1]}\` OVERRIDES the directory name at load, so the trigger line naming ` +
          `\`${name}\` stops matching; drop the \`name:\` line or make it \`name: ${name}\``,
      );
    }
    // The trigger is the instruction to read the file, not a mention of its path.
    if (!new RegExp(`\\bread\\s+\`?${rel.replace(/[.]/g, '\\.')}\\b`).test(body)) {
      errs.push(
        `skill '${name}' has no trigger line in AGENTS.md, so the agent will never open it. Add one line under ` +
          `"## スキル": - When <the situation it handles>, read ${rel} and follow it.`,
      );
    }
  }
  return skills;
}

function checkHookEntries(rel, event, entries, spec, errs) {
  if (!spec.events.has(event)) {
    errs.push(`${rel}: unknown event ${JSON.stringify(event)}; the framework dispatches ${[...spec.events].sort().join(', ')} (PascalCase)`);
    return [];
  }
  if (!Array.isArray(entries)) {
    errs.push(`${rel}: ${event} must map to a LIST of matcher entries`);
    return [];
  }
  const commands = [];
  entries.forEach((entry, i) => {
    if (!entry || typeof entry !== 'object' || !Array.isArray(entry.hooks)) {
      errs.push(`${rel}: ${event}[${i}] needs a \`hooks\` list`);
      return;
    }
    for (const h of entry.hooks) {
      const type = h?.type;
      if (!spec.types.has(type)) {
        errs.push(`${rel}: ${event}[${i}] hook type ${JSON.stringify(type)} is not run here; use ${[...spec.types].join(' / ')}`);
      } else if (type === 'command') {
        if (!String(h.command ?? '').trim()) errs.push(`${rel}: ${event}[${i}] has an empty \`command\``);
        else commands.push(String(h.command));
      }
    }
  });
  return commands;
}

function checkHooks(root, errs) {
  const commands = [];
  let files = 0;
  for (const spec of HOOK_FILES) {
    const path = join(root, spec.rel);
    if (!existsSync(path)) continue;
    files++;
    let doc;
    try {
      doc = JSON.parse(readFileSync(path, 'utf8'));
    } catch (exc) {
      errs.push(`${spec.rel} is not valid JSON: ${exc.message}`);
      continue;
    }
    if (spec.groups) {
      for (const [group, cfg] of Object.entries(doc ?? {})) {
        if (!cfg || typeof cfg !== 'object') {
          errs.push(`${spec.rel}: group ${JSON.stringify(group)} must be an object`);
          continue;
        }
        for (const [event, entries] of Object.entries(cfg)) {
          if (event === 'enabled') continue;
          commands.push(...checkHookEntries(spec.rel, event, entries, spec, errs));
        }
      }
      continue;
    }
    const hooks = doc?.hooks;
    if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) {
      if (spec.rel !== '.claude/settings.json') errs.push(`${spec.rel} needs a top-level {"hooks": {"<Event>": [...]}} object`);
      continue;
    }
    for (const [event, entries] of Object.entries(hooks)) {
      commands.push(...checkHookEntries(spec.rel, event, entries, spec, errs));
    }
  }
  return { commands, files };
}

function checkScriptRefs(root, sources, errs) {
  for (const [rel, src] of sources) {
    // `$CLAUDE_PROJECT_DIR/` and `${CLAUDE_PROJECT_DIR}/` resolve to the repository root.
    for (const [, ref] of src.replace(/\$\{?CLAUDE_PROJECT_DIR\}?\//g, '').matchAll(SCRIPT_REF)) {
      if (!existsSync(join(root, ref))) errs.push(`${rel} invokes \`${ref}\` but that file does not exist`);
    }
  }
}

export function checkHarness(root) {
  const errs = [];
  const body = checkAlwaysOn(root, errs);
  const skills = checkSkills(root, body, errs);
  const { commands, files } = checkHooks(root, errs);
  const sources = [['AGENTS.md', body], ...skills.map((n) => {
    const rel = `.agents/skills/${n}/SKILL.md`;
    return [rel, readFileSync(join(root, rel), 'utf8')];
  }), ...commands.map((c) => ['hooks', c])];
  checkScriptRefs(root, sources, errs);
  return {
    errors: [...new Set(errs)],
    census: { always_on_chars: chars(body), always_on_max: ALWAYS_ON_MAX, skills: skills.length, hook_files: files, hook_commands: commands.length },
  };
}

function main(argv) {
  const at = argv.indexOf('--root');
  const root = resolve(at >= 0 ? argv[at + 1] : join(dirname(fileURLToPath(import.meta.url)), '../..'));
  const { errors, census } = checkHarness(root);
  if (argv.includes('--json')) console.log(JSON.stringify({ ok: errors.length === 0, errors, census }, null, 2));
  else if (errors.length) {
    console.log(`HARNESS FAIL  ${errors.length} problem(s)`);
    for (const e of errors) console.log(`  - ${e}`);
  } else {
    console.log(`HARNESS OK  AGENTS.md ${census.always_on_chars}/${census.always_on_max} chars, ${census.skills} skill(s), ${census.hook_commands} hook command(s)`);
  }
  return errors.length ? 1 : 0;
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  process.exitCode = main(process.argv.slice(2));
}
