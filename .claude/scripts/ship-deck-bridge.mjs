#!/usr/bin/env node

/**
 * ship-deck-bridge.mjs — Structured feedback bridge for deck verdicts (minimal HTTP).
 *
 * Persists browser checklist verdicts (OK / Needs Fix + notes) in real-time to `review-result.json`.
 * AI consumers parse `state:"ng"` items directly into fix tasks without prose interpretation.
 *
 * Copying results via markdown in the deck works independently of this bridge —
 * this script provides automated synchronization (R-CM-030 Rule 12).
 *
 * Usage:
 *   node .claude/scripts/ship-deck-bridge.mjs --out .tmp/ship-deck/<safeBranch>/review-result.json [--port 7357]
 *
 * Endpoints:
 *   GET  /ping   → { ok: true, tool: "ship-deck-bridge" }  (deck connection status)
 *   POST /result → Stamps receivedAt on body (JSON) and writes to --out
 *
 * Exit codes: 0 Normal run (SIGINT termination) / 1 Missing args or occupied port
 *
 * Boundary (R-CM-028): perspective1-only.
 */

import http from 'node:http';
import { mkdirSync } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { writeJsonAtomicSync } from './lib/atomic-fs.mjs';

const MAX_BODY_BYTES = 1024 * 1024; // 1MB payload limit for checklist verdict

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
  // Chromium Private Network Access — allows loopback preflight from file:// pages
  'Access-Control-Allow-Private-Network': 'true',
};

function sendJson(res, status, body) {
  if (res.headersSent) return; // Prevent duplicate header error
  res.writeHead(status, { ...CORS_HEADERS, 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

/** review-result.json is consumed as SSOT by AI — atomic write (temp→rename, R-CM-024 / AGENTS.md Rule 2) */
function defaultWriteResult(path, payload) {
  mkdirSync(dirname(path), { recursive: true });
  writeJsonAtomicSync(path, payload);
}

function handlePostResult(req, res, { outPath, writeResult, now }) {
  let size = 0;
  const chunks = [];
  let aborted = false;
  req.on('error', () => {
    // Client socket error (ECONNRESET etc.) — fail-open to avoid crashing process
    aborted = true;
  });
  req.on('data', (chunk) => {
    if (aborted) return;
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      aborted = true;
      sendJson(res, 413, { ok: false, error: 'payload_too_large' });
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on('end', () => {
    if (aborted) return;
    let payload;
    try {
      payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
      sendJson(res, 400, { ok: false, error: 'invalid_json' });
      return;
    }
    // Checklist payload must always be a JSON object
    if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      sendJson(res, 400, { ok: false, error: 'expected_json_object' });
      return;
    }
    payload.receivedAt = now();
    try {
      writeResult(outPath, payload);
    } catch (err) {
      sendJson(res, 500, { ok: false, error: `write_failed: ${err.message}` });
      return;
    }
    sendJson(res, 200, { ok: true });
  });
}

/**
 * Request handler factory — injectable writeResult/now for serverless testing.
 */
export function createRequestHandler({
  outPath,
  writeResult = defaultWriteResult,
  now = () => new Date().toISOString(),
}) {
  return (req, res) => {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, CORS_HEADERS);
      res.end();
      return;
    }
    if (req.method === 'GET' && req.url === '/ping') {
      sendJson(res, 200, { ok: true, tool: 'ship-deck-bridge' });
      return;
    }
    if (req.method === 'POST' && req.url === '/result') {
      handlePostResult(req, res, { outPath, writeResult, now });
      return;
    }
    sendJson(res, 404, { ok: false, error: 'not_found' });
  };
}

function parseArgs(argv) {
  const args = { port: 7357 };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--out') {
      args.out = argv[i + 1];
      i += 1;
    } else if (argv[i] === '--port') {
      args.port = Number.parseInt(argv[i + 1], 10);
      i += 1;
    }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.out || !Number.isInteger(args.port)) {
    process.stderr.write('[ship-deck-bridge] Usage: node .claude/scripts/ship-deck-bridge.mjs --out <review-result.json> [--port 7357]\n');
    process.exit(1);
  }
  const outPath = isAbsolute(args.out) ? args.out : resolve(process.cwd(), args.out);
  const server = http.createServer(createRequestHandler({ outPath }));
  server.on('error', (err) => {
    process.stderr.write(`[ship-deck-bridge] Launch failed: ${err.message} (if port is occupied, use --port <number> and open deck with ?bridge=<number>)\n`);
    process.exit(1);
  });
  server.listen(args.port, '127.0.0.1', () => {
    process.stdout.write(`[ship-deck-bridge] http://127.0.0.1:${args.port} → ${outPath}\n`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
