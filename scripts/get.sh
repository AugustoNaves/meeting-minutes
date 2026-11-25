#!/bin/bash
# Installs the latest Prosa release (no Xcode or compiling needed):
#   curl -fsSL https://raw.githubusercontent.com/AugustoNaves/prosa/main/scripts/get.sh | bash
set -euo pipefail

REPO="AugustoNaves/prosa"
BUNDLE_ID="local.meetingminutes"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Prosa needs a Mac with Apple Silicon (M1 or newer)."
  exit 1
fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 26 ]; then
  echo "Prosa needs macOS 26 (Tahoe) or newer. This Mac has macOS $(sw_vers -productVersion)."
  exit 1
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

WORK="$(mktemp -d -t prosa)"
cleanup() { rm -rf -- "${WORK:?}"; }
trap cleanup EXIT

echo "==> Downloading the latest Prosa…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/Prosa.zip" -o "$WORK/Prosa.zip"
ditto -x -k "$WORK/Prosa.zip" "$WORK"
codesign --verify "$WORK/Prosa.app"

echo "==> Closing the previous version (if it is running)…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x MeetingMinutes >/dev/null 2>&1 || true

echo "==> Installing in $DEST…"
rm -rf -- "$DEST/Prosa.app" "$DEST/Meeting Minutes.app"
ditto "$WORK/Prosa.app" "$DEST/Prosa.app"
xattr -dr com.apple.quarantine "$DEST/Prosa.app" 2>/dev/null || true

# Each build has its own local signature: old permissions would look granted but not apply.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" onboardingDone -bool false

open "$DEST/Prosa.app"
echo
echo "Done! Prosa is in the menu bar (top right of the screen)."
echo "Follow the windows to grant the permissions and choose an AI (or none)."
