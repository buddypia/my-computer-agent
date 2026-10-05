/**
 * section-template-renderer.mjs — Pure Markdown section renderer shared by
 * worktree-plan-template.mjs (PLAN.md) and worktree-ship-report.mjs
 * (Pre-Ship Human Review Panel). Section counts rely on each data constant as SSOT — not specified
 * here (avoiding prose count drift).
 *
 * Purpose (Option C — shared engine + separated data, user decision): Shares rendering *logic* of
 * both templates via a single pure function, while harness maintains data as JS constants (DEFAULT_*_SECTIONS)
 * to avoid adding file I/O to live shipping paths. Transplant target projects receive JSONs of the same schema
 * (data/registry/transplant-templates/*.generic.json) as customization seeds — harness does not read those JSONs.
 *
 * 5 primitives represent 100% of existing outputs for both templates (PLAN.md / approval panel):
 *   - static: Fixed text lines (supports {{var}} interpolation)
 *   - checklist_group: `### subheading` + `- [ ] item` list
 *   - field_list: `- Label: value` list (value processed via valueOrDash)
 *   - fenced_block: ```lang\n<content or fallback>\n``` (trim option)
 *   - table: header lines + rows_key array expanded via row_template (empty_rows if empty array)
 *
 * Heading lines (`section.heading` or `checklist_group.subheading`) automatically have 1 blank line
 * prepended unless it is the first line of the document — this single rule accounts for all blank-line
 * placement across both original templates. Heading status is determined by *structure* (originating field)
 * rather than re-inferring text content via regex — body text in static blocks that happens to start with `#`
 * (e.g., free text like "# Note") renders faithfully without false positives.
 *
 * Regressions: tests/unit/section-template-renderer.test.mjs.
 */

/**
 * Own-property read. Every lookup keyed by template data goes through this: template JSON is
 * project-editable, and a key such as `__proto__`, `constructor` or `valueOf` must read as absent
 * rather than reach Object.prototype (which threw inside a ship guard).
 */
const own = (obj, key) =>
  obj !== null && typeof obj === 'object' && Object.hasOwn(obj, key) ? obj[key] : undefined;

function interpolate(str, context) {
  if (typeof str !== 'string') return str;
  return str.replace(/\{\{(\w+)\}\}/g, (_, key) =>
    Object.prototype.hasOwnProperty.call(context, key) && context[key] !== undefined
      ? String(context[key])
      : '',
  );
}

function interpolateRow(template, row) {
  return template.replace(/\{(\w+)\}/g, (_, key) => valueOrDash(own(row, key)));
}

function valueOrDash(value) {
  if (value === null || value === undefined || value === '') return '-';
  return String(value);
}

function renderStatic(block, context) {
  return (block.lines || []).map((line) => interpolate(line, context));
}

function renderFieldList(block, context) {
  return (block.fields || []).map((f) => `- ${f.label}: ${valueOrDash(own(context, f.key))}`);
}

function renderFencedBlock(block, context) {
  const raw = own(context, block.content_key);
  let content;
  if (block.trim) {
    content = typeof raw === 'string' && raw.trim() ? raw.trim() : block.fallback || '';
  } else {
    content = raw || block.fallback || '';
  }
  return [`\`\`\`${block.lang || 'text'}`, content, '```'];
}

function renderTable(block, context) {
  const source = own(context, block.rows_key);
  const rows = Array.isArray(source) && source.length > 0 ? source : block.empty_rows || [];
  return [...(block.header_lines || []), ...rows.map((row) => interpolateRow(block.row_template, row))];
}

const BLOCK_RENDERERS = {
  static: renderStatic,
  field_list: renderFieldList,
  fenced_block: renderFencedBlock,
  table: renderTable,
};

/**
 * Renders block, pushes to `rawLines`, and records indices of lines treated as headings in `headingAt`.
 * Only `checklist_group.subheading` is treated as heading at block level — other block types do not produce headings
 * (structural determination, not text regex).
 */
function appendBlockLines(block, context, rawLines, headingAt) {
  if (!block) return;
  if (block.type === 'checklist_group') {
    if (block.subheading) {
      headingAt.add(rawLines.length);
      rawLines.push(interpolate(block.subheading, context));
    }
    for (const item of block.items || []) rawLines.push(`- [ ] ${interpolate(item, context)}`);
    return;
  }
  const renderer = own(BLOCK_RENDERERS, block.type);
  if (renderer) rawLines.push(...renderer(block, context));
}

/**
 * Renders sections array into a Markdown string (no trailing newline — caller's responsibility).
 * @param {Array<{heading?: string, blocks?: Array<object>}>} sections
 * @param {Record<string, unknown>} [context]
 * @returns {string}
 */
export function renderTemplateFromSections(sections, context = {}) {
  const rawLines = [];
  const headingAt = new Set();
  for (const section of sections || []) {
    if (section.heading) {
      headingAt.add(rawLines.length);
      rawLines.push(interpolate(section.heading, context));
    }
    for (const block of section.blocks || []) {
      appendBlockLines(block, context, rawLines, headingAt);
    }
  }
  const out = [];
  rawLines.forEach((line, idx) => {
    if (idx > 0 && headingAt.has(idx)) out.push('');
    out.push(line);
  });
  return out.join('\n');
}

const isStr = (v) => typeof v === 'string';
const isStrArray = (v) => Array.isArray(v) && v.every(isStr);
const optional = (v, check) => v === undefined || check(v);

/** Per-type shape the renderers above rely on (anything else throws or renders garbage). */
const BLOCK_SHAPES = {
  static: (b) => isStrArray(b.lines),
  checklist_group: (b) => isStrArray(b.items) && optional(b.subheading, isStr),
  field_list: (b) =>
    Array.isArray(b.fields) && b.fields.every((f) => f && isStr(f.label) && isStr(f.key)),
  fenced_block: (b) =>
    isStr(b.content_key) && optional(b.fallback, isStr) && optional(b.lang, isStr),
  table: (b) =>
    isStr(b.rows_key) &&
    isStr(b.row_template) &&
    optional(b.header_lines, isStrArray) &&
    optional(
      b.empty_rows,
      (r) =>
        Array.isArray(r) &&
        r.every(
          (x) =>
            x && typeof x === 'object' && Object.values(x).every((v) => v === null || typeof v !== 'object'),
        ),
    ),
};

/**
 * Validates a sections array for renderTemplateFromSections before it is trusted from a
 * project-editable file (a malformed block used to throw inside a ship guard).
 *
 * @returns {string|null} first problem found, or null when every section/block is well-formed
 */
export function validateSections(sections) {
  if (!Array.isArray(sections) || sections.length === 0) return 'sections must be a non-empty array';
  for (const [i, section] of sections.entries()) {
    if (!section || !isStr(section.heading) || !Array.isArray(section.blocks)) {
      return `sections[${i}] needs a string heading and a blocks array`;
    }
    for (const [j, block] of section.blocks.entries()) {
      const shape = own(BLOCK_SHAPES, block?.type);
      if (!shape) return `sections[${i}].blocks[${j}] has unknown type ${JSON.stringify(block?.type)}`;
      if (!shape(block)) return `sections[${i}].blocks[${j}] (${block.type}) is malformed`;
    }
  }
  return null;
}
