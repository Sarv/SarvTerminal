#!/usr/bin/env bash
# Build an unsigned DMG with a drag-to-Applications installer layout.
#
# Usage:
#   bash Ankur/build_dmg.sh [flags]
#
# Flags:
#   --app-name  NAME     App bundle name shown in Finder  (default: WarpOss)
#   --version   VERSION  Version string in Info.plist     (default: Ankur-custom-build)
#   --release            Release-optimised build (slower, smaller binary)
#   --dmg-only           Skip build, just repackage the existing .app into a DMG
#
# Examples:
#   bash Ankur/build_dmg.sh --app-name WarpAnkur --version 1.0-ankur
#   bash Ankur/build_dmg.sh --dmg-only --app-name WarpAnkur
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$REPO_ROOT"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

# ── Defaults ──────────────────────────────────────────────────────────────────
APP_NAME="WarpOss"          # cargo-bundle always produces this name from Cargo.toml
CUSTOM_NAME=""              # if set, .app is renamed to this after bundling
CUSTOM_VERSION="Ankur-custom-build"
CARGO_PROFILE_FLAG=""
PROFILE="debug"
DMG_ONLY=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-name) CUSTOM_NAME="$2";    shift 2 ;;
        --version)  CUSTOM_VERSION="$2"; shift 2 ;;
        --release)  CARGO_PROFILE_FLAG="--release"; PROFILE="release"; shift ;;
        --dmg-only) DMG_ONLY=true; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# Resolved names
BUNDLE_NAME="${CUSTOM_NAME:-$APP_NAME}"     # final .app name (may differ from cargo output)
BUILT_BUNDLE="target/${PROFILE}/bundle/osx/${APP_NAME}.app"
FINAL_BUNDLE="target/${PROFILE}/bundle/osx/${BUNDLE_NAME}.app"
DMG_OUT="Ankur/${BUNDLE_NAME}-${CUSTOM_VERSION}.dmg"
STAGING_DIR="/tmp/warp-dmg-staging"

echo "==> App name : $BUNDLE_NAME"
echo "==> Version  : $CUSTOM_VERSION"
echo "==> Profile  : $PROFILE"
echo "==> Output   : $DMG_OUT"
echo

# ── 1. Build ──────────────────────────────────────────────────────────────────
if [ "$DMG_ONLY" = false ]; then
    export GIT_RELEASE_TAG="$CUSTOM_VERSION"
    export WARP_OSS_QUIET=1
    echo "==> Building .app bundle (this takes a few minutes)…"
    WARP_BIN_NAME="warp-oss" \
    WARP_CHANNEL="oss" \
    FEATURES="gui" \
      bash script/macos/run --dont-open $CARGO_PROFILE_FLAG
fi

# ── 2. Rename .app if --app-name differs from cargo output ────────────────────
if [ -n "$CUSTOM_NAME" ] && [ "$CUSTOM_NAME" != "$APP_NAME" ]; then
    echo "==> Renaming ${APP_NAME}.app → ${BUNDLE_NAME}.app…"
    rm -rf "$FINAL_BUNDLE"
    cp -R "$BUILT_BUNDLE" "$FINAL_BUNDLE"
fi

# ── 3. Patch Info.plist ───────────────────────────────────────────────────────
PLIST="${FINAL_BUNDLE}/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    echo "==> Patching Info.plist…"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CUSTOM_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CUSTOM_VERSION"            "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME"                  "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_NAME"           "$PLIST" 2>/dev/null || true
fi

# ── 4. Codesign ───────────────────────────────────────────────────────────────
# Set SIGN_IDENTITY to your Developer ID cert name to use a real signature.
# Leave blank (or unset) to fall back to ad-hoc signing (-).
#
# Example:
#   export SIGN_IDENTITY="Developer ID Application: Sarv Communications Pvt Ltd (ABCD1234EF)"
#   bash Ankur/build_dmg.sh --release
#
# Find your cert name with:
#   security find-identity -v -p codesigning
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing .app with: $SIGN_IDENTITY"
    codesign --deep --force --options runtime --sign "$SIGN_IDENTITY" "$FINAL_BUNDLE" \
        && echo "   codesign OK" \
        || { echo "   codesign FAILED"; exit 1; }
else
    echo "==> Signing .app (ad-hoc — set SIGN_IDENTITY for a real Developer ID signature)…"
    codesign --deep --force --sign - "$FINAL_BUNDLE" \
        && echo "   codesign OK" \
        || echo "   codesign skipped (codesign not available)"
fi

# ── 5. DMG with drag-to-Applications layout ───────────────────────────────────
echo "==> Creating DMG…"
mkdir -p Ankur
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R "$FINAL_BUNDLE" "$STAGING_DIR/${BUNDLE_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

TEMP_DMG="/tmp/warp-temp.dmg"
rm -f "$TEMP_DMG" "$DMG_OUT"

hdiutil create \
    -volname "${BUNDLE_NAME} ${CUSTOM_VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov -fs HFS+ -format UDRW \
    "$TEMP_DMG"

hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_OUT"

rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

echo
echo "✓ Done: $DMG_OUT"
echo "  Open the DMG and drag ${BUNDLE_NAME}.app → Applications."
