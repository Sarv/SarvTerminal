#!/bin/sh
# Build the DEBUG app and run it in DEMO mode for capturing README screenshots.
#
# Demo mode (--demo) uses a fully ISOLATED workspace:
#   • data:  ~/.config/sarvterminal-demo   (own encrypted stores + keystore)
#   • keys:  ~/.config/sarvterminal-demo/.ssh (sample keys + known_hosts)
# It never reads or writes your dev (~/.config/sarvterminal-dev) or release
# (~/.config/sarvterminal) data, and never touches your real ~/.ssh. On first
# launch it seeds realistic, privacy-safe sample data (hosts, groups, keys,
# snippets, port-forwards, logs).
#
# Usage:
#   ./scripts/demo.sh          build + launch (seeds once, then reuses data)
#   ./scripts/demo.sh reset    wipe the demo workspace first, then re-seed
set -e
cd "$(dirname "$0")/.."

# `reset` wipes the isolated demo workspace so the next launch re-seeds fresh.
if [ "$1" = "reset" ]; then
  rm -rf "$HOME/.config/sarvterminal-demo"
  echo "reset: cleared ~/.config/sarvterminal-demo"
  shift
fi

zig build "$@"

# Isolated /tmp copy so it never collides with the dev or release app.
DEMO_APP="/tmp/SarvTerminal_Demo.app"
rm -rf "$DEMO_APP"
cp -R zig-out/SarvTerminal.app "$DEMO_APP"
# Brand name for the menu bar (matches dev/release), then ad-hoc re-sign.
/usr/libexec/PlistBuddy -c "Set :CFBundleName Sarv Terminal" "$DEMO_APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$DEMO_APP" >/dev/null 2>&1 || true

# Restart ONLY the demo instance (match the full /tmp path).
pkill -f "SarvTerminal_Demo.app/Contents/MacOS/SarvTerminalDev" 2>/dev/null || true
sleep 0.5
# Demo mode is detected from the bundle path (/tmp/SarvTerminal_Demo.app) — see
# AppPaths.isDemo. We intentionally pass NO CLI flags: the Ghostty engine parses
# `--flags` as config and would reject an unknown one.
open -n "$DEMO_APP"
echo "launched demo: $DEMO_APP"
