/**
 * narrative-quality.mjs — Ship deck "human brief" quality gate (pure functions, fail-closed).
 *
 * Why (user feedback 2026-09-18):
 *   A deck there passed every existing check and was still unreadable. The first screen was machine
 *   tables; the prose said "perfect isolation", "0ms", "Section 8e.5"; the single trade-off row
 *   named no cost; nothing told the reviewer where to look or what was left undone. Field presence
 *   + path cross-check (ship-deck-core.mjs) proved the narrative was *there*, not that a human
 *   could *use* it. The glossary-based plain-language check only judges unexplained terms, and it
 *   is dormant wherever data/registry/glossary.json is absent — so this gate does not depend on it.
 *
 * What this gate judges — deterministic, no LLM, no glossary dependency:
 *   1. Brief fields exist: for_whom, review_focus[1..4] (where/check/risk_if_wrong each),
 *      known_gaps[≥1], tradeoffs[].cost.
 *   2. Ceilings — the brief must fit one screen. Over-length text is rejected, never truncated,
 *      because truncation hides exactly the sentence the author should have cut.
 *   3. Hype / unverifiable claims (perfect, seamless, 완벽, 0ms …) — a reviewer cannot check them.
 *      A negating prefix (imperfect, 불완전한) is not hype; it is usually the self-criticism we asked for.
 *   4. Empty phrases (ensure traceability, 추적성 확보 …) — they name an activity and say nothing.
 *   5. Internal locators (Section 8e.5, DEBT-123, R-CM-030) in brief prose — meaningless to
 *      anyone who was not in the author's session. Allowed only where a pointer is the point:
 *      requirements[].validation and rollback.
 *   6. Non-answers ("none", "n/a", "-", "없음") in the self-critique fields — the field exists so the
 *      author has to think; a placeholder is the same as leaving it out.
 *   7. review_focus.where that names a path must name one in the changeset.
 *
 * One traversal: word-level rules run over `collectProseFields()` from plain-language.mjs, the
 * same enumeration the glossary check uses, so a field cannot be covered by one gate and missed
 * by the other (review of PR #76 found four such holes when this file kept its own list).
 *
 * What it cannot judge: whether the "why" is true. That stays with the human. The gate only
 * guarantees the human receives a short, claim-free, self-critical text to judge.
 *
 * Word lists are locale-keyed (en, ko); see the table comment below.
 *
 * Boundary (R-CM-028): perspective1-only — review deck stack. Not deployed to scaffold targets.
 */

import { collectProseFields } from './plain-language.mjs';
import { reachRequirements } from './change-reach.mjs';

/** Character ceilings per field (whitespace-collapsed, indices stripped). One screen, not one scroll. */
export const SHIP_BRIEF_LIMITS = Object.freeze({
  what: 120,
  for_whom: 80,
  why: 220,
  how: 220,
  next: 160,
  impact: 220,
  regression_risk: 260,
  rollback: 200,
  'tradeoffs.topic': 60,
  'tradeoffs.chosen': 140,
  'tradeoffs.rejected': 140,
  'tradeoffs.why': 200,
  'tradeoffs.cost': 200,
  'review_focus.where': 120,
  'review_focus.check': 180,
  'review_focus.risk_if_wrong': 160,
  known_gaps: 160,
  out_of_scope: 100,
  affected_features: 80,
  'file_notes.change': 140,
  'file_notes.reason': 120,
  'requirements.need': 140,
  'requirements.why': 160,
  'requirements.implementation.change': 140,
  // Impact-first layer (2026-09-18)
  'failure_modes.scenario': 140,
  'failure_modes.who_notices': 80,
  'failure_modes.detect': 140,
  'failure_modes.mitigation': 160,
  'exposure.who': 100,
  'exposure.how_many': 80,
  'exposure.when': 100,
  'exposure.reversible': 140,
  'data_change.what_moves': 160,
  'data_change.count': 60,
  'data_change.irreversible': 160,
  'data_change.order': 200,
  'data_change.consumers': 120,
  'diagram.title': 80,
  'diagram.steps.label': 40,
  'diagram.steps.note': 80,
  'diagram.rows.aspect': 40,
  'diagram.rows.before': 100,
  'diagram.rows.after': 100,
});

/** List-size bounds. Below min = missing self-critique; above max = nobody reads it. */
export const SHIP_BRIEF_COUNTS = Object.freeze({
  review_focus: { min: 1, max: 4 },
  known_gaps: { min: 1, max: 5 },
  tradeoffs: { min: 1, max: 5 },
  out_of_scope: { min: 0, max: 6 },
  // min is raised by reach (change-reach.mjs#reachRequirements): 2 when the change reaches production.
  failure_modes: { min: 1, max: 5 },
  'diagram.steps': { min: 2, max: 8 },
  'diagram.rows': { min: 1, max: 6 },
});

export const DIAGRAM_KINDS = Object.freeze(['flow', 'before_after']);
export const DIAGRAM_STEP_STATES = Object.freeze(['same', 'changed', 'new', 'removed']);

/*
 * Word lists are keyed by locale (BCP 47 primary subtag). Every locale is applied to every field —
 * a narrative is often written in one language with identifiers and quotes in another — but a
 * negating prefix only neutralises a term of its own locale ("un" must not excuse "완벽", "불"
 * must not excuse "perfect"). To support another language, add the same key to each table below;
 * `NARRATIVE_LOCALES` lists what is covered.
 */

/**
 * Words that assert quality instead of describing it. Each one appeared in a shipped deck and
 * gave the reviewer nothing to verify. Matched as substrings, case-insensitive, unless preceded
 * by a negating prefix of the same locale (NEGATING_PREFIXES).
 * Not listed on purpose (ko): '절대' (절대 경로 = absolute path) and '무결' (무결성 검증 = integrity
 * check) — both are ordinary technical words and would be false positives.
 */
export const HYPE_TERMS = Object.freeze({
  en: Object.freeze([
    'perfect',
    'flawless',
    'bulletproof',
    'seamless',
    'blazing',
    'guaranteed',
    'zero-risk',
    'permanently',
    'future-proof',
    'best practice',
    'industry standard',
  ]),
  ko: Object.freeze(['완벽', '완전히', '완전한', '영구', '극대화', '획기적', '혁신적', '고효율', '최고의']),
});

/**
 * "imperfect", "non-seamless", "not perfect", "불완전한", "반영구", "안 완벽" — a hype root turned
 * into an admission. Compared against the text immediately before the match (lower-cased).
 * A prefix ending in a space is a separate word: it must start the text or follow whitespace
 * ("보안 완벽" is not "안 완벽").
 */
export const NEGATING_PREFIXES = Object.freeze({
  en: Object.freeze(['im', 'un', 'non-', 'non', 'not ', 'never ', 'no ']),
  ko: Object.freeze(['불', '반', '미', '비', '안 ', '못 ']),
});

/**
 * Negation that follows the root — Korean negates after the word: "완벽하지 않다", "완전히
 * 되돌리지 못한다", "완벽한 방법은 없다". Matched against the text right after the hype root.
 */
export const NEGATING_SUFFIXES = Object.freeze({
  ko: Object.freeze([/^\s?[가-힣]{0,6}?지[는도]?\s*(않|못)/, /^[가-힣]{0,3}(\s+[가-힣]{1,6})?\s*없/]),
});

/**
 * Established technical terms that contain a hype root but assert nothing ("guaranteed delivery"
 * is a messaging semantic). Removed before the hype scan.
 */
const HYPE_TERM_OF_ART = Object.freeze({
  en: Object.freeze(['guaranteed delivery', 'delivery guarantee', 'at-least-once', 'exactly-once']),
  ko: Object.freeze([]),
});

/**
 * Factual fields where permanence and completeness words are the honest answer: what a revert
 * does not undo ("permanently deleted", "영구 삭제"), how to roll back ("완전히 되돌린다"), what
 * goes wrong. Hype is not judged there; every other rule still is. `exposure.reversible` stays
 * checked: "완벽하게 되돌릴 수 있다" is a claim about the future, not a fact about data.
 */
const HYPE_EXEMPT_FIELDS =
  /^(rollback|data_change\.(what_moves|irreversible|order)|failure_modes\.scenario)$/;

/**
 * Template placeholders: a whole field written as `<...>` (the skeleton's form). An unedited
 * `--template` must not pass, even after its optional blocks are deleted.
 */
const PLACEHOLDER = /^<[^<>]*>$/;

/**
 * Phrases that name an activity without saying what changed for the reader.
 * "ensure traceability" / "추적성 확보" tells you the author did something about traceability,
 * and nothing else.
 */
export const EMPTY_PHRASES = Object.freeze({
  en: Object.freeze([
    'ensure traceability',
    'ensured traceability',
    'ensure consistency',
    'ensured consistency',
    'improve stability',
    'improved stability',
    'enhanced robustness',
    'various improvements',
    'general improvements',
    'documentation refresh',
  ]),
  ko: Object.freeze([
    '추적성 확보',
    '정합성 확보',
    '커버리지 확보',
    '안정성 확보',
    '불변 규범',
    '불변 규칙',
    '영구 보존',
    '영구 회귀 방지',
    '완벽 격리',
    '적대적 리뷰',
    '상태 동기화',
    '문서 최신화',
    '최신화 및',
    '규범 추가',
  ]),
});

/** Session-local locators: section numbers, debt tickets, rule ids. Language-neutral. */
export const INTERNAL_LOCATOR_PATTERNS = Object.freeze([
  /\bSection\s+\d+[A-Za-z]?(?:\.\d+)*\b/i,
  /§\s*\d+/,
  /\bDEBT-\d+\b/,
  /\bR-CM-\d+\b/,
  /\bPF-\d+\b/,
  /\bPOF-\d+\b/,
]);

/** Fields where a pointer *is* the content — locators are allowed there. */
const LOCATOR_ALLOWED = /^(rollback|requirements\.validation)$/;

/** Placeholders that satisfy a presence check without answering the question (whole-field match). */
export const NON_ANSWERS = Object.freeze({
  en: Object.freeze(['n/a', 'na', 'none', 'nothing', 'no', '-', '—', 'tbd', 'todo']),
  ko: Object.freeze(['없음', '없다', '없습니다', '해당 없음', '해당없음']),
});

/** Locales every table above covers. */
export const NARRATIVE_LOCALES = Object.freeze(Object.keys(HYPE_TERMS));

/** Self-critique fields: a non-answer here means the author did not think. (No length floor — "global cache" is a real answer.) */
const SELF_CRITIQUE_FIELDS =
  /^(known_gaps|tradeoffs\.rejected|tradeoffs\.cost|review_focus\.check|review_focus\.risk_if_wrong|failure_modes\.(scenario|who_notices|detect|mitigation)|exposure\.(who|how_many|when|reversible)|data_change\.(what_moves|count|irreversible|order|consumers))$/;

/** Stage-only narrative fields the ship deck never renders — not judged here. */
const SHIP_HIDDEN_FIELDS = /^fr_notes\b/;

/**
 * A performance claim that is not accompanied by how it was measured: any `ms` figure, or a `%`
 * figure next to a comparative ("30% faster", "메모리 50% 줄었다"). "chips on 100% of cards" is a count.
 */
const LATENCY_CLAIM = /\d+(?:\.\d+)?\s*ms\b/i;
/** An ms figure beside one of these is a configured value ("debounce 300ms"), not a speed claim. */
const SETTING_CONTEXT = /(timeout|debounce|throttle|interval|delay|ttl|backoff|retry|poll|타임아웃|디바운스|간격|지연 시간|대기 시간|주기|재시도)/i;
const PERCENT_FIGURE = /\d+(?:\.\d+)?\s*%/;
const COMPARATIVES = Object.freeze({
  en: /(faster|slower|reduc|improv|less|fewer|more|speed|shrink|cut)/i,
  ko: /(빨라|빠르|느려|줄(었|어|인|임)|절감|감소|증가|향상|개선|단축)/,
});
const MEASUREMENT_EVIDENCE = Object.freeze({
  en: /(measured|benchmark|lighthouse|profil)/i,
  ko: /(측정|계측|벤치)/,
});
/** A trade-off topic that admits no comparison was made. */
const SINGLE_APPROACH = Object.freeze({
  en: /single approach|no alternatives?\b/i,
  ko: /단일 접근|대안 없음/,
});

function anyLocale(table, text) {
  return Object.values(table).some((re) => re.test(text));
}

function collapse(text) {
  return String(text ?? '')
    .replace(/\s+/g, ' ')
    .trim();
}

/** `tradeoffs[2].cost` → `tradeoffs.cost`; `known_gaps[0]` → `known_gaps`. */
function limitKey(field) {
  return String(field).replace(/\[\d+\]/g, '');
}

function endsWithPrefix(before, prefix) {
  if (!before.endsWith(prefix)) return false;
  if (!prefix.endsWith(' ')) return true;
  const at = before.length - prefix.length;
  return at === 0 || /\s/.test(before[at - 1]);
}

/** True when the occurrence at `idx` is negated by its own locale (prefix before or suffix after). */
function isNegated(lowered, idx, len, locale) {
  const before = lowered.slice(0, idx);
  if ((NEGATING_PREFIXES[locale] ?? []).some((prefix) => endsWithPrefix(before, prefix))) return true;
  const after = lowered.slice(idx + len, idx + len + 24);
  return (NEGATING_SUFFIXES[locale] ?? []).some((re) => re.test(after));
}

function findHype(text) {
  let lowered = collapse(text).toLowerCase();
  for (const phrase of Object.values(HYPE_TERM_OF_ART).flat()) lowered = lowered.split(phrase).join(' ');
  return Object.entries(HYPE_TERMS).flatMap(([locale, terms]) =>
    terms.filter((term) => {
      const t = term.toLowerCase();
      for (let idx = lowered.indexOf(t); idx !== -1; idx = lowered.indexOf(t, idx + t.length)) {
        if (!isNegated(lowered, idx, t.length, locale)) return true;
      }
      return false;
    }),
  );
}

function findEmptyPhrases(text) {
  const flat = collapse(text).toLowerCase();
  return Object.values(EMPTY_PHRASES)
    .flat()
    .filter((phrase) => flat.includes(phrase.toLowerCase()));
}

function findLocators(text) {
  const flat = collapse(text);
  return INTERNAL_LOCATOR_PATTERNS.map((re) => flat.match(re)?.[0]).filter(Boolean);
}

function hasUnbackedMeasurement(text) {
  const flat = collapse(text);
  if (anyLocale(MEASUREMENT_EVIDENCE, flat)) return false;
  const latency = LATENCY_CLAIM.test(flat) && !SETTING_CONTEXT.test(flat);
  return latency || (PERCENT_FIGURE.test(flat) && anyLocale(COMPARATIVES, flat));
}

function isNonAnswer(text) {
  const flat = collapse(text).toLowerCase().replace(/[.。!]+$/, '');
  return Object.values(NON_ANSWERS).some((list) => list.includes(flat));
}

const list = (items) => items.map((x) => `"${x}"`).join(', ');

/**
 * Word-level rules, each `(key, text) => message | null`. `key` is the field with indices
 * stripped (`tradeoffs.cost`); the caller prefixes `narrative.<field>: `.
 */
const PROSE_RULES = [
  (key, text) => {
    const limit = SHIP_BRIEF_LIMITS[key];
    const len = collapse(text).length;
    return limit && len > limit ? `${len} chars > ${limit} limit — cut, do not compress` : null;
  },
  (key, text) =>
    PLACEHOLDER.test(collapse(text)) ? `"${collapse(text)}" is a template placeholder — write the answer` : null,
  (key, text) => {
    const hype = HYPE_EXEMPT_FIELDS.test(key) ? [] : findHype(text);
    return hype.length ? `hype word(s) ${list(hype)} — state what a reviewer can verify instead` : null;
  },
  (key, text) => {
    const empty = findEmptyPhrases(text);
    return empty.length ? `empty phrase(s) ${list(empty)} — say what changed for the reader` : null;
  },
  (key, text) => {
    const found = LOCATOR_ALLOWED.test(key) ? [] : findLocators(text);
    return found.length
      ? `internal locator(s) ${list(found)} — meaningless outside this session; describe the thing, not its label`
      : null;
  },
  (key, text) =>
    hasUnbackedMeasurement(text)
      ? 'performance number without how it was measured — add "(measured: …)" / "(측정: …)" or drop the number'
      : null,
  (key, text) =>
    SELF_CRITIQUE_FIELDS.test(key) && isNonAnswer(text)
      ? `"${collapse(text)}" is a non-answer — this field exists so you have to think`
      : null,
];

/** Word-level rules for one prose field (field label as produced by collectProseFields). */
function proseErrors(field, text) {
  if (!text) return [];
  const key = limitKey(field);
  if (SHIP_HIDDEN_FIELDS.test(key)) return [];
  return PROSE_RULES.map((rule) => rule(key, text))
    .filter(Boolean)
    .map((message) => `narrative.${field}: ${message}`);
}

/**
 * Splits one whitespace token into a path core and whatever hangs off it: brackets, quotes,
 * punctuation, and Korean / Japanese particles written without a space (`build.mjs의`,
 * `build.mjsの` → core `build.mjs`). Returns null when the core does not look like a path.
 */
export function splitPathMention(token) {
  const m = String(token).match(/^([(\['"`]*)(.*?)([가-힣ぁ-ゖ]*[,.;:)\]'"`]*)$/);
  if (!m) return null;
  const core = m[2];
  if (!core || !(core.includes('/') || /\.[a-z0-9]{1,6}$/i.test(core))) return null;
  return { lead: m[1], core, rest: m[3] };
}

/**
 * Path-looking tokens inside free text: `the chip loop in scripts/build.mjs,` →
 * ['scripts/build.mjs']. Particles and punctuation stripped. Bare words are not paths.
 */
export function extractPathTokens(text) {
  return collapse(text)
    .split(' ')
    .map((tok) => splitPathMention(tok)?.core)
    .filter(Boolean);
}

function countErrors(field, list, { min, max }) {
  const n = Array.isArray(list) ? list.length : 0;
  if (n < min) return `narrative.${field}: at least ${min} item(s) required — an honest "none" does not exist here`;
  if (n > max) return `narrative.${field}: ${n} items > ${max} — keep the ones a reviewer would act on`;
  return null;
}

function diagramErrors(diagram) {
  if (!diagram) return [];
  const errors = [];
  if (!DIAGRAM_KINDS.includes(diagram.kind)) {
    errors.push(`narrative.diagram.kind: "${diagram.kind}" — expected ${DIAGRAM_KINDS.join(' | ')}`);
    return errors;
  }
  if (diagram.kind === 'flow') {
    errors.push(countErrors('diagram.steps', diagram.steps, SHIP_BRIEF_COUNTS['diagram.steps']));
    (diagram.steps ?? []).forEach((st, i) => {
      if (!st.label) errors.push(`narrative.diagram.steps[${i}].label: required`);
      if (st.state && !DIAGRAM_STEP_STATES.includes(st.state)) {
        errors.push(`narrative.diagram.steps[${i}].state: "${st.state}" — expected ${DIAGRAM_STEP_STATES.join(' | ')}`);
      }
    });
    if ((diagram.steps ?? []).length && !(diagram.steps ?? []).some((st) => st.state && st.state !== 'same')) {
      errors.push('narrative.diagram.steps: mark at least one step as changed | new | removed — a flow where nothing changed explains nothing');
    }
  } else {
    errors.push(countErrors('diagram.rows', diagram.rows, SHIP_BRIEF_COUNTS['diagram.rows']));
    (diagram.rows ?? []).forEach((r, i) => {
      if (!r.aspect || !r.before || !r.after) errors.push(`narrative.diagram.rows[${i}]: aspect / before / after all required`);
    });
  }
  return errors.filter(Boolean);
}

/**
 * `narrative.<prefix>.<snake>: required<hint>` for every blank field. `spec` rows are
 * [camelKey, snake_key, hint] — the message names the JSON (snake_case) field the author writes.
 */
function missingFieldErrors(prefix, entry, spec) {
  return spec.filter(([key]) => !entry[key]).map(([, snake, hint]) => `narrative.${prefix}.${snake}: required${hint}`);
}

const FAILURE_MODE_FIELDS = [
  ['scenario', 'scenario', ' — what goes wrong?'],
  ['whoNotices', 'who_notices', ' — who feels it first?'],
  ['detect', 'detect', ' — how would we find out (log, test, complaint, dashboard)?'],
  ['mitigation', 'mitigation', ' — what we do when it happens'],
];
const EXPOSURE_FIELDS = [
  ['who', 'who', ' — which users or systems see this'],
  ['howMany', 'how_many', ' — a number or a share (455 cards, all locales, 3 API consumers)'],
  ['when', 'when', ' — on merge, on Stage sign-off, behind a flag …'],
  ['reversible', 'reversible', ' — can it be taken back, how, how long'],
];
const DATA_CHANGE_FIELDS = [
  ['whatMoves', 'what_moves', ''],
  ['count', 'count', ' — how many records/files/consumers'],
  ['irreversible', 'irreversible', ' — name the part a revert does not undo, or say why every step is reversible'],
  ['order', 'order', ' — the sequence (backfill → code → cleanup) and where it can stop safely'],
  ['consumers', 'consumers', ' — who reads this data or contract'],
];
const TRADEOFF_FIELDS = [
  ['topic', 'topic', ' — what was being decided?'],
  ['cost', 'cost', ' — what does the chosen option give up? (a choice without a cost was not compared)'],
];
const REVIEW_FOCUS_FIELDS = [
  ['where', 'where', ' — a changed file or an area of the change'],
  ['check', 'check', ' — what should the reviewer verify there?'],
  ['riskIfWrong', 'risk_if_wrong', ' — what breaks for whom if this is wrong?'],
];

/** What breaks — the one section every tier must carry; production tiers need two scenarios. */
function failureModeErrors(failureModes, requires, tierNote) {
  const fm = failureModes ?? [];
  const min = Math.max(SHIP_BRIEF_COUNTS.failure_modes.min, requires.failureModesMin);
  const { max } = SHIP_BRIEF_COUNTS.failure_modes;
  const errors = [];
  if (fm.length < min) {
    errors.push(`narrative.failure_modes: at least ${min} scenario(s) required${tierNote} — what goes wrong, who notices first, how we would know, what we do then`);
  } else if (fm.length > max) {
    errors.push(`narrative.failure_modes: ${fm.length} items > ${max} — keep the ones a reviewer would act on`);
  }
  fm.forEach((f, i) => errors.push(...missingFieldErrors(`failure_modes[${i}]`, f, FAILURE_MODE_FIELDS)));
  return errors;
}

/** An object block the reach tier owes (exposure, data_change): absent = one error, partial = per field. */
function owedBlockErrors(owed, block, name, spec, absentHint) {
  if (!owed) return [];
  if (!block) return [`narrative.${name}: required${absentHint}`];
  return missingFieldErrors(name, block, spec);
}

/** Trade-offs — every choice has a cost, or it was not a choice. */
function tradeoffErrors(tradeoffs) {
  return (tradeoffs ?? []).flatMap((t, i) => {
    const errors = missingFieldErrors(`tradeoffs[${i}]`, t, TRADEOFF_FIELDS);
    if (anyLocale(SINGLE_APPROACH, collapse(t.topic))) {
      errors.push(`narrative.tradeoffs[${i}].topic: "single approach" is not accepted at ship — name the alternative you would have taken and why not`);
    }
    return errors;
  });
}

/** Review focus — where / what to check / what breaks if wrong. Every path mentioned must be real. */
function reviewFocusErrors(reviewFocus, changed) {
  return (reviewFocus ?? []).flatMap((f, i) => {
    const errors = missingFieldErrors(`review_focus[${i}]`, f, REVIEW_FOCUS_FIELDS);
    // One true path must not excuse a fabricated one beside it.
    const missing = extractPathTokens(f.where).filter((tok) => !changed.has(tok));
    if (missing.length) {
      errors.push(`narrative.review_focus[${i}].where: mentions ${missing.map((t) => `"${t}"`).join(', ')} but ${missing.length === 1 ? 'it is' : 'they are'} not in the changeset`);
    }
    return errors;
  });
}

/** snake_case list field → normalized (camelCase) narrative key. */
const BRIEF_LIST_KEYS = Object.freeze({
  review_focus: 'reviewFocus',
  known_gaps: 'knownGaps',
  tradeoffs: 'tradeoffs',
  out_of_scope: 'outOfScope',
});

/**
 * Validates the human-brief layer of a *normalized* ship narrative (review-narrative.mjs shape).
 * @param {object} narrative normalized narrative
 * @param {Set<string>} changed changed-path set from git
 * @param {object|null} reach change-reach.mjs#buildReach summary (null = local-tier rules)
 * @returns {string[]} error messages (empty = pass)
 */
export function validateShipBrief(narrative, changed = new Set(), reach = null) {
  if (!narrative || typeof narrative !== 'object') return ['narrative: brief validation needs a narrative'];
  const requires = reach?.requires ?? reachRequirements('local');
  const tierNote = reach ? ` (change reaches ${reach.label})` : '';
  const errors = [
    narrative.forWhom ? null : 'narrative.for_whom: required — who notices this change (user, reviewer, operator)?',
    ...['review_focus', 'known_gaps', 'tradeoffs', 'out_of_scope'].map((field) =>
      countErrors(field, narrative[BRIEF_LIST_KEYS[field]], SHIP_BRIEF_COUNTS[field]),
    ),
    ...failureModeErrors(narrative.failureModes, requires, tierNote),
    // Exposure once the change reaches what users see or what other systems read.
    ...owedBlockErrors(requires.exposure, narrative.exposure, 'exposure', EXPOSURE_FIELDS,
      `${tierNote} — who is exposed, how many, when, and whether it can be taken back`),
    // Data change when stored data or an external contract moves.
    ...owedBlockErrors(requires.dataChange, narrative.dataChange, 'data_change', DATA_CHANGE_FIELDS,
      `${tierNote} — what moves, how many records, what cannot be undone, in what order, who reads it`),
    // Structured diagram — optional, but when present it must be drawable.
    ...diagramErrors(narrative.diagram),
    ...tradeoffErrors(narrative.tradeoffs),
    ...reviewFocusErrors(narrative.reviewFocus, changed),
    // Word-level rules over every prose field, using the same enumeration as the glossary gate.
    ...collectProseFields(narrative).flatMap(({ field, text }) => proseErrors(field, text)),
  ];
  return errors.filter(Boolean);
}

/**
 * Narrative skeleton for `ship-deck.mjs --template`. Placeholders are deliberately invalid
 * (every `<...>` field trips the placeholder rule) so an unedited template cannot pass,
 * even after its optional blocks are deleted.
 */
export function shipNarrativeTemplate() {
  const L = SHIP_BRIEF_LIMITS;
  return {
    $how_to_write: [
      'The reader is an engineer who was not part of this work. The first screen must show how far the change reaches, what changed, for whom, why, what breaks if it is wrong, what was given up, and where to look.',
      'First run `node .claude/scripts/ship-deck.mjs --reach --worktree <path>` to see how far the change reaches. Local tooling only: one failure_modes entry is enough. Production screens or data: at least two failure_modes plus exposure. Data or contracts: data_change as well.',
      'Argue against yourself before writing: if this is wrong, who notices first? How would we find out? What else could we have done? What does the chosen option cost? What did we not do?',
      'The file list is not on the first screen. file_notes and requirements are optional and render as folded evidence when written. Spend the time on failure scenarios and trade-offs.',
      `Generation is rejected for hype words, internal identifiers (Section 8e.5, DEBT-123), activity-only empty phrases and placeholders ("none", "n/a"). Word lists cover: ${NARRATIVE_LOCALES.join(', ')}.`,
      `Character ceilings: ${JSON.stringify(L)}`,
    ],
    what: `<one sentence: what changed (max ${L.what} chars)>`,
    for_whom: `<who notices this change (max ${L.for_whom} chars)>`,
    why: `<the observed problem, including "why now" (max ${L.why} chars)>`,
    how: `<the approach in one or two sentences (max ${L.how} chars)>`,
    next: '<next step after merge>',
    rollback: `<command or procedure that undoes it (max ${L.rollback} chars)>`,
    failure_modes: [
      {
        scenario: '<what goes wrong: a concrete situation>',
        who_notices: '<who notices first (user, operator, the next AI session)>',
        detect: '<how we find out: test, log, dashboard, report>',
        mitigation: '<what we do then>',
      },
    ],
    exposure: {
      $when_required: 'Required when the change reaches production screens/behavior or data/contracts (check with --reach). Delete it for local tooling or pipeline-only changes.',
      who: '<who is exposed: user group or consuming system>',
      how_many: '<how many: count or share (455 cards, all 3 locales)>',
      when: '<from when: on merge, after staging sign-off, behind a flag>',
      reversible: '<can it be taken back: how, and how long it takes>',
    },
    data_change: {
      $when_required: 'Required only when the change reaches data/contracts (stored data, API payloads, schemas, host config). Delete it otherwise.',
      what_moves: '<which data or contract changes, and how>',
      count: '<how many records/files/consumers>',
      irreversible: '<the part a revert does not undo, or why every step is reversible>',
      order: '<the sequence (backfill → code → cleanup) and where it can stop safely>',
      consumers: '<who reads this data or contract>',
    },
    diagram: {
      $optional: 'Optional. Use flow when a sequence changed, before_after when a state changed. The renderer draws it; do not hand-write SVG.',
      kind: 'flow',
      title: '<diagram title>',
      steps: [
        { label: '<step>', note: '<one-line note>', state: 'same' },
        { label: '<changed step>', note: '<what is different>', state: 'changed' },
      ],
    },
    tradeoffs: [
      {
        topic: '<what was being decided>',
        chosen: '<what was chosen>',
        rejected: '<the alternative given up; "none" is not accepted>',
        why: '<why this one>',
        cost: '<what the chosen option costs; required, "none" is not accepted>',
      },
    ],
    review_focus: [
      {
        where: '<changed file path or area; a path must be in the changeset>',
        check: '<what the reviewer should verify there>',
        risk_if_wrong: '<what breaks for whom if this is wrong>',
      },
    ],
    known_gaps: ['<what was not done, known limits (at least one; "none" is not accepted)>'],
    out_of_scope: ['<what was deliberately left out>'],
    requirements: [
      {
        $optional: 'Optional. Write it for SPEC-driven work; it renders as folded evidence.',
        id: '<FR-...>',
        need: '<requirement>',
        why: '<rationale>',
        implementation: [{ path: '<changed file>', change: '<what was done in that file>' }],
        validation: '<how it was verified; test names and section pointers are allowed here>',
      },
    ],
    file_notes: [{ $optional: 'Optional. Paths must be in the changeset. Attached to the folded file tree.', path: '<changed file>', change: '<what>', reason: '<why>' }],
    affected_features: ['<affected feature label>'],
    glossary: [{ term: '<term used only in this document>', plain: '<one-line explanation>' }],
  };
}
