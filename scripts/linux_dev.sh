#!/bin/sh
# Linux counterpart of scripts/dev.sh: build and run the DEBUG GTK app.
#
# Unlike macOS, the Linux box is usually a fresh VM (UTM etc.), so the first
# run also bootstraps the toolchain: distro packages (dnf or apt) and the
# pinned Zig. After `git clone`, this one script is all a new VM needs.
#
#   ./scripts/linux_dev.sh              # bootstrap (if needed) + build + run
#   ./scripts/linux_dev.sh -Dtest-filter=foo   # extra zig build flags pass through
#
# NOTE: the Linux app is the engine-level GTK frontend (src/apprt/gtk) — no
# Sarv Terminal UI (Vaults/SFTP/sidebar) yet. See README roadmap.
set -e
cd "$(dirname "$0")/.."

[ "$(uname -s)" = "Linux" ] || {
  echo "error: this script runs inside the Linux VM (macOS uses scripts/dev.sh)" >&2
  exit 1
}

ZIG_MIN="0.15.2"
ZIG_HOME="$HOME/.local/zig"

# ── Distro packages ──────────────────────────────────────────────────────
# Cheap presence probe first so repeat runs don't touch the package manager.
need_pkgs=0
pkg-config --exists gtk4 2>/dev/null || need_pkgs=1
pkg-config --exists libadwaita-1 2>/dev/null || need_pkgs=1
command -v blueprint-compiler >/dev/null 2>&1 || need_pkgs=1
command -v git >/dev/null 2>&1 || need_pkgs=1
command -v cc >/dev/null 2>&1 || need_pkgs=1

if [ "$need_pkgs" = 1 ]; then
  echo "=== Installing build dependencies (sudo) ==="
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git gcc pkg-config gtk4-devel libadwaita-devel \
      blueprint-compiler gettext libxml2 wayland-protocols-devel \
      gtk4-layer-shell-devel
  elif command -v apt-get >/dev/null 2>&1; then
    # Needs Ubuntu 25.04+ / Debian testing — older releases ship a
    # blueprint-compiler too old for the GTK app.
    sudo apt-get update
    sudo apt-get install -y git build-essential pkg-config libgtk-4-dev \
      libadwaita-1-dev blueprint-compiler gettext libxml2-utils \
      libgtk4-layer-shell-dev
  else
    echo "error: unsupported distro (need dnf or apt-get); install deps manually — see HACKING.md" >&2
    exit 1
  fi
fi

# ── Zig (pinned; distro packages are usually the wrong version) ─────────
zig_ok() {
  command -v zig >/dev/null 2>&1 || return 1
  have=$(zig version)
  [ "$(printf '%s\n' "$ZIG_MIN" "$have" | sort -V | head -1)" = "$ZIG_MIN" ]
}

PATH="$ZIG_HOME:$PATH"
if ! zig_ok; then
  ARCH=$(uname -m)   # aarch64 (UTM on Apple Silicon) or x86_64
  echo "=== Installing Zig $ZIG_MIN ($ARCH) to $ZIG_HOME ==="
  TMP=$(mktemp -d)
  # Tarball naming changed across Zig releases — try both layouts.
  for name in "zig-$ARCH-linux-$ZIG_MIN" "zig-linux-$ARCH-$ZIG_MIN"; do
    if curl -fsSL "https://ziglang.org/download/$ZIG_MIN/$name.tar.xz" -o "$TMP/zig.tar.xz"; then
      break
    fi
  done
  [ -s "$TMP/zig.tar.xz" ] || { echo "error: could not download Zig $ZIG_MIN" >&2; exit 1; }
  mkdir -p "$ZIG_HOME"
  tar -xJf "$TMP/zig.tar.xz" -C "$ZIG_HOME" --strip-components=1
  rm -rf "$TMP"
  echo "hint: add to your shell profile →  export PATH=\"$ZIG_HOME:\$PATH\""
fi
echo "using zig $(zig version) at $(command -v zig)"

# ── Build + run ──────────────────────────────────────────────────────────
# Pass the version explicitly (skips git tag detection, which panics when
# HEAD is on a release tag) — same as the macOS scripts.
exec zig build -Dversion-string="$(cat VERSION)" "$@" run
