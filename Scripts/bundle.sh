#!/bin/bash
#
# Builds MyComputerAgent.app.
#
# A bundle is not cosmetic here. macOS attributes TCC permissions to a signed
# bundle identifier, and two things break without one:
#
#   1. The system reads usage-description strings from Info.plist to populate
#      the permission prompts. No Info.plist, no prompt.
#   2. `AudioHardwareCreateProcessTap` fails on an unsigned binary *without*
#      prompting, which looks exactly like a bug in the app.
#
# The signing identity matters more than it looks. TCC stores a code-signing
# requirement next to the grant, and for an ad-hoc signature that requirement
# is the binary's cdhash:
#
#   designated => cdhash H"37a3376f..."
#
# The hash changes on every rebuild, so macOS sees a different app, the grant
# stops matching, and the entry vanishes from System Settings. Signing with any
# real certificate produces a stable, identity-based requirement instead:
#
#   designated => identifier "com.buddypia.mca" and anchor apple generic
#                 and certificate leaf[subject.CN] = "Apple Development: ..."
#
# which survives rebuilds. This script therefore prefers a real identity and
# only falls back to ad-hoc with a loud warning.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/MyComputerAgent.app"
BUNDLE_ID="com.buddypia.mca"

# --- pick a signing identity -------------------------------------------------

pick_identity() {
    if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
        echo "$1"
        return
    fi
    if [ -n "${MCA_SIGN_IDENTITY:-}" ]; then
        echo "$MCA_SIGN_IDENTITY"
        return
    fi
    # Developer ID is best (distributable); Apple Development is fine locally.
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"')
    if [ -n "$found" ]; then echo "$found"; return; fi
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')
    if [ -n "$found" ]; then echo "$found"; return; fi
    echo "-"
}

IDENTITY="$(pick_identity "${1:-}")"

# --- build -------------------------------------------------------------------

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT"

BINARY="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)/mca"
test -f "$BINARY" || { echo "no binary at $BINARY"; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/mca"

# Ship the license texts with the binary: the third-party licenses require their
# notices to travel with redistributed copies.
for f in LICENSE NOTICES.md; do
    test -f "$ROOT/$f" || { echo "missing $ROOT/$f"; exit 1; }
    cp "$ROOT/$f" "$APP/Contents/Resources/$f"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyComputerAgent</string>
  <key>CFBundleDisplayName</key><string>My Computer Agent</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>mca</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>

  <!-- Accessory policy: no Dock icon, no menu bar. The UI is the overlay. -->
  <key>LSUIElement</key><true/>

  <!-- These strings are what the user reads in the permission dialogs, so they
       state what is captured and where it goes. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Transcribes your speech so the copilot can follow your conversations. With the Apple engine audio stays on this Mac; with the Gemini engine (the default) and in live voice sessions, audio is sent to Google Gemini.</string>

  <key>NSAudioCaptureUsageDescription</key>
  <string>Captures system audio so the copilot can follow meeting participants. With the Apple engine transcription happens on this Mac; with the Gemini engine (the default), audio is sent to Google Gemini.</string>

  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Converts captured audio to text using Apple's on-device speech model when the Apple engine is selected.</string>

  <key>NSScreenCaptureUsageDescription</key>
  <string>Reads text from your focused window when an app exposes no accessibility information. Text is recognized on this Mac; screenshots and extracted text may be sent to your configured AI model provider to answer your requests.</string>

  <key>NSAppleEventsUsageDescription</key>
  <string>Sends Apple Events to other apps, including System Events, to run AppleScript you have approved or to type text you have approved.</string>
</dict>
</plist>
PLIST

cat > "$ROOT/build/mca.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Deliberately NOT sandboxed. The App Sandbox has no entitlement that
       grants access to another application's accessibility tree, so a
       sandboxed build cannot read the screen at all. -->
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <!-- No keychain-access-groups: that entitlement needs a provisioning
       profile, and an unsandboxed app reaches its own generic-password items
       without it. -->
</dict>
</plist>
ENTITLEMENTS

# --- sign --------------------------------------------------------------------

echo "==> Signing as: $IDENTITY"
codesign --force --sign "$IDENTITY" \
    --entitlements "$ROOT/build/mca.entitlements" \
    --options runtime \
    "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

DR="$(codesign -dr - "$APP" 2>&1 | grep '^designated' || true)"
echo "    $DR"

if [ "$IDENTITY" = "-" ]; then
    cat <<'WARN'

⚠️  AD-HOC SIGNED — permissions will NOT survive a rebuild.

    The designated requirement above is a bare cdhash. macOS ties every TCC
    grant to it, so the next build looks like a different app: Microphone,
    Screen Recording and Accessibility all revert, and the stale entries can
    even disappear from System Settings entirely.

    Fix: sign with any real certificate. A free Apple Development certificate
    from Xcode ▸ Settings ▸ Accounts is enough for local use.

    Meanwhile, reset the stale grants after each build:
        mca reset-permissions
WARN
else
    echo ""
    echo "==> Identity-based requirement — TCC grants will survive rebuilds."
fi

cat <<EOF

==> Built $APP

    open "$APP"                          # background agent + overlay
    mca doctor                           # check permissions
    mca listen 20                        # verify the audio path
EOF
