/**
 * ledger.mjs — What the decision ledger says about decisions that were overturned (pure).
 *
 * Event types, appended by trust.mjs:
 *   assessment  what the machine decided for a diff_id (human | auto_merge)
 *   human       what the human answered for an escalated diff_id (approve | revise | abort)
 *   escape      an auto-merged change later found defective — the machine's call was overturned
 *
 * The breaker is the feedback loop: one escape freezes the categories it touched, `max_escapes`
 * escapes stop auto-merge altogether. Only escapes after `breaker.since` count, and moving `since`
 * is a policy change, which is itself never auto-merged — so re-opening needs a human.
 */

/** @returns {{escapes: number, tripped: boolean, frozen: string[]}} */
export function breakerState(events, breaker = {}) {
  const since = Date.parse(breaker.since ?? '');
  const max = breaker.max_escapes ?? 2;
  // Instants, not strings. An escape whose time cannot be read counts: dropping it would re-open auto-merge.
  const escapes = events.filter((e) => {
    if (e?.type !== 'escape') return false;
    const at = Date.parse(e.at);
    return Number.isNaN(since) || Number.isNaN(at) || at >= since;
  });
  const frozen = [...new Set(escapes.flatMap((e) => e.categories ?? []))].sort();
  return { escapes: escapes.length, tripped: escapes.length >= max, frozen };
}

/**
 * Latest decision per diff, with every human answer. `over_escalation` (escalated, then approved
 * unchanged) is the material for loosening a rule; `revised` is evidence the rule earned its keep.
 */
export function summarize(events) {
  const byDiff = new Map();
  for (const e of events) {
    if (!e?.diff_id || (e.type !== 'assessment' && e.type !== 'human')) continue;
    const slot = byDiff.get(e.diff_id) ?? { humans: [] };
    if (e.type === 'assessment') slot.assessment = e;
    else slot.humans.push(e);
    byDiff.set(e.diff_id, slot);
  }
  const out = { auto_merge: 0, human: 0, over_escalation: 0, revised: 0, by_rule: {} };
  for (const { assessment: a, humans } of byDiff.values()) {
    if (!a) continue;
    if (a.decision === 'auto_merge') {
      out.auto_merge += 1;
      continue;
    }
    out.human += 1;
    if (humans.length === 0) continue;
    // A revise followed by an approve on the same diff still means a human stopped it once.
    const approvedUnchanged = humans.every((h) => h.decision === 'approve');
    for (const id of a.escalations ?? []) {
      const r = (out.by_rule[id] ??= { approved_unchanged: 0, revised: 0 });
      if (approvedUnchanged) r.approved_unchanged += 1;
      else r.revised += 1;
    }
    if (approvedUnchanged && (a.escalations ?? []).length > 0) out.over_escalation += 1;
    if (!approvedUnchanged) out.revised += 1;
  }
  return out;
}
