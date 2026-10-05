#!/bin/bash
#
# Rebuilds the bundle and restarts the running agent.
#
# This exists because two separate things make an edit look like it did nothing,
# both silently, and they compound:
#
#   1. `swift build` writes .build/<config>/mca. The *bundle's* copy of that
#      binary is only refreshed by Scripts/bundle.sh, which the quality gate
#      does not run. An app launched from build/ therefore keeps running
#      whatever was current the last time somebody bundled it — which can be
#      days of edits ago, with a green build and green tests the whole time.
#
#   2. The app is LSUIElement and stays resident with no Dock icon. `open` on a
#      resident app is a *reopen*, not a relaunch: it delivers
#      applicationShouldHandleReopen — which shows the settings window — and
#      leaves the old process untouched. So the one gesture that looks like
#      "restart it" is precisely the one that cannot pick up new code.
#
# Defaults to a debug build: this is the edit/run loop, and a release build pays
# whole-module optimisation on every iteration. Use CONFIGURATION=release for a
# build anyone else will run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/MyComputerAgent.app"

DEBUG_MODE=0
STREAM_LOGS=0
BUNDLE_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --debug|-d)
            DEBUG_MODE=1
            ;;
        --stream|-s)
            STREAM_LOGS=1
            ;;
        --help|-h)
            cat <<EOF
Usage: ./Scripts/run.sh [options] [signing-identity]

Rebuilds the app bundle and relaunches MyComputerAgent.

Options:
  --debug, -d   Launch the agent in debug mode (enables verbose autonomous loop diagnostics)
  --stream, -s  Follow the unified log stream immediately after launching
  --help, -h    Show this help message

Environment variables:
  MCA_DEBUG=1   Enable debug mode
  CONFIGURATION Build configuration ('debug' [default] or 'release')
EOF
            exit 0
            ;;
        *)
            BUNDLE_ARGS+=("$arg")
            ;;
    esac
done

if [ "${MCA_DEBUG:-0}" = "1" ]; then
    DEBUG_MODE=1
fi

CONFIGURATION="${CONFIGURATION:-debug}" "$ROOT/Scripts/bundle.sh" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"}

if pkill -f "$APP/Contents/MacOS/mca" 2>/dev/null; then
    echo ""
    echo "==> Stopped the running agent"
    # applicationWillTerminate tears the audio taps down and waits up to three
    # seconds for it. Killing through that teardown leaks the CoreAudio
    # aggregate device, which then shows up in later runs as a tap that will
    # not start.
    sleep 1
fi

if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "==> Launching agent in DEBUG mode (MCA_DEBUG=1)..."
    open "$APP" --args --debug
else
    open "$APP"
fi

cat <<EOF

==> Relaunched. (Debug mode: $([ "$DEBUG_MODE" -eq 1 ] && echo "ON" || echo "OFF"))

    Startup report and errors go to the unified log:
        log stream --predicate 'subsystem == "com.buddypia.mca"' --level debug
EOF

if [ "$STREAM_LOGS" -eq 1 ]; then
    echo ""
    echo "==> Streaming logs (press Ctrl+C to stop)..."
    exec log stream --predicate 'subsystem == "com.buddypia.mca"' --level debug
fi
