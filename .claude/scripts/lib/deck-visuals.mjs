/**
 * deck-visuals.mjs — Machine-generated visual figures for review decks (pure function, render layer)
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Measured 0 `<svg>` elements in deck outputs (`.tmp/ship-deck/<branch>/index.html`,
 *       `.tmp/review-deck/<key>/<stage>/index.html`, 2026-07-25). Humans review far more effectively
 *       when figures are present, yet decks only had text, tables, and single bars.
 *   (b) Gaps: Visualizations relied solely on the optional `--diagram <svg>` — requiring AI to write SVG by hand
 *       and pass `isSafeDiagramSvg` without any mandate in SKILL.md.
 *   (c) Simpler alternatives comparison: "Mandate SVG writing by AI" risks prose restatement and is unverifiable (R-CM-024 spirit).
 *       "Mermaid/chart CDN" violates self-contained HTML principle.
 *       Adopted: Pure-function SVGs rendered deterministically from **pre-existing model data** (zero external dependencies).
 *
 * All functions assemble only escaped strings without generating `<script>` or event handlers —
 * unlike `--diagram` injected SVG, this is a trusted code path (author is code).
 *
 * Boundary (R-CM-028): perspective1-only — same deployment isolation as deck assets.
 */

import { escapeHtml } from './ship-deck-core.mjs';
import { RISK_ORDER } from './deck-signals.mjs';
import { IMPACT_LABEL } from './change-taxonomy.mjs';
import { PASSPORT_RELPATH as PASSPORT_HINT } from './review-origin.mjs';

/** Deck palette — mirrors DECK_CSS values (SVGs duplicate constants because some renderers cannot read CSS variables) */
const COLOR = {
  bg: '#0d1117',
  line: '#30363d',
  text: '#e6edf3',
  muted: '#8b949e',
  dim: '#9da7b3',
  accent: '#58a6ff',
  ok: '#2ea45f',
  okBright: '#3fb950',
  warn: '#d4a72c',
  bad: '#e5534b',
  purple: '#a371f7',
};

const RISK_COLOR = { critical: COLOR.bad, major: COLOR.warn, info: COLOR.muted };
const RISK_LABEL = { critical: 'Critical', major: 'Major', info: 'Info' };

/** Truncates label at end — leading words carry identifying information */
export function truncateLabel(text, max = 18) {
  const s = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max - 1)}…`;
}

/** Wide character detection (CJK/fullwidth) — SVG lacks auto-wrap, requiring explicit width estimation */
const WIDE_CHAR_RE =
  /[ᄀ-ᇿ⺀-㿿㄰-㆏㐀-䶿一-鿿가-힯豈-﫿＀-｠￠-￦]/;

/** Estimates rendered text width in px — fullwidth equals font size, others ~0.55x */
export function estimateTextWidth(text, fontSize) {
  let width = 0;
  for (const ch of String(text ?? '')) {
    width += WIDE_CHAR_RE.test(ch) ? fontSize : fontSize * 0.55;
  }
  return width;
}

/** Truncates text at end to fit estimated width budget in px */
export function truncateToWidth(text, maxPx, fontSize) {
  const s = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (!s || maxPx <= 0) return '';
  if (estimateTextWidth(s, fontSize) <= maxPx) return s;
  const ellipsisPx = estimateTextWidth('…', fontSize);
  const out = [];
  let width = 0;
  for (const ch of s) {
    const next = width + estimateTextWidth(ch, fontSize);
    if (next + ellipsisPx > maxPx) break;
    out.push(ch);
    width = next;
  }
  return out.length ? `${out.join('')}…` : '…';
}

/** Truncates path at start to fit estimated width budget (filename at end is distinguishing info) */
export function truncatePathToWidth(path, maxPx, fontSize) {
  const s = String(path ?? '');
  if (!s || maxPx <= 0) return '';
  if (estimateTextWidth(s, fontSize) <= maxPx) return s;
  const ellipsisPx = estimateTextWidth('…', fontSize);
  const chars = [...s];
  const out = [];
  let width = 0;
  for (let i = chars.length - 1; i >= 0; i -= 1) {
    const next = width + estimateTextWidth(chars[i], fontSize);
    if (next + ellipsisPx > maxPx) break;
    out.unshift(chars[i]);
    width = next;
  }
  return out.length ? `…${out.join('')}` : '…';
}

const TRACE_ROW_H = 28;

/**
 * Requirements -> Implementation files traceability map (bipartite).
 * Explicitly marks unlinked items on both sides.
 */
export function renderTraceMapSvg(graph) {
  const nodes = Array.isArray(graph?.nodes) ? graph.nodes : [];
  const files = Array.isArray(graph?.files) ? graph.files : [];
  if (!nodes.length && !files.length) return '';
  const width = 900;
  const leftW = 250;
  const rightW = 380;
  const leftX = 12;
  const rightX = width - rightW - 12;
  const rows = Math.max(nodes.length, files.length);
  const height = rows * TRACE_ROW_H + 34;
  const yOf = (i, count) => 24 + i * TRACE_ROW_H + (rows - count) * (TRACE_ROW_H / 2) + TRACE_ROW_H / 2;

  const fileIndex = new Map(files.map((f, i) => [f.path, i]));
  const links = nodes.flatMap((node) =>
    (node.targets ?? [])
      .filter((path) => fileIndex.has(path))
      .map((path) => {
        const y1 = yOf(nodes.indexOf(node), nodes.length);
        const y2 = yOf(fileIndex.get(path), files.length);
        const x1 = leftX + leftW;
        const x2 = rightX;
        const mid = (x1 + x2) / 2;
        return `<path d="M ${x1} ${y1.toFixed(1)} C ${mid} ${y1.toFixed(1)}, ${mid} ${y2.toFixed(1)}, ${x2} ${y2.toFixed(1)}"
    fill="none" stroke="${COLOR.accent}" stroke-width="1.4" opacity="0.75" />`;
      }),
  );

  const leftBoxes = nodes
    .map((node, i) => {
      const y = yOf(i, nodes.length);
      const orphan = !(node.targets ?? []).length;
      const color = orphan ? COLOR.bad : COLOR.line;
      const label = `${node.label}${node.need ? ` · ${truncateLabel(node.need, 16)}` : ''}`;
      return `<g>
    <rect x="${leftX}" y="${(y - 11).toFixed(1)}" width="${leftW}" height="22" rx="6" fill="${COLOR.bg}" stroke="${color}" />
    <text x="${leftX + 9}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${COLOR.text}">${escapeHtml(truncateToWidth(label, leftW - 18, 11))}</text>
    ${orphan ? `<text x="${leftX + leftW + 6}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${COLOR.bad}">⚠ Unlinked implementation</text>` : ''}
  </g>`;
    })
    .join('\n  ');

  const rightBoxes = files
    .map((file, i) => {
      const y = yOf(i, files.length);
      const color = file.orphan ? COLOR.bad : COLOR.line;
      return `<g>
    <rect x="${rightX}" y="${(y - 11).toFixed(1)}" width="${rightW}" height="22" rx="6" fill="${COLOR.bg}" stroke="${color}" ${file.orphan ? 'stroke-dasharray="4 3" ' : ''}/>
    <text x="${rightX + 9}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${file.orphan ? COLOR.muted : COLOR.text}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">${escapeHtml(truncatePathToWidth(file.path, rightW - 18, 11))}</text>
    ${file.orphan ? `<text x="${rightX - 8}" y="${(y + 4).toFixed(1)}" font-size="11" fill="${COLOR.bad}" text-anchor="end">⚠</text>` : ''}
  </g>`;
    })
    .join('\n  ');

  const orphanCount = files.filter((f) => f.orphan).length;
  return `<svg class="deck-svg" viewBox="0 0 ${width} ${height}" width="100%" height="${height}" role="img"
  aria-label="Traceability between ${nodes.length} requirements and ${files.length} changed files. ${orphanCount} files unlinked to requirements">
  <text x="${leftX}" y="14" font-size="10" fill="${COLOR.dim}">Requirements</text>
  <text x="${rightX}" y="14" font-size="10" fill="${COLOR.dim}">Implementation Files</text>
  ${links.join('\n  ')}
  ${leftBoxes}
  ${rightBoxes}
</svg>`;
}

const MATRIX_ROW_H = 22;
const MATRIX_MAX_ROWS = 16;

/**
 * Readiness matrix — Row (requirements) x Column (judgment criteria) grid.
 * Visually distinguishes filled and empty criteria at a glance (CP-SPEC).
 */
export function renderReadinessMatrixSvg({ rows = [], columns = [] } = {}) {
  const visible = rows.slice(0, MATRIX_MAX_ROWS);
  if (!visible.length || !columns.length) return '';
  const hidden = rows.length - visible.length;
  const width = 900;
  const labelW = 190;
  const colW = Math.min(150, (width - labelW - 16) / columns.length);
  const height = visible.length * MATRIX_ROW_H + 46 + (hidden > 0 ? 16 : 0);

  const headers = columns
    .map(
      (col, ci) =>
        `<text x="${(labelW + ci * colW + colW / 2).toFixed(1)}" y="18" text-anchor="middle" font-size="10" fill="${COLOR.dim}">${escapeHtml(truncateToWidth(col, colW - 6, 10))}</text>`,
    )
    .join('\n  ');

  const body = visible
    .map((row, ri) => {
      const y = 28 + ri * MATRIX_ROW_H;
      const cells = columns
        .map((_, ci) => {
          const filled = Boolean(row.cells?.[ci]);
          const cx = labelW + ci * colW + colW / 2;
          return filled
            ? `<g><rect x="${(cx - 9).toFixed(1)}" y="${(y + 3).toFixed(1)}" width="18" height="14" rx="4" fill="${COLOR.ok}" fill-opacity="0.28" stroke="${COLOR.ok}" /><text x="${cx.toFixed(1)}" y="${(y + 14).toFixed(1)}" text-anchor="middle" font-size="10" fill="${COLOR.okBright}">✓</text></g>`
            : `<g><rect x="${(cx - 9).toFixed(1)}" y="${(y + 3).toFixed(1)}" width="18" height="14" rx="4" fill="${COLOR.bg}" stroke="${COLOR.bad}" stroke-dasharray="3 2" /><text x="${cx.toFixed(1)}" y="${(y + 14).toFixed(1)}" text-anchor="middle" font-size="10" fill="${COLOR.bad}">·</text></g>`;
        })
        .join('');
      return `<g>
    <text x="4" y="${(y + 14).toFixed(1)}" font-size="11" fill="${COLOR.text}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">${escapeHtml(truncateToWidth(row.label, labelW - 12, 11))}</text>
    <line x1="4" y1="${(y + 20).toFixed(1)}" x2="${width - 8}" y2="${(y + 20).toFixed(1)}" stroke="${COLOR.line}" stroke-opacity="0.5" />
    ${cells}
  </g>`;
    })
    .join('\n  ');

  const filledCount = visible.reduce((s, r) => s + (r.cells ?? []).filter(Boolean).length, 0);
  const totalCells = visible.length * columns.length;
  const restNote = hidden > 0
    ? `<text x="4" y="${height - 6}" font-size="10" fill="${COLOR.muted}">Other ${hidden} items in requirement map below</text>`
    : '';
  return `<svg class="deck-svg" viewBox="0 0 ${width} ${height}" width="100%" height="${height}" role="img"
  aria-label="Requirement readiness — ${filledCount}/${totalCells} filled across ${visible.length} items × ${columns.length} columns">
  ${headers}
  ${body}
  ${restNote}
</svg>`;
}

/** Risk signal chip — Color + Label based on risk severity */
function riskChip(item) {
  const color = RISK_COLOR[item.level] ?? COLOR.muted;
  const body = `<span class="rk-level" style="color:${color}">${RISK_LABEL[item.level] ?? 'Info'}</span> ${escapeHtml(item.label)}`;
  const title = item.detail ? ` title="${escapeHtml(item.detail)}"` : '';
  return item.anchor
    ? `<a class="rk-chip" style="border-color:${color}" href="#${escapeHtml(item.anchor)}"${title}>${body} <span class="rk-go">↓</span></a>`
    : `<span class="rk-chip" style="border-color:${color}"${title}>${body}</span>`;
}

/** Risk chips container — Honestly reports when 0 issues detected */
function riskChipsHtml(risks) {
  if (!risks?.length) {
    return '<p class="muted small">No machine-detected risk signals — issues outside detector axes (narrative completeness / narrative↔actual mismatch / tests / contract surfaces / unwritten source) still require human judgment.</p>';
  }
  const sorted = [...risks].sort((a, b) => RISK_ORDER[a.level] - RISK_ORDER[b.level]);
  return `<div class="rk-chips">${sorted.map(riskChip).join('')}</div>`;
}

/** Unprovided narrative channel chips */
function missingChipsHtml(coverage) {
  const missing = coverage?.missing ?? [];
  if (!missing.length) return '';
  const chips = missing
    .map((m) => `<a class="chip" href="#${escapeHtml(m.anchor)}">${escapeHtml(m.label)}</a>`)
    .join(' ');
  return `<p class="sc-missing"><b>Missing narrative ${missing.length} items</b> ${chips}</p>`;
}

/**
 * Scorecard / Where to look first — topmost section of review decks.
 */
export function renderScorecardSection(signals, { title = 'Where to Look First' } = {}) {
  if (!signals) return '';
  const { coverage, risks } = signals;
  return `<section class="card scorecard" id="scorecard">
  <h2>${escapeHtml(title)} <span class="gen machine">Machine Detected</span></h2>
  <div class="sc-body">
    ${riskChipsHtml(risks)}
    ${missingChipsHtml(coverage)}
  </div>
</section>`;
}

/**
 * Original request + AI interpretation section.
 */
export function renderOriginSection(origin) {
  if (!origin) {
    return `<section class="card origin" id="origin">
  <h2>Original Request <span class="gen machine">Session Record</span></h2>
  <p class="muted">No original request recorded (missing <code>${escapeHtml(PASSPORT_HINT)}</code>) — request↔result verification must be performed manually.</p>
</section>`;
  }
  const staleWarn = origin.stale
    ? '<p class="narrative-missing">AI interpretation was recorded against instructions different from this request (request hash mismatch at interpretation time) — task may be misaligned.</p>'
    : '';
  const sharedWarn = origin.shared
    ? `<p class="muted small">This request was read from a session-shared file (<code>${escapeHtml(PASSPORT_HINT)}</code>) — concurrent multi-terminal usage may show requests from another session. If a <code>## Original Request</code> section exists in worktree PLAN.md, that text takes precedence.</p>`
    : '';
  const interp = origin.interpretation ?? {};
  const rows = [
    ['Goal', interp.goal],
    ['Scope', interp.scope?.join(' · ')],
    ['Assumptions', interp.assumptions?.join(' · ')],
    ['Verification', interp.verification?.join(' · ')],
  ]
    .filter(([, v]) => v)
    .map(([k, v]) => `<dt>${k}</dt><dd>${escapeHtml(v)}</dd>`)
    .join('\n');
  const sha = origin.sha256
    ? `<span class="muted small">Request hash ${escapeHtml(origin.sha256.slice(0, 12))}…</span>`
    : '';
  const recorded = origin.recordedAt
    ? ` <span class="muted small">· Interpretation recorded ${escapeHtml(origin.recordedAt)}</span>`
    : '';
  const sourceLabel =
    origin.source === 'plan_md'
      ? 'PLAN.md record — Not rewritten by AI'
      : origin.shared
        ? 'Session record (unidentified shared slot — may be from another session)'
        : 'Session record (this session slot)';
  return `<section class="card origin" id="origin">
  <h2>Original Request (Verbatim) <span class="gen machine">${escapeHtml(sourceLabel)}</span></h2>
  <blockquote class="origin-quote">${escapeHtml(origin.excerpt)}</blockquote>
  <p class="origin-meta">${sha}${recorded}</p>
  ${sharedWarn}
  ${staleWarn}
  ${rows ? `<h3>AI Interpretation <span class="gen ai">AI authored — compare with request above</span></h3><dl class="origin-interp">\n${rows}\n</dl>` : ''}
</section>`;
}

function impactBadge(impact) {
  const color = impact === 'global' ? COLOR.bad : impact === 'module' ? COLOR.warn : COLOR.muted;
  return `<span class="badge" style="border-color:${color};color:${color}">${escapeHtml(IMPACT_LABEL[impact] ?? impact)}</span>`;
}

/** Matrix cell — opacity proportional to file count */
function matrixCell(cell, rowLabel, colLabel, maxCell) {
  if (!cell.files) return '<td class="mx-0">·</td>';
  const ratio = maxCell ? Math.min(1, cell.files / maxCell) : 0;
  const alpha = (0.14 + ratio * 0.5).toFixed(2);
  const title = `${rowLabel} · ${colLabel} — ${cell.files} files, ${cell.churn.toLocaleString('en-US')} lines`;
  return `<td class="mx-c" style="background:rgba(88,166,255,${alpha})" title="${escapeHtml(title)}">${cell.files}</td>`;
}

/**
 * Area (feature/area) x Change nature matrix table.
 */
export function renderImpactMatrixTable(matrix) {
  const rows = matrix?.rows ?? [];
  const cols = matrix?.visibleColumns ?? [];
  if (!rows.length || !cols.length) return '';
  const colIdx = cols.map((c) => matrix.columns.findIndex((x) => x.id === c.id));
  const max = matrix.totals?.maxCell ?? 0;
  const head = cols.map((c) => `<th>${escapeHtml(c.label)}</th>`).join('');
  const body = rows
    .map((r) => {
      const cells = colIdx
        .map((ci, i) => matrixCell(r.cells[ci], r.label, cols[i].label, max))
        .join('');
      const mark = r.kind === 'feature' ? ' <span class="muted small">(registered feature)</span>' : '';
      return `<tr>
    <th class="mx-r">${escapeHtml(r.label)}${mark}<br/>${impactBadge(r.impact)}</th>
    ${cells}
    <td class="mx-t">${r.files}</td>
    <td class="num"><span class="add">+${r.added}</span> <span class="del">-${r.deleted}</span></td>
  </tr>`;
    })
    .join('\n');
  const t = matrix.totals ?? {};
  const foot = colIdx
    .map((ci) => `<td class="mx-t">${t.perNature?.[ci]?.files ?? 0}</td>`)
    .join('');
  const kinds = Object.entries(t.kinds ?? {})
    .filter(([, v]) => v)
    .map(([k, v]) => `${k} ${v}`)
    .join(' · ');
  return `<table class="mx-table">
  <thead><tr><th class="mx-corner">Where \\ What</th>${head}<th class="mx-t">Total</th><th>Lines</th></tr></thead>
  <tbody>
${body}
  </tbody>
  <tfoot><tr><th class="mx-r">Total</th>${foot}<td class="mx-t">${t.files ?? 0}</td><td class="num"><span class="add">+${t.added ?? 0}</span> <span class="del">-${t.deleted ?? 0}</span></td></tr></tfoot>
</table>
<p class="muted small">${escapeHtml(kinds)}</p>`;
}

const KIND_LETTER = { NEW: 'N', EDIT: 'M', DELETE: 'D', RENAME: 'R' };

/** "Where to look first" list renderer */
function renderReadFirstList(readFirst, title = 'Where to Look First') {
  const items = readFirst?.items ?? [];
  if (!items.length) return '';
  const rows = items
    .map((f, i) => {
      const why = f.why ? `<span class="rf-why">${escapeHtml(f.why)}</span>` : '';
      const hint = f.intentHint
        ? '<span class="muted small">To grasp change intent first, start here</span>'
        : '';
      return `<div class="rf-row">
    <span class="rf-no">${i + 1}</span>
    <span class="rf-kind">${escapeHtml(KIND_LETTER[f.kind] ?? 'M')}</span>
    <code class="rf-path">${escapeHtml(f.path)}</code>
    ${why}${hint}
    <span class="rf-nums"><span class="add">+${f.added}</span> <span class="del">-${f.deleted}</span></span>
  </div>`;
    })
    .join('\n');
  const rest = readFirst.hidden
    ? `<p class="muted small">Remaining ${readFirst.hidden} files can be viewed by bundle in "Changes" below.</p>`
    : '';
  return `<h3>${escapeHtml(title)} <span class="gen machine">Contract surfaces → Global impact → Churn order</span></h3>
  <div class="rf-list">${rows}</div>
  ${rest}`;
}

const EFFECT_COLOR = { warn: COLOR.warn, ok: COLOR.dim };

/** 3-column ledger: What changed · Why · What impact */
function renderLedgerTable(ledger) {
  if (!ledger?.length) return '';
  const rows = ledger
    .map((row) => {
      const reasons = row.reasons.length
        ? row.reasons.map((r) => `<p class="lg-why">${escapeHtml(r)}</p>`).join('')
        : '<p class="lg-why muted">This bundle has no why (reason for change) description — approving without explanation.</p>';
      const missing = row.missingReason
        ? `<p class="muted small">Missing description in ${row.missingReason} files</p>`
        : '';
      const effects = row.effects
        .map(
          (e) =>
            `<div class="lg-effect" style="color:${EFFECT_COLOR[e.level] ?? COLOR.dim}">${escapeHtml(e.text)}</div>`,
        )
        .join('');
      return `<tr>
    <td><b>${escapeHtml(row.area)}</b><div class="muted small">${row.files} files · ${escapeHtml(row.natures.join(' · '))}</div>${row.lead ? `<div class="lg-lead">${escapeHtml(row.lead)}</div>` : ''}</td>
    <td>${reasons}${missing}</td>
    <td>${impactBadge(row.impact)}${effects}</td>
  </tr>`;
    })
    .join('\n');
  return `<h3>What Changed · Why · What Impact <span class="gen ai">Why = AI authored</span> <span class="gen machine">Impact = Machine evaluated</span> — ${ledger.length} bundles</h3>
  <table class="lg-table">
    <thead><tr><th style="width:28%">What Changed</th><th style="width:38%">Why Changed</th><th>What Impact</th></tr></thead>
    <tbody>
${rows}
    </tbody>
  </table>`;
}

/** Cross-check block between AI declarations and machine ownership set */
function renderDeclarationCompare(featureImpact) {
  const declaredChips = featureImpact.declared?.length
    ? `<p class="fi-declared"><span class="gen ai">AI declared affected features</span> ${featureImpact.declared.map((d) => `<code>${escapeHtml(d)}</code>`).join(' ')}</p>`
    : '<p class="muted small">AI did not specify affected features — no machine comparison baseline.</p>';
  const notJudgeable =
    featureImpact.declared?.length && featureImpact.declarationJudgeable === false
      ? '<p class="muted small">Ownership index coverage is too low to evaluate this declaration by machine — absence from machine set means "index does not yet know this area" rather than "incorrect".</p>'
      : '';
  const declaredOnly = featureImpact.declaredOnly?.length
    ? `<p class="narrative-missing">Items missing from machine ownership set: ${featureImpact.declaredOnly.map((d) => `<code>${escapeHtml(d)}</code>`).join(' ')} — indicates name mismatch or misidentified impact scope.</p>`
    : '';
  const machineOnly = featureImpact.machineOnly?.length
    ? `<p class="narrative-missing">Features owning files not declared by AI: ${featureImpact.machineOnly.map((d) => `<code>${escapeHtml(d)}</code>`).join(' ')} — indicates omitted impact scope.</p>`
    : '';
  return `${declaredChips}${notJudgeable}${declaredOnly}${machineOnly}`;
}

/** Impacted features cards */
function renderFeatureCards(featureImpact) {
  if (!featureImpact) return '';
  const cov = featureImpact.coverage ?? {};
  const covNote = `<p class="muted small">Feature ownership index comparison — ${cov.mappedFiles ?? 0} of ${cov.totalFiles ?? 0} changed files are owned by registered features (${cov.registeredFeatures ?? 0}). Unmapped files are pre-feature infrastructure (tooling/rules); low coverage means impact scope cannot be judged from this table alone.</p>`;
  const cards = (featureImpact.features ?? [])
    .map((f) => {
      const untouched = f.untouchedAnchors.length
        ? `<p class="fi-keep"><b>Intact</b> ${f.untouchedAnchors
            .slice(0, 4)
            .map((p) => `<code>${escapeHtml(p)}</code>`)
            .join(' ')}${f.untouchedAnchors.length > 4 ? ` <span class="muted">and ${f.untouchedAnchors.length - 4} others</span>` : ''}</p>`
        : '<p class="muted small">All registered anchor files for this feature were modified.</p>';
      const test = f.testTouched
        ? '<span class="badge" style="border-color:#2ea45f;color:#3fb950">With tests</span>'
        : '<span class="badge" style="border-color:#d4a72c;color:#d4a72c">No test changes</span>';
      return `<article class="fi-card">
    <h4>${escapeHtml(f.title)} ${test}</h4>
    <p class="muted small">${escapeHtml(f.domain ?? 'Domain unspecified')} · Status ${escapeHtml(f.status ?? 'unrecorded')} · ${f.files} files · ${escapeHtml(f.natures.join(' · '))}</p>
    <p class="fi-changed"><b>Changed</b> ${f.changedPaths.map((p) => `<code>${escapeHtml(p)}</code>`).join(' ')}</p>
    ${untouched}
  </article>`;
    })
    .join('\n');
  const declared = renderDeclarationCompare(featureImpact);
  const body = cards
    ? `<p class="muted small">Below are <b>machine-evaluated</b> owning features — compare with declaration above.</p><div class="fi-grid">${cards}</div>`
    : '<p class="muted">No changed files are owned by registered features — feature-level impact should be judged via matrix areas above.</p>';
  return `<h3>Affected Features <span class="gen machine">docs/features ownership index comparison</span></h3>
  ${covNote}
  ${declared}
  ${body}`;
}

/** Contract surfaces grid */
function renderContractGrid(contracts) {
  const surfaces = contracts?.surfaces ?? [];
  if (!surfaces.length) return '';
  const cells = surfaces
    .map((s) => {
      const paths = s.changed
        ? `<div class="cs-paths">${s.paths.slice(0, 5).map((p) => `<code>${escapeHtml(p)}</code>`).join(' ')}${s.paths.length > 5 ? ` <span class="muted">and ${s.paths.length - 5} others</span>` : ''}</div>
      <div class="cs-q">${escapeHtml(s.question)}</div>`
        : '<div class="muted small">This change does not touch this contract.</div>';
      return `<div class="cs-item${s.changed ? ' cs-changed' : ''}">
    <div class="cs-head"><b>${escapeHtml(s.label)}</b> <span class="badge" style="border-color:${s.changed ? COLOR.warn : COLOR.line};color:${s.changed ? COLOR.warn : COLOR.muted}">${s.changed ? 'Changed' : 'Intact'}</span></div>
    ${paths}
  </div>`;
    })
    .join('\n');
  return `<h3>Contract Surfaces — Exposed Commitments <span class="gen machine">Path convention measured</span></h3>
  <p class="muted small">${contracts.changedCount} changes / ${surfaces.length} inspected surfaces. "Intact" indicates machine verification that the contract was not touched.</p>
  <div class="cs-grid">${cells}</div>`;
}

/** Area x Nature matrix block */
function renderMatrixBlock(matrix) {
  const table = renderImpactMatrixTable(matrix);
  if (!table) return '';
  return `<h3>Where · What Changed <span class="gen machine">git + feature ownership index measured</span></h3>
  <p class="muted small">Vertical = Where changed (feature/area) · Horizontal = What changed (nature of change) · Darker indicates higher concentration.</p>
  ${table}`;
}

/**
 * Impact Map Section
 */
export function renderImpactMapSection(impactMap, { readFirstTitle } = {}) {
  if (!impactMap) return '';
  const body = [
    renderMatrixBlock(impactMap.matrix),
    renderReadFirstList(impactMap.readFirst, readFirstTitle),
    renderLedgerTable(impactMap.ledger),
    renderFeatureCards(impactMap.featureImpact),
    renderContractGrid(impactMap.contracts),
  ]
    .filter(Boolean)
    .join('\n  ');
  if (!body) return '';
  return `<section class="card impact-map" id="impact-map">
  <h2>Changes · Why · Impact</h2>
  ${body}
</section>`;
}

/** Visual figure wrapper */
export function renderVisualFigure({ svg, caption, note }) {
  if (!svg) return '';
  return `<figure class="visual-figure">
  ${svg}
  <figcaption class="visual-caption">${escapeHtml(caption ?? '')}${note ? ` <span class="muted">— ${escapeHtml(note)}</span>` : ''}</figcaption>
</figure>`;
}

/** Deck visual CSS */
export const DECK_VISUAL_CSS = `
.scorecard { border-left: 4px solid #58a6ff; }
.sc-body { display: grid; gap: 10px; min-width: 0; }
.rk-chips { display: flex; flex-wrap: wrap; gap: 6px; }
.rk-chip { display: inline-flex; align-items: center; gap: 5px; border: 1px solid #30363d;
  border-radius: 999px; padding: 3px 10px; font-size: 12px; color: #e6edf3;
  text-decoration: none; background: #0d1117; }
a.rk-chip:hover { background: #161b22; }
.rk-level { font-size: 10px; font-weight: 700; }
.rk-go { color: #58a6ff; font-size: 11px; }
.sc-missing { font-size: 12px; color: #d4a72c; margin: 0; display: flex; flex-wrap: wrap;
  gap: 6px; align-items: center; }
.sc-missing a.chip { color: #d4a72c; text-decoration: none; border-color: #6b5620; }
.sc-missing a.chip:hover { background: #2b2111; }
.visual-figure { margin: 12px 0 4px; padding: 10px 10px 6px; background: #0d1117;
  border: 1px solid #30363d; border-radius: 8px; overflow-x: auto; }
.deck-svg { display: block; min-width: 520px; }
.visual-caption { font-size: 11.5px; color: #8b949e; margin-top: 6px; }
.check-item[data-severity="critical"] { border-left: 3px solid #e5534b; }
.check-item[data-severity="major"] { border-left: 3px solid #d4a72c; }
.check-item[data-severity="info"] { border-left: 3px solid #6e7681; }
.origin { border-left: 4px solid #d4a72c; }
.origin-quote { margin: 0; padding: 10px 14px; background: #0d1117; border: 1px solid #30363d;
  border-left: 3px solid #d4a72c; border-radius: 6px; font-size: 13.5px; line-height: 1.7;
  white-space: pre-wrap; color: #e6edf3; }
.origin-meta { margin: 6px 0 0; }
.origin-interp { display: grid; grid-template-columns: 52px 1fr; gap: 5px 12px; margin: 6px 0 0;
  font-size: 13px; }
.origin-interp dt { color: #9da7b3; }
.origin-interp dd { margin: 0; line-height: 1.6; }
.mx-table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin: 10px 0 4px; }
.mx-table th, .mx-table td { border: 1px solid #30363d; padding: 6px 8px; text-align: center;
  vertical-align: middle; }
.mx-table thead th, .mx-table tfoot th { color: #9da7b3; background: #11161d; font-weight: 600; }
.mx-table th.mx-r, .mx-table th.mx-corner { text-align: left; color: #e6edf3; background: #11161d;
  font-weight: 600; line-height: 1.5; }
.mx-table td.mx-0 { color: #484f58; }
.mx-table td.mx-c { font-weight: 700; }
.mx-table td.mx-t, .mx-table th.mx-t { background: #11161d; font-weight: 700; }
.mx-table td.num { text-align: right; white-space: nowrap; }
.mx-table .add, .lg-table .add, .rf-nums .add { color: #3fb950; }
.mx-table .del, .lg-table .del, .rf-nums .del { color: #ff7b72; }
.impact-map { border-left: 4px solid #a371f7; }
.rf-list { display: grid; gap: 5px; margin: 8px 0 4px; }
.rf-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline; background: #0d1117;
  border: 1px solid #30363d; border-radius: 7px; padding: 7px 10px; font-size: 12.5px; }
.rf-no { color: #8b949e; min-width: 14px; font-variant-numeric: tabular-nums; }
.rf-kind { border: 1px solid #30363d; border-radius: 4px; padding: 0 5px; font-size: 10.5px;
  color: #9da7b3; }
.rf-path { word-break: break-all; }
.rf-why { color: #d4a72c; font-size: 12px; }
.rf-nums { margin-left: auto; white-space: nowrap; font-size: 11.5px; }
.lg-table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin: 8px 0 4px; }
.lg-table th, .lg-table td { border: 1px solid #30363d; padding: 8px 9px; text-align: left;
  vertical-align: top; line-height: 1.55; }
.lg-table th { color: #9da7b3; background: #11161d; }
.lg-lead { margin-top: 4px; color: #e6edf3; }
.lg-why { margin: 0 0 5px; }
.lg-effect { font-size: 12px; margin-top: 4px; }
.fi-grid, .cs-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px;
  margin: 8px 0 4px; }
.fi-card, .cs-item { background: #0d1117; border: 1px solid #30363d; border-radius: 8px;
  padding: 10px 12px; font-size: 12.5px; }
.fi-card h4 { margin: 0 0 4px; font-size: 13.5px; display: flex; gap: 6px; align-items: center;
  flex-wrap: wrap; }
.fi-changed, .fi-keep { margin: 6px 0 0; line-height: 1.7; word-break: break-all; }
.fi-keep { color: #8b949e; }
.fi-declared { margin: 6px 0 0; line-height: 1.8; }
.cs-item.cs-changed { border-color: #6b5620; }
.cs-head { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.cs-paths { margin-top: 5px; line-height: 1.7; word-break: break-all; }
.cs-q { margin-top: 5px; color: #d4a72c; font-size: 12px; }
@media (max-width: 720px) { .fi-grid, .cs-grid { grid-template-columns: 1fr; } }
.check-title { display: flex; align-items: center; gap: 6px; }
.check-pass { font-size: 12px; color: #3fb950; line-height: 1.55; }
.check-pass b { color: #2ea45f; font-weight: 700; margin-right: 4px; }
.check-jump { color: #58a6ff; text-decoration: none; font-size: 11.5px; white-space: nowrap; }
.check-jump:hover { text-decoration: underline; }
.sev-badge { font-size: 10px; font-weight: 700; border-radius: 4px; padding: 1px 6px;
  vertical-align: middle; flex: none; }
`;

/** Checklist severity badge */
export function severityBadge(severity) {
  const color = RISK_COLOR[severity] ?? COLOR.warn;
  const label = RISK_LABEL[severity] ?? RISK_LABEL.major;
  return `<span class="sev-badge" style="background:${color};color:#0d1117">${label}</span>`;
}
