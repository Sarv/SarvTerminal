#!/bin/sh
# Build the Linux (GTK) app inside the dev container from a macOS host.
# Usage: ./scripts/linux/build.sh [extra zig build args...]
# The repo is mounted read-write; zig caches persist in named volumes so
# incremental builds are fast.
set -e
cd "$(dirname "$0")/../.."

IMAGE=sarvterminal-linux-dev

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building dev image (first run only)..."
    docker build -t "$IMAGE" -f scripts/linux/Dockerfile.dev .
fi

docker run --rm \
    -v "$(pwd):/src" \
    -v sarvterminal-zig-global-cache:/root/.cache/zig \
    -v sarvterminal-zig-local-cache:/src/.zig-cache-linux \
    -e ZIG_LOCAL_CACHE_DIR=/src/.zig-cache-linux \
    "$IMAGE" \
    zig build --prefix zig-out-linux -Dversion-string="$(cat VERSION)" "$@"
