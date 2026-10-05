/**
 * approval-trust.mjs — Earned autonomy for the ship gate: escapes demote an area, prevention restores it.
 *
 * Why: auto-approval is only as trustworthy as its measured miss rate. An *escape* is a defect that
 * reached the trunk through an auto-approved ship and had to be fixed or reverted afterwards. Each
 * escape takes the areas it touched back to human approval (per-area demotion, user decision
 * 2026-09-25) until a recurrence-prevention guard — a test, hook or audit that would have caught it —
 * is on the trunk. That is the fix → prevent-recurrence loop, made the only way back to autonomy.
 * Sources: SRE error budgets as an autonomy throttle; blameless postmortem → poka-yoke.
 *
 * Detection is derived from trunk history, not self-report: a `fix:` / `revert` landing that touches
 * a file whose previous toucher was an auto-approved ship within the window is an escape. It
 * over-counts (a fix for an older bug in the same file still counts) — the allowed direction, since
 * a false escape costs one human approval and a missed one costs trust in every later auto-approval.
 *
 * Escapes are persisted as found so they outlive the scan window; the only exit is `prevent`.
 * There is deliberately no dismiss: an AI that can dismiss its own escapes grades its own work.
 *
 * Boundary (R-CM-028): Perspective 1 only (ship gate); the store lives in `.harness/system/`.
 */

import { existsSync, readFileSync } from 'node:fs';
import { writeJsonAtomicSync } from './atomic-fs.mjs';
import { areaOf } from './change-risk.mjs';
import { matchesAny } from './approval-policy.mjs';
import { resolveSystemFile } from '../../../.cli/lib/layout-resolver.mjs';

export const TRUST_STORE_FILENAME = 'approval-trust.json';

const DAY_MS = 86_400_000;
const RS = '\x1e';
const US = '\x1f';

export function trustStorePath(projectDir) {
  return resolveSystemFile(TRUST_STORE_FILENAME, projectDir);
}

/**
 * Trunk log with changed files, one git call (R-CM-008 Rule 9: record separator, never blank-line guessing).
 * `--numstat` so a fix's guard can be told from a guard it merely touched or deleted; `--no-renames`
 * keeps every row a plain path (a rename is its delete + add).
 */
export function trustLogArgs(baseBranch, depth) {
  return ['log', '--first-parent', '-n', String(depth), `--format=${RS}%H${US}%cI${US}%s`, '--numstat', '--no-renames', `origin/${baseBranch}`];
}

const NUMSTAT_ROW = /^(\d+|-)\t(\d+|-)\t(.+)$/;

/**
 * `grown`: files the commit added lines to. A bare path row (no counts) or a binary row counts as
 * not grown — unknown growth never resolves an escape.
 *
 * @returns {Array<{sha:string, at:string, subject:string, files:string[], grown:string[]}>} oldest first
 */
export function parseTrustLog(text) {
  const commits = [];
  for (const block of String(text ?? '').split(RS)) {
    const [header, ...rest] = block.split('\n');
    const [sha, at, subject] = header.split(US);
    if (!sha || !at) continue;
    const files = [];
    const grown = [];
    for (const line of rest.map((l) => l.trim()).filter(Boolean)) {
      const m = NUMSTAT_ROW.exec(line);
      files.push(m ? m[3] : line);
      if (m && Number(m[1]) > 0) grown.push(m[3]);
    }
    commits.push({ sha: sha.trim(), at: at.trim(), subject: subject ?? '', files, grown });
  }
  return commits.reverse();
}

/** merge_sha → ledger row, restricted to auto-approved ships (candidates for a later escape). */
function indexAutoApprovedShips(ledger) {
  const auto = new Map();
  for (const row of ledger ?? []) {
    if (row?.approval === 'auto' && typeof row.merge_sha === 'string' && row.merge_sha) auto.set(row.merge_sha, row);
  }
  return auto;
}

/**
 * Records one file touched by a `fix:`/`revert` commit as an escape if its previous toucher was an
 * auto-approved ship within the escape window. Mutates `found` in place (shared accumulator across
 * files/commits keeps `detectEscapes` itself a single pass).
 */
function recordEscapeIfWithinWindow({ file, commit, prevToucher, auto, windowMs, found, guardPaths }) {
  if (!prevToucher || prevToucher.sha === commit.sha || !auto.has(prevToucher.sha)) return;
  if (Date.parse(commit.at) - Date.parse(prevToucher.at) > windowMs) return;
  const id = `${prevToucher.sha.slice(0, 12)}..${commit.sha.slice(0, 12)}`;
  const e = found.get(id) ?? {
    id,
    auto_sha: prevToucher.sha,
    auto_pr: auto.get(prevToucher.sha)?.pr ?? null,
    fix_sha: commit.sha,
    fix_subject: commit.subject,
    fixed_at: commit.at,
    // Grown, not touched: deleting or trimming a test is not a guard against the defect.
    fix_guards: (commit.grown ?? []).filter((f) => matchesAny(guardPaths, f)),
    files: [],
    areas: [],
  };
  e.files.push(file);
  found.set(id, e);
}

/**
 * @param {{commits: ReturnType<typeof parseTrustLog>, ledger: object[], policy: object}} input
 * @returns {Array<{id:string, auto_sha:string, auto_pr:number|null, fix_sha:string, fix_subject:string, fixed_at:string, files:string[], areas:string[]}>}
 */
export function detectEscapes({ commits, ledger, policy }) {
  const esc = policy?.escape;
  if (!esc) return [];
  const auto = indexAutoApprovedShips(ledger);
  const windowMs = esc.windowDays * DAY_MS;
  const lastToucher = new Map();
  const found = new Map();
  for (const c of commits ?? []) {
    if (esc.fixSubject.test(c.subject)) {
      for (const file of c.files) {
        if (matchesAny(esc.ignorePaths, file)) continue;
        recordEscapeIfWithinWindow({ file, commit: c, prevToucher: lastToucher.get(file), auto, windowMs, found, guardPaths: esc.guardPaths });
      }
    }
    for (const file of c.files) lastToucher.set(file, { sha: c.sha, at: c.at });
  }
  for (const e of found.values()) e.areas = [...new Set(e.files.map(areaOf).filter(Boolean))].sort();
  return [...found.values()];
}

export function readTrustStore(path, { existsFn = existsSync, readFn = readFileSync } = {}) {
  if (!existsFn(path)) return { version: 1, escapes: [], preventions: [] };
  const raw = JSON.parse(String(readFn(path, 'utf-8')));
  return {
    version: 1,
    escapes: Array.isArray(raw?.escapes) ? raw.escapes : [],
    preventions: Array.isArray(raw?.preventions) ? raw.preventions : [],
  };
}

/**
 * Store ∪ live escapes (by id). Pure — the caller decides whether to persist. A stored escape
 * recorded before `fix_guards` existed takes it from the live scan, so it can resolve on its own.
 */
export function mergeEscapes(store, live) {
  const liveById = new Map((live ?? []).map((e) => [e.id, e]));
  const known = new Set(store.escapes.map((e) => e.id));
  const added = (live ?? []).filter((e) => !known.has(e.id));
  const escapes = store.escapes.map((e) =>
    e.fix_guards === undefined && liveById.get(e.id)?.fix_guards ? { ...e, fix_guards: liveById.get(e.id).fix_guards } : e,
  );
  return { store: { ...store, escapes: [...escapes, ...added] }, added };
}

/**
 * An escape whose fix grew its own guard (a test, hook or audit in `escape.guard_paths`) is
 * prevented by that fix — the same evidence `prevent` accepts ("changed by the fix or after"), read
 * from trunk history, so no one self-reports it. Only a fix that landed without a guard keeps the
 * area demoted: the automated review is known to have missed there, and nothing yet plugs the hole.
 *
 * @returns {{escapes: object[], unresolved: object[], demotedAreas: string[]}}
 */
export function trustState(store) {
  const prevented = new Set(store.preventions.map((p) => p.escape_id));
  for (const e of store.escapes) if (e.fix_guards?.length) prevented.add(e.id);
  const unresolved = store.escapes.filter((e) => !prevented.has(e.id));
  const demotedAreas = [...new Set(unresolved.flatMap((e) => e.areas ?? []))].sort();
  return { escapes: store.escapes, unresolved, demotedAreas };
}

/** Areas of this diff that are demoted, with the escape that demoted each. */
export function demotionsFor(areas, state) {
  const out = [];
  for (const area of areas ?? []) {
    const by = state.unresolved.find((e) => (e.areas ?? []).includes(area));
    if (by) out.push({ area, escape: by.id });
  }
  return out;
}

/**
 * A prevention counts only when the guard is on the trunk and changed by the fix or after it —
 * a guard that predates the escape evidently did not catch it.
 *
 * @param {{escape: object, guardPath: string, policy: object, baseBranch: string, runGit: (args: string[]) => string}} input
 * @returns {{ok: true, guard_sha: string} | {ok: false, error: string}}
 */
export function verifyPreventionGuard({ escape, guardPath, policy, baseBranch, runGit }) {
  const guard = String(guardPath ?? '').replace(/^\.\//, '');
  if (!guard) return { ok: false, error: '--guard is required' };
  if (!matchesAny(policy.escape.guardPaths, guard)) {
    return { ok: false, error: `${guard} is not a guard location (escape.guard_paths in the approval policy)` };
  }
  const trunk = `origin/${baseBranch}`;
  try {
    runGit(['cat-file', '-e', `${trunk}:${guard}`]);
  } catch {
    return { ok: false, error: `${guard} is not on ${trunk} — land the guard first, then register it` };
  }
  let sha = '';
  try {
    sha = String(runGit(['log', '-1', '--format=%H', `${escape.fix_sha}^..${trunk}`, '--', guard])).trim();
  } catch (e) {
    return { ok: false, error: `could not read ${guard} history: ${e?.message ?? e}` };
  }
  if (!sha) return { ok: false, error: `${guard} has not changed since the fix ${escape.fix_sha.slice(0, 12)} — it cannot be what prevents a recurrence` };
  return { ok: true, guard_sha: sha };
}

/** Ledger → approval counts. Rows written before this mechanism have no `approval` field. */
export function approvalCounts(ledger) {
  const counts = { auto: 0, human: 0, unrecorded: 0 };
  for (const row of ledger ?? []) {
    if (row?.approval === 'auto') counts.auto += 1;
    else if (row?.approval === 'human') counts.human += 1;
    else counts.unrecorded += 1;
  }
  return counts;
}

export function formatTrustStatus({ counts, state, added = [] }) {
  const rate = counts.auto ? `${((state.escapes.length / counts.auto) * 100).toFixed(1)}%` : 'n/a (no auto-approved ships yet)';
  const lines = [
    `Approvals: auto ${counts.auto} / human ${counts.human} (${counts.unrecorded} ledger rows predate approval recording)`,
    `Escapes: ${state.escapes.length} total, ${state.unresolved.length} unresolved — escape rate ${rate}`,
    `Demoted areas (human approval until a guard is registered): ${state.demotedAreas.length ? state.demotedAreas.join(', ') : 'none'}`,
  ];
  for (const e of state.unresolved) {
    lines.push(`  - ${e.id}: auto PR ${e.auto_pr ?? '?'} → "${e.fix_subject}" [${(e.areas ?? []).join(', ')}]`);
    lines.push(`    restore: node .claude/scripts/approval-trust.mjs prevent --escape ${e.id} --guard <test|hook|audit path> --note "<what it catches>"`);
  }
  if (added.length) lines.push(`New escapes recorded this run: ${added.map((e) => e.id).join(', ')}`);
  return lines.join('\n');
}

/**
 * One call for consumers: trunk log → live escapes → merged with the store → state.
 * Throws when the trunk or store cannot be read; the ship gate turns that into "human approval".
 */
export function loadTrust({ projectDir, baseBranch, ledger, policy, runGit, storePath = trustStorePath(projectDir), io }) {
  const commits = parseTrustLog(runGit(trustLogArgs(baseBranch, policy.escape.scanDepth)));
  const live = detectEscapes({ commits, ledger, policy });
  const { store, added } = mergeEscapes(readTrustStore(storePath, io), live);
  return { store, added, state: trustState(store), storePath };
}

export function saveTrustStore(path, store) {
  writeJsonAtomicSync(path, store);
}

/**
 * The ship gate's auto-approval verdict (pure). Every "no" names what a human must decide instead,
 * so the Panel shows why this ship needs them — not just that it does.
 *
 * @param {{risk: {tier:string, reasons:object[], areas:string[]}, qualityLabel: string|null,
 *          policy: object|null, trust: {state?: object, error?: string}}} input
 * @returns {{auto: boolean, tier: string, why: string, demotions: object[]}}
 */
/** T2 one-way doors always need a human — nothing else to check. */
function checkOneWayDoor(tier, risk, no) {
  if (tier !== 'T2') return null;
  return no(`T2 one-way door — ${(risk?.reasons ?? []).map((r) => r.detail).join('; ')}`);
}

/** The tier's required independent review label must be present on the PROOF ledger row. */
function checkReviewLabel(tier, qualityLabel, policy, no) {
  const accepted = policy?.ship?.reviewLabels?.[tier];
  if (accepted?.has(qualityLabel)) return null;
  return no(`${tier} needs an independent review label (${[...(accepted ?? [])].join(' | ')}); PROOF has ${qualityLabel ?? 'none'}`);
}

/** Areas touched by this diff must not currently be demoted by an unresolved escape. */
function checkDemotedAreas(risk, trust, no) {
  if (!trust?.state) return no(`escape history unreadable (${trust?.error ?? 'unknown'}) — cannot rule out a demoted area`);
  const demotions = demotionsFor(risk.areas, trust.state);
  if (!demotions.length) return null;
  return no(`demoted area(s) after an escape: ${demotions.map((d) => `${d.area} (${d.escape})`).join(', ')}`, demotions);
}

export function assessAutoApproval({ risk, qualityLabel, policy, trust }) {
  const tier = risk?.tier ?? 'T2';
  const no = (why, demotions = []) => ({ auto: false, tier, why, demotions });
  const denial =
    checkOneWayDoor(tier, risk, no) ?? checkReviewLabel(tier, qualityLabel, policy, no) ?? checkDemotedAreas(risk, trust, no);
  if (denial) return denial;
  return { auto: true, tier, why: `${tier} ${(risk.reasons ?? []).map((r) => r.code).join('+')}, label ${qualityLabel}, no demoted area`, demotions: [] };
}
