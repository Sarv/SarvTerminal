#!/usr/bin/env bash
# Build and run your custom Warp OSS.
# Usage:  bash Ankur/build.sh
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$REPO_ROOT"

# Ensure cargo is on PATH (handles both fresh shells and CI)
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

# Verify prerequisites are installed; install missing ones silently
if ! command -v cargo &>/dev/null; then
    echo "Rust not found. Run ./script/bootstrap first."
    exit 1
fi

if ! command -v cargo-bundle &>/dev/null; then
    echo "Installing cargo-bundle..."
    "$REPO_ROOT/script/install_cargo_bundle"
fi

if ! command -v diesel &>/dev/null; then
    echo "Installing diesel CLI (one-time, takes ~2 min)..."
    cargo binstall --force -y diesel_cli 2>/dev/null \
        || cargo install diesel_cli --no-default-features --features sqlite
fi

# Build and launch (suppress channel-config and skills noise for this OSS build)
WARP_OSS_QUIET=1 ./script/run
