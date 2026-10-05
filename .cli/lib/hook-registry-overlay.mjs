/**
 * hook-registry-overlay.mjs — Project-local overlay over the managed hook registry.
 *
 * A transplant target receives `.cli/lib/hook-registry.mjs` as a role=managed file: every re-transplant
 * overwrites it. Project-only hooks (e.g. a production-release-guard) therefore could not
 * live there without either being dropped on re-transplant (the guard silently turns off) or turning the
 * file into a fork. They live in `.claude/config/hook-registry.local.json` instead — target-owned, never
 * shipped or overwritten by transplant-bundle, and merged over the managed registry at module load by
 * hook-registry.mjs, so every consumer (orchestrator, hook-flags, regen-hooks-settings, validators) reads
 * the same merged view through that one loader.
 *
 * The overlay file MUST be committed (never gitignored): worktrees are fresh checkouts, so an untracked
 * overlay is absent there and every local guard silently turns off in that worktree.
 *
 * Overlay format:
 *   {
 *     "hooks":     { "<Event>": [ { "matcher": "Bash", "hooks": [ { "id": "...", "module": "...", ... } ] } ] },
 *     "overrides": { "<hook id>": { "timeout": 30, ... } }
 *   }
 *   - `hooks` ADDS entries, in the same shape as HOOK_REGISTRY (fields limited to ADD_FIELDS). A group whose
 *     matcher already exists for the event is appended to; otherwise a new group is created. An added id that
 *     collides with any managed id (any event) is rejected — change managed entries through `overrides`.
 *   - `overrides` changes OVERRIDABLE_FIELDS of existing managed entries by id (every event the id is under).
 *
 * Validation (every added and overridden value): timeout/cliTimeout positive integers (seconds), priority finite,
 * profile ∈ REGISTRY_PROFILES, booleans/strings/string arrays by field. Strings that reach the settings.json
 * command line (`module`, `commandArgs`) must pass a strict safe-charset check.
 *
 * Safety policy — managed safety guards (`profile: "minimal"`) cannot be weakened from here:
 *   The registry has no `required` flag; its safety tier is `minimal` — the guards that stay on under every
 *   profile, whose removal upstream is gated by R-CM-014 / R-CM-024 (hook-essential-set.test.mjs). A
 *   target-owned file is outside that governance, so an override of a minimal guard is rejected (with a
 *   warning) when it demotes `profile`, sets `if`, makes it `async`, drops `cliTargets`, changes `priority`,
 *   or lowers `timeout`/`cliTimeout` below the managed value. An added orchestrated entry may not run before a
 *   minimal guard it is dispatched with (priority below the highest overlapping minimal priority).
 *   Non-minimal guards MAY be downgraded (e.g. `profile: "none"` turns a standard guard off) — allowed but
 *   reported: every added entry and overridden field is listed by regen-hooks-settings and the transplant
 *   report (formatOverlaySummary), so a disabled guard is visible to a human.
 *
 * Failure policy: a missing file is the normal case (no-op). An unreadable/invalid file yields a warning and
 * the managed registry only — hooks must never crash on a broken local file.
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const HOOK_REGISTRY_LOCAL_REL = '.claude/config/hook-registry.local.json';

export const REGISTRY_PROFILES = new Set(['minimal', 'standard', 'none']);

export const OVERRIDABLE_FIELDS = new Set([
  'priority', 'profile', 'timeout', 'statusMessage', 'description', 'if', 'async', 'cliTargets', 'cliTimeout',
]);

const SAFETY_PROFILE = 'minimal';
const DEFAULT_CLI_TIMEOUT = 5; // cli-hooks-codegen.mjs DEFAULT_CLI_TIMEOUT — omitted cliTimeout means this
const MODULE_RE = /^(?:\.\/|\.\.\/scripts\/(?:lib\/)?|\.cli\/)[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)*\.mjs$/;
const SAFE_ARGS_RE = /^[A-Za-z0-9_.:=,/-]+(?: [A-Za-z0-9_.:=,/-]+)*$/;
const ID_RE = /^[a-z0-9][a-z0-9-]*$/;

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isPositiveInt = (v) => Number.isInteger(v) && v > 0; // seconds; 0 / negative / fractional / strings rejected
const isStringArray = (v) => Array.isArray(v) && v.every((s) => typeof s === 'string' && s.length > 0);

const FIELD_CHECKS = {
  id: [(v) => typeof v === 'string' && ID_RE.test(v), 'a kebab-case string'],
  module: [(v) => typeof v === 'string' && MODULE_RE.test(v), 'a ./x.mjs, ../scripts/x.mjs or .cli/…/x.mjs path'],
  priority: [(v) => typeof v === 'number' && Number.isFinite(v), 'a finite number'],
  profile: [(v) => REGISTRY_PROFILES.has(v), `one of ${[...REGISTRY_PROFILES].join('|')}`],
  timeout: [isPositiveInt, 'a positive integer (seconds)'],
  cliTimeout: [isPositiveInt, 'a positive integer (seconds)'],
  description: [(v) => typeof v === 'string', 'a string'],
  statusMessage: [(v) => typeof v === 'string', 'a string'],
  if: [(v) => typeof v === 'string' && v.length > 0, 'a non-empty string'],
  orchestrated: [(v) => typeof v === 'boolean', 'a boolean'],
  async: [(v) => typeof v === 'boolean', 'a boolean'],
  profileChecked: [(v) => typeof v === 'boolean', 'a boolean'],
  cliTargets: [isStringArray, 'an array of strings'],
  cliMatcherTools: [isStringArray, 'an array of strings'],
  commandArgs: [(v) => typeof v === 'string' && SAFE_ARGS_RE.test(v), 'space-separated [A-Za-z0-9_.:=,/-] tokens'],
};

/** Field allowlist for overlay-added entries (anything else, e.g. `type`/`prompt`, is rejected). */
export const ADD_FIELDS = new Set(Object.keys(FIELD_CHECKS));

/** Returns a reason when `field: value` has the wrong type/shape, else null. */
export function invalidFieldValue(field, value) {
  const check = FIELD_CHECKS[field];
  if (!check) return `field "${field}" is not allowed`;
  return check[0](value) ? null : `${field} must be ${check[1]} (got ${JSON.stringify(value)})`;
}

function lowersBudget(entry, field, value) {
  const managed = field === 'cliTimeout' ? (entry.cliTimeout ?? DEFAULT_CLI_TIMEOUT) : entry.timeout;
  if (typeof managed !== 'number') return `sets ${field} where the managed entry relies on the platform default`;
  return value < managed ? `lowers ${field} ${managed} → ${value}` : null;
}

function dropsCliTargets(entry, value) {
  const next = new Set(value);
  const dropped = (entry.cliTargets || []).filter((c) => !next.has(c));
  return dropped.length ? `drops CLI coverage (${dropped.join(', ')})` : null;
}

const SAFETY_CHECKS = {
  profile: (e, v) => (v !== SAFETY_PROFILE ? `demotes profile "${SAFETY_PROFILE}" → "${v}"` : null),
  if: () => 'adds/changes an `if` filter (narrows when the guard runs)',
  async: (e, v) => (v ? 'makes the guard async (it can no longer block)' : null),
  cliTargets: dropsCliTargets,
  priority: (e, v) => (v !== e.priority ? `changes priority ${e.priority} → ${v} (reorders the guard chain)` : null),
  timeout: (e, v) => lowersBudget(e, 'timeout', v),
  cliTimeout: (e, v) => lowersBudget(e, 'cliTimeout', v),
};

/** Returns a reason string when `field: value` would weaken a managed safety (minimal-profile) entry. */
function weakensSafetyGuard(entry, field, value) {
  if (entry.profile !== SAFETY_PROFILE || !SAFETY_CHECKS[field]) return null;
  return SAFETY_CHECKS[field](entry, value);
}

/** Reads the overlay file under rootDir. Returns {present, overlay|null, warnings}. Never throws. */
export function readHookRegistryOverlay(rootDir) {
  const abs = join(rootDir, HOOK_REGISTRY_LOCAL_REL);
  if (!existsSync(abs)) return { present: false, overlay: null, warnings: [] };
  try {
    const overlay = JSON.parse(readFileSync(abs, 'utf8'));
    if (!isPlainObject(overlay)) throw new Error('top level must be a JSON object');
    return { present: true, overlay, warnings: [] };
  } catch (err) {
    return {
      present: true,
      overlay: null,
      warnings: [`${HOOK_REGISTRY_LOCAL_REL} ignored (managed registry only): ${err.message}`],
    };
  }
}

function cloneRegistry(registry) {
  return JSON.parse(JSON.stringify(registry || {}));
}

function eventHookIds(groups) {
  return new Set(groups.flatMap((g) => (g.hooks || []).map((h) => h.id)));
}

function allHookIds(registry) {
  return new Set(Object.values(registry).flatMap((groups) => [...eventHookIds(groups)]));
}

const matcherTokens = (m) => (m === '*' || m === '' ? null : m.split('|').map((t) => t.trim()));

/** True when some tool name is dispatched to both matchers (hook-registry.mjs#matchesTool semantics). */
function matchersOverlap(a, b) {
  const ta = matcherTokens(a);
  const tb = matcherTokens(b);
  return !ta || !tb || ta.some((t) => tb.includes(t));
}

/** Highest priority among managed minimal guards dispatched together with `matcher` in `event`. */
function maxOverlappingMinimalPriority(managed, event, matcher) {
  const prios = (managed[event] || [])
    .filter((g) => matchersOverlap(g.matcher, matcher))
    .flatMap((g) => g.hooks.filter((h) => h.profile === SAFETY_PROFILE).map((h) => h.priority ?? 50));
  return prios.length ? Math.max(...prios) : null;
}

/**
 * An added orchestrated hook runs in-process in the same sequential chain as the managed guards; it must not
 * run before a minimal guard of that chain. Standalone (orchestrated:false) entries are separate processes that
 * Claude Code runs in parallel, so their registry priority only orders the settings.json array.
 */
function runsBeforeSafetyGuard(ctx, event, matcher, hook) {
  if (hook.orchestrated !== true) return null;
  const floor = maxOverlappingMinimalPriority(ctx.managed, event, matcher);
  const prio = hook.priority ?? 50;
  return floor !== null && prio < floor
    ? `orchestrated priority ${prio} would run before managed minimal guards of ${event}[${matcher}] (needs >= ${floor})`
    : null;
}

function addedHookProblem(ctx, event, matcher, hook, taken) {
  if (!isPlainObject(hook)) return 'entry is not an object';
  for (const required of ['id', 'module']) {
    if (hook[required] === undefined) return `missing \`${required}\``;
  }
  const badField = Object.entries(hook).map(([f, v]) => invalidFieldValue(f, v)).find(Boolean);
  if (badField) return `${hook.id}: ${badField}`;
  if (ctx.managedIds.has(hook.id)) return `${hook.id} collides with a managed hook id — change it through "overrides"`;
  if (taken.has(hook.id)) return `${hook.id} is already added for ${event}`;
  return runsBeforeSafetyGuard(ctx, event, matcher, hook);
}

/** Adds one overlay group's hooks into eventGroups (same-matcher group reused). Mutates acc. */
function addGroup(ctx, eventGroups, event, group, acc) {
  const { matcher } = group;
  const valid = [];
  for (const hook of Array.isArray(group.hooks) ? group.hooks : []) {
    const problem = addedHookProblem(ctx, event, matcher, hook, acc.taken);
    if (problem) {
      acc.warnings.push(`hooks.${event}[${matcher}]: ${problem} (entry ignored)`);
      continue;
    }
    valid.push({ ...hook });
    acc.taken.add(hook.id);
  }
  if (!valid.length) return;
  let target = eventGroups.find((g) => g.matcher === matcher);
  if (!target) eventGroups.push((target = { matcher, hooks: [] }));
  target.hooks.push(...valid);
  acc.added.push(...valid.map((h) => ({ event, matcher, id: h.id, profile: h.profile ?? null })));
}

/** Appends overlay groups of one event into merged[event]; returns {added, warnings}. */
function addEventGroups(ctx, merged, event, groups) {
  const acc = { taken: new Set(), added: [], warnings: [] };
  const eventGroups = merged[event] || [];
  for (const group of Array.isArray(groups) ? groups : []) {
    if (isPlainObject(group) && typeof group.matcher === 'string') addGroup(ctx, eventGroups, event, group, acc);
    else acc.warnings.push(`hooks.${event}: group without a string \`matcher\` ignored`);
  }
  if (eventGroups.length) merged[event] = eventGroups;
  return { added: acc.added, warnings: acc.warnings };
}

function addHooks(ctx, merged, hooks) {
  const added = [];
  const warnings = [];
  if (hooks === undefined) return { added, warnings };
  if (!isPlainObject(hooks)) return { added, warnings: ['`hooks` must be an object keyed by event (ignored)'] };
  for (const [event, groups] of Object.entries(hooks)) {
    if (ctx.validEvents && !ctx.validEvents.has(event)) {
      warnings.push(`hooks.${event}: unknown hook event (ignored)`);
      continue;
    }
    const r = addEventGroups(ctx, merged, event, groups);
    added.push(...r.added);
    warnings.push(...r.warnings);
  }
  return { added, warnings };
}

function managedEntriesById(merged, id, managedIds) {
  if (!managedIds.has(id)) return [];
  return Object.values(merged).flatMap((groups) => groups.flatMap((g) => g.hooks.filter((h) => h.id === id)));
}

/** Applies one override field to every entry, or returns the rejection reason. */
function applyOverrideField(entries, id, field, value, changes) {
  if (!OVERRIDABLE_FIELDS.has(field)) return `overrides.${id}.${field}: field is not overridable (ignored)`;
  const invalid = invalidFieldValue(field, value);
  if (invalid) return `overrides.${id}.${field}: ${invalid} (ignored)`;
  const weakening = entries.map((e) => weakensSafetyGuard(e, field, value)).find(Boolean);
  if (weakening) return `overrides.${id}.${field}: rejected — ${id} is a managed safety guard (profile "${SAFETY_PROFILE}"); the override ${weakening}`;
  changes.push({ id, field, from: entries[0][field] ?? null, to: value });
  for (const e of entries) e[field] = value;
  return null;
}

function applyOverrides(merged, overrides, managedIds) {
  const overridden = [];
  const warnings = [];
  if (overrides === undefined) return { overridden, warnings };
  if (!isPlainObject(overrides)) return { overridden, warnings: ['`overrides` must be an object keyed by hook id (ignored)'] };
  for (const [id, fields] of Object.entries(overrides)) {
    const entries = managedEntriesById(merged, id, managedIds);
    if (!entries.length || !isPlainObject(fields)) {
      warnings.push(`overrides.${id}: ${entries.length ? 'value must be an object' : 'no managed hook with this id'} (ignored)`);
      continue;
    }
    for (const [field, value] of Object.entries(fields)) {
      const rejected = applyOverrideField(entries, id, field, value, overridden);
      if (rejected) warnings.push(rejected);
    }
  }
  return { overridden, warnings };
}

/**
 * Pure merge: managed registry + overlay → { registry, added, overridden, warnings }.
 *   added:      [{event, matcher, id, profile}]  overridden: [{id, field, from, to}]
 * The managed registry object is never mutated.
 */
export function mergeHookRegistryOverlay(managed, overlay, { validEvents = null } = {}) {
  const merged = cloneRegistry(managed);
  if (!overlay) return { registry: merged, added: [], overridden: [], warnings: [] };
  const ctx = { managed, managedIds: allHookIds(merged), validEvents };
  const o = applyOverrides(merged, overlay.overrides, ctx.managedIds);
  const a = addHooks(ctx, merged, overlay.hooks);
  return { registry: merged, added: a.added, overridden: o.overridden, warnings: [...a.warnings, ...o.warnings] };
}

/** Reads + merges the overlay of rootDir. Never throws; warnings carry every ignored/rejected part. */
export function loadMergedHookRegistry(managed, rootDir, opts = {}) {
  const read = readHookRegistryOverlay(rootDir);
  const m = mergeHookRegistryOverlay(managed, read.overlay, opts);
  return { ...m, present: read.present, path: HOOK_REGISTRY_LOCAL_REL, warnings: [...read.warnings, ...m.warnings] };
}

/**
 * Human-facing summary of what the overlay changed — printed by regen-hooks-settings and the transplant report
 * (not per hook invocation). Empty array when no overlay file exists.
 */
export function formatOverlaySummary(status) {
  if (!status || !status.present) return [];
  const lines = [`[hook-registry] ${status.path}: ${status.added.length} added, ${status.overridden.length} overridden field(s), ${status.warnings.length} warning(s)`];
  for (const a of status.added) lines.push(`  + added ${a.event}[${a.matcher}] ${a.id} (profile ${a.profile ?? 'unset'})`);
  for (const c of status.overridden) {
    const off = c.field === 'profile' && c.to === 'none' ? '  ← guard DISABLED' : '';
    lines.push(`  ~ override ${c.id}.${c.field}: ${JSON.stringify(c.from)} → ${JSON.stringify(c.to)}${off}`);
  }
  for (const w of status.warnings) lines.push(`  ! ${w}`);
  return lines;
}
