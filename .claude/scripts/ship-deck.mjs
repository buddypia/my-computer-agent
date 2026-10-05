#!/usr/bin/env node

/**
 * ship-deck.mjs — Pre-Ship Visual Review Deck generator CLI (R-CM-030 Rule 12).
 *
 * Why (R-CM-029 Rule 3 Proposal-stage obligation):
 *   (a) Threat: Pre-Ship Human Review Panels (full-panel prose) for large worktrees
 *       cause cognitive overload leading to superficial reviews.
 *   (b) Existing gap: Lack of in-repo pre-ship visualization assets.
 *   (c) Simpler alternatives: Checklist chat output or user-home preview dependencies rejected.
 *
 * Usage:
 *   node .claude/scripts/ship-deck.mjs --template            # print the narrative skeleton + rules
 *   node .claude/scripts/ship-deck.mjs --worktree .worktrees/feature/<task> \
 *     --narrative-json <path> [--base origin/main] [--out <dir>] \
 *     [--diagram <svg path>]
 *
 * Narrative contract: field presence + git path cross-check (lib/ship-deck-core.mjs) AND the
 * human-brief quality gate (lib/narrative-quality.mjs — ceilings, hype, empty phrases, cost of
 * the chosen option, where to review, known gaps). Both fail closed.
 *
 * Behavior:
 *   - Main root resolved via parent of `git rev-parse --git-common-dir`.
 *   - Git data collected via `git -C <worktree>`.
 *   - Output: <main>/.tmp/ship-deck/<safeBranch>/index.html (self-contained HTML).
 *   - stdout: JSON result (out/scale/stats/glossary_terms/plain_language).
 *
 * Exit codes:
 *   0 — Deck generation successful
 *   1 — Missing args / worktree absent / git collection failure / JSON parse error
 *
 * Boundary (R-CM-028): perspective1-only.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  inferBranchFromWorktreePath,
  resolveWorktreePlanPath,
  safeBranchKey,
} from '../../.cli/lib/worktree-plan-path.mjs';
import { parseNameStatusRows } from '../../.cli/lib/worktree-ship-report.mjs';
import { resolveMainRoot } from './mark-pre-ship-confirmed.mjs';
import { buildDeckModel, extractPlanGoal } from './lib/ship-deck-core.mjs';
import { resolveReviewOrigin } from './lib/review-origin.mjs';
import { resolveShipBaseRefs } from '../../.cli/lib/ship-base-branch.mjs';
import { loadFeatureIndexSafe } from './lib/deck-impact.mjs';
import { buildPlainLanguageLexicon, loadGlossaryRegistry } from './lib/plain-language.mjs';
import { renderDeckHtml } from './lib/ship-deck-render.mjs';
import { shipNarrativeTemplate } from './lib/narrative-quality.mjs';
import { buildReach, describeReach, loadReachMap } from './lib/change-reach.mjs';

/** Printed once when a repository has no project reach map — the banner is then a guess. */
const REACH_MAP_HINT =
  'no .claude/reach-map.json — reach computed from builtin conventions; add the map so production paths are not mistaken for local ones';


/**
 * Lexicon is read from running script's own repo root to ensure version alignment.
 */
const SCRIPT_REPO_ROOT = fileURLToPath(new URL('../../', import.meta.url));

export function parseArgs(argv) {
  const args = {};
  const flagMap = {
    '--worktree': 'worktree',
    '--branch': 'branch',
    '--base': 'base',
    '--out': 'out',
    '--quality-json': 'qualityJson',
    '--evidence-json': 'evidenceJson',
    '--checklist-json': 'checklistJson',
    '--narrative-json': 'narrativeJson',
    '--panel-md': 'panelMd',
    '--diagram': 'diagram',
  };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--template') {
      args.template = true;
      continue;
    }
    if (argv[i] === '--reach') {
      args.reach = true;
      continue;
    }
    const key = flagMap[argv[i]];
    if (!key) continue;
    args[key] = argv[i + 1];
    i += 1;
  }
  return args;
}

const DEPRECATED_INPUTS = {
  qualityJson: '--quality-json',
  evidenceJson: '--evidence-json',
  checklistJson: '--checklist-json',
  panelMd: '--panel-md',
};

/** Surfacing guidance for deprecated inputs instead of silent ignoring */
export function deprecatedShipDeckInputError(args) {
  const used = Object.entries(DEPRECATED_INPUTS)
    .filter(([key]) => args[key])
    .map(([, flag]) => flag);
  return used.length
    ? `${used.join(', ')} removed from ship-deck body inputs — use requirements/file_notes/tradeoffs in --narrative-json`
    : null;
}

/**
 * Collects git data using injectable execFn for testability.
 * Uses base...HEAD (merge-base) to prevent divergent origin/main pollution.
 */
export function collectGitData({ worktreePath, baseRef, execFn }) {
  const run = (...gitArgs) => execFn(['-C', worktreePath, ...gitArgs]);
  const log = run('log', '--oneline', `${baseRef}..HEAD`);
  const numstatText = run('diff', `${baseRef}...HEAD`, '--numstat');
  const nameStatusText = run('diff', `${baseRef}...HEAD`, '--name-status');
  return {
    commits: log
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean),
    numstatText,
    nameStatusRows: parseNameStatusRows(nameStatusText),
  };
}

function defaultExec(gitArgs) {
  return execFileSync('git', gitArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
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
  process.stderr.write(`[ship-deck] ${message}\n`);
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

function readPlanGoal(worktreePath, branch) {
  try {
    const planPath = resolveWorktreePlanPath(worktreePath, branch);
    if (!existsSync(planPath)) return null;
    return extractPlanGoal(readFileSync(planPath, 'utf8'));
  } catch {
    return null;
  }
}

function readPlanText(worktreePath, branch) {
  try {
    const planPath = resolveWorktreePlanPath(worktreePath, branch);
    return existsSync(planPath) ? readFileSync(planPath, 'utf8') : null;
  } catch {
    return null;
  }
}

function readOptionalInputs(args) {
  const inputs = {};
  if (args.narrativeJson) inputs.narrative = readJsonOrFail(args.narrativeJson, '--narrative-json');
  if (args.diagram) inputs.diagramSvg = readFileOrFail(args.diagram, '--diagram');
  return inputs;
}

function resolveOutDir(args, mainRoot, branch) {
  if (!args.out) return join(mainRoot, '.tmp', 'ship-deck', safeBranchKey(branch));
  return isAbsolute(args.out) ? args.out : resolve(mainRoot, args.out);
}

function resolveLexicon(mainRoot) {
  const { glossary, errors } = loadGlossaryRegistry(mainRoot);
  for (const errorMessage of errors) {
    process.stderr.write(`[ship-deck] ${errorMessage}\n`);
  }
  if (!glossary) {
    process.stderr.write('[ship-deck] Plain language check skipped — glossary load failed (fail-open)\n');
    return null;
  }
  return buildPlainLanguageLexicon({ glossary });
}

/** Project reach map, or builtin conventions with a printed hint. A present-but-broken map fails. */
function loadReachMapOrFail(worktreePath) {
  let reachMap;
  try {
    reachMap = loadReachMap(worktreePath);
  } catch (err) {
    fail(`reach map unreadable: ${err.message}`);
  }
  if (reachMap.source === 'builtin') process.stderr.write(`[ship-deck] ${REACH_MAP_HINT}\n`);
  if (reachMap.warning) process.stderr.write(`[ship-deck] ${reachMap.warning}\n`);
  return reachMap;
}

/** `--reach`: the tier, what the gate will demand, and the touched paths per tier. */
function printReach(reach) {
  process.stdout.write(`${describeReach(reach)}\n`);
  for (const tier of reach.tiers.filter((t) => t.touched)) {
    process.stdout.write(`\n${tier.label} (${tier.files})\n`);
    for (const path of tier.paths) process.stdout.write(`  ${path}\n`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.template) {
    process.stdout.write(`${JSON.stringify(shipNarrativeTemplate(), null, 2)}\n`);
    return;
  }
  if (!args.worktree) {
    fail('Usage: node .claude/scripts/ship-deck.mjs --worktree <path> --narrative-json <path> | --worktree <path> --reach | --template');
  }
  const deprecatedInputError = deprecatedShipDeckInputError(args);
  if (deprecatedInputError) fail(deprecatedInputError);
  if (!args.narrativeJson && !args.reach) fail('--narrative-json <path> is required — a deck without narrative is not review material');
  const mainRoot = resolveMainRoot();
  if (!mainRoot) fail('Called outside git repo — failed to resolve main root');

  const worktreePath = isAbsolute(args.worktree) ? args.worktree : resolve(mainRoot, args.worktree);
  if (!existsSync(worktreePath)) fail(`worktree does not exist: ${worktreePath}`);

  const branch = args.branch || inferBranchFromWorktreePath(worktreePath);
  if (!branch) fail('Failed to infer branch — specify with --branch');

  const baseRef = resolveBaseRef(worktreePath, args.base);

  let gitData;
  try {
    gitData = collectGitData({ worktreePath, baseRef, execFn: defaultExec });
  } catch (err) {
    fail(`Failed to collect git data (base=${baseRef}): ${err.message}`);
  }

  const reachMap = loadReachMapOrFail(worktreePath);
  if (args.reach) {
    printReach(buildReach({ nameStatusRows: gitData.nameStatusRows, map: reachMap }));
    return;
  }

  const optionalInputs = readOptionalInputs(args);
  const lexicon = resolveLexicon(SCRIPT_REPO_ROOT);

  const model = buildDeckModel({
    branch,
    baseRef,
    generatedAt: new Date().toISOString(),
    commits: gitData.commits,
    numstatText: gitData.numstatText,
    nameStatusRows: gitData.nameStatusRows,
    planGoal: readPlanGoal(worktreePath, branch),
    lexicon,
    origin: resolveReviewOrigin({
      planText: readPlanText(worktreePath, branch),
      repoRoot: mainRoot,
    }),
    featureIndex: loadFeatureIndexSafe(worktreePath),
    reachMap,
    ...optionalInputs,
  });
  if (model.narrativeErrors.length) {
    fail(`narrative contract violation (reach: ${describeReach(model.reach)}):\n- ${model.narrativeErrors.join('\n- ')}`);
  }

  const outDir = resolveOutDir(args, mainRoot, branch);
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, 'index.html');
  writeFileSync(outPath, renderDeckHtml(model), 'utf8');

  process.stdout.write(
    `${JSON.stringify(
      {
        ok: true,
        out: outPath,
        branch,
        scale: model.scale,
        reach: describeReach(model.reach),
        stats: model.stats,
        glossary_terms: model.glossary.length,
        plain_language: lexicon ? 'checked' : 'skipped',
        open_hint: `open "${outPath}"`,
      },
      null,
      2,
    )}\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
