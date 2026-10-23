#!/bin/bash
#
# Scripts/gate.sh — the staged quality gate.
#
# This is the single source of truth for "is the tree in a shippable state?".
# A human runs it by hand, and both Claude Code and Codex CLI run it through
# their Stop hooks (see .claude/hooks/gate-stop.sh). There is deliberately only
# one implementation: a gate that the agent runs differently from the human is
# a gate that drifts, and the first time it drifts is the time it matters.
#
# The stages are ordered by cost, and each one is a precondition for the next.
# There is no point running the test suite against a tree that does not compile,
# and no point assembling a signed bundle from a tree that fails its tests, so a
# failure short-circuits the rest.
#
#   G0  harness    Scripts/harness/check.mjs + its tests (AGENTS.md cap, skill triggers, hooks shape)
#       classify   what changed? docs-only edits exit 0 without touching swift
#   G1  build      swift build          (~20s incremental; skipped on non-Swift local changes)
#   G2  trust      node --test Scripts/trust/tests/*.test.mjs  (~1s)
#       test       swift test --xunit-output   (~12s)
#       isolated   whole-process measurements, alone and serial (~25s)
#       guards     trust.mjs incident check against this run's TAP + xUnit  (~0s)
#   G3  bundle     Scripts/bundle.sh    (opt-in; minutes, and it codesigns)
#
# G3 is not part of the default run on purpose. It rewrites build/ and invokes
# codesign, which is a side effect an agent should not perform on every turn.
#
# Usage:
#   Scripts/gate.sh                 # G0..G2 (default)
#   Scripts/gate.sh --stage 1       # stop after the build
#   Scripts/gate.sh --stage 3       # include the release bundle
#   Scripts/gate.sh --force         # run even if the change is docs-only
#   MCA_GATE=off Scripts/gate.sh    # escape hatch: skip everything
#   MCA_GATE_NO_CACHE=1 Scripts/gate.sh   # never trust the pass cache (Scripts/trust assess uses this)
#
# Exit codes:
#   0  every requested stage passed, or the change did not warrant a gate
#   1  a stage failed (the failing output is on stdout)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.tmp/gate"
LOG_DIR="$STATE_DIR/logs"
MAX_STAGE=2
FORCE=0

# Resolve shared scratchpad directory in the main checkout (shared across all worktrees).
resolve_scratchpad_dir() {
    if [ -d "$ROOT/.git" ]; then
        printf '%s/.tmp/agent-scratchpad' "$ROOT"
        return 0
    fi
    local common
    common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ]; then
        printf '%s/.tmp/agent-scratchpad' "$(dirname "$common")"
        return 0
    fi
    printf '%s/.tmp/agent-scratchpad' "$ROOT"
}
SCRATCHPAD_DIR="$(resolve_scratchpad_dir)"

# How many lines of a failing tool's output to surface. Enough to contain a
# Swift diagnostic with its context, short enough not to bury the agent.
TAIL_LINES=60

while [ $# -gt 0 ]; do
    case "$1" in
        --stage) MAX_STAGE="$2"; shift 2 ;;
        --stage=*) MAX_STAGE="${1#*=}"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "gate: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "${MCA_GATE:-on}" = "off" ]; then
    echo "GATE SKIP  MCA_GATE=off"
    exit 0
fi

mkdir -p "$LOG_DIR"

# --- G0: classify the change -------------------------------------------------
#
# The rule is an explicit list of paths that cannot break the build, and the
# default for everything else is to run the gate. This direction matters: an
# allowlist of "code paths" would silently skip a new top-level directory,
# whereas an allowlist of "harmless paths" only ever errs toward doing the work.

is_doc_path() {
    case "$1" in
        *.md|*.markdown|*.txt|docs/*|LICENSE|NOTICES*|.github/*|.gitignore|.editorconfig) return 0 ;;
        *) return 1 ;;
    esac
}

# Explicit allowlist of non-Swift repository paths (harness, hooks, trust, evals, docs).
# Any unknown path or Swift/package/bundle path falls through to return 1 (runs Swift build/tests).
is_non_swift_path() {
    case "$1" in
        .claude/*|.cli/*|.codex/*|.agents/*|.husky/*|Scripts/gate.sh|Scripts/harness/*|Scripts/trust/*|Scripts/eval/*|data/harness/*|data/trust/*|Evals/*|Makefile)
            return 0 ;;
        *)
            is_doc_path "$1" ;;
    esac
}

# Paths the working tree has touched, tracked and untracked alike. If the tree
# is clean the agent may have committed its work already, so fall back to what
# the branch brought in since it left main, and what HEAD brought in.
changed_paths() {
    local out
    out="$(
        git -C "$ROOT" diff --no-renames --name-only HEAD 2>/dev/null
        git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null
    )"
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        out="$(
            git -C "$ROOT" diff --no-renames --name-only origin/main...HEAD 2>/dev/null
            git -C "$ROOT" diff-tree --root -m -r --no-commit-id --name-only HEAD 2>/dev/null
        )"
    fi
    printf '%s\n' "$out" | sed '/^$/d' | sort -u
}

# A content fingerprint, not just a file list. `git status` reports a file as
# modified no matter how many times it is edited, so keying the cache on the
# status output would let a second edit inherit the first edit's PASS.
fingerprint() {
    {
        git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo no-head
        git -C "$ROOT" diff HEAD 2>/dev/null
        git -C "$ROOT" ls-files --others --exclude-standard -z 2>/dev/null \
            | xargs -0 shasum 2>/dev/null
    } | shasum | awk '{print $1}'
}

# Subsystem content fingerprints for cross-worktree stamp sharing in SCRATCHPAD_DIR.
subsystem_fingerprint() {
    {
        git -C "$ROOT" ls-tree HEAD -- "$@" 2>/dev/null || true
        git -C "$ROOT" diff HEAD -- "$@" 2>/dev/null || true
        git -C "$ROOT" ls-files --others --exclude-standard -z -- "$@" 2>/dev/null \
            | xargs -0 shasum 2>/dev/null || true
    } | shasum | awk '{print $1}'
}

# Cross-worktree lock for heavy Swift toolchain invocations so 4+ parallel worktrees
# do not thrash CPU/RAM simultaneously and cause hook timeouts.
acquire_swift_slot() {
    [ "${MCA_GATE_NO_CACHE:-0}" = "1" ] && return 0
    local lock_dir="$SCRATCHPAD_DIR/locks/swift.lock"
    mkdir -p "$SCRATCHPAD_DIR/locks" 2>/dev/null || return 0
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        local owner_pid
        owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
        if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
            rm -rf "$lock_dir" 2>/dev/null || true
            continue
        fi
        [ "$waited" -ge 180 ] && break
        sleep 1
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
}

release_swift_slot() {
    local lock_dir="$SCRATCHPAD_DIR/locks/swift.lock"
    local owner_pid
    owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [ "$owner_pid" = "$$" ]; then
        rm -rf "$lock_dir" 2>/dev/null || true
    fi
}
trap 'release_swift_slot' EXIT

# The auto-approval evaluator and its recurrence-prevention registry (docs/trust/auto-approval.md).
# Cheap, so it also runs on docs-only changes: a checklist guard lives in docs/, and hollowing it out
# must not be the one edit the gate never looks at. A skipped or todo test fails the stage — a guard
# test that no longer runs is not a guard. Guards are checked *after* the Swift suite so a Swift
# regression-test guard is confirmed by this run's xUnit, not by the text of its file.
TRUST_TAP="$LOG_DIR/trust-tap.txt"
SWIFT_XUNIT="$LOG_DIR/swift-xunit.xml"
SWIFT_XUNIT_ST="$LOG_DIR/swift-xunit-swift-testing.xml"
# The same run as an event stream: Scripts/trust reads what executed from it instead of running the
# suite a second time (`trust.mjs evidence`, `trust.mjs baseline`).
SWIFT_EVENTS="$LOG_DIR/swift-events.jsonl"

trust_tests() {
    local out trust_fp shared_tap
    mkdir -p "$LOG_DIR"
    rm -f "$TRUST_TAP"
    if [ "${MCA_GATE_NO_CACHE:-0}" != "1" ] && [ "$FORCE" -eq 0 ]; then
        trust_fp="$(subsystem_fingerprint Scripts/trust data/trust .claude/scripts .cli Scripts/gate.sh)"
        shared_tap="$SCRATCHPAD_DIR/stamps/trust-tap-$trust_fp.txt"
        if [ -n "$trust_fp" ] && [ -f "$shared_tap" ]; then
            cp "$shared_tap" "$TRUST_TAP" 2>/dev/null && return 0
        fi
    fi
    out="$(node --test --test-reporter=tap "$ROOT"/Scripts/trust/tests/*.test.mjs 2>&1)" || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out" > "$TRUST_TAP"
    if printf '%s\n' "$out" | grep -Eq '^# (skipped|todo) [1-9]'; then
        printf '%s\n' "$out" | grep -E '# (SKIP|TODO)|^# (skipped|todo)'
        echo "trust: skipped/todo tests are not allowed in Scripts/trust/tests"
        return 1
    fi
    if [ -n "${trust_fp:-}" ]; then
        mkdir -p "$SCRATCHPAD_DIR/stamps" 2>/dev/null || true
        cp "$TRUST_TAP" "$SCRATCHPAD_DIR/stamps/trust-tap-$trust_fp.txt" 2>/dev/null || true
    fi
}

# SwiftPM queues its own processes on .build/.lock, so concurrent gates wait for each other.
# Something outside that lock can still hold swift-build's database for a moment, and the build
# then fails with "database is locked" although nothing is wrong with the tree. Only that failure
# is retried; any other is the build's own.
swift_build() {
    if [ "${SWIFT_TOUCHED:-1}" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
        echo "Build skipped: no Swift paths touched"
        return 0
    fi
    acquire_swift_slot
    local out attempt=1 rc=0
    until out="$(swift build --package-path "$ROOT" 2>&1)"; do
        printf '%s\n' "$out"
        # A here-string, not a pipe: under pipefail, grep -q quitting early fails a long printf (SIGPIPE).
        if ! { grep -q 'database is locked' <<< "$out" && [ "$attempt" -lt 3 ]; }; then
            release_swift_slot
            return 1
        fi
        echo "gate: the build database is locked by another build; retrying"
        sleep "${MCA_GATE_LOCK_RETRY_SECONDS:-5}"
        attempt=$((attempt + 1))
    done
    release_swift_slot
    printf '%s\n' "$out"
    return "$rc"
}

swift_tests() {
    rm -f "$SWIFT_XUNIT" "$SWIFT_XUNIT_ST" "$SWIFT_EVENTS"
    if [ "${SWIFT_TOUCHED:-1}" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
        echo "Tests skipped: no Swift paths touched"
        return 0
    fi
    acquire_swift_slot
    local rc=0
    swift test --package-path "$ROOT" --xunit-output "$SWIFT_XUNIT" \
        --event-stream-output-path "$SWIFT_EVENTS" --event-stream-version 0 || rc=$?
    release_swift_slot
    return "$rc"
}

# Process-wide numbers (main-thread latency, the watchdog, pool wall-clock, resident memory) are
# asserted behind `IsolatedTiming.enabled` in tests named `…Isolated`. The parallel run above checks
# only their functional part: there the numbers measure the neighbours, which made CI red on a slow
# runner. Here those tests run alone, one at a time, with the numbers switched on. Fails closed, read
# from xUnit: fewer test cases than declared `…Isolated(` functions, or any skip, is not a pass.
ISOLATED_XUNIT="$LOG_DIR/isolated-xunit.xml"
ISOLATED_XUNIT_ST="$LOG_DIR/isolated-xunit-swift-testing.xml"

isolated_tests() {
    local declared ran skipped rc=0
    rm -f "$ISOLATED_XUNIT" "$ISOLATED_XUNIT_ST"
    if [ "${SWIFT_TOUCHED:-1}" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
        echo "Isolated tests skipped: no Swift paths touched"
        return 0
    fi
    acquire_swift_slot
    MCA_ISOLATED_TIMING=1 swift test --package-path "$ROOT" --skip-build --no-parallel \
        --filter 'Isolated\(' --xunit-output "$ISOLATED_XUNIT" || rc=$?
    release_swift_slot
    [ "$rc" -eq 0 ] || return 1
    declared="$(grep -rEho '\bfunc[[:space:]]+[A-Za-z0-9_]+Isolated[[:space:]]*\(' "$ROOT/Tests" | wc -l | tr -d ' ')"
    ran="$(grep -o '<testcase ' "$ISOLATED_XUNIT_ST" 2>/dev/null | wc -l | tr -d ' ')"
    skipped="$(grep -o '<skipped' "$ISOLATED_XUNIT_ST" 2>/dev/null | wc -l | tr -d ' ')"
    echo "isolated: declared $declared, ran $ran, skipped $skipped"
    [ "$declared" -gt 0 ] && [ "$ran" -ge "$declared" ] && [ "$skipped" -eq 0 ]
}

trust_guards() {
    local xunit=()
    [ -f "$SWIFT_XUNIT_ST" ] && xunit=(--xunit "$SWIFT_XUNIT_ST")
    node "$ROOT/Scripts/trust/trust.mjs" incident check --tap "$TRUST_TAP" ${xunit[@]+"${xunit[@]}"}
}

# The agent harness (AGENTS.md, .agents/skills, hooks files) is almost all Markdown, so G0 would class
# an edit to it as docs-only and skip it. The check is cheap and runs before that classification.
harness_check() {
    node "$ROOT/Scripts/harness/check.mjs" --root "$ROOT" || return 1
    local harness_fp stamp_file
    if [ "${MCA_GATE_NO_CACHE:-0}" != "1" ] && [ "$FORCE" -eq 0 ]; then
        harness_fp="$(subsystem_fingerprint AGENTS.md CLAUDE.md .agents .claude .cli .codex Scripts/harness data/harness)"
        stamp_file="$SCRATCHPAD_DIR/stamps/harness-$harness_fp.ok"
        if [ -n "$harness_fp" ] && [ -f "$stamp_file" ]; then
            return 0
        fi
    fi
    node --test "$ROOT"/Scripts/harness/tests/*.test.mjs || return 1
    if [ -n "${harness_fp:-}" ]; then
        mkdir -p "$SCRATCHPAD_DIR/stamps" 2>/dev/null || true
        printf '%s\n' "$harness_fp" > "$SCRATCHPAD_DIR/stamps/harness-$harness_fp.ok" 2>/dev/null || true
    fi
}

PATHS="$(changed_paths)"
FP="$(fingerprint)"

# --force means "run everything": a clean tree whose HEAD changed nothing (an empty commit) lists no
# paths, and a forced run that skipped would read as a pass to anyone who only checks the exit code.
if [ -z "$PATHS" ]; then
    if [ "$FORCE" -eq 0 ]; then
        echo "GATE SKIP  no changes to gate"
        exit 0
    fi
    PATHS="(forced)"
fi

# Nothing has changed since the last green run, so re-running the toolchain
# would only re-derive an answer we already have.
if [ "${MCA_GATE_NO_CACHE:-0}" != "1" ] && [ "$FORCE" -eq 0 ] && [ -f "$STATE_DIR/pass" ]; then
    CACHED_PASS="$(cat "$STATE_DIR/pass" 2>/dev/null || true)"
    if [ "$CACHED_PASS" = "$FP:$MAX_STAGE" ] || { [ "$CACHED_PASS" = "$FP:2" ] && [ "$MAX_STAGE" -le 2 ]; }; then
        echo "GATE PASS  cached (unchanged since last green run, stage<=$MAX_STAGE)"
        exit 0
    fi
fi

if ! harness_out="$(harness_check 2>&1)"; then
    echo "GATE FAIL  harness checks"
    printf '%s\n' "$harness_out" | tail -n "$TAIL_LINES"
    rm -f "$STATE_DIR/pass"
    exit 1
fi

CODE_TOUCHED=0
SWIFT_TOUCHED=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! is_doc_path "$p"; then CODE_TOUCHED=1; fi
    if ! is_non_swift_path "$p"; then SWIFT_TOUCHED=1; fi
done <<< "$PATHS"

if [ "$CODE_TOUCHED" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    rm -f "$SWIFT_XUNIT_ST"
    if ! trust_out="$(trust_tests 2>&1 && trust_guards 2>&1)"; then
        echo "GATE FAIL  trust checks (docs-only change)"
        printf '%s\n' "$trust_out" | tail -n "$TAIL_LINES"
        exit 1
    fi
    echo "$FP:$MAX_STAGE" > "$STATE_DIR/pass"
    echo "GATE SKIP  docs-only change ($(printf '%s\n' "$PATHS" | wc -l | tr -d ' ') file(s))"
    exit 0
fi

echo "GATE RUN   $(printf '%s\n' "$PATHS" | wc -l | tr -d ' ') changed path(s), stages G1..G$MAX_STAGE"

# --- stage runner ------------------------------------------------------------

run_stage() {
    local num="$1" name="$2"; shift 2
    [ "$MAX_STAGE" -ge "$num" ] || return 0

    local log="$LOG_DIR/g$num-$name.log"
    local started elapsed
    started=$SECONDS

    if "$@" > "$log" 2>&1; then
        elapsed=$((SECONDS - started))
        echo "  G$num $name    PASS  (${elapsed}s)"
        return 0
    fi

    elapsed=$((SECONDS - started))
    echo "  G$num $name    FAIL  (${elapsed}s)"
    echo ""
    echo "--- G$num $name: last $TAIL_LINES lines ($log) ---"
    tail -n "$TAIL_LINES" "$log"
    # The tail of a parallel test run is mostly passing tests; the failures can sit anywhere above it.
    if grep -qE '^✘ |error:' "$log"; then
        echo "--- G$num $name: failures ---"
        grep -E '^✘ |error:' "$log" | head -n "$TAIL_LINES"
    fi
    echo "--- end G$num $name ---"
    rm -f "$STATE_DIR/pass"
    return 1
}

run_stage 1 build  swift_build                         || exit 1
run_stage 2 trust  trust_tests                         || exit 1
run_stage 2 test   swift_tests                         || exit 1
run_stage 2 isolated isolated_tests                    || exit 1
run_stage 2 guards trust_guards                        || exit 1
run_stage 3 bundle "$ROOT/Scripts/bundle.sh"          || exit 1

echo "$FP:$MAX_STAGE" > "$STATE_DIR/pass"
if [ -f "$ROOT/.claude/scripts/agent-scratchpad.mjs" ]; then
    node "$ROOT/.claude/scripts/agent-scratchpad.mjs" record-gate --worktree "$ROOT" --stage "$MAX_STAGE" --status pass --fp "$FP" >/dev/null 2>&1 || true
fi
echo "GATE PASS  stages G1..G$MAX_STAGE"
