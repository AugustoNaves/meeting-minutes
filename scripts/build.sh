#!/bin/bash
# Builds the app and assembles "build/Meeting Minutes.app" (does not install it).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Meeting Minutes"
BUNDLE_ID="local.meetingminutes"
APP="build/$APP_NAME.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Run:  xcode-select --install  and try again."
  exit 1
fi

echo "==> Building (the first build takes about a minute)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling the app…"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MeetingMinutes" "$APP/Contents/MacOS/MeetingMinutes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  echo "==> Drawing the icon…"
  if swiftc -O scripts/make-icon.swift -o build/make-icon 2>/dev/null; then
    build/make-icon build/AppIcon.icns || echo "   (icon skipped)"
  fi
fi
if [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (local ad-hoc signature, no developer account needed)…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify "$APP"

echo "Done: $APP"
