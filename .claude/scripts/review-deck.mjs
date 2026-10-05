#!/usr/bin/env node

/**
 * review-deck.mjs — Stage Review Deck generator CLI (CP-SPEC / CP-PLAN / CP-MILESTONE / CP-UI).
 *
 * Generates gated visual checkpoints across lifecycle phases — "auto-generated and presented, never auto-passed".
 *
 * Usage:
 *   # CP-SPEC — Requirements specification review (after SPEC creation/update, before implementation)
 *   node .claude/scripts/review-deck.mjs --stage spec --spec docs/features/<id>/SPEC-*.md \
 *     --narrative-json <path> [--feature <docKey>] [--checklist-json <path>] \
 *     [--diagram <svg>] [--out <dir>]
 *
 *   # CP-PLAN — Pre-kickoff plan review (SPEC-less PLAN.md-only path — DEBT-224)
 *   node .claude/scripts/review-deck.mjs --stage plan --worktree .worktrees/<branch> \
 *     --narrative-json <path> [--plan <path>] [--branch <name>] \
 *     [--checklist-json <path>] [--diagram <svg>] [--out <dir>]
 *
 *   # CP-MILESTONE — Intermediate implementation review (when PLAN milestone is complete)
 *   node .claude/scripts/review-deck.mjs --stage milestone --worktree .worktrees/<branch> \
 *     --narrative-json <path> [--milestone "M1 core"] [--base origin/main] \
 *     [--checklist-json <path>] [--diagram <svg>] [--out <dir>]
 *
 *   # CP-UI — Wireframe review (promoted format for ui-approval-gate — DEBT-226)
 *   node .claude/scripts/review-deck.mjs --stage ui --wireframe docs/wireframes/<id>-wireframe.md \
 *     --narrative-json <path> [--feature <docKey>] [--checklist-json <path>] \
 *     [--diagram <svg>] [--out <dir>]
 *
 *   --narrative-json: { what, why, how, next,
 *     file_notes: [{path, change, reason}],   // milestone
 *     fr_notes: [{id, ko, why, how}],         // spec
 *     tradeoffs: [{topic, chosen, rejected, why}],
 *     api_changes: [{surface, before, after, compat}],
 *     spec_changes: [{doc, change}],
 *     affected_features: [string], impact: string, regression_risk: string }
 *
 * Behavior:
 *   - milestone diff includes working tree changes against merge-base (uncommitted edits form the review subject).
 *   - Output: <main>/.tmp/review-deck/<key>/<stage>/index.html (self-contained HTML).
 *   - Feedback loop: review-result.json via ship-deck-bridge.
 *
 * Exit codes: 0 success / 1 invalid arguments or collection failure
 *
 * Boundary (R-CM-028): perspective1-only.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  inferBranchFromWorktreePath,
  resolveWorktreePlanPath,
  safeBranchKey,
} from '../../.cli/lib/worktree-plan-path.mjs';
import { parseNameStatusRows } from '../../.cli/lib/worktree-ship-report.mjs';
import { resolveMainRoot } from './mark-pre-ship-confirmed.mjs';
import { slugify } from './lib/ship-deck-core.mjs';
import {
  buildPlainLanguageLexicon,
  collectProseFields,
  evaluatePlainLanguage,
  findRedundantNarrativeGlossary,
  formatPlainLanguageViolations,
  formatRedundantGlossaryEntries,
  loadGlossaryRegistry,
  withNarrativeGlossary,
} from './lib/plain-language.mjs';
import {
  buildMilestoneDeckModel,
  buildPlanDeckModel,
  buildSpecDeckModel,
  buildUiDeckModel,
} from './lib/review-deck-core.mjs';
import { resolveReviewOrigin } from './lib/review-origin.mjs';
import { resolveShipBaseRefs } from '../../.cli/lib/ship-base-branch.mjs';
import { loadFeatureIndexSafe } from './lib/deck-impact.mjs';
import {
  renderMilestoneDeckHtml,
  renderPlanDeckHtml,
  renderSpecDeckHtml,
  renderUiDeckHtml,
} from './lib/review-deck-render.mjs';


/**
 * Lexicon is read from the running script's own repo root to ensure version alignment.
 */
const SCRIPT_REPO_ROOT = fileURLToPath(new URL('../../', import.meta.url));

export function parseArgs(argv) {
  const args = {};
  const flagMap = {
    '--stage': 'stage',
    '--spec': 'spec',
    '--plan': 'plan',
    '--wireframe': 'wireframe',
    '--feature': 'feature',
    '--worktree': 'worktree',
    '--branch': 'branch',
    '--base': 'base',
    '--milestone': 'milestone',
    '--out': 'out',
    '--checklist-json': 'checklistJson',
    '--narrative-json': 'narrativeJson',
    '--diagram': 'diagram',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const key = flagMap[argv[i]];
    if (!key) continue;
    args[key] = argv[i + 1];
    i += 1;
  }
  return args;
}

/**
 * Collects milestone git data — includes working tree diffs relative to merge-base.
 * Uses `-c core.quotepath=false` to receive raw UTF-8 paths without octal escapes.
 */
export function collectMilestoneGitData({ worktreePath, baseRef, execFn }) {
  const run = (...gitArgs) => execFn(['-C', worktreePath, '-c', 'core.quotepath=false', ...gitArgs]);
  const mergeBase = run('merge-base', baseRef, 'HEAD').trim();
  return {
    mergeBase,
    commits: run('log', '--oneline', `${baseRef}..HEAD`)
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean),
    numstatText: run('diff', mergeBase, '--numstat'),
    nameStatusRows: parseNameStatusRows(run('diff', mergeBase, '--name-status')),
    diffText: run('diff', mergeBase),
    untrackedPaths: run('ls-files', '--others', '--exclude-standard')
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean),
  };
}

function defaultExec(gitArgs) {
  return execFileSync('git', gitArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

/** Max byte limit for embedding untracked file contents */
const UNTRACKED_MAX_BYTES = 200 * 1024;

/**
 * Reads content of untracked files (DEBT-230) — embeds text files, marks binaries/oversized as notes.
 */
export function readUntrackedFiles(worktreePath, untrackedPaths, readFn = readFileSync) {
  return untrackedPaths.map((p) => {
    try {
      const buf = readFn(join(worktreePath, p));
      if (buf.length > UNTRACKED_MAX_BYTES) return { path: p, content: null, note: 'too_large' };
      if (buf.subarray(0, 8000).includes(0)) return { path: p, content: null, note: 'binary' };
      return { path: p, content: buf.toString('utf8') };
    } catch {
      return { path: p, content: null, note: 'unreadable' };
    }
  });
}

function resolveBaseRef(worktreePath, explicitBase) {
  if (explicitBase) return explicitBase;
  // Candidates come from the ship-base SSOT (configured base first, origin/main / main as
  // fallbacks) — a local ['origin/main', 'main'] measured unreleased base commits as this branch's
  // own work on projects that ship onto another branch.
  const candidates = resolveShipBaseRefs(worktreePath);
  for (const cand of candidates) {
    try {
      execFileSync('git', ['-C', worktreePath, 'rev-parse', '--verify', '--quiet', cand], {
        stdio: 'ignore',
      });
      return cand;
    } catch {
      /* Try next candidate */
    }
  }
  return candidates[0];
}

function fail(message) {
  process.stderr.write(`[review-deck] ${message}\n`);
  process.exit(1);
}

function readFileOrFail(path, label) {
  try {
    return readFileSync(path, 'utf8');
  } catch (err) {
    fail(`${label} read failed: ${path} — ${err.message}`);
    return null;
  }
}

function readJsonOrFail(path, label) {
  const raw = readFileOrFail(path, label);
  try {
    return JSON.parse(raw);
  } catch (err) {
    fail(`${label} JSON parse failed: ${path} — ${err.message}`);
    return null;
  }
}

/** Loads optional inputs — delegates defaults to model builders */
function readOptionalInputs(args, mainRoot, planText = null) {
  const inputs = { origin: resolveReviewOrigin({ planText, repoRoot: mainRoot }) };
  if (args.checklistJson) inputs.checklist = readJsonOrFail(args.checklistJson, '--checklist-json');
  if (args.narrativeJson) inputs.narrative = readJsonOrFail(args.narrativeJson, '--narrative-json');
  if (args.diagram) inputs.diagramSvg = readFileOrFail(args.diagram, '--diagram');
  return inputs;
}

function resolveOutDir(args, mainRoot, defaultSegments) {
  if (!args.out) return join(mainRoot, '.tmp', 'review-deck', ...defaultSegments);
  return isAbsolute(args.out) ? args.out : resolve(mainRoot, args.out);
}

/**
 * Plain language contract enforcement.
 */
function enforcePlainLanguage(model) {
  const { glossary, errors } = loadGlossaryRegistry(SCRIPT_REPO_ROOT);
  for (const errorMessage of errors) {
    process.stderr.write(`[review-deck] ${errorMessage}\n`);
  }
  if (!glossary) {
    process.stderr.write('[review-deck] Plain language check skipped — glossary load failed (fail-open)\n');
    return { ...model, glossary: [] };
  }
  const baseLexicon = buildPlainLanguageLexicon({ glossary });
  const lexicon = withNarrativeGlossary(baseLexicon, model.narrative);
  const { matches, violations } = evaluatePlainLanguage(
    collectProseFields(model.narrative),
    lexicon,
  );
  const messages = [
    ...formatPlainLanguageViolations(violations),
    ...formatRedundantGlossaryEntries(findRedundantNarrativeGlossary(model.narrative, baseLexicon)),
  ];
  if (messages.length) {
    fail(`Plain language contract violation:\n- ${messages.join('\n- ')}`);
  }
  return { ...model, glossary: matches };
}

function writeDeck({ outDir, html, payload }) {
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, 'index.html');
  writeFileSync(outPath, html, 'utf8');
  const resultJsonPath = join(outDir, 'review-result.json');
  process.stdout.write(
    `${JSON.stringify(
      {
        ok: true,
        out: outPath,
        ...payload,
        open_hint: `open "${outPath}"`,
        bridge_hint: `node .claude/scripts/ship-deck-bridge.mjs --out "${resultJsonPath}"`,
      },
      null,
      2,
    )}\n`,
  );
}

function runSpecStage(args, mainRoot) {
  if (!args.spec) fail('--stage spec requires --spec <SPEC.md path>');
  const specPath = isAbsolute(args.spec) ? args.spec : resolve(mainRoot, args.spec);
  if (!existsSync(specPath)) fail(`SPEC does not exist: ${specPath}`);

  const specText = readFileOrFail(specPath, '--spec');
  const docKey = args.feature || slugify(basename(specPath).replace(/\.md$/i, ''), 'spec');
  const model = enforcePlainLanguage(
    buildSpecDeckModel({
      specText,
      specPath: args.spec,
      docKey,
      generatedAt: new Date().toISOString(),
      ...readOptionalInputs(args, mainRoot),
    }),
  );
  writeDeck({
    outDir: resolveOutDir(args, mainRoot, [model.docKey, 'spec']),
    html: renderSpecDeckHtml(model),
    payload: {
      stage: 'spec',
      docKey: model.docKey,
      scale: model.scale,
      fr_count: model.frs.length,
      acceptance_count: model.acceptance.length,
      narrative_provided: Boolean(model.narrative),
      checklist_slugs: model.checklist.map((i) => i.slug),
    },
  });
}

function runMilestoneStage(args, mainRoot) {
  if (!args.worktree) fail('--stage milestone requires --worktree <path>');
  const worktreePath = isAbsolute(args.worktree) ? args.worktree : resolve(mainRoot, args.worktree);
  if (!existsSync(worktreePath)) fail(`worktree does not exist: ${worktreePath}`);

  const branch = args.branch || inferBranchFromWorktreePath(worktreePath);
  if (!branch) fail('Failed to infer branch — specify with --branch');

  const baseRef = resolveBaseRef(worktreePath, args.base);
  let gitData;
  try {
    gitData = collectMilestoneGitData({ worktreePath, baseRef, execFn: defaultExec });
  } catch (err) {
    fail(`Failed to collect git data (base=${baseRef}): ${err.message}`);
  }

  let planText = null;
  try {
    const planPath = resolveWorktreePlanPath(worktreePath, branch);
    if (existsSync(planPath)) planText = readFileSync(planPath, 'utf8');
  } catch {
    /* Missing PLAN — model reports as undetected */
  }

  const model = enforcePlainLanguage(
    buildMilestoneDeckModel({
      branch,
      baseRef,
      milestoneLabel: args.milestone ?? null,
      generatedAt: new Date().toISOString(),
      commits: gitData.commits,
      numstatText: gitData.numstatText,
      nameStatusRows: gitData.nameStatusRows,
      untrackedPaths: gitData.untrackedPaths,
      untrackedFiles: readUntrackedFiles(worktreePath, gitData.untrackedPaths),
      diffText: gitData.diffText,
      planText,
      featureIndex: loadFeatureIndexSafe(worktreePath),
      ...readOptionalInputs(args, mainRoot, planText),
    }),
  );
  writeDeck({
    outDir: resolveOutDir(args, mainRoot, [
      safeBranchKey(branch),
      `milestone-${slugify(model.milestoneLabel, 'checkpoint')}`,
    ]),
    html: renderMilestoneDeckHtml(model),
    payload: {
      stage: 'milestone',
      branch,
      milestone: model.milestoneLabel,
      scale: model.scale,
      stats: model.stats,
      progress: model.progress,
      untracked_count: model.untrackedPaths.length,
      narrative_provided: Boolean(model.narrative),
      diff_files_embedded: model.diffFiles.length,
      checklist_slugs: model.checklist.map((i) => i.slug),
    },
  });
}

/** CP-PLAN target resolution — prefers direct `--plan`, otherwise standard worktree location */
function resolvePlanTarget(args, mainRoot) {
  if (args.plan) {
    return {
      branch: args.branch || null,
      planPath: isAbsolute(args.plan) ? args.plan : resolve(mainRoot, args.plan),
    };
  }
  if (!args.worktree) fail('--stage plan requires --plan <PLAN.md> or --worktree <path>');
  const worktreePath = isAbsolute(args.worktree) ? args.worktree : resolve(mainRoot, args.worktree);
  if (!existsSync(worktreePath)) fail(`worktree does not exist: ${worktreePath}`);
  const branch = args.branch || inferBranchFromWorktreePath(worktreePath);
  if (!branch) fail('Failed to infer branch — specify with --branch');
  return { branch, planPath: resolveWorktreePlanPath(worktreePath, branch) };
}

/** CP-PLAN stage — pre-kickoff plan review for SPEC-less path (DEBT-224) */
function runPlanStage(args, mainRoot) {
  const { branch, planPath } = resolvePlanTarget(args, mainRoot);
  if (!existsSync(planPath)) fail(`PLAN.md does not exist: ${planPath}`);
  const planBody = readFileOrFail(planPath, 'PLAN.md');

  const model = enforcePlainLanguage(
    buildPlanDeckModel({
      planText: planBody,
      planPath: args.plan ?? planPath,
      branch,
      generatedAt: new Date().toISOString(),
      ...readOptionalInputs(args, mainRoot, planBody),
    }),
  );
  writeDeck({
    outDir: resolveOutDir(args, mainRoot, [branch ? safeBranchKey(branch) : model.docKey, 'plan']),
    html: renderPlanDeckHtml(model),
    payload: {
      stage: 'plan',
      branch: model.branch,
      goal_detected: Boolean(model.goal),
      progress: model.progress,
      item_count: model.items.length,
      narrative_provided: Boolean(model.narrative),
      checklist_slugs: model.checklist.map((i) => i.slug),
    },
  });
}

/** CP-UI stage — renders wireframe markdown screens as an HTML deck (DEBT-226) */
function runUiStage(args, mainRoot) {
  if (!args.wireframe) fail('--stage ui requires --wireframe <wireframe md path>');
  const wfPath = isAbsolute(args.wireframe) ? args.wireframe : resolve(mainRoot, args.wireframe);
  if (!existsSync(wfPath)) fail(`Wireframe does not exist: ${wfPath}`);

  const docKey = args.feature || slugify(basename(wfPath).replace(/\.md$/i, ''), 'ui');
  const model = enforcePlainLanguage(
    buildUiDeckModel({
      wireframeText: readFileOrFail(wfPath, '--wireframe'),
      wireframePath: args.wireframe,
      docKey,
      generatedAt: new Date().toISOString(),
      ...readOptionalInputs(args, mainRoot),
    }),
  );
  writeDeck({
    outDir: resolveOutDir(args, mainRoot, [model.docKey, 'ui']),
    html: renderUiDeckHtml(model),
    payload: {
      stage: 'ui',
      docKey: model.docKey,
      screen_count: model.screens.length,
      narrative_provided: Boolean(model.narrative),
      checklist_slugs: model.checklist.map((i) => i.slug),
    },
  });
}

const STAGE_RUNNERS = {
  spec: runSpecStage,
  plan: runPlanStage,
  milestone: runMilestoneStage,
  ui: runUiStage,
};

function main() {
  const args = parseArgs(process.argv.slice(2));
  const runner = STAGE_RUNNERS[args.stage];
  if (!runner) {
    fail('Usage: node .claude/scripts/review-deck.mjs --stage spec|plan|milestone|ui ... (see docstring at top for details)');
  }
  if (!args.narrativeJson) {
    fail('--narrative-json <path> is required — a deck without what/why/how is not review material');
  }
  const mainRoot = resolveMainRoot();
  if (!mainRoot) fail('Called outside git repo — failed to resolve main root');
  runner(args, mainRoot);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
