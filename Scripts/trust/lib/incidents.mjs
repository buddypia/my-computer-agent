/**
 * incidents.mjs — Recurrence-prevention registry checks (pure; file access is injected).
 *
 * Every problem found — by a reviewer, by a human, or after landing — is recorded with its root-cause
 * class and at least one *guard*: an artifact in the tree that would have caught it. The gate runs
 * `check`, so deleting or hollowing out a guard turns the build red instead of silently re-opening
 * the hole.
 *
 * Guard kinds form a ladder, weakest first:
 *   checklist  an item fed to the independent reviewer (docs/trust/review-checklist.md)
 *   test       an automated test that fails on the defect
 *   gate       a gate stage / static check that fails on the whole class of defect
 *
 * When one class recurs `recurrence_limit` times, the latest incident of that class must carry a
 * guard at least `min_kind_on_recurrence` strong: the weaker guard already demonstrably failed.
 */

export const GUARD_KINDS = ['checklist', 'test', 'gate'];
const rank = (k) => GUARD_KINDS.indexOf(k);

const ID_RE = /^INC-\d{3,}$/;
const CLASS_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

// Drops line and block comments but keeps string contents (test names live in strings).
export function stripComments(text) {
  let out = '';
  let quote = null;
  const s = String(text ?? '');
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (quote) {
      out += ch;
      if (ch === '\\') { out += s[i + 1] ?? ''; i += 1; }
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; out += ch; continue; }
    if (s.startsWith('//', i)) { while (i < s.length && s[i] !== '\n') i += 1; out += '\n'; continue; }
    if (s.startsWith('/*', i)) {
      const end = s.indexOf('*/', i + 2);
      const stop = end === -1 ? s.length : end + 2;
      out += s.slice(i, stop).replace(/[^\n]/g, '');
      i = stop - 1;
      continue;
    }
    out += ch;
  }
  return out;
}

/**
 * Where each kind of guard may live, and where its `contains` anchor must appear. The author of an
 * incident picks the guard, so the kind is checked against the file rather than taken on trust
 * (INC-004), and the anchor must be on a line that executes (INC-006):
 *   gate  a gate.sh line that *starts with* the anchor after comments are gone — `: run_stage`,
 *         `true || run_stage` and `# run_stage` do not
 *   test  a test declaration that is not a comment and not skipped; when TAP from the run is
 *         supplied, the test must also appear there as passed (not `# SKIP` / `# TODO`)
 */
const GUARD_RULES = {
  checklist: {
    path: /^docs\/.+\.md$/,
    lines: (text) => text.split('\n'),
    anchor: () => true,
  },
  test: {
    path: /^(?:Tests\/.+\.swift|Scripts\/(?:.+\/)?tests\/.+\.test\.mjs)$/,
    lines: (text) => stripComments(text).split('\n'),
    anchor: (line) =>
      /^\s*(?:test|it)\s*\(|^\s*@Test\b|^\s*func\s+test/.test(line) &&
      !/\.(?:skip|todo|only)\b|\.disabled\b|\.enabled\b|\bskip\s*:|\btodo\s*:/.test(line),
  },
  gate: {
    path: /^Scripts\/gate\.sh$/,
    lines: (text) => text.split('\n').map((l) => l.replace(/(^|\s)#.*$/, '$1')),
    anchor: (line, contains) => line.trim().startsWith(contains),
  },
};

// TAP escapes `#` in test names as `\#`; an unescaped `# SKIP` / `# TODO` is a directive.
function tapPassed(tap, contains) {
  return tap
    .split('\n')
    .some((l) => /^\s*ok \d+ - /.test(l) && l.replace(/\\#/g, '#').includes(contains) && !/(?<!\\)# (?:SKIP|TODO)\b/i.test(l));
}

/**
 * The body of the test declared on `line` (up to the next top-level test declaration) must assert
 * something — a guard whose body was emptied still "passes" (INC-010).
 */
function bodyAsserts(lines, index) {
  const body = [];
  for (let i = index; i < lines.length; i += 1) {
    if (i > index && /^\s*(?:test|it)\s*\(/.test(lines[i])) break;
    body.push(lines[i]);
  }
  return /\bassert\b|\bassert\.|\bexpect\s*\(/.test(body.join('\n'));
}

function xunitPassed(xml, contains) {
  const re = /<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g;
  for (const m of String(xml).matchAll(re)) {
    // Match the test's own name only — a class name or a generic word like "Tests" would let any
    // passing test vouch for a skipped guard.
    const name = /\bname="([^"]*)"/.exec(m[1])?.[1] ?? '';
    if (name.includes(contains) && !/<(?:skipped|failure|error)\b/.test(m[2] ?? '')) return true;
  }
  return false;
}

function guardProblem(g, fs, { tap, xunit } = {}) {
  const rule = GUARD_RULES[g?.kind];
  if (!rule) return `未知の guard kind "${g?.kind}"`;
  if (typeof g.path !== 'string' || g.path.startsWith('/') || g.path.split('/').includes('..')) {
    return `guard path は repo 相対で .. を含まないこと: ${g?.path}`;
  }
  if (!rule.path.test(g.path)) return `kind "${g.kind}" の guard は ${rule.path} に置く: ${g.path}`;
  if (typeof g.contains !== 'string' || g.contains.trim().length < 3) return `guard ${g.path} に contains（3 文字以上）が必要`;
  if (!fs.exists(g.path)) return `guard が消えている: ${g.path}`;
  const text = fs.read(g.path);
  if (!text.includes(g.contains)) return `guard ${g.path} に "${g.contains}" が見つからない（弱められた可能性）`;
  const lines = rule.lines(text);
  const at = lines.findIndex((line) => line.includes(g.contains) && rule.anchor(line, g.contains));
  if (at === -1) {
    return `guard ${g.path} の "${g.contains}" が実行される位置にない（${g.kind === 'gate' ? 'コマンド行の先頭でない' : 'テスト宣言でない / コメント / skip'}）`;
  }
  if (g.kind === 'test' && g.path.endsWith('.mjs')) {
    if (!bodyAsserts(lines, at)) return `guard テスト "${g.contains}" の本体に assert がない（中身を抜かれた可能性）`;
    if (tap !== null && tap !== undefined && !tapPassed(tap, g.contains)) return `guard テスト "${g.contains}" が今回の実行で pass していない`;
  }
  // A Swift guard is confirmed by the run: when xUnit is available it must be there, passed.
  if (g.kind === 'test' && g.path.endsWith('.swift') && xunit !== null && xunit !== undefined && !xunitPassed(xunit, g.contains)) {
    return `Swift guard テスト "${g.contains}" が今回の swift test で pass していない`;
  }
  return null;
}

/**
 * @param {{incidents: Array<object>}} registry
 * @param {{exists: (p: string) => boolean, read: (p: string) => string}} fs
 * @param {{recurrence_limit?: number, min_kind_on_recurrence?: string}} ladder
 * @param {{tap?: string|null, xunit?: string|null}} [run]  this run's node TAP / Swift xUnit, when available
 * @returns {{errors: string[], classes: Record<string, number>}}
 */
export function checkIncidents(registry, fs, ladder = {}, run = {}) {
  const errors = [];
  const incidents = Array.isArray(registry?.incidents) ? registry.incidents : null;
  if (!incidents) return { errors: ['incidents が配列でない'], classes: {} };

  const seen = new Set();
  const byClass = new Map();
  for (const inc of incidents) {
    const where = inc?.id ?? '(id なし)';
    if (!ID_RE.test(inc?.id ?? '')) errors.push(`${where}: id は INC-NNN 形式`);
    if (seen.has(inc?.id)) errors.push(`${where}: id 重複`);
    seen.add(inc?.id);
    if (!CLASS_RE.test(inc?.class ?? '')) errors.push(`${where}: class は kebab-case`);
    for (const key of ['summary', 'root_cause']) {
      if (typeof inc?.[key] !== 'string' || inc[key].trim().length < 10) errors.push(`${where}: ${key} が短すぎる (10 文字以上)`);
    }
    const guards = Array.isArray(inc?.guards) ? inc.guards : [];
    if (guards.length === 0) errors.push(`${where}: guard がない — 再発防止策なしに close できない`);
    for (const g of guards) {
      const problem = guardProblem(g, fs, run);
      if (problem) errors.push(`${where}: ${problem}`);
    }
    if (inc?.class) byClass.set(inc.class, [...(byClass.get(inc.class) ?? []), inc]);
  }

  const limit = ladder.recurrence_limit ?? 2;
  const minKind = ladder.min_kind_on_recurrence ?? 'test';
  for (const [cls, list] of byClass) {
    if (list.length < limit) continue;
    const latest = list[list.length - 1];
    const strongest = Math.max(-1, ...(latest.guards ?? []).map((g) => rank(g.kind)));
    if (strongest < rank(minKind)) {
      errors.push(
        `${latest.id}: class "${cls}" が ${list.length} 回目の再発 — 弱い guard は既に破られている。` +
          `"${minKind}" 以上の guard が必要`,
      );
    }
  }

  const classes = Object.fromEntries([...byClass].map(([c, l]) => [c, l.length]));
  return { errors, classes };
}

/** Checklist items the independent reviewer must walk, harvested from the registry. */
export function reviewerChecklist(registry) {
  return (registry?.incidents ?? []).map((i) => `- [${i.id} / ${i.class}] ${i.check ?? i.summary}`);
}
