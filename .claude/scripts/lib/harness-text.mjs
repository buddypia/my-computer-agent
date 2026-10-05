/**
 * harness-text.mjs — Single SSOT for detecting and stripping harness-injected text (zero-dependency lightweight lib)
 *
 * Provides a single repository of tags and classification/stripping functions for non-user text
 * injected into the "user message" slot by the Claude Code harness
 * (task-notification / system-reminder / teammate-message, etc.).
 *
 * Zero-dependency constraint: Because hot-path hooks like UserPromptSubmit import this on fresh Node processes,
 * no dependencies (fs, crypto, layout-resolver) should be added to this file.
 */

export const HARNESS_TAGS = new Set([
  'task-notification',
  'system-reminder',
  'teammate-message',
  'command-name',
  'command-message',
  'command-args',
  'command-stdout',
  'local-command-stdout',
  'local-command-caveat',
  'user-prompt-submit-hook',
  'session-restore',
  'ai-task-passport',
  'ai-task-context-protocol',
]);

/** Returns true if text begins with harness-injected tags (not a human user instruction). */
export function isHarnessInjectedText(text) {
  if (typeof text !== 'string') return false;
  const trimmed = text.trimStart();
  if (!trimmed.startsWith('<')) return false;
  const match = /^<([a-zA-Z][a-zA-Z0-9_-]*)(?=[\s/>])/.exec(trimmed);
  if (!match) return false;
  return HARNESS_TAGS.has(match[1].toLowerCase());
}

/**
 * Strips harness tag blocks (<tag ...>...</tag>) embedded in text.
 * extraTags allows consumer-specific tags (result, output, etc.) to be included.
 */
export function stripHarnessTagBlocks(text, extraTags = []) {
  let out = String(text || '');
  for (const tag of [...HARNESS_TAGS, ...extraTags]) {
    out = out.replace(new RegExp(`<${tag}(?:\\s[^>]*)?>[\\s\\S]*?</${tag}>`, 'g'), '');
  }
  return out;
}

/**
 * Whitespace normalization + code-point safe truncation (default 240 chars, appends '…' on overflow).
 */
export function promptExcerpt(text, limit = 240) {
  const normalized = String(text || '')
    .replace(/\s+/g, ' ')
    .trim();
  const points = [...normalized];
  if (points.length <= limit) return normalized;
  return `${points.slice(0, limit - 1).join('')}…`;
}
