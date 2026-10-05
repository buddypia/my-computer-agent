/**
 * hook-output.mjs — Standardized Hook Output Library
 *
 * Output helpers adhering to the official Claude Code Hooks API specification.
 * Generates appropriate JSON structures for each Hook Event Type.
 *
 * API Specification References:
 * - PreToolUse: hookSpecificOutput.permissionDecision ("deny"/"allow"/"ask")
 * - PostToolUse: Top-level decision ("block") or hookSpecificOutput.additionalContext
 * - Stop/SubagentStop: Top-level decision ("block") + reason, or systemMessage (advisory)
 * - UserPromptSubmit: Top-level decision ("block") + reason
 *
 * Usage:
 *   import { output } from './utils.mjs';
 *   import { HookOutput } from './hook-output.mjs';
 *   return output(HookOutput.deny('reason'));
 */

// ═══════════════════════════════════════════════════════════════
// PreToolUse Output (permissionDecision based)
// ═══════════════════════════════════════════════════════════════

/**
 * PreToolUse: Denies tool invocation.
 * Reason is passed to Claude as feedback.
 *
 * @param {string} reason - Denial reason (read and acted upon by Claude)
 * @returns {object} Hook output JSON
 */
export function deny(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  };
}

/**
 * PreToolUse: Allows tool invocation but displays a warning message.
 * Reason is displayed only to user (unexposed to Claude). (Note: from Claude 0.2.x, permissionDecisionReason may be passed to Claude)
 *
 * @param {string} reason - Warning message (read by user)
 * @param {string} [contextBlock] - Optional additional context. Merged into reason.
 * @returns {object} Hook output JSON
 */
export function allowWithWarning(reason, contextBlock) {
  const fullReason = contextBlock ? `${reason}\n\n${contextBlock}` : reason;
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: fullReason,
    },
  };
}

/**
 * PreToolUse: Allows tool invocation but updates input.
 * Used when automatically correcting input parameters (e.g., model routing).
 *
 * @param {string} reason - Modification reason (displayed to user)
 * @param {object} updatedInput - Full modified tool_input object
 * @returns {object} Hook output JSON
 */
export function allowWithUpdatedInput(reason, updatedInput) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: reason,
      updatedInput,
    },
  };
}

// ═══════════════════════════════════════════════════════════════
// Stop / SubagentStop Output (decision based)
// ═══════════════════════════════════════════════════════════════

/**
 * Stop: Blocks session termination.
 * Reason is passed to Claude to instruct continued execution.
 *
 * @param {string} reason - Block reason (read and acted upon by Claude)
 * @returns {object} Hook output JSON
 */
export function block(reason) {
  return { decision: 'block', reason };
}

/**
 * Stop: Advisory notice that does NOT block session termination.
 * `systemMessage` is shown to the user by Claude Code; the model is not re-prompted.
 *
 * Perspective 1 policy (harness-budget.json#stop_block_allowlist): Stop-turn blocking
 * re-prompts the model mid-flow and is the main source of "AI parallel-dev interference".
 * Real gates live at commit/push (pre-commit / pre-push). Stop hooks may only inform.
 *
 * @param {string} message - Notice text (shown to the user, not fed back to the model)
 * @returns {object} Hook output JSON
 */
export function notice(message) {
  return { systemMessage: message };
}

/**
 * Stop / SubagentStop: converts a blocking decision into an advisory notice.
 *
 * Runtime half of `harness-budget.json#stop_block_allowlist`: the lexical scan in
 * `tests/unit/stop-hooks-advisory.test.mjs` cannot see a block assembled inside an imported helper,
 * so `hook-orchestrator` applies this to every Stop result whose hook id is not allowlisted.
 * The original reason is preserved in the notice — nothing is hidden, only the re-prompt is removed.
 *
 * @param {object} result - A hook result carrying `decision: 'block'`
 * @param {string} hookId - Registry id of the hook that produced it
 * @returns {object} Advisory notice output
 */
export function downgradeStopBlock(result, hookId) {
  const reason = String(result?.reason ?? '').trim();
  return notice(
    `[STOP ADVISORY — ${hookId}] blocking decision downgraded to a notice ` +
      `(hook is not in harness-budget.json#stop_block_allowlist).` +
      (reason ? `\n${reason}` : ''),
  );
}

/**
 * Stop / SubagentStop: advisory for a guard's own internal exception (fail-open, R-CM-006 Rule 2).
 *
 * A guard that catches its own crash and returns bare `passthrough()` reads as a *clean*
 * evaluation to `hook-orchestrator.mjs#executeHook` (which only sets `evaluation.error` when
 * `run()` itself throws) — a guard broken on every turn then reports healthy in telemetry
 * indefinitely. `errorNotice` keeps the crash visible to the user via `systemMessage` and tags
 * the result with an internal `hookError` marker (not part of the Claude Code hook schema,
 * stripped before the result reaches aggregation) so `executeHook` can still record it as an error.
 *
 * @param {string} guardId - Hook id (for attribution in the message)
 * @param {unknown} err - The caught exception
 * @returns {object} Advisory notice output carrying the internal `hookError` marker
 */
export function errorNotice(guardId, err) {
  const message = err?.message || String(err ?? 'unknown error');
  return {
    ...notice(`[${guardId}] guard exception (fail-open, advisory only): ${message}`),
    hookError: true,
  };
}

// ═══════════════════════════════════════════════════════════════
// Context Injection (Used in PostToolUse, PostToolBatch, UserPromptSubmit, SessionStart)
// ═══════════════════════════════════════════════════════════════

/**
 * Injects additional context into Claude.
 * Delivers informational messages without blocking.
 *
 * Supported events: PostToolUse, PostToolBatch, UserPromptSubmit, SessionStart
 * Unsupported: Stop, SubagentStop (supports decision-based only — use block(), notice(), or passthrough())
 *              PreToolUse (permissionDecision-based — use deny()/allowWithWarning())
 *              PreCompact (hookSpecificOutput.additionalContext unsupported by Claude Code spec —
 *                          if context preservation after compact is needed, use source==='compact' branch in SessionStart hook)
 *
 * @param {string} message - Context message to inject
 * @param {string} [hookEventName] - Event name. Explicit argument > CLAUDE_HOOK_EVENT_NAME > PostToolUse.
 * @returns {object} Hook output JSON
 */
export function context(message, hookEventName) {
  const resolvedEvent = hookEventName || process.env.CLAUDE_HOOK_EVENT_NAME || 'PostToolUse';
  return {
    hookSpecificOutput: {
      hookEventName: resolvedEvent,
      additionalContext: message,
    },
  };
}

// ═══════════════════════════════════════════════════════════════
// Passthrough (Usable across all events)
// ═══════════════════════════════════════════════════════════════

/**
 * Passes through without action.
 * @returns {object} Empty object
 */
export function passthrough() {
  return {};
}

// ═══════════════════════════════════════════════════════════════
// Per-Event-Type Factories (Type-safe — exposes valid outputs only)
// ═══════════════════════════════════════════════════════════════

/**
 * Dedicated output set for Stop/SubagentStop.
 * Only block(), notice(), passthrough(), errorNotice() are valid.
 * In Perspective 1, block() is reserved for `stop_block_allowlist` entries (currently empty);
 * use notice() for everything else, and errorNotice() when the guard's own logic throws.
 *
 * Usage:
 *   const H = HookOutput.forStop();
 *   return output(H.notice('advisory text'));
 *   return output(H.passthrough());
 */
export function forStop() {
  return { block, notice, passthrough, errorNotice };
}

/**
 * Dedicated output set for PreToolUse.
 * Only deny(), allowWithWarning(), allowWithUpdatedInput(), passthrough() are valid.
 */
export function forPreToolUse() {
  return { deny, allowWithWarning, allowWithUpdatedInput, passthrough };
}

/**
 * Dedicated output set for PostToolUse.
 * Only block(), context(), passthrough() are valid.
 */
export function forPostToolUse() {
  return {
    block,
    context: (message) => context(message, 'PostToolUse'),
    passthrough,
  };
}

/**
 * Dedicated output set for UserPromptSubmit.
 * Only block(), context(), passthrough() are valid.
 */
export function forUserPromptSubmit() {
  return {
    block,
    context: (message) => context(message, 'UserPromptSubmit'),
    passthrough,
  };
}

/**
 * Dedicated output set for SessionStart.
 * Only context(), passthrough() are valid.
 *
 * Note: PreCompact does not support hookSpecificOutput.additionalContext by spec.
 * If context preservation after compact is needed, use source==='compact' branch in SessionStart hook.
 */
export function forSession(hookEventName = process.env.CLAUDE_HOOK_EVENT_NAME || 'SessionStart') {
  return {
    context: (message) => context(message, hookEventName),
    passthrough,
  };
}

// ═══════════════════════════════════════════════════════════════
// Namespace Export
// ═══════════════════════════════════════════════════════════════

export const HookOutput = {
  // Individual functions (legacy compatibility — factories recommended for new code)
  deny,
  allowWithWarning,
  allowWithUpdatedInput,
  block,
  notice,
  downgradeStopBlock,
  errorNotice,
  context,
  passthrough,
  // Per-event-type factories (recommended)
  forStop,
  forPreToolUse,
  forPostToolUse,
  forUserPromptSubmit,
  forSession,
};
