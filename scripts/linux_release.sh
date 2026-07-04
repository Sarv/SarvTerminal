#!/bin/sh
# Linux counterpart of scripts/release.sh — optimized GTK build + tarball.
#
# Deliberately SIMPLER than the macOS release: version bumping, tagging, the
# appcast, and GitHub release creation all live in scripts/release.sh (run on
# the Mac). This script only builds the CURRENT ./VERSION as an optimized
# binary and packages it, so a Linux artifact can be attached to the same
# GitHub release:
#
#   ./scripts/linux_release.sh
#   → dist/SarvTerminal-<version>-<arch>-linux.tar.gz
#
# Attach it from the VM (or copy to the Mac first) with:
#   gh release upload v<version> dist/SarvTerminal-<version>-<arch>-linux.tar.gz
#
# No signing/notarization on Linux. Toolchain bootstrap is shared with
# linux_dev.sh — run that once first on a fresh VM.
set -e
cd "$(dirname "$0")/.."

[ "$(uname -s)" = "Linux" ] || {
  echo "error: this script runs inside the Linux VM (macOS uses scripts/release.sh)" >&2
  exit 1
}

PATH="$HOME/.local/zig:$PATH"
command -v zig >/dev/null 2>&1 || {
  echo "error: zig not found — run ./scripts/linux_dev.sh once to bootstrap" >&2
  exit 1
}

VERSION=$(cat VERSION)
ARCH=$(uname -m)

echo "=== Building Sarv Terminal $VERSION ($ARCH, ReleaseFast) ==="
rm -rf zig-out
zig build -Doptimize=ReleaseFast -Dversion-string="$VERSION"

mkdir -p dist
TARBALL="dist/SarvTerminal-$VERSION-$ARCH-linux.tar.gz"
tar -C zig-out -czf "$TARBALL" .

echo "✓ $TARBALL"
echo "  attach to the release with:"
echo "  gh release upload v$VERSION $TARBALL"
