/**
 * review-narrative.mjs — Human explanation contract SSOT shared by stage/ship review decks.
 *
 * Machine diffs prove "what changed" but cannot create "why is it needed / why this choice /
 * what must humans decide". Without mixing the two layers, AI-authored narratives are normalized
 * once and consumed by purpose-specific renderers.
 *
 * Boundary (R-CM-028): perspective1-only. Not deployed to scaffold targets.
 */


function trimField(value) {
  return String(value || '').trim();
}

function normalizeStringList(list) {
  return (Array.isArray(list) ? list : []).map((value) => trimField(value)).filter(Boolean);
}

/**
 * `keepPartial`: keep an entry whose key field is blank as long as *some* field has text, so the
 * validator can say "topic required" instead of the item vanishing before anyone sees it
 * (code review of PR #76 / fix branch, 2026-09-18). Default stays strict for glossary / api / spec
 * entries whose consumers index by the key.
 */
function normalizeEntryList(list, keyField, fields, { keepPartial = false } = {}) {
  return (Array.isArray(list) ? list : [])
    .map((entry) => {
      if (!entry || typeof entry !== 'object') return null;
      const out = {};
      for (const field of fields) out[field] = trimField(entry[field]);
      if (trimField(entry[keyField])) return out;
      return keepPartial && fields.some((field) => out[field]) ? out : null;
    })
    .filter(Boolean);
}
const PARTIAL = { keepPartial: true };

/** Flat object → trimmed fields, or null when every field is blank. */
function normalizeObject(input, fields) {
  if (!input || typeof input !== 'object') return null;
  const out = {};
  for (const [snake, camel] of fields) out[camel] = trimField(input[snake]);
  return Object.values(out).some(Boolean) ? out : null;
}

/**
 * Structured diagram the renderer draws itself (no external library, no AI-drawn SVG to trust):
 *   { kind: 'flow', title, steps: [{ label, note?, state?: 'same'|'changed'|'new'|'removed' }] }
 *   { kind: 'before_after', title, rows: [{ aspect, before, after }] }
 * Kept as authored (validation happens in narrative-quality.mjs); only strings are trimmed.
 */
function normalizeDiagram(input) {
  if (!input || typeof input !== 'object') return null;
  const kind = trimField(input.kind);
  const out = {
    kind,
    title: trimField(input.title),
    steps: normalizeEntryList(input.steps, 'label', ['label', 'note', 'state'], PARTIAL),
    rows: normalizeEntryList(input.rows, 'aspect', ['aspect', 'before', 'after'], PARTIAL),
  };
  return kind || out.title || out.steps.length || out.rows.length ? out : null;
}

function normalizeRequirements(requirements) {
  return (Array.isArray(requirements) ? requirements : [])
    .map((entry) => {
      if (!entry || typeof entry !== 'object' || !trimField(entry.id)) return null;
      return {
        id: trimField(entry.id),
        need: trimField(entry.need),
        why: trimField(entry.why),
        implementation: normalizeEntryList(entry.implementation, 'path', ['path', 'change'], PARTIAL),
        validation: trimField(entry.validation),
      };
    })
    .filter(Boolean);
}

/**
 * Normalizes narrative JSON (snake_case) to renderer model (camelCase).
 * Preserves legacy stage fields alongside ship decision fields so both CLIs share the same semantic contract.
 */
export function normalizeNarrative(input) {
  if (!input || typeof input !== 'object') return null;
  const normalized = {
    what: trimField(input.what),
    why: trimField(input.why),
    how: trimField(input.how),
    next: trimField(input.next),
    impact: trimField(input.impact),
    regressionRisk: trimField(input.regression_risk),
    rollback: trimField(input.rollback),
    // Human brief layer (2026-09-18) — who notices, where to look, what was left undone.
    forWhom: trimField(input.for_whom),
    reviewFocus: normalizeEntryList(input.review_focus, 'where', ['where', 'check', 'risk_if_wrong'], PARTIAL).map(
      (entry) => ({ where: entry.where, check: entry.check, riskIfWrong: entry.risk_if_wrong }),
    ),
    knownGaps: normalizeStringList(input.known_gaps),
    // Impact-first layer (2026-09-18) — what breaks for whom, who is exposed, what data moves.
    failureModes: normalizeEntryList(
      input.failure_modes,
      'scenario',
      ['scenario', 'who_notices', 'detect', 'mitigation'],
      PARTIAL,
    ).map((e) => ({ scenario: e.scenario, whoNotices: e.who_notices, detect: e.detect, mitigation: e.mitigation })),
    exposure: normalizeObject(input.exposure, [
      ['who', 'who'],
      ['how_many', 'howMany'],
      ['when', 'when'],
      ['reversible', 'reversible'],
    ]),
    dataChange: normalizeObject(input.data_change, [
      ['what_moves', 'whatMoves'],
      ['count', 'count'],
      ['irreversible', 'irreversible'],
      ['order', 'order'],
      ['consumers', 'consumers'],
    ]),
    diagram: normalizeDiagram(input.diagram),
    outOfScope: normalizeStringList(input.out_of_scope),
    fileNotes: normalizeEntryList(input.file_notes, 'path', ['path', 'change', 'reason'], PARTIAL),
    frNotes: normalizeEntryList(input.fr_notes, 'id', ['id', 'ko', 'why', 'how']),
    requirements: normalizeRequirements(input.requirements),
    tradeoffs: normalizeEntryList(input.tradeoffs, 'topic', ['topic', 'chosen', 'rejected', 'why', 'cost'], PARTIAL),
    apiChanges: normalizeEntryList(input.api_changes, 'surface', [
      'surface',
      'before',
      'after',
      'compat',
    ]),
    specChanges: normalizeEntryList(input.spec_changes, 'doc', ['doc', 'change']),
    affectedFeatures: normalizeStringList(input.affected_features),
    // Deck-specific on-the-spot glossary — escape hatch for plain language contract (plain-language.mjs).
    // (review_decisions was retired per user decision on 2026-07-16 — decisions are unified into chat 3-way choices.
    //  review_decisions input in older narratives is ignored.)
    glossary: normalizeEntryList(input.glossary, 'term', ['term', 'plain']),
  };
  const hasContent = Object.values(normalized).some((value) =>
    Array.isArray(value) ? value.length > 0 : Boolean(value),
  );
  return hasContent ? normalized : null;
}
