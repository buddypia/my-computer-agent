/**
 * review-deck-core.mjs — Stage Review Deck data model (CP-SPEC / CP-PLAN / CP-MILESTONE / CP-UI, pure functions).
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Reviewing everything only after implementation is completed leads to delayed feedback and high remediation costs.
 *   (b) Gap addressed: ship-deck was exclusively for the ship stage (large worktrees only).
 *       The SPEC stage only had text-based SPEC.md, with 0 review checkpoints during implementation.
 *   (c) Alternative comparison: Running ship-deck mid-implementation could not handle SPEC stage (diff absence).
 *       Adopted: reuse ship-deck-core primitives + 2 stage models without additional render engines.
 *
 * Design Rule: FR maps / acceptance criteria / progress / heatmaps are mechanically generated
 * from SPEC.md, PLAN.md, and git diff without AI prose paraphrasing.
 *
 * Boundary (R-CM-028): perspective1-only — separate deployment from target scaffolds.
 */

import {
  buildDefaultChecklist,
  classifyScale,
  extractPlanGoal,
  normalizeChecklist,
  parseNumstat,
  slugify,
} from './ship-deck-core.mjs';
import {
  buildContractSurfaces,
  classificationPathOf,
  classifyChangeNature,
} from './deck-impact.mjs';
import { buildRequirementMatrix, buildReviewSignals } from './deck-signals.mjs';
import { orderSectionsForReview, parseDocumentOutline, summarizeOutline } from './doc-outline.mjs';
import { normalizeNarrative } from './review-narrative.mjs';

export { normalizeNarrative } from './review-narrative.mjs';

/** SPEC stage estimated scale thresholds */
export const SPEC_SCALE_THRESHOLDS = {
  largeFr: 8,
  largeTargetFiles: 10,
  largeScreens: 4,
  smallFr: 3,
  smallTargetFiles: 3,
  smallScreens: 1,
};

function truncateText(text, max = 80) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  if (!s) return '';
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

/**
 * Strips fenced code block (``` / ~~~) lines to prevent code examples from being misinterpreted as data.
 */
export function stripFencedBlocks(markdown) {
  if (!markdown || typeof markdown !== 'string') return [];
  const out = [];
  let fence = null;
  for (const line of markdown.split(/\r?\n/)) {
    const m = line.match(/^\s*(```+|~~~+)/);
    if (m) {
      if (!fence) fence = m[1][0];
      else if (m[1][0] === fence) fence = null;
      continue;
    }
    if (!fence) out.push(line);
  }
  return out;
}

/**
 * Extracts section body matching heading regex (up until next heading of equal/higher level).
 */
export function extractSection(markdown, headingRegex) {
  const lines = stripFencedBlocks(markdown);
  const start = lines.findIndex((l) => headingRegex.test(l.trim()));
  if (start === -1) return null;
  const levelMatch = lines[start].trim().match(/^(#+)/);
  const level = levelMatch ? levelMatch[1].length : 2;
  const body = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const heading = lines[i].trim().match(/^(#+)\s/);
    if (heading && heading[1].length <= level) break;
    body.push(lines[i]);
  }
  const text = body.join('\n').trim();
  return text || null;
}

/** Parses markdown table rows — excludes header row and separator (`---`), returns cell array */
export function parseTableRows(sectionText) {
  if (!sectionText || typeof sectionText !== 'string') return [];
  const rows = [];
  let headerSkipped = false;
  for (const raw of sectionText.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line.startsWith('|')) continue;
    const cells = line
      .split('|')
      .slice(1, -1)
      .map((c) => c.trim());
    if (!cells.length) continue;
    if (cells.every((c) => /^:?-{3,}:?$/.test(c))) continue;
    if (!headerSkipped) {
      headerSkipped = true;
      continue;
    }
    rows.push(cells);
  }
  return rows;
}

/** Extracts list items (`- `, `* `, `1.`) from section text */
export function parseListItems(sectionText) {
  if (!sectionText || typeof sectionText !== 'string') return [];
  return sectionText
    .split(/\r?\n/)
    .map((l) => l.match(/^\s*(?:[-*]|\d+[.)])\s+(.+)$/))
    .filter(Boolean)
    .map((m) => m[1].trim().replace(/^\[( |x|X)\]\s*/, ''))
    .filter(Boolean);
}

/** Per-file diff embedding limits */
export const DIFF_MAX_LINES_PER_FILE = 300;
export const DIFF_MAX_FILES = 40;

const QUOTED_SIMPLE_ESCAPES = { n: 10, t: 9, r: 13, '"': 34, '\\': 92, a: 7, b: 8, f: 12, v: 11 };

function pushUtf8Bytes(bytes, ch) {
  for (const b of Buffer.from(ch, 'utf8')) bytes.push(b);
}

/** Decodes octal (`\ooo`) or single-character escape into byte array */
function decodeQuotedEscape(inner, i, bytes) {
  if (inner[i + 1] >= '0' && inner[i + 1] <= '7') {
    let oct = '';
    while (oct.length < 3 && inner[i + 1] >= '0' && inner[i + 1] <= '7') {
      oct += inner[i + 1];
      i += 1;
    }
    bytes.push(parseInt(oct, 8) & 0xff);
    return i;
  }
  const mapped = QUOTED_SIMPLE_ESCAPES[inner[i + 1]];
  if (mapped != null) bytes.push(mapped);
  else pushUtf8Bytes(bytes, String(inner[i + 1] ?? ''));
  return i + 1;
}

/**
 * Unquotes C-style quoted git path (octal escapes decoded back to UTF-8).
 */
function unquoteGitPath(raw) {
  const s = String(raw ?? '');
  if (!(s.length >= 2 && s.startsWith('"') && s.endsWith('"'))) return s;
  const inner = s.slice(1, -1);
  const bytes = [];
  for (let i = 0; i < inner.length; i += 1) {
    if (inner[i] !== '\\') pushUtf8Bytes(bytes, inner[i]);
    else i = decodeQuotedEscape(inner, i, bytes);
  }
  return Buffer.from(bytes).toString('utf8');
}

/**
 * Extracts b-side path from `diff --git ` header remainder.
 */
function parseDiffHeaderPath(rest) {
  if (rest.endsWith('"')) {
    const quoted = rest.match(/"((?:[^"\\]|\\.)*)"$/);
    if (quoted) {
      const p = unquoteGitPath(`"${quoted[1]}"`);
      return p.startsWith('b/') ? p.slice(2) : p;
    }
  }
  const plain = rest.match(/^(?:a\/.+|"(?:[^"\\]|\\.)*") b\/(.+)$/);
  if (plain) return plain[1];
  return rest.trim();
}

/**
 * Splits unified diff text into per-file blocks.
 */
export function parseDiffFiles(diffText, { maxLinesPerFile = DIFF_MAX_LINES_PER_FILE } = {}) {
  if (!diffText || typeof diffText !== 'string') return [];
  const files = [];
  let current = null;
  for (const line of diffText.split(/\r?\n/)) {
    if (line.startsWith('diff --git ')) {
      if (current) files.push(current);
      current = {
        path: parseDiffHeaderPath(line.slice('diff --git '.length)),
        lines: [],
        truncated: false,
      };
      continue;
    }
    if (!current) continue;
    if (current.lines.length >= maxLinesPerFile) {
      current.truncated = true;
      continue;
    }
    current.lines.push(line);
  }
  if (current) files.push(current);
  return files.map((f) => ({ path: f.path, text: f.lines.join('\n'), truncated: f.truncated }));
}

/**
 * Synthesizes untracked file contents in diffFiles format (all lines prefixed with `+`).
 */
export function synthesizeUntrackedDiffFiles(
  untrackedFiles,
  { maxLinesPerFile = DIFF_MAX_LINES_PER_FILE } = {},
) {
  return (Array.isArray(untrackedFiles) ? untrackedFiles : [])
    .filter((f) => f && typeof f.path === 'string' && f.path.trim())
    .map((f) => {
      if (typeof f.content !== 'string') {
        return {
          path: f.path,
          text: '',
          truncated: false,
          untracked: true,
          lineCount: 0,
          unavailable: f.note || 'unreadable',
        };
      }
      const all = f.content.split(/\r?\n/);
      if (all.length && all[all.length - 1] === '') all.pop();
      const truncated = all.length > maxLinesPerFile;
      return {
        path: f.path,
        text: all
          .slice(0, maxLinesPerFile)
          .map((l) => `+${l}`)
          .join('\n'),
        truncated,
        untracked: true,
        lineCount: all.length,
      };
    });
}

const FR_ID_RE = /^FR-[A-Za-z0-9._-]+$/;

/** Collects FR entries: table rows or headings `### FR-xxx ...` */
function collectFrEntries(lines) {
  const frs = [];
  const seen = new Set();
  const pushFr = (fr) => {
    if (!seen.has(fr.id)) {
      seen.add(fr.id);
      frs.push(fr);
    }
  };
  for (const raw of lines) {
    const line = raw.trim();
    if (line.startsWith('|')) {
      const cells = line
        .split('|')
        .slice(1, -1)
        .map((c) => c.trim());
      if (cells.length && FR_ID_RE.test(cells[0])) {
        pushFr({ id: cells[0], requirement: cells[1] || '', acceptance: cells[2] || '' });
      }
      continue;
    }
    const h = line.match(/^#{2,4}\s+(FR-[A-Za-z0-9._-]+)\s*[:.\-]?\s*(.*)$/);
    if (h) pushFr({ id: h[1], requirement: h[2] || '', acceptance: '' });
  }
  return frs;
}

function countSectionEntries(sectionText) {
  if (!sectionText) return 0;
  return Math.max(parseTableRows(sectionText).length, parseListItems(sectionText).length);
}

function parseAcceptanceItems(sectionText) {
  const listItems = parseListItems(sectionText);
  if (listItems.length) return listItems;
  return parseTableRows(sectionText).map((cells) => cells.filter(Boolean).join(' · '));
}

/**
 * Mechanically parses SPEC.md structure.
 */
export function parseSpecStructure(specText) {
  const empty = {
    title: null,
    overview: null,
    frs: [],
    acceptance: [],
    targetFileCount: 0,
    screenCount: 0,
  };
  if (!specText || typeof specText !== 'string') return empty;

  const lines = stripFencedBlocks(specText);
  const titleLine = lines.find((l) => /^#\s+\S/.test(l.trim()));
  const title = titleLine ? titleLine.trim().replace(/^#\s+/, '').trim() : null;

  const overview =
    extractSection(specText, /^##\s*1\.?\s*(?:Overview|개요)/i) ??
    extractSection(specText, /^##\s*(?:Overview|개요)\b/i);

  return {
    title,
    overview,
    frs: collectFrEntries(lines),
    acceptance: parseAcceptanceItems(extractSection(specText, /^#{2,4}\s*(?:Acceptance Criteria|수용 기준)/i)),
    targetFileCount: countSectionEntries(extractSection(specText, /^#{2,4}\s*0\.1\.?\s*(?:Target Files|대상 파일)/i)),
    screenCount: countSectionEntries(extractSection(specText, /^##\s*4\.?\s*(?:Screens?|화면)/i)),
  };
}

/**
 * Estimates SPEC stage scale before diffs exist.
 */
export function estimateSpecScale({ frCount = 0, targetFileCount = 0, screenCount = 0 } = {}) {
  const t = SPEC_SCALE_THRESHOLDS;
  const detail = `FR ${frCount} / Target Files ${targetFileCount} / Screens ${screenCount}`;
  if (frCount >= t.largeFr || targetFileCount >= t.largeTargetFiles || screenCount >= t.largeScreens) {
    return {
      scale: 'large',
      label: 'Large (Estimated)',
      reason: `${detail} — reached large threshold (FR ≥ ${t.largeFr} OR files ≥ ${t.largeTargetFiles} OR screens ≥ ${t.largeScreens})`,
    };
  }
  if (frCount <= t.smallFr && targetFileCount <= t.smallTargetFiles && screenCount <= t.smallScreens) {
    return {
      scale: 'small',
      label: 'Small (Estimated)',
      reason: `${detail} — within small baseline (FR ≤ ${t.smallFr} AND files ≤ ${t.smallTargetFiles} AND screens ≤ ${t.smallScreens})`,
    };
  }
  return { scale: 'medium', label: 'Medium (Estimated)', reason: `${detail} — did not reach large/small thresholds` };
}

/** PLAN.md checkbox progress — `- [ ]` / `- [x]` counts */
export function parsePlanProgress(planText) {
  if (!planText || typeof planText !== 'string') return { done: 0, total: 0 };
  let done = 0;
  let total = 0;
  for (const line of stripFencedBlocks(planText)) {
    const m = line.match(/^\s*[-*]\s*\[( |x|X)\]/);
    if (!m) continue;
    total += 1;
    if (m[1] !== ' ') done += 1;
  }
  return { done, total };
}

/** Extracts PLAN.md checkbox items */
export function parsePlanChecklistItems(planText) {
  if (!planText || typeof planText !== 'string') return [];
  const items = [];
  for (const line of stripFencedBlocks(planText)) {
    const m = line.match(/^\s*[-*]\s*\[( |x|X)\]\s*(.+)$/);
    if (!m) continue;
    items.push({ text: m[2].trim(), done: m[1] !== ' ' });
  }
  return items;
}

function collectUnmatched(entries, keyField, knownSet) {
  return (entries ?? []).map((e) => e[keyField]).filter((k) => !knownSet.has(k));
}

/**
 * Default evaluation checklist for CP-SPEC.
 */
export function buildSpecDefaultChecklist({ frs = [], acceptance = [], scale = null } = {}) {
  const items = [
    {
      slug: 'spec-approve',
      label: 'Implementation Start Approval',
      desc: 'Is it safe to begin implementation according to this requirement definition? (Lowest remediation cost phase)',
      severity: 'critical',
    },
    acceptance.length
      ? {
          slug: 'acceptance-verifiable',
          label: 'Acceptance Criteria Verifiability',
          desc: `Are all ${acceptance.length} acceptance criteria executable/measurable?`,
          severity: 'major',
        }
      : {
          slug: 'acceptance-missing',
          label: 'Missing Acceptance Criteria',
          desc: '0 acceptance criteria — verify if proceeding without verifiable criteria is acceptable',
          severity: 'critical',
        },
    frs.length
      ? {
          slug: 'requirement-intent',
          label: 'Requirement Alignment',
          desc: `Do the ${frs.length} requirements match the intended scope?`,
          severity: 'major',
        }
      : {
          slug: 'requirement-missing',
          label: 'Requirements Not Detected',
          desc: '0 FR tables/headings detected — requirements are not structured',
          severity: 'critical',
        },
    {
      slug: 'problem-fit',
      label: 'Problem-Solution Fit',
      desc: 'Does the overview accurately define the problem being solved without presuming solutions?',
      severity: 'major',
    },
    {
      slug: 'scope-creep',
      label: 'Scope Creep',
      desc: 'Are unnecessary requirements or screens bundled into this phase?',
      severity: 'major',
    },
    scale
      ? {
          slug: 'scale-fit',
          label: 'Appropriate Scale',
          desc: `${scale.reason} — is this scale acceptable to proceed?`,
          severity: 'info',
        }
      : null,
  ].filter(Boolean);
  return normalizeChecklist(items);
}

/**
 * Assembles CP-SPEC deck model (renderer input contract).
 * All metrics are derived from the SPEC document since diffs do not yet exist.
 */
export function buildSpecDeckModel(input = {}) {
  const spec = parseSpecStructure(input.specText);
  const scale = estimateSpecScale({
    frCount: spec.frs.length,
    targetFileCount: spec.targetFileCount,
    screenCount: spec.screenCount,
  });
  const provided = normalizeChecklist(input.checklist);
  const docKey = String(input.docKey || '').trim() || slugify(spec.title, 'spec');
  const narrative = normalizeNarrative(input.narrative);
  const outline = parseDocumentOutline(input.specText);
  const model = {
    stage: 'spec',
    origin: input.origin ?? null,
    docKey,
    outline,
    outlineGroups: orderSectionsForReview(outline),
    outlineSummary: summarizeOutline(outline),
    specPath: input.specPath ?? null,
    generatedAt: input.generatedAt ?? null,
    title: spec.title ?? '(Title Not Detected)',
    overview: spec.overview,
    frs: spec.frs,
    acceptance: spec.acceptance,
    targetFileCount: spec.targetFileCount,
    screenCount: spec.screenCount,
    scale,
    checklist: provided.length
      ? provided
      : buildSpecDefaultChecklist({ frs: spec.frs, acceptance: spec.acceptance, scale }),
    diagramSvg: input.diagramSvg ?? null,
    narrative,
    narrativeUnmatchedFrIds: collectUnmatched(
      narrative?.frNotes,
      'id',
      new Set(spec.frs.map((f) => f.id)),
    ),
  };
  return {
    ...model,
    signals: buildReviewSignals(model),
    requirementMatrix: buildRequirementMatrix(model),
  };
}

/** Axis applicability filters — only include axes relevant to the changeset */
const AXIS_APPLICABILITY = {
  'design-fit': (ctx) => ctx.hasNewFile,
  'complexity-check': (ctx) => ctx.hasCodeChange,
  'docs-sync': (ctx) => ctx.changedSurfaces.length > 0,
};

/**
 * Default evaluation checklist for CP-MILESTONE.
 */
export function buildMilestoneDefaultChecklist({
  planGoal = null,
  numstatRows = [],
  nameStatusRows = [],
  milestoneLabel = null,
} = {}) {
  const rows = Array.isArray(nameStatusRows) ? nameStatusRows : [];
  const ctx = {
    hasNewFile: rows.some((r) => r.kind === 'NEW'),
    hasCodeChange: rows.some((r) => classifyChangeNature(classificationPathOf(r.path)) === 'code'),
    changedSurfaces: buildContractSurfaces(rows).surfaces.filter((s) => s.changed),
  };
  const base = buildDefaultChecklist({ planGoal, numstatRows })
    .filter((item) => (AXIS_APPLICABILITY[item.slug] ?? (() => true))(ctx))
    .map((item) =>
      item.slug === 'docs-sync'
        ? {
            ...item,
            desc: `${ctx.changedSurfaces.map((s) => s.label).join(' · ')} changed — are usage/contract docs included in this changeset?`,
            evidence: 'impact-map',
          }
        : item,
    );
  const items = [
    {
      slug: 'continue-direction',
      label: 'Proceed with Direction',
      desc: 'Is it safe to continue to the next milestone with this architectural approach? (Lowest remediation cost phase)',
      severity: 'critical',
    },
    milestoneLabel
      ? {
          slug: `milestone-${slugify(milestoneLabel, 'label')}`,
          label: `Milestone: ${truncateText(milestoneLabel, 40)}`,
          desc: 'Does the actual progress match the intended milestone goals?',
          severity: 'major',
        }
      : null,
    ...base,
  ].filter(Boolean);
  return normalizeChecklist(items);
}

function textOrNull(value) {
  const s = String(value ?? '').trim();
  return s || null;
}

function milestoneIdentity(input) {
  const branch = textOrNull(input.branch) ?? '(unknown)';
  const milestoneLabel = textOrNull(input.milestoneLabel);
  return {
    branch,
    baseRef: textOrNull(input.baseRef) ?? 'origin/main',
    milestoneLabel,
    docKey: `${branch}::${slugify(milestoneLabel, 'checkpoint')}`,
  };
}

function resolvePlanContext(input) {
  const planText = typeof input.planText === 'string' ? input.planText : null;
  return {
    planGoal: input.planGoal ?? (planText ? extractPlanGoal(planText) : null),
    progress: parsePlanProgress(planText),
  };
}

function buildDiffStats(numstat, commits) {
  const added = numstat.reduce((s, r) => s + (r.added ?? 0), 0);
  const deleted = numstat.reduce((s, r) => s + (r.deleted ?? 0), 0);
  return { files: numstat.length, added, deleted, loc: added + deleted, commits: commits.length };
}

function mergeUntrackedRows(baseRows, untrackedPaths) {
  const rows = Array.isArray(baseRows) ? baseRows : [];
  const knownPaths = new Set(rows.map((r) => r.path));
  return [
    ...rows,
    ...untrackedPaths.filter((p) => !knownPaths.has(p)).map((p) => ({ kind: 'NEW', path: p })),
  ];
}

export function buildMilestoneDeckModel(input = {}) {
  const numstat = parseNumstat(input.numstatText);
  const commits = (Array.isArray(input.commits) ? input.commits : []).map((c) => String(c)).filter(Boolean);
  const stats = buildDiffStats(numstat, commits);

  const untrackedPaths = (Array.isArray(input.untrackedPaths) ? input.untrackedPaths : [])
    .map((p) => String(p).trim())
    .filter(Boolean);
  const nameStatusRows = mergeUntrackedRows(input.nameStatusRows, untrackedPaths);

  const identity = milestoneIdentity(input);
  const { planGoal, progress } = resolvePlanContext(input);
  const provided = normalizeChecklist(input.checklist);
  const narrative = normalizeNarrative(input.narrative);

  const changedPathSet = new Set(
    nameStatusRows.flatMap((r) =>
      r.kind === 'RENAME' ? String(r.path).split(' -> ') : [String(r.path)],
    ),
  );

  const planOutline = parseDocumentOutline(input.planText);
  const model = {
    stage: 'milestone',
    origin: input.origin ?? null,
    featureIndex: input.featureIndex ?? null,
    ...identity,
    outline: planOutline,
    outlineSummary: summarizeOutline(planOutline),
    generatedAt: input.generatedAt ?? null,
    commits,
    numstat,
    nameStatusRows,
    untrackedPaths,
    stats,
    scale: classifyScale({ files: stats.files, loc: stats.loc }),
    progress,
    planGoal,
    checklist: provided.length
      ? provided
      : buildMilestoneDefaultChecklist({
          planGoal,
          numstatRows: numstat,
          nameStatusRows,
          milestoneLabel: identity.milestoneLabel,
        }),
    panelMarkdown: null,
    diagramSvg: input.diagramSvg ?? null,
    narrative,
    narrativeUnmatchedPaths: collectUnmatched(narrative?.fileNotes, 'path', changedPathSet),
    narrativeUnmatchedSpecDocs: collectUnmatched(narrative?.specChanges, 'doc', changedPathSet),
    diffFiles: buildMilestoneDiffFiles(input),
  };
  return { ...model, signals: buildReviewSignals(model) };
}

function buildMilestoneDiffFiles(input) {
  const synthesized = synthesizeUntrackedDiffFiles(input.untrackedFiles).slice(0, DIFF_MAX_FILES);
  const tracked = parseDiffFiles(input.diffText).slice(
    0,
    Math.max(0, DIFF_MAX_FILES - synthesized.length),
  );
  return [...tracked, ...synthesized];
}

// ---------------------------------------------------------------------------
// CP-PLAN (DEBT-224) — Review before implementation for PLAN.md-only pathways
// ---------------------------------------------------------------------------

/** Default evaluation checklist for CP-PLAN */
export function buildPlanDefaultChecklist({ goal = null, items = [] } = {}) {
  return normalizeChecklist(
    [
      {
        slug: 'start-approval',
        label: 'Start Approval',
        desc: 'Is it safe to begin implementation according to this plan? (Lowest remediation cost phase)',
        severity: 'critical',
      },
      goal
        ? {
            slug: 'goal-verifiable',
            label: 'Goal Verifiability',
            desc: `Is the goal ("${truncateText(goal, 60)}") measurable and executable? (R-CM-029 Rule 2)`,
            severity: 'major',
          }
        : {
            slug: 'goal-missing',
            label: 'Missing Goal',
            desc: 'PLAN.md Goal missing — verify purpose before starting implementation',
            severity: 'critical',
          },
      items.length
        ? {
            slug: 'verify-defined',
            label: 'Verification Plan',
            desc: `Are all ${items.length} checklist items defined at the command execution level?`,
            severity: 'major',
          }
        : {
            slug: 'checklist-missing',
            label: 'Missing Checklist',
            desc: '0 PLAN.md checkboxes — criteria for completion are undefined',
            severity: 'critical',
          },
      {
        slug: 'scope-subtraction',
        label: 'Scope Subtraction',
        desc: 'Are unnecessary items included in this plan? Decide what to remove first.',
        severity: 'major',
      },
    ].filter(Boolean),
  );
}

/**
 * Assembles CP-PLAN deck model.
 */
export function buildPlanDeckModel(input = {}) {
  const planText = typeof input.planText === 'string' ? input.planText : null;
  const goal = planText ? extractPlanGoal(planText) : null;
  const items = parsePlanChecklistItems(planText);
  const provided = normalizeChecklist(input.checklist);
  const branch = textOrNull(input.branch);
  const outline = parseDocumentOutline(planText);
  const model = {
    stage: 'plan',
    origin: input.origin ?? null,
    outline,
    outlineGroups: orderSectionsForReview(outline),
    outlineSummary: summarizeOutline(outline),
    branch: branch ?? '(unknown)',
    docKey: branch ?? slugify(input.planPath, 'plan'),
    planPath: input.planPath ?? null,
    generatedAt: input.generatedAt ?? null,
    goal,
    progress: parsePlanProgress(planText),
    items,
    checklist: provided.length ? provided : buildPlanDefaultChecklist({ goal, items }),
    diagramSvg: input.diagramSvg ?? null,
    narrative: normalizeNarrative(input.narrative),
  };
  return { ...model, signals: buildReviewSignals(model) };
}

// ---------------------------------------------------------------------------
// CP-UI (DEBT-226) — HTML deck representation for ui-approval-gate wireframes
// ---------------------------------------------------------------------------

function classifyFenceLine(line, fence) {
  const m = line.match(/^\s*(```+|~~~+)\s*(\S*)\s*$/);
  if (!m) return null;
  if (!fence) return { kind: 'open', char: m[1][0], len: m[1].length, lang: m[2] || '' };
  if (m[1][0] === fence.char && m[1].length >= fence.len && !m[2]) return { kind: 'close' };
  return { kind: 'literal' };
}

export function parseWireframeScreens(wireframeText) {
  if (!wireframeText || typeof wireframeText !== 'string') return [];
  const screens = [];
  let heading = null;
  let fence = null;
  const pushScreen = (extra = {}) => {
    screens.push({
      title: heading ?? `Screen ${screens.length + 1}`,
      lang: fence.lang,
      content: fence.buf.join('\n'),
      ...extra,
    });
  };
  for (const line of wireframeText.split(/\r?\n/)) {
    const f = classifyFenceLine(line, fence);
    if (f?.kind === 'open') {
      fence = { char: f.char, len: f.len, lang: f.lang, buf: [] };
      continue;
    }
    if (f?.kind === 'close') {
      pushScreen();
      fence = null;
      continue;
    }
    if (fence) {
      fence.buf.push(line);
      continue;
    }
    const h = line.match(/^#{1,6}\s+(.+)$/);
    if (h) heading = h[1].trim();
  }
  if (fence) {
    if (fence.buf.length && fence.buf[fence.buf.length - 1] === '') fence.buf.pop();
    pushScreen({ unclosed: true });
  }
  return screens;
}

/** Default evaluation checklist for CP-UI */
export function buildUiDefaultChecklist({ screens = [] } = {}) {
  return normalizeChecklist([
    {
      slug: 'ui-approve',
      label: 'UI Approval',
      desc: 'Is it safe to proceed with implementation based on these wireframes? (Approve/Revise/Reject)',
      severity: 'critical',
    },
    screens.length
      ? {
          slug: 'screen-coverage',
          label: 'Screen Coverage',
          desc: `Do the ${screens.length} screen blocks cover all required screens?`,
          severity: 'major',
        }
      : {
          slug: 'screens-missing',
          label: 'Screen Blocks Missing',
          desc: '0 screen blocks (fenced code) detected in wireframe',
          severity: 'critical',
        },
    {
      slug: 'state-variants',
      label: 'State Variants',
      desc: 'Are standard/loading/empty state variants provided for each screen?',
      severity: 'major',
    },
    {
      slug: 'flow-consistency',
      label: 'Flow Consistency',
      desc: 'Does the screen transition flow match the requirements?',
      severity: 'major',
    },
  ]);
}

/**
 * Assembles CP-UI deck model.
 */
export function buildUiDeckModel(input = {}) {
  const screens = parseWireframeScreens(input.wireframeText);
  const provided = normalizeChecklist(input.checklist);
  const outline = parseDocumentOutline(input.wireframeText);
  const model = {
    stage: 'ui',
    origin: input.origin ?? null,
    outline,
    outlineSummary: summarizeOutline(outline),
    docKey: textOrNull(input.docKey) ?? 'ui',
    wireframePath: input.wireframePath ?? null,
    generatedAt: input.generatedAt ?? null,
    screens,
    checklist: provided.length ? provided : buildUiDefaultChecklist({ screens }),
    diagramSvg: input.diagramSvg ?? null,
    narrative: normalizeNarrative(input.narrative),
  };
  return { ...model, signals: buildReviewSignals(model) };
}
