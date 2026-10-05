/**
 * ship-deck-core.mjs — Pre-Ship Visual Review Deck data model (pure functions).
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Large worktree Pre-Ship Human Review Panels (full-panel prose) induce
 *       cognitive fatigue, reducing human review to a formality.
 *   (b) Gap addressed: Pre-ship visual review assets were absent in-repo — `.cli/lib/worktree-ship-report.mjs`
 *       generated text templates only.
 *   (c) Alternative comparison: Chat-only checklists lack visual cues and slug-anchor feedback.
 *       Adopting in-repo native pure functions + renderer + minimal bridge.
 *
 * Design Rule: Explanations required for human judgment are derived from a common
 * narrative SSOT, and file/requirement paths are cross-referenced against actual git changesets.
 * LOC/commits/gates/evidence serve as deck trigger and pre-validation data, not the primary review text.
 * Word-level quality (length, hype, empty phrases, self-critique fields) is judged by
 * narrative-quality.mjs — presence + path checks alone shipped an unreadable deck on 2026-09-17.
 *
 * Boundary (R-CM-028): perspective1-only — R-CM-030 Rule 12 consumption only.
 */

// Gate signal/verdict enum SSOT — shared with quality-gate.json PROOF contract
import { buildReviewSignals, buildTraceGraph } from './deck-signals.mjs';
import { buildReach } from './change-reach.mjs';
import { normalizeNarrative } from './review-narrative.mjs';
import { validateShipBrief } from './narrative-quality.mjs';
import {
  collectProseFields,
  evaluatePlainLanguage,
  findRedundantNarrativeGlossary,
  formatPlainLanguageViolations,
  formatRedundantGlossaryEntries,
  withNarrativeGlossary,
} from './plain-language.mjs';

/** Scale evaluation thresholds (AI default — shared adjustment policy with R-CM-030 Rule 10) */
export const SCALE_THRESHOLDS = {
  largeFiles: 10,
  largeLoc: 300,
  smallFiles: 3,
  smallLoc: 50,
};

/** Decision request ceiling — too many approval questions dilute prioritization. */
export const CHECKLIST_MAX_ITEMS = 12;

const HTML_ESCAPES = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

export function escapeHtml(value) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch]);
}

/**
 * Normalizes git numstat rename notations (`dir/{old => new}/f.mjs`, `old.mjs => new.mjs`)
 * to the post-rename path.
 */
export function normalizeRenamePath(path) {
  const raw = String(path || '');
  if (!raw.includes('=>')) return raw;
  const braced = raw.replace(/\{([^{}]*)\s=>\s([^{}]*)\}/g, (_m, _from, to) => to);
  if (braced !== raw) return braced.replace(/\/{2,}/g, '/');
  const idx = raw.lastIndexOf('=>');
  return raw.slice(idx + 2).trim();
}

/**
 * Parses `git diff --numstat` output.
 * - Binary files (`-\t-\tpath`) have null added/deleted values
 * - Non-tab lines (warnings/meta) are excluded
 */
export function parseNumstat(text) {
  if (!text || typeof text !== 'string') return [];
  return text
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+$/, ''))
    .filter(Boolean)
    .map((line) => {
      const cols = line.split('\t');
      if (cols.length < 3) return null;
      const [addedRaw, deletedRaw, ...pathCols] = cols;
      const path = normalizeRenamePath(pathCols.join('\t').trim());
      if (!path) return null;
      const added = addedRaw.trim() === '-' ? null : Number.parseInt(addedRaw, 10);
      const deleted = deletedRaw.trim() === '-' ? null : Number.parseInt(deletedRaw, 10);
      if (added !== null && Number.isNaN(added)) return null;
      if (deleted !== null && Number.isNaN(deleted)) return null;
      return { path, added, deleted };
    })
    .filter(Boolean);
}

function sortTreeNodes(a, b) {
  if (a.type !== b.type) return a.type === 'directory' ? -1 : 1;
  return a.name.localeCompare(b.name);
}

/** Converts list of modified paths into a directory-first file tree model. */
export function buildFileTree(nameStatusRows) {
  const root = { children: [], childMap: new Map() };
  for (const row of Array.isArray(nameStatusRows) ? nameStatusRows : []) {
    if (!row?.path) continue;
    const parts = String(row.path).split('/').filter(Boolean);
    if (!parts.length) continue;
    let parent = root;
    const pathParts = [];
    parts.forEach((name, index) => {
      pathParts.push(name);
      const path = pathParts.join('/');
      const isFile = index === parts.length - 1;
      let node = parent.childMap.get(name);
      if (!node) {
        node = isFile
          ? { name, path, type: 'file', kind: row.kind || 'EDIT' }
          : { name, path, type: 'directory', children: [], childMap: new Map() };
        parent.childMap.set(name, node);
        parent.children.push(node);
      }
      if (!isFile) parent = node;
    });
  }

  function finalize(nodes) {
    return nodes.sort(sortTreeNodes).map((node) => {
      if (node.type === 'file') return node;
      return { name: node.name, path: node.path, type: 'directory', children: finalize(node.children) };
    });
  }
  return finalize(root.children);
}

/** Classifies scale — Large: files ≥ 10 OR LOC(±) ≥ 300 */
export function classifyScale({ files = 0, loc = 0 } = {}) {
  const t = SCALE_THRESHOLDS;
  if (files >= t.largeFiles || loc >= t.largeLoc) {
    return {
      scale: 'large',
      label: 'Large',
      reason: `Files ${files} / LOC ${loc} — reached large threshold (files ≥ ${t.largeFiles} OR LOC ≥ ${t.largeLoc})`,
    };
  }
  if (files <= t.smallFiles && loc <= t.smallLoc) {
    return {
      scale: 'small',
      label: 'Small',
      reason: `Files ${files} / LOC ${loc} — within small baseline (files ≤ ${t.smallFiles} AND LOC ≤ ${t.smallLoc})`,
    };
  }
  return { scale: 'medium', label: 'Medium', reason: `Files ${files} / LOC ${loc} — medium scale` };
}

/**
 * Unicode slugification — preserves letters and numbers.
 * Capped at 80 characters to prevent ENAMETOOLONG when used as directory segments.
 */
export function slugify(text, fallback = 'item') {
  const normalized = String(text || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '');
  const slug = Array.from(normalized).slice(0, 80).join('').replace(/-+$/g, '');
  return slug || fallback;
}

/** Checklist severity levels */
export const CHECKLIST_SEVERITIES = new Set(['critical', 'major', 'info']);
const SEVERITY_ORDER = { critical: 0, major: 1, info: 2 };
export const DEFAULT_CHECKLIST_SEVERITY = 'major';

function normalizeChecklistItem(raw, i, seen) {
  if (!raw || typeof raw !== 'object') return null;
  const label = String(raw.label || '').trim();
  if (!label) return null;
  let slug = String(raw.slug || '').trim() || slugify(label, `item-${i + 1}`);
  if (seen.has(slug)) {
    let n = 2;
    while (seen.has(`${slug}-${n}`)) n += 1;
    slug = `${slug}-${n}`;
  }
  seen.add(slug);
  return {
    slug,
    label,
    desc: String(raw.desc || '').trim(),
    passWhen: String(raw.passWhen || raw.pass_when || '').trim(),
    evidence: String(raw.evidence || '').trim(),
    severity: CHECKLIST_SEVERITIES.has(raw.severity) ? raw.severity : DEFAULT_CHECKLIST_SEVERITY,
    order: i,
  };
}

export function normalizeChecklist(items) {
  const seen = new Set();
  const out = (Array.isArray(items) ? items : [])
    .map((raw, i) => normalizeChecklistItem(raw, i, seen))
    .filter(Boolean);
  return out
    .sort((a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity] || a.order - b.order)
    .slice(0, CHECKLIST_MAX_ITEMS)
    .map((item) => ({
      slug: item.slug,
      label: item.label,
      desc: item.desc,
      passWhen: item.passWhen,
      evidence: item.evidence,
      severity: item.severity,
    }));
}

function truncateText(text, max = 60) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  if (!s) return '';
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

function goalChecklistItem(planGoal) {
  const goalHint = truncateText(planGoal);
  return goalHint
    ? {
        slug: 'goal-diff-match',
        label: 'Goal Alignment',
        desc: `Are there changes outside the PLAN goal ("${goalHint}")?`,
        passWhen: 'All rows in the impact matrix are accounted for by the goal (0 unexplained areas)',
        evidence: 'impact-map',
        severity: 'major',
      }
    : {
        slug: 'goal-diff-match',
        label: 'Goal Missing',
        desc: 'Missing PLAN.md Goal — verify the purpose of this change before proceeding',
        severity: 'critical',
      };
}

function testChecklistItem(numstatRows) {
  const rows = Array.isArray(numstatRows) ? numstatRows : [];
  const hasTestChange = rows.some(
    (r) => /(^|\/)tests?\//.test(r.path) || /\.(test|spec)\.[a-z]+$/.test(r.path),
  );
  return hasTestChange
    ? {
        slug: 'test-coverage',
        label: 'Test Coverage',
        desc: 'Are test changes present for new/modified logic (Google Review Axis: Tests)',
        passWhen: 'Every new branch has tests with Red→Green verification evidence',
        evidence: 'changes',
        severity: 'major',
      }
    : {
        slug: 'test-coverage',
        label: 'Zero Test Changes',
        desc: 'Code changes exist with 0 test changes — verify if proceeding without tests is acceptable',
        severity: 'critical',
      };
}

/**
 * Google eng-practices review axis checklist items (Design / Complexity / Documentation).
 * Reference: https://google.github.io/eng-practices/review/reviewer/looking-for.html
 */
const GOOGLE_AXIS_ITEMS = [
  {
    slug: 'design-fit',
    label: 'Design Fit',
    desc: 'Does this change fit cleanly into the codebase and integrate with existing structures? (Google Axis: Design)',
    passWhen: 'New modules/boundaries follow existing architectural conventions without duplicate layers',
    evidence: 'changes',
    severity: 'major',
  },
  {
    slug: 'complexity-check',
    label: 'Unnecessary Complexity',
    desc: 'Is the solution over-engineered for hypothetical future needs? (Google Axis: Complexity)',
    passWhen: 'Implements only what is needed now — 0 unused abstractions or configuration switches',
    evidence: 'tradeoffs',
    severity: 'major',
  },
  {
    slug: 'docs-sync',
    label: 'Documentation Sync',
    desc: 'If user-facing behavior or contracts changed, are corresponding docs included? (Google Axis: Documentation)',
    passWhen: 'Every contract change (flags, schemas, rules) has corresponding doc changes in the same changeset',
    evidence: 'impact',
    severity: 'major',
  },
];

/** Derives default checklist for stage review decks. */
export function buildDefaultChecklist({ planGoal = null, numstatRows = [] } = {}) {
  const items = [
    goalChecklistItem(planGoal),
    testChecklistItem(numstatRows),
    ...GOOGLE_AXIS_ITEMS,
  ].filter(Boolean);
  return normalizeChecklist(items);
}

/** Extracts `## Goal` section content from PLAN.md */
export function extractPlanGoal(planText) {
  if (!planText || typeof planText !== 'string') return null;
  const lines = planText.split(/\r?\n/);
  const start = lines.findIndex((l) => /^##\s*Goal\b/.test(l.trim()));
  if (start === -1) return null;
  const body = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^##\s/.test(lines[i].trim())) break;
    body.push(lines[i]);
  }
  const text = body.join('\n').trim();
  return text || null;
}

function toStringOrNull(value) {
  if (value === null || value === undefined) return null;
  const s = String(value);
  return s || null;
}

function normalizeCommits(commits) {
  return (Array.isArray(commits) ? commits : []).map((c) => String(c)).filter(Boolean);
}

function buildStats(numstat, commitCount) {
  const added = numstat.reduce((s, r) => s + (r.added ?? 0), 0);
  const deleted = numstat.reduce((s, r) => s + (r.deleted ?? 0), 0);
  return { files: numstat.length, added, deleted, loc: added + deleted, commits: commitCount };
}

function changedPathSet(nameStatusRows) {
  return new Set(
    (Array.isArray(nameStatusRows) ? nameStatusRows : [])
      .map((row) => String(row?.path || '').trim())
      .filter(Boolean),
  );
}

/**
 * Presence of the story fields. `impact` / `regression_risk` stopped being required on 2026-09-18:
 * the impact-first brief carries `failure_modes` / `exposure` instead (narrative-quality.mjs);
 * the old fields render under folded evidence when present.
 */
function validateRequiredNarrativeFields(narrative) {
  const errors = [];
  for (const field of ['what', 'why', 'how', 'rollback']) {
    if (!narrative[field]) errors.push(`narrative.${field}: required description missing`);
  }
  if (!narrative.tradeoffs.length) errors.push('narrative.tradeoffs: at least 1 item required');
  return errors;
}

/**
 * File notes are optional at ship (2026-09-18 — "people do not read file lists anyway"). When given they
 * must still be true: every path in the changeset, change + reason filled.
 */
function validateFileNotes(narrative, changed) {
  const errors = [];
  for (const note of narrative.fileNotes) {
    if (!changed.has(note.path)) errors.push(`narrative.file_notes: path not in actual changeset — ${note.path}`);
    if (!note.change || !note.reason) errors.push(`narrative.file_notes: change/reason required — ${note.path}`);
  }
  return errors;
}

function validateRequirements(narrative, changed) {
  const errors = [];
  for (const requirement of narrative.requirements) {
    if (!requirement.need || !requirement.why || !requirement.validation) {
      errors.push(`narrative.requirements: need/why/validation required — ${requirement.id}`);
    }
    if (!requirement.implementation.length) {
      errors.push(`narrative.requirements: at least 1 implementation required — ${requirement.id}`);
    }
    for (const implementation of requirement.implementation) {
      if (!changed.has(implementation.path)) {
        errors.push(`narrative.requirements: implementation path not in actual changeset — ${implementation.path}`);
      }
      if (!implementation.change) errors.push(`narrative.requirements: implementation.change required — ${requirement.id}`);
    }
  }
  return errors;
}

function validateChoices(narrative) {
  const errors = [];
  for (const tradeoff of narrative.tradeoffs) {
    if (!tradeoff.chosen || !tradeoff.rejected || !tradeoff.why) {
      errors.push(`narrative.tradeoffs: chosen/rejected/why required — ${tradeoff.topic}`);
    }
  }
  return errors;
}

function validatePlainLanguage(narrative, lexicon) {
  if (!lexicon) return [];
  const { violations } = evaluatePlainLanguage(
    collectProseFields(narrative),
    withNarrativeGlossary(lexicon, narrative),
  );
  return [
    ...formatPlainLanguageViolations(violations),
    ...formatRedundantGlossaryEntries(findRedundantNarrativeGlossary(narrative, lexicon)),
  ];
}

/**
 * @param {object} rawNarrative snake_case narrative JSON
 * @param {Array} nameStatusRows git name-status rows
 * @param {object|null} lexicon plain-language lexicon (null = skip)
 * @param {{reach?: object, reachMap?: object}} [options] reach summary (or a map to derive it) — decides
 *   which impact fields are mandatory. Omitted = local tier rules.
 */
export function validateShipReviewNarrative(rawNarrative, nameStatusRows, lexicon = null, options = {}) {
  const narrative = normalizeNarrative(rawNarrative);
  if (!narrative) return ['narrative: --narrative-json required'];
  const changed = changedPathSet(nameStatusRows);
  const reach =
    options.reach ?? (options.reachMap ? buildReach({ nameStatusRows, map: options.reachMap }) : null);
  return [
    ...validateRequiredNarrativeFields(narrative),
    ...validateFileNotes(narrative, changed),
    ...validateRequirements(narrative, changed),
    ...validateChoices(narrative),
    ...validateShipBrief(narrative, changed, reach),
    ...validatePlainLanguage(narrative, lexicon),
  ];
}

/**
 * Assembles the ship deck data model (renderer input contract).
 */
export function buildDeckModel(input = {}) {
  const numstat = parseNumstat(input.numstatText);
  const commits = normalizeCommits(input.commits);
  const stats = buildStats(numstat, commits.length);
  const planGoal = toStringOrNull(input.planGoal);
  const nameStatusRows = Array.isArray(input.nameStatusRows) ? input.nameStatusRows : [];
  const narrative = normalizeNarrative(input.narrative);
  const lexicon = input.lexicon ?? null;
  const reach = buildReach({ nameStatusRows, numstat, map: input.reachMap ?? null });
  const plainLanguage =
    lexicon && narrative
      ? evaluatePlainLanguage(
          collectProseFields(narrative),
          withNarrativeGlossary(lexicon, narrative),
        )
      : { matches: [], violations: [] };
  const model = {
    stage: 'ship',
    branch: toStringOrNull(input.branch) ?? '(unknown)',
    baseRef: toStringOrNull(input.baseRef) ?? 'origin/main',
    generatedAt: toStringOrNull(input.generatedAt),
    commits,
    numstat,
    nameStatusRows,
    fileTree: buildFileTree(nameStatusRows),
    stats,
    scale: classifyScale({ files: stats.files, loc: stats.loc }),
    planGoal,
    narrative,
    reach,
    narrativeErrors: [
      ...validateShipReviewNarrative(input.narrative, nameStatusRows, null, { reach }),
      ...formatPlainLanguageViolations(plainLanguage.violations),
      ...(lexicon && narrative
        ? formatRedundantGlossaryEntries(findRedundantNarrativeGlossary(narrative, lexicon))
        : []),
    ],
    glossary: plainLanguage.matches,
    panelMarkdown: toStringOrNull(input.panelMarkdown),
    origin: input.origin ?? null,
    featureIndex: input.featureIndex ?? null,
    diagramSvg: toStringOrNull(input.diagramSvg),
  };
  return { ...model, signals: buildReviewSignals(model), traceGraph: buildTraceGraph(model) };
}
