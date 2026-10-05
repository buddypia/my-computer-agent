/**
 * worktree-plan-status.mjs — PLAN.md checklist status SSOT.
 *
 * Used by Stop hooks and create-pr so "ready for review" and "ready to ship"
 * mean the same thing: no unchecked, non-cancelled PLAN.md checklist items.
 */

import { existsSync, readFileSync } from 'node:fs';
import { resolveWorktreePlanPath } from './worktree-plan-path.mjs';
import { DEFAULT_REPORT_LABELS, formatLabel } from './worktree-ship-report.mjs';

export function stripIgnoredPlanSections(content) {
  return String(content || '')
    .replace(/```[\s\S]*?```/g, '')
    .replace(/<!--[\s\S]*?-->/g, '');
}

/**
 * Item waiver/cancellation marker vocabulary — **unchecked evaluation and obligation waiver evaluation must share the identical vocabulary.**
 *
 * Specifying separately risks drift where checklists pass while obligations remain un-waived.
 * This constant serves as the SSOT (shared with `plan-obligation.mjs#parseObligationDecisions`).
 */
export const CANCEL_MARKER_SOURCE =
  '\\(cancelled[^)]*\\)|\\(Cancelled[^)]*\\)|\\(취소됨[^)]*\\)|\\(dropped[^)]*\\)|\\(Dropped[^)]*\\)|\\(deferred[^)]*\\)|\\(Deferred[^)]*\\)|~~';

/** Checks whether a line contains a cancellation marker (no global flag — avoids lastIndex state pollution). */
export function hasCancelMarker(line) {
  return new RegExp(CANCEL_MARKER_SOURCE).test(String(line ?? ''));
}

const UNCHECKED_RE = new RegExp(
  `^[\\s]*[-*]\\s\\[\\s\\](?!.*(?:${CANCEL_MARKER_SOURCE})).*$`,
  'gm',
);

export function parseUncheckedPlanItems(content) {
  return stripIgnoredPlanSections(content).match(UNCHECKED_RE) || [];
}

export function readWorktreePlanChecklistStatus(worktreePath, branch = null, opts = {}) {
  const _existsSync = opts._existsSync || existsSync;
  const _readFileSync = opts._readFileSync || readFileSync;
  const plan_path = resolveWorktreePlanPath(worktreePath, branch);

  if (!_existsSync(plan_path)) {
    return {
      present: false,
      complete: false,
      unreadable: false,
      unchecked_count: null,
      unchecked: [],
      plan_path,
    };
  }

  try {
    const unchecked = parseUncheckedPlanItems(_readFileSync(plan_path, 'utf-8'));
    return {
      present: true,
      complete: unchecked.length === 0,
      unreadable: false,
      unchecked_count: unchecked.length,
      unchecked,
      plan_path,
    };
  } catch {
    return {
      present: true,
      complete: false,
      unreadable: true,
      unchecked_count: null,
      unchecked: [],
      plan_path,
    };
  }
}

/**
 * Display-only label (Stop hook listing + review panel `PLAN.md` field). Nothing parses the return
 * value, so a project may localize it: pass the resolved panel labels
 * (`worktree-ship-report.mjs#loadReviewPanelConfig(...).labels`). Omitted → built-in English.
 */
export function formatPlanChecklistStatus(status, labels = DEFAULT_REPORT_LABELS) {
  if (!status || status.present === false) return labels.plan_missing;
  if (status.unreadable) return labels.plan_unreadable;
  if (status.complete) return labels.plan_complete;
  return formatLabel(labels.plan_incomplete, { count: status.unchecked_count ?? '?' });
}
