#!/bin/sh
# Build the DEBUG ("SarvTerminal Dev") app and run it from /tmp — so the dev
# build never lives in /Applications and never collides with the daily release
# app (different bundle id `com.sarv.terminal.debug` + its own data dir
# `~/.config/sarvterminal-dev`).
set -e
cd "$(dirname "$0")/.."

zig build "$@"

DEV_APP="/tmp/SarvTerminal Dev.app"
rm -rf "$DEV_APP"
cp -R zig-out/SarvTerminal.app "$DEV_APP"
# ad-hoc re-sign the copy so it launches cleanly
codesign --force --deep --sign - "$DEV_APP" >/dev/null 2>&1 || true

# Restart ONLY the dev instance (match by its /tmp path; the release app in
# /Applications is left running).
pkill -f "SarvTerminal Dev.app/Contents/MacOS/ghostty" 2>/dev/null || true
sleep 0.5
open -n "$DEV_APP"
echo "launched dev: $DEV_APP"
