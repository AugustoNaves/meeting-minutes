#!/bin/bash
# Builds Prosa, installs it in the Applications folder and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Prosa"
BUNDLE_ID="local.meetingminutes"

./scripts/build.sh

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

echo "==> Closing the previous version (if it is running)…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x MeetingMinutes >/dev/null 2>&1 || true

echo "==> Installing in $DEST…"
rm -rf "$DEST/$APP_NAME.app"
# The app used to be called "Meeting Minutes": remove the old copy (same app, new name).
rm -rf "$DEST/Meeting Minutes.app"
cp -R "build/$APP_NAME.app" "$DEST/"

# Every build gets a new signature. Resetting old permissions avoids macOS showing the app
# as "allowed" while the permission does not actually apply to the new build.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" onboardingDone -bool false

open "$DEST/$APP_NAME.app"
echo
echo "Done! The icon is now in the menu bar (top right of the screen)."
echo "Follow the windows to grant the permissions. Then just use the ⌘⇧R shortcut."
