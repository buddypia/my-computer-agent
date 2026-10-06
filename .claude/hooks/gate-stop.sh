#!/bin/bash
#
# .claude/hooks/gate-stop.sh — Stop-hook adapter around Scripts/gate.sh.
#
# Registered from both .claude/settings.json and .codex/hooks.json. The two CLIs
# agree on the parts this script depends on: a JSON payload on stdin carrying
# `session_id`, and a `{"decision":"block","reason":...}` object on stdout with
# exit 0 to hand the turn back to the model instead of ending it.
#
# The hook is what makes the gate non-optional. An instruction in AGENTS.md asks
# the model to build; a Stop hook means the turn does not end until it does. But
# an unconditional block is a livelock waiting to happen, so the retry budget
# below caps how many times one session may be sent back. When the budget is
# spent the turn is allowed to end with the failure stated plainly — a human
# deciding to ship a red build is a legitimate outcome; an agent silently
# looping on it is not.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT/.tmp/gate"
MAX_RETRIES="${MCA_GATE_MAX_RETRIES:-3}"

mkdir -p "$STATE_DIR"

PAYLOAD="$(cat 2>/dev/null || true)"

# Sessions are the unit the budget is counted over. Without an id every turn
# would look like a fresh session and the budget would never bind.
SESSION="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
s = d.get("session_id") or (d.get("session") or {}).get("id") or "nosession"
print(re.sub(r"[^A-Za-z0-9_-]", "", str(s))[:64] or "nosession")
' 2>/dev/null || echo nosession)"

COUNTER="$STATE_DIR/retries-$SESSION"

# Every turn pays for this, so it stops at the build (G1). The tests run on CI for the pushed HEAD,
# and `trust.mjs approve --ci` will not auto-merge without that run's evidence.
OUTPUT="$("$ROOT/Scripts/gate.sh" --stage "${MCA_GATE_HOOK_STAGE:-1}" 2>&1)"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    rm -f "$COUNTER"
    exit 0
fi

TRIES=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$TRIES" > "$COUNTER"

if [ "$TRIES" -gt "$MAX_RETRIES" ]; then
    rm -f "$COUNTER"
    # Not a block: report and let the turn end. The failure still has to reach
    # the human, and stderr on a non-blocking exit is where they will see it.
    echo "GATE still failing after $MAX_RETRIES attempts — handing back to the human." >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 0
fi

python3 -c '
import json, sys
output, tries, cap = sys.argv[1], sys.argv[2], sys.argv[3]
reason = (
    f"品質ゲートが失敗しました (試行 {tries}/{cap})。\n\n"
    f"{output}\n\n"
    "この失敗を修正してから応答を終えてください。修正後は Scripts/gate.sh を"
    "自分で実行して緑になったことを確認すること。ゲートを回避する目的で "
    "MCA_GATE=off を使ってはいけません。"
)
print(json.dumps({"decision": "block", "reason": reason}))
' "$OUTPUT" "$TRIES" "$MAX_RETRIES"
exit 0
