/**
 * review-origin.mjs — Extracts original user request + AI interpretation (deck top-level input)
 *
 * Reads machine-derived request excerpts and AI interpretations to contrast user requests with deliverables.
 *
 * Source priority:
 *   1. PLAN.md `## Original Request` section (worktree-local, race-free).
 *   2. `current-task-passport.json` (session slot).
 * Returns null if absent (fail-open).
 *
 * Boundary (R-CM-028): perspective1-only — passport is Perspective 1 session state.
 */

import { readFileSync } from 'node:fs';
import { resolveSessionId, taskPassportPath } from './task-passport.mjs';

/**
 * Display relative path for passport in deck.
 */
export const PASSPORT_RELPATH = '.harness/session/current-task-passport.json'; // @layout-resolver-allow: display relative path

/**
 * Extracts original request from PLAN.md `## Original Request` or `## 원 요청` section (Priority 1 source).
 *
 * @param {string} planText
 * @returns {object|null}
 */
export function extractOriginFromPlan(planText) {
  if (!planText || typeof planText !== 'string') return null;
  const lines = planText.split(/\r?\n/);
  const start = lines.findIndex((l) =>
    /^##\s*(Original Request|원\s*요청)(?![\p{L}\p{N}])/iu.test(l.trim()),
  );
  if (start === -1) return null;
  const body = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^##\s/.test(lines[i].trim())) break;
    body.push(lines[i]);
  }
  const text = body
    .filter((l) => !/^\s*<!--/.test(l))
    .map((l) => l.replace(/^\s*>\s?/, ''))
    .join('\n')
    .trim();
  if (!text || /^\(작성\s*필요|\(needs\s*filling/i.test(text)) return null;
  return {
    excerpt: text,
    sha256: null,
    source: 'plan_md',
    recordedAt: null,
    stale: false,
    interpretation: { goal: null, scope: [], assumptions: [], verification: [] },
  };
}

function textOrNull(value) {
  const s = String(value ?? '').trim();
  return s || null;
}

function normalizeList(value) {
  if (Array.isArray(value)) return value.map((v) => textOrNull(v)).filter(Boolean);
  const s = textOrNull(value);
  return s ? [s] : [];
}

/**
 * Loads original request and AI interpretation from task passport (Priority 2 source).
 *
 * @param {string} repoRoot
 * @param {(p: string) => string} [readFn]
 * @returns {{excerpt: string, sha256: string|null, source: string, interpretation: object, recordedAt: string|null, stale: boolean, shared: boolean}|null}
 */
export function loadReviewOrigin(repoRoot, readFn = (p) => readFileSync(p, 'utf8')) {
  let passport;
  try {
    passport = JSON.parse(readFn(taskPassportPath(repoRoot)));
  } catch {
    return null;
  }
  const objective = passport?.active_objective ?? {};
  const excerpt = textOrNull(objective.excerpt);
  if (!excerpt) return null;

  const interp = passport?.ai_interpretation ?? {};
  const interpSha = textOrNull(interp.objective_sha256);
  const objSha = textOrNull(objective.sha256);
  return {
    excerpt,
    sha256: objSha,
    shared: resolveSessionId() === null,
    source: textOrNull(objective.source) ?? 'unknown',
    recordedAt: textOrNull(interp.recorded_at) ?? textOrNull(passport?.generated_at),
    stale: Boolean(objSha && interpSha && objSha !== interpSha),
    interpretation: {
      goal: textOrNull(interp.goal),
      scope: normalizeList(interp.scope),
      assumptions: normalizeList(interp.assumptions),
      verification: normalizeList(interp.verification),
    },
  };
}

/**
 * Resolves original user request from PLAN.md (Priority 1) or passport (Priority 2).
 */
export function resolveReviewOrigin({ planText = null, repoRoot = null } = {}, readFn) {
  return (
    extractOriginFromPlan(planText) ??
    (repoRoot ? loadReviewOrigin(repoRoot, readFn ?? ((p) => readFileSync(p, 'utf8'))) : null)
  );
}
