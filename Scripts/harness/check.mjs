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
//   - a subagent (.claude/agents/*.md) without `name:` and `description:` is never registered.
//   - the same instruction in AGENTS.md and a skill dilutes both ("do not restate what the harness already
//     says"), so a prose line may live in only one of them.
//   - error-hint.mjs's table (.cli/hooks/error-hints.json) holds only errors that recurred, each with a
//     signature that compiles and its recorded `evidence`.
//   - the experience ledger (data/harness/experience.json) records what each harness edit did with a verdict
//     of helped / hurt / no observed effect / confounded, and at most one lesson per entry that cites its
//     rows, names their component and rests on at least one helped or hurt row (harness2 core/prompts.py
//     `experience`: "a lesson resting only on confounded rows is a guess").
// CLAUDE.md must stay a pointer to AGENTS.md (a symlink or the single line `@AGENTS.md`), so the same
// instruction is never kept in two places.
//
// Usage:
//   node Scripts/harness/check.mjs [--root <dir>] [--base <git-ref>] [--json]
//   --base reports how many always-on characters the change adds over <ref> (harness2 diff_summary).
// Exit codes: 0 valid, 1 one or more problems (listed on stdout).

import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
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
const SCRIPT_REF = /(?<![\w.-]|[\w.-]\/)((?:Scripts|\.claude\/scripts|\.claude\/hooks|\.cli|\.agents\/skills\/[\w-]+)\/[\w./-]+\.(?:mjs|js|sh|py))(?![\w])/g;

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

function checkSubagents(root, errs) {
  const dir = join(root, '.claude/agents');
  if (!existsSync(dir)) return 0;
  const files = readdirSync(dir).filter((f) => f.endsWith('.md'));
  for (const f of files) {
    const fm = frontmatter(readFileSync(join(dir, f), 'utf8'));
    for (const key of ['name', 'description']) {
      if (!new RegExp(`^${key}:\\s*\\S`, 'm').test(fm)) {
        errs.push(`.claude/agents/${f} needs \`${key}:\` in its frontmatter, or the subagent is never registered`);
      }
    }
  }
  return files.length;
}

// Prose lines of a Markdown file: no code fences, headings or table rows, list markers stripped, and only
// lines long enough to be an instruction rather than a label.
function proseLines(src) {
  const out = new Set();
  let fence = false;
  for (const raw of src.split('\n')) {
    const s = raw.trim();
    if (s.startsWith('```')) { fence = !fence; continue; }
    if (fence || s.startsWith('#') || s.startsWith('|') || s.startsWith('---')) continue;
    const line = s.replace(/^(?:[-*]|\d+\.)\s+/, '');
    if (chars(line) >= 30) out.add(line);
  }
  return out;
}

function checkDuplicates(body, skillSources, errs) {
  const always = proseLines(body);
  for (const [rel, src] of skillSources) {
    for (const line of proseLines(src)) {
      if (always.has(line)) {
        errs.push(`${rel} repeats an AGENTS.md line verbatim ("${line.slice(0, 60)}…"); keep the instruction in one place — duplicated instruction dilutes the rest`);
      }
    }
  }
}

export const HINTS_REL = '.cli/hooks/error-hints.json';

// `neededBy` is the file that reads `rel`. While it exists, a missing `rel` is an error: the hook or
// skill would silently find nothing, and the count would read 0 instead of failing.
function readJson(root, rel, errs, neededBy) {
  const path = join(root, rel);
  if (!existsSync(path)) {
    if (neededBy && existsSync(join(root, neededBy))) errs.push(`${rel} is missing but ${neededBy} reads it`);
    return null;
  }
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (exc) {
    errs.push(`${rel} is not valid JSON: ${exc.message}`);
    return null;
  }
}

function checkHints(root, errs) {
  const doc = readJson(root, HINTS_REL, errs, '.cli/hooks/error-hint.mjs');
  if (!doc) return 0;
  if (!Array.isArray(doc.hints)) {
    errs.push(`${HINTS_REL} needs a \`hints\` list`);
    return 0;
  }
  const ids = new Set();
  doc.hints.forEach((h, i) => {
    const at = `${HINTS_REL} hints[${i}]${h?.id ? ` (${h.id})` : ''}`;
    if (!String(h?.id ?? '').trim()) errs.push(`${at} needs an \`id\``);
    else if (ids.has(h.id)) errs.push(`${at}: duplicate id`);
    ids.add(h?.id);
    try {
      if (!String(h?.signature ?? '').trim()) throw new Error('empty');
      new RegExp(h.signature);
    } catch (exc) {
      errs.push(`${at}: \`signature\` must be a non-empty regular expression (${exc.message})`);
    }
    if (!String(h?.hint ?? '').trim()) errs.push(`${at} needs a \`hint\``);
    if (!String(h?.evidence ?? '').trim()) {
      errs.push(`${at} needs \`evidence\` that the error recurred across sessions; a hint for a one-off failure is speculation`);
    }
  });
  return doc.hints.length;
}

export const EXPERIENCE_REL = 'data/harness/experience.json';
export const VERDICTS = ['helped', 'hurt', 'no observed effect', 'confounded'];

function checkExperience(root, errs) {
  const doc = readJson(root, EXPERIENCE_REL, errs, '.agents/skills/harness-design/SKILL.md');
  if (!doc) return { entries: 0, lessons: 0 };
  if (!Array.isArray(doc.entries)) {
    errs.push(`${EXPERIENCE_REL} needs an \`entries\` list`);
    return { entries: 0, lessons: 0 };
  }
  const ids = new Set();
  let lessons = 0;
  doc.entries.forEach((e, i) => {
    const at = `${EXPERIENCE_REL} entries[${i}]${e?.id ? ` (${e.id})` : ''}`;
    if (!/^HX-\d{3,}$/.test(String(e?.id ?? ''))) errs.push(`${at}: \`id\` must look like HX-001`);
    else if (ids.has(e.id)) errs.push(`${at}: duplicate id`);
    ids.add(e?.id);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(e?.at ?? ''))) errs.push(`${at}: \`at\` must be YYYY-MM-DD`);
    if (!String(e?.change ?? '').trim()) errs.push(`${at} needs \`change\` (the PR or commit the edits shipped in)`);
    const rows = Array.isArray(e?.edits) ? e.edits : [];
    if (rows.length === 0) errs.push(`${at} needs at least one row in \`edits\``);
    rows.forEach((r, j) => {
      for (const key of ['component', 'change', 'observed']) {
        if (!String(r?.[key] ?? '').trim()) errs.push(`${at} edits[${j}] needs \`${key}\``);
      }
      if (!VERDICTS.includes(r?.verdict)) errs.push(`${at} edits[${j}]: \`verdict\` must be one of ${VERDICTS.join(' / ')}`);
    });
    const l = e?.lesson;
    if (l === null || l === undefined) return;
    lessons++;
    for (const key of ['cue', 'lesson']) {
      if (!String(l?.[key] ?? '').trim()) errs.push(`${at} lesson needs \`${key}\``);
    }
    if (!/^(?:high|medium|low)\b/.test(String(l?.confidence ?? ''))) errs.push(`${at} lesson: \`confidence\` must start with high / medium / low`);
    const cited = Array.isArray(l?.evidence) ? l.evidence : [];
    const bad = cited.filter((n) => !Number.isInteger(n) || n < 1 || n > rows.length);
    if (cited.length === 0 || bad.length) {
      errs.push(`${at} lesson: \`evidence\` must list the 1-based numbers of the edits rows it rests on`);
      return;
    }
    const used = cited.map((n) => rows[n - 1]);
    if (!used.some((r) => r?.verdict === 'helped' || r?.verdict === 'hurt')) {
      errs.push(`${at} lesson rests only on confounded / no-observed-effect rows, so it is a guess; narrow it to what a helped or hurt row shows, or set \`lesson\` to null`);
    }
    if (!used.some((r) => r?.component && String(l?.lesson ?? '').includes(r.component))) {
      errs.push(`${at} lesson must name the component it concerns (one of: ${[...new Set(used.map((r) => r?.component))].join(', ')})`);
    }
  });
  return { entries: doc.entries.length, lessons };
}

// AGENTS.md at <ref>, or null when the ref or the file does not exist there.
function alwaysOnAt(root, ref) {
  try {
    return execFileSync('git', ['-C', root, 'show', `${ref}:AGENTS.md`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

export function checkHarness(root, { base } = {}) {
  const errs = [];
  const body = checkAlwaysOn(root, errs);
  const skills = checkSkills(root, body, errs);
  const { commands, files } = checkHooks(root, errs);
  const skillSources = skills.map((n) => {
    const rel = `.agents/skills/${n}/SKILL.md`;
    return [rel, readFileSync(join(root, rel), 'utf8')];
  });
  checkDuplicates(body, skillSources, errs);
  checkScriptRefs(root, [['AGENTS.md', body], ...skillSources, ...commands.map((c) => ['hooks', c])], errs);
  const subagents = checkSubagents(root, errs);
  const hints = checkHints(root, errs);
  const experience = checkExperience(root, errs);
  const census = {
    always_on_chars: chars(body), always_on_max: ALWAYS_ON_MAX, skills: skills.length, subagents,
    hook_files: files, hook_commands: commands.length, error_hints: hints,
    experience_entries: experience.entries, experience_lessons: experience.lessons,
  };
  if (base) {
    const before = alwaysOnAt(root, base);
    if (before === null) errs.push(`--base ${base}: AGENTS.md could not be read at that ref`);
    else census.always_on_char_delta = chars(body) - chars(before);
  }
  return { errors: [...new Set(errs)], census };
}

function main(argv) {
  const at = argv.indexOf('--root');
  const root = resolve(at >= 0 ? argv[at + 1] : join(dirname(fileURLToPath(import.meta.url)), '../..'));
  const b = argv.indexOf('--base');
  const { errors, census } = checkHarness(root, { base: b >= 0 ? argv[b + 1] : undefined });
  if (argv.includes('--json')) console.log(JSON.stringify({ ok: errors.length === 0, errors, census }, null, 2));
  else if (errors.length) {
    console.log(`HARNESS FAIL  ${errors.length} problem(s)`);
    for (const e of errors) console.log(`  - ${e}`);
  } else {
    const delta = census.always_on_char_delta === undefined ? '' : ` (${census.always_on_char_delta >= 0 ? '+' : ''}${census.always_on_char_delta} vs base)`;
    console.log(
      `HARNESS OK  AGENTS.md ${census.always_on_chars}/${census.always_on_max} chars${delta}, ${census.skills} skill(s), ` +
        `${census.hook_commands} hook command(s), ${census.error_hints} error hint(s), ` +
        `${census.experience_entries} experience entr${census.experience_entries === 1 ? 'y' : 'ies'}`,
    );
  }
  return errors.length ? 1 : 0;
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  process.exitCode = main(process.argv.slice(2));
}
