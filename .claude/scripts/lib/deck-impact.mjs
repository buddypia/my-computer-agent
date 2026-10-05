/**
 * deck-impact.mjs — "What changed · Why · What impact" impact scope derivation (pure function, core layer)
 *
 * Why (user feedback 2026-07-25 #4 + reference decks + web evidence):
 *   (a) Threat: Review decks showed "which files changed and how many lines", but did not reveal
 *       "which features and commitments are impacted". When approving, a reviewer's actual fear
 *       is not line count, but "whether something I don't know about changed alongside".
 *   (b) Gaps:
 *       - `change-taxonomy.mjs:34-100` groups paths into categories along 1 axis, unable to separate
 *         "implementation changed vs tests only changed".
 *       - Feature-level impact was solely `affectedFeatures` in `review-narrative.mjs:84` (unstructured AI text)
 *         without machine cross-check, allowing omissions/misattributions to go undetected.
 *       - Lacked code to evaluate external contract (rules/hooks/deployment registry/schema) changes.
 *   (c) Web evidence:
 *       - Google eng-practices "What to Look For in a Code Review" — 2nd pillar is **Functionality**:
 *         "Is what the developer intended good for the users of this code?", 9th is Documentation:
 *         "If a CL changes how users build, test, interact with, or release code, check to see that
 *         it also updates associated documentation". The core of review is **impact on users and external contracts**.
 *         https://google.github.io/eng-practices/review/reviewer/looking-for.html
 *       - Google "Writing good CL descriptions" — "What change is being made?" +
 *         "Why are these changes being made? What contexts did you have as an author".
 *         Separating what/why is the rationale for the 3-column ledger.
 *         https://google.github.io/eng-practices/review/developer/cl-descriptions.html
 *       - Bohner & Arnold change impact analysis definition — "identifying the potential consequences
 *         of a change" + ripple effect. Deriving ripple surface from change set (SIS) is the definition of IA.
 *         https://en.wikipedia.org/wiki/Change_impact_analysis
 *       - Bacchelli & Bird (ICSE 2013) — "code and change understanding is the key aspect of code reviewing".
 *         https://www.microsoft.com/en-us/research/publication/expectations-outcomes-and-challenges-of-modern-code-review/
 *   (d) Simpler alternatives comparison: 1. "AI writes impacted features in prose" = already exists
 *       (`affectedFeatures`) and is unverifiable -> cross-check against machine derivation instead.
 *       2. "Parse commit message body for why" requires expanding git collection and new parser,
 *       whereas `file_notes[].reason` is already fail-closed validated -> rejected.
 *       3. "Add heatmap bars" duplicates data (R-CM-030 Rule 12) -> rejected.
 *       Adopted: **Machine-derived 2-axis matrix + contract surface evaluation** based on path conventions + feature ownership index.
 *
 * Boundary (R-CM-028): perspective1-only — same deployment isolation as deck assets (not deployed to scaffold).
 */

import { classifyChangePath } from './change-taxonomy.mjs';
import { buildCodeOwnershipIndex } from './code-ownership-index.mjs';

/**
 * Loads feature ownership index — **the only impure function in this module** (file reading).
 * Returns null if index construction fails, degrading deck to path-based areas (R-CM-006 Rule 2 fail-open compliance).
 *
 * Location rationale (R-CM-028): `code-ownership-index.mjs` is a boundary-uniform deployment asset
 * requiring **byte-for-byte fidelity** with scaffold templates (`tests/unit/feature-pilot-ownership-index-contract.test.mjs`).
 * Placing deck-only (perspective1-only) convenience functions there would leak consumerless code into Perspective 2.
 */
export function loadFeatureIndexSafe(projectDir = process.cwd()) {
  try {
    return buildCodeOwnershipIndex(projectDir);
  } catch {
    return null;
  }
}

/** Change nature (column axis) — "What changed". Orthogonal to area (row axis) */
export const NATURE_COLUMNS = [
  { id: 'code', label: 'Implementation' },
  { id: 'test', label: 'Test' },
  { id: 'config', label: 'Config & Data' },
  { id: 'docs', label: 'Docs' },
  { id: 'other', label: 'Other' },
];

const NATURE_RULES = [
  ['test', (p) => /(^|\/)(tests?|__tests__|spec)\//.test(p) || /\.(test|spec)\.[a-z]+$/.test(p)],
  ['code', (p) => /\.(mjs|cjs|js|jsx|ts|tsx|dart|rs|py|sh)$/.test(p)],
  [
    'config',
    (p) =>
      /\.(json|ya?ml|toml|lock|ini|env)$/.test(p) ||
      /(^|\/)(Makefile|Dockerfile|\.gitignore|\.npmrc|\.editorconfig)$/.test(p),
  ],
  ['docs', (p) => /\.(md|mdx|txt|html?|svg|csv)$/.test(p)],
];

/** Path -> Change nature (deterministic classification based on path/extension conventions) */
export function classifyChangeNature(path) {
  const p = String(path ?? '').replace(/^\.\//, '');
  if (!p) return 'other';
  for (const [id, match] of NATURE_RULES) if (match(p)) return id;
  return 'other';
}

const IMPACT_RANK = { global: 0, module: 1, local: 2 };

/**
 * Contract surfaces — "Exposed commitments". If modified, behavior outside this PR changes.
 * Translates reference deck's "provider/route/repository/API/DB contracts are maintained" into harness vocabulary.
 * Crucially specifies **unmodified surfaces alongside modified ones** (reviewers fear unstated changes, so absence is informative).
 */
const CONTRACT_SURFACES = [
  {
    id: 'rules',
    label: 'Rules (Governance Criteria)',
    question: 'Judgment criteria for all subsequent sessions will change — did rule wording change while enforcement points remain intact?',
    match: (p) => /^\.claude\/rules\//.test(p) || /^data\/rules-as-code\//.test(p),
  },
  {
    id: 'hooks',
    label: 'Hooks & Gates (Execution Interception Points)',
    question: 'Block/allow judgment will change — did fail-open policy and regression tests change accordingly?',
    match: (p) =>
      /^\.(claude|cli)\/hooks\//.test(p) ||
      /hook-registry\.mjs$/.test(p) ||
      /^\.claude\/settings(\.local)?\.json$/.test(p),
  },
  {
    id: 'deployment',
    label: 'Deployment Registry (Assets Exported to Generated Projects)',
    question: 'Generated project contents will change — was Perspective 2 boundary (R-CM-028) verified?',
    match: (p) => /^data\/registry\/.*deploy/.test(p) || /deployed-(skills|assets)\.json$/.test(p),
  },
  {
    id: 'schema',
    label: 'Schema (Artifact Contracts)',
    question: 'Existing artifacts may fail validation — was backward compatibility verified?',
    match: (p) => /^data\/schemas\//.test(p) || /\.schema\.json$/.test(p),
  },
  {
    id: 'pipeline',
    label: 'Pipeline Definition (Stage Order & Dependencies)',
    question: 'Stage workflow will change — will running runs remain uncorrupted?',
    match: (p) => /^\.claude\/pipelines\//.test(p),
  },
  {
    id: 'skills',
    label: 'Skill Contract (AI Action Directives)',
    question: 'AI behavior will change — do directives contradict machine enforcement?',
    match: (p) => /^\.claude\/skills\/.*\/(SKILL\.md|MANIFEST\.json)$/.test(p),
  },
  {
    id: 'entrypoint',
    label: 'Command Entry Points (Directly Called by Humans)',
    question: 'Command behavior will change — was usage documentation updated accordingly?',
    match: (p) => /^Makefile$/.test(p) || /^\.claude\/commands\//.test(p) || /^\.claude\/scripts\/[^/]+\.mjs$/.test(p),
  },
  {
    id: 'deps',
    label: 'Dependencies (Installation & Security Surface)',
    question: 'Installation results will change — do audit results and lockfile match?',
    match: (p) => /^(package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock)$/.test(p),
  },
];

/** List of contract surface IDs touched by path (0 = internal implementation only) */
export function contractSurfaceIdsOf(path) {
  const p = String(path ?? '').replace(/^\.\//, '');
  if (!p) return [];
  return CONTRACT_SURFACES.filter((s) => s.match(p)).map((s) => s.id);
}

/**
 * Contract surface evaluation — returns both modified and **unmodified** surfaces.
 * @returns {{surfaces: Array, changedCount: number}}
 */
export function buildContractSurfaces(nameStatusRows = []) {
  const paths = (Array.isArray(nameStatusRows) ? nameStatusRows : [])
    .map((r) => classificationPathOf(r?.path).replace(/^\.\//, ''))
    .filter(Boolean);
  const surfaces = CONTRACT_SURFACES.map((s) => {
    const hits = paths.filter((p) => s.match(p));
    return {
      id: s.id,
      label: s.label,
      question: s.question,
      changed: hits.length > 0,
      paths: hits,
    };
  });
  return { surfaces, changedCount: surfaces.filter((s) => s.changed).length };
}

function featureLookup(featureIndex) {
  const map = featureIndex?.reverse_lookup?.file_to_feature;
  const byId = new Map(
    (Array.isArray(featureIndex?.features) ? featureIndex.features : []).map((f) => [f.id, f]),
  );
  return {
    idOf: (path) => (map && typeof map === 'object' ? (map[path] ?? null) : null),
    get: (id) => byId.get(id) ?? null,
    total: byId.size,
  };
}

/** Path -> Area (row axis). If owned by registered feature -> feature; otherwise degrades to path category */
function resolveArea(path, lookup) {
  const featureId = lookup.idOf(path);
  const feature = featureId ? lookup.get(featureId) : null;
  const category = classifyChangePath(path);
  if (feature) {
    return {
      id: `feature:${feature.id}`,
      label: feature.title || feature.id,
      kind: 'feature',
      impact: category.impact,
      featureId: feature.id,
    };
  }
  return { id: `cat:${category.id}`, label: category.label, kind: 'category', impact: category.impact, featureId: null };
}

function newRow(area) {
  return {
    ...area,
    cells: NATURE_COLUMNS.map(() => ({ files: 0, churn: 0 })),
    files: 0,
    added: 0,
    deleted: 0,
    kinds: { NEW: 0, EDIT: 0, DELETE: 0, RENAME: 0 },
    paths: [],
  };
}

/**
 * RENAME rows arrive as composite notation `old -> new` (`parseNameStatusRows`).
 * Classification must be based on the **new path** — display keeps composite notation,
 * while nature/area/contract surfaces are judged by target location (prevents old prefix misclassification).
 */
export function classificationPathOf(path) {
  const s = String(path ?? '');
  return s.includes(' -> ') ? s.split(' -> ').pop().trim() : s;
}

/**
 * Aggregation key — collapses **rename rows only** to new path.
 *
 * `" -> "` is synthetic syntax created by name-status to denote rename, not path syntax.
 * Collapsing without checking kind would incorrectly merge files with literal `" -> "` in name (`docs/before -> after.md`).
 */
function aggregationKeyOf(row) {
  const path = String(row?.path ?? '');
  return row?.kind === 'RENAME' ? classificationPathOf(path) : path;
}

/** name-status row -> aggregation key map (display path preserves rename arrow) */
function indexByNewPath(nameStatusRows) {
  const entries = new Map();
  for (const row of Array.isArray(nameStatusRows) ? nameStatusRows : []) {
    const display = String(row?.path ?? '');
    if (!display) continue;
    entries.set(aggregationKeyOf(row), {
      path: display,
      kind: row?.kind || 'EDIT',
      added: 0,
      deleted: 0,
    });
  }
  return entries;
}

/**
 * Merges numstat churn into same key (registers new paths as EDIT).
 * numstat paths are already normalized to new path (`ship-deck-core.mjs#normalizeRenamePath`).
 */
function mergeChurnByNewPath(entries, numstat) {
  for (const row of Array.isArray(numstat) ? numstat : []) {
    const key = String(row?.path ?? '');
    if (!key) continue;
    const cur = entries.get(key) ?? { path: key, kind: 'EDIT', added: 0, deleted: 0 };
    cur.added = row?.added ?? 0;
    cur.deleted = row?.deleted ?? 0;
    entries.set(key, cur);
  }
  return entries;
}

function collectChangeSet({ nameStatusRows = [], numstat = [] }) {
  const entries = mergeChurnByNewPath(indexByNewPath(nameStatusRows), numstat);
  return [...entries.entries()].map(([classifyPath, e]) => ({
    path: e.path,
    classifyPath,
    kind: e.kind,
    added: e.added,
    deleted: e.deleted,
    churn: e.added + e.deleted,
    nature: classifyChangeNature(classifyPath),
    surfaces: contractSurfaceIdsOf(classifyPath),
  }));
}

/**
 * Area (feature/area) x Change nature matrix — 2-axis view of "what changed where".
 * Extends 1-axis table to 2-axis grid. All axes are machine-derived.
 */
export function buildImpactMatrix({ nameStatusRows = [], numstat = [], featureIndex = null } = {}) {
  const files = collectChangeSet({ nameStatusRows, numstat });
  if (!files.length) return null;
  const lookup = featureLookup(featureIndex);
  const rows = new Map();

  for (const file of files) {
    const area = resolveArea(file.classifyPath, lookup);
    const row = rows.get(area.id) ?? newRow(area);
    const ci = NATURE_COLUMNS.findIndex((c) => c.id === file.nature);
    const cell = row.cells[ci >= 0 ? ci : NATURE_COLUMNS.length - 1];
    cell.files += 1;
    cell.churn += file.churn;
    row.files += 1;
    row.added += file.added;
    row.deleted += file.deleted;
    if (row.kinds[file.kind] === undefined) row.kinds[file.kind] = 0;
    row.kinds[file.kind] += 1;
    row.paths.push(file.path);
    // Representative impact is highest within area (1 global file makes row global)
    if (IMPACT_RANK[area.impact] < IMPACT_RANK[row.impact]) row.impact = area.impact;
    rows.set(area.id, row);
  }

  // Paths within row sorted by churn desc — ledger lead description points to largest change
  const churnByPath = new Map(files.map((f) => [f.path, f.churn]));
  const list = [...rows.values()]
    .map((row) => ({
      ...row,
      paths: [...row.paths].sort(
        (a, b) => (churnByPath.get(b) ?? 0) - (churnByPath.get(a) ?? 0) || a.localeCompare(b),
      ),
    }))
    .sort(
      (a, b) =>
        IMPACT_RANK[a.impact] - IMPACT_RANK[b.impact] ||
        b.files - a.files ||
        a.label.localeCompare(b.label),
    );
  return {
    columns: NATURE_COLUMNS,
    visibleColumns: NATURE_COLUMNS.filter((c, ci) => list.some((r) => r.cells[ci].files > 0)),
    rows: list,
    totals: buildMatrixTotals(list, files),
  };
}

function buildMatrixTotals(rows, files) {
  const perNature = NATURE_COLUMNS.map((c, ci) => ({
    id: c.id,
    label: c.label,
    files: rows.reduce((s, r) => s + r.cells[ci].files, 0),
  }));
  const kinds = { NEW: 0, EDIT: 0, DELETE: 0, RENAME: 0 };
  for (const r of rows) {
    for (const [k, v] of Object.entries(r.kinds)) kinds[k] = (kinds[k] ?? 0) + v;
  }
  return {
    files: files.length,
    added: files.reduce((s, f) => s + f.added, 0),
    deleted: files.reduce((s, f) => s + f.deleted, 0),
    perNature,
    kinds,
    maxCell: rows.reduce((m, r) => Math.max(m, ...r.cells.map((c) => c.files)), 0),
  };
}

const READ_FIRST_MAX = 6;

/**
 * "Where to look first" — Implements Google navigate "Look at the most important part of the
 * change first" in deterministic machine order: Contract surfaces -> Global impact -> Churn order.
 * Tests are marked with `intentHint` ("it's also helpful to read the tests first").
 * https://google.github.io/eng-practices/review/reviewer/navigate.html
 */
export function buildReadFirst({ nameStatusRows = [], numstat = [], featureIndex = null } = {}) {
  const files = collectChangeSet({ nameStatusRows, numstat });
  if (!files.length) return null;
  const lookup = featureLookup(featureIndex);
  const surfaceLabel = new Map(CONTRACT_SURFACES.map((s) => [s.id, s.label]));
  const scored = files.map((file) => {
    const area = resolveArea(file.classifyPath, lookup);
    return {
      ...file,
      area: area.label,
      impact: area.impact,
      why: file.surfaces.length
        ? `${surfaceLabel.get(file.surfaces[0])} — Exposed contract`
        : area.impact === 'global'
          ? 'Global impact — Baseline for all subsequent work'
          : '',
      intentHint: file.nature === 'test',
      rank: file.surfaces.length ? 0 : area.impact === 'global' ? 1 : 2,
    };
  });
  scored.sort((a, b) => a.rank - b.rank || b.churn - a.churn || a.path.localeCompare(b.path));
  return { items: scored.slice(0, READ_FIRST_MAX), hidden: Math.max(0, scored.length - READ_FIRST_MAX) };
}

/**
 * Feature impact — Registered features (docs/features/NNN-*) touched by this change.
 * Yields **intact anchors alongside modified ones** ("contracts maintained" pattern).
 * Cross-checks AI `affected_features` text against machine set to surface omissions/misattributions.
 */
export function buildFeatureImpact({
  nameStatusRows = [],
  numstat = [],
  featureIndex = null,
  narrative = null,
} = {}) {
  const files = collectChangeSet({ nameStatusRows, numstat });
  if (!files.length) return null;
  const lookup = featureLookup(featureIndex);
  const changedSet = new Set(files.map((f) => f.classifyPath));
  const byFeature = new Map();

  for (const file of files) {
    const id = lookup.idOf(file.classifyPath);
    if (!id) continue;
    const entry = byFeature.get(id) ?? { id, files: [], natures: new Set() };
    entry.files.push(file);
    entry.natures.add(file.nature);
    byFeature.set(id, entry);
  }

  const features = [...byFeature.values()].map((entry) => {
    const meta = lookup.get(entry.id) ?? {};
    const anchors = featureAnchors(meta);
    return {
      id: entry.id,
      title: meta.title || entry.id,
      domain: meta.domain || null,
      status: meta.status || null,
      files: entry.files.length,
      churn: entry.files.reduce((s, f) => s + f.churn, 0),
      natures: NATURE_COLUMNS.filter((c) => entry.natures.has(c.id)).map((c) => c.label),
      changedPaths: entry.files.map((f) => f.path),
      untouchedAnchors: anchors.filter((p) => !changedSet.has(p)),
      testTouched: entry.natures.has('test'),
    };
  });
  features.sort((a, b) => b.files - a.files || a.title.localeCompare(b.title));

  const coverage = {
    mappedFiles: files.filter((f) => lookup.idOf(f.classifyPath)).length,
    totalFiles: files.length,
    registeredFeatures: lookup.total,
  };
  return { features, coverage, ...compareNarrativeFeatures(features, narrative, coverage) };
}

/**
 * Minimum coverage threshold for ownership index to judge validity of AI declarations (AI default).
 * If less than half of changed files map to features, absence from machine set indicates
 * "index does not yet know this area" rather than "declaration is incorrect".
 */
const DECLARATION_JUDGE_MIN_COVERAGE = 0.5;

function featureAnchors(meta) {
  return [
    ...(Array.isArray(meta.spec_paths) ? meta.spec_paths : []),
    ...(Array.isArray(meta.related_files) ? meta.related_files : []),
    meta.context_path,
  ].filter(Boolean);
}

/**
 * Bi-directional cross-check between AI narrative and machine ownership set.
 * Returns `declared` so renderers can display declarations and machine sets side-by-side (R-CM-030 Rule 12).
 *
 * Distinct validity criteria for both directions:
 *   - `machineOnly` (undeclared by AI but has owned files) is **positive evidence**, valid regardless of coverage.
 *   - `declaredOnly` (declaration absent from machine set) is **absence evidence**, valid only when index coverage is sufficient.
 */
function compareNarrativeFeatures(features, narrative, coverage) {
  const declared = Array.isArray(narrative?.affectedFeatures) ? narrative.affectedFeatures : [];
  const judgeable =
    coverage.totalFiles > 0 &&
    coverage.mappedFiles / coverage.totalFiles >= DECLARATION_JUDGE_MIN_COVERAGE;
  if (!declared.length) {
    return {
      declared,
      declaredOnly: [],
      machineOnly: features.map((f) => f.title),
      declarationJudgeable: judgeable,
    };
  }
  const norm = (s) => String(s ?? '').toLowerCase().replace(/[\s_-]/g, '');
  const machineKeys = features.flatMap((f) => [norm(f.id), norm(f.title), norm(f.domain)]).filter(Boolean);
  return {
    declared,
    declaredOnly: judgeable
      ? declared.filter((d) => !machineKeys.some((k) => k.includes(norm(d)) || norm(d).includes(k)))
      : [],
    machineOnly: features
      .filter((f) => !declared.some((d) => norm(f.title).includes(norm(d)) || norm(d).includes(norm(f.title))))
      .map((f) => f.title),
    declarationJudgeable: judgeable,
  };
}

const LEDGER_MAX_REASONS = 3;

/**
 * Change bundle ledger — 3 columns: **What changed · Why · What impact**.
 * What/why cites fail-closed validated AI `file_notes` (change/reason); impact is machine-derived.
 * Bundled by matrix row (area) so upper and lower tables share the same axis.
 */
export function buildChangeLedger({ matrix = null, narrative = null } = {}) {
  if (!matrix?.rows?.length) return null;
  const noteByPath = new Map(
    (Array.isArray(narrative?.fileNotes) ? narrative.fileNotes : []).map((n) => [n.path, n]),
  );
  const surfaceLabel = new Map(CONTRACT_SURFACES.map((s) => [s.id, s.label]));
  // Tests are their own area, so "no tests in this bundle" is always true for code areas —
  // check whether entire change set contains tests to avoid false alarms.
  const testColumn = NATURE_COLUMNS.findIndex((c) => c.id === 'test');
  const globalHasTests = matrix.rows.some((r) => r.cells[testColumn]?.files > 0);
  return matrix.rows.map((row) => {
    const notes = row.paths.map((p) => noteByPath.get(p)).filter(Boolean);
    const reasons = [...new Set(notes.map((n) => n.reason).filter(Boolean))].slice(0, LEDGER_MAX_REASONS);
    const lead = notes.map((n) => n.change).filter(Boolean)[0] ?? null;
    const surfaces = [...new Set(row.paths.flatMap((p) => contractSurfaceIdsOf(classificationPathOf(p))))];
    const natures = row.cells
      .map((c, ci) => (c.files ? `${NATURE_COLUMNS[ci].label} ${c.files}` : null))
      .filter(Boolean);
    return {
      area: row.label,
      kind: row.kind,
      impact: row.impact,
      files: row.files,
      natures,
      lead,
      reasons,
      missingReason: row.paths.length - notes.filter((n) => n.reason).length,
      effects: ledgerEffects(row, surfaces, surfaceLabel, globalHasTests),
    };
  });
}

function ledgerEffects(row, surfaces, surfaceLabel, globalHasTests) {
  const out = [];
  const testFiles = row.cells[NATURE_COLUMNS.findIndex((c) => c.id === 'test')]?.files ?? 0;
  const codeFiles = row.cells[NATURE_COLUMNS.findIndex((c) => c.id === 'code')]?.files ?? 0;
  for (const id of surfaces) {
    out.push({ level: 'warn', text: `Contract surface changed — ${surfaceLabel.get(id)}` });
  }
  if (codeFiles && testFiles) out.push({ level: 'ok', text: `${testFiles} tests changed together` });
  else if (codeFiles && globalHasTests) {
    out.push({ level: 'ok', text: 'Tests are in separate bundle — verify if they cover this change' });
  } else if (codeFiles) {
    out.push({ level: 'warn', text: '0 test changes — no tests in entire change set either' });
  }
  // Tests are code too — attaching "no execution code changed" to test-only bundle looks deceptive
  if (!codeFiles) {
    out.push({
      level: 'ok',
      text: testFiles
        ? 'Tests only changed — product behavior remains intact'
        : 'No execution code changed — behavior remains intact',
    });
  }
  if (row.kinds.DELETE) out.push({ level: 'warn', text: `${row.kinds.DELETE} deletions — verify no residual references remain` });
  return out;
}

/**
 * Batch assembly of impact map (entry point for deck core). Returns null if change set is empty.
 */
export function buildImpactMap({
  nameStatusRows = [],
  numstat = [],
  featureIndex = null,
  narrative = null,
} = {}) {
  const matrix = buildImpactMatrix({ nameStatusRows, numstat, featureIndex });
  if (!matrix) return null;
  return {
    matrix,
    readFirst: buildReadFirst({ nameStatusRows, numstat, featureIndex }),
    ledger: buildChangeLedger({ matrix, narrative }),
    featureImpact: buildFeatureImpact({ nameStatusRows, numstat, featureIndex, narrative }),
    contracts: buildContractSurfaces(nameStatusRows),
  };
}
