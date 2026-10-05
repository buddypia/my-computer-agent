import { existsSync, readdirSync, statSync, rmSync, unlinkSync } from 'fs';
import { createHash } from 'crypto';
import { join, relative } from 'path';
import {
  getGovernanceRoot,
  resolveSystemFile,
  withProjectDirOverride,
} from '../../../.cli/lib/layout-resolver.mjs';
import { atomicWriteJson, safeReadJson } from '../../../.cli/lib/utils.mjs';
import { safeBranchKey } from '../../../.cli/lib/worktree-plan-path.mjs';
import { isHarnessInjectedText, promptExcerpt } from './harness-text.mjs';
import { normalizeAcceptance } from './task-acceptance.mjs';

export const TASK_PASSPORT_SCHEMA_VERSION = '1.0';

const STAGES = [
  { id: 'intake', order: 1, skill: 'business-analyzer', json: 'business-context.json', handoff: 'stage-1-handoff.json' },
  { id: 'market_research', order: 2, skill: 'market-researcher', json: 'market-research.json', handoff: 'stage-2-handoff.json' },
  { id: 'mvp_scoping', order: 3, skill: 'mvp-scoper', json: 'mvp-scope.json', handoff: 'stage-3-handoff.json' },
  { id: 'platform_decision', order: 4, skill: 'platform-selector', json: 'platform-decision.json', handoff: 'stage-4-handoff.json' },
  { id: 'stack_selection', order: 5, skill: 'stack-selector', json: 'stack-config.json', handoff: 'stage-5-handoff.json' },
  { id: 'infra_design', order: 6, skill: 'infra-designer', json: 'infra-config.json', handoff: 'stage-6-handoff.json' },
  { id: 'scaffolding', order: 7, skill: 'project-scaffolder', json: null, handoff: 'stage-7-handoff.json' },
  { id: 'output_gate', order: 8, skill: 'output-gate', json: 'pipeline-progress.json', handoff: 'stage-8-handoff.json' },
];

const STAGE_BY_ID = new Map(STAGES.map((stage) => [stage.id, stage]));
const PIPELINE_ROOT_DIRNAME = '.harness';

function unique(values, limit = 20) {
  const seen = new Set();
  const result = [];
  for (const value of values.flat(Infinity)) {
    if (typeof value !== 'string') continue;
    const normalized = value.trim();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    result.push(normalized);
    if (result.length >= limit) break;
  }
  return result;
}

function excerpt(text, limit = 240) {
  return promptExcerpt(text, limit);
}

function sha256(text) {
  return createHash('sha256').update(String(text || '')).digest('hex');
}

function relativeIfExists(projectDir, relPath) {
  return existsSync(join(projectDir, relPath)) ? relPath : null;
}

export { isHarnessInjectedText };

export const PASSPORT_STALE_TTL_HOURS = 24;

export const PASSPORT_RESTORE_REASONS = Object.freeze({
  MISSING: 'missing_passport',
  HARNESS_POLLUTED: 'harness_polluted_objective',
  UNKNOWN_AGE: 'unknown_age',
  TTL_EXCEEDED: 'ttl_exceeded',
  FRESH: 'fresh',
});

export function evaluatePassportRestore(passport, { nowMs = Date.now() } = {}) {
  if (!passport || typeof passport !== 'object') {
    return { restore: false, stale: false, reason: PASSPORT_RESTORE_REASONS.MISSING };
  }
  if (isHarnessInjectedText(passport.active_objective?.excerpt)) {
    return { restore: false, stale: false, reason: PASSPORT_RESTORE_REASONS.HARNESS_POLLUTED };
  }
  const generatedMs = Date.parse(passport.generated_at || '');
  if (!Number.isFinite(generatedMs)) {
    return { restore: true, stale: true, reason: 'unknown_age' };
  }
  const ageHours = (nowMs - generatedMs) / (60 * 60 * 1000);
  if (ageHours > PASSPORT_STALE_TTL_HOURS) {
    return { restore: true, stale: true, reason: 'ttl_exceeded', age_hours: Math.round(ageHours) };
  }
  return { restore: true, stale: false, reason: 'fresh', age_hours: Math.max(0, Math.round(ageHours)) };
}

export function readCurrentTaskPassport(projectDir, sessionId) {
  const slug = resolveSessionId(sessionId);
  const primary = safeReadJson(taskPassportPath(projectDir, slug), null);
  if (primary) return primary;
  if (slug) return null;
  return safeReadJson(taskPassportLegacyPath(projectDir), null);
}

/**
 * Reader for external observers (dashboards/aggregators) returning the latest session passport.
 *
 * @param {string} projectDir
 * @returns {object|null}
 */
export function readLatestTaskPassport(projectDir) {
  let newest = null;
  try {
    const bySession = join(sessionRoot(projectDir), 'by-session');
    if (existsSync(bySession)) {
      for (const entry of readdirSync(bySession, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const file = join(bySession, entry.name, 'current-task-passport.json');
        if (!existsSync(file)) continue;
        let mtime = 0;
        try { mtime = statSync(file).mtimeMs; } catch { continue; }
        if (!newest || mtime > newest.mtime) newest = { file, mtime };
      }
    }
  } catch {}
  if (newest) {
    const passport = safeReadJson(newest.file, null);
    if (passport) return passport;
  }
  return (
    safeReadJson(sharedTaskPassportPath(projectDir), null)
    ?? safeReadJson(taskPassportLegacyPath(projectDir), null)
  );
}

/**
 * Prunes older session passports to prevent unbounded disk growth.
 *
 * @param {string} projectDir
 * @param {number} [keep]
 */
export function pruneSessionPassports(projectDir, keep = MAX_SESSION_PASSPORTS) {
  try {
    const bySession = join(sessionRoot(projectDir), 'by-session');
    if (!existsSync(bySession)) return;
    const entries = readdirSync(bySession, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => {
        const dir = join(bySession, e.name);
        let mtime = 0;
        try { mtime = statSync(dir).mtimeMs; } catch {}
        return { dir, mtime };
      })
      .sort((a, b) => b.mtime - a.mtime);
    for (const stale of entries.slice(keep)) {
      rmSync(stale.dir, { recursive: true, force: true });
    }
  } catch {}
}

/**
 * Durable, session-independent store binding an AI interpretation + acceptance contract to a git
 * BRANCH rather than a CLAUDE_CODE_SESSION_ID. Root cause of the pre-ship acceptance gate defect
 * (DEFECT 1): checkAcceptance previously read whichever session passport the *caller* happened to
 * own, so a different session (or the same session after switching tasks) could ship a branch
 * while that branch's real acceptance criteria were never evaluated. Recording a branch-keyed copy
 * at `task-interpretation.mjs record` time makes the contract retrievable by the work unit being
 * shipped, independent of which session/terminal is doing the shipping.
 *
 *
 * One file per branch (`task-contract--<safeBranchKey>.json`), never a shared map: the store lives in
 * the cross-worktree system root, and a shared map's read-modify-write lets concurrent sessions on
 * *different* branches silently drop each other's entry — a dropped contract reads as "none
 * recorded" and the gate fails open. Per-branch files make every write a single atomic rename that
 * touches only its own branch; same-branch writers are last-writer-wins, which is the intended
 * "latest recorded interpretation" semantics.
 *
 * @param {string} projectDir
 * @param {string} branch
 * @returns {string} Absolute path to this branch's contract file in the flat `system` layout.
 */
export function branchContractPath(projectDir, branch) {
  return resolveSystemFile(`task-contract--${safeBranchKey(branch)}.json`, projectDir);
}

export function readBranchTaskContract(projectDir, branch) {
  if (!branch) return null;
  const entry = safeReadJson(branchContractPath(projectDir, branch), null);
  return entry && typeof entry === 'object' && !Array.isArray(entry) ? entry : null;
}

export function writeBranchTaskContract(projectDir, branch, contract) {
  if (!branch) return null;
  const entry = { ...contract, branch };
  atomicWriteJson(branchContractPath(projectDir, branch), entry);
  return entry;
}

/**
 * Drops `branch`'s contract once the branch has shipped — otherwise a later branch reusing the same
 * name would inherit a stale contract at its own ship gate.
 */
export function removeBranchTaskContract(projectDir, branch) {
  if (!branch) return false;
  try {
    unlinkSync(branchContractPath(projectDir, branch));
    return true;
  } catch (err) {
    if (err?.code === 'ENOENT') return false;
    throw err;
  }
}

/**
 * Resolves the acceptance contract that applies to `branch` — shared by
 * `mark-pre-ship-confirmed.mjs#checkAcceptance` and the `acceptance-contract` pre-ship-steps step so
 * the branch/session precedence logic is defined exactly once (DEFECT 1 root-cause fix).
 *
 * Precedence: (1) a durable branch-keyed contract always wins when present — it is the record of
 * what was actually promised for this work unit. (2) Only when no branch contract exists do we fall
 * back to the *current* session passport, and only if that passport's own interpretation declares
 * the same branch — an interpretation recorded for a different (or no) branch must never satisfy an
 * unrelated branch's gate, otherwise defect (1) reopens for legacy/undeclared passports.
 *
 * @param {string} projectDir
 * @param {string} branch
 * @param {{readPassport?: Function}} [deps]
 * @returns {{interp: object|null, source: 'branch_contract'|'session_passport'|null, passport: object|null}}
 */
export function resolveAcceptanceContract(projectDir, branch, { readPassport = readCurrentTaskPassport } = {}) {
  const result = { interp: null, source: null, passport: null };
  if (!branch) return result;
  let branchContract = null;
  try { branchContract = readBranchTaskContract(projectDir, branch); } catch { branchContract = null; }
  if (branchContract) {
    result.interp = branchContract;
    result.source = 'branch_contract';
    return result;
  }
  let passport;
  try { passport = readPassport(projectDir); } catch { passport = null; }
  result.passport = passport;
  if (!passport) return result;
  const sessionInterp = passport.ai_interpretation;
  if (sessionInterp && sessionInterp.branch === branch) {
    result.interp = sessionInterp;
    result.source = 'session_passport';
  }
  return result;
}

function buildInterpretation(passport, { goal, scope, assumptions, verification, acceptance, nonGoals, branch }) {
  const normalizedGoal = String(goal || '').trim();
  const normalizedVerification = String(verification || '').trim();
  if (!normalizedGoal) throw new Error('ai_interpretation.goal is required (AI re-statement of the goal).');
  if (!normalizedVerification) throw new Error('ai_interpretation.verification is required (completion verification method).');

  const toList = (v) => (Array.isArray(v) ? v : [v]).filter(Boolean).map((s) => String(s).trim()).filter(Boolean);
  const normalizedBranch = branch ? String(branch).trim() || null : null;
  return {
    objective_sha256: passport.active_objective?.sha256 || 'unknown',
    recorded_at: new Date().toISOString(),
    goal: normalizedGoal,
    scope: toList(scope),
    non_goals: toList(nonGoals),
    assumptions: toList(assumptions),
    verification: normalizedVerification,
    // Executable definition of done — validated here so a malformed contract fails at record time,
    // not silently at the ship gate (see task-acceptance.mjs).
    acceptance: normalizeAcceptance(acceptance),
    ...(normalizedBranch ? { branch: normalizedBranch } : {}),
  };
}

export function recordTaskInterpretation(projectDir, {
  goal, scope = [], assumptions = [], verification, acceptance = [], nonGoals = [], sessionId, branch = null,
} = {}) {
  const slug = resolveSessionId(sessionId);
  const passport = readCurrentTaskPassport(projectDir, slug);
  if (!passport) {
    const error = new Error(
      'No current task passport found — ai_interpretation can only be recorded after an actionable prompt generates a passport.',
    );
    error.code = 'NO_PASSPORT';
    throw error;
  }
  const interpretation = buildInterpretation(passport, {
    goal, scope, assumptions, verification, acceptance, nonGoals, branch,
  });
  const normalizedBranch = interpretation.branch || null;
  const latest = readCurrentTaskPassport(projectDir, slug) || passport;
  const updated = {
    ...latest,
    ai_interpretation: interpretation,
  };
  writeCurrentTaskPassport(projectDir, updated, slug);
  // Durable branch-bound copy — survives session switches so ship-time evaluation reads the
  // contract for the branch being shipped rather than whatever session happens to be shipping it.
  if (normalizedBranch) {
    writeBranchTaskContract(projectDir, normalizedBranch, interpretation);
  }
  return updated;
}

export function writeCurrentTaskPassport(projectDir, passport, sessionId) {
  const slug = resolveSessionId(sessionId);
  const result = atomicWriteJson(taskPassportPath(projectDir, slug), passport);
  if (slug) pruneSessionPassports(projectDir);
  return result;
}

function detectProjectRole(projectDir) {
  if (existsSync(join(projectDir, 'project-brief.json'))) return 'scaffold_target';
  if (
    existsSync(join(projectDir, 'data', 'process-contracts', 'harness.process-contract.json'))
    || existsSync(join(projectDir, '.claude', 'pipelines', 'harness.yaml'))
  ) {
    return 'generator';
  }
  return 'unknown';
}

function toProjectRelative(projectDir, absPath) {
  const relPath = relative(projectDir, absPath);
  return relPath && !relPath.startsWith('..') ? relPath : absPath;
}

function pipelineRoot(projectDir) {
  return join(projectDir, PIPELINE_ROOT_DIRNAME);
}

function systemFilePath(projectDir, filename) {
  const resolved = resolveSystemFile(filename, projectDir);
  if (existsSync(resolved)) return resolved;
  return join(pipelineRoot(projectDir), 'system', filename);
}

function activeRunPath(projectDir) {
  const root = pipelineRoot(projectDir);
  const newPath = join(root, 'run', 'active.json');
  if (existsSync(newPath)) return newPath;

  const systemLegacy = join(root, 'system', 'active-run.json');
  if (existsSync(systemLegacy)) return systemLegacy;

  const flatLegacy = join(root, 'active-run.json');
  if (existsSync(flatLegacy)) return flatLegacy;

  return newPath;
}

export function sessionSlug(sessionId) {
  if (typeof sessionId !== 'string') return null;
  const trimmed = sessionId.trim();
  return /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(trimmed) ? trimmed : null;
}

export function resolveSessionId(explicit) {
  return sessionSlug(explicit) ?? sessionSlug(process.env.CLAUDE_CODE_SESSION_ID);
}

export const MAX_SESSION_PASSPORTS = 10;

function sessionRoot(projectDir) {
  return join(pipelineRoot(projectDir), 'session');
}

export function taskPassportPath(projectDir, sessionId) {
  const slug = resolveSessionId(sessionId);
  return slug
    ? join(sessionRoot(projectDir), 'by-session', slug, 'current-task-passport.json')
    : sharedTaskPassportPath(projectDir);
}

function sharedTaskPassportPath(projectDir) {
  return join(sessionRoot(projectDir), 'current-task-passport.json');
}

function taskPassportLegacyPath(projectDir) {
  return systemFilePath(projectDir, 'current-task-passport.json');
}

function pipelineRootRel(projectDir) {
  return toProjectRelative(projectDir, pipelineRoot(projectDir));
}

function activeRunRelPath(projectDir) {
  return toProjectRelative(projectDir, activeRunPath(projectDir));
}

function taskPassportRelPath(projectDir) {
  return toProjectRelative(projectDir, taskPassportPath(projectDir));
}

function runStageOutputDir(projectDir, activeRun) {
  const root = pipelineRoot(projectDir);
  if (activeRun?.run_id) {
    return join(root, 'runs', activeRun.run_id, 'stage-output');
  }
  return join(root, 'stage-output');
}

function runHandoffDir(projectDir, activeRun) {
  const root = pipelineRoot(projectDir);
  if (activeRun?.run_id) {
    return join(root, 'runs', activeRun.run_id, 'handoff');
  }
  return join(root, 'handoff');
}

function collectGeneratorAgenticResearchFiles(projectDir, activeRun) {
  const dirs = unique([
    runStageOutputDir(projectDir, activeRun),
    runStageOutputDir(projectDir, null),
  ]);
  const refs = [];
  for (const dir of dirs) {
    const market = safeReadJson(join(dir, 'market-research.json'), null);
    if (!market) continue;
    if (Array.isArray(market.agentic_research_sessions)) {
      refs.push(...market.agentic_research_sessions.map((session) => session?.output_path));
    }
    if (Array.isArray(market.agentic_research_handoff?.canonical_files)) {
      refs.push(...market.agentic_research_handoff.canonical_files);
    }
  }
  return unique(refs, 10);
}

function collectScaffoldAgenticResearchFiles(projectDir) {
  const index = safeReadJson(join(projectDir, 'docs', 'harness', 'discovery-index.json'), null);
  const refs = [
    ...(index?.answer_grounding?.agentic_research?.canonical_files || []),
    ...(index?.files?.agentic_research || []),
  ];
  return unique(refs, 10);
}

function collectFeatureContexts(projectDir, limit = 5) {
  const roots = [
    'docs/features',
    'documentation/features',
  ];
  const contexts = [];
  for (const root of roots) {
    const absRoot = join(projectDir, root);
    if (!existsSync(absRoot)) continue;
    let entries = [];
    try {
      entries = readdirSync(absRoot, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const rel = join(root, entry.name, 'CONTEXT.json');
      const ctx = safeReadJson(join(projectDir, rel), null);
      if (!ctx) continue;
      const status = ctx.status || ctx.state || ctx.execution?.status || 'unknown';
      if (['done', 'completed', 'archived'].includes(String(status).toLowerCase())) continue;
      contexts.push({ path: rel, status, feature_id: ctx.feature_id || ctx.id || entry.name });
      if (contexts.length >= limit) return contexts;
    }
  }
  return contexts;
}

function governanceHandoffRel(projectDir) {
  try {
    const abs = withProjectDirOverride(projectDir, () =>
      join(getGovernanceRoot(), 'handoff', 'governance-audit-handoff-current.md'),
    );
    return relative(projectDir, abs);
  } catch {
    return null;
  }
}

function domainMustReadCandidates(projectDir, domain) {
  if (domain === 'governance') {
    return ['docs/11_ai_task_context_operating_contract.md', governanceHandoffRel(projectDir)];
  }
  if (domain === 'docs') return ['docs/index.md'];
  if (domain === 'memory') return ['docs/10_ai_knowledge_learning_governance.md'];
  return [];
}

function domainMustRead(projectDir, domains) {
  const out = [];
  for (const domain of Array.isArray(domains) ? domains : []) {
    for (const rel of domainMustReadCandidates(projectDir, domain)) {
      const existing = rel ? relativeIfExists(projectDir, rel) : null;
      if (existing) out.push(existing);
    }
  }
  return out;
}

function generatorPassport(projectDir, domains = []) {
  const activeRun = safeReadJson(activeRunPath(projectDir), null);
  const currentStage = activeRun?.current_stage || null;
  const stage = STAGE_BY_ID.get(currentStage) || null;
  const stageOutputDir = toProjectRelative(projectDir, runStageOutputDir(projectDir, activeRun));
  const handoffDir = toProjectRelative(projectDir, runHandoffDir(projectDir, activeRun));
  const previousStage = stage ? STAGES.find((item) => item.order === stage.order - 1) : null;
  const pipelineRel = pipelineRootRel(projectDir);
  const activeRunRel = activeRunRelPath(projectDir);

  const mustRead = [
    activeRunRel,
    'data/process-contracts/harness.process-contract.json',
    '.claude/pipelines/harness.yaml',
    stage?.json ? `${stageOutputDir}/${stage.json}` : null,
    previousStage?.json ? `${stageOutputDir}/${previousStage.json}` : null,
    previousStage?.handoff ? `${handoffDir}/${previousStage.handoff}` : null,
    ...domainMustRead(projectDir, domains),
  ].filter(Boolean);

  const agenticResearchFiles = collectGeneratorAgenticResearchFiles(projectDir, activeRun);

  return {
    role: 'generator',
    current_lock: {
      status: activeRun?.status || 'unknown',
      run_id: activeRun?.run_id || null,
      current_stage: currentStage,
      current_skill: stage?.skill || null,
      pipeline_type: activeRun?.pipeline_type || null,
    },
    context_authority: [
      activeRunRel,
      'data/process-contracts/harness.process-contract.json',
      '.claude/pipelines/harness.yaml',
      join(pipelineRel, 'runs', '<run_id>', 'stage-output', '*.json'),
      join(pipelineRel, 'runs', '<run_id>', 'handoff', '*.json'),
    ],
    must_read_before_action: unique(mustRead, 16),
    evidence: {
      agentic_research_files: agenticResearchFiles,
      answer_grounding_refs: [],
      agentic_research_usage: 'read_on_demand_before_market_scope_pricing_gtm_claims',
    },
    forbidden_assumptions: [
      'Do not reuse another business idea/run unless run_id and user request match.',
      'Do not treat completed outputs as current execution authority when active-run has current_stage.',
      'Do not rely on session-only research; use files recorded in stage output or docs/research.',
      'Do not eagerly read agentic_research_files during routine work; read them only when market, scope, pricing, GTM, or priority claims depend on them.',
    ],
  };
}

function scaffoldPassport(projectDir) {
  const projectBrief = safeReadJson(join(projectDir, 'project-brief.json'), null);
  const projectConfig = safeReadJson(join(projectDir, 'project-config.json'), null);
  const featureContexts = collectFeatureContexts(projectDir);
  const agenticResearchFiles = collectScaffoldAgenticResearchFiles(projectDir);
  const answerRefs = projectBrief?.answer_grounding?.evidence?.source_refs || [];

  return {
    role: 'scaffold_target',
    current_lock: {
      status: 'project-local',
      run_id: null,
      current_stage: null,
      current_skill: null,
      platform: projectConfig?.platform || projectBrief?.architecture?.platform || null,
    },
    context_authority: [
      'project-brief.json',
      'project-config.json',
      'docs/harness/discovery-index.json',
      'docs/features/<feature-id>/CONTEXT.json',
      'docs/features/<feature-id>/SPEC-*.md',
      'docs/features/<feature-id>/PLAN.md',
    ],
    must_read_before_action: unique([
      relativeIfExists(projectDir, 'project-brief.json'),
      relativeIfExists(projectDir, 'project-config.json'),
      relativeIfExists(projectDir, 'docs/harness/discovery-index.json'),
      ...featureContexts.map((ctx) => ctx.path),
    ], 16),
    evidence: {
      agentic_research_files: agenticResearchFiles,
      answer_grounding_refs: unique(answerRefs, 8),
      agentic_research_usage: 'read_on_demand_before_market_scope_pricing_gtm_claims',
    },
    active_features: featureContexts,
    forbidden_assumptions: [
      'Do not use harness generator active-run state as scaffold execution authority.',
      'Do not expand MVP scope without project-brief or discovery update.',
      'Do not make product/market/price claims without answer_grounding evidence refs.',
      'Do not eagerly read agentic_research_files during routine coding; read them only when market, scope, pricing, GTM, or priority claims depend on them.',
    ],
  };
}

function unknownPassport(projectDir) {
  return {
    role: 'unknown',
    current_lock: {
      status: 'unknown-project-role',
      run_id: null,
      current_stage: null,
      current_skill: null,
      project_dir: projectDir,
    },
    context_authority: [
      taskPassportRelPath(projectDir),
      'AGENTS.md',
      'CLAUDE.md',
    ],
    must_read_before_action: unique([
      relativeIfExists(projectDir, 'AGENTS.md'),
      relativeIfExists(projectDir, 'CLAUDE.md'),
      taskPassportRelPath(projectDir),
    ], 8),
    evidence: {
      agentic_research_files: [],
      answer_grounding_refs: [],
    },
    forbidden_assumptions: [
      'Do not assume this workspace is the harness generator or a generated scaffold project.',
      'Do not borrow pipeline state from another directory.',
      'Identify the project role from local SSOT files before making durable changes.',
    ],
  };
}

export function buildTaskPassport({
  projectDir, prompt = '', event = 'UserPromptSubmit', domains = [],
} = {}) {
  const root = projectDir || process.cwd();
  const role = detectProjectRole(root);
  const roleData = role === 'scaffold_target'
    ? scaffoldPassport(root)
    : role === 'generator'
      ? generatorPassport(root, domains)
      : unknownPassport(root);

  const previous = readCurrentTaskPassport(root);
  const carriedInterpretation =
    previous?.ai_interpretation && typeof previous.ai_interpretation === 'object'
      ? { ai_interpretation: previous.ai_interpretation }
      : {};

  return {
    ...carriedInterpretation,
    schema_version: TASK_PASSPORT_SCHEMA_VERSION,
    generated_at: new Date().toISOString(),
    generated_by: 'task-passport',
    event,
    passport_file: taskPassportRelPath(root),
    project_role: roleData.role || role,
    active_objective: {
      source: 'newest_user_message',
      excerpt: excerpt(prompt),
      sha256: sha256(prompt),
      compatibility_rule: 'Carry forward only prior context compatible with this newest user message.',
    },
    current_lock: roleData.current_lock,
    context_authority: roleData.context_authority,
    must_read_before_action: roleData.must_read_before_action,
    evidence: roleData.evidence,
    active_features: roleData.active_features || [],
    forbidden_assumptions: roleData.forbidden_assumptions,
    confusion_prevention: [
      'Newest user message wins over older thread context.',
      'Use context_authority files before acting on product, pipeline, scope, or governance claims.',
      'If task and authority files disagree, pause and reconcile instead of guessing.',
      'Persist new durable context to an SSOT file; do not leave it only in chat memory.',
    ],
  };
}

function bullets(values, limit = 6) {
  const list = Array.isArray(values) ? values.filter(Boolean).slice(0, limit) : [];
  if (list.length === 0) return '  - none';
  return list.map((value) => `  - ${value}`).join('\n');
}

function stalenessLineFor(passport, nowMs) {
  const freshness = evaluatePassportRestore(passport, { nowMs });
  if (!freshness.stale) return null;
  const age = freshness.reason === 'unknown_age' ? 'age unknown' : `${freshness.age_hours}h old`;
  return `objective_freshness: STALE (${age}) — this passport is a historical snapshot. The latest user message always takes precedence.`;
}

function interpretationBlockFor(passport) {
  const interp = passport.ai_interpretation;
  if (!interp || typeof interp !== 'object') return null;
  if (interp.objective_sha256 !== passport.active_objective?.sha256) {
    return 'ai_interpretation: STALE (objective changed) — record interpretation for new instruction.';
  }
  return [
    'ai_interpretation (AI interpretation contract — bound to objective sha):',
    `  goal: ${interp.goal || ''}`,
    `  scope: ${(interp.scope || []).join(', ') || 'none'}`,
    `  non_goals: ${(interp.non_goals || []).join(' | ') || 'none'}`,
    `  assumptions: ${(interp.assumptions || []).join(' | ') || 'none'}`,
    `  verification: ${interp.verification || ''}`,
    `  acceptance: ${(interp.acceptance || []).length} executable criteria (task-interpretation.mjs check)`,
  ].join('\n');
}

export function formatTaskPassportForContext(passport, { nowMs = Date.now() } = {}) {
  if (!passport || typeof passport !== 'object') return '';
  const lock = passport.current_lock || {};
  const evidence = passport.evidence || {};
  const activeFeatureLines = (passport.active_features || [])
    .slice(0, 4)
    .map((feature) => `${feature.feature_id || feature.path} (${feature.status || 'unknown'})`);
  const stalenessLine = stalenessLineFor(passport, nowMs);
  const interpretationBlock = interpretationBlockFor(passport);

  return [
    '<ai-task-passport>',
    `passport_file: ${passport.passport_file || 'current-task-passport.json'}`,
    `objective_sha256: ${passport.active_objective?.sha256 || 'unknown'}`,
    `objective_excerpt: ${passport.active_objective?.excerpt || ''}`,
    stalenessLine,
    interpretationBlock,
    `project_role: ${passport.project_role || 'unknown'}`,
    `current_lock: status=${lock.status || 'unknown'} stage=${lock.current_stage || 'none'} skill=${lock.current_skill || 'none'} run_id=${lock.run_id || 'none'}`,
    'must_read_before_action:',
    bullets(passport.must_read_before_action, 8),
    `agentic_research_usage: ${evidence.agentic_research_usage || 'read_on_demand'}`,
    'agentic_research_files:',
    bullets(evidence.agentic_research_files, 6),
    activeFeatureLines.length > 0 ? `active_features:\n${bullets(activeFeatureLines, 4)}` : 'active_features:\n  - none',
    'anti_confusion_rules:',
    bullets(passport.confusion_prevention, 6),
    '</ai-task-passport>',
  ].filter((line) => line !== null && line !== undefined).join('\n');
}
