/**
 * change-taxonomy.mjs — Semantic classification + review ordering of change sets (pure function)
 *
 * Why (user feedback 2026-07-25 #3 + web references):
 *   (a) Threat: Review decks only showed directory paths (`.claude/scripts`), failing to communicate the meaning
 *       of "what changed". Reviewers judge risk not by paths, but by whether rules, tests, or app code changed.
 *   (b) Web references:
 *       - Bacchelli & Bird, "Expectations, Outcomes, and Challenges of Modern Code Review"
 *         (ICSE 2013, Microsoft Research): "Code and change understanding is the key aspect
 *         of code reviewing ... most of which are not met by current tools" — the greatest challenge
 *         for reviewers is understanding changes rather than defect finding.
 *         https://www.microsoft.com/en-us/research/publication/expectations-outcomes-and-challenges-of-modern-code-review/
 *       - Google eng-practices, "Navigating a CL in Review": "Look at the most important part
 *         of the change first" + "it's also helpful to read the tests first".
 *         https://google.github.io/eng-practices/review/reviewer/navigate.html
 *   (c) Simpler alternatives comparison: "AI-labeled categories" was rejected as non-verifiable (R-CM-024 spirit).
 *       "Maintaining heatmap bars" was rejected as 3x data duplication. Adopted: deterministic path-convention classification.
 *
 * Aggregation location (2026-07-25 #4): 1-axis category aggregation (`buildChangeTaxonomy`) was deprecated
 * and replaced by the 2-axis area x nature matrix (`deck-impact.mjs#buildImpactMatrix`).
 * Review budget calculation (`buildReviewBudget`, SmartBear 200~400 LOC) was also deprecated (user feedback
 * 2026-07-26: "Exceeded single review limit..." is not material for approval decisions). This module retains
 * only the core classification and ordering primitives used by matrix and file sorting.
 *
 * Boundary (R-CM-028): perspective1-only — same deployment isolation as review deck stack.
 */

/**
 * Category definitions — matched top-to-bottom (specific -> general).
 * `impact` denotes change scope: global (baseline for all subsequent work) / module / local.
 * Order implements Google navigate "most important part first" at category level.
 */
const CATEGORIES = [
  {
    id: 'test',
    label: 'Test',
    impact: 'local',
    // Reading tests first clarifies change intent (Google navigate) — marked via readFirst
    readFirst: true,
    match: (p) => /(^|\/)(tests?|__tests__|spec)\//.test(p) || /\.(test|spec)\.[a-z]+$/.test(p),
  },
  {
    id: 'governance',
    label: 'Governance & Rules',
    impact: 'global',
    match: (p) =>
      /^\.claude\/rules\//.test(p) ||
      /^data\/rules-as-code\//.test(p) ||
      /^\.harness\/governance\//.test(p) ||
      /^(CLAUDE|AGENTS|GOVERNANCE)\.md$/.test(p) ||
      /\/(CLAUDE|AGENTS|GOVERNANCE)\.md$/.test(p),
  },
  {
    id: 'config',
    label: 'Config & Dependencies',
    impact: 'global',
    match: (p) =>
      /^(package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock|tsconfig.*\.json|Makefile|\.gitignore|\.npmrc)$/.test(p) ||
      /^\.claude\/settings(\.local)?\.json$/.test(p) ||
      /^(eslint|vitest|vite|next|tailwind|prettier)\.config\.[a-z]+$/.test(p) ||
      /^\.github\/workflows\//.test(p),
  },
  {
    id: 'hook',
    label: 'Hooks & Gates',
    impact: 'global',
    match: (p) => /^\.claude\/hooks\//.test(p) || /^\.cli\/hooks\//.test(p),
  },
  {
    id: 'skill',
    label: 'Skills & Agents',
    impact: 'module',
    match: (p) => /^\.claude\/(skills|agents|commands)\//.test(p),
  },
  {
    id: 'tooling',
    label: 'Automation & Tooling',
    impact: 'module',
    match: (p) => /^\.claude\/scripts\//.test(p) || /^\.cli\//.test(p) || /^scripts\//.test(p),
  },
  {
    id: 'schema',
    label: 'Data & Schemas',
    impact: 'module',
    match: (p) => /^data\//.test(p) || /\.schema\.json$/.test(p),
  },
  {
    id: 'app',
    label: 'App Code',
    impact: 'module',
    match: (p) => /^(src|app|lib|components|pages|features)\//.test(p),
  },
  {
    id: 'docs',
    label: 'Docs & Specs',
    impact: 'local',
    match: (p) => /^docs\//.test(p) || /\.mdx?$/.test(p),
  },
];

const FALLBACK = { id: 'other', label: 'Other', impact: 'local', match: () => true };

export const IMPACT_LABEL = { global: 'Global', module: 'Module', local: 'Local' };
const IMPACT_ORDER = { global: 0, module: 1, local: 2 };

/** Path -> Category (deterministic path-convention classification, not AI labeling) */
export function classifyChangePath(path) {
  const p = String(path ?? '').replace(/^\.\//, '');
  if (!p) return FALLBACK;
  return CATEGORIES.find((c) => c.match(p)) ?? FALLBACK;
}

/**
 * File review ordering — implements Google navigate "primary files first" + "read tests first".
 * Sorting: 1. Impact scope (global -> module -> local) 2. Largest churn within category.
 * Tests are marked with `readFirst` so renderers can guide reviewers to read them first for intent.
 */
export function orderFilesForReview({ numstat = [], nameStatusRows = [] } = {}) {
  const churn = new Map((Array.isArray(numstat) ? numstat : []).map((r) => [r.path, r]));
  return (Array.isArray(nameStatusRows) ? nameStatusRows : [])
    .filter((r) => r?.path)
    .map((row) => {
      const cat = classifyChangePath(row.path);
      const stat = churn.get(row.path);
      const added = stat?.added ?? 0;
      const deleted = stat?.deleted ?? 0;
      return {
        ...row,
        category: cat.label,
        categoryId: cat.id,
        impact: cat.impact,
        readFirst: Boolean(cat.readFirst),
        added,
        deleted,
        churn: added + deleted,
      };
    })
    .sort(
      (a, b) =>
        IMPACT_ORDER[a.impact] - IMPACT_ORDER[b.impact] ||
        b.churn - a.churn ||
        a.path.localeCompare(b.path),
    );
}
