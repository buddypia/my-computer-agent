/**
 * doc-section-render.mjs — Source section model -> HTML rendering (tables as tables, code as code)
 *
 * Input contract: Array of sections from `doc-outline.mjs#parseDocumentOutline`.
 * Principle: No re-authoring or summarizing of source text — classification, layout, and quality badges only (R-CM-024 spirit).
 *
 * Boundary (R-CM-028): perspective1-only.
 */

import { escapeHtml } from './ship-deck-core.mjs';
import { parseListBlock, parseTableBlock } from './doc-outline.mjs';

/**
 * Escapes text and restores inline code (`x`) and bold (**x**) tags.
 */
export function inlineMarkdown(text) {
  return escapeHtml(String(text ?? ''))
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
}

function renderTable(block) {
  const table = parseTableBlock(block);
  if (!table) return '';
  const head = table.headers.map((h) => `<th>${inlineMarkdown(h)}</th>`).join('');
  const body = table.rows
    .map((cells) => `<tr>${cells.map((c) => `<td>${inlineMarkdown(c)}</td>`).join('')}</tr>`)
    .join('\n');
  return `<table class="doc-table"><thead><tr>${head}</tr></thead><tbody>
${body}
</tbody></table>`;
}

function renderList(block) {
  const items = parseListBlock(block);
  if (!items.length) return '';
  const lis = items
    .map((i) => {
      if (i.done === null) return `<li>${inlineMarkdown(i.text)}</li>`;
      const mark = i.done ? '✓' : '○';
      return `<li class="${i.done ? 'done' : 'todo'}"><span class="cb">${mark}</span> ${inlineMarkdown(i.text)}</li>`;
    })
    .join('\n');
  const checkbox = items.some((i) => i.done !== null);
  return `<ul class="doc-list${checkbox ? ' checkbox' : ''}">
${lis}
</ul>`;
}

function renderCode(block) {
  const lang = block.lang ? `<span class="code-lang">${escapeHtml(block.lang)}</span>` : '';
  const unclosed = block.unclosed
    ? '<span class="badge warn-badge">Unclosed code block — missing fence in source</span>'
    : '';
  const body = escapeHtml(block.lines.join('\n'));
  return `<div class="doc-code">${lang}${unclosed}<pre>${body}</pre></div>`;
}

function renderParagraph(block) {
  const text = block.lines.map((l) => inlineMarkdown(l.trim())).join('<br/>');
  return `<p class="doc-p">${text}</p>`;
}

function renderQuote(block) {
  const text = block.lines.map((l) => inlineMarkdown(l.replace(/^\s*>\s?/, ''))).join('<br/>');
  return `<blockquote class="doc-quote">${text}</blockquote>`;
}

const BLOCK_RENDERERS = {
  table: renderTable,
  list: renderList,
  code: renderCode,
  quote: renderQuote,
  paragraph: renderParagraph,
};

/** Block array -> HTML */
export function renderBlocks(blocks) {
  return (Array.isArray(blocks) ? blocks : [])
    .map((b) => (BLOCK_RENDERERS[b.type] ?? renderParagraph)(b))
    .filter(Boolean)
    .join('\n');
}

/** Section quality badge */
function qualityBadge(quality, container = false) {
  if (quality?.empty) {
    return container ? '' : '<span class="badge bad-badge">No content</span>';
  }
  if (quality?.placeholder) {
    return '<span class="badge bad-badge">Unwritten (TBD/needs writing)</span>';
  }
  if (quality?.thin) {
    return `<span class="badge warn-badge">One-liner (${quality.chars} chars)</span>`;
  }
  return '';
}

/** Heading level -> HTML heading tag */
function headingTag(level) {
  if (level <= 2) return 'h3';
  return level === 3 ? 'h4' : 'h5';
}

/**
 * Single section -> HTML card.
 * @param {object} section doc-outline section
 * @param {object} [opts] { open }
 */
export function renderDocSection(section, { open = true } = {}) {
  if (!section) return '';
  const title = section.title ?? '(Untitled Preamble)';
  const tag = headingTag(section.level || 2);
  const badge = qualityBadge(section.quality, section.container);
  const body =
    renderBlocks(section.blocks) ||
    (section.container
      ? '<p class="doc-p muted">Content is in subsections below.</p>'
      : '<p class="doc-p muted">No content in source document.</p>');
  const levelClass = `doc-sec lv${Math.min(6, Math.max(1, section.level || 2))}`;
  return `<section class="${levelClass}" id="${escapeHtml(section.slug)}"${open ? '' : ' data-collapsed="1"'}>
  <${tag} class="doc-h">${inlineMarkdown(title)} ${badge}</${tag}>
  ${body}
</section>`;
}

/** Section array -> HTML */
export function renderDocSections(sections, opts) {
  return (Array.isArray(sections) ? sections : [])
    .map((s) => renderDocSection(s, opts))
    .filter(Boolean)
    .join('\n');
}

/** State badge for outline table of contents */
function outlineStateBadge(section) {
  const q = section.quality ?? {};
  if (q.empty) return `<span class="oi-state${section.container ? '' : ' bad'}">${section.container ? 'Subsection' : 'No content'}</span>`;
  if (q.placeholder) return '<span class="oi-state bad">Unwritten</span>';
  if (q.thin) return '<span class="oi-state warn">One-liner</span>';
  const extra = `${q.hasTable ? ' · table' : ''}${q.hasCode ? ' · code' : ''}`;
  return `<span class="oi-state ok">${q.chars} chars${extra}</span>`;
}

export function renderOutlineIndex(sections) {
  const list = (Array.isArray(sections) ? sections : []).filter((s) => s.title);
  if (!list.length) return '';
  const rows = list
    .map(
      (s) =>
        `<li class="oi-item lv${Math.min(4, s.level)}"><a href="#${escapeHtml(s.slug)}">${inlineMarkdown(s.title)}</a>${outlineStateBadge(s)}</li>`,
    )
    .join('\n');
  return `<ul class="outline-index">
${rows}
</ul>`;
}

/** Section render CSS */
export const DOC_SECTION_CSS = `
.doc-sec { border-left: 2px solid #30363d; padding: 2px 0 2px 12px; margin: 14px 0; }
.doc-sec.lv3, .doc-sec.lv4 { margin-left: 10px; border-left-color: #262c34; }
.doc-h { margin: 0 0 6px; color: #e6edf3; font-size: 14px; }
.doc-sec.lv3 .doc-h, .doc-sec.lv4 .doc-h { font-size: 13px; color: #c9d5e1; }
.doc-p { margin: 5px 0; font-size: 13.5px; line-height: 1.65; }
.doc-list { margin: 5px 0; padding-left: 20px; font-size: 13.5px; line-height: 1.7; }
.doc-list.checkbox { list-style: none; padding-left: 2px; }
.doc-list .cb { display: inline-block; width: 14px; color: #8b949e; }
.doc-list li.done { color: #3fb950; }
.doc-table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin: 8px 0; }
.doc-table th, .doc-table td { border: 1px solid #30363d; padding: 6px 8px; text-align: left;
  vertical-align: top; line-height: 1.55; }
.doc-table th { color: #9da7b3; background: #11161d; font-weight: 600; }
.doc-code { margin: 8px 0; position: relative; }
.doc-code .code-lang { position: absolute; right: 8px; top: 6px; font-size: 10px; color: #6e7681; }
.doc-code pre { margin: 0; font-size: 12px; }
.doc-quote { margin: 8px 0; padding: 4px 12px; border-left: 3px solid #30363d; color: #9da7b3;
  font-size: 13px; }
.bad-badge { border-color: #e5534b; color: #e5534b; }
.warn-badge { border-color: #d4a72c; color: #d4a72c; }
.outline-index { list-style: none; padding: 0; margin: 8px 0 0; display: grid; gap: 3px;
  font-size: 12.5px; }
.oi-item { display: flex; gap: 8px; align-items: baseline; }
.oi-item.lv2 { padding-left: 0; }
.oi-item.lv3 { padding-left: 14px; }
.oi-item.lv4 { padding-left: 28px; }
.oi-item a { color: #58a6ff; text-decoration: none; }
.oi-item a:hover { text-decoration: underline; }
.oi-state { margin-left: auto; font-size: 11px; white-space: nowrap; }
.oi-state.ok { color: #6e7681; }
.oi-state.warn { color: #d4a72c; }
.oi-state.bad { color: #e5534b; }
`;
