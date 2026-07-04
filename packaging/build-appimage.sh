#!/usr/bin/env bash
#
# build-appimage.sh — assemble a portable AppImage for Sarv Terminal.
#
# This does NOT build the app. It takes an already-built `zig-out` prefix
# (produced by `zig build --prefix zig-out`, as the linux-release workflow
# does) and bundles it into a relocatable AppImage that runs on any modern
# Linux distro.
#
# Usage:
#   packaging/build-appimage.sh [ZIG_OUT_PREFIX]
#
#   ZIG_OUT_PREFIX  Path to the built prefix. Defaults to ./zig-out.
#
# Output:
#   SarvTerminal-<version>-<arch>.AppImage  (in the current directory)
#
# Requirements: bash, curl, file, and network access to fetch linuxdeploy and
# the GTK plugin. FUSE is needed to *run* the resulting AppImage, but
# APPIMAGE_EXTRACT_AND_RUN=1 is exported so building works in containers/CI
# without FUSE.

set -euo pipefail

# --- Resolve paths ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ZIG_OUT="${1:-${REPO_ROOT}/zig-out}"
ZIG_OUT="$(cd "${ZIG_OUT}" 2>/dev/null && pwd || true)"

if [ -z "${ZIG_OUT}" ] || [ ! -x "${ZIG_OUT}/bin/ghostty" ]; then
  echo "error: no built prefix found (expected \$ZIG_OUT/bin/ghostty)." >&2
  echo "       build first, e.g.: zig build -Doptimize=ReleaseFast --prefix zig-out" >&2
  echo "       then: $0 [path-to-zig-out]" >&2
  exit 1
fi

# --- Version + arch --------------------------------------------------------

VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"

# linuxdeploy names artifacts by machine arch; keep the same convention.
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  LD_ARCH="x86_64" ;;
  aarch64|arm64) LD_ARCH="aarch64"; ARCH="aarch64" ;;
  *) echo "error: unsupported architecture '${ARCH}'" >&2; exit 1 ;;
esac

# --- Workspace -------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

APPDIR="${WORK_DIR}/AppDir"
mkdir -p "${APPDIR}/usr"

echo ":: Assembling AppDir from ${ZIG_OUT}"
# Copy the whole prefix into usr/ (bin + share, incl. installed desktop file,
# hicolor icons, terminfo, manpages, shell integration, etc.).
cp -R "${ZIG_OUT}/bin"   "${APPDIR}/usr/bin"
cp -R "${ZIG_OUT}/share" "${APPDIR}/usr/share"

# Install the `sarvterminal` CLI name as a symlink to the real `ghostty`
# binary (internal app id stays com.mitchellh.ghostty on purpose).
ln -sf ghostty "${APPDIR}/usr/bin/sarvterminal"

# --- Desktop entry ---------------------------------------------------------

# Use our Sarv-branded entry (Name=Sarv Terminal, Exec=sarvterminal). It must
# live in usr/share/applications AND at the AppDir root for linuxdeploy.
DESKTOP_SRC="${REPO_ROOT}/dist/linux/sarvterminal.desktop"
install -Dm644 "${DESKTOP_SRC}" "${APPDIR}/usr/share/applications/sarvterminal.desktop"

# --- Icon ------------------------------------------------------------------

# The .desktop references Icon=sarvterminal, so ship a matching icon name.
# Prefer the hicolor icons the build already installed; fall back to
# assets/logo.png; else emit a placeholder so linuxdeploy still succeeds.
ICON_DEST_DIR="${APPDIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${ICON_DEST_DIR}"

if [ -f "${APPDIR}/usr/share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png" ]; then
  # Re-name the installed hicolor icons to the `sarvterminal` icon name across
  # every size so the theme lookup for Icon=sarvterminal resolves.
  while IFS= read -r -d '' src; do
    dst="${src%/com.mitchellh.ghostty.png}/sarvterminal.png"
    cp -f "${src}" "${dst}"
  done < <(find "${APPDIR}/usr/share/icons/hicolor" -name 'com.mitchellh.ghostty.png' -print0)
  ICON_SRC="${APPDIR}/usr/share/icons/hicolor/256x256/apps/sarvterminal.png"
elif [ -f "${REPO_ROOT}/assets/logo.png" ]; then
  ICON_SRC="${ICON_DEST_DIR}/sarvterminal.png"
  cp -f "${REPO_ROOT}/assets/logo.png" "${ICON_SRC}"
else
  echo ":: WARNING: no icon found (looked for installed hicolor icons and" >&2
  echo "   assets/logo.png). Writing a 1x1 placeholder; replace before shipping." >&2
  ICON_SRC="${ICON_DEST_DIR}/sarvterminal.png"
  # Minimal valid 1x1 transparent PNG (base64) as a placeholder.
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' \
    | base64 -d > "${ICON_SRC}"
fi

# linuxdeploy expects a top-level icon + desktop file in the AppDir root.
cp -f "${ICON_SRC}" "${APPDIR}/sarvterminal.png"
cp -f "${DESKTOP_SRC}" "${APPDIR}/sarvterminal.desktop"

# --- Fetch linuxdeploy + GTK plugin ---------------------------------------

TOOLS_DIR="${WORK_DIR}/tools"
mkdir -p "${TOOLS_DIR}"

LD_BASE="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous"
LD_GTK_BASE="https://github.com/linuxdeploy/linuxdeploy-plugin-gtk/releases/download/continuous"

LINUXDEPLOY="${TOOLS_DIR}/linuxdeploy-${LD_ARCH}.AppImage"
LINUXDEPLOY_GTK="${TOOLS_DIR}/linuxdeploy-plugin-gtk.sh"

echo ":: Downloading linuxdeploy (${LD_ARCH})"
curl -fsSL "${LD_BASE}/linuxdeploy-${LD_ARCH}.AppImage" -o "${LINUXDEPLOY}"
chmod +x "${LINUXDEPLOY}"

echo ":: Downloading linuxdeploy-plugin-gtk"
curl -fsSL "${LD_GTK_BASE}/linuxdeploy-plugin-gtk.sh" -o "${LINUXDEPLOY_GTK}"
chmod +x "${LINUXDEPLOY_GTK}"

# Let linuxdeploy find the plugin.
export PATH="${TOOLS_DIR}:${PATH}"
# Run AppImages without FUSE (works in CI/containers).
export APPIMAGE_EXTRACT_AND_RUN=1
# Name of the produced artifact.
export OUTPUT="SarvTerminal-${VERSION}-${ARCH}.AppImage"
# linuxdeploy-plugin-gtk uses this to set GTK-related env in the AppRun.
export DEPLOY_GTK_VERSION=4

echo ":: Running linuxdeploy -> ${OUTPUT}"
"${LINUXDEPLOY}" \
  --appdir "${APPDIR}" \
  --plugin gtk \
  --desktop-file "${APPDIR}/sarvterminal.desktop" \
  --icon-file "${APPDIR}/sarvterminal.png" \
  --output appimage

echo ":: Done: ${PWD}/${OUTPUT}"
