/**
 * hook-registry.mjs — Single SSOT Hook Registry (R-CM-006 Rule 4)
 *
 * This file is the **Single Source of Truth (Single SSOT)** for all Hook information in harness.
 * - settings.json#hooks is codegen'd from this registry (regen-hooks-settings.mjs)
 * - Profile membership is derived directly from the entry's `profile` field
 * - PROFILE_MAP in hook-flags.mjs is built from this registry
 *
 * - Transplant targets add project-only hooks in `.claude/config/hook-registry.local.json` (target-owned overlay,
 *   merged into HOOK_REGISTRY at load — see ./hook-registry-overlay.mjs); this file stays role=managed.
 *
 * Direct editing of settings.json is prohibited — blocked by settings-codegen-guard hook.
 * To change profiles, modify only the entry's `profile` field, then run `node .claude/scripts/regen-hooks-settings.mjs`.
 *
 * Hook entry fields:
 *   id                — hookId (argument to safeHookMainWithProfile)
 *   module            — `.mjs` path (../scripts/ or ./)
 *   priority          — Execution order (lower runs earlier)
 *   profile           — 'minimal' | 'standard' | 'none' (unprofiled; strict tier removed 2026-06-11 → 2-tier)
 *   profileChecked    — If false, uses safeHookMain (bypasses profile)
 *   orchestrated      — If true, runs in-process via hook-orchestrator
 *   description       — For AI context awareness
 *   timeout           — settings.json command timeout (seconds)
 *   if                — Bash conditional matcher (e.g., 'Bash(git *)')
 *   statusMessage     — User-facing status message
 *   async             — If true, runs asynchronously
 *   commandArgs       — Additional arguments for node module.mjs (e.g., 'SessionStart')
 *   type              — 'command' (default) or 'prompt'
 *   prompt            — LLM prompt body when type='prompt'
 *   hookType          — 'prompt' | 'agent' in PROMPT_AGENT_HOOKS
 *
 * @see .claude/rules/common/hooks.md (R-CM-006 Rule 4 — Single SSOT)
 * @see .claude/scripts/regen-hooks-settings.mjs (codegen)
 * @see .claude/hooks/settings-codegen-guard.mjs (blocks direct edits)
 */

import { fileURLToPath } from 'node:url';
import { loadMergedHookRegistry } from './hook-registry-overlay.mjs';

/** Valid hook event types (Claude Code platform event vocabulary — independent of registered hooks). */
export const VALID_EVENT_TYPES = new Set([
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionStart', 'SessionEnd',
  'PreCompact', 'UserPromptSubmit', 'SubagentStart', 'SubagentStop',
  'TaskCreated', 'TaskCompleted', 'PermissionRequest', 'FileChanged', 'Notification', 'ConfigChange',
  // WorktreeCreate/WorktreeRemove are valid events but currently have 0 registered hooks (agent-worktree-guard retired 2026-06-26).
  'WorktreeCreate', 'WorktreeRemove',
]);

/**
 * CLI adapter exclusive events — excluded from Claude `settings.json` codegen (skipped by regen-hooks-settings.mjs).
 *
 * PermissionRequest is wired exclusively for Codex approval stage dual defense. In Claude, PreToolUse `deny` is the
 * active path; wiring the same guard redundantly at the approval stage causes scope creep in Claude behavior + throws in
 * orchestrator 3-contract assertion (ORCHESTRATOR_DISPATCHERS). Skipping settings codegen entirely via this SSOT prevents both issues.
 * CLI codegen (cli-hooks-codegen.mjs) emits independently via cfg.eventOrder and remains unaffected
 * (only Codex includes PermissionRequest in eventOrder; Antigravity excludes it).
 */
export const CLI_ONLY_EVENTS = new Set(['PermissionRequest']);

/**
 * orchestrator dispatcher entries (1 matcher = 1 invocation in settings.json)
 *
 * Only (event, matcher) pairs with a dispatcher can have `orchestrated: true` —
 * `regen-hooks-settings.mjs#assertOrchestratedContract` (c) throws at codegen time otherwise.
 *
 * **Dispatcher expansion is not the sole telemetry path**: Orchestrated hooks record evaluation (denominator)
 * and firing (numerator) via the orchestrator, while hooks running directly as commands in settings.json without
 * dispatchers record via process gates (`safeHookMainWithProfile` / `output` in `.cli/lib/utils.mjs`) (R-CM-040 Rule 2).
 * Thus, hooks that **cannot structurally be orchestrated** (such as `if: Bash(git *)` conditionals, `mcp__*` prefix globs,
 * or events without dispatchers) are also observed. Previously, these remained permanently `unmeasured`, concealing
 * inoperational states in destructive-git-guard, commit-guard, and the former completion-evidence-guard for 24/78 days (#1088 / #1086 empirical).
 * Gate bypass prevention: `tests/unit/hook-telemetry-coverage.test.mjs`.
 *
 * Timeout is set to approximately 2x the sum of individual timeouts for orchestrated hooks in that group. Because the
 * orchestrator runs sync hooks **sequentially**, a single dispatcher represents the budget for the whole group —
 * treating it like individual hook timeouts silently cuts off the final hook.
 *
 * **Caution on glob matchers**: `matchesTool` supports only standalone `*` and `|` separation, not prefix globs like `mcp__*`.
 * Running such matchers as orchestrated causes zero hooks to match during dispatch, resulting in **permanent non-execution**
 * (`PostToolUseFailure / "mcp__*"` remains standalone for this reason).
 */
export const ORCHESTRATOR_DISPATCHERS = [
  {
    "event": "Stop",
    "matcher": "",
    "timeout": 60
  },
  {
    "event": "PreToolUse",
    "matcher": "Edit|Write",
    "timeout": 15
  },
  {
    "event": "PreToolUse",
    "matcher": "Bash",
    "timeout": 45
  },
  {
    "event": "PreToolUse",
    "matcher": "Task",
    "timeout": 15
  },
  {
    "event": "PreToolUse",
    "matcher": "Skill",
    "timeout": 40
  },
  {
    "event": "PostToolUse",
    "matcher": "Write|Edit",
    "timeout": 45
  },
  {
    "event": "PostToolUse",
    "matcher": "Edit",
    "timeout": 15
  },
  {
    "event": "PostToolUse",
    "matcher": "Read",
    "timeout": 15
  },
  {
    "event": "PostToolUse",
    "matcher": "Bash",
    "timeout": 45
  },
  {
    "event": "SubagentStart",
    "matcher": "",
    "timeout": 15
  },
  {
    "event": "SubagentStop",
    "matcher": "",
    "timeout": 40
  },
  {
    "event": "SessionStart",
    "matcher": "",
    "timeout": 60
  },
  {
    "event": "UserPromptSubmit",
    "matcher": "",
    "timeout": 20
  }
];

/** prompt/agent type hooks (PROMPT_AGENT_HOOKS) */
export const PROMPT_AGENT_HOOKS = {
  // The former prompt-type completion-evidence-guard entry lacked a `prompt` body field and was permanently skipped
  // during settings.json entry in codegen (`if (!ph.prompt) continue;` in regen-hooks-settings.mjs#appendPromptHooks) —
  // a dead remnant of prompt→command migration (#109). The command-type guard was retired in the
  // contract-reconciliation-harness ADR (ship gate `mark-pre-ship-confirmed.mjs#checkAcceptance` replaces it).
  "Stop": [],
  "PreToolUse": [],
  "TaskCompleted": [],
  // SubagentStop does not register prompt-type hooks (enforced by codegen guard in regen-hooks-settings.mjs).
  // Rationale: Prompt-type SubagentStop injects verification instructions into subagent context, causing subagents
  // to overwrite actual deliverables (e.g., review findings from code-reviewer) with responses to those instructions ({"decision":"allow"}).
  // Stage closure verification is covered by prompt-level audits (stage skills) + handoff-consistency-guard (PostToolUse),
  // making allow-biased prompt hooks redundant and polluting. SubagentStop verification must be written as command-type hooks only (R-CM-006 Rule 1).
  "SubagentStop": []
};

/**
 * Managed registry (shipped by transplant-bundle as role=managed). Consumers read HOOK_REGISTRY below — this
 * literal merged with the project-local overlay. Only transplant shipping reads the managed literal directly.
 */
export const MANAGED_HOOK_REGISTRY = {
  "PreToolUse": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "pre-tool-enforcer",
          "module": "../scripts/pre-tool-enforcer.mjs",
          "priority": 10,
          "profile": "minimal",
          "description": "Pipeline context injection + validation before skill execution",
          "orchestrated": false,
          "timeout": 5
        }
      ]
    },
    {
      "matcher": "Edit|Write",
      "hooks": [
        {
          "id": "settings-codegen-guard",
          "module": "./settings-codegen-guard.mjs",
          "priority": 6,
          "profile": "minimal",
          "description": "[R-CM-006 Rule 4] Block direct editing of settings.json#hooks (Single SSOT)",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "phase-boundary-file-guard",
          "module": "./phase-boundary-file-guard.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Validate requiredInputs when writing pipeline artifacts (3-Layer L1). 2026-07-11 Tier C expansion — applies L1 gate to pipeline artifact editing in Codex/Antigravity sessions",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "secret-leak-guard",
          "module": ".cli/hooks/secret-leak-guard.mjs",
          "priority": 5,
          "profile": "minimal",
          "description": "Detect hardcoded API keys/secrets + DENY",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "worktree-policy-guard",
          "module": ".cli/hooks/worktree-policy-guard.mjs",
          "priority": 8,
          "profile": "minimal",
          "description": "Enforce direct main work Tier policy (Tier 1/2/3 + hotfix/* escape hatch). SSOT: .claude/config/worktree-policy.json",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "worktree-session-owner-guard",
          "module": ".cli/hooks/worktree-session-owner-guard.mjs",
          "priority": 9,
          "profile": "standard",
          "description": "[R-CM-036] Block multi-session cross-worktree edits (Layer 1 cwd-confinement + Layer 2 session_id sidecar). Targets Edit|Write|MultiEdit",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "coverage-threshold-guard",
          "module": ".cli/hooks/coverage-threshold-guard.mjs",
          "priority": 40,
          "profile": "standard",
          "description": "Protect the verification loop (Playbook Stage 4): coverage threshold ratchet (up-only) + DENY edits to locked regression tests (lock = tests added by fix/hotfix branch commits ∪ manual ledger − recorded releases; ledger itself is CLI-only) — .cli/lib/test-lock.mjs",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "health-ratchet-guard",
          "module": "./health-ratchet-guard.mjs",
          "priority": 41,
          "profile": "standard",
          "description": "Detect and warn on score degradation when directly modifying Code Health 7-axis baseline (data/registry/code-health-ratchet-baseline.json) (conforms to R-CM-016 Rule 10)",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        }
      ]
    },
    {
      "matcher": "Bash",
      "hooks": [
        {
          "id": "merge-guard",
          "module": ".cli/hooks/merge-guard.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Prevent git merge conflicts",
          "orchestrated": false,
          "timeout": 30,
          "if": "Bash(git *)",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "destructive-git-guard",
          "module": ".cli/hooks/destructive-git-guard.mjs",
          "priority": 5,
          "profile": "minimal",
          "description": "Block destructive git commands such as reset --hard and force push",
          "orchestrated": false,
          "timeout": 30,
          "if": "Bash(git *)",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "commit-guard",
          "module": ".cli/hooks/commit-guard.mjs",
          "priority": 20,
          "profile": "standard",
          "description": "Trunk-commit / amend / branch-creation guard + [R-CM-002 Rule 10] DENY a git commit that modifies, deletes or renames a locked regression test (closes the shell-edit bypass of the edit-time guard)",
          "orchestrated": false,
          "timeout": 30,
          "if": "Bash(git *)",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "worktree-policy-guard",
          "module": ".cli/hooks/worktree-policy-guard.mjs",
          "priority": 8,
          "profile": "minimal",
          "description": "[opt-in] Trunk Bash allowlist — on trunk, deny Bash commands not listed in worktree-policy.json#trunk_bash_allowlist. Default off: returns after one JSON read. Registered on every Bash (no `if`) because the allowlist must see non-git commands; orchestrated so Claude pays no extra process",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "worktree-session-owner-guard",
          "module": ".cli/hooks/worktree-session-owner-guard.mjs",
          "priority": 25,
          "profile": "standard",
          "description": "[R-CM-036] Block multi-session cross-worktree git commit (Layer 1 cwd-confinement + Layer 2 lease). Opt-in worktree-policy.json#session_owner_scope=\"all_bash\" widens it to every Bash command, so it is registered without `if: Bash(git *)` and orchestrated (in-process) — the default scope still passes non-commit commands through",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "dev-server-guard",
          "module": "./dev-server-guard.mjs",
          "priority": 30,
          "profile": "standard",
          "description": "Recommend using tmux session when running dev server",
          "orchestrated": true,
          "timeout": 30,
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "git-push-warning",
          "module": ".cli/hooks/git-push-warning.mjs",
          "priority": 35,
          "profile": "standard",
          "description": "Change review notification before git push",
          "orchestrated": false,
          "timeout": 30,
          "if": "Bash(git push*)",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "guardrail-guard",
          "module": ".cli/hooks/guardrail-guard.mjs",
          "priority": 40,
          "profile": "standard",
          "description": "Bash tool risk level classification + block high-risk tools during pipeline execution",
          "orchestrated": false,
          "timeout": 30,
          "statusMessage": "Guardrail: checking tool risk level",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "pre-ship-review-guard",
          "module": ".cli/hooks/pre-ship-review-guard.mjs",
          "priority": 50,
          "profile": "minimal",
          "description": "(settings-only — generated during R-CM-006 single SSOT migration)",
          "orchestrated": true,
          "timeout": 30,
          "cliTargets": ["codex", "antigravity"]
        }
      ]
    },
    {
      "matcher": "Task",
      "hooks": [
        {
          "id": "model-routing-guard",
          "module": "./model-routing-guard.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Validate model suitability + cost optimization on Task execution",
          "orchestrated": false,
          "timeout": 5
        },
        {
          "id": "agent-review-readiness-guard",
          "module": "./agent-review-readiness-guard.mjs",
          "priority": 20,
          "profile": "standard",
          "description": "Block uncommitted + zero commits when invoking review/code-simplifier agent (prevent wrong-scope review). Single entry point via /code-review following /simplify removal and simplifit skill deprecation on 2026-05-27", // retired-ref-ok: simplifit deprecation documents hook context — not an invocation instruction
          "orchestrated": true,
          "timeout": 5
        }
      ]
    },
    {
      "matcher": "Skill",
      "hooks": [
        {
          "id": "new-run-guard",
          "module": "./new-run-guard.mjs",
          "priority": 2,
          "profile": "standard",
          "description": "Automatically block boundary right before starting new business idea (entering business-analyzer) (R-CM-014/028)",
          "orchestrated": false,
          "timeout": 5
        },
        {
          "id": "pipeline-boundary-guard",
          "module": "./pipeline-boundary-guard.mjs",
          "priority": 5,
          "profile": "minimal",
          "description": "Block execution of dev skills in harness repo + inject Saga State",
          "orchestrated": true,
          "timeout": 5
        },
        {
          "id": "constraint-injector",
          "module": "./constraint-injector.mjs",
          "priority": 35,
          "profile": "standard",
          "description": "Inject previous stage constraints (Rule 6-9)",
          "orchestrated": true,
          "timeout": 10,
          "statusMessage": "Constraint Injector: injecting previous stage constraints (Rule 6-9)"
        },
        {
          "id": "inbox-guard-skill",
          "module": "./inbox-guard.mjs",
          "priority": 3,
          "profile": "standard",
          "description": "Detect unprocessed inbox items before Skill execution",
          "orchestrated": true,
          "timeout": 5,
          "commandArgs": "PreToolUse"
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit",
      "hooks": [
        {
          "id": "edit-error-recovery",
          "module": "./edit-error-recovery.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Automatic recovery guidance on Edit failure",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "MultiEdit"]
        }
      ]
    },
    {
      "matcher": "WebSearch",
      "hooks": [
        {
          "id": "websearch-evidence-extractor",
          "module": "./websearch-evidence-extractor.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "[R-CM-035] Persist WebSearch results as markdown + meta JSON in runs/{active}/research/web-search/ (Observatory decision evidence)",
          "orchestrated": false,
          "timeout": 5
        }
      ]
    },
    {
      "matcher": "Read",
      "hooks": [
        {
          "id": "wisdom-ref-tracker",
          "module": "./wisdom-ref-tracker.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Track Wisdom file references (updates last_referenced — input to session-extractor confidence scoring)",
          "orchestrated": false,
          "timeout": 3
        },
        {
          "id": "prompt-injection-guard",
          "module": "./prompt-injection-guard.mjs",
          "priority": 20,
          "profile": "standard",
          "description": "[ECC] Detect prompt injection patterns in read file contents. Standalone: direct settings.json invocation",
          "orchestrated": true,
          "timeout": 5
        }
      ]
    },
    {
      "matcher": "Write|Edit",
      "hooks": [
        {
          "id": "pipeline-change-tracker",
          "module": "./pipeline-change-tracker.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Track pipeline artifact changes + Schema validation + Saga updates (3-Layer L2). 2026-07-11 Tier C expansion. No-op in Antigravity PostToolUse due to missing toolCall — operates in Codex only (MULTI-CLI.md PostToolUse limitation section)",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "esp-consistency-guard",
          "module": "./esp-consistency-guard.mjs",
          "priority": 30,
          "profile": "standard",
          "description": "Validate ESP (Enforced Skill Pattern) consistency",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "handoff-consistency-guard",
          "module": "./handoff-consistency-guard.mjs",
          "priority": 40,
          "profile": "standard",
          "description": "Validate Confidence Ratchet + Handoff structure (3-Layer L2). 2026-07-11 Tier C expansion. No-op in Antigravity PostToolUse due to missing toolCall — operates in Codex only (MULTI-CLI.md PostToolUse limitation section)",
          "orchestrated": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "docs-consistency-guard",
          "module": "./docs-consistency-guard.mjs",
          "priority": 45,
          "profile": "standard",
          "description": "Detect Input→Output Staleness (3-Layer L2). 2026-07-11 Tier C expansion (async is Claude-exclusive — CLI registrations emit {type,command,timeout} only). No-op in Antigravity PostToolUse due to missing toolCall — operates in Codex only (MULTI-CLI.md PostToolUse limitation section)",
          "orchestrated": true,
          "async": true,
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "skill-structure-check",
          "module": "./skill-structure-check.mjs",
          "priority": 90,
          "profile": "standard",
          "description": "[R-CM-018] Validate SKILL.md structural validity",
          "orchestrated": true,
          "timeout": 5,
          "statusMessage": "R-CM-018: validating SKILL.md structure",
          "cliTargets": ["codex", "antigravity"],
          "cliMatcherTools": ["Edit", "Write", "MultiEdit"]
        },
        {
          "id": "scaffold-artifact-schema-warning",
          "module": "./scaffold-artifact-schema-warning.mjs",
          "priority": 92,
          "profile": "standard",
          "description": "Notify on scaffold artifact (project-brief/config) schema drift",
          "orchestrated": false,
          "timeout": 5,
          "statusMessage": "P13: scaffold artifact schema check"
        },
        {
          "id": "scaffold-validation-warning",
          "module": "./scaffold-validation-warning.mjs",
          "priority": 93,
          "profile": "standard",
          "description": "Notify on output scaffold validation report staleness",
          "orchestrated": false,
          "timeout": 5,
          "statusMessage": "P20: scaffold validation staleness check"
        },
        {
          "id": "milestone-deck-warning-edit",
          "module": ".cli/hooks/milestone-deck-warning.mjs",
          "priority": 95,
          "profile": "standard",
          "description": "[R-CM-030 Rule 12 / DEBT-248] Remind CP-MILESTONE the moment cumulative session edits reach large threshold (advisory additionalContext, non-blocking). Shares module + one-shot marker with commit-time entry (milestone-deck-warning) — in single session straight-through implementations, commit happens only once at the very end, making commit-time trigger too late (#1050·#1054·#1056·#1057 4 consecutive empirical measurements)",
          "orchestrated": true,
          "timeout": 10,
          "statusMessage": "Milestone Deck: accumulating edit scale toward large threshold (R-CM-030 Rule 12)"
        }
      ]
    },
    {
      "matcher": "Bash",
      "hooks": [
        {
          "id": "worktree-owner-tracker",
          "module": ".cli/hooks/worktree-owner-tracker.mjs",
          "priority": 90,
          "profile": "standard",
          "description": "[R-CM-036] Record session ownership sidecar (.session-owner) upon successful worktree creation + [R-CM-002 Rule 10] announce which test files a successful fix/* or hotfix/* commit just locked (git history is the lock; context only — safeHookMain, profile-independent, never BLOCKs)",
          "orchestrated": true,
          "timeout": 5,
          "profileChecked": false,
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "bash-file-integrity-guard",
          "module": ".cli/hooks/bash-file-integrity-guard.mjs",
          "priority": 70,
          "profile": "standard",
          "description": "Detect 0-byte file corruption after sed -i / awk -i inplace",
          "orchestrated": true,
          "timeout": 5,
          "statusMessage": "Bash File Integrity: detecting 0-byte corruption from sed -i / awk -i inplace (R-CM-019)",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "milestone-deck-warning",
          "module": ".cli/hooks/milestone-deck-warning.mjs",
          "priority": 60,
          "profile": "standard",
          "description": "[R-CM-030 Rule 12] Measure diff scale immediately after worktree git commit — remind once if large threshold is reached and CP-MILESTONE deck evidence is 0 (advisory additionalContext, non-blocking. Proactive complement to ship-time retroactive warning DEBT-223)",
          "orchestrated": true,
          "timeout": 10,
          "statusMessage": "Milestone Deck: checking large-scale threshold after worktree commit (R-CM-030 Rule 12)"
        }
      ]
    }
  ],
  "PostToolUseFailure": [
    {
      "matcher": "mcp__*",
      "hooks": [
        {
          "id": "mcp-failure-tracker",
          "module": "./mcp-failure-tracker.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Update health status with explicit failure info on MCP tool failure. Standalone: direct settings.json invocation",
          "orchestrated": false,
          "timeout": 5
        }
      ]
    }
  ],
  "Stop": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "quality-gate-stop-guard",
          "module": "./quality-gate-stop-guard.mjs",
          "priority": 5,
          "profile": "standard",
          "description": "Enforce passing quality gate (make q.check)",
          "orchestrated": true,
          "cliTargets": ["codex"],
          "cliTimeout": 10
        },
        {
          "id": "stop-handler",
          "module": "../scripts/stop-handler.mjs",
          "priority": 10,
          "profile": "none",
          "description": "Extract ECC instincts (pipeline stage learnings)",
          "orchestrated": true,
          "profileChecked": false
        },
        {
          "id": "analyze-guard",
          "module": "../scripts/analyze-guard.mjs",
          "priority": 20,
          "profile": "none",
          "description": "Summarize analysis results + context injection",
          "orchestrated": true,
          "profileChecked": false
        },
        {
          "id": "pipeline-drift-guard",
          "module": "./pipeline-drift-guard.mjs",
          "priority": 30,
          "profile": "standard",
          "description": "Drift + structure + content + schema conformance + Saga consistency validation (L3). Antigravity dropped from cliTargets 2026-09-23 (defect 5) — Antigravity has no Stop message channel, yet running this hook still touched shared 5-min attempt markers and suppressed Claude's own Stop notices",
          "orchestrated": true,
          "cliTargets": ["codex"],
          "cliTimeout": 15
        },
        {
          "id": "worktree-shipping-guard",
          "module": ".cli/hooks/worktree-shipping-guard.mjs",
          "priority": 35,
          "profile": "standard",
          "description": "[R-CM-030] Automatically guide /create-pr ship-worktree on worktree commit + unmerged (5-minute attempt marker)",
          "orchestrated": true,
          "cliTargets": ["codex"],
          "cliTimeout": 10
        },
        {
          "id": "ecosystem-health-guard",
          "module": "./ecosystem-health-guard.mjs",
          "priority": 50,
          "profile": "standard",
          "description": "Validate .claude/ ecosystem internal consistency",
          "orchestrated": true
        },
        {
          "id": "inbox-guard-stop",
          "module": "./inbox-guard.mjs",
          "priority": 5,
          "profile": "standard",
          "description": "Detect unprocessed inbox items on Stop",
          "orchestrated": true,
          "timeout": 5,
          "commandArgs": "Stop"
        },
        {
          "id": "docs-index-guard",
          "module": "./docs-index-guard.mjs",
          "priority": 55,
          "profile": "standard",
          "description": "Block stale docs/index.md automatic index (AUTO marker) on docs/ changes + guide update (main + owned worktree)",
          "orchestrated": false,
          "timeout": 15,
          "statusMessage": "docs-index-guard: checking docs/index.md AUTO section freshness",
          "cliTargets": ["codex"],
          "cliTimeout": 15
        }
      ]
    }
  ],
  "SessionStart": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "trunk-start-warning",
          "module": ".cli/hooks/trunk-start-warning.mjs",
          "priority": 5,
          "profile": "minimal",
          "description": "Inject worktree guidance as context when entering AI session on main branch (conforms to R-CM-006 Rule 1 — SessionStart cannot block). Registered under PreInvocation (invocationNum===0, DEBT-212 pilot) for Antigravity — codegen eventNameMap + adapter gating, additionalContext → injectSteps.ephemeralMessage",
          "orchestrated": true,
          "timeout": 10,
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "inflight-awareness-injector",
          "module": ".cli/hooks/inflight-awareness-injector.mjs",
          "priority": 6,
          "profile": "standard",
          "description": "Inject a capped read-only summary of other in-flight worktrees (branch, HEAD age, dirty count, PLAN open boxes) at session start — proactive duplicate-work awareness complementing ship-time superset detection (R-CM-008 Rule 9). Silent when no other worktrees. SSOT: .cli/lib/inflight-awareness-core.mjs",
          "orchestrated": true,
          "timeout": 10
        },
        {
          "id": "ownership-context-injector",
          "module": ".cli/hooks/ownership-context-injector.mjs",
          "priority": 7,
          "profile": "standard",
          "description": "Antigravity-exclusive SessionStart (→PreInvocation invocationNum===0) one-time static guidance — injects manual ownership query procedure since per-prompt routing is structurally impossible due to lack of UserPromptSubmit (DEBT-219). Claude/Codex path passes through due to absence of prompt (for Claude, UserPromptSubmit registration is the effective path)",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["antigravity"]
        },
        {
          "id": "session-start",
          "module": "../scripts/session-start.mjs",
          "priority": 10,
          "profile": "none",
          "description": "Load previous session context + detect pipeline state (fallback registered under PreInvocation invocationNum===0 for Antigravity — DEBT-219 expansion 2026-07-12)",
          "orchestrated": true,
          "profileChecked": false,
          "timeout": 10,
          "cliTargets": ["codex", "antigravity"],
          "cliTimeout": 10
        },
        {
          "id": "pipeline-memory-injector",
          "module": "./pipeline-memory-injector.mjs",
          "priority": 30,
          "profile": "standard",
          "description": "Inject pipeline memory on session start (fallback registered under PreInvocation invocationNum===0 for Antigravity — DEBT-219 expansion 2026-07-12)",
          "orchestrated": true,
          "timeout": 10,
          "statusMessage": "Pipeline Memory: injecting session context",
          "cliTargets": ["codex", "antigravity"],
          "cliTimeout": 10
        },
        {
          "id": "learnings-injector",
          "module": "./learnings-injector.mjs",
          "priority": 32,
          "profile": "standard",
          "description": "Inject top learnings from learnings.jsonl on session start (stage relevance + confidence floor filters, TOP_K=10 bounded). Reintroduced after producer repair in #1093 following removal on empty data in #1037 (R-CM-020 Rule 6). 3-CLI restoration per MULTI-CLI.md contract (PreInvocation invocationNum===0 for Antigravity)",
          "orchestrated": true,
          "timeout": 10,
          "statusMessage": "Learnings: injecting episodic knowledge",
          "cliTargets": ["codex", "antigravity"],
          "cliTimeout": 10
        },
        {
          "id": "inbox-guard",
          "module": "./inbox-guard.mjs",
          "priority": 35,
          "profile": "standard",
          "description": "Detect unprocessed inbox items + notification",
          "orchestrated": true,
          "timeout": 5,
          "commandArgs": "SessionStart"
        },
        {
          "id": "session-integrity-check",
          "module": "./session-integrity-check.mjs",
          "priority": 40,
          "profile": "standard",
          "description": "Validate cross-file ecosystem consistency (fallback registered under PreInvocation invocationNum===0 for Antigravity — DEBT-219 expansion 2026-07-12)",
          "orchestrated": false,
          "timeout": 10,
          "statusMessage": "Ecosystem Integrity: validating cross-file consistency",
          "cliTargets": ["codex", "antigravity"],
          "cliTimeout": 10
        },
        {
          "id": "worktree-system-symlink-guard",
          "module": "./worktree-system-symlink-guard.mjs",
          "priority": 42,
          "profile": "minimal",
          "description": "[R-CM-030] Detect whether worktree's .harness/system/ is a main worktree symlink. No auto-creation (Consequential). Fail-open. (Fallback registered under PreInvocation invocationNum===0 for Antigravity — DEBT-219 expansion 2026-07-12)",
          "orchestrated": true,
          "timeout": 5,
          "statusMessage": "R-CM-030: checking system_persistent worktree symlink",
          "cliTargets": ["codex", "antigravity"]
        },
        {
          "id": "compact-context-preserver",
          "module": "./compact-context-preserver.mjs",
          "priority": 50,
          "profile": "standard",
          "description": "Re-inject core context upon first session start immediately after compact (source===\"compact\" only). Codex SessionStart (source=compact) expansion — codegen sessionStartMatcher covers compact, re-injected via additionalContext (codex-only)",
          "orchestrated": true,
          "timeout": 15,
          "statusMessage": "Compact Context: re-injecting preserved context after compaction",
          "cliTargets": ["codex"]
        }
      ]
    }
  ],
  "SessionEnd": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "session-end",
          "module": "../scripts/session-end.mjs",
          "priority": 30,
          "profile": "none",
          "description": "Session cleanup",
          "orchestrated": false,
          "profileChecked": false,
          "timeout": 5
        },
        {
          "id": "session-extractor",
          "module": "./session-extractor.mjs",
          "priority": 50,
          "profile": "standard",
          "description": "Session pattern analysis + wisdom confidence update + instinct promotion",
          "orchestrated": false,
          "async": true,
          "timeout": 15
        },
        {
          "id": "pipeline-memory-extractor",
          "module": "./pipeline-memory-extractor.mjs",
          "priority": 60,
          "profile": "standard",
          "description": "Extract pipeline facts on session termination",
          "orchestrated": false,
          "timeout": 10,
          "statusMessage": "Pipeline Memory: extracting session facts"
        },
        {
          "id": "transcript-extractor",
          "module": "./transcript-extractor.mjs",
          "priority": 70,
          "profile": "standard",
          "description": "Copy Claude Code transcript_path jsonl to active run's transcript/ (input to Observatory chat view)",
          "orchestrated": false,
          "async": true,
          "timeout": 5
        }
      ]
    }
  ],
  "UserPromptSubmit": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "context-alert-guard",
          "module": ".cli/hooks/context-alert-guard.mjs",
          "priority": 12,
          "profile": "standard",
          "description": "Read session-scoped context usage state persisted by statusline and, on 60%/70% tier crossing, inject an AI hint to recommend wrap-up//handoff to the user before auto-compact (~83%) — recommendation only, autonomous handoff stays prohibited (R-CM-016 Rule 10). SSOT: .cli/lib/context-alert-state.mjs",
          "orchestrated": true,
          "timeout": 5
        },
        {
          "id": "ownership-context-injector",
          "module": ".cli/hooks/ownership-context-injector.mjs",
          "priority": 15,
          "profile": "standard",
          "description": "Inject derived code ownership candidates on UserPromptSubmit to reduce NEW/MODIFY routing drift",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex"]
        },
        {
          "id": "task-context-injector",
          "module": "./task-context-injector.mjs",
          "priority": 20,
          "profile": "standard",
          "description": "Inject latest task/SSOT/verification contracts into task-oriented prompts to reduce AI context drift (codex-only CLI expansion — UserPromptSubmit is not an official Antigravity event)",
          "orchestrated": true,
          "timeout": 5,
          "cliTargets": ["codex"]
        }
      ]
    }
  ],
  "SubagentStart": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "subagent-limit-guard",
          "module": "./subagent-limit-guard.mjs",
          "priority": 10,
          "profile": "standard",
          "description": "Limit concurrent subagent count (MAX=5). Codex SubagentStart expansion — official event in subagent-start scope per manual (codex-only, Antigravity lacks subagent events)",
          "orchestrated": true,
          "timeout": 5,
          "statusMessage": "Subagent Limit: tracking concurrency",
          "cliTargets": ["codex"]
        }
      ]
    }
  ],
  "SubagentStop": [
    {
      "matcher": "*",
      "hooks": [
        {
          "id": "subagent-cleanup",
          "module": "./subagent-cleanup.mjs",
          "priority": 5,
          "profile": "standard",
          "description": "Remove from active agent list upon subagent completion. Codex SubagentStop expansion — pair of subagent-limit-guard (codex-only, Antigravity lacks subagent events)",
          "orchestrated": true,
          "timeout": 5,
          "statusMessage": "Subagent Cleanup: removing from active agents",
          "cliTargets": ["codex"]
        },
        {
          "id": "stop-handler",
          "module": "../scripts/stop-handler.mjs",
          "priority": 10,
          "profile": "none",
          "description": "Extract ECC instincts (subagent completion)",
          "orchestrated": true,
          "profileChecked": false,
          "timeout": 15
        }
      ]
    }
  ],
  "PermissionRequest": [
    {
      "matcher": "Bash",
      "hooks": [
        {
          "id": "destructive-git-guard",
          "module": ".cli/hooks/destructive-git-guard.mjs",
          "priority": 5,
          "description": "[PermissionRequest dual-defense] Block approval of destructive git commands like reset --hard / force push (reinforces escalations missed by Codex PreToolUse)",
          "cliTargets": ["codex"]
        },
        {
          "id": "merge-guard",
          "module": ".cli/hooks/merge-guard.mjs",
          "priority": 10,
          "description": "[PermissionRequest dual-defense] Block approval of Git merge conflicts",
          "cliTargets": ["codex"]
        },
        {
          "id": "commit-guard",
          "module": ".cli/hooks/commit-guard.mjs",
          "priority": 20,
          "description": "[PermissionRequest dual-defense] Approval stage validation of Conventional Commits format",
          "cliTargets": ["codex"]
        },
        {
          "id": "guardrail-guard",
          "module": ".cli/hooks/guardrail-guard.mjs",
          "priority": 40,
          "description": "[PermissionRequest dual-defense] Block approval of system destructive commands like rm -rf / mkfs",
          "cliTargets": ["codex"]
        }
      ]
    },
    {
      "matcher": "Edit|Write",
      "hooks": [
        {
          "id": "secret-leak-guard",
          "module": ".cli/hooks/secret-leak-guard.mjs",
          "priority": 5,
          "description": "[PermissionRequest dual-defense] Block approval of file edits containing hardcoded secrets",
          "cliTargets": ["codex"]
        },
        {
          "id": "worktree-policy-guard",
          "module": ".cli/hooks/worktree-policy-guard.mjs",
          "priority": 8,
          "description": "[PermissionRequest dual-defense] Block approval under Tier policy for direct main edits",
          "cliTargets": ["codex"]
        }
      ]
    }
  ]
};

/**
 * Single SSOT view — managed registry + `.claude/config/hook-registry.local.json` (project-local overlay,
 * target-owned, never shipped). settings.json#hooks is codegen'd from this merged view, and every runtime
 * consumer reads it, so local entries stay wired. Broken overlay → warning + managed only (never throws).
 * @see ./hook-registry-overlay.mjs (format, merge + safety policy)
 */
const OVERLAY = loadMergedHookRegistry(MANAGED_HOOK_REGISTRY, fileURLToPath(new URL('../../', import.meta.url)), {
  validEvents: VALID_EVENT_TYPES,
});
export const HOOK_REGISTRY = OVERLAY.registry;
export const HOOK_REGISTRY_OVERLAY_STATUS = Object.freeze({
  path: OVERLAY.path,
  present: OVERLAY.present,
  added: OVERLAY.added,
  overridden: OVERLAY.overridden,
  warnings: OVERLAY.warnings,
});
// Not printed here (that would repeat on every hook process): regen-hooks-settings and the transplant report
// print formatOverlaySummary(HOOK_REGISTRY_OVERLAY_STATUS) where a human reads it.

// ═══════════════════════════════════════════════════════════════
// Helpers (registry-derived)
// ═══════════════════════════════════════════════════════════════

export function matchesTool(matcher, toolName) {
  if (matcher === '*' || matcher === '') return true;
  return matcher.split('|').some((m) => m.trim() === toolName);
}

export function getHooksForEvent(event, toolName) {
  const groups = HOOK_REGISTRY[event] || [];
  const matched = [];
  for (const g of groups) {
    if (matchesTool(g.matcher, toolName)) matched.push(...g.hooks);
  }
  return matched.sort((a, b) => (a.priority || 50) - (b.priority || 50));
}

/** Flattened list of all entries (without deduplicating id — preserves multi-registrations like inbox-guard) */
export function flattenRegistry() {
  const out = [];
  for (const [event, groups] of Object.entries(HOOK_REGISTRY)) {
    for (const g of groups) {
      for (const h of g.hooks) out.push({ event, matcher: g.matcher, ...h });
    }
  }
  for (const [event, list] of Object.entries(PROMPT_AGENT_HOOKS)) {
    for (const h of list) out.push({ event, matcher: '', ...h });
  }
  return out;
}

/**
 * Set of hooks/ directory module filenames registered in HOOK_REGISTRY (`./xxx.mjs` → `xxx.mjs`).
 *
 * SSOT query for "is this hook file registered in the registry (= not a dead hook)". Since settings.json is
 * codegen'd from this registry (R-CM-006 Rule 4), registration in registry = active hook (regardless of orchestrated
 * status — orchestrated hooks dispatch via orchestrator, remainder execute directly via settings.json commands).
 *
 * Shared by ecosystem-health-guard E1 + ecosystem-integrity-validator EI3 — previously, E1 parsed hook-registry.mjs
 * source text via regex to recognize `orchestrated:true` only, while EI3 programmatically recognized all `./` modules,
 * leading to divergence. Unified via this helper to eliminate drift. `../scripts/` modules excluded as they are outside hooks/ scope.
 * Returns basename set — collects basenames for both `./X.mjs` (.claude/hooks/) and `.cli/hooks/X.mjs` (after multi-CLI guard migration).
 */
export function collectRegistryHookFiles() {
  const set = new Set();
  for (const groups of Object.values(HOOK_REGISTRY)) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        const mod = hook.module || '';
        if (mod.startsWith('./')) set.add(mod.slice(2));
        else if (mod.startsWith('.cli/')) set.add(mod.split('/').pop());
      }
    }
  }
  return set;
}

export function getRegistryStats() {
  const flat = flattenRegistry();
  return {
    total: flat.length,
    byProfile: {
      minimal: flat.filter((h) => h.profile === 'minimal').length,
      standard: flat.filter((h) => h.profile === 'standard').length,
      none: flat.filter((h) => h.profile === 'none' || h.profileChecked === false).length,
    },
    orchestrated: flat.filter((h) => h.orchestrated).length,
    standalone: flat.filter((h) => h.orchestrated === false).length,
  };
}
