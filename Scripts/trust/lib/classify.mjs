/**
 * classify.mjs — Finds the parts of a change whose merge decision would be fatal if wrong (pure).
 *
 * Every rule answers one question: if auto-merging this turns out to be a mistake, can the damage be
 * undone by reverting it? A rule names the *axis* of the answer (why a revert is not enough) and states
 * the consequence in `if_wrong`, so a human reading the escalation sees the risk, not a path list.
 *
 *   self_reference  the change alters the evaluator; a wrong call corrupts every later call
 *   irreversible    the effect outlives the code (migrated data, deleted files, Keychain items)
 *   blast_radius    the damage reaches secrets, permissions, guardrails or the supply chain
 *   direction       purpose, architecture or spec; later work is built on the wrong premise
 *   exposure        the mistake is shown to users and tests cannot judge it
 *   undetectable    built in: too large or not displayable, so a mistake would not be noticed
 *
 * A path that matches no rule is merely *eligible*: it still has to clear every evidence check. So
 * a new directory landing on the eligible side costs nothing without evidence.
 */

export const AXES = new Set(['self_reference', 'irreversible', 'blast_radius', 'direction', 'exposure', 'undetectable']);

/** Minimal glob → RegExp: `**` spans directories, `*` stays within one segment. */
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i += 1) {
    const ch = glob[i];
    if (ch === '*' && glob[i + 1] === '*') {
      // `**/` matches zero or more whole directories; a trailing `**` matches anything.
      if (glob[i + 2] === '/') {
        re += '(?:.*/)?';
        i += 2;
      } else {
        re += '.*';
        i += 1;
      }
    } else if (ch === '*') {
      re += '[^/]*';
    } else if (ch === '?') {
      re += '[^/]';
    } else {
      re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${re}$`);
}

export function matchesAny(path, globs = []) {
  return globs.some((g) => globToRegExp(g).test(path));
}

/** Bucket an escape freezes. */
export function categoryOf(path) {
  const layer = /^Sources\/([^/]+)\//.exec(path);
  if (layer) return `src:${layer[1]}`;
  if (/^Tests\//.test(path)) return 'tests';
  if (/\.(md|markdown|txt)$/i.test(path) || path.startsWith('docs/')) return 'docs';
  if (path.startsWith('Scripts/')) return 'scripts';
  return 'other';
}

/**
 * A policy that cannot state why each rule is fatal is not a policy the evaluator may act on: an
 * empty or malformed one would otherwise auto-merge everything. Returns human-readable problems.
 */
export function validatePolicy(policy, now = Date.now()) {
  const problems = [];
  if (policy?.version !== 2) problems.push(`policy version ${policy?.version} は未対応（2 が必要）`);
  if (!Array.isArray(policy?.fatal_risk) || policy.fatal_risk.length === 0) problems.push('fatal_risk が空');
  for (const r of policy?.fatal_risk ?? []) {
    const where = r?.id ?? '(id なし)';
    if (!AXES.has(r?.axis) || r.axis === 'undetectable') problems.push(`${where}: axis "${r?.axis}" は未知`);
    if (typeof r?.if_wrong !== 'string' || r.if_wrong.trim().length < 10) problems.push(`${where}: if_wrong（誤ったときに何が起きるか）が必要`);
    if (!Array.isArray(r?.paths) || r.paths.length === 0) problems.push(`${where}: paths が空`);
  }
  const b = policy?.breaker;
  // Compared as instants, so the value must be a full ISO-8601 timestamp; anything else would make
  // every escape "before since" and the breaker could never trip.
  if (typeof b?.since !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(b.since) || Number.isNaN(Date.parse(b.since))) {
    problems.push(`breaker.since "${b?.since}" は ISO-8601 の日時でない`);
  }
  // A `since` in the future puts every escape before it, so the breaker could never trip.
  else if (Date.parse(b.since) > now) problems.push(`breaker.since "${b.since}" が未来の日時`);
  if (!Number.isInteger(b?.max_escapes) || b.max_escapes < 1) problems.push(`breaker.max_escapes "${b?.max_escapes}" は 1 以上の整数でない`);
  for (const r of policy?.fatal_risk ?? []) {
    if (r?.content_scope !== undefined && r.content_scope !== 'file') problems.push(`${r.id}: content_scope "${r.content_scope}" は未知`);
    if (r?.content_side !== undefined && r.content_side !== 'added') problems.push(`${r.id}: content_side "${r.content_side}" は未知`);
  }
  const u = policy?.undetectable;
  if (!(u?.max_files > 0) || !(u?.max_loc > 0)) problems.push('undetectable.max_files / max_loc が必要');
  if (!policy?.fatal_risk?.some((r) => r.axis === 'self_reference' && matchesAny('data/trust/policy.json', r.paths))) {
    problems.push('policy.json 自身を self_reference で守る規則がない');
  }
  return problems;
}

const escalation = (rule, paths) => ({ id: rule.id, axis: rule.axis, if_wrong: rule.if_wrong, paths });

/**
 * @param {{files: Array<{path: string, added: number, removed: number, binary?: boolean, addedLines?: string[], removedLines?: string[],
 *                       before?: string|null, after?: string|null}>}} change
 * @param {object} policy  data/trust/policy.json (v2)
 * @returns {{escalations: Array<{id: string, axis: string, if_wrong: string, paths: string[]}>, categories: string[],
 *            scale: {files: number, loc: number}}}
 */
export function classifyChange({ files }, policy) {
  const escalations = [];
  const loc = files.reduce((n, f) => n + (f.added || 0) + (f.removed || 0), 0);

  for (const rule of policy.fatal_risk ?? []) {
    let matched = files.filter((f) => matchesAny(f.path, rule.paths));
    if (matched.length === 0) continue;

    if (Array.isArray(rule.content) && rule.content.length > 0) {
      // Content-scoped: the path alone is not enough, a changed line must mention a needle. For a
      // destructive call only an *added* line matters — removing one makes the code less dangerous.
      // `content_scope: file` looks at the whole file before and after: editing a column inside an
      // existing CREATE TABLE changes no line that names the statement.
      const lines = (f) => {
        if (rule.content_scope === 'file') return [f.before ?? '', f.after ?? '', ...(f.addedLines ?? []), ...(f.removedLines ?? [])];
        return rule.content_side === 'added' ? f.addedLines ?? [] : [...(f.addedLines ?? []), ...(f.removedLines ?? [])];
      };
      matched = matched.filter((f) => lines(f).some((line) => rule.content.some((c) => line.toLowerCase().includes(c.toLowerCase()))));
    }
    if (typeof rule.min_loc === 'number') {
      const ruleLoc = matched.reduce((n, f) => n + (f.added || 0) + (f.removed || 0), 0);
      if (ruleLoc < rule.min_loc) matched = [];
    }
    if (matched.length > 0) escalations.push(escalation(rule, matched.map((f) => f.path)));
  }

  const u = policy.undetectable ?? {};
  // A file whose content the approver is not shown cannot be judged by any content rule either.
  const unmeasurable = files.filter((f) => f.binary);
  if (unmeasurable.length > 0) {
    escalations.push(escalation({ id: 'unmeasurable', axis: 'undetectable', if_wrong: u.if_wrong ?? 'バイナリ扱いで中身を確認できない' }, unmeasurable.map((f) => f.path)));
  }
  if (files.length > u.max_files || loc > u.max_loc) {
    escalations.push(
      escalation(
        { id: 'scale', axis: 'undetectable', if_wrong: `${u.if_wrong ?? '規模が大きい'} (files ${files.length}/${u.max_files}, loc ${loc}/${u.max_loc})` },
        [],
      ),
    );
  }

  const categories = [...new Set(files.map((f) => categoryOf(f.path)))].sort();
  return { escalations, categories, scale: { files: files.length, loc } };
}
