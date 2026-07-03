#!/bin/sh
# Build the DEBUG ("SarvTerminal Dev") app and run it from /tmp — so the dev
# build never lives in /Applications and never collides with the daily release
# app (different bundle id `com.sarv.terminal.debug` + its own data dir
# `~/.config/sarvterminal-dev`).
set -e
cd "$(dirname "$0")/.."

# Pass the version explicitly (skips git detection, which panics when HEAD is on
# a release tag). "$@" still lets you add flags like -Dtest-filter.
zig build -Dversion-string="$(cat VERSION)" "$@"

# No space in the filename so the path is shell-friendly (`open /tmp/...`).
# The in-app display name stays "Sarv Terminal Dev" (set in Info.plist).
DEV_APP="/tmp/SarvTerminal_Dev.app"
rm -rf "$DEV_APP"
cp -R "zig-out/Sarv Terminal.app" "$DEV_APP"
# Stamp the version from ./VERSION so About shows the real version instead of the
# hardcoded MARKETING_VERSION placeholder (0.1). Before signing so it's covered.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(cat VERSION)" "$DEV_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(cat VERSION)" "$DEV_APP/Contents/Info.plist" 2>/dev/null || true
# Brand the dev build distinctly so it's obvious which app is which. CFBundleName
# drives the bold app-menu title and ⌘-Tab; CFBundleDisplayName drives Dock &
# Finder. Release stays "Sarv Terminal". The static menu subitems (About/Hide/
# Quit/Help/Default Terminal) are relabeled from these keys at runtime
# (AppDelegate.brandMenuFromBundleName).
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Sarv Terminal Dev" "$DEV_APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Sarv Terminal Dev" "$DEV_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName Sarv Terminal Dev" "$DEV_APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string Sarv Terminal Dev" "$DEV_APP/Contents/Info.plist" 2>/dev/null || true
# ad-hoc re-sign the copy so it launches cleanly
codesign --force --deep --sign - "$DEV_APP" >/dev/null 2>&1 || true

# Restart ONLY the dev instance. Match by the full /tmp path so the release
# app in /Applications is never touched. The debug binary is named
# `SarvTerminalDev` (release is `SarvTerminal`), so even a name-only pkill of
# the dev build can't collide with the release app.
pkill -f "SarvTerminal_Dev.app/Contents/MacOS/SarvTerminalDev" 2>/dev/null || true
sleep 0.5
open -n "$DEV_APP"
echo "launched dev: $DEV_APP"
