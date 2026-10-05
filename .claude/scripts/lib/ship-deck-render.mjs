/**
 * ship-deck-render.mjs — Deck model → Self-contained HTML renderer (0 CDN/external dependencies)
 *
 * Input contract: Model returned by `ship-deck-core.mjs#buildDeckModel`.
 * Output: Single index.html string — inline CSS/JS, fully functional offline.
 *
 * Screen structure (2026-09-18, second rewrite — impact first, file lists gone from the first view):
 *   Brief:  reach banner (how far the change goes, computed from git paths — data · product ·
 *           pipeline · local — with a four-segment bar) → what · for whom · why · how →
 *           [exposure tiles when the change reaches users or contracts] → [data change block when
 *           stored data or an external contract moves] → what breaks if this is wrong (scenario ·
 *           who notices · how we would know · what we do) → [structured diagram the renderer
 *           draws] → chosen vs rejected with cost → where to review → gaps · rollback · next.
 *   Below:  machine warnings (only when any) → <details> folds: original request · changed files
 *           (tree; per-file notes only if authored) · requirements trace (only if authored) ·
 *           legacy impact notes (only if authored) · impact map · AI SVG · glossary · sources.
 *
 *   Why this order (user feedback 2026-09-18): "People do not read file lists however long they are. What
 *   matters is where the change lands, how much, and what can go wrong if it is big." A harness fix and a data migration used to
 *   open with the same file tree. Now the first line says which one this is, and the gate asks
 *   for more when it is the latter.
 *
 * Boundary (R-CM-028): perspective1-only. Not deployed to scaffold targets.
 */

import { escapeHtml } from './ship-deck-core.mjs';
import { splitPathMention } from './narrative-quality.mjs';
import { escapeRegExp } from './plain-language.mjs';
import { PASSPORT_RELPATH } from './review-origin.mjs';
import {
  DECK_VISUAL_CSS,
  renderImpactMapSection,
  renderOriginSection,
  renderScorecardSection,
  renderTraceMapSvg,
  renderVisualFigure,
  severityBadge,
} from './deck-visuals.mjs';

export { DECK_VISUAL_CSS };

/**
 * Wraps matched glossary terms in escaped prose with `? icon + CSS tooltip` structure:
 * `<span class="term">Term<sup class="term-icon">?</sup><span class="term-tip">Definition</span></span>`.
 * Hovering or keyboard focusing immediately displays the definition without delay.
 */
export function annotateGlossaryTerms(escapedText, glossaryEntries) {
  const entries = Array.isArray(glossaryEntries) ? glossaryEntries : [];
  if (!escapedText || !entries.length) return escapedText;
  const ranges = [];
  for (const entry of entries) {
    for (const alias of entry.aliases ?? []) {
      if (!/[A-Za-z]/.test(alias)) continue;
      const re = new RegExp(
        `(?<![A-Za-z0-9_])${escapeRegExp(alias)}(?![A-Za-z0-9_])`,
        'gi',
      );
      for (const m of escapedText.matchAll(re)) {
        ranges.push({ start: m.index, end: m.index + m[0].length, plain: entry.plain });
      }
    }
    if (entry.pattern) {
      try {
        for (const m of escapedText.matchAll(new RegExp(entry.pattern, 'g'))) {
          ranges.push({ start: m.index, end: m.index + m[0].length, plain: entry.plain });
        }
      } catch {
        /* skip invalid pattern */
      }
    }
  }
  ranges.sort((a, b) => a.start - b.start || b.end - a.end);
  const parts = [];
  let cursor = 0;
  for (const r of ranges) {
    if (r.start < cursor) continue;
    parts.push(escapedText.slice(cursor, r.start));
    parts.push(
      `<span class="term" tabindex="0" aria-label="${escapedText.slice(r.start, r.end)}: ${escapeHtml(r.plain)}">${escapedText.slice(r.start, r.end)}<sup class="term-icon" aria-hidden="true">?</sup><span class="term-tip" role="tooltip">${escapeHtml(r.plain)}</span></span>`,
    );
    cursor = r.end;
  }
  parts.push(escapedText.slice(cursor));
  return parts.join('');
}

function proseHtml(value, glossary) {
  return annotateGlossaryTerms(escapeHtml(value), glossary);
}

/**
 * Glossary section — Lists glossary terms actually present in this deck's prose.
 */
export function renderGlossarySection(model) {
  const entries = Array.isArray(model.glossary) ? model.glossary : [];
  if (!entries.length) return '';
  const rows = entries
    .map((e) => `<dt>${escapeHtml(e.label)}</dt><dd>${escapeHtml(e.plain)}</dd>`)
    .join('\n');
  return `<section class="card" id="glossary">
  <h2>Glossary <span class="gen machine">Lexicon cross-reference — terms used in this document</span></h2>
  <p class="muted small">Hover over the ? icon next to any <span class="term" tabindex="0" aria-label="Dotted underlined term: Hovering displays the definition">dotted underlined term<sup class="term-icon" aria-hidden="true">?</sup><span class="term-tip" role="tooltip">Hovering displays the definition</span></span> to view its definition.</p>
  <dl class="glossary">
${rows}
  </dl>
</section>`;
}

/**
 * Serializes DECK_DATA inline, escaping `<` to prevent script injection.
 */
export function serializeDeckData(data) {
  return JSON.stringify(data).replace(/</g, '\\u003c');
}

function decodeEntities(text) {
  return text
    .replace(/&#x([0-9a-f]+);?/gi, (_m, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);?/g, (_m, dec) => String.fromCodePoint(parseInt(dec, 10)))
    .replace(/&amp;/gi, '&');
}

/**
 * SVG safety check for AI-generated diagrams.
 */
export function isSafeDiagramSvg(svg) {
  if (!svg || typeof svg !== 'string') return false;
  const lowered = decodeEntities(svg).toLowerCase().replace(/\s+/g, ' ');
  if (!lowered.includes('<svg')) return false;
  const DANGEROUS = [
    /<\s*script/,
    /<\s*foreignobject/,
    /<\s*iframe/,
    /<\s*use\b/,
    /<\s*a\b/,
    /[\s/]on[a-z]+\s*=/,
    /javascript:/,
    /data:\s*text\/html/,
    /data:\s*image\/svg/,
  ];
  return !DANGEROUS.some((re) => re.test(lowered));
}

function fileBadge(kind) {
  const colors = { NEW: '#2ea45f', DELETE: '#e5534b', RENAME: '#a371f7', EDIT: '#58a6ff' };
  const color = colors[kind] || colors.EDIT;
  return `<span class="badge" style="border-color:${color};color:${color}">${escapeHtml(kind)}</span>`;
}

export function renderChecklistSection(
  model,
  checklistKind = 'ship-deck',
  num = '⑤',
  title = 'Verdict — Review Checklist',
) {
  const items = model.checklist
    .map((item) => {
      const pass = item.passWhen
        ? `<span class="check-pass"><b>PASS Condition</b> ${escapeHtml(item.passWhen)}</span>`
        : '';
      const link = item.evidence
        ? ` <a class="check-jump" href="#${escapeHtml(item.evidence)}">View Evidence ↓</a>`
        : '';
      return `<li class="check-item" data-check-item="${escapeHtml(item.slug)}" data-severity="${escapeHtml(item.severity ?? 'major')}">
  <div class="check-label"><span class="check-title">${severityBadge(item.severity)}<b>${escapeHtml(item.label)}</b></span><span class="muted">${escapeHtml(item.desc)}${link}</span>${pass}</div>
  <div class="check-actions"></div>
</li>`;
    })
    .join('\n');
  return `<section class="card checklist" id="verdict" data-checklist="${escapeHtml(checklistKind)}">
  <div class="between">
    <h2>${num ? `${escapeHtml(num)} ` : ''}${escapeHtml(title)}</h2>
    <span class="badge" data-checklist-progress></span>
  </div>
  <ul class="check-list">
${items}
  </ul>
  <div class="check-footer">
    <button type="button" class="btn" data-copy-results>Copy Results</button>
    <span class="muted small" data-bridge-status>Auto-save: Not connected</span>
  </div>
</section>`;
}

export function renderAppendix(model) {
  const parts = [];
  if (model.commits.length) {
    parts.push(
      `<details><summary>Commits (${model.commits.length})</summary><pre>${escapeHtml(model.commits.join('\n'))}</pre></details>`,
    );
  }
  if (model.panelMarkdown) {
    parts.push(
      `<details><summary>Pre-Ship Human Review Panel Source (Full Panel Text)</summary><pre class="panel-md">${escapeHtml(model.panelMarkdown)}</pre></details>`,
    );
  }
  if (!parts.length) return '';
  return `<section class="card" id="appendix"><h2>Source Documents (Progressive Disclosure)</h2>${parts.join('\n')}</section>`;
}

export const DECK_CSS = `
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; padding: 24px; background: #0d1117; color: #e6edf3;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Apple SD Gothic Neo", "Noto Sans KR", sans-serif; }
main { max-width: 920px; margin: 0 auto; display: grid; gap: 16px; }
h1 { font-size: 20px; margin: 0 0 4px; }
h2 { font-size: 16px; margin: 0 0 12px; }
h3 { font-size: 13px; margin: 16px 0 8px; color: #9da7b3; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 16px 18px; }
.muted { color: #8b949e; }
.small { font-size: 12px; }
.goal { font-size: 14px; white-space: pre-wrap; }
.badge { display: inline-block; border: 1px solid #30363d; border-radius: 999px; padding: 1px 9px; font-size: 12px; }
.gen { font-size: 11px; font-weight: normal; border-radius: 4px; padding: 2px 6px; vertical-align: middle; }
.gen.machine { background: #12261e; color: #3fb950; }
.gen.ai { background: #2b2111; color: #d4a72c; }
.stats { display: flex; gap: 12px; flex-wrap: wrap; margin: 10px 0; }
.stat { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 8px 14px; min-width: 88px; text-align: center; }
.stat-v { font-size: 20px; font-weight: 700; }
.stat-l { font-size: 11px; color: #8b949e; }
.hm-row { display: grid; grid-template-columns: 220px 1fr 130px; gap: 10px; align-items: center; margin: 4px 0; }
.hm-label { font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl; text-align: left; }
.hm-track { background: #0d1117; border-radius: 4px; height: 14px; }
.hm-bar { background: linear-gradient(90deg, #1f6feb, #e5534b); height: 100%; border-radius: 4px; }
.hm-num { font-size: 11px; color: #8b949e; text-align: right; }
.files { list-style: none; padding: 0; display: grid; gap: 4px; font-size: 12px; }
.diagram svg { max-width: 100%; height: auto; }
.between { display: flex; justify-content: space-between; align-items: center; }
.check-list { list-style: none; padding: 0; margin: 12px 0 0; display: grid; gap: 10px; }
.check-item { display: grid; grid-template-columns: 1fr auto; gap: 10px; background: #0d1117;
  border: 1px solid #30363d; border-radius: 8px; padding: 10px 12px; }
.check-item[data-state="ok"] { border-color: #2ea45f; }
.check-item[data-state="ng"] { border-color: #e5534b; }
.check-label { display: grid; gap: 3px; font-size: 13px; }
.check-actions { display: flex; gap: 6px; align-items: flex-start; }
.btn { background: #21262d; color: #e6edf3; border: 1px solid #30363d; border-radius: 6px;
  padding: 4px 10px; font-size: 12px; cursor: pointer; }
.btn.active-ok { background: #12261e; border-color: #2ea45f; color: #3fb950; }
.btn.active-ng { background: #2d1416; border-color: #e5534b; color: #ff7b72; }
.check-note { grid-column: 1 / -1; width: 100%; background: #0d1117; color: #e6edf3;
  border: 1px solid #30363d; border-radius: 6px; padding: 6px 8px; font-size: 12px; }
.check-footer { display: flex; gap: 12px; align-items: center; margin-top: 14px; }
pre { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 10px;
  font-size: 12px; overflow: auto; white-space: pre-wrap; }
details > summary { cursor: pointer; font-size: 13px; color: #58a6ff; margin: 6px 0; }
.review-intro { border-left: 4px solid #58a6ff; }
.review-intro dl { display: grid; grid-template-columns: 92px 1fr; gap: 8px 14px; margin: 0; }
.review-intro dt { color: #9da7b3; font-size: 13px; }
.review-intro dd { margin: 0; line-height: 1.6; white-space: pre-wrap; }
.trace-list { display: grid; gap: 12px; }
.trace-card { border: 1px solid #30363d; border-radius: 8px; padding: 12px; background: #0d1117; }
.trace-card h3 { margin: 0 0 6px; color: #e6edf3; font-size: 14px; }
.trace-grid { display: grid; grid-template-columns: minmax(180px, 0.8fr) 34px minmax(260px, 1.5fr);
  gap: 10px; align-items: center; margin: 10px 0; }
.trace-arrow { color: #58a6ff; font-size: 22px; text-align: center; }
.trace-box { border: 1px solid #30363d; border-radius: 7px; padding: 9px 10px; line-height: 1.5; }
.trace-impl { display: grid; gap: 6px; }
.trace-validation { color: #9da7b3; font-size: 12px; margin-top: 8px; }
.tree { list-style: none; margin: 0; padding-left: 0; font-size: 13px; }
.tree .tree { margin: 5px 0 0 18px; padding-left: 14px; border-left: 1px solid #30363d; }
.tree-node { margin: 5px 0; }
.tree-dir-label { color: #9da7b3; font-weight: 650; }
.tree-file { border: 1px solid #30363d; border-radius: 7px; padding: 8px 10px; background: #0d1117; }
.tree-file-head { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.tree-note { margin: 5px 0 0 0; line-height: 1.5; }
.tree-reason { color: #9da7b3; }
.decision-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.decision-table th, .decision-table td { border: 1px solid #30363d; padding: 8px 9px;
  text-align: left; vertical-align: top; line-height: 1.5; }
.decision-table th { color: #9da7b3; }
.term { position: relative; border-bottom: 1px dotted #d4a72c; cursor: help; }
.term-icon { display: inline-block; margin-left: 2px; padding: 0 4px; border-radius: 999px;
  background: #d4a72c; color: #0d1117; font-size: 9px; font-weight: 700; line-height: 1.5;
  vertical-align: super; user-select: none; }
.term-tip { display: none; position: absolute; left: 0; top: calc(100% + 6px); z-index: 20;
  width: max-content; max-width: min(340px, 78vw); background: #1c2128; border: 1px solid #d4a72c;
  border-radius: 6px; padding: 6px 10px; font-size: 12px; font-weight: 400; color: #e6edf3;
  line-height: 1.55; white-space: normal; pointer-events: none;
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.45); }
.term:hover .term-tip, .term:focus .term-tip, .term:focus-within .term-tip { display: block; }
.glossary { display: grid; grid-template-columns: minmax(140px, 240px) 1fr; gap: 6px 14px; margin: 0; font-size: 13px; }
.glossary dt { color: #d4a72c; }
.glossary dd { margin: 0; color: #9da7b3; line-height: 1.55; }
.risk-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.risk-box { border: 1px solid #30363d; border-radius: 8px; padding: 10px 12px; background: #0d1117; }
.risk-box h3 { margin: 0 0 6px; color: #9da7b3; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { border: 1px solid #30363d; border-radius: 999px; padding: 3px 9px; font-size: 12px; }
@media (max-width: 720px) { .hm-row { grid-template-columns: 120px 1fr 110px; } }
@media (max-width: 720px) { .trace-grid { grid-template-columns: 1fr; } .trace-arrow { transform: rotate(90deg); }
  .risk-grid { grid-template-columns: 1fr; } .review-intro dl { grid-template-columns: 1fr; gap: 2px; } }
.brief { border-left: 4px solid #3fb950; padding: 18px 20px; }
.brief-headline { font-size: 18px; font-weight: 700; line-height: 1.45; margin: 0 0 12px; }
.brief-grid { display: grid; grid-template-columns: 96px 1fr; gap: 8px 14px; margin: 0 0 14px; }
.brief-grid dt { color: #9da7b3; font-size: 13px; padding-top: 1px; }
.brief-grid dd { margin: 0; line-height: 1.6; font-size: 14px; }
.brief h3 { margin: 16px 0 8px; font-size: 13px; color: #9da7b3; letter-spacing: 0.02em; }
.brief-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.brief-table th, .brief-table td { border: 1px solid #30363d; padding: 7px 9px; text-align: left;
  vertical-align: top; line-height: 1.5; }
.brief-table th { color: #9da7b3; background: #11161d; font-weight: 600; white-space: nowrap; }
.brief-table td.cost { color: #d4a72c; }
.brief-focus { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.brief-focus li { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 9px 12px;
  display: grid; grid-template-columns: 24px 1fr; gap: 4px 10px; font-size: 13px; line-height: 1.5; }
.brief-focus .no { color: #58a6ff; font-weight: 700; grid-row: span 3; }
.brief-focus .where { color: #e6edf3; }
.brief-focus .where code { font-size: 12.5px; }
.brief-focus .check { color: #e6edf3; }
.brief-focus .risk { color: #ff7b72; font-size: 12.5px; }
.brief-gaps { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.brief-gaps ul { margin: 0; padding-left: 18px; font-size: 13px; line-height: 1.6; }
.brief-gaps .gap-title { color: #9da7b3; font-size: 12px; margin: 0 0 4px; }
.brief-rollback { margin: 14px 0 0; font-size: 12.5px; color: #9da7b3; }
.brief-rollback code { color: #e6edf3; }
.evidence { border: 1px solid #30363d; border-radius: 10px; background: #161b22; }
.evidence > summary { padding: 12px 18px; font-size: 14px; color: #e6edf3; cursor: pointer;
  list-style: none; display: flex; justify-content: space-between; align-items: center; }
.evidence > summary::-webkit-details-marker { display: none; }
.evidence > summary::after { content: '▸'; color: #8b949e; }
.evidence[open] > summary::after { content: '▾'; }
.evidence > .card { border: 0; border-top: 1px solid #30363d; border-radius: 0; }
.evidence .muted-count { color: #8b949e; font-size: 12px; font-weight: normal; }
@media (max-width: 720px) { .brief-grid { grid-template-columns: 1fr; gap: 2px; } .brief-gaps { grid-template-columns: 1fr; } }
/* ---- impact-first brief (2026-09-18) ---- */
.brief.tone-red { border-left-color: #f85149; }
.brief.tone-orange { border-left-color: #db6d28; }
.brief.tone-yellow { border-left-color: #d4a72c; }
.brief.tone-green { border-left-color: #3fb950; }
.reach { margin: -4px 0 16px; }
.reach-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 0 0 10px; font-size: 14px; }
.reach-head b { font-size: 16px; }
.reach-means { color: #9da7b3; font-size: 13px; }
.reach-dot { width: 12px; height: 12px; border-radius: 999px; background: #3fb950; box-shadow: 0 0 0 4px rgba(63,185,80,.18); }
.tone-red .reach-dot { background: #f85149; box-shadow: 0 0 0 4px rgba(248,81,73,.2); }
.tone-orange .reach-dot { background: #db6d28; box-shadow: 0 0 0 4px rgba(219,109,40,.2); }
.tone-yellow .reach-dot { background: #d4a72c; box-shadow: 0 0 0 4px rgba(212,167,44,.2); }
.reach-bar { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 6px; }
.reach-bar .seg { border: 1px solid #30363d; border-radius: 8px; padding: 8px 10px; background: #0d1117; display: grid; gap: 3px; opacity: .55; min-height: 58px; }
.reach-bar .seg.on { opacity: 1; }
.reach-bar .seg.top { box-shadow: inset 0 0 0 1px currentColor; }
.reach-bar .seg.tone-red.on { color: #ff7b72; background: #2d1416; }
.reach-bar .seg.tone-orange.on { color: #f0883e; background: #2b1a10; }
.reach-bar .seg.tone-yellow.on { color: #e3b341; background: #2b2111; }
.reach-bar .seg.tone-green.on { color: #3fb950; background: #12261e; }
.seg-label { font-size: 12px; font-weight: 700; letter-spacing: .02em; }
.seg-count { font-size: 13px; color: #e6edf3; }
.seg:not(.on) .seg-count { color: #8b949e; }
.seg-paths { font-size: 11px; color: #9da7b3; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.seg-paths code { font-size: 11px; color: #c9d1d9; }
.reach-caveat { margin: 8px 0 0; font-size: 12px; color: #d4a72c; }
.tiles { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
.tile { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 9px 11px; display: grid; gap: 4px; }
.tile-k { font-size: 11px; color: #9da7b3; letter-spacing: .02em; }
.tile-v { font-size: 13px; line-height: 1.5; }
.data-change { border: 1px solid #5a2a2a; background: #1a0f10; border-radius: 8px; padding: 10px 12px; }
.brief-table.failures td.scenario { font-weight: 600; }
.brief-table.failures td:nth-child(2) { color: #f0883e; }
.brief-table.failures td:nth-child(4) { color: #9da7b3; }
.diagram-flow, .diagram-ba { margin: 14px 0 0; }
.diagram-flow figcaption, .diagram-ba figcaption { font-size: 12px; color: #9da7b3; margin: 0 0 8px; }
.flow-steps { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 0; align-items: stretch; }
.flow-steps .step { position: relative; background: #0d1117; border: 1px solid #30363d; border-radius: 8px; padding: 8px 12px 8px 12px; margin-right: 26px; display: grid; gap: 2px; min-width: 120px; max-width: 220px; font-size: 13px; }
.flow-steps .step small { color: #9da7b3; font-size: 11.5px; line-height: 1.4; }
.flow-steps .step:not(:last-child)::after { content: '→'; position: absolute; right: -21px; top: 50%; transform: translateY(-50%); color: #58a6ff; font-size: 16px; }
.flow-steps .step:has(+ .state-removed)::after { content: ''; }
.flow-steps .step.state-removed { margin-left: 8px; }
.flow-steps .step.state-changed { border-color: #d4a72c; background: #2b2111; }
.flow-steps .step.state-new { border-color: #3fb950; background: #12261e; }
.flow-steps .step.state-removed { border-color: #f85149; background: #2d1416; text-decoration: line-through; opacity: .8; }
.flow-legend { margin: 8px 0 0; font-size: 11px; color: #9da7b3; display: flex; gap: 12px; }
.flow-legend span::before { content: ''; display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 5px; vertical-align: -1px; border: 1px solid #30363d; background: #0d1117; }
.flow-legend .state-changed::before { border-color: #d4a72c; background: #2b2111; }
.flow-legend .state-new::before { border-color: #3fb950; background: #12261e; }
.flow-legend .state-removed::before { border-color: #f85149; background: #2d1416; }
.ba-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.ba-table th, .ba-table td { border: 1px solid #30363d; padding: 7px 9px; text-align: left; vertical-align: top; line-height: 1.5; }
.ba-table thead th { color: #9da7b3; background: #11161d; font-weight: 600; }
.ba-table tbody th { color: #9da7b3; font-weight: 600; white-space: nowrap; }
.ba-table td.before { color: #9da7b3; }
.ba-table td.arrow { color: #58a6ff; text-align: center; width: 28px; }
.ba-table td.after { color: #e6edf3; }
@media (max-width: 720px) { .reach-bar { grid-template-columns: repeat(2, minmax(0, 1fr)); } .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
`;

export const DECK_JS = `
(function () {
  var data = window.DECK_DATA || { branch: '(unknown)', checklist: [] };
  var tool = data.tool || 'ship-deck';
  var storeKey = tool + ':' + (data.docKey || data.branch);
  var state = {};
  try { state = JSON.parse(localStorage.getItem(storeKey) || '{}') || {}; } catch (e) { state = {}; }
  var items = Array.prototype.slice.call(document.querySelectorAll('[data-check-item]'));
  var progressEl = document.querySelector('[data-checklist-progress]');
  var bridgeStatusEl = document.querySelector('[data-bridge-status]');
  var bridgePort = new URLSearchParams(location.search).get('bridge') || '7357';
  var bridgeBase = 'http://127.0.0.1:' + bridgePort;
  var bridgeConnected = false;

  function itemMeta(li) {
    var slug = li.getAttribute('data-check-item');
    var labelEl = li.querySelector('.check-label b');
    var descEl = li.querySelector('.check-label .muted');
    return {
      slug: slug,
      label: labelEl ? labelEl.textContent : slug,
      desc: descEl ? descEl.textContent : '',
    };
  }

  function summary() {
    var total = items.length, ok = 0, ng = 0;
    items.forEach(function (li) {
      var s = state[li.getAttribute('data-check-item')];
      if (s && s.state === 'ok') ok += 1;
      if (s && s.state === 'ng') ng += 1;
    });
    return { total: total, checked: ok + ng, ok: ok, ng: ng };
  }

  function buildResult(sum) {
    return {
      tool: tool,
      version: 1,
      branch: data.branch,
      page: location.pathname,
      updatedAt: new Date().toISOString(),
      summary: sum || summary(),
      items: items.map(function (li) {
        var meta = itemMeta(li);
        var s = state[meta.slug] || {};
        return { slug: meta.slug, label: meta.label, desc: meta.desc, state: s.state || null, note: s.note || '' };
      }),
    };
  }

  function buildMarkdown() {
    var sum = summary();
    var lines = ['## Ship Deck Review Results — ' + data.branch, 'Verified ' + sum.checked + '/' + sum.total + ' · Issues ' + sum.ng];
    items.forEach(function (li) {
      var meta = itemMeta(li);
      var s = state[meta.slug] || {};
      var mark = s.state === 'ok' ? '[OK]' : s.state === 'ng' ? '[Needs Fix]' : '[Unverified]';
      var note = s.state === 'ng' && s.note ? ' — ' + s.note : '';
      lines.push('- ' + mark + ' ' + meta.label + ' (' + meta.slug + ')' + note);
    });
    return lines.join('\\n');
  }

  function updateProgress(sum) {
    if (!progressEl) return;
    sum = sum || summary();
    progressEl.textContent = 'Verified ' + sum.checked + '/' + sum.total + ' · Issues ' + sum.ng;
  }

  function pushBridge(sum) {
    if (!bridgeConnected) return;
    fetch(bridgeBase + '/result', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(buildResult(sum)),
    }).catch(function () { setBridgeStatus(false); });
  }

  function setBridgeStatus(connected) {
    bridgeConnected = connected;
    if (bridgeStatusEl) bridgeStatusEl.textContent = connected ? 'Auto-save: Connected (port ' + bridgePort + ')' : 'Auto-save: Not connected';
  }

  var failCount = 0;
  var pingTimer = null;
  function schedulePing() {
    if (pingTimer) clearTimeout(pingTimer);
    var delay = bridgeConnected ? 5000 : Math.min(60000, 5000 * Math.pow(2, Math.min(failCount, 4)));
    pingTimer = setTimeout(pingBridge, delay);
  }
  function pingBridge() {
    if (typeof document !== 'undefined' && document.hidden) { schedulePing(); return; }
    fetch(bridgeBase + '/ping')
      .then(function (r) { if (!r.ok) throw new Error('bad status'); return r.json(); })
      .then(function (body) {
        var ok = !!(body && body.tool === 'ship-deck-bridge');
        var was = bridgeConnected;
        setBridgeStatus(ok);
        failCount = ok ? 0 : failCount + 1;
        if (!was && ok) pushBridge();
        schedulePing();
      })
      .catch(function () { setBridgeStatus(false); failCount += 1; schedulePing(); });
  }

  function save() {
    try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch (e) { /* ignore storage error */ }
    var sum = summary();
    updateProgress(sum);
    pushBridge(sum);
  }

  function renderItem(li) {
    var slug = li.getAttribute('data-check-item');
    var s = state[slug] || {};
    li.setAttribute('data-state', s.state || '');
    var actions = li.querySelector('.check-actions');
    actions.innerHTML = '';
    [['ok', 'OK'], ['ng', 'Needs Fix']].forEach(function (pair) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn' + (s.state === pair[0] ? ' active-' + pair[0] : '');
      btn.textContent = pair[1];
      btn.addEventListener('click', function () {
        var cur = state[slug] || {};
        state[slug] = { state: cur.state === pair[0] ? null : pair[0], note: cur.note || '' };
        save();
        renderItem(li);
      });
      actions.appendChild(btn);
    });
    var existingNote = li.querySelector('.check-note');
    if (existingNote) existingNote.remove();
    if (s.state === 'ng') {
      var note = document.createElement('textarea');
      note.className = 'check-note';
      note.placeholder = 'What needs to be fixed and how (will be fed into AI remediation task)';
      note.value = s.note || '';
      note.addEventListener('change', function () {
        state[slug] = { state: 'ng', note: note.value };
        save();
      });
      li.appendChild(note);
    }
  }

  var copyBtn = document.querySelector('[data-copy-results]');
  if (copyBtn) {
    copyBtn.addEventListener('click', function () {
      var md = buildMarkdown();
      var done = function () { copyBtn.textContent = 'Copied'; setTimeout(function () { copyBtn.textContent = 'Copy Results'; }, 1500); };
      var fallback = function () {
        try {
          var ta = document.createElement('textarea');
          ta.value = md; document.body.appendChild(ta); ta.select();
          document.execCommand('copy'); ta.remove(); done();
        } catch (e) { copyBtn.textContent = 'Copy failed — select manually'; }
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(md).then(done).catch(fallback);
      } else {
        fallback();
      }
    });
  }

  items.forEach(renderItem);
  updateProgress();
  pingBridge();
  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('visibilitychange', function () { if (!document.hidden) pingBridge(); });
  }
})();
`;

/**
 * Human-facing deck labels per locale. The locale comes from `.claude/reach-map.json#locale`
 * (carried on `model.reach.locale`); an unknown or absent locale renders English, which is the
 * pre-extension-point output byte for byte. `ko` is a shipped Korean copy, so a
 * target selects it with one config key instead of editing this managed file.
 */
export const DECK_LABELS = Object.freeze({
  en: {
    lang: 'en',
    more: (n) => `+${n} more`,
    builtinCaveat: 'Classified by builtin conventions (no <code>.claude/reach-map.json</code>) — production paths may look local.',
    computedFromGit: 'computed from git paths',
    reachAria: 'Change reach',
    exposureTitle: 'Who is exposed, and how many',
    exposureWho: 'Who',
    exposureHowMany: 'How many',
    exposureWhen: 'From when',
    exposureReversible: 'Reversible?',
    dataChangeTitle: 'Data / contract movement',
    dataWhatMoves: 'What moves',
    dataCount: 'Count',
    dataIrreversible: 'Not undone by a revert',
    dataOrder: 'Order · safe stopping points',
    dataConsumers: 'Who reads it',
    failuresTitle: 'What breaks if this is wrong',
    failuresScenario: 'Scenario',
    failuresWho: 'Who notices first',
    failuresDetect: 'How we find out',
    failuresMitigation: 'What we do then',
    flowChanged: 'Changed step',
    flowNew: 'New step',
    flowRemoved: 'Removed step',
    flowSame: 'Unchanged',
    before: 'Before',
    after: 'After',
    ifWrong: 'If wrong',
    forWhom: 'For whom',
    why: 'Why',
    how: 'How',
    tradeoffsTitle: 'Chosen vs rejected',
    tradeoffDecision: 'Decision',
    tradeoffChosen: 'Chosen · why',
    tradeoffRejected: 'Rejected alternative',
    tradeoffCost: 'Cost of the choice',
    reviewFocusTitle: 'Where to review',
    gapsTitle: 'Not done · known gaps',
    outOfScopeTitle: 'Deliberately out of scope',
    rollback: 'Rollback',
    next: 'Next',
    scorecardTitle: 'Machine-detected warnings',
    foldOrigin: 'Original request <span class="muted-count">verbatim · check against the AI interpretation</span>',
    foldChangedFiles: 'Changed files',
    foldRequirements: 'Requirements → implementation trace',
    foldImpact: 'Impact · regression notes <span class="muted-count">author notes</span>',
    foldImpactMap: 'Machine-measured impact map <span class="muted-count">feature ownership · contract surfaces</span>',
    foldDiagram: 'Behavior · structure diagram (SVG)',
    foldGlossary: 'Glossary',
    foldSources: 'Source documents',
  },
  ko: {
    lang: 'ko',
    more: (n) => `외 ${n}`,
    builtinCaveat: '내장 규칙으로 분류했다 (<code>.claude/reach-map.json</code> 없음) — 프로덕션 경로가 로컬로 보일 수 있다.',
    computedFromGit: 'git 경로로 계산',
    reachAria: '도달 범위',
    exposureTitle: '누가 · 얼마나 노출되나',
    exposureWho: '누가',
    exposureHowMany: '얼마나',
    exposureWhen: '언제부터',
    exposureReversible: '되돌릴 수 있나',
    dataChangeTitle: '데이터 · 계약 이동',
    dataWhatMoves: '무엇이 어떻게',
    dataCount: '건수',
    dataIrreversible: 'revert 로 안 돌아오는 것',
    dataOrder: '순서 · 멈출 수 있는 지점',
    dataConsumers: '읽는 쪽',
    failuresTitle: '잘못되면 무슨 일이 생기나',
    failuresScenario: '시나리오',
    failuresWho: '누가 먼저 알아채나',
    failuresDetect: '어떻게 알아내나',
    failuresMitigation: '그때 무엇을 하나',
    flowChanged: '바뀐 단계',
    flowNew: '새 단계',
    flowRemoved: '없어진 단계',
    flowSame: '그대로',
    before: '전',
    after: '후',
    ifWrong: '틀리면',
    forWhom: '누구를 위해',
    why: '왜',
    how: '어떻게',
    tradeoffsTitle: '고른 것과 버린 것',
    tradeoffDecision: '결정',
    tradeoffChosen: '고른 것 · 이유',
    tradeoffRejected: '버린 대안',
    tradeoffCost: '치른 비용',
    reviewFocusTitle: '리뷰어가 볼 곳',
    gapsTitle: '안 한 것 · 알려진 한계',
    outOfScopeTitle: '의도적으로 제외',
    rollback: '되돌리기',
    next: '다음',
    scorecardTitle: '경고',
    foldOrigin: '원문 요청 <span class="muted-count">그대로 · AI 해석 대조</span>',
    foldChangedFiles: '변경 파일',
    foldRequirements: '요구사항 → 구현 추적',
    foldImpact: '영향 · 회귀 메모 <span class="muted-count">작성자 메모</span>',
    foldImpactMap: '기계 측정 영향 지도 <span class="muted-count">feature ownership · contract surfaces</span>',
    foldDiagram: '동작 · 구조 도식 (SVG)',
    foldGlossary: '용어',
    foldSources: '원본 문서',
  },
});

/** Labels for a deck model — `model.reach.locale` selects; anything unknown renders English. */
export function deckLabelsFor(model) {
  const locale = model?.reach?.locale;
  return typeof locale === 'string' && Object.hasOwn(DECK_LABELS, locale) ? DECK_LABELS[locale] : DECK_LABELS.en;
}

/**
 * Reach banner — the first thing on the page. Machine-computed from git paths (change-reach.mjs),
 * so it cannot be talked up or down by the author. Four segments, highest stakes first; touched
 * segments are filled, the top touched one names the tier.
 */
function renderReachBanner(reach, L = DECK_LABELS.en) {
  if (!reach) return '';
  const segs = reach.tiers
    .map((t) => {
      const paths = t.paths.slice(0, 2).map((p) => `<code>${escapeHtml(p)}</code>`).join(' ');
      const more = t.paths.length > 2 ? ` <span class="muted">${L.more(t.paths.length - 2)}</span>` : '';
      return `<li class="seg tone-${t.tone}${t.touched ? ' on' : ''}${t.id === reach.tier ? ' top' : ''}">
  <span class="seg-label">${escapeHtml(t.short)}</span>
  <span class="seg-count">${t.touched ? `${t.files} file${t.files === 1 ? '' : 's'}` : '—'}</span>
  ${t.touched ? `<span class="seg-paths">${paths}${more}</span>` : ''}
</li>`;
    })
    .join('\n');
  const caveat =
    reach.source === 'builtin'
      ? `<p class="reach-caveat">${L.builtinCaveat}</p>`
      : '';
  return `<div class="reach tone-${reach.tone}" id="reach">
  <p class="reach-head"><span class="reach-dot" aria-hidden="true"></span><b>${escapeHtml(reach.label)}</b><span class="reach-means">${escapeHtml(reach.means)}</span><span class="gen machine">${L.computedFromGit}</span></p>
  <ol class="reach-bar" aria-label="${L.reachAria}">${segs}</ol>
  ${caveat}
</div>`;
}

/** Who · how many · from when · reversible — four tiles, only when the narrative carries them. */
function renderExposure(exposure, g, L = DECK_LABELS.en) {
  if (!exposure) return '';
  const tiles = [
    [L.exposureWho, exposure.who],
    [L.exposureHowMany, exposure.howMany],
    [L.exposureWhen, exposure.when],
    [L.exposureReversible, exposure.reversible],
  ]
    .filter(([, v]) => v)
    .map(([k, v]) => `<div class="tile"><span class="tile-k">${k}</span><span class="tile-v">${proseHtml(v, g)}</span></div>`)
    .join('');
  return `<h3>${L.exposureTitle}</h3><div class="tiles" id="exposure">${tiles}</div>`;
}

/** Data / contract movement — only when stored data or an external contract moves. */
function renderDataChange(dataChange, g, L = DECK_LABELS.en) {
  if (!dataChange) return '';
  const rows = [
    [L.dataWhatMoves, dataChange.whatMoves],
    [L.dataCount, dataChange.count],
    [L.dataIrreversible, dataChange.irreversible],
    [L.dataOrder, dataChange.order],
    [L.dataConsumers, dataChange.consumers],
  ]
    .filter(([, v]) => v)
    .map(([k, v]) => `<dt>${k}</dt><dd>${proseHtml(v, g)}</dd>`)
    .join('');
  return `<h3>${L.dataChangeTitle}</h3><dl class="brief-grid data-change" id="data-change">${rows}</dl>`;
}

/** What breaks if this is wrong — the table every tier carries. */
function renderFailureModes(failureModes, g, L = DECK_LABELS.en) {
  if (!failureModes?.length) return '';
  const rows = failureModes
    .map(
      (f) => `<tr><td class="scenario">${proseHtml(f.scenario, g)}</td><td>${proseHtml(f.whoNotices, g)}</td><td>${proseHtml(f.detect, g)}</td><td>${proseHtml(f.mitigation, g)}</td></tr>`,
    )
    .join('\n');
  return `<h3>${L.failuresTitle}</h3>
  <table class="brief-table failures" id="failures"><thead><tr><th>${L.failuresScenario}</th><th>${L.failuresWho}</th><th>${L.failuresDetect}</th><th>${L.failuresMitigation}</th></tr></thead><tbody>${rows}</tbody></table>`;
}

/**
 * Structured diagram, drawn by the renderer from narrative data (no library, no author SVG):
 *   flow          — steps left to right; changed / new / removed steps are colour-coded
 *   before_after  — aspect · before → after rows
 */
function renderNarrativeDiagram(diagram, g, L = DECK_LABELS.en) {
  if (!diagram) return '';
  const title = diagram.title ? `<figcaption>${proseHtml(diagram.title, g)}</figcaption>` : '';
  if (diagram.kind === 'flow') {
    const steps = (diagram.steps ?? [])
      .map((st) => {
        const state = st.state || 'same';
        return `<li class="step state-${escapeHtml(state)}"><b>${proseHtml(st.label, g)}</b>${st.note ? `<small>${proseHtml(st.note, g)}</small>` : ''}</li>`;
      })
      .join('\n');
    return `<figure class="diagram-flow" id="diagram-flow">${title}<ol class="flow-steps">${steps}</ol>
  <p class="flow-legend"><span class="state-changed">${L.flowChanged}</span><span class="state-new">${L.flowNew}</span><span class="state-removed">${L.flowRemoved}</span><span class="state-same">${L.flowSame}</span></p></figure>`;
  }
  if (diagram.kind === 'before_after') {
    const rows = (diagram.rows ?? [])
      .map((r) => `<tr><th>${proseHtml(r.aspect, g)}</th><td class="before">${proseHtml(r.before, g)}</td><td class="arrow" aria-hidden="true">→</td><td class="after">${proseHtml(r.after, g)}</td></tr>`)
      .join('\n');
    return `<figure class="diagram-ba" id="diagram-before-after">${title}<table class="ba-table"><thead><tr><th></th><th>${L.before}</th><th></th><th>${L.after}</th></tr></thead><tbody>${rows}</tbody></table></figure>`;
  }
  return '';
}

/**
 * Human brief — the first screen. Every line answers a question a reviewer asks before reading
 * code: how far does this reach, what changed, who feels it, why now, how, what breaks if it is
 * wrong, what was given up, where to look, what is missing, how to undo. Labels follow the deck
 * locale (`DECK_LABELS`, English by default); the prose is in whatever language the author wrote.
 */
export function renderBriefSection(model) {
  const L = deckLabelsFor(model);
  const n = model.narrative;
  const g = model.glossary;
  const tradeoffRows = n.tradeoffs
    .map(
      (t) => `<tr><td>${proseHtml(t.topic, g)}</td><td><b>${proseHtml(t.chosen, g)}</b><br/><span class="muted">${proseHtml(t.why, g)}</span></td><td>${proseHtml(t.rejected, g)}</td><td class="cost">${proseHtml(t.cost, g)}</td></tr>`,
    )
    .join('\n');
  const changedPaths = new Set((model.nameStatusRows ?? []).map((row) => row?.path));
  const focusItems = n.reviewFocus
    .map((f, i) => {
      const where = linkChangedPaths(f.where, changedPaths, g);
      return `<li><span class="no">${i + 1}</span><span class="where">${where}</span><span class="check">${proseHtml(f.check, g)}</span><span class="risk">${L.ifWrong} · ${proseHtml(f.riskIfWrong, g)}</span></li>`;
    })
    .join('\n');
  const gaps = n.knownGaps.map((x) => `<li>${proseHtml(x, g)}</li>`).join('');
  const scope = n.outOfScope.map((x) => `<li>${proseHtml(x, g)}</li>`).join('');
  return `<section class="card brief tone-${escapeHtml(model.reach?.tone ?? 'green')}" id="brief">
  ${renderReachBanner(model.reach, L)}
  <p class="brief-headline">${proseHtml(n.what, g)}</p>
  <dl class="brief-grid">
    <dt>${L.forWhom}</dt><dd>${proseHtml(n.forWhom, g)}</dd>
    <dt>${L.why}</dt><dd>${proseHtml(n.why, g)}</dd>
    <dt>${L.how}</dt><dd>${proseHtml(n.how, g)}</dd>
  </dl>
  ${renderExposure(n.exposure, g, L)}
  ${renderDataChange(n.dataChange, g, L)}
  ${renderFailureModes(n.failureModes, g, L)}
  ${renderNarrativeDiagram(n.diagram, g, L)}
  <h3>${L.tradeoffsTitle}</h3>
  <table class="brief-table" id="tradeoffs"><thead><tr><th>${L.tradeoffDecision}</th><th>${L.tradeoffChosen}</th><th>${L.tradeoffRejected}</th><th>${L.tradeoffCost}</th></tr></thead><tbody>${tradeoffRows}</tbody></table>
  <h3>${L.reviewFocusTitle}</h3>
  <ol class="brief-focus">${focusItems}</ol>
  <div class="brief-gaps" style="margin-top:14px">
    <div><p class="gap-title">${L.gapsTitle}</p><ul>${gaps}</ul></div>
    ${scope ? `<div><p class="gap-title">${L.outOfScopeTitle}</p><ul>${scope}</ul></div>` : ''}
  </div>
  <p class="brief-rollback">${L.rollback} · <code>${escapeHtml(n.rollback)}</code>${n.next ? `<br/>${L.next} · ${proseHtml(n.next, g)}` : ''}</p>
</section>`;
}

/**
 * Renders `where` as prose, turning only the changed-path tokens into links to the file tree:
 * `the chip loop in scripts/build.mjs,` → the chip loop in <a><code>scripts/build.mjs</code></a>,
 * (Korean particles glued to the path, `build.mjs의`, split the same way.)
 * The sentence stays prose (glossary tooltips intact); only the path is monospace.
 */
function linkChangedPaths(where, changedPaths, glossary) {
  return String(where ?? '')
    .trim()
    .split(/\s+/)
    .map((tok) => {
      const m = splitPathMention(tok);
      if (!m || !changedPaths.has(m.core)) return proseHtml(tok, glossary);
      return `${escapeHtml(m.lead)}<a href="#structure"><code>${escapeHtml(m.core)}</code></a>${escapeHtml(m.rest)}`;
    })
    .join(' ');
}

/**
 * Opens every <details> around a fragment target so anchors into folded evidence always land —
 * on load, on hash change, and on every in-page click (a re-click of the current hash fires no
 * hashchange, and the reader may have folded the box again since).
 */
const REVEAL_JS = `
(function () {
  function revealId(id) {
    var el = id && document.getElementById(id); if (!el) return;
    for (var d = el.closest('details'); d; d = d.parentElement && d.parentElement.closest('details')) d.open = true;
    el.scrollIntoView();
  }
  function reveal() { revealId(location.hash.slice(1)); }
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest && e.target.closest('a[href^="#"]');
    if (a) revealId(a.getAttribute('href').slice(1));
  });
  window.addEventListener('hashchange', reveal); reveal();
})();`;

/** Folds a rendered section under a one-line summary. Empty sections fold to nothing. */
function fold(summary, html, { open = false } = {}) {
  if (!html) return '';
  return `<details class="evidence"${open ? ' open' : ''}><summary>${summary}</summary>${html}</details>`;
}

function renderRequirementTrace(model) {
  if (!model.narrative.requirements.length) return '';
  const cards = model.narrative.requirements
    .map((requirement) => {
      const implementation = requirement.implementation
        .map(
          (item) => `<div class="trace-box"><code>${escapeHtml(item.path)}</code><br/>${proseHtml(item.change, model.glossary)}</div>`,
        )
        .join('');
      return `<article class="trace-card">
  <h3>${escapeHtml(requirement.id)} · ${proseHtml(requirement.need, model.glossary)}</h3>
  <p class="muted">Rationale · ${proseHtml(requirement.why, model.glossary)}</p>
  <div class="trace-grid">
    <div class="trace-box"><b>Requirement</b><br/>${proseHtml(requirement.need, model.glossary)}</div>
    <div class="trace-arrow" aria-hidden="true">→</div>
    <div class="trace-impl">${implementation}</div>
  </div>
  <p class="trace-validation">Validation · ${proseHtml(requirement.validation, model.glossary)}</p>
</article>`;
    })
    .join('\n');
  const map = renderVisualFigure({
    svg: renderTraceMapSvg(model.traceGraph),
    caption: 'Requirements → Implementation File Mapping',
    note: 'Dotted lines / ⚠ represent changed files not linked to any requirement (coverage gap)',
  });
  return `<section class="card" id="traceability">
  <h2>Requirements → Implementation Traceability <span class="gen machine">Diagram verified against git changesets</span></h2>
  ${map}
  <div class="trace-list">${cards}</div>
</section>`;
}

function renderDecisionDiagram(model) {
  if (!model.diagramSvg) return '';
  if (!isSafeDiagramSvg(model.diagramSvg)) {
    return `<section class="card" id="diagram"><h2>Behavior & Structure Visualization</h2><p class="muted">Diagram omitted due to SVG safety check failure.</p></section>`;
  }
  return `<section class="card" id="diagram">
  <h2>Behavior & Structure Visualization <span class="gen ai">AI-authored · Supporting visual</span></h2>
  <div class="diagram">${model.diagramSvg}</div>
</section>`;
}

function renderFileTreeNodes(nodes, noteByPath, glossary, root = false) {
  const items = nodes
    .map((node) => {
      if (node.type === 'directory') {
        return `<li class="tree-node" role="treeitem" aria-expanded="true">
  <div class="tree-dir-label">▾ ${escapeHtml(node.name)}/</div>
  ${renderFileTreeNodes(node.children, noteByPath, glossary)}
</li>`;
      }
      const note = noteByPath.get(node.path);
      const noteHtml = note
        ? `<p class="tree-note">${proseHtml(note.change ?? '', glossary)}<br/><span class="tree-reason">Reason · ${proseHtml(note.reason ?? '', glossary)}</span></p>`
        : '';
      return `<li class="tree-node tree-file" role="treeitem">
  <div class="tree-file-head">${fileBadge(node.kind)} <code>${escapeHtml(node.name)}</code></div>
  ${noteHtml}
</li>`;
    })
    .join('\n');
  return `<ul class="tree" role="${root ? 'tree' : 'group'}">${items}</ul>`;
}

function renderFileTreeSection(model) {
  const noteByPath = new Map(model.narrative.fileNotes.map((note) => [note.path, note]));
  const noteLabel = noteByPath.size ? 'git paths + AI rationale' : 'git paths';
  return `<section class="card" id="structure"><span id="changes"></span>
  <h2>Change Structure <span class="gen machine">${noteLabel}</span></h2>
  ${renderFileTreeNodes(model.fileTree, noteByPath, model.glossary, true)}
</section>`;
}

function renderContractChanges(narrative) {
  const apiRows = narrative.apiChanges
    .map((item) => `<li><code>${escapeHtml(item.surface)}</code> · ${escapeHtml(item.before)} → ${escapeHtml(item.after)} (${escapeHtml(item.compat)})</li>`)
    .join('');
  const specRows = narrative.specChanges
    .map((item) => `<li><code>${escapeHtml(item.doc)}</code> · ${escapeHtml(item.change)}</li>`)
    .join('');
  if (!apiRows && !specRows) return '';
  return `<div class="risk-box"><h3>Contract & Spec Changes</h3>${apiRows ? `<ul>${apiRows}</ul>` : ''}${specRows ? `<ul>${specRows}</ul>` : ''}</div>`;
}

/** Legacy impact / regression prose and contract lists — folded, and only when the author wrote them. */
function renderImpactSection(model) {
  const narrative = model.narrative;
  const g = model.glossary;
  const contracts = renderContractChanges(narrative);
  if (!narrative.impact && !narrative.regressionRisk && !contracts) return '';
  return `<section class="card" id="impact">
  <h2>Impact & Risks <span class="gen ai">AI-authored · rollback is in the brief above</span></h2>
  <div class="risk-grid">
    ${narrative.impact ? `<div class="risk-box"><h3>Blast Radius</h3>${proseHtml(narrative.impact, g)}</div>` : ''}
    ${narrative.regressionRisk ? `<div class="risk-box"><h3>Regression Risk & Mitigation</h3>${proseHtml(narrative.regressionRisk, g)}</div>` : ''}
    ${contracts}
  </div>
</section>`;
}

/** Everything below the brief: evidence a reviewer opens on demand. Empty sections fold to nothing. */
function renderEvidenceFolds(model, stats, L = DECK_LABELS.en) {
  const churn = `${stats.files ?? 0} files · +${stats.added ?? 0} −${stats.deleted ?? 0}`;
  return [
    fold(L.foldOrigin, model.origin ? renderOriginSection(model.origin) : ''),
    fold(`${L.foldChangedFiles} <span class="muted-count">${churn}</span>`, renderFileTreeSection(model)),
    fold(`${L.foldRequirements} <span class="muted-count">requirements ${model.narrative.requirements.length}</span>`, renderRequirementTrace(model)),
    fold(L.foldImpact, renderImpactSection(model)),
    fold(L.foldImpactMap, renderImpactMapSection(model.signals?.impactMap, { readFirstTitle: 'Suggested read order' })),
    fold(L.foldDiagram, renderDecisionDiagram(model)),
    fold(L.foldGlossary, renderGlossarySection(model)),
    fold(L.foldSources, renderAppendix(model)),
  ].join('\n');
}

/** Title line: branch, base, time, size — and, when no original request was recorded, where to put it. */
function renderDeckHeader(model, stats) {
  const generated = model.generatedAt ? `Generated ${escapeHtml(model.generatedAt)}` : 'Generation timestamp unavailable';
  const originNote = model.origin
    ? ''
    : ` · original request not recorded (no <code>## Original Request</code> in worktree PLAN.md and no <code>${escapeHtml(PASSPORT_RELPATH)}</code>) — check request ↔ result by hand`;
  return `  <header>
    <h1>Pre-Ship Review</h1>
    <p class="muted small"><code>${escapeHtml(model.branch)}</code> · Base <code>${escapeHtml(model.baseRef)}</code> · ${generated} · ${escapeHtml(String(stats.files ?? 0))} files · ${escapeHtml(String(stats.commits ?? 0))} commits${originNote}</p>
  </header>`;
}

/**
 * Deck model → Self-contained HTML string.
 */
export function renderDeckHtml(model) {
  if (!model.narrative || model.narrativeErrors?.length) {
    throw new Error(`ship-deck narrative contract violation: ${(model.narrativeErrors || ['no narrative']).join('; ')}`);
  }
  const hasSignals = Boolean(model.signals?.risks?.length || model.signals?.coverage?.missing?.length);
  const stats = model.stats ?? {};
  const L = deckLabelsFor(model);
  return `<!doctype html>
<html lang="${L.lang}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Pre-Ship Review — ${escapeHtml(model.branch)}</title>
<style>${DECK_CSS}${DECK_VISUAL_CSS}</style>
</head>
<body>
<main>
${renderDeckHeader(model, stats)}
${renderBriefSection(model)}
${hasSignals ? renderScorecardSection(model.signals, { title: L.scorecardTitle }) : ''}
${renderEvidenceFolds(model, stats, L)}
</main>
<script>${REVEAL_JS}</script>
</body>
</html>
`;
}
