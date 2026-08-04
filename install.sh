#!/bin/bash
# Packages trinket, quits any running copy, installs to /Applications and launches it.
#
#   ./install.sh            keep existing settings
#   ./install.sh --fresh    wipe every trace first — the handover mode
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="trinket"
BUNDLE_ID="com.local.trinket"
FRESH=0
[[ "${1:-}" == "--fresh" ]] && FRESH=1

# Quit first. A running app holds its bundle open and gets replaced underneath itself, and
# --self-check hangs forever while another instance is live.
echo "==> Quitting any running copy"
osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
pkill -x Trinket 2>/dev/null || true
sleep 1

if [[ $FRESH -eq 1 ]]; then
  echo "==> Fresh install: wiping every trace"
  # Leftover state hides bugs — a stale preference masks a changed default, and an existing
  # setting hides the empty state. Every handover build is --fresh for this reason.
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -f  "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
  rm -f  "$HOME/Library/Preferences/ByHost/${BUNDLE_ID}."*.plist
  rm -rf "$HOME/Library/Application Support/${APP_NAME}"
  rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
  rm -rf "$HOME/Library/Caches/${BUNDLE_ID}"
  rm -rf "$HOME/Library/Logs/${APP_NAME}"
  # UserDefaults caches per-domain in a daemon; without this the deleted keys come straight back.
  killall cfprefsd 2>/dev/null || true
fi

./package-app.sh

echo "==> Installing to /Applications"
rm -rf "/Applications/${APP_NAME}.app"
cp -R "build/${APP_NAME}.app" /Applications/

# An ad-hoc signature's designated requirement is its cdhash, so every build is a different program
# to the permissions system. Resetting makes a stale grant fail obviously and re-grantably.
tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true

# LaunchServices keeps serving the previous artwork otherwise.
touch "/Applications/${APP_NAME}.app"
killall Dock 2>/dev/null || true

echo "==> Launching"
open "/Applications/${APP_NAME}.app"
echo "==> Installed $(defaults read "/Applications/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString)"
