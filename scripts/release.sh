#!/bin/bash
# Build the RELEASE SarvTerminal app (cyan AppIcon, bundle com.sarv.terminal),
# sign with Developer ID, package a DMG, and notarize + staple it so it opens
# cleanly on other Macs. Output → ~/Downloads.
#
# Signing uses a DEDICATED, EPHEMERAL keychain created from your .p12 — this
# avoids the repeated login-keychain password prompts entirely (the build
# keychain is unlocked, partition-listed for codesign, and deleted afterward).
#
# Usage:  ./scripts/release.sh [major|minor|patch|X.Y.Z]
#   A bump arg advances the version in ./VERSION (e.g. `minor`: 1.0.0 -> 1.1.0),
#   builds + signs + notarizes the DMG into ./dist (gitignored), updates the
#   in-repo update feed under docs/ (appcast.xml served via GitHub Pages), and
#   GENERATES release notes freshly from the git commits since the last tag —
#   grouped by scope, so a release never ships blank or stale notes.
#   It then creates ONE release commit + a `vX.Y.Z` tag, PUSHES both, and uploads
#   the DMG to the GitHub release (needs the `gh` CLI). Set NO_PUSH=1 to stop
#   after the local commit/tag and push by hand.
#   With no arg it just builds the current ./VERSION (no commit/tag/push).
#
# Credentials are kept in your macOS Keychain — never written to disk, never
# seen by anyone but you:
#   • Notarization: a notarytool Keychain profile you create ONCE (see below).
#   • .p12 password: read from the login Keychain (prompted + stored first run).
set -e
cd "$(dirname "$0")/.."

# ── Version (optional first arg: major|minor|patch|X.Y.Z) ───────────────
# ./VERSION is the source of truth build.zig reads; release.sh bumps it.
VERSION_FILE="VERSION"
bump_version() {
  local IFS=.; read -r ma mi pa <<<"$1"; ma=${ma:-0}; mi=${mi:-0}; pa=${pa:-0}
  case "$2" in
    major) echo "$((ma + 1)).0.0" ;;
    minor) echo "$ma.$((mi + 1)).0" ;;
    patch) echo "$ma.$mi.$((pa + 1))" ;;
  esac
}
CUR=$(cat "$VERSION_FILE" 2>/dev/null || echo "1.0.0")
case "${1:-}" in
  "")                   VERSION="$CUR" ;;
  major | minor | patch) VERSION=$(bump_version "$CUR" "$1") ;;
  [0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
  *) echo "✗ usage: ./scripts/release.sh [major|minor|patch|X.Y.Z]"; exit 1 ;;
esac
echo "$VERSION" > "$VERSION_FILE"
echo "✓ Release version: $VERSION (was $CUR)"

# DMG is written into the repo under dist/ (gitignored — see .gitignore) so it
# sits next to the release commit, ready to upload as a GitHub release asset.
DIST_DIR="dist"
mkdir -p "$DIST_DIR"
DMG_OUT="$DIST_DIR/SarvTerminal-$VERSION.dmg"

# ── Credentials — Keychain only, nothing written to disk ─────────────────
: "${SARV_P12_PATH:=$HOME/Downloads/sarv-developerID-application.p12}"
[[ -f "$SARV_P12_PATH" ]] || { echo "✗ .p12 not found at $SARV_P12_PATH (set SARV_P12_PATH)"; exit 1; }

# .p12 password: read from the login Keychain. If it's not there yet, prompt once
# and store it in the Keychain (protected + never in a plaintext file).
P12_KC_SERVICE="sarv-terminal-p12"
SARV_P12_PASSWORD=$(security find-generic-password -a "$USER" -s "$P12_KC_SERVICE" -w 2>/dev/null || true)
if [[ -z "$SARV_P12_PASSWORD" ]]; then
  read -rsp "Password for the .p12 ($SARV_P12_PATH): " SARV_P12_PASSWORD; echo
  [[ -z "$SARV_P12_PASSWORD" ]] && { echo "✗ .p12 password required"; exit 1; }
  security add-generic-password -a "$USER" -s "$P12_KC_SERVICE" -w "$SARV_P12_PASSWORD" -U >/dev/null 2>&1 \
    && echo "✓ Saved .p12 password to your login Keychain (service: $P12_KC_SERVICE)"
fi

# Notarization uses a notarytool Keychain profile you create ONCE — this script
# only references the profile NAME and never sees your Apple ID / password:
#   xcrun notarytool store-credentials "sarv-notary" \
#     --apple-id "you@sarv.com" --team-id "LV54AA5562" --password "<app-specific-pw>"
NOTARY_PROFILE="${NOTARY_PROFILE:-sarv-notary}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-LV54AA5562}"   # not secret; only used in the setup hint

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
# Start from a clean bundle: dev.sh (Debug) and this script (ReleaseLocal) build
# into the SAME zig-out with different EXECUTABLE_NAMEs, so stale binaries
# (`ghostty`, `SarvTerminalDev`) pile up in Contents/MacOS and break
# `codesign --deep --strict`.
rm -rf "zig-out/Sarv Terminal.app"
# Pass the version explicitly so the build never falls back to git detection —
# otherwise building right after a release (HEAD sitting on the previous vX.Y.Z
# tag) panics with "tagged releases must match build.zig".
zig build -Doptimize=ReleaseFast -Dversion-string="$VERSION"
APP="zig-out/Sarv Terminal.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found after build"; exit 1; }

# Belt-and-suspenders: keep only the declared main executable in MacOS/.
EXE=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$APP/Contents/Info.plist")
find "$APP/Contents/MacOS" -maxdepth 1 -type f ! -name "$EXE" -delete
echo "✓ Bundle executable: $EXE"

# Stamp the version from ./VERSION into the built app. The Xcode project's
# MARKETING_VERSION is a hardcoded placeholder (0.1), so without this the app
# reports 0.1 in About AND — because Sparkle compares CFBundleVersion against the
# appcast's sparkle:version — it would re-offer the same update forever. Done
# before signing so the signature covers it.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
echo "✓ Bundle version: $VERSION"

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
cp -R "$APP" "$STAGE/Sarv Terminal.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create -volname "Sarv Terminal" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT" >/dev/null
rm -rf "$STAGE"
sign "$DMG_OUT"

# ── Notarize + staple ──────────────────────────────────────────────────
echo "=== Notarizing (a few minutes) ==="
echo "  (using Keychain profile '$NOTARY_PROFILE' — if this fails, run once:"
echo "     xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@…> --team-id $APPLE_TEAM_ID --password <app-specific-pw>)"
xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_OUT"
xcrun stapler staple "$APP"

echo ""
echo "════════════════════════════════════════"
echo "  Signed + notarized DMG:"
echo "  $DMG_OUT"
echo "════════════════════════════════════════"
spctl --assess --type open --context context:primary-signature -v "$DMG_OUT" 2>&1 || true

# ── Update the appcast + changelog ──────────────────────────────────────
# The update feed lives in THIS repo under docs/ and is served via GitHub Pages
# (https://sarv.github.io/SarvTerminal/appcast.xml). Optional:
#   SARV_DMG_URL         public DMG URL → adds a Sparkle <enclosure> (auto-download)
#   SPARKLE_SIGN_UPDATE  path to Sparkle's `sign_update` tool → adds edSignature
#   APPCAST_PUSH=1       commit + push docs/appcast.xml + release notes automatically
APPCAST="docs/appcast.xml"
NOTES_DIR="docs/release-notes"
if [[ -f "$APPCAST" ]]; then
  if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
    echo "=== Appcast already lists $VERSION — not adding a duplicate item ==="
  else
  echo "=== Updating $APPCAST ==="
  PUBDATE=$(date -u +'%a, %d %b %Y %H:%M:%S +0000')
  NOTES_URL="https://sarv.github.io/SarvTerminal/release-notes/$VERSION.html"
  # Direct DMG download on the public GitHub release (uploaded via `gh release
  # create` below). The app's update notification opens this link directly.
  DL_URL="https://github.com/Sarv/SarvTerminal/releases/download/v$VERSION/SarvTerminal-$VERSION.dmg"

  # A SIGNED <enclosure> so Sparkle auto-downloads + installs (an
  # <sparkle:informationalUpdate> only offers "Learn More"). The enclosure URL is
  # the GitHub release asset uploaded later in this script. The EdDSA signature
  # requires the private key in your Keychain (created once via `generate_keys`).
  LEN=$(stat -f%z "$DMG_OUT")
  SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1)}"
  [[ -x "$SIGN_UPDATE" ]] || { echo "✗ Sparkle sign_update not found — build once so the Sparkle SPM artifacts exist, or set SPARKLE_SIGN_UPDATE"; exit 1; }
  EDSIG=$("$SIGN_UPDATE" "$DMG_OUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
  [[ -n "$EDSIG" ]] || { echo "✗ Could not produce an EdDSA signature — is the Sparkle private key in your Keychain? (run generate_keys)"; exit 1; }
  BODY="      <enclosure url=\"$DL_URL\" sparkle:version=\"$VERSION\" sparkle:shortVersionString=\"$VERSION\" length=\"$LEN\" type=\"application/octet-stream\" sparkle:edSignature=\"$EDSIG\"/>"

  ITEM="    <item>
      <title>Version $VERSION</title>
      <link>$DL_URL</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>
      <sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>
$BODY
    </item>"

  # Insert the new item right after the channel <title> (newest first). The item
  # is read from a temp file inside awk because macOS awk (BWK) aborts on a
  # newline in a -v value ("newline in string") — which silently produced an
  # empty appcast and dropped the release from the feed.
  ITEM_FILE=$(mktemp)
  printf '%s\n' "$ITEM" > "$ITEM_FILE"
  awk -v itemfile="$ITEM_FILE" '
    /<title>Sarv Terminal<\/title>/ && !done {
      print
      while ((getline line < itemfile) > 0) print line
      close(itemfile)
      done = 1
      next
    }
    { print }
  ' "$APPCAST" > "$APPCAST.tmp" \
    && mv "$APPCAST.tmp" "$APPCAST"
  rm -f "$ITEM_FILE"

  mkdir -p "$NOTES_DIR"
  NOTES_FILE="$NOTES_DIR/$VERSION.html"
  # Regenerate when the file is MISSING or exists but has an EMPTY change list (no
  # <li>). An empty file happens when a prior run generated notes while the commit
  # range was still empty; the old `! -f` guard then froze that blank file forever.
  # A file that already has <li> items is left untouched so hand-tidied wording
  # survives a re-run.
  if [[ ! -f "$NOTES_FILE" ]] || ! grep -q '<li>' "$NOTES_FILE"; then
    # Build the notes FRESHLY from the git commits since the last release tag —
    # never copied from a previous version (that shipped stale, wrong notes).
    # We keep user-facing conventional commits (feat/fix/perf) and group them by
    # scope (tabs, ssh, sessions…) so sections match how features are organised.
    # Shared styling is in docs/release-notes/style.css; each file just links it.
    BASE_TAG=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)
    if [[ -n "$BASE_TAG" ]]; then RANGE="$BASE_TAG..HEAD"; else RANGE="HEAD"; fi
    echo "=== Generating $VERSION notes from commits (${BASE_TAG:-repo start}..HEAD) ==="

    esc(){ sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
    prettify(){ case "$1" in
        ssh|ssl|api|ui|dmg|url) tr '[:lower:]' '[:upper:]' <<<"$1" ;;
        general) echo "General" ;;
        *) echo "$(tr '[:lower:]' '[:upper:]' <<<"${1:0:1}")${1:1}" ;;
      esac; }

    # Documentation never belongs in user-facing release notes: skip commits
    # whose CHANGES are only .md files or docs/ (regardless of commit type).
    docs_only(){ # $1 = commit hash → success if every touched file is docs
      local files f
      files=$(git diff-tree --no-commit-id --name-only -r "$1")
      [[ -n "$files" ]] || return 1
      while IFS= read -r f; do
        [[ "$f" == *.md || "$f" == docs/* ]] || return 1
      done <<<"$files"
      return 0
    }

    # scope<TAB>description, one per kept commit (newest first). Skips docs
    # scopes and docs-only commits.
    PARSED=$(mktemp)
    re='^(feat|fix|perf)(\(([^)]+)\))?!?:[[:space:]]+(.+)$'
    # `tformat:` (not `format:`) so a trailing newline terminates the LAST/oldest
    # commit too — `format:` omits it and `while read` then silently drops that
    # final line (this is what dropped the oldest fix from 1.7.2/1.7.3 notes).
    git log $RANGE --no-merges --pretty=tformat:'%H%x09%s' | while IFS=$'\t' read -r hash subj; do
      if [[ "$subj" =~ $re ]]; then
        case "${BASH_REMATCH[3]}" in docs|readme|changelog) continue ;; esac
        docs_only "$hash" && continue
        printf '%s\t%s\n' "${BASH_REMATCH[3]:-general}" "${BASH_REMATCH[4]}"
      fi
    done > "$PARSED"

    # Never blank: if no conventional feat/fix/perf commits exist in range, fall
    # back to every commit subject so the notes still describe real, current work
    # — still excluding docs commits.
    if [[ ! -s "$PARSED" ]]; then
      git log $RANGE --no-merges --pretty=tformat:'%H%x09%s' | while IFS=$'\t' read -r hash subj; do
        [[ "$subj" =~ ^docs ]] && continue
        docs_only "$hash" && continue
        printf 'general\t%s\n' "$subj"
      done > "$PARSED"
    fi

    # Never ship a blank changelog. If BOTH passes produced nothing, the commit
    # range itself is empty — almost always because a v$VERSION tag already exists
    # (so `$BASE_TAG..HEAD` resolves to that tag..itself). Fail loudly here, BEFORE
    # any tag/push, instead of writing empty notes that then get frozen.
    if [[ ! -s "$PARSED" ]]; then
      rm -f "$PARSED"
      echo "ERROR: no release-worthy commits in range '$RANGE' — refusing to write empty" >&2
      echo "       release notes for $VERSION. Check that all commits are in place and that a" >&2
      echo "       v$VERSION tag doesn't already exist (which would make the range empty)." >&2
      exit 1
    fi

    # HTML body (Sparkle web page) + a Markdown copy (GitHub release body, which
    # renders Markdown — feeding it HTML shows raw <tags>).
    BODY=""
    MD_NOTES=$(mktemp)
    for scope in $(cut -f1 "$PARSED" | awk '!seen[$0]++'); do
      BODY+="  <h2>$(prettify "$scope")</h2>"$'\n'"  <ul>"$'\n'
      printf '### %s\n\n' "$(prettify "$scope")" >> "$MD_NOTES"
      while IFS=$'\t' read -r sc desc; do
        [[ "$sc" == "$scope" ]] || continue
        BODY+="    <li>$(printf '%s' "$desc" | esc)</li>"$'\n'
        printf -- '- %s\n' "$desc" >> "$MD_NOTES"
      done < "$PARSED"
      BODY+="  </ul>"$'\n'
      printf '\n' >> "$MD_NOTES"
    done
    rm -f "$PARSED"

    cat > "$NOTES_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sarv Terminal $VERSION</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
  <h1>Sarv Terminal $VERSION</h1>
  <div class="meta">Improvements &amp; fixes</div>
$BODY</body>
</html>
HTML
  fi
  echo "✓ Appcast item added and $NOTES_FILE generated from commits — review/tidy the wording before publishing."

  fi
fi

# ── Release commit + tag → push → upload DMG to the GitHub release ───────
# Only when this run actually set a new version (a bump arg or explicit X.Y.Z);
# a bare rebuild of the current VERSION must not create a commit/tag.
NOTES_FILE="$NOTES_DIR/$VERSION.html"
REPO="Sarv/SarvTerminal"
if [[ -n "${1:-}" && "$VERSION" != "$CUR" ]] || [[ "${FORCE_RELEASE_COMMIT:-}" == "1" ]]; then
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "⚠︎ Tag v$VERSION already exists — skipping commit/tag/push."
  else
    # The generated notes are your entry point — edit them now so they land in
    # the single release commit before it's pushed (interactive shells pause).
    echo ""
    echo "→ Release notes generated at: $NOTES_FILE"
    echo "  Edit them now if you want; they're the starting point, never blank/stale."
    if [[ -t 0 && "${NO_PUSH:-}" != "1" ]]; then
      read -rp "  Press Enter to commit + tag + PUSH v$VERSION and publish (Ctrl-C to abort)… " _
    fi
    git add "$VERSION_FILE" "$APPCAST" "$NOTES_FILE"
    git commit -q -m "release: SarvTerminal $VERSION"
    git tag -a "v$VERSION" -m "SarvTerminal $VERSION"
    echo "✓ Created release commit + tag v$VERSION"

    if [[ "${NO_PUSH:-}" == "1" ]]; then
      echo "  (NO_PUSH=1 — not pushing. Push by hand: git push && git push origin v$VERSION)"
    else
      BRANCH=$(git rev-parse --abbrev-ref HEAD)
      echo "=== Pushing $BRANCH + tag v$VERSION ==="
      git push origin "$BRANCH"
      git push origin "v$VERSION"

      echo "=== Publishing GitHub release v$VERSION (uploading DMG) ==="
      if command -v gh >/dev/null 2>&1; then
        # GitHub renders the release body as Markdown — use the generated .md,
        # falling back to a link if this run reused existing notes.
        if [[ -n "${MD_NOTES:-}" && -f "${MD_NOTES:-}" ]]; then
          NOTES_ARG=(--notes-file "$MD_NOTES")
        else
          NOTES_ARG=(--notes "Release notes: https://sarv.github.io/SarvTerminal/release-notes/$VERSION.html")
        fi
        gh release create "v$VERSION" "$DMG_OUT" \
          --repo "$REPO" --title "Sarv Terminal $VERSION" "${NOTES_ARG[@]}"
        echo "✓ Pushed + published release v$VERSION with the DMG attached"
      else
        echo "⚠︎ 'gh' CLI not found — commit + tag are pushed, but the DMG was NOT uploaded."
        echo "   Install gh (brew install gh) then run:"
        echo "     gh release create v$VERSION \"$DMG_OUT\" --repo $REPO \\"
        echo "       --title \"Sarv Terminal $VERSION\" --notes \"Release notes: https://sarv.github.io/SarvTerminal/release-notes/$VERSION.html\""
      fi
    fi
  fi
fi

echo ""
echo "════════════════════════════════════════"
echo "  Release v$VERSION complete."
echo "  DMG:   $DMG_OUT"
echo "  Notes: $NOTES_FILE"
echo "════════════════════════════════════════"
