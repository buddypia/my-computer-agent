#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import {
  auditCodeOwnershipIndex,
  buildCodeOwnershipIndex,
  queryOwnershipIndex,
  renderAuditSummary,
  renderIndexSummary,
  renderQuerySummary,
} from './lib/code-ownership-index.mjs';

const USAGE = `Usage:
  node .claude/scripts/generate-code-ownership-index.mjs generate [--json] [--write] [--out <path>]
  node .claude/scripts/generate-code-ownership-index.mjs query "<request text>" [--json]
  node .claude/scripts/generate-code-ownership-index.mjs audit [--json]

The index is derived from project-config.json, docs/features/domain-map.json,
feature CONTEXT.json files, SPEC docs, and filesystem discovery. It is not a new SSOT.`;

function parseArgs(argv) {
  const args = [...argv];
  const command = args.shift();
  const flags = new Set();
  const positional = [];
  let out = null;

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--out') {
      out = args[i + 1] || null;
      i += 1;
    } else if (arg.startsWith('--')) {
      flags.add(arg);
    } else {
      positional.push(arg);
    }
  }

  return { command, flags, positional, out };
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function writeJson(projectDir, outPath, value) {
  const abs = resolve(projectDir, outPath || '.tmp/code-ownership-index.json');
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, `${JSON.stringify(value, null, 2)}\n`);
  return abs;
}

function main(argv = process.argv.slice(2), projectDir = process.cwd()) {
  const { command, flags, positional, out } = parseArgs(argv);
  if (!command || flags.has('--help') || flags.has('-h')) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }

  const index = buildCodeOwnershipIndex(projectDir);
  const json = flags.has('--json');

  if (command === 'generate') {
    if (flags.has('--write')) {
      const written = writeJson(projectDir, out, index);
      if (!json) process.stdout.write(`Wrote ${written}\n`);
    }
    if (json) printJson(index);
    else process.stdout.write(`${renderIndexSummary(index)}\n`);
    return 0;
  }

  if (command === 'query') {
    const query = positional.join(' ').trim();
    if (!query) {
      process.stderr.write(`${USAGE}\n`);
      return 2;
    }
    const result = queryOwnershipIndex(index, query);
    if (json) printJson(result);
    else process.stdout.write(`${renderQuerySummary(result)}\n`);
    return 0;
  }

  if (command === 'audit') {
    const result = auditCodeOwnershipIndex(index);
    if (json) printJson(result);
    else process.stdout.write(`${renderAuditSummary(result)}\n`);
    return result.ok ? 0 : 1;
  }

  process.stderr.write(`${USAGE}\n`);
  return 2;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exitCode = main();
}

export { main };
