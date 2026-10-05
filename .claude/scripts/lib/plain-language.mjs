/**
 * plain-language.mjs — Review deck plain language contract: lexicon merging + unexplained term validation (pure function)
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Unexplained technical jargon ("guided run", etc.) appeared in deck prose making review
 *       difficult for non-domain engineers (reported 2026-07-16 — feature/stage1-conversation-optimization deck).
 *   (b) Gaps: Deck contract only validated field presence/path consistency — zero language clarity checks.
 *   (c) Simpler alternatives: SKILL/rule prompt-level guidance alone rejected due to lack of hard enforcement.
 *
 * Mechanism (Target audience: general software engineers):
 *   1. lexicon = glossary.json (SSOT for term data — R-CM-038 anchor glossary)
 *      + narrative.glossary (deck-scoped on-the-fly definitions).
 *   2. Latin technical words extracted from prose fields — paths/filenames/numbers and
 *      common engineering vocabulary (ENGINEER_ALLOW code constants) are exempted.
 *   3. Terms must be resolved via: (a) lexicon entry, (b) reference number pattern (REFERENCE_PATTERNS),
 *      or (c) "Term (inline definition)" glossing. Unresolved terms trigger fail-closed validation.
 *   4. Matched terms returned for rendering the Glossary section.
 *
 * Boundary (R-CM-028): perspective1-only — review deck stack (never_deploy). Not deployed to scaffolds.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/** Term data SSOT location (repo root relative) — shared by ship-deck and review-deck */
export const GLOSSARY_REGISTRY_RELPATH = 'data/registry/glossary.json';

/**
 * Common engineering vocabulary allowlist (lowercase) — terms widely understood
 * by software engineers without needing explicit glossary definitions.
 * Maintained as code constants rather than glossary.json entries.
 * harness-specific terms (guided run, builder mode, etc.) belong in glossary.json instead.
 */
export const ENGINEER_ALLOW = new Set(
  [
    // Acronyms / Formats / Protocols
    ...['ai', 'api', 'cli', 'ui', 'ux', 'ci', 'cd', 'id', 'ids', 'ok', 'pr', 'prs', 'url', 'uri'],
    ...['http', 'https', 'html', 'css', 'json', 'jsonl', 'yaml', 'yml', 'xml', 'svg', 'csv'],
    ...['md', 'mjs', 'markdown', 'sql', 'db', 'regex', 'regexp', 'ascii', 'io', 'os', 'cpu'],
    ...['sdk', 'ide', 'llm', 'mcp', 'ssot', 'utf-8', 'e2e', 'xss', 'jwt', 'oauth', 'cors'],
    // Git / Review workflow
    ...['git', 'github', 'gitignore', 'commit', 'commits', 'merge', 'squash', 'rebase'],
    ...['push', 'pull', 'fetch', 'clone', 'branch', 'branches', 'main', 'master', 'origin'],
    ...['remote', 'upstream', 'diff', 'diffs', 'revert', 'rollback', 'head', 'sha', 'stash'],
    ...['checkout', 'tag', 'cherry-pick', 'review', 'reviewer', 'approve', 'ship', 'release'],
    ...['deploy', 'deployment', 'hotfix', 'patch', 'ship-worktree', 'create-pr', 'draft'],
    ...['code-review', 'code-reviewer', 'verdict', 'go', 'no-go', 'quality', 'gate', 'panel'],
    // General development nouns
    ...['repo', 'repository', 'package', 'module', 'modules', 'library', 'framework', 'stack'],
    ...['dependency', 'dependencies', 'version', 'config', 'configs', 'configuration', 'env'],
    ...['log', 'logs', 'logging', 'debug', 'error', 'errors', 'warning', 'warnings', 'exit'],
    ...['exception', 'crash', 'fail', 'failed', 'failure', 'pass', 'passed', 'script', 'scripts'],
    ...['command', 'commands', 'shell', 'bash', 'zsh', 'terminal', 'path', 'paths', 'file'],
    ...['files', 'folder', 'directory', 'root', 'dir', 'bug', 'bugs', 'fix', 'fixes', 'todo'],
    ...['feature', 'features', 'chore', 'docs', 'doc', 'refactor', 'refactoring', 'readme'],
    // Build / Test / Quality
    ...['test', 'tests', 'testing', 'lint', 'linter', 'linting', 'build', 'builds', 'compile'],
    ...['bundle', 'format', 'formatter', 'prettier', 'eslint', 'typecheck', 'coverage'],
    ...['unit', 'integration', 'smoke', 'benchmark', 'fixture', 'fixtures', 'mock', 'mocks'],
    ...['stub', 'stubs', 'snapshot', 'snapshots', 'golden', 'regression', 'red-green', 'audit'],
    ...['vitest', 'jest', 'playwright', 'node', 'npm', 'npx', 'pnpm', 'yarn', 'makefile'],
    ...['make', 'docker', 'typescript', 'javascript', 'js', 'ts', 'python', 'rust', 'flutter'],
    ...['dart', 'tauri', 'react', 'nextjs', 'postgres', 'sqlite', 'supabase', 'graphql', 'rest'],
    // Code concepts
    ...['schema', 'schemas', 'spec', 'specs', 'contract', 'contracts', 'interface', 'type'],
    ...['types', 'class', 'function', 'functions', 'method', 'methods', 'callback', 'promise'],
    ...['async', 'await', 'sync', 'event', 'events', 'handler', 'handlers', 'hook', 'hooks'],
    ...['listener', 'trigger', 'triggers', 'guard', 'guards', 'validation', 'validate'],
    ...['validator', 'parser', 'parse', 'parsing', 'render', 'renderer', 'rendering'],
    ...['template', 'templates', 'generator', 'scaffold', 'scaffolding', 'boilerplate'],
    ...['pipeline', 'pipelines', 'workflow', 'workflows', 'queue', 'cron', 'batch', 'cache'],
    ...['token', 'tokens', 'session', 'sessions', 'request', 'response', 'endpoint', 'route'],
    ...['router', 'query', 'queries', 'param', 'params', 'parameter', 'parameters'],
    ...['argument', 'arguments', 'args', 'flag', 'flags', 'option', 'options', 'input'],
    ...['inputs', 'output', 'outputs', 'stdin', 'stdout', 'stderr', 'null', 'undefined'],
    ...['true', 'false', 'boolean', 'string', 'strings', 'number', 'array', 'arrays', 'list'],
    ...['map', 'set', 'object', 'objects', 'key', 'keys', 'value', 'values', 'field', 'fields'],
    ...['index', 'state', 'status', 'marker', 'markers', 'registry', 'resolver', 'loader'],
    ...['runner', 'wrapper', 'adapter', 'proxy', 'middleware', 'plugin', 'plugins', 'agent'],
    ...['agents', 'subagent', 'subagents', 'skill', 'skills', 'prompt', 'prompts', 'context'],
    ...['runtime', 'process', 'thread', 'memory', 'buffer', 'stream', 'atomic', 'transaction'],
    ...['idempotent', 'idempotency', 'immutable', 'fallback', 'timeout', 'retry', 'retries'],
    ...['dry-run', 'verbose', 'silent', 'silently', 'drift', 'stale', 'staleness', 'fresh'],
    ...['freshness', 'allowlist', 'blocklist', 'fail-open', 'fail-closed', 'opt-in', 'opt-out'],
    ...['opt-in-by-presence', 'pre-commit', 'prompt-level', 'lexicon', 'deck', 'legend'],
    ...['narrative', 'glossary', 'note', 'notes', 'slug', 'worktree', 'worktrees'],
    ...['grep', 'sed', 'awk', 'curl', 'learning', 'intake'],
    ...['production', 'staging', 'dev', 'development', 'local', 'run', 'runs', 'stage', 'tier'],
    ...['migration', 'seed', 'predicate', 'predicates', 'block', 'blocking', 'deny', 'allow'],
    // Product / Platform names
    ...['harness', 'claude', 'code', 'codex', 'anthropic', 'antigravity'],
    ...['web', 'mobile', 'desktop', 'app', 'apps', 'vs', 'etc', 'via', 'a11y'],
  ].map((w) => w.toLowerCase()),
);

/**
 * Reference number patterns — Identifiers within the harness system.
 * Managed as code constants rather than glossary terms.
 */
export const REFERENCE_PATTERNS = [
  {
    pattern: 'R-(?:CM|PL|TS|DT|RS)-\\d+[\\w.-]*',
    label: 'R-CM-* / R-PL-* Rule ID',
    plain: 'harness internal operational rule ID (located in .claude/rules/)',
  },
  {
    pattern: 'DEBT-\\d+',
    label: 'DEBT-* Follow-up Debt ID',
    plain: 'Registered follow-up task ID for subsequent work',
  },
  {
    pattern: 'FR-[\\w.-]+',
    label: 'FR-* Functional Requirement ID',
    plain: 'Functional requirement ID in SPEC documents',
  },
  {
    pattern: 'REQ-\\d+',
    label: 'REQ-* Requirement ID',
    plain: 'Requirement ID within this review deck',
  },
  {
    pattern: 'CP-[A-Z]+',
    label: 'CP-* Review Checkpoint',
    plain:
      'Review checkpoint name (CP-SPEC=Requirements, CP-PLAN=Plan, CP-MILESTONE=Interim, CP-UI=Screens, CP-SHIP=Pre-ship)',
  },
  {
    pattern: 'SPEC-\\d+[\\w.-]*',
    label: 'SPEC-* Specification Document ID',
    plain: 'Feature specification (SPEC) document ID',
  },
];

/** Latin technical vocabulary — leading letter/underscore + word characters/dots/hyphens */
const LATIN_WORD_RE = /[A-Za-z_][A-Za-z0-9_.-]*/g;
/** Slashes denote paths/URLs — excluded from plain language check */
const PATH_LIKE_RE = /\S*[/\\]\S*/g;
/** File names with extensions — excluded from check */
const FILE_NAME_RE =
  /[\w.-]+\.(?:mjs|cjs|js|ts|tsx|jsx|json|md|ya?ml|html|css|svg|sh|py|txt|lock)\b/gi;

/** Escapes regex special characters */
export function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Latin alias word boundary matching regex */
function latinAliasRegExp(alias, flags) {
  return new RegExp(`(?<![A-Za-z0-9_])${escapeRegExp(alias)}(?![A-Za-z0-9_])`, flags);
}

/** glossary.json term → matching alias candidates (Latin-containing only) */
function glossaryAliases(term) {
  const raw = [
    ...(Array.isArray(term.aliases) ? term.aliases : []),
    ...String(term.technical || '').split('/'),
  ];
  return [
    ...new Set(
      raw.map((a) => String(a).trim()).filter((a) => a.length >= 2 && /[A-Za-z]/.test(a)),
    ),
  ];
}

function asList(value) {
  return Array.isArray(value) ? value : [];
}

/** glossary.json terms → lexicon entries (excluding retired terms) */
function glossaryEntries(glossary) {
  return asList(glossary?.terms)
    .filter((term) => term && term.status !== 'retired' && term.definition)
    .map((term) => ({ term, aliases: glossaryAliases(term) }))
    .filter(({ aliases }) => aliases.length)
    .map(({ term, aliases }) => ({
      label:
        term.surface && term.technical
          ? `${term.surface} (${term.technical})`
          : String(term.surface || term.technical || aliases[0]),
      plain: String(term.definition),
      aliases,
    }));
}

/** narrative.glossary (deck-scoped definitions) → lexicon entries */
function extraTermEntries(extraTerms) {
  return asList(extraTerms)
    .map((extra) => ({
      label: String(extra?.term || '').trim(),
      plain: String(extra?.plain || '').trim(),
    }))
    .filter((e) => e.label && e.plain)
    .map((e) => ({ ...e, aliases: [e.label] }));
}

/** Compiles reference number patterns */
function compilePatterns(patternDefs) {
  const patterns = [];
  for (const p of asList(patternDefs)) {
    if (!p?.pattern || !p.label || !p.plain) continue;
    try {
      patterns.push({
        regex: new RegExp(`(?<![A-Za-z0-9_])(?:${p.pattern})(?![A-Za-z0-9_])`, 'g'),
        label: String(p.label),
        plain: String(p.plain),
      });
    } catch {
      /* skip */
    }
  }
  return patterns;
}

/**
 * Merges lexicon — glossary (SSOT) + extraTerms (narrative definitions).
 *
 * @returns {{ entries: Array<{label, plain, aliases}>, patterns: Array<{regex, label, plain}>, allow: Set }}
 */
export function buildPlainLanguageLexicon({ glossary, extraTerms, extraAllow } = {}) {
  return {
    entries: [...glossaryEntries(glossary), ...extraTermEntries(extraTerms)],
    patterns: compilePatterns(REFERENCE_PATTERNS),
    allow: new Set([
      ...ENGINEER_ALLOW,
      ...asList(extraAllow).map((a) => String(a).toLowerCase()),
    ]),
  };
}

/**
 * Returns copy of lexicon with narrative.glossary[] merged in.
 */
export function withNarrativeGlossary(lexicon, narrative) {
  const extras = extraTermEntries(narrative?.glossary);
  if (!lexicon || !extras.length) return lexicon;
  return { ...lexicon, entries: [...lexicon.entries, ...extras] };
}

/**
 * Detects whether term is explained inline with parenthetical definitions.
 */
export function isInlineGlossed(text, word) {
  const esc = escapeRegExp(word);
  const glossAfter = new RegExp(`${esc}\\s*[(（][^)）]*[\\p{L}]{2,}[^)）]*[)）]`, 'u');
  const glossBefore = new RegExp(`[\\p{L}]{2,}\\s*[(（][^)）]*${esc}`, 'u');
  return glossAfter.test(text) || glossBefore.test(text);
}

/** Human-brief prose (ship deck, 2026-09-18): who notices, where to review, what was left undone. */
function pushBriefFields(narrative, push) {
  push('for_whom', narrative.forWhom);
  (narrative.knownGaps ?? []).forEach((v, i) => push(`known_gaps[${i}]`, v));
  (narrative.reviewFocus ?? []).forEach((f, i) => {
    push(`review_focus[${i}].where`, f.where);
    push(`review_focus[${i}].check`, f.check);
    push(`review_focus[${i}].risk_if_wrong`, f.riskIfWrong);
  });
}

/** Impact-first prose (ship deck, 2026-09-18): what breaks, who is exposed, what data moves, the drawn diagram. */
function pushImpactFields(narrative, push) {
  (narrative.failureModes ?? []).forEach((f, i) => {
    push(`failure_modes[${i}].scenario`, f.scenario);
    push(`failure_modes[${i}].who_notices`, f.whoNotices);
    push(`failure_modes[${i}].detect`, f.detect);
    push(`failure_modes[${i}].mitigation`, f.mitigation);
  });
  if (narrative.exposure) {
    push('exposure.who', narrative.exposure.who);
    push('exposure.how_many', narrative.exposure.howMany);
    push('exposure.when', narrative.exposure.when);
    push('exposure.reversible', narrative.exposure.reversible);
  }
  if (narrative.dataChange) {
    push('data_change.what_moves', narrative.dataChange.whatMoves);
    push('data_change.count', narrative.dataChange.count);
    push('data_change.irreversible', narrative.dataChange.irreversible);
    push('data_change.order', narrative.dataChange.order);
    push('data_change.consumers', narrative.dataChange.consumers);
  }
  if (narrative.diagram) {
    push('diagram.title', narrative.diagram.title);
    (narrative.diagram.steps ?? []).forEach((st, i) => {
      push(`diagram.steps[${i}].label`, st.label);
      push(`diagram.steps[${i}].note`, st.note);
    });
    (narrative.diagram.rows ?? []).forEach((r, i) => {
      push(`diagram.rows[${i}].aspect`, r.aspect);
      push(`diagram.rows[${i}].before`, r.before);
      push(`diagram.rows[${i}].after`, r.after);
    });
  }
}

/** Collects prose fields from normalized narrative */
export function collectProseFields(narrative) {
  if (!narrative || typeof narrative !== 'object') return [];
  const fields = [];
  const push = (field, value) => {
    const text = String(value ?? '').trim();
    if (text) fields.push({ field, text });
  };
  push('what', narrative.what);
  push('why', narrative.why);
  push('how', narrative.how);
  push('next', narrative.next);
  push('impact', narrative.impact);
  push('regression_risk', narrative.regressionRisk);
  push('rollback', narrative.rollback);
  pushBriefFields(narrative, push);
  (narrative.outOfScope ?? []).forEach((v, i) => push(`out_of_scope[${i}]`, v));
  pushImpactFields(narrative, push);
  (narrative.affectedFeatures ?? []).forEach((v, i) => push(`affected_features[${i}]`, v));
  (narrative.requirements ?? []).forEach((r, i) => {
    push(`requirements[${i}].need`, r.need);
    push(`requirements[${i}].why`, r.why);
    push(`requirements[${i}].validation`, r.validation);
    (r.implementation ?? []).forEach((im, j) =>
      push(`requirements[${i}].implementation[${j}].change`, im.change),
    );
  });
  (narrative.tradeoffs ?? []).forEach((t, i) => {
    push(`tradeoffs[${i}].topic`, t.topic);
    push(`tradeoffs[${i}].chosen`, t.chosen);
    push(`tradeoffs[${i}].rejected`, t.rejected);
    push(`tradeoffs[${i}].why`, t.why);
    push(`tradeoffs[${i}].cost`, t.cost);
  });
  (narrative.fileNotes ?? []).forEach((n, i) => {
    push(`file_notes[${i}].change`, n.change);
    push(`file_notes[${i}].reason`, n.reason);
  });
  (narrative.frNotes ?? []).forEach((n, i) => {
    push(`fr_notes[${i}].ko`, n.ko);
    push(`fr_notes[${i}].why`, n.why);
    push(`fr_notes[${i}].how`, n.how);
  });
  (narrative.specChanges ?? []).forEach((c, i) => push(`spec_changes[${i}].change`, c.change));
  (narrative.apiChanges ?? []).forEach((c, i) => push(`api_changes[${i}].compat`, c.compat));
  return fields;
}

/** Removes all occurrences of alias from text */
function removeAlias(text, alias) {
  return text.replace(latinAliasRegExp(alias, 'gi'), ' ');
}

/**
 * Evaluates plain language compliance.
 *
 * @param {Array<{field, text}>} fields
 * @param {object} lexicon - Output of buildPlainLanguageLexicon
 * @returns {{ matches: Array<{label, plain, aliases}>, violations: Array<{field, token}> }}
 */
export function evaluatePlainLanguage(fields, lexicon) {
  const matches = new Map();
  const violations = [];
  const aliasList = flattenAliasesLongestFirst(lexicon.entries);
  for (const { field, text } of Array.isArray(fields) ? fields : []) {
    if (!text || typeof text !== 'string') continue;
    let stripped = text.replace(PATH_LIKE_RE, ' ').replace(FILE_NAME_RE, ' ');
    stripped = stripLexiconEntries(stripped, aliasList, matches);
    stripped = stripPatternRefs(stripped, lexicon, matches);
    collectFieldViolations({ field, text, stripped, lexicon, violations });
  }
  return {
    matches: [...matches.values()].sort((a, b) => a.label.localeCompare(b.label, 'en')),
    violations,
  };
}

function flattenAliasesLongestFirst(entries) {
  const flat = [];
  for (const entry of entries) {
    for (const alias of entry.aliases) flat.push({ alias, entry });
  }
  return flat.sort((a, b) => b.alias.length - a.alias.length);
}

function stripLexiconEntries(stripped, aliasList, matches) {
  for (const { alias, entry } of aliasList) {
    if (!latinAliasRegExp(alias, 'i').test(stripped)) continue;
    stripped = removeAlias(stripped, alias);
    if (!matches.has(entry.label)) matches.set(entry.label, entry);
  }
  return stripped;
}

function stripPatternRefs(stripped, lexicon, matches) {
  for (const p of lexicon.patterns) {
    const re = new RegExp(p.regex.source, 'g');
    if (!re.test(stripped)) continue;
    if (!matches.has(p.label)) {
      matches.set(p.label, { label: p.label, plain: p.plain, aliases: [], pattern: p.regex.source });
    }
    re.lastIndex = 0;
    stripped = stripped.replace(re, ' ');
  }
  return stripped;
}

/**
 * Detects redundant narrative.glossary entries that are already resolved.
 */
export function findRedundantNarrativeGlossary(narrative, lexicon) {
  if (!lexicon || typeof lexicon !== 'object') return [];
  const aliasSet = new Set(
    (lexicon.entries ?? []).flatMap((e) => (e.aliases ?? []).map((a) => String(a).toLowerCase())),
  );
  const results = [];
  const seen = new Set();
  for (const entry of asList(narrative?.glossary)) {
    const term = String(entry?.term || '').trim();
    const lower = term.toLowerCase();
    if (!term || seen.has(lower)) continue;
    seen.add(lower);
    const reason = classifyRedundantTerm(term, lower, lexicon, aliasSet);
    if (reason) results.push({ term, reason });
  }
  return results;
}

function classifyRedundantTerm(term, lower, lexicon, aliasSet) {
  if (aliasSet.has(lower)) return 'glossary';
  if ((lexicon.patterns ?? []).some((p) => new RegExp(`^(?:${p.regex.source})$`).test(term))) {
    return 'pattern';
  }
  if (/[가-힣]/.test(term)) return null;
  const tokens = (term.match(LATIN_WORD_RE) ?? [])
    .map((t) => t.replace(/[.-]+$/, '').toLowerCase())
    .filter((t) => t.length >= 2);
  return tokens.length && tokens.every((t) => lexicon.allow?.has(t)) ? 'allow' : null;
}

/** Formats redundant glossary entry error messages */
export function formatRedundantGlossaryEntries(entries) {
  const why = {
    glossary: `Term already registered in glossary (${GLOSSARY_REGISTRY_RELPATH}) — definition is automatically injected`,
    allow: 'Standard engineering vocabulary (ENGINEER_ALLOW) — definition not required',
    pattern: 'Reference pattern with automatic resolution',
  };
  return (Array.isArray(entries) ? entries : []).map(
    (e) =>
      `narrative.glossary: Redundant definition "${e.term}" — ${why[e.reason] ?? 'Already resolved'}. Remove this entry (harness-specific terms should be registered in glossary.json)`,
  );
}

/** Formats plain language violation error messages */
export function formatPlainLanguageViolations(violations) {
  return (Array.isArray(violations) ? violations : []).map(
    (v) =>
      `narrative.${v.field}: Unexplained technical term "${v.token}" — explain in plain language, inline gloss as "Term (explanation)", define in narrative.glossary, or register in data/registry/glossary.json`,
  );
}

function collectFieldViolations({ field, text, stripped, lexicon, violations }) {
  const seen = new Set();
  for (const raw of stripped.match(LATIN_WORD_RE) ?? []) {
    const word = raw.replace(/[.-]+$/, '');
    if (word.length < 2) continue;
    const lower = word.toLowerCase();
    if (seen.has(lower)) continue;
    seen.add(lower);
    if (lexicon.allow.has(lower)) continue;
    if (isInlineGlossed(text, word)) continue;
    violations.push({ field, token: word });
  }
}

/**
 * Loads glossary registry (glossary.json). Fail-open.
 */
export function loadGlossaryRegistry(rootDir, readFn = readFileSync) {
  const errors = [];
  let glossary = null;
  try {
    glossary = JSON.parse(readFn(join(rootDir, GLOSSARY_REGISTRY_RELPATH), 'utf8'));
  } catch (err) {
    errors.push(`Failed to load glossary lexicon (${GLOSSARY_REGISTRY_RELPATH}): ${err.message}`);
  }
  return { glossary, errors };
}
