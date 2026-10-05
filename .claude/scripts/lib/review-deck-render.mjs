/**
 * review-deck-render.mjs — Stage Review Deck Model → Self-contained HTML (0 CDN/external dependencies)
 *
 * Input contract: `review-deck-core.mjs#buildSpecDeckModel` / `#buildPlanDeckModel` /
 * `#buildMilestoneDeckModel` / `#buildUiDeckModel`.
 * Shared assets (CSS / checklist engine JS / evidence·verdict sections) are imported from ship-deck-render.
 *
 * 2-Layer Principle (Reflecting user deck review feedback 2026-07-13):
 *   - AI-authored layer (Explanations): Story (what/why/how/next), position in overall flow,
 *     per-file change reasons, per-FR requirements·background·approach — "A deck without explanation is unreviewable".
 *   - Machine-generated layer (Evidence): Progress / diffstat / raw diff / heatmap / gate results — AI re-description prohibited.
 *   Both layers are always labeled distinctly as "AI-authored" / "Source · git".
 *
 * Screen structure (2026-07-26 redesign — abolished repetitive total metrics / progress / gate signals / evidence):
 *   Common Header — Original request (verbatim) → High-priority areas (machine-detected risk signals only)
 *   CP-SPEC       — Background·approach (AI) → Trade-offs → Impact → Requirements map → Success criteria
 *                   → Full source SPEC sections → Glossary → Verdict
 *   CP-PLAN       — Story → Trade-offs → Impact → Plan body → Full source PLAN → Glossary → Verdict
 *   CP-MILESTONE  — Fixed·Why·Impact (matrix / reading order / 3-column / feature / contract) → Story
 *                   → Trade-offs → Impact → Changes (per-file explanation + diff) → Full source PLAN
 *                   → Glossary → Verdict → Appendix
 *   CP-UI         — Story → Screen wireframes → Trade-offs·Impact (secondary tone) → Source → Verdict
 *
 * Boundary (R-CM-028): perspective1-only. Not deployed to scaffold targets.
 */

import { escapeHtml } from './ship-deck-core.mjs';
import {
  DECK_VISUAL_CSS,
  renderImpactMapSection,
  renderOriginSection,
  renderReadinessMatrixSvg,
  renderScorecardSection,
  renderVisualFigure,
} from './deck-visuals.mjs';
import { IMPACT_LABEL, orderFilesForReview } from './change-taxonomy.mjs';
import {
  DOC_SECTION_CSS,
  renderDocSections,
  renderOutlineIndex,
} from './doc-section-render.mjs';
import {
  annotateGlossaryTerms,
  DECK_CSS,
  DECK_JS,
  isSafeDiagramSvg,
  renderAppendix,
  renderChecklistSection,
  renderGlossarySection,
  serializeDeckData,
} from './ship-deck-render.mjs';

/** AI prose → escape + glossary inline annotations (same as ship-deck — fulfills tooltip promise) */
function prose(value, glossary) {
  return annotateGlossaryTerms(escapeHtml(value), glossary);
}

/** data-checklist identifier for verdict checklist section */
const CHECKLIST_KIND = 'review-deck';

// Keep labels brief (once per section) — previous 5x repetition of "AI-authored — Explanation (Not machine verified)"
// was noisy and took more space than the content itself (user feedback 2026-07-25).
const AI_LABEL = '<span class="gen ai">AI-authored</span>';
const MACHINE_LABEL = '<span class="gen machine">Source · git</span>';

const REVIEW_DECK_CSS = `
.story dl { display: grid; grid-template-columns: 84px 1fr; gap: 8px 14px; margin: 0; }
.story dt { color: #9da7b3; font-size: 13px; }
.story dd { margin: 0; font-size: 14px; line-height: 1.6; white-space: pre-wrap; }
.narrative-missing { border: 1px solid #d4a72c; border-radius: 8px; padding: 10px 12px;
  color: #d4a72c; font-size: 13px; }
.file-block { border: 1px solid #30363d; border-radius: 8px; padding: 10px 12px; margin: 8px 0;
  background: #0d1117; }
.file-head { display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; font-size: 13px; }
.file-note { font-size: 13px; margin: 6px 0 0; line-height: 1.55; }
.file-note .why { color: #9da7b3; }
.diffstat { font-size: 12px; color: #8b949e; margin-left: auto; }
.diffstat .add { color: #3fb950; }
.diffstat .del { color: #ff7b72; }
pre.diff { max-height: 340px; }
pre.diff .da { color: #3fb950; }
pre.diff .dd { color: #ff7b72; }
pre.diff .dh { color: #58a6ff; }
.fr-item { border: 1px solid #30363d; border-radius: 8px; padding: 10px 12px; margin: 8px 0;
  background: #0d1117; }
.fr-item h3 { margin: 0 0 6px; font-size: 14px; color: #e6edf3; }
.fr-item .fr-meta { display: grid; grid-template-columns: 64px 1fr; gap: 4px 10px; font-size: 13px; }
.fr-item .fr-meta dt { color: #9da7b3; }
.fr-item .fr-meta dd { margin: 0; line-height: 1.55; }
.plan-items { list-style: none; padding: 0; margin: 10px 0; }
.plan-items li { font-size: 14px; line-height: 1.7; }
.plan-items li.done { color: #3fb950; }
.plan-items li.todo { color: #e6edf3; }
pre.wire { max-height: 480px; overflow: auto; }
.impact-table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0; }
.impact-table th, .impact-table td { border: 1px solid #30363d; padding: 6px 8px;
  text-align: left; vertical-align: top; line-height: 1.5; }
.impact-table th { color: #9da7b3; font-weight: 600; }
.chg-group { margin: 14px 0; }
.chg-head { font-size: 13px; margin-bottom: 6px; display: flex; gap: 8px; align-items: center;
  flex-wrap: wrap; }
details.chg-group > summary { font-size: 13px; margin-bottom: 6px; }
.file-bar { height: 3px; background: #21262d; border-radius: 2px; margin: 5px 0 0; overflow: hidden; }
.file-bar-fill { height: 100%; background: linear-gradient(90deg, #1f6feb, #e5534b); }
h3.grp { margin: 18px 0 8px; color: #58a6ff; font-size: 12px; text-transform: none;
  border-bottom: 1px solid #21262d; padding-bottom: 4px; }
`;

function deckShell({ pageTitle, headerHtml, sectionsHtml, deckData }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(pageTitle)}</title>
<style>${DECK_CSS}${DECK_VISUAL_CSS}${DOC_SECTION_CSS}${REVIEW_DECK_CSS}</style>
</head>
<body>
<main>
${headerHtml}
${sectionsHtml}
</main>
<script>window.DECK_DATA = ${serializeDeckData(deckData)};</script>
<script>${DECK_JS}</script>
</body>
</html>
`;
}

const NARRATIVE_MISSING_HTML = `<p class="narrative-missing">AI explanation (--narrative-json) not provided — a deck without what/why/how lacks review substance. Fails gate presentation requirements (feature-pilot "Stage Review Checkpoints" contract).</p>`;

/** ① Story — What, why, how, and next (Core of AI-authored layer) */
function renderStorySection({ narrative, title, glossary }) {
  if (!narrative || !(narrative.what || narrative.why || narrative.how || narrative.next)) {
    return `<section class="card story" id="story">
  <h2>${escapeHtml(title)} ${AI_LABEL}</h2>
  ${NARRATIVE_MISSING_HTML}
</section>`;
  }
  const rows = [
    ['What', narrative.what],
    ['Why', narrative.why],
    ['How', narrative.how],
    ['Next', narrative.next],
  ]
    .filter(([, v]) => v)
    .map(([k, v]) => `<dt>${k}</dt><dd>${prose(v, glossary)}</dd>`)
    .join('\n');
  return `<section class="card story" id="story">
  <h2>${escapeHtml(title)} ${AI_LABEL}</h2>
  <dl>
${rows}
  </dl>
</section>`;
}

/** Injected diagram is supplementary — rendered in separate section only when provided (does not replace machine-generated visuals) */
function renderDiagramBlockSection(model) {
  const html = renderDiagramBlock(model.diagramSvg);
  if (!html) return '';
  return `<section class="card" id="diagram">
  <h2>Supporting Diagram <span class="gen ai">AI-authored</span></h2>
  ${html}
</section>`;
}

function renderDiagramBlock(diagramSvg) {
  if (!diagramSvg) return '';
  if (!isSafeDiagramSvg(diagramSvg)) {
    return '<p class="muted">Injected diagram SVG omitted due to safety check failure (script/event handlers prohibited).</p>';
  }
  return `<div class="diagram">${diagramSvg}</div>`;
}

/** PLAN checkbox progress bar (Machine) */
function renderPlanProgressBar(progress) {
  const { done, total } = progress || { done: 0, total: 0 };
  if (total <= 0) {
    return '<p class="muted">PLAN.md checkboxes not detected — unable to compute progress (not detected = unmeasured, not 0% progress).</p>';
  }
  const pct = Math.round((done / total) * 100);
  return `<div class="hm-row"><div class="hm-label">PLAN Checklist</div><div class="hm-track"><div class="hm-bar" style="width:${pct}%"></div></div><div class="hm-num">${done}/${total} (${pct}%)</div></div>`;
}

/** Diff raw text line colors (+ / - / @@) — machine raw output preserved verbatim, styled with line spans */
function renderDiffText(text) {
  return text
    .split('\n')
    .map((line) => {
      const esc = escapeHtml(line);
      if (line.startsWith('+')) return `<span class="da">${esc}</span>`;
      if (line.startsWith('-')) return `<span class="dd">${esc}</span>`;
      if (line.startsWith('@@')) return `<span class="dh">${esc}</span>`;
      return esc;
    })
    .join('\n');
}

function fileBadge(kind) {
  const colors = { NEW: '#2ea45f', DELETE: '#e5534b', RENAME: '#a371f7', EDIT: '#58a6ff' };
  const color = colors[kind] || colors.EDIT;
  return `<span class="badge" style="border-color:${color};color:${color}">${escapeHtml(kind)}</span>`;
}

/** Untracked synthetic diff diffstat/body display — explicitly notes line tally omission at bottom of section */
function renderUntrackedStat(diff) {
  if (!diff) return '<span class="diffstat muted">untracked — content uncollected</span>';
  if (diff.unavailable) {
    const reasons = { binary: 'binary', too_large: 'size exceeded', unreadable: 'read failed' };
    return `<span class="diffstat muted">untracked — content un-embedded (${reasons[diff.unavailable] || escapeHtml(diff.unavailable)})</span>`;
  }
  return `<span class="diffstat"><span class="add">+${diff.lineCount ?? '?'}</span> <span class="muted">(untracked new)</span></span>`;
}

/** Single file block — badge + path + AI notes (what/why) + diffstat + collapsible raw diff */
function renderFileBlock(row, { note, stat, diff, glossary, sizeRatio = 0 }) {
  const statHtml = stat
    ? `<span class="diffstat"><span class="add">+${stat.added ?? '?'}</span> <span class="del">-${stat.deleted ?? '?'}</span></span>`
    : renderUntrackedStat(diff);
  const noteHtml = note
    ? `<p class="file-note">${prose(note.change || '(no change explanation)', glossary)}${note.reason ? ` <span class="why">— Why: ${prose(note.reason, glossary)}</span>` : ''}</p>`
    : '<p class="file-note muted">Change explanation not provided for this file (narrative.file_notes)</p>';
  const diffHtml =
    diff && !diff.unavailable && diff.text
      ? `<details><summary>${diff.untracked ? 'View file content (new — full + lines)' : 'View raw diff'}${diff.truncated ? ` (first portion only — remainder truncated)` : ''}</summary><pre class="diff">${renderDiffText(diff.text)}</pre></details>`
      : '';
  // Inline churn bar — combines file list and change volume into a single row to avoid double counting
  const bar = sizeRatio > 0
    ? `<div class="file-bar"><div class="file-bar-fill" style="width:${Math.max(2, Math.round(sizeRatio * 100))}%"></div></div>`
    : '';
  return `<div class="file-block">
  <div class="file-head">${fileBadge(row.kind)} <code>${escapeHtml(row.path)}</code>${statHtml}</div>
  ${bar}
  ${noteHtml}
  ${diffHtml}
</div>`;
}

// ---------------------------------------------------------------------------
// Review Depth Extension Sections (Shared across all stages) — User feedback 2026-07-14:
// Having trade-offs / API·spec changes / blast radius / feature mapping only immediately
// prior to ship (Pre-Ship Panel §8) delays corrections. Warnings are rendered when missing —
// silent omissions prohibited, "No alternatives" must be explicitly declared.
// ---------------------------------------------------------------------------

/** Missing note display — soft (secondary tone, CP-UI) uses muted, otherwise warning box */
function missingNote(text, soft) {
  return soft
    ? `<p class="muted">${text}</p>`
    : `<p class="narrative-missing">${text}</p>`;
}

/** Decisions & Trade-offs — What was chosen and what was given up (AI-authored) */
function renderTradeoffSection({ narrative, soft = false, glossary }) {
  const tradeoffs = narrative?.tradeoffs ?? [];
  const blocks = tradeoffs
    .map((t) => {
      const rows = [
        ['Selected', t.chosen],
        ['Rejected', t.rejected],
        ['Why', t.why],
        ['Cost', t.cost],
      ]
        .filter(([, v]) => v)
        .map(([k, v]) => `<dt>${k}</dt><dd>${prose(v, glossary)}</dd>`)
        .join('\n');
      return `<div class="fr-item">
  <h3>${prose(t.topic, glossary)}</h3>
  ${rows ? `<dl class="fr-meta">\n${rows}\n  </dl>` : ''}
</div>`;
    })
    .join('\n');
  const missing = missingNote(
    'Trade-offs not provided (narrative.tradeoffs) — decisions cannot be reviewed without knowing what was given up in choosing this approach. Name the alternative you would otherwise have taken, why not, and what the chosen option costs — "Single approach" is rejected at ship.',
    soft,
  );
  return `<section class="card" id="tradeoffs">
  <h2>Decisions & Trade-offs — What was chosen and what was given up ${AI_LABEL}</h2>
  ${blocks || missing}
</section>`;
}

/** API & Contract Changes table — surface / before / after / compatibility */
function renderApiChangesTable(apiChanges) {
  if (!apiChanges?.length) return '';
  const rows = apiChanges
    .map(
      (a) =>
        `<tr><td><code>${escapeHtml(a.surface)}</code></td><td>${escapeHtml(a.before)}</td><td>${escapeHtml(a.after)}</td><td>${escapeHtml(a.compat)}</td></tr>`,
    )
    .join('\n');
  return `<h3>API & Contract Changes</h3>
<table class="impact-table"><thead><tr><th>Surface</th><th>Before</th><th>After</th><th>Compatibility</th></tr></thead><tbody>
${rows}
</tbody></table>`;
}

/** Requirements & Specification changes list + (milestone) change set comparison warning */
function renderSpecChangesList(specChanges, unmatchedSpecDocs) {
  if (!specChanges?.length) return '';
  const items = specChanges
    .map(
      (s) =>
        `<li><code>${escapeHtml(s.doc)}</code>${s.change ? ` — ${escapeHtml(s.change)}` : ''}</li>`,
    )
    .join('\n');
  return `<h3>Requirements & Specification Changes</h3>
${renderUnmatchedWarning(unmatchedSpecDocs, 'doc in AI explanation (spec_changes) not present in current change set')}
<ul>${items}</ul>`;
}

/**
 * Assembles impact body parts — excludes empty parts (all empty = impact explanation omitted).
 * `affected_features` is omitted here — displayed side-by-side in the "Affected Features"
 * heading (#impact-map) alongside machine-derived ownership sets.
 */
function impactBodyParts(n, unmatchedSpecDocs, glossary) {
  if (!n) return [];
  return [
    n.impact ? `<p class="file-note">${prose(n.impact, glossary)}</p>` : '',
    renderApiChangesTable(n.apiChanges),
    renderSpecChangesList(n.specChanges, unmatchedSpecDocs),
    n.regressionRisk
      ? `<p class="file-note"><span class="why">Regression Risk:</span> ${prose(n.regressionRisk, glossary)}</p>`
      : '',
  ].filter(Boolean);
}

/** Blast Radius & Impact — Systemic blast radius / feature·domain / API·spec changes / regression risk (AI-authored) */
function renderImpactSection({ narrative, unmatchedSpecDocs = [], soft = false, glossary }) {
  const head = `<h2>Blast Radius & Impact — What downstream effects exist across the system ${AI_LABEL}</h2>`;
  const parts = impactBodyParts(narrative, unmatchedSpecDocs, glossary);
  const body = parts.length
    ? parts.join('\n  ')
    : missingNote(
        'Impact description not provided (narrative.impact / api_changes / spec_changes / affected_features / regression_risk) — cannot approve without understanding systemic impact. If impact is localized, state explicitly.',
        soft,
      );
  return `<section class="card" id="impact">
  ${head}
  ${body}
</section>`;
}

// ---------------------------------------------------------------------------
// CP-MILESTONE
// ---------------------------------------------------------------------------

/**
 * Source doc section card — places implementation contract sections first, followed by remainder in document order.
 * Previous implementations only included 4 of 22 sections, rendering approval decisions impossible (user feedback 2026-07-25).
 */
function renderSourceDocSection(model, { title, sourceLabel }) {
  const outline = Array.isArray(model.outline) ? model.outline : [];
  const titled = outline.filter((sec) => sec.title);
  if (!titled.length) {
    return `<section class="card" id="source-doc">
  <h2>${escapeHtml(title)} ${MACHINE_LABEL}</h2>
  <p class="muted">No sections (headings) found in source document — unstructured document.</p>
</section>`;
  }
  const groups = model.outlineGroups ?? { contract: [], rest: titled };
  const contractHtml = groups.contract?.length
    ? `<h3 class="grp">Implementation Contract — Sections directly informing approval decisions</h3>${renderDocSections(groups.contract)}`
    : '';
  const restHtml = groups.rest?.length
    ? `<h3 class="grp">Other Source Document Sections (Document order)</h3>${renderDocSections(groups.rest)}`
    : '';
  const body = contractHtml || restHtml ? `${contractHtml}\n${restHtml}` : renderDocSections(titled);
  const sum = model.outlineSummary;
  const note = sum
    ? `<p class="muted small">${escapeHtml(sourceLabel)} all ${sum.total} sections · ${sum.chars.toLocaleString('en-US')} chars · ${sum.tables} tables · ${sum.codeBlocks} code blocks — included verbatim rather than excerpted; incomplete sections marked with badges.</p>`
    : '';
  return `<section class="card" id="source-doc">
  <h2>${escapeHtml(title)} ${MACHINE_LABEL}</h2>
  ${note}
  <details open><summary>Source Document Table of Contents (Section size & status)</summary>${renderOutlineIndex(titled)}</details>
  ${body}
</section>`;
}

/**
 * Groups file blocks by **category (impact scope) order + churn volume order**.
 * Aligns raw git output order with Google eng-practices "Navigating a CL in Review"
 * (Primary files first · Test reading hints). Collapses by category while displaying counts
 * to make it explicit that items are collapsed rather than omitted.
 */
function renderChangeGroups(model) {
  const ordered = orderFilesForReview({
    numstat: model.numstat,
    nameStatusRows: model.nameStatusRows,
  });
  if (!ordered.length) return '<p class="muted">No changes</p>';
  const statByPath = new Map(model.numstat.map((r) => [r.path, r]));
  const noteByPath = new Map((model.narrative?.fileNotes ?? []).map((n) => [n.path, n]));
  const diffByPath = new Map((model.diffFiles ?? []).map((d) => [d.path, d]));
  const maxChurn = ordered.reduce((m, f) => Math.max(m, f.churn), 0) || 1;

  const groups = new Map();
  for (const file of ordered) {
    const g = groups.get(file.categoryId) ?? {
      label: file.category,
      impact: file.impact,
      readFirst: file.readFirst,
      files: [],
      added: 0,
      deleted: 0,
    };
    g.files.push(file);
    g.added += file.added;
    g.deleted += file.deleted;
    groups.set(file.categoryId, g);
  }

  return [...groups.values()]
    .map((g) => {
      const blocks = g.files
        .map((file) =>
          renderFileBlock(file, {
            note: noteByPath.get(file.path) ?? null,
            stat: statByPath.get(file.path) ?? null,
            diff: diffByPath.get(file.path) ?? null,
            glossary: model.glossary,
            sizeRatio: file.churn / maxChurn,
          }),
        )
        .join('\n');
      const impactColor =
        g.impact === 'global' ? '#e5534b' : g.impact === 'module' ? '#d4a72c' : '#8b949e';
      // Local impact + many files → collapsed by default (count indicates non-omission)
      const collapsed = g.impact === 'local' && g.files.length > 5;
      const head = `<span class="badge" style="border-color:${impactColor};color:${impactColor}">${escapeHtml(IMPACT_LABEL[g.impact] ?? g.impact)}</span> <b>${escapeHtml(g.label)}</b> · ${g.files.length} items <span class="diffstat"><span class="add">+${g.added}</span> <span class="del">-${g.deleted}</span></span>${g.readFirst ? ' <span class="muted small">Start here to understand change intent</span>' : ''}`;
      return collapsed
        ? `<details class="chg-group"><summary>${head} <span class="muted small">(collapsed — expand to show all ${g.files.length} items)</span></summary>${blocks}</details>`
        : `<div class="chg-group"><div class="chg-head">${head}</div>${blocks}</div>`;
    })
    .join('\n');
}

function renderChangesSection(model) {
  const blocks = renderChangeGroups(model);
  const untrackedTotal = model.untrackedPaths.length;
  const untrackedInDeck = (model.diffFiles ?? []).filter((d) => d.untracked).length;
  const untrackedDropped = Math.max(0, untrackedTotal - untrackedInDeck);
  const untracked = untrackedTotal
    ? `<p class="muted small">untracked ${untrackedTotal} file(s) are new files prior to first commit — content embedded in NEW block with + lines, but excluded from git diff line tally (explicitly stated).${untrackedDropped ? ` Due to file count limits, ${untrackedDropped} file(s) have content un-embedded — list (NEW) only.` : ''}</p>`
    : '';
  // Treemap SVG abolished per user feedback (2026-07-26) — file name rectangles alone lack intent.
  // #impact-map matrix provides the same information with labels and semantic context.
  return `<section class="card" id="changes">
  <h2>Change Content — What changed in each file and why ${AI_LABEL} ${MACHINE_LABEL}</h2>
  <p class="muted small">Explanations (what/why) are AI-authored; change churn and raw diffs are machine-generated from git.</p>
  ${renderUnmatchedWarning(model.narrativeUnmatchedPaths, 'path in AI explanation (file_notes) not in actual changed file set')}
  ${blocks || '<p class="muted">No changes</p>'}
  ${untracked}
</section>`;
}

/**
 * narrative ↔ machine set comparison warning (DEBT-228) — displays mismatches explicitly
 * rather than silently ignoring them. Signals stale descriptions or incorrect targets (comparison result only).
 */
function renderUnmatchedWarning(unmatched, subject) {
  if (!unmatched?.length) return '';
  const codes = unmatched.map((v) => `<code>${escapeHtml(v)}</code>`).join(', ');
  return `<p class="narrative-missing">${subject} ${unmatched.length} item(s) — description is stale or references an invalid target: ${codes}</p>`;
}

/**
 * CP-MILESTONE deck — Visualization of mid-implementation snapshots for human review.
 *
 * Section composition (2026-07-26 redesign):
 *   Original request → Key inspection points (suspicious areas only) → Fixed·Why·Impact → Story → Trade-offs →
 *   Impact prose → Changes → Full source PLAN → Glossary → Verdict → Appendix.
 */
export function renderMilestoneDeckHtml(model) {
  const generated = model.generatedAt ? `Generated ${escapeHtml(model.generatedAt)}` : 'Generation timestamp unrecorded';
  const milestone = model.milestoneLabel
    ? ` · Section <b>${escapeHtml(model.milestoneLabel)}</b>`
    : '';
  const headerHtml = `  <header>
    <h1>Stage Review Deck — CP-MILESTONE (Mid-Implementation Review)</h1>
    <p class="muted small">branch <code>${escapeHtml(model.branch)}</code> · base <code>${escapeHtml(model.baseRef)}</code> (merge-base reference, includes uncommitted changes)${milestone} · ${generated}<br/>
    Explanations are <b>AI-authored</b>; impact assessment, churn, and diff are <b>machine-generated</b> — distinguished by labels. Catching corrections prior to ship is cheapest.</p>
  </header>`;
  const sectionsHtml = [
    renderOriginSection(model.origin),
    renderScorecardSection(model.signals),
    renderImpactMapSection(model.signals?.impactMap),
    renderStorySection({
      narrative: model.narrative,
      title: 'Story — What, why, and how work is progressing',
      glossary: model.glossary,
    }),
    renderTradeoffSection({ narrative: model.narrative, glossary: model.glossary }),
    renderImpactSection({
      narrative: model.narrative,
      unmatchedSpecDocs: model.narrativeUnmatchedSpecDocs,
      glossary: model.glossary,
    }),
    renderChangesSection(model),
    renderSourceDocSection(model, { title: 'Plan Source Document (All sections of PLAN.md)', sourceLabel: 'PLAN.md' }),
    renderDiagramBlockSection(model),
    renderGlossarySection(model),
    renderChecklistSection(model, CHECKLIST_KIND, ''),
    renderAppendix(model),
  ]
    .filter(Boolean)
    .join('\n');
  return deckShell({
    pageTitle: `Review Deck (Milestone) — ${model.branch}`,
    headerHtml,
    sectionsHtml,
    deckData: { branch: model.branch, docKey: model.docKey, tool: 'review-deck:milestone' },
  });
}

// ---------------------------------------------------------------------------
// CP-SPEC
// ---------------------------------------------------------------------------

function renderFrItem(fr, note, glossary) {
  const title = note?.ko || fr.requirement || '(No requirement text)';
  const metaRows = [
    ['Why', note?.why || ''],
    ['How', note?.how || ''],
    ['Acceptance Criteria', fr.acceptance || ''],
  ]
    .filter(([, v]) => v)
    .map(([k, v]) => `<dt>${k}</dt><dd>${prose(v, glossary)}</dd>`)
    .join('\n');
  const missing = note
    ? ''
    : '<p class="file-note muted">Explanation (why/how) not provided for this FR (narrative.fr_notes)</p>';
  const original =
    note?.ko && fr.requirement
      ? `<details><summary>View Source</summary><p class="muted small">${escapeHtml(fr.requirement)}</p></details>`
      : '';
  return `<div class="fr-item">
  <h3><code>${escapeHtml(fr.id)}</code> ${escapeHtml(title)}</h3>
  ${metaRows ? `<dl class="fr-meta">\n${metaRows}\n  </dl>` : ''}
  ${missing}
  ${original}
</div>`;
}

function renderFrMapSection(model) {
  const unmatchedFr = renderUnmatchedWarning(
    model.narrativeUnmatchedFrIds,
    'id in AI explanation (fr_notes) not in SPEC FR set',
  );
  if (!model.frs.length) {
    return `<section class="card" id="fr-map">
  <h2>Requirements Map ${MACHINE_LABEL}</h2>
  <p class="muted">FR not detected — missing \`| FR-xxx | ... |\` table in SPEC §2 or missing FR heading. SPEC requirements are unstructured.</p>
  ${unmatchedFr}
</section>`;
  }
  const noteById = new Map((model.narrative?.frNotes ?? []).map((n) => [n.id, n]));
  const items = model.frs.map((fr) => renderFrItem(fr, noteById.get(fr.id) ?? null, model.glossary)).join('\n');
  const matrix = renderVisualFigure({
    svg: renderReadinessMatrixSvg(model.requirementMatrix),
    caption: 'Requirements Readiness — Are the 4 essentials for decision-making satisfied?',
    note: 'Empty boxes (dashed) indicate requirements that cannot be approved as-is',
  });
  return `<section class="card" id="fr-map">
  <h2>Requirements Map — Why each requirement arose and how it is addressed ${AI_LABEL} ${MACHINE_LABEL}</h2>
  <p class="muted small">Requirement list and acceptance criteria are machine-extracted from source SPEC; explanation, why, and how are AI-authored. Readiness grid contrasts both layers.</p>
  ${unmatchedFr}
  ${matrix}
  ${items}
</section>`;
}

function renderAcceptanceSection(model) {
  const body = model.acceptance.length
    ? `<ul>${model.acceptance.map((a) => `<li>${escapeHtml(a)}</li>`).join('\n')}</ul>`
    : '<p class="muted">Acceptance Criteria 0 items — SPEC contains no criteria to judge success (untestable SPEC signal).</p>';
  return `<section class="card" id="acceptance">
  <h2>Success Criteria — What constitutes completion ${MACHINE_LABEL}</h2>
  ${body}
</section>`;
}

/** CP-SPEC deck — Requirements definition document visualization for human review */
export function renderSpecDeckHtml(model) {
  const generated = model.generatedAt ? `Generated ${escapeHtml(model.generatedAt)}` : 'Generation timestamp unrecorded';
  const specPath = model.specPath ? ` · <code>${escapeHtml(model.specPath)}</code>` : '';
  const headerHtml = `  <header>
    <h1>Stage Review Deck — CP-SPEC (Requirements Review)</h1>
    <p class="muted small">${escapeHtml(model.title)}${specPath} · ${generated}<br/>
    Background, approach, and requirements are <b>AI-authored</b>; FR list and success criteria are <b>machine-extracted</b> from source SPEC. Last correction opportunity before implementation begins.</p>
  </header>`;
  const sectionsHtml = [
    renderOriginSection(model.origin),
    renderScorecardSection(model.signals),
    renderStorySection({
      narrative: model.narrative,
      title: 'Background & Approach — Why this SPEC arose and how to address it',
      glossary: model.glossary,
    }),
    renderTradeoffSection({ narrative: model.narrative, glossary: model.glossary }),
    renderImpactSection({ narrative: model.narrative, glossary: model.glossary }),
    renderFrMapSection(model),
    renderAcceptanceSection(model),
    renderSourceDocSection(model, {
      title: 'Requirements Definition Document (All sections of SPEC)',
      sourceLabel: 'SPEC',
    }),
    renderDiagramBlockSection(model),
    renderGlossarySection(model),
    renderChecklistSection(model, CHECKLIST_KIND, ''),
  ]
    .filter(Boolean)
    .join('\n');
  return deckShell({
    pageTitle: `Review Deck (SPEC) — ${model.docKey}`,
    headerHtml,
    sectionsHtml,
    deckData: { branch: model.docKey, docKey: model.docKey, tool: 'review-deck:spec' },
  });
}

// ---------------------------------------------------------------------------
// CP-PLAN (DEBT-224)
// ---------------------------------------------------------------------------

/** PLAN checkbox items list (Machine) — done/todo marks */
function renderPlanItems(items) {
  if (!items?.length) {
    return '<p class="muted">PLAN.md checkboxes not detected — completion criteria undefined (not detected = unmeasured).</p>';
  }
  const lis = items
    .map(
      (i) =>
        `<li class="${i.done ? 'done' : 'todo'}">${i.done ? '✓' : '○'} ${escapeHtml(i.text)}</li>`,
    )
    .join('\n');
  return `<ul class="plan-items">
${lis}
</ul>`;
}

function renderPlanBodySection(model) {
  const goal = model.goal
    ? `<p class="goal">${escapeHtml(model.goal)}</p>`
    : '<p class="goal muted">PLAN.md Goal not detected — untestable plan signal.</p>';
  return `<section class="card" id="plan-body">
  <h2>Plan Progress — Checklist item status ${MACHINE_LABEL}</h2>
  ${goal}
  ${renderPlanProgressBar(model.progress)}
  ${renderPlanItems(model.items)}
</section>`;
}

/** CP-PLAN deck — Pre-implementation plan review visualization for SPEC-less paths */
export function renderPlanDeckHtml(model) {
  const generated = model.generatedAt ? `Generated ${escapeHtml(model.generatedAt)}` : 'Generation timestamp unrecorded';
  const planPath = model.planPath ? ` · <code>${escapeHtml(model.planPath)}</code>` : '';
  const headerHtml = `  <header>
    <h1>Stage Review Deck — CP-PLAN (Pre-Implementation Plan Review)</h1>
    <p class="muted small">branch <code>${escapeHtml(model.branch)}</code>${planPath} · ${generated}<br/>
    Story and flow are <b>AI-authored</b>; Goal, progress, and checklist items are <b>machine-extracted</b> from PLAN.md. Last correction opportunity before implementation (replaces CP-SPEC for SPEC-less paths).</p>
  </header>`;
  const sectionsHtml = [
    renderOriginSection(model.origin),
    renderScorecardSection(model.signals),
    renderStorySection({
      narrative: model.narrative,
      title: 'Story — What, why, and how the work is planned',
      glossary: model.glossary,
    }),
    renderTradeoffSection({ narrative: model.narrative, glossary: model.glossary }),
    renderImpactSection({ narrative: model.narrative, glossary: model.glossary }),
    renderPlanBodySection(model),
    renderSourceDocSection(model, { title: 'Plan Source Document (All sections of PLAN.md)', sourceLabel: 'PLAN.md' }),
    renderDiagramBlockSection(model),
    renderGlossarySection(model),
    renderChecklistSection(model, CHECKLIST_KIND, ''),
  ]
    .filter(Boolean)
    .join('\n');
  return deckShell({
    pageTitle: `Review Deck (PLAN) — ${model.branch}`,
    headerHtml,
    sectionsHtml,
    deckData: { branch: model.branch, docKey: model.docKey, tool: 'review-deck:plan' },
  });
}

// ---------------------------------------------------------------------------
// CP-UI (DEBT-226)
// ---------------------------------------------------------------------------

/** Single screen block — Title + ASCII/mermaid source (embedded in <pre> after escaping, self-contained principle) */
function renderScreenBlock(screen) {
  const langTag = screen.lang
    ? ` <span class="badge">${escapeHtml(screen.lang)}${screen.lang === 'mermaid' ? ' — Text display (external renderer not used)' : ''}</span>`
    : '';
  const unclosedTag = screen.unclosed
    ? ' <span class="badge" style="border-color:#d4a72c;color:#d4a72c">Unclosed block — possible missing code fence in wireframe markdown</span>'
    : '';
  return `<div class="file-block">
  <div class="file-head"><b>${escapeHtml(screen.title)}</b>${langTag}${unclosedTag}</div>
  <pre class="wire">${escapeHtml(screen.content)}</pre>
</div>`;
}

function renderScreensSection(model) {
  const blocks = model.screens.map(renderScreenBlock).join('\n');
  return `<section class="card" id="screens">
  <h2>Screen Wireframes ${AI_LABEL} ${MACHINE_LABEL}</h2>
  <p class="muted small">Wireframe content is AI-authored (ui-approval-gate artifact); block extraction and embedding are machine-processed.</p>
  ${blocks || '<p class="muted">Screen blocks (fenced code) not detected — wireframe markdown contains no screens to review.</p>'}
</section>`;
}

/** CP-UI deck — Elevates ui-approval-gate wireframe presentations to HTML (approval gate logic remains SSOT in skill) */
export function renderUiDeckHtml(model) {
  const generated = model.generatedAt ? `Generated ${escapeHtml(model.generatedAt)}` : 'Generation timestamp unrecorded';
  const wfPath = model.wireframePath ? ` · <code>${escapeHtml(model.wireframePath)}</code>` : '';
  const headerHtml = `  <header>
    <h1>Stage Review Deck — CP-UI (Wireframe Review)</h1>
    <p class="muted small"><code>${escapeHtml(model.docKey)}</code>${wfPath} · ${generated}<br/>
    Visual check prior to implementation — approval/revision/rejection verdict is handled by ui-approval-gate (this deck elevates presentation format).</p>
  </header>`;
  const sectionsHtml = [
    renderOriginSection(model.origin),
    renderScorecardSection(model.signals),
    renderStorySection({
      narrative: model.narrative,
      title: 'Story — Why these screens were designed this way',
      glossary: model.glossary,
    }),
    renderScreensSection(model),
    // CP-UI focuses on screen review — trade-offs/impact are secondary tone (soft, muted missing note)
    renderTradeoffSection({ narrative: model.narrative, soft: true, glossary: model.glossary }),
    renderImpactSection({ narrative: model.narrative, soft: true, glossary: model.glossary }),
    renderSourceDocSection(model, {
      title: 'Wireframe Source Document (All sections)',
      sourceLabel: 'Wireframe',
    }),
    renderDiagramBlockSection(model),
    renderGlossarySection(model),
    renderChecklistSection(model, CHECKLIST_KIND, ''),
  ]
    .filter(Boolean)
    .join('\n');
  return deckShell({
    pageTitle: `Review Deck (UI) — ${model.docKey}`,
    headerHtml,
    sectionsHtml,
    deckData: { branch: model.docKey, docKey: model.docKey, tool: 'review-deck:ui' },
  });
}

