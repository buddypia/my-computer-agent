/**
 * test-run.mjs — Compares what `swift test` actually *ran* on the trunk and on the branch (pure).
 *
 * Why this exists (INC-009): three rounds of review found a new way to switch a Swift test off each
 * time — `#if` conditions, `.enabled { false }`, a custom `TestScoping` trait, `arguments: 0..<0`.
 * Listing spellings cannot close that class; asking the test runner can. A test that passed on the
 * trunk and does not pass on the branch (missing, skipped, failed) is a lowered bar no matter how it
 * was spelled, and a parameterized test that runs fewer cases is too.
 *
 * Input is Swift Testing's event stream (`swift test --event-stream-output-path … --event-stream-version 0`),
 * one JSON object per line. It was chosen over the console text and xUnit (INC-011): the console keys
 * case counts by display name (unnamed tests print unquoted, and two suites can share a name), and
 * xUnit has no per-case data at all. The event stream carries a `testID` on every test and case event.
 *
 * Key: `testID` without its trailing `:line:col`, so moving a test within its file is not a change but
 * moving it to another file is. Overloads in one file share a key; they are merged worst-first (any
 * skipped/failed wins over passed) and their case counts summed, so one cannot hide the other.
 *
 * Not covered: a test that runs and passes without asserting anything (an early `return`, a scope
 * trait that never calls the body). That is a *content* judgement left to the reviewer.
 */

const RANK = { passed: 0, skipped: 1, failed: 2 };
const worst = (a, b) => (RANK[a] >= RANK[b] ? a : b);

/** `Module.Suite/func()/File.swift:10:6` → `Module.Suite/func()/File.swift`. Suites have no `/`. */
export function testKey(testID) {
  const id = String(testID ?? '');
  if (!id.includes('/')) return null;
  return id.replace(/:\d+:\d+$/, '');
}

/**
 * @param {string} jsonl  event stream, version 0
 * @returns {Map<string, {status: 'passed'|'skipped'|'failed', cases: number}>}
 */
export function parseEventStream(jsonl) {
  // Per exact testID first, then merged per key.
  const byId = new Map();
  const get = (id) => byId.get(id) ?? byId.set(id, { ended: false, skipped: false, failed: false, cases: 0 }).get(id);
  for (const line of String(jsonl ?? '').split('\n')) {
    if (!line.trim()) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const p = rec?.kind === 'event' ? rec.payload : null;
    if (!p?.testID || !testKey(p.testID)) continue;
    const t = get(p.testID);
    if (p.kind === 'testCaseStarted') t.cases += 1;
    else if (p.kind === 'testSkipped') t.skipped = true;
    else if (p.kind === 'issueRecorded' && !p.issue?.isKnown) t.failed = true;
    else if (p.kind === 'testEnded') t.ended = true;
  }
  const out = new Map();
  for (const [id, t] of byId) {
    const status = t.failed ? 'failed' : t.skipped ? 'skipped' : t.ended ? 'passed' : 'failed';
    const key = testKey(id);
    const prev = out.get(key);
    out.set(key, prev ? { status: worst(prev.status, status), cases: prev.cases + t.cases } : { status, cases: t.cases });
  }
  return out;
}

/** True when the stream contains the end of a run — a crash or build failure leaves none. */
export function runCompleted(jsonl) {
  return String(jsonl ?? '')
    .split('\n')
    .some((line) => {
      try {
        const rec = JSON.parse(line);
        return rec?.kind === 'event' && rec.payload?.kind === 'runEnded';
      } catch {
        return false;
      }
    });
}

/**
 * @param {Map<string, {status: string, cases: number}>} base
 * @param {Map<string, {status: string, cases: number}>} head
 * @returns {Array<{signal: string, id: string, detail: string}>}
 */
export function compareRuns(base, head) {
  const findings = [];
  for (const [id, b] of base) {
    if (b.status !== 'passed') continue;
    const h = head.get(id);
    if (!h) {
      findings.push({ signal: 'test_not_run', id, detail: 'trunk で pass、branch では実行されていない（削除・改名・ファイル移動・無効化）' });
      continue;
    }
    if (h.status !== 'passed') {
      findings.push({ signal: `test_${h.status}`, id, detail: `trunk で pass、branch では ${h.status}` });
      continue;
    }
    if (b.cases > 0 && h.cases < b.cases) {
      findings.push({ signal: 'cases_reduced', id, detail: `パラメータ化テストのケース数 ${b.cases} → ${h.cases}` });
    }
  }
  return findings;
}
