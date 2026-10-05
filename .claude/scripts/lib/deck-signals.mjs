/**
 * deck-signals.mjs — Review deck "where to look first" risk signal derivation (pure function, core layer)
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: As decks grow large (measured 174KB), humans must read top-to-bottom to locate risk signals.
 *       Unfilled warnings and mismatch alerts scattered through the body leave reviewers wondering "where should I look".
 *   (b) Gaps: Decks only displayed individual numeric tiles; unfilled/mismatch warnings were emitted piecemeal
 *       per section — no code existed to generate aggregate metrics (narrative coverage) or consolidated risk lists.
 *   (c) Simpler alternatives comparison: "Highlight warning colors in each section" still requires full reading.
 *       "AI writes summary prose" lacks machine verification (R-CM-024 spirit).
 *       Adopted: **Machine derivation** of signals from already-assembled deck model (zero AI re-authoring).
 *
 * Contract: `buildReviewSignals(model)` — model is the completed model assembled by review-deck-core / ship-deck-core.
 *   Never throws on partial inputs (`{}`), degrading honestly to unmeasured defaults.
 *
 * Prohibition on aggregate metric tiles: Change file counts, added/deleted lines, commit counts, progress percentages,
 *   and review budget statements are deprecated — they occupied prime screen real estate without aiding approval decisions.
 *   Only "what might be wrong" is retained.
 *
 * Boundary (R-CM-028): perspective1-only — same deployment isolation as deck assets (not deployed to scaffold).
 */

import { buildImpactMap } from './deck-impact.mjs';
import { SHIP_BRIEF_COUNTS } from './narrative-quality.mjs';

/** Risk sort weighting — uses same vocabulary as checklist severity (aligned with 3-Tier Quality Gate) */
export const RISK_ORDER = { critical: 0, major: 1, info: 2 };

/**
 * AI narrative channels per stage — denominator for narrative coverage.
 * `key` is normalized narrative field (review-narrative.mjs), `anchor` is deck section ID.
 */
const STORY_CHANNELS = [
  { key: 'what', label: 'What', anchor: 'story' },
  { key: 'why', label: 'Why', anchor: 'story' },
  { key: 'how', label: 'How', anchor: 'story' },
  { key: 'next', label: 'Next', anchor: 'story' },
  { key: 'tradeoffs', label: 'Trade-offs', anchor: 'tradeoffs' },
  { key: 'impact', label: 'Impact Summary', anchor: 'impact' },
];

const NARRATIVE_CHANNELS = {
  spec: [...STORY_CHANNELS, { key: 'regressionRisk', label: 'Regression Risk', anchor: 'impact' }],
  plan: [...STORY_CHANNELS, { key: 'regressionRisk', label: 'Regression Risk', anchor: 'impact' }],
  milestone: [
    ...STORY_CHANNELS,
    // Affected feature declaration is displayed side-by-side with machine ownership set in #impact-map
    { key: 'affectedFeatures', label: 'Affected Features', anchor: 'impact-map' },
    { key: 'regressionRisk', label: 'Regression Risk', anchor: 'impact' },
    { key: 'fileNotes', label: 'Per-File Change Notes', anchor: 'changes' },
  ],
  ui: STORY_CHANNELS,
  ship: [
    // Impact-first brief (ship-deck-render.mjs#renderBriefSection). List channels carry `count`:
    // they are coverage channels only while the gate requires ≥ 1 (SHIP_BRIEF_COUNTS is the SSOT).
    // `exposure` / `dataChange` are added per model by shipChannels() when the reach requires them.
    // requirements / file_notes / impact / regression_risk are optional at ship and never chips.
    { key: 'what', label: 'What', anchor: 'brief' },
    { key: 'forWhom', label: 'For whom', anchor: 'brief' },
    { key: 'why', label: 'Why', anchor: 'brief' },
    { key: 'how', label: 'How', anchor: 'brief' },
    { key: 'failureModes', label: 'What breaks', anchor: 'failures', count: 'failure_modes' },
    { key: 'tradeoffs', label: 'Chosen vs rejected', anchor: 'tradeoffs', count: 'tradeoffs' },
    { key: 'reviewFocus', label: 'Where to review', anchor: 'brief', count: 'review_focus' },
    { key: 'knownGaps', label: 'Known gaps', anchor: 'brief', count: 'known_gaps' },
    { key: 'outOfScope', label: 'Out of scope', anchor: 'brief', count: 'out_of_scope' },
    { key: 'rollback', label: 'Rollback', anchor: 'brief' },
  ].filter((channel) => !channel.count || (SHIP_BRIEF_COUNTS[channel.count]?.min ?? 1) > 0),
};

/** Ship channels for one model — reach decides whether exposure / data change are owed. */
function shipChannels(model) {
  const req = model?.reach?.requires;
  return [
    ...NARRATIVE_CHANNELS.ship,
    ...(req?.exposure ? [{ key: 'exposure', label: 'Exposure', anchor: 'exposure' }] : []),
    ...(req?.dataChange ? [{ key: 'dataChange', label: 'Data change', anchor: 'data-change' }] : []),
  ];
}

function isFilled(value) {
  if (Array.isArray(value)) return value.length > 0;
  if (value === null || value === undefined) return false;
  if (typeof value === 'object') return Object.values(value).some((v) => isFilled(v));
  return String(value).trim() !== '';
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

/** Narrative coverage — binary determination per channel. provided=0 if narrative is absent (0% honest indication) */
function buildCoverage(stage, narrative, model = null) {
  const channels = stage === 'ship' ? shipChannels(model) : (NARRATIVE_CHANNELS[stage] ?? NARRATIVE_CHANNELS.milestone);
  const missing = [];
  let provided = 0;
  for (const channel of channels) {
    if (narrative && isFilled(narrative[channel.key])) provided += 1;
    else missing.push({ key: channel.key, label: channel.label, anchor: channel.anchor });
  }
  const total = channels.length;
  return { provided, total, pct: total ? Math.round((provided / total) * 100) : 0, missing };
}

function risk(level, label, detail, anchor) {
  return { level, label, detail: String(detail ?? ''), anchor: anchor ?? null };
}

/** Narrative ↔ Machine set mismatches (DEBT-228 channel) — surfaces cross-check aggregate findings */
function unmatchedRisks(model) {
  const out = [];
  const pairs = [
    ['narrativeUnmatchedPaths', 'modified files', 'changes'],
    ['narrativeUnmatchedFrIds', 'requirement IDs', 'fr-map'],
    ['narrativeUnmatchedSpecDocs', 'specification documents', 'impact'],
  ];
  for (const [field, subject, anchor] of pairs) {
    const list = asArray(model[field]);
    if (list.length) {
      out.push(
        risk(
          'critical',
          `Narrative↔Actual mismatch (${list.length})`,
          `AI narrative references non-existent ${subject}: ${list.slice(0, 3).join(', ')}${list.length > 3 ? ' …' : ''}`,
          anchor,
        ),
      );
    }
  }
  return out;
}

/** Number of changed files lacking notes (file_notes) — warning in milestone, 0 in ship due to fail-closed requirement */
function fileNoteGapRisk(model) {
  const rows = asArray(model.nameStatusRows);
  if (!rows.length) return null;
  const noted = new Set(asArray(model.narrative?.fileNotes).map((n) => n.path));
  const gap = rows.filter((r) => !noted.has(r.path)).length;
  if (!gap) return null;
  return risk(
    'major',
    `Missing file notes (${gap}/${rows.length})`,
    'Files without notes are approved without understanding "what and why changed"',
    'changes',
  );
}

/** Test changes presence — warning if code changed but 0 test changes exist (machine-derived via path conventions) */
function testGapRisk(numstatRows) {
  const rows = asArray(numstatRows);
  if (!rows.length) return null;
  const isTest = (p) => /(^|\/)tests?\//.test(p) || /\.(test|spec)\.[a-z]+$/.test(p);
  if (rows.some((r) => isTest(r.path))) return null;
  return risk('major', '0 test changes', 'If logic has changed, a justification for absent tests is required', 'changes');
}

/** Changed files not linked to requirements — unlinked left-right signal on traceability map (ship only) */
function orphanImplementationRisk(model) {
  const rows = asArray(model.nameStatusRows);
  if (!rows.length) return null;
  const linked = new Set(
    asArray(model.narrative?.requirements).flatMap((r) =>
      asArray(r.implementation).map((i) => i.path),
    ),
  );
  if (!linked.size) return null; // Missing requirements handled by coverage channel
  const orphans = rows.filter((r) => !linked.has(r.path));
  if (!orphans.length) return null;
  return risk(
    'major',
    `Unlinked requirement changes (${orphans.length})`,
    `Changes pointing to no requirement: ${orphans.slice(0, 3).map((r) => r.path).join(', ')}${orphans.length > 3 ? ' …' : ''}`,
    'traceability',
  );
}

/**
 * Source quality risks — incomplete source documents cannot be evaluated regardless of deck quality.
 * Unwritten/TBD sections are critical, one-liner sections are major.
 * Skips if outline is absent (opt-in-by-presence).
 */
function outlineRisks(outlineSummary) {
  if (!outlineSummary || !outlineSummary.total) return [];
  const out = [];
  const dead = [...(outlineSummary.empty ?? []), ...(outlineSummary.placeholder ?? [])];
  if (dead.length) {
    out.push(
      risk(
        'critical',
        `Unwritten source sections (${dead.length}/${outlineSummary.total})`,
        `Sections with no content / TBD state preventing approval: ${dead.slice(0, 4).join(', ')}${dead.length > 4 ? ' …' : ''}`,
        'source-doc',
      ),
    );
  }
  const thin = outlineSummary.thin ?? [];
  if (thin.length) {
    out.push(
      risk(
        'major',
        `One-liner sections (${thin.length})`,
        `${thin.slice(0, 4).join(', ')}${thin.length > 4 ? ' …' : ''} — verify if content provides sufficient judgment basis`,
        'source-doc',
      ),
    );
  }
  return out;
}

/** Stage-specific risk signals (machine-derived) — excludes aggregate tiles */
const STAGE_RULES = {
  spec: (model) => [
    ...outlineRisks(model.outlineSummary),
    asArray(model.acceptance).length
      ? null
      : risk('critical', '0 acceptance criteria', 'SPEC without definition of done cannot be verified', 'acceptance'),
    asArray(model.frs).length
      ? null
      : risk('major', 'Requirements undetected', 'Machine could not find FR table/headings in SPEC', 'fr-map'),
    frNoteGapRisk(model),
  ],
  plan: (model) => [
    ...outlineRisks(model.outlineSummary),
    model.goal
      ? null
      : risk('critical', 'Goal undetected', 'Plan begins without a verifiable goal', 'plan-body'),
    asArray(model.items).length
      ? null
      : risk('critical', '0 check items', 'Definition of done is not defined', 'plan-body'),
  ],
  milestone: (model) => [
    ...outlineRisks(model.outlineSummary),
    testGapRisk(model.numstat),
    fileNoteGapRisk(model),
    asArray(model.untrackedPaths).length
      ? risk(
          'info',
          `Untracked new files (${asArray(model.untrackedPaths).length})`,
          'New uncommitted files — excluded from diff line count (honest disclosure)',
          'changes',
        )
      : null,
  ],
  ui: (model) => [
    ...outlineRisks(model.outlineSummary),
    asArray(model.screens).length
      ? null
      : risk('critical', '0 screen blocks', 'No screens to review', 'screens'),
    asArray(model.screens).some((s) => s.unclosed)
      ? risk('major', 'Unclosed blocks', 'Possible missing fences in wireframe md', 'screens')
      : null,
  ],
  ship: (model) => [testGapRisk(model.numstat), orphanImplementationRisk(model), ...reachRisks(model.reach)],
};

/**
 * Reach-derived warnings (ship only). The banner already says how far the change goes; these
 * chips exist for the two cases a reader should not have to infer: stored data / external
 * contracts moved, and the classification itself was a guess (no project reach map).
 */
function reachRisks(reach) {
  if (!reach) return [];
  const out = [];
  const data = reach.tiers?.find((t) => t.id === 'data');
  if (data?.touched) {
    out.push(
      risk(
        'major',
        `Data / contract surface changed (${data.files})`,
        `${data.paths.slice(0, 3).join(', ')}${data.paths.length > 3 ? ' …' : ''} — check that data_change names the part a revert does not undo`,
        'data-change',
      ),
    );
  }
  if (reach.source === 'builtin') {
    out.push(
      risk(
        'info',
        'Reach computed from builtin conventions',
        'No .claude/reach-map.json, so paths were classified by generic conventions — production paths may look local',
        'reach',
      ),
    );
  }
  return out;
}

/** Number of FRs lacking explanatory notes (fr_notes) — spec only */
function frNoteGapRisk(model) {
  const frs = asArray(model.frs);
  if (!frs.length) return null;
  const noted = new Set(asArray(model.narrative?.frNotes).map((n) => n.id));
  const gap = frs.filter((fr) => !noted.has(fr.id)).length;
  if (!gap) return null;
  return risk(
    'major',
    `Missing requirement notes (${gap}/${frs.length})`,
    'FR with only raw English SPEC cannot be evaluated by non-specialists',
    'fr-map',
  );
}

/**
 * Deck model -> Risk signals + Impact map.
 * @returns {{stage:string, coverage:object, risks:Array, impactMap:(object|null)}}
 */
export function buildReviewSignals(model = {}) {
  const stage = typeof model.stage === 'string' && STAGE_RULES[model.stage] ? model.stage : 'ship';
  const narrative = model.narrative ?? null;
  const coverage = buildCoverage(stage, narrative, model);
  const impactMap = deriveImpactMap(model);

  const risks = [
    narrative
      ? null
      : risk('critical', 'Complete absence of AI narrative', 'Deck containing only numbers and filenames is insufficient for review', 'story'),
    ...unmatchedRisks(model),
    ...STAGE_RULES[stage](model),
    ...impactRisks(impactMap),
  ]
    .filter(Boolean)
    .sort((a, b) => RISK_ORDER[a.level] - RISK_ORDER[b.level]);

  return { stage, coverage, risks, impactMap };
}

/**
 * Derives impact map for stages with change sets (milestone/ship).
 * Reviewers evaluate risk by "which features and contracts changed" rather than directory paths.
 */
function deriveImpactMap(model) {
  const hasChangeSet = asArray(model.nameStatusRows).length > 0 || asArray(model.numstat).length > 0;
  if (!hasChangeSet) return null;
  return buildImpactMap({
    numstat: model.numstat,
    nameStatusRows: model.nameStatusRows,
    featureIndex: model.featureIndex ?? null,
    narrative: model.narrative ?? null,
  });
}

/**
 * Impact scope risks — Contract surface modifications / AI affected feature declaration ↔ machine ownership set mismatches.
 */
function impactRisks(impactMap) {
  if (!impactMap) return [];
  const out = [];
  const changed = impactMap.contracts?.surfaces?.filter((s) => s.changed) ?? [];
  if (changed.length) {
    out.push(
      risk(
        'major',
        `Contract surface changed (${changed.length})`,
        `${changed.map((s) => s.label).join(' · ')} — behavior outside this PR will change`,
        'impact-map',
      ),
    );
  }
  const fi = impactMap.featureImpact;
  if (fi?.declaredOnly?.length) {
    out.push(
      risk(
        'major',
        `Affected feature declaration mismatch (${fi.declaredOnly.length})`,
        `AI declared affected features not in machine ownership set: ${fi.declaredOnly.join(', ')}`,
        'impact-map',
      ),
    );
  }
  return out;
}

/**
 * Requirement readiness matrix (render input for CP-SPEC).
 * Since SPEC phase lacks implementation files, displays readiness across 4 judgment criteria per FR.
 */
export function buildRequirementMatrix(model = {}) {
  const frs = asArray(model.frs);
  const noteById = new Map(asArray(model.narrative?.frNotes).map((n) => [n.id, n]));
  return {
    columns: ['Requirement', 'Why Needed', 'How Addressed', 'Acceptance Criteria'],
    rows: frs.map((fr) => {
      const note = noteById.get(fr.id) ?? null;
      return {
        label: fr.id,
        cells: [
          isFilled(note?.ko || note?.requirement || note?.description),
          isFilled(note?.why),
          isFilled(note?.how),
          isFilled(fr.acceptance),
        ],
      };
    }),
  };
}

/** Requirements <-> Implementation files linkage graph (trace map render input). */
export function buildTraceGraph(model = {}) {
  const requirements = asArray(model.narrative?.requirements);
  const changed = asArray(model.nameStatusRows).map((r) => r.path);
  const links = [];
  const nodes = requirements.map((r) => ({
    id: r.id,
    label: r.id,
    need: r.need ?? '',
    targets: asArray(r.implementation).map((i) => i.path),
  }));
  const targetSet = new Set();
  for (const node of nodes) {
    for (const path of node.targets) {
      targetSet.add(path);
      links.push({ from: node.id, to: path });
    }
  }
  const orphanFiles = changed.filter((p) => !targetSet.has(p));
  const files = [...new Set([...targetSet, ...orphanFiles])];
  return {
    nodes,
    files: files.map((path) => ({ path, orphan: !targetSet.has(path) })),
    links,
    emptyRequirements: nodes.filter((n) => !n.targets.length).map((n) => n.id),
  };
}
