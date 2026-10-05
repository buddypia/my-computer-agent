/**
 * review.mjs — Validates an independent review record (pure).
 *
 * The record is written by a reviewer that did not author the change (a fresh-context subagent or
 * another CLI). Only its *shape* and *binding* are checked here — whether the reviewer was thorough
 * is not something one record can prove; escapes measure it after the fact.
 *
 * Binding to `diff_id` is the point: a review of an earlier revision says nothing about the diff that
 * is about to land, and a stale PASS is how "green but worse" slips through.
 *
 * Record shape (docs/trust/auto-approval.md):
 *   { "diff_id": "<sha256>", "reviewer": "<who, and that it was not the author>",
 *     "verdict": "go" | "no-go",
 *     "findings": [{ "severity": "CRITICAL|HIGH|MEDIUM|LOW", "file": "...", "summary": "...",
 *                    "resolved": true|false }] }
 */

export const BLOCKING_SEVERITIES = new Set(['CRITICAL', 'HIGH']);
const SEVERITIES = new Set(['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']);

/** @returns {{ok: boolean, detail: string, blocking: Array<object>}} */
export function validateReview(record, diffId) {
  if (!record || typeof record !== 'object') return { ok: false, detail: 'レビュー記録なし', blocking: [] };
  if (!diffId) return { ok: false, detail: 'diff_id を解決できない（fail-closed）', blocking: [] };
  if (record.diff_id !== diffId) {
    return { ok: false, detail: `レビューが古い: reviewed ${String(record.diff_id).slice(0, 12)} ≠ current ${diffId.slice(0, 12)}`, blocking: [] };
  }
  if (typeof record.reviewer !== 'string' || record.reviewer.trim().length < 3) {
    return { ok: false, detail: 'reviewer が未記載', blocking: [] };
  }
  if (!Array.isArray(record.findings)) return { ok: false, detail: 'findings が配列でない', blocking: [] };

  const malformed = record.findings.filter((f) => !SEVERITIES.has(f?.severity));
  if (malformed.length > 0) {
    return { ok: false, detail: `未知の severity: ${malformed.map((f) => f?.severity).join(', ')}`, blocking: [] };
  }

  const blocking = record.findings.filter((f) => BLOCKING_SEVERITIES.has(f.severity) && f.resolved !== true);
  if (record.verdict !== 'go') return { ok: false, detail: `reviewer verdict=${record.verdict}`, blocking };
  if (blocking.length > 0) return { ok: false, detail: `未解決の CRITICAL/HIGH ${blocking.length} 件`, blocking };
  return { ok: true, detail: `go by ${record.reviewer} (findings ${record.findings.length}, blocking 0)`, blocking };
}
