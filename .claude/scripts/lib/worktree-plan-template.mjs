/**
 * worktree-plan-template.mjs — Worktree mailbox (`.tmp/worktree-<safeBranch>/`)
 * standard template helper. Manages PLAN.md (automatically generated on worktree-init)
 * and handoff.md (RETURN contract — generated on-demand at handoff time).
 *
 * Purpose (R-CM-030 worktree flow + retrospective resolutions #1 #5 #6):
 *   - Automatically creates PLAN.md at the canonical path resolved by
 *     `worktree-plan-path.mjs#resolveWorktreePlanPath` SSOT → eliminates misplaced files.
 *   - Splits verify section into "Automated" and "Manual" categories → forces conscious
 *     distinction between automated verification and user-dependent checks.
 *   - Acceptance freeze + Status evidence discipline (teamwork-preview transplant, user decision 2026-07-14)
 *     → freezes acceptance criteria at kickoff, requires fresh evidence with every progress update (R-CM-034 Rule 2).
 *   - handoff.md RETURN contract (teamwork-preview transplant Phase 2) → mandates structured handoffs
 *     containing Observation, Logic, Caveat, Conclusion, and Verification rather than conversational summaries.
 *     Not auto-created on worktree-init — presence signals "RETURN drafted" (R-CM-034 Rule 2).
 *   - Idempotent — preserves existing PLAN.md / handoff.md without overwriting in-progress documents.
 *
 * Pure helper module with unit tests in `tests/unit/worktree-plan-template.test.mjs`.
 */

import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import {
  resolveWorktreePlanPath,
  resolveWorktreeHandoffPath,
  inferBranchFromWorktreePath,
} from '../../../.cli/lib/worktree-plan-path.mjs';
import { renderTemplateFromSections } from '../../../.cli/lib/section-template-renderer.mjs';

/**
 * Default 9-section PLAN.md structure used by harness (JS constant — Option C, no live-path file I/O).
 * Customizable transplant version: data/registry/transplant-templates/worktree-plan.generic.json
 * (harness does not read this JSON directly — target projects customize and wire it).
 */
export const DEFAULT_PLAN_SECTIONS = [
  { heading: '# PLAN — {{branch}}', blocks: [] },
  {
    heading: '## Goal',
    blocks: [{ type: 'static', lines: ['(Required — Single sentence describing the objective achieved in this worktree)'] }],
  },
  {
    heading: '## Why',
    blocks: [{ type: 'static', lines: ['(Required — Why is this change necessary now? Existing gaps/issues)'] }],
  },
  {
    heading: '## Acceptance (Frozen at kickoff — record rationale in Decisions if modified)',
    blocks: [
      {
        type: 'static',
        lines: [
          '(Required — Verifiable acceptance criteria for this worktree to be considered "done". Pre-Ship verdict cross-checks this criteria. Using `- [ ]` checkboxes includes them in ship completion checks)',
        ],
      },
    ],
  },
  {
    heading: '## Scope (Surgical — R-CM-029 Rule 4)',
    blocks: [{ type: 'static', lines: ['(Required — Target files/modules to modify)'] }],
  },
  {
    heading: '## Out of scope',
    blocks: [{ type: 'static', lines: ['(Required — Areas explicitly left untouched)'] }],
  },
  {
    heading: '## Verify',
    blocks: [
      {
        type: 'checklist_group',
        subheading: '### Automated (Run within this turn)',
        items: [
          '(Required — Commands like `npm test` / `npx vitest run <paths>`)',
          '(Required — Automated checks like lint / audit / smoke tests)',
        ],
      },
      {
        type: 'checklist_group',
        subheading: '### Manual',
        items: [
          '(Remove section or mark (dropped) if inapplicable. For UI changes, note verification steps like "Check X in browser")',
        ],
      },
    ],
  },
  {
    heading: '## Status (append-only — accompanied by fresh evidence)',
    blocks: [
      {
        type: 'static',
        lines: [
          '- {{createdAt}}: Worktree initialized + PLAN drafted.',
          '<!-- Format: - YYYY-MM-DD done: <completed item> / evidence: <file:line · test output · commit sha> / next: <next action> / blocker: <if any> -->',
          '<!-- An "in progress" line without fresh evidence is not a progress report (heartbeat ≠ progress). Do not modify existing entries; append only. -->',
        ],
      },
    ],
  },
  { heading: '## Outstanding', blocks: [{ type: 'static', lines: ['- None (initial state)'] }] },
  {
    heading: '## Decisions',
    blocks: [{ type: 'static', lines: ['- (Required — Distinguish AI default decisions from explicit user decisions)'] }],
  },
];

/**
 * Renders standard PLAN.md template body. Pure — no fs access.
 *
 * @param {string} branch — Branch name like `feature/cmux-surface-select`.
 * @param {{ createdAt?: string, sections?: Array<object> }} [options] — Uses `DEFAULT_PLAN_SECTIONS`
 *   when `sections` is omitted.
 * @returns {string}
 */
export function renderPlanTemplate(branch, options = {}) {
  const branchName = branch || '<branch>';
  const createdAt = options.createdAt || new Date().toISOString().slice(0, 10);
  const sections = options.sections || DEFAULT_PLAN_SECTIONS;
  return renderTemplateFromSections(sections, { branch: branchName, createdAt }) + '\n';
}

/**
 * Ensures PLAN.md exists in worktree using standard template. Preserves existing files.
 *
 * Note on `options.branch` override: Overriding branch creates PLAN.md at
 * `resolveWorktreePlanPath(worktreePath, options.branch)`. This may differ from the
 * default path inferred via `inferBranchFromWorktreePath(worktreePath)`.
 *
 * @param {string} worktreePath — Worktree absolute path.
 * @param {{ branch?: string, createdAt?: string }} [options]
 * @returns {{ created: boolean, path: string }}
 */
export function ensureWorktreePlan(worktreePath, options = {}) {
  return ensureMailboxFile(worktreePath, options, resolveWorktreePlanPath, renderPlanTemplate);
}

/**
 * Common logic for idempotent mailbox file generation: infers branch → resolves path →
 * checks existing → mkdir + template write.
 */
function ensureMailboxFile(worktreePath, options, resolvePathFn, renderFn) {
  const branch = options.branch || inferBranchFromWorktreePath(worktreePath);
  const path = resolvePathFn(worktreePath, branch);
  if (existsSync(path)) {
    return { created: false, path };
  }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, renderFn(branch, { createdAt: options.createdAt }), 'utf-8');
  return { created: true, path };
}

/**
 * handoff.md 5-section RETURN contract (teamwork-preview transplant Phase 2).
 * Structured handoff separating Observation from Logic, allowing successor sessions
 * to independently re-verify conclusions.
 * Customizable transplant version: data/registry/transplant-templates/worktree-handoff.generic.json
 */
export const DEFAULT_HANDOFF_SECTIONS = [
  { heading: '# HANDOFF — {{branch}}', blocks: [] },
  {
    heading: '## Observation (Observed Facts)',
    blocks: [
      {
        type: 'static',
        lines: [
          '(Required — Verified facts only. Backed by file:line, command output, or commit sha evidence. Keep inferences separate in Logic section)',
        ],
      },
    ],
  },
  {
    heading: '## Logic (Inference)',
    blocks: [
      { type: 'static', lines: ['(Required — Rationale leading from observations to conclusions. Explicitly state uncertainties)'] },
    ],
  },
  {
    heading: '## Caveat (Cautions & Limitations)',
    blocks: [
      {
        type: 'static',
        lines: ['(Required — Unverified items, known risks, and potential pitfalls for successors)'],
      },
    ],
  },
  {
    heading: '## Conclusion (Verdict & Artifact Index)',
    blocks: [
      {
        type: 'static',
        lines: ['(Required — Final status in a single sentence + list of deliverable paths. Categorize remaining tasks as checkpoint / done / incomplete)'],
      },
    ],
  },
  {
    heading: '## Verification (Re-verification Method)',
    blocks: [
      {
        type: 'static',
        lines: ['(Required — Commands and procedures for successors to independently reproduce this conclusion)'],
      },
    ],
  },
];

/**
 * Renders handoff.md RETURN template body. Pure — no fs access.
 *
 * @param {string} branch — Branch name.
 * @param {{ createdAt?: string, sections?: Array<object> }} [options]
 * @returns {string}
 */
export function renderHandoffTemplate(branch, options = {}) {
  const branchName = branch || '<branch>';
  const createdAt = options.createdAt || new Date().toISOString().slice(0, 10);
  const sections = options.sections || DEFAULT_HANDOFF_SECTIONS;
  return renderTemplateFromSections(sections, { branch: branchName, createdAt }) + '\n';
}

/**
 * Ensures handoff.md exists in worktree mailbox using RETURN template. Preserves existing files.
 *
 * Unlike ensureWorktreePlan, this is not invoked by worktree-init chain. The file's presence
 * itself signals that a structured handoff has been drafted (R-CM-034 Rule 2).
 *
 * @param {string} worktreePath — Worktree absolute path.
 * @param {{ branch?: string, createdAt?: string }} [options]
 * @returns {{ created: boolean, path: string }}
 */
export function ensureWorktreeHandoff(worktreePath, options = {}) {
  return ensureMailboxFile(worktreePath, options, resolveWorktreeHandoffPath, renderHandoffTemplate);
}
