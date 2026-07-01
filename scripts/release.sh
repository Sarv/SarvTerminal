#!/bin/bash
# Build the RELEASE SarvTerminal app (cyan AppIcon, bundle com.sarv.terminal),
# sign with Developer ID, package a DMG, and notarize + staple it so it opens
# cleanly on other Macs. Output → ~/Downloads.
#
# Signing uses a DEDICATED, EPHEMERAL keychain created from your .p12 — this
# avoids the repeated login-keychain password prompts entirely (the build
# keychain is unlocked, partition-listed for codesign, and deleted afterward).
#
# Usage:  ./scripts/release.sh
# Credentials are entered once and cached in ~/.sarvterminal-release-env.
set -e
cd "$(dirname "$0")/.."

DMG_OUT="$HOME/Downloads/SarvTerminal.dmg"
ENV_FILE="$HOME/.sarvterminal-release-env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ask_and_save() {
  local var="$1" prompt="$2" secret="$3"
  if [[ -z "${!var}" ]]; then
    if [[ "$secret" == "secret" ]]; then read -rsp "$prompt: " v; echo; else read -rp "$prompt: " v; fi
    [[ -z "$v" ]] && { echo "✗ $var is required"; exit 1; }
    export "$var=$v"; echo "export $var=\"$v\"" >> "$ENV_FILE"; chmod 600 "$ENV_FILE"
  fi
}

# ── Credentials (cached) ───────────────────────────────────────────────
: "${SARV_P12_PATH:=$HOME/Downloads/sarv-developerID-application.p12}"
grep -q SARV_P12_PATH "$ENV_FILE" 2>/dev/null || echo "export SARV_P12_PATH=\"$SARV_P12_PATH\"" >> "$ENV_FILE"
[[ -f "$SARV_P12_PATH" ]] || { echo "✗ .p12 not found at $SARV_P12_PATH (set SARV_P12_PATH)"; exit 1; }
ask_and_save SARV_P12_PASSWORD "Password for the .p12 ($SARV_P12_PATH)" secret
ask_and_save APPLE_ID "Apple ID (notarization email)"
ask_and_save APPLE_APP_SPECIFIC_PASSWORD "App-specific password (appleid.apple.com)" secret
: "${APPLE_TEAM_ID:=LV54AA5562}"
grep -q APPLE_TEAM_ID "$ENV_FILE" 2>/dev/null || echo "export APPLE_TEAM_ID=\"$APPLE_TEAM_ID\"" >> "$ENV_FILE"

# ── Ephemeral signing keychain (no prompts) ────────────────────────────
BUILD_KC="$HOME/Library/Keychains/sarv-build.keychain-db"
BUILD_KC_PW="sarv-build-$$"
ORIG_KEYCHAINS=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
cleanup() {
  # Restore the original search list and remove the throwaway keychain.
  # shellcheck disable=SC2086
  security list-keychains -d user -s $ORIG_KEYCHAINS >/dev/null 2>&1 || true
  security delete-keychain "$BUILD_KC" 2>/dev/null || true
}
trap cleanup EXIT

security delete-keychain "$BUILD_KC" 2>/dev/null || true
security create-keychain -p "$BUILD_KC_PW" "$BUILD_KC"
security set-keychain-settings -lut 21600 "$BUILD_KC"     # don't auto-lock mid-build
security unlock-keychain -p "$BUILD_KC_PW" "$BUILD_KC"
security import "$SARV_P12_PATH" -k "$BUILD_KC" -P "$SARV_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/productsign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$BUILD_KC_PW" "$BUILD_KC" >/dev/null
# Put the build keychain FIRST so codesign resolves the identity from it.
# shellcheck disable=SC2086
security list-keychains -d user -s "$BUILD_KC" $ORIG_KEYCHAINS >/dev/null

SIGN_ID=$(security find-identity -v -p codesigning "$BUILD_KC" | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
[[ -z "$SIGN_ID" ]] && { echo "✗ No Developer ID Application identity in the .p12"; exit 1; }
echo "✓ Signing identity (ephemeral keychain): $SIGN_ID"

# ── Build the release app ──────────────────────────────────────────────
echo "=== Building release (ReleaseFast) ==="
zig build -Doptimize=ReleaseFast
APP="zig-out/SarvTerminal.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found after build"; exit 1; }

# ── Sign inside-out (Sparkle first, app last) ──────────────────────────
sign(){ codesign --force --timestamp --options runtime --keychain "$BUILD_KC" --sign "$SIGN_ID" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
echo "=== Signing ==="
[[ -d "$SP" ]] && {
  sign "$SP/XPCServices/Downloader.xpc"
  sign "$SP/XPCServices/Installer.xpc"
  sign "$SP/Updater.app"
  sign "$SP/Autoupdate"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
}
for p in "$APP"/Contents/PlugIns/*; do [[ -e "$p" ]] && sign "$p"; done
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ Signed: $(codesign -dv "$APP" 2>&1 | grep '^Authority' | head -1)"

# ── Package DMG ────────────────────────────────────────────────────────
echo "=== Packaging DMG ==="
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/SarvTerminal.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create -volname "SarvTerminal" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null
rm -rf "$STAGE"
sign "$DMG_OUT"

# ── Notarize + staple ──────────────────────────────────────────────────
echo "=== Notarizing (a few minutes) ==="
xcrun notarytool submit "$DMG_OUT" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$DMG_OUT"
xcrun stapler staple "$APP"

echo ""
echo "════════════════════════════════════════"
echo "  Signed + notarized DMG:"
echo "  $DMG_OUT"
echo "════════════════════════════════════════"
spctl --assess --type open --context context:primary-signature -v "$DMG_OUT" 2>&1 || true
