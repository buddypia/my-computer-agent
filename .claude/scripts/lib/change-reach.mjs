/**
 * change-reach.mjs — How far a change reaches (pure function + one optional file read).
 *
 * Why (user feedback 2026-09-18): "People do not read file lists.
 * What matters is where the change lands and how much. A harness fix only touches local tooling;
 * a production data migration or a new feature must be judged properly." A reviewer's first
 * question is not "which files" but
 * "who feels this if it is wrong, and can we take it back". This module answers that from git
 * paths alone, deterministically, so the deck can open with it and the narrative gate can demand
 * more when the stakes are higher.
 *
 * Tiers (highest stakes first). The change's tier is the highest tier any of its paths reaches.
 *   data     — stored data or contracts other systems read (API payloads, schemas, host config).
 *              Revert of the code does not undo what consumers already read or wrote.
 *   product  — what users see or run after deploy (pages, catalog content, locale strings, the
 *              runtime server, and the build scripts that emit the pages).
 *   pipeline — how things get built, verified and deployed. Users do not feel it directly; a
 *              mistake ships the wrong artifact or blocks shipping.
 *   local    — only people and AIs working inside this repository feel it.
 *
 * Rules live in `.claude/reach-map.json` (project-owned; this file is a harness-managed asset
 * and may be re-transplanted, the map must survive that — so the map is deliberately NOT part of
 * any transplant bundle: harness's map describes harness's layout, a target writes its own).
 * When the map is absent, generic conventions apply and the deck says so.
 *
 * Localization: the map may carry `locale` (e.g. "ko" — also selects the deck's DECK_LABELS) and
 * `tiers.<id>.{label,short,means}` to re-word a tier without editing this managed file. Tier ids,
 * order and tone are fixed here; only the words are the project's.
 *
 * Boundary (R-CM-028): perspective1-only — same isolation as the other deck modules.
 */

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const REACH_MAP_RELPATH = '.claude/reach-map.json';

export const REACH_TIERS = Object.freeze([
  {
    id: 'data',
    label: 'Data · contracts',
    short: 'Data/contracts',
    tone: 'red',
    means: 'Stored data or a contract other systems read (API payloads, schemas, host config) changes. Reverting the code does not undo what consumers already read.',
  },
  {
    id: 'product',
    label: 'Production screens · behavior',
    short: 'Production',
    tone: 'orange',
    means: 'Once deployed, what users see or run changes.',
  },
  {
    id: 'pipeline',
    label: 'Build · deploy · verification path',
    short: 'Pipeline',
    tone: 'yellow',
    means: 'How things get built, verified or deployed changes. Users do not feel it directly; if it is wrong, the wrong thing ships or shipping is blocked.',
  },
  {
    id: 'local',
    label: 'Local tooling · docs',
    short: 'Local',
    tone: 'green',
    means: 'Only people and AIs working inside this repository feel it. Users, data and deploys are not touched.',
  },
]);

/** Plain-text fragments of the reach summary, per locale. Unknown locales use `en`. */
export const REACH_TEXT = Object.freeze({
  en: { more: (n) => `+${n} more`, none: 'none', noFiles: 'no changed files' },
  ko: { more: (n) => `외 ${n}`, none: '없음', noFiles: '변경 파일 없음' },
});

const reachText = (locale) => (Object.hasOwn(REACH_TEXT, locale ?? '') ? REACH_TEXT[locale] : REACH_TEXT.en);

const TIER_TEXT_KEYS = ['label', 'short', 'means'];

/** Validated `tiers` overrides from a reach map: `{ <tier id>: { label?, short?, means? } }`. */
function compileTierOverrides(raw, source) {
  if (raw === undefined) return {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error(`${source}: \`tiers\` must be an object`);
  const out = {};
  for (const [id, words] of Object.entries(raw)) {
    if (!REACH_TIERS.some((t) => t.id === id)) {
      throw new Error(`${source}: tiers.${id} is not a tier (expected ${REACH_TIERS.map((t) => t.id).join('|')})`);
    }
    out[id] = {};
    for (const k of TIER_TEXT_KEYS) {
      if (words?.[k] === undefined) continue;
      if (typeof words[k] !== 'string' || !words[k].trim()) throw new Error(`${source}: tiers.${id}.${k} must be a non-empty string`);
      out[id][k] = words[k];
    }
  }
  return out;
}

const TIER_RANK = Object.fromEntries(REACH_TIERS.map((t, i) => [t.id, i]));
export const REACH_TIER_IDS = Object.freeze(REACH_TIERS.map((t) => t.id));

/**
 * Generic conventions for repositories without a reach map. Conservative on purpose: an unknown
 * source directory is assumed to ship (product), never silently local; tests and docs never rank
 * above local; only real schema / migration paths reach data. First match wins.
 */
const BUILTIN_RULES = [
  {
    tier: 'local',
    why: 'builtin: tests, fixtures, docs, examples (checked first so a fixture schema or docs/api page is not data)',
    match: ['^(tests?|__tests__|spec|e2e|fixtures|docs?|examples?)/', '(^|/)__tests__/', '(^|/)[^/]+\\.(test|spec)\\.[a-z]+$'],
  },
  {
    tier: 'pipeline',
    why: 'builtin: AI harness, git hooks, CI, build tooling, package manifests',
    match: [
      '^\\.(claude|cli|agents|husky|codex|cursor|github|circleci|gitlab)/', '^\\.gitlab-ci\\.ya?ml$',
      '^Makefile$', '(^|/)Dockerfile$', '^(package(-lock)?\\.json|pnpm-lock\\.yaml|yarn\\.lock)$',
      '^(scripts?|tools?|ci)/', '^[^/]+\\.config\\.[cm]?[jt]s$', '^\\.[^/]+$',
    ],
  },
  {
    tier: 'data',
    why: 'builtin: migrations, SQL, Prisma, schema files',
    match: ['(^|/)migrations?/', '\\.sql$', '(^|/)prisma/', '\\.schema\\.json$', '(^|/)schema\\.(prisma|graphql|gql|sql)$'],
  },
  { tier: 'local', why: 'builtin: top-level prose (README, CHANGELOG, LICENSE)', match: ['^[^/]+\\.(md|txt)$', '^LICENSE'] },
  { tier: 'product', why: 'builtin: everything else is assumed to ship', match: ['.*'] },
];

function compileRules(rawRules, source) {
  const rules = [];
  for (const raw of Array.isArray(rawRules) ? rawRules : []) {
    if (!raw || typeof raw !== 'object' || !Object.prototype.hasOwnProperty.call(TIER_RANK, raw.tier)) {
      throw new Error(`${source}: rule with unknown tier ${JSON.stringify(raw?.tier)} (expected ${REACH_TIER_IDS.join('|')})`);
    }
    const patterns = (Array.isArray(raw.match) ? raw.match : []).map((p) => new RegExp(p));
    if (!patterns.length) throw new Error(`${source}: rule for tier ${raw.tier} has no match patterns`);
    rules.push({ tier: raw.tier, why: String(raw.why ?? ''), patterns });
  }
  if (!rules.length) throw new Error(`${source}: no rules`);
  return rules;
}

export function builtinReachMap() {
  return { source: 'builtin', path: null, rules: compileRules(BUILTIN_RULES, 'builtin'), locale: 'en', tiers: {} };
}

/**
 * Loads `.claude/reach-map.json` from a project directory. Falls back to builtin conventions
 * when the file is missing (`source: 'builtin'`), so a transplanted repository still gets a
 * banner — with a visible caveat rather than a silent guess. A present-but-broken map throws:
 * a wrong map is worse than no map.
 */
export function loadReachMap(projectDir = process.cwd()) {
  const path = join(projectDir, REACH_MAP_RELPATH);
  if (!existsSync(path)) return builtinReachMap();
  const parsed = JSON.parse(readFileSync(path, 'utf8'));
  const locale = typeof parsed.locale === 'string' ? parsed.locale.trim() : undefined;
  const known = locale !== undefined && Object.hasOwn(REACH_TEXT, locale);
  return {
    source: 'project',
    path,
    rules: compileRules(parsed.rules, REACH_MAP_RELPATH),
    locale: known ? locale : 'en',
    tiers: compileTierOverrides(parsed.tiers, REACH_MAP_RELPATH),
    // An unknown locale renders English — said out loud rather than silently.
    warning:
      parsed.locale !== undefined && !known
        ? `${REACH_MAP_RELPATH}: locale ${JSON.stringify(parsed.locale)} is not one of ${Object.keys(REACH_TEXT).join('|')} — English used`
        : null,
  };
}

/** Rename rows arrive as `old -> new`; the new location decides where the change reaches. */
function classificationPath(path) {
  const s = String(path ?? '')
    .trim()
    .replace(/^\.\//, '');
  return s.includes(' -> ') ? s.split(' -> ').pop().trim() : s;
}

/** Path → tier id (first matching rule wins). */
export function classifyReach(path, map) {
  const p = classificationPath(path);
  if (!p) return 'local';
  const rules = map?.rules ?? builtinReachMap().rules;
  for (const rule of rules) if (rule.patterns.some((re) => re.test(p))) return rule.tier;
  return 'local';
}

/** What the narrative must carry at a given tier. The gate reads this; so does the template. */
export function reachRequirements(tierId) {
  const rank = TIER_RANK[tierId] ?? TIER_RANK.local;
  return {
    exposure: rank <= TIER_RANK.product, // data, product
    dataChange: tierId === 'data',
    failureModesMin: rank <= TIER_RANK.product ? 2 : 1,
  };
}

function shortList(paths, text, max = 2) {
  const head = paths.slice(0, max).join(', ');
  return paths.length > max ? `${head} ${text.more(paths.length - max)}` : head;
}

/** Changed paths from name-status rows, plus numstat-only paths (tests build models from numstat alone). */
function changedPaths(nameStatusRows, numstat) {
  const paths = nameStatusRows.map((r) => String(r?.path ?? '').trim()).filter(Boolean);
  for (const r of numstat) {
    const p = String(r?.path ?? '').trim();
    if (p && !paths.includes(p)) paths.push(p);
  }
  return paths;
}

/** Per-tier file count, churn and paths, highest stakes first. */
function tierSummaries(paths, numstat, map) {
  const churn = new Map(numstat.map((r) => [classificationPath(r.path), r]));
  const buckets = Object.fromEntries(REACH_TIER_IDS.map((id) => [id, []]));
  for (const path of paths) buckets[classifyReach(path, map)].push(path);
  return REACH_TIERS.map((base) => {
    const t = { ...base, ...(map?.tiers?.[base.id] ?? {}) };
    const list = buckets[t.id];
    const loc = list.reduce((s, p) => {
      const c = churn.get(classificationPath(p));
      return s + (c?.added ?? 0) + (c?.deleted ?? 0);
    }, 0);
    return { ...t, files: list.length, loc, paths: list, touched: list.length > 0 };
  });
}

/**
 * Change set → reach summary for the deck and the gate.
 * @param {{nameStatusRows?: Array<{path:string,kind?:string}>, numstat?: Array<{path:string,added?:number,deleted?:number}>, map?: object}} input
 */
export function buildReach({ nameStatusRows = [], numstat = [], map = null } = {}) {
  const numstatRows = Array.isArray(numstat) ? numstat : [];
  const paths = changedPaths(Array.isArray(nameStatusRows) ? nameStatusRows : [], numstatRows);
  const tiers = tierSummaries(paths, numstatRows, map);
  const top = tiers.find((t) => t.touched) ?? tiers[tiers.length - 1];
  const locale = map?.locale ?? 'en';
  const text = reachText(locale);
  return {
    tier: top.id,
    label: top.label,
    short: top.short,
    tone: top.tone,
    means: top.means,
    source: map?.source ?? 'builtin',
    locale,
    tiers,
    touched: tiers.filter((t) => t.touched).map((t) => t.id),
    files: paths.length,
    requires: reachRequirements(top.id),
    headline: paths.length ? `${top.label} — ${top.means} (${shortList(top.paths, text)})` : text.noFiles,
  };
}

/** One-line, plain-text rendering for the CLI (`ship-deck.mjs --reach`) and error hints. */
export function describeReach(reach) {
  if (!reach) return '';
  const parts = reach.tiers.filter((t) => t.touched).map((t) => `${t.short} ${t.files}`);
  const req = [
    reach.requires.exposure ? 'exposure' : null,
    reach.requires.dataChange ? 'data_change' : null,
    `failure_modes ≥ ${reach.requires.failureModesMin}`,
  ]
    .filter(Boolean)
    .join(', ');
  return `${reach.label} [${parts.join(' · ') || reachText(reach.locale).none}]${reach.source === 'builtin' ? ' (builtin conventions — no reach map)' : ''} → required: ${req}`;
}
