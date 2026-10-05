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
#   G0  classify   what changed? docs-only edits exit 0 without touching swift
#   G1  build      swift build          (~20s incremental)
#   G2  trust      node --test Scripts/trust/tests/*.test.mjs  (~1s)
#       test       swift test --xunit-output   (~12s)
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

# Paths the working tree has touched, tracked and untracked alike. If the tree
# is clean the agent may have committed its work already, so fall back to what
# HEAD brought in. Not `git show`: a clean merge commit (ship merging main into
# the branch) shows no paths, and the gate would skip the very tree that is about
# to land. -m lists a merge against each parent; --root lists every file of a
# commit with no parent (a root commit, or the tip of a depth-1 clone).
# --no-renames: a rename lists only its new path, so `git mv a.swift docs/a.txt`
# would read as docs-only and hide the deleted source file.
changed_paths() {
    local out
    out="$(
        git -C "$ROOT" diff --no-renames --name-only HEAD 2>/dev/null
        git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null
    )"
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        out="$(git -C "$ROOT" diff-tree --root -m -r --no-commit-id --name-only HEAD 2>/dev/null)"
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

# The auto-approval evaluator and its recurrence-prevention registry (docs/trust/auto-approval.md).
# Cheap, so it also runs on docs-only changes: a checklist guard lives in docs/, and hollowing it out
# must not be the one edit the gate never looks at. A skipped or todo test fails the stage — a guard
# test that no longer runs is not a guard. Guards are checked *after* the Swift suite so a Swift
# regression-test guard is confirmed by this run's xUnit, not by the text of its file.
TRUST_TAP="$LOG_DIR/trust-tap.txt"
SWIFT_XUNIT="$LOG_DIR/swift-xunit.xml"
SWIFT_XUNIT_ST="$LOG_DIR/swift-xunit-swift-testing.xml"

trust_tests() {
    local out
    mkdir -p "$LOG_DIR"
    rm -f "$TRUST_TAP"
    out="$(node --test --test-reporter=tap "$ROOT"/Scripts/trust/tests/*.test.mjs 2>&1)" || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out" > "$TRUST_TAP"
    if printf '%s\n' "$out" | grep -Eq '^# (skipped|todo) [1-9]'; then
        printf '%s\n' "$out" | grep -E '# (SKIP|TODO)|^# (skipped|todo)'
        echo "trust: skipped/todo tests are not allowed in Scripts/trust/tests"
        return 1
    fi
}

swift_tests() {
    rm -f "$SWIFT_XUNIT" "$SWIFT_XUNIT_ST"
    swift test --package-path "$ROOT" --xunit-output "$SWIFT_XUNIT"
}

trust_guards() {
    local xunit=()
    [ -f "$SWIFT_XUNIT_ST" ] && xunit=(--xunit "$SWIFT_XUNIT_ST")
    node "$ROOT/Scripts/trust/trust.mjs" incident check --tap "$TRUST_TAP" ${xunit[@]+"${xunit[@]}"}
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

CODE_TOUCHED=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! is_doc_path "$p"; then CODE_TOUCHED=1; break; fi
done <<< "$PATHS"

if [ "$CODE_TOUCHED" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    rm -f "$SWIFT_XUNIT_ST"
    if ! trust_out="$(trust_tests 2>&1 && trust_guards 2>&1)"; then
        echo "GATE FAIL  trust checks (docs-only change)"
        printf '%s\n' "$trust_out" | tail -n "$TAIL_LINES"
        exit 1
    fi
    echo "GATE SKIP  docs-only change ($(printf '%s\n' "$PATHS" | wc -l | tr -d ' ') file(s))"
    exit 0
fi

# Nothing has changed since the last green run, so re-running the toolchain
# would only re-derive an answer we already have.
if [ "${MCA_GATE_NO_CACHE:-0}" != "1" ] && [ -f "$STATE_DIR/pass" ] && [ "$(cat "$STATE_DIR/pass")" = "$FP:$MAX_STAGE" ]; then
    echo "GATE PASS  cached (unchanged since last green run, stage<=$MAX_STAGE)"
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
    echo "--- end G$num $name ---"
    rm -f "$STATE_DIR/pass"
    return 1
}

run_stage 1 build  swift build --package-path "$ROOT" || exit 1
run_stage 2 trust  trust_tests                         || exit 1
run_stage 2 test   swift_tests                         || exit 1
run_stage 2 guards trust_guards                        || exit 1
run_stage 3 bundle "$ROOT/Scripts/bundle.sh"          || exit 1

echo "$FP:$MAX_STAGE" > "$STATE_DIR/pass"
echo "GATE PASS  stages G1..G$MAX_STAGE"
