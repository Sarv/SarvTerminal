#!/usr/bin/env bash
# Remove WarpAnkur / WarpOss and all associated data.
#
# Usage:
#   bash Ankur/uninstall.sh              # remove app + all data
#   bash Ankur/uninstall.sh --data-only  # wipe data, keep the .app
#   bash Ankur/uninstall.sh --dry-run    # print what would be deleted
set -euo pipefail

APP_NAMES=("WarpAnkur" "WarpOss")
BUNDLE_ID="dev.warp.WarpOss"

DATA_ONLY=false
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --data-only) DATA_ONLY=true ;;
        --dry-run)   DRY_RUN=true ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

# ── helpers ───────────────────────────────────────────────────────────────────

remove() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        if $DRY_RUN; then
            echo "  [dry-run] would remove: $path"
        else
            rm -rf "$path"
            echo "  removed: $path"
        fi
    fi
}

# ── 1. Kill running instances ─────────────────────────────────────────────────
echo "==> Stopping any running Warp instances…"
for name in "warp-oss" "${APP_NAMES[@]}"; do
    if pgrep "$name" >/dev/null 2>&1; then
        if $DRY_RUN; then
            echo "  [dry-run] would kill: $name"
        else
            pkill "$name" 2>/dev/null || true
            echo "  killed: $name"
        fi
    fi
done
sleep 1

# ── 2. Remove .app bundles ────────────────────────────────────────────────────
if ! $DATA_ONLY; then
    echo "==> Removing .app bundles…"
    for name in "${APP_NAMES[@]}"; do
        remove "/Applications/${name}.app"
    done
fi

# ── 3. Remove user data ───────────────────────────────────────────────────────
echo "==> Removing user data…"

# Config dir: settings.toml, keybindings, themes, workflows
remove "$HOME/.warp-oss"

# Non-sandboxed SQLite DB (used by unsigned/custom builds)
remove "$HOME/Library/Application Support/${BUNDLE_ID}"

# Sync repo clone
remove "$HOME/.warp-sync"

# Spotlight / Launch Services caches
remove "$HOME/Library/Caches/${BUNDLE_ID}"
remove "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
remove "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
remove "$HOME/Library/Cookies/${BUNDLE_ID}.binarycookies"
remove "$HOME/Library/WebKit/${BUNDLE_ID}"

# ── 4. Group Container (sandboxed official Warp data) ─────────────────────────
GC="$HOME/Library/Group Containers"
if [ -d "$GC" ]; then
    for entry in "$GC"/*/; do
        candidate="${entry}Library/Application Support/${BUNDLE_ID}"
        if [ -d "$candidate" ]; then
            remove "$candidate"
        fi
    done
fi

# ── 5. Rebuild Launch Services DB so Spotlight entries disappear ──────────────
if ! $DRY_RUN; then
    echo "==> Refreshing Launch Services…"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -kill -r -domain local -domain system -domain user 2>/dev/null || true
fi

echo
if $DRY_RUN; then
    echo "Dry run complete — nothing was deleted."
else
    echo "Done. All WarpAnkur/WarpOss data has been removed."
    if $DATA_ONLY; then
        echo "The .app bundle was kept. Launch it to start fresh."
    fi
fi
