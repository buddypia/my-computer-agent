/**
 * change-risk.mjs — Ship diff → approval tier (T0 / T1 / T2) with the reasons that decided it.
 *
 * Why: the ship gate's `approval` step asked a human about every diff identically, so the one
 * question that matters ("can this be taken back?") was never asked by anything. This classifier
 * asks it deterministically from the diff alone — no LLM judgment — so the same diff always gets
 * the same tier and a disagreement is a policy edit, not an argument (Meta RADAR keeps its gating
 * rule-based for the same reason: auditable, calibratable against revert rate).
 *
 * Fail-closed: any failure to read or classify the diff decides T2. The cost of a wrong T2 is one
 * human question; the cost of a wrong T0 is an unreviewed one-way door.
 *
 * Boundary (R-CM-028): Perspective 1 only (consumed by `pre-ship-steps.mjs`, never deployed).
 */

import { classifyReach } from './change-reach.mjs';
import { parseNumstat, normalizeRenamePath } from './ship-deck-core.mjs';
import { matchesAny, TIERS } from './approval-policy.mjs';
import { parseNameStatusRows } from '../../../.cli/lib/worktree-ship-report.mjs';
import { resolveShipBaseRefs } from '../../../.cli/lib/ship-base-branch.mjs';
import { defaultGit } from '../../../.cli/lib/ship-scale.mjs';

/** `old -> new` rename rows → both sides; a trust-boundary file renamed away still loosened the gate. */
function sidesOf(path) {
  const s = String(path ?? '').trim();
  return s.includes(' -> ') ? s.split(' -> ').map((p) => p.trim()) : [s];
}

const newSide = (path) => sidesOf(path).pop();

/**
 * The unit an escape demotes. Two leading segments, three under `.claude/skills/` so one skill's
 * escape does not demote every skill. Coarse on purpose: finer areas would let a fix land one
 * directory over from the defect and never meet the demotion.
 */
export function areaOf(path) {
  const parts = newSide(path).split('/').filter(Boolean);
  if (parts.length <= 1) return parts[0] ?? '';
  const depth = parts[0] === '.claude' && parts[1] === 'skills' && parts.length > 3 ? 3 : 2;
  return parts.slice(0, Math.min(depth, parts.length - 1)).join('/');
}

function churnIndex(numstat) {
  const index = new Map();
  for (const r of numstat) index.set(normalizeRenamePath(r.path), r);
  return index;
}

/**
 * @param {{nameStatusRows: Array<{path:string, kind:string}>, numstat: Array<{path:string, added:number|null, deleted:number|null}>,
 *          policy: object|null, policyError?: string|null, reachMap?: object|null}} input
 * @returns {{tier: string, reasons: Array<{code:string, detail:string}>, areas: string[],
 *            stats: {files:number, added:number, deleted:number, deletedFiles:number}}}
 */
/** Trust-boundary reason: any rename side that touches the approval mechanism itself. */
function checkTrustBoundary(sides, p, reasons) {
  const boundary = sides.find((s) => matchesAny(p.trustBoundary, s));
  if (boundary) reasons.push({ code: 'trust_boundary', detail: `${boundary} is part of the approval mechanism` });
}

/**
 * Direction reason: a decision record added, withdrawn or cut back (an architecture change or a
 * pivot). Both rename sides, as for the trust boundary. An additive edit stays reversible.
 */
function checkDirection({ sides, row, churnRow, p, reasons }) {
  const decision = sides.find((s) => matchesAny(p.direction, s));
  if (!decision) return;
  // Binary rows carry null counts: unknown deletions are treated as deletions.
  if (row.kind === 'EDIT' && churnRow?.deleted === 0) return;
  const what = row.kind === 'EDIT' ? `-${churnRow?.deleted ?? '?'}` : row.kind;
  reasons.push({ code: 'direction', detail: `${decision} (${what}) changes a decision later work builds on` });
}

/**
 * Data-contract reasons: a migration (always one-way) or a breaking/additive change to a contract file.
 * @returns {1|0} 1 if this row was an additive contract change (folded into the caller's `dataAdditive` tally).
 */
function checkDataContract({ sides, path, row, churnRow, p, reachMap, reasons }) {
  // Both rename sides, as for the trust boundary: a migration moved out of `migrations/` still ran.
  const migration = sides.find((s) => matchesAny(p.dataAlwaysOneWay, s));
  const contract = sides.find((s) => classifyReach(s, reachMap) === p.dataReachTier && !matchesAny(p.dataNotContract, s));
  if (migration) {
    reasons.push({ code: 'migration', detail: `${migration} changes stored data shape` });
    return 0;
  }
  if (!contract) return 0;
  // Binary rows carry null counts: unknown deletions are treated as deletions.
  const removes = row.kind === 'DELETE' || row.kind === 'RENAME' || churnRow?.deleted !== 0;
  if (removes) {
    reasons.push({ code: 'data_breaking', detail: `${contract} (${row.kind}, -${churnRow?.deleted ?? '?'}) may break a consumer` });
    return 0;
  }
  return 1;
}

/** Product-surface reasons: tallies files/LOC in the product-reach tier and flags screen-set adds/removes. */
function checkProductSurface({ path, row, churnRow, tier, p, product, reasons }) {
  if (tier !== p.productReachTier) return;
  product.files += 1;
  product.loc += (churnRow?.added ?? 0) + (churnRow?.deleted ?? 0);
  if ((row.kind === 'NEW' || row.kind === 'DELETE') && matchesAny(p.screenPaths, path)) {
    reasons.push({ code: 'screen_set', detail: `${path} ${row.kind === 'NEW' ? 'adds' : 'removes'} a screen` });
  }
}

/** Per-row reason accumulation: trust boundary, data contract, product surface, design system. */
function classifyRow({ row, churn, p, reachMap, reasons, product }) {
  const sides = sidesOf(row.path);
  const path = sides[sides.length - 1];
  const churnRow = churn.get(path);
  const tier = classifyReach(path, reachMap);

  checkTrustBoundary(sides, p, reasons);
  checkDirection({ sides, row, churnRow, p, reasons });
  const additive = checkDataContract({ sides, path, row, churnRow, p, reachMap, reasons });
  checkProductSurface({ path, row, churnRow, tier, p, product, reasons });
  if (matchesAny(p.designSystemPaths, path)) reasons.push({ code: 'design_system', detail: `${path} changes the design system` });
  return additive;
}

/** Whole-diff threshold reasons: large product change, or mass deletion. */
function checkDiffThresholds({ product, stats, p, reasons }) {
  if (product.files >= p.productMaxFiles || product.loc >= p.productMaxLoc) {
    reasons.push({
      code: 'large_product',
      detail: `product change ${product.files} files / ${product.loc} LOC (limit ${p.productMaxFiles} / ${p.productMaxLoc})`,
    });
  }
  if (stats.deletedFiles >= p.massDeletedFiles || stats.deleted >= p.massDeletedLoc) {
    reasons.push({
      code: 'mass_deletion',
      detail: `${stats.deletedFiles} files / ${stats.deleted} lines deleted (limit ${p.massDeletedFiles} / ${p.massDeletedLoc})`,
    });
  }
}

/** Aggregate added/deleted LOC and deleted-file count from the churn index + name-status rows. */
function computeDiffStats(rows, churn) {
  const stats = { files: rows.length, added: 0, deleted: 0, deletedFiles: 0 };
  for (const r of churn.values()) {
    stats.added += r.added ?? 0;
    stats.deleted += r.deleted ?? 0;
  }
  stats.deletedFiles = rows.filter((r) => r.kind === 'DELETE').length;
  return stats;
}

/** Final tier decision once every row and threshold reason has been collected. */
function decideFinalTier({ rows, reasons, dataAdditive, p, result }) {
  if (reasons.length) return result(TIERS.T2, reasons);
  if (rows.every((r) => sidesOf(r.path).every((s) => matchesAny(p.mechanicalPaths, s)))) {
    return result(TIERS.T0, [{ code: 'mechanical', detail: 'prose only — nothing reads it as instructions' }]);
  }
  const notes = [{ code: 'reversible', detail: 'no one-way door in the diff; a revert restores the prior state' }];
  if (dataAdditive) notes.push({ code: 'data_additive', detail: `${dataAdditive} contract file(s) changed additively` });
  return result(TIERS.T1, notes);
}

export function classifyDiffRisk({ nameStatusRows = [], numstat = [], policy, policyError = null, reachMap = null }) {
  const rows = Array.isArray(nameStatusRows) ? nameStatusRows : [];
  const churn = churnIndex(Array.isArray(numstat) ? numstat : []);
  const areas = [...new Set(rows.map((r) => areaOf(r.path)).filter(Boolean))].sort();
  const stats = computeDiffStats(rows, churn);
  const result = (tier, reasons) => ({ tier, reasons, areas, stats });

  if (!policy?.ship) return result(TIERS.T2, [{ code: 'no_policy', detail: policyError ?? 'approval policy unavailable' }]);
  if (rows.length === 0) return result(TIERS.T2, [{ code: 'no_diff', detail: 'no changed files measured — nothing to vouch for' }]);

  const p = policy.ship;
  const reasons = [];
  const product = { files: 0, loc: 0 };
  let dataAdditive = 0;

  for (const row of rows) {
    dataAdditive += classifyRow({ row, churn, p, reachMap, reasons, product });
  }

  checkDiffThresholds({ product, stats, p, reasons });

  return decideFinalTier({ rows, reasons, dataAdditive, p, result });
}

/**
 * Measures `<base>...HEAD` in the worktree and classifies it. Tries the same base refs as
 * `measureShipScale`, so tier and scale are never quoted against different bases.
 */
export function measureDiffRisk(worktreeAbs, { policy, policyError = null, reachMap = null, gitFn = defaultGit, io } = {}) {
  let lastError = 'no base ref resolved';
  for (const base of resolveShipBaseRefs(worktreeAbs, { gitFn, ...io })) {
    try {
      const nameStatus = String(gitFn(worktreeAbs, ['diff', '-M', '--name-status', `${base}...HEAD`]));
      const numstat = String(gitFn(worktreeAbs, ['diff', '-M', '--numstat', `${base}...HEAD`]));
      return {
        base,
        ...classifyDiffRisk({
          nameStatusRows: parseNameStatusRows(nameStatus),
          numstat: parseNumstat(numstat),
          policy,
          policyError,
          reachMap,
        }),
      };
    } catch (e) {
      lastError = e?.message ?? String(e);
    }
  }
  return {
    base: null,
    tier: TIERS.T2,
    reasons: [{ code: 'classifier_error', detail: `diff unreadable: ${lastError}` }],
    areas: [],
    stats: null,
  };
}
