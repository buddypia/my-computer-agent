/**
 * doc-outline.mjs — Structures **all sections** of source documents (SPEC.md / PLAN.md / wireframes) (pure function)
 *
 * Why (user feedback 2026-07-25 "The output content is too brief to evaluate properly"):
 *   (a) Threat: Decks only extracted a small subset of fields — in `SPEC-001-feature-pilot-target-scope.md`
 *       only 4 of 22 sections (title, overview, FR table, acceptance) were shown, omitting vital
 *       Error Handling / Data Schema / API Contract / Safety & Guardrails / Rollback /
 *       Dependencies & Risks / Verification & Tests sections.
 *   (b) Gaps: `review-deck-core.mjs#parseSpecStructure` counted only file counts and discarded bodies.
 *   (c) Simpler alternatives comparison: Attaching raw markdown into `<pre>` loses table/code structure.
 *       Whitelisting key sections misses diverse template sections.
 *       Adopted: Parse and structure all sections.
 *
 * Contract: Returns heading tree + per-section blocks (table/code/list/paragraph) + quality diagnosis
 *   (unwritten/placeholder/one-liner). No AI re-authoring of text — classification and diagnosis only.
 *
 * Boundary (R-CM-028): perspective1-only — same deployment isolation as review deck stack.
 */

/** Phrases indicating placeholder content (bilingual) */
const PLACEHOLDER_RE =
  /^(tbd|todo|t\.?b\.?d\.?|n\/?a|none|not\s*applicable|later|-|—|\.\.\.|…|\(needs\s*writing\)|\(to\s*be\s*written\)|needs\s*writing|placeholder|없음|해당\s*없음|미정|추후|없다|\(작성\s*필요\)|\(작성필요\)|작성\s*필요|미작성)$/i;

/** Contractual sections related to implementation (bilingual) */
const CONTRACT_TITLE_RE =
  /(error|exception|schema|api|contract|guardrail|safety|security|rollback|rollout|observab|nfr|perform|state|hook|dependenc|risk|verification|test|migration|계약|에러|예외|스키마|보안|안전|롤백|배포|관측|성능|의존|위험|검증|테스트|마이그레이션)/i;

/** Matches heading line — valid only outside fences */
function matchHeading(line) {
  const m = line.match(/^(#{1,6})\s+(.+?)\s*$/);
  return m ? { level: m[1].length, title: m[2].trim() } : null;
}

/** Tracks code fence transitions */
function fenceTransition(line, open) {
  const m = line.match(/^\s*(`{3,}|~{3,})\s*(\S*)\s*$/);
  if (!m) return null;
  const char = m[1][0];
  const len = m[1].length;
  if (!open) return { kind: 'open', char, len, lang: m[2] || '' };
  if (char === open.char && len >= open.len && !m[2]) return { kind: 'close' };
  return null;
}

/** Determines block type for non-code lines */
function plainLineType(line) {
  if (line.trim().startsWith('|')) return 'table';
  if (/^\s*(?:[-*+]|\d+[.)])\s+/.test(line)) return 'list';
  if (/^\s*>/.test(line)) return 'quote';
  return 'paragraph';
}

/**
 * Classifies section body lines into structured blocks.
 */
export function classifyBlocks(lines) {
  const blocks = [];
  const state = { fence: null, buffer: null };

  const flush = () => {
    if (state.buffer && state.buffer.lines.some((l) => l.trim())) blocks.push(state.buffer);
    state.buffer = null;
  };
  const push = (type, line) => {
    if (!state.buffer || state.buffer.type !== type) {
      flush();
      state.buffer = { type, lines: [] };
    }
    state.buffer.lines.push(line);
  };
  const handleFence = (line) => {
    const t = fenceTransition(line, state.fence);
    if (t?.kind === 'open') {
      flush();
      state.fence = { char: t.char, len: t.len, lang: t.lang };
      state.buffer = { type: 'code', lang: t.lang, lines: [] };
      return true;
    }
    if (t?.kind === 'close') {
      if (state.buffer) blocks.push(state.buffer);
      state.buffer = null;
      state.fence = null;
      return true;
    }
    return false;
  };

  for (const line of Array.isArray(lines) ? lines : []) {
    if (handleFence(line)) continue;
    if (state.fence) {
      state.buffer.lines.push(line);
      continue;
    }
    if (!line.trim()) {
      flush();
      continue;
    }
    push(plainLineType(line), line);
  }
  if (state.fence && state.buffer) {
    blocks.push({ ...state.buffer, unclosed: true });
    state.buffer = null;
  }
  flush();
  return blocks;
}

/**
 * Parses table row into array of cells. Respects `\|` escaped pipe.
 */
function splitTableRow(line) {
  const cells = [];
  let cur = '';
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '\\' && (line[i + 1] === '|' || line[i + 1] === '\\')) {
      cur += line[i + 1];
      i += 1;
      continue;
    }
    if (ch === '|') {
      cells.push(cur);
      cur = '';
      continue;
    }
    cur += ch;
  }
  cells.push(cur);
  return cells;
}

/** Table block -> { headers, rows } */
export function parseTableBlock(block) {
  if (block?.type !== 'table') return null;
  const rows = block.lines
    .map((l) => l.trim())
    .filter((l) => l.startsWith('|'))
    .map((l) =>
      splitTableRow(l)
        .slice(1, -1)
        .map((c) => c.trim()),
    )
    .filter((cells) => cells.length);
  const dataRows = rows.filter((cells) => !cells.every((c) => /^:?-{2,}:?$/.test(c)));
  if (!dataRows.length) return null;
  return { headers: dataRows[0], rows: dataRows.slice(1) };
}

/** List block -> array of item objects with optional done boolean */
export function parseListBlock(block) {
  if (block?.type !== 'list') return [];
  return block.lines
    .map((l) => l.match(/^\s*(?:[-*+]|\d+[.)])\s+(.*)$/))
    .filter(Boolean)
    .map((m) => {
      const raw = m[1].trim();
      const cb = raw.match(/^\[( |x|X)\]\s*(.*)$/);
      return cb ? { text: cb[2].trim(), done: cb[1] !== ' ' } : { text: raw, done: null };
    })
    .filter((i) => i.text);
}

/**
 * Section quality diagnosis: empty / placeholder / thin.
 */
export function diagnoseSection(blocks) {
  const renderable = blocks.filter((b) => b.type !== 'table' || parseTableBlock(b));
  const textBlocks = renderable.filter((b) => b.type !== 'code');
  const chars = textBlocks.reduce((s, b) => s + b.lines.join(' ').replace(/\s+/g, ' ').trim().length, 0);
  const hasTable = renderable.some((b) => b.type === 'table');
  const hasCode = renderable.some((b) => b.type === 'code' && b.lines.some((l) => l.trim()));
  const flatText = textBlocks
    .flatMap((b) => b.lines)
    .map((l) => l.replace(/^\s*(?:[-*+]|\d+[.)])\s+/, '').trim())
    .filter(Boolean);
  const placeholder =
    flatText.length > 0 && flatText.every((l) => PLACEHOLDER_RE.test(l.replace(/[.,;:]$/, '')));
  const empty = !renderable.length || (!chars && !hasCode);
  return {
    chars,
    hasTable,
    hasCode,
    empty,
    placeholder: !empty && placeholder,
    thin: !empty && !placeholder && !hasTable && !hasCode && chars < 40,
  };
}

/** Determines if heading title represents an implementation contract section */
export function isContractSection(title) {
  return CONTRACT_TITLE_RE.test(String(title ?? ''));
}

function slugifySection(title, index) {
  const base = String(title ?? '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '');
  return `sec-${index}-${Array.from(base).slice(0, 40).join('') || 'section'}`;
}

/** Marks container headings that have child subsections */
function markContainers(sections) {
  for (let i = 0; i < sections.length; i += 1) {
    const cur = sections[i];
    const next = sections[i + 1];
    cur.container = Boolean(cur.title && next?.title && next.level > cur.level);
  }
  return sections;
}

/**
 * Parses markdown into structured section array.
 *
 * @returns {Array<{index, level, title, slug, blocks, quality, contract, container}>}
 */
export function parseDocumentOutline(markdown) {
  if (!markdown || typeof markdown !== 'string') return [];
  const lines = markdown.replace(/^﻿+/, '').split(/\r?\n/);
  const sections = [];
  let current = { level: 0, title: null, lines: [] };
  let fence = null;

  for (const line of lines) {
    const t = fenceTransition(line, fence);
    if (t?.kind === 'open') fence = { char: t.char, len: t.len };
    else if (t?.kind === 'close') fence = null;
    const heading = fence ? null : matchHeading(line);
    if (heading) {
      sections.push(current);
      current = { level: heading.level, title: heading.title, lines: [] };
      continue;
    }
    current.lines.push(line);
  }
  sections.push(current);

  return markContainers(
    sections
      .filter((s, i) => s.title !== null || s.lines.some((l) => l.trim()) || i > 0)
      .map((s, i) => {
        const blocks = classifyBlocks(s.lines);
        return {
          index: i,
          level: s.level,
          title: s.title,
          slug: slugifySection(s.title ?? 'preamble', i),
          blocks,
          quality: diagnoseSection(blocks),
          contract: s.title ? isContractSection(s.title) : false,
          container: false,
        };
      }),
  );
}

/** Orders sections putting contract sections first */
export function orderSectionsForReview(sections) {
  const list = Array.isArray(sections) ? sections : [];
  const contract = list.filter((s) => s.contract);
  const rest = list.filter((s) => !s.contract);
  return { contract, rest };
}

/**
 * Summarizes outline quality across entire document.
 */
export function summarizeOutline(sections) {
  const list = (Array.isArray(sections) ? sections : []).filter((s) => s.title);
  const empty = list.filter((s) => !s.container && s.quality.empty);
  const placeholder = list.filter((s) => s.quality.placeholder);
  const thin = list.filter((s) => !s.container && s.quality.thin);
  return {
    total: list.length,
    empty: empty.map((s) => s.title),
    placeholder: placeholder.map((s) => s.title),
    thin: thin.map((s) => s.title),
    chars: list.reduce((sum, s) => sum + s.quality.chars, 0),
    tables: list.filter((s) => s.quality.hasTable).length,
    codeBlocks: list.filter((s) => s.quality.hasCode).length,
  };
}
