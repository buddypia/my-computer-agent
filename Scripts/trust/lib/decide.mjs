/**
 * decide.mjs — Turns fatal-risk classification, the escape breaker and evidence into a decision (pure).
 *
 * The criterion is the cost of being wrong, not a track record: a change is merged without a human
 * exactly when a mistake in it would be caught by the evidence below and undone by a revert.
 *
 *   1. invalid policy       → human (an empty rule set must not mean "merge everything")
 *   2. mode is not auto_merge → human (kill switch)
 *   3. a fatal-risk rule hits → human — no evidence buys these
 *   4. breaker tripped / category frozen by an escape → human
 *   5. any evidence missing or failing → human (the machine cannot vouch for what it did not check)
 *   6. otherwise             → auto_merge
 *
 * Nothing here reads the environment: no variable can lift a decision (INC-007).
 */

import { validatePolicy } from './classify.mjs';

/** Evidence every auto_merge needs. `regression_test` is added on fix branches and then also has to pass. */
export const REQUIRED_EVIDENCE = ['clean', 'gate', 'executed_tests', 'bar_move', 'review', 'stable'];

/**
 * @param {{classification: {escalations: Array<object>, categories: string[]},
 *          evidence: Array<{id: string, ok: boolean, detail: string}>,
 *          policy: object, breaker: {tripped: boolean, frozen: string[], escapes: number}}} input
 * @returns {{decision: 'human'|'auto_merge', reasons: string[]}}
 */
export function decide({ classification, evidence, policy, breaker = { tripped: false, frozen: [], escapes: 0 } }) {
  const problems = validatePolicy(policy);
  if (problems.length > 0) return { decision: 'human', reasons: problems.map((p) => `[policy] ${p}`) };

  if (policy.mode !== 'auto_merge') {
    return { decision: 'human', reasons: [`[mode] mode=${policy.mode}: 自動マージは停止中`] };
  }

  if (classification.escalations.length > 0) {
    return {
      decision: 'human',
      reasons: classification.escalations.map(
        (e) => `[fatal:${e.axis}/${e.id}] ${e.if_wrong}${e.paths.length ? ` — ${e.paths.slice(0, 3).join(', ')}` : ''}`,
      ),
    };
  }

  if (breaker.tripped) {
    return { decision: 'human', reasons: [`[breaker] 自動マージ後の欠陥が ${breaker.escapes} 件（上限 ${policy.breaker.max_escapes}）。人間が原因を確かめて breaker.since を進めるまで停止`] };
  }
  const frozen = classification.categories.filter((c) => breaker.frozen.includes(c));
  if (frozen.length > 0) {
    return { decision: 'human', reasons: frozen.map((c) => `[breaker:${c}] このカテゴリで自動マージの判断が覆った（escape）ため凍結中`) };
  }

  // Evidence that is absent is as good as evidence that failed: a caller that forgot to gather one
  // must not get a merge by omission.
  const present = new Set(evidence.map((e) => e.id));
  const missing = REQUIRED_EVIDENCE.filter((id) => !present.has(id));
  if (missing.length > 0) return { decision: 'human', reasons: missing.map((id) => `[evidence:${id}] 証拠がない`) };
  const failed = evidence.filter((e) => !e.ok);
  if (failed.length > 0) return { decision: 'human', reasons: failed.map((e) => `[evidence:${e.id}] ${e.detail}`) };

  return { decision: 'auto_merge', reasons: ['致命的リスクに該当せず、誤っても revert で戻せる。証拠はすべて緑'] };
}
