/**
 * cli-flag-guard.mjs — Rejects CLI tokens a script does not understand, instead of ignoring them.
 *
 * Why (Root Cause): `args.includes('--dry-run')` reads a flag but never notices the ones it did not
 * read. On a script whose **default is to mutate** and where `--dry-run` is the opt-out, that turns a
 * typo into the opposite of what was asked: you request a preview and get an apply. Measured on
 * 2026-09-05 — `migrate-harness-layout.mjs --dry-runn` printed the same report as `--dry-run`
 * minus the `(DRY RUN)` banner, exited 0, and ran in apply mode. Nothing was destroyed only because
 * the plan happened to hold 0 moves.
 *
 *   Polarity is the whole story, which is why this guard is not applied everywhere:
 *   - `--write` / `--apply` opt-in (default = preview): a typo yields a preview. Fail-safe, no guard needed.
 *   - `--force` / `--confirm` opt-in: a typo leaves the guard on. Fail-safe.
 *   - `--dry-run` opt-out (default = mutate): a typo silently removes the safety. This is the class.
 *
 * Same failure shape as three fixes shipped the same week — `archive-and-reset` dropping an unknown
 * argument and proceeding to archive + reset (#1250), `record-quality-gate` dropping an unknown key
 * out of the PROOF record (#1251), and `ops.mjs` dropping the tracker's warning on the success path
 * (#1252). Each was found by reading, never by the tool saying anything.
 *
 * This is the SSOT for a check that already existed in bespoke form in `archive-and-reset.mjs`
 * (`unknownCliTokens`) and `ops.mjs` (`unknown_flag`). Scattered copies of an identical check are how
 * `main`-vs-`master` trunk detection quietly leaked (R-CM-008 Rule 6) — one implementation, one test.
 *
 * Boundary (R-CM-028): boundary-uniform — "reject what you cannot interpret" holds identically in
 * both perspectives. Not currently deployed to scaffolds; nothing here would need to change if it were.
 */

/**
 * Tokens in `argv` that `spec` does not declare.
 *
 * By default only `-`-prefixed tokens are candidates: positionals (an archive slug, a plan file) are
 * data and belong to the caller. `--` ends option parsing per POSIX Utility Syntax Guideline 10;
 * everything after it becomes a positional and is judged by the same `allowPositionals` rule.
 *
 * `allowPositionals: false` is for CLIs that take **no** positionals at all. There, a stray word is
 * as meaningless as a stray flag, and staying silent about it is the same failure — `archive-and-reset`
 * has zero required arguments, so an ignored token is indistinguishable from "no flags given", which
 * is precisely the input that archives and resets the run. Letting `--` grant a blanket pass would
 * reopen that hole from the other side: `archive-and-reset -- --dry-runn` would parse clean and then
 * run in apply mode, because `--dry-run` is still absent (measured while replacing the bespoke scan).
 *
 * @param {string[]} argv Tokens after the script name (`process.argv.slice(2)`)
 * @param {{flags?: string[], valueFlags?: string[], allowPositionals?: boolean}} spec `flags` are
 *   boolean; each `valueFlags` entry consumes the following token, so `--worktree --weird` treats
 *   `--weird` as the path it is.
 * @returns {string[]} Unknown tokens in the order given
 */
export function unknownFlags(argv, spec = {}) {
  const flags = new Set(spec.flags ?? []);
  const valueFlags = new Set(spec.valueFlags ?? []);
  const allowPositionals = spec.allowPositionals !== false;
  const tokens = (Array.isArray(argv) ? argv : []).map((t) => String(t ?? ''));

  // A CLI that takes no positionals has nothing to protect with `--`, so the terminator is not
  // honoured there and `--` stays an ordinary unknown token.
  const terminator = allowPositionals ? tokens.indexOf('--') : -1;
  const options = terminator < 0 ? tokens : tokens.slice(0, terminator);

  const unknown = [];
  for (let i = 0; i < options.length; i++) {
    const token = options[i];
    if (!token.startsWith('-')) {
      if (!allowPositionals) unknown.push(token);
      continue;
    }

    const eq = token.indexOf('=');
    const name = eq < 0 ? token : token.slice(0, eq);

    if (valueFlags.has(name)) {
      if (eq < 0) i++;
      continue;
    }
    if (!flags.has(name)) unknown.push(token);
  }
  return unknown;
}

/**
 * Exits 2 when `argv` carries a token `spec` does not declare. No-op otherwise.
 *
 * Exit 2 (not 1) distinguishes "you asked for something I cannot parse" from "the work failed",
 * matching `archive-and-reset.mjs#parseCliOpts`. The accepted list is printed because the caller is
 * usually recovering from a typo and the nearest correct spelling is the whole answer.
 *
 * @param {string[]} argv
 * @param {{flags?: string[], valueFlags?: string[]}} spec
 * @param {{name?: string, usage?: string}} [opts] `name` is a free-form label prefixed to the
 *   message — pass whatever prefix the calling script already uses for its errors, so the guard does
 *   not introduce a second voice. `usage` replaces the generated accepted-flag list.
 */
export function assertKnownFlags(argv, spec = {}, opts = {}) {
  const unknown = unknownFlags(argv, spec);
  if (unknown.length === 0) return;

  const label = opts.name ? `${opts.name}: ` : '';
  console.error(`${label}unknown argument(s): ${unknown.join(' ')}`);
  console.error(
    opts.usage ?? `accepted: ${[...(spec.flags ?? []), ...(spec.valueFlags ?? [])].sort().join(' ')}`,
  );
  process.exit(2);
}
