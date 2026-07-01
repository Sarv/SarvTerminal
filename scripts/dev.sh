#!/bin/sh
# Build the DEBUG ("SarvTerminal Dev") app and run it from /tmp — so the dev
# build never lives in /Applications and never collides with the daily release
# app (different bundle id `com.sarv.terminal.debug` + its own data dir
# `~/.config/sarvterminal-dev`).
set -e
cd "$(dirname "$0")/.."

zig build "$@"

# No space in the filename so the path is shell-friendly (`open /tmp/...`).
# The in-app display name stays "SarvTerminal Dev" (set in Info.plist).
DEV_APP="/tmp/SarvTerminal_Dev.app"
rm -rf "$DEV_APP"
cp -R zig-out/SarvTerminal.app "$DEV_APP"
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
