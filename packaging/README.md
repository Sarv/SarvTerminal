# Linux packaging

This directory holds the assets for building installable Linux artifacts for
**Sarv Terminal** (a Ghostty fork).

## What gets installed

Every artifact installs the same layout:

- the binary at `/usr/bin/ghostty` (the internal application id stays
  `com.mitchellh.ghostty` — renaming it is intentionally out of scope);
- a `/usr/bin/sarvterminal` symlink — the user-facing CLI name;
- the Sarv-branded desktop entry
  ([`dist/linux/sarvterminal.desktop`](../dist/linux/sarvterminal.desktop)),
  which shows up as **Sarv Terminal** in app menus;
- everything the build already puts under `share/` (hicolor icons, terminfo,
  manpages, shell integration, the upstream `com.mitchellh.ghostty` desktop
  entry and dbus service).

Because the desktop entry uses `Icon=sarvterminal`, the packages also copy the
existing hicolor icon(s) under the `sarvterminal` name so the icon resolves.

## Prerequisite: build the prefix

The `.deb`, `.rpm` and AppImage flows all consume a pre-built prefix. Build it
natively on the target architecture (the GTK app links dynamically and can't be
cross-compiled without the target's system libraries):

```sh
zig build -Doptimize=ReleaseFast -Dcpu=baseline \
  -Dversion-string="$(cat VERSION)" --prefix zig-out
```

## AppImage — portable, runs on any distro

Recommended when you want a single file that works everywhere without installing
system packages.

```sh
# from the repo root, after building the prefix above
packaging/build-appimage.sh              # uses ./zig-out
packaging/build-appimage.sh /path/to/zig-out
```

Produces `SarvTerminal-<version>-<arch>.AppImage`. The script fetches
`linuxdeploy` + the GTK plugin, bundles GTK4/libadwaita, and sets
`APPIMAGE_EXTRACT_AND_RUN=1` so it builds in CI/containers without FUSE. (FUSE
is still needed on the end-user machine to *run* an AppImage, or they can run it
with `--appimage-extract-and-run`.)

## `.deb` / `.rpm` — Debian/Ubuntu and Fedora/RHEL

Uses [nfpm](https://nfpm.goreleaser.com). Install nfpm, build the prefix, then:

```sh
export VERSION="$(cat VERSION)"
export GOARCH=amd64        # or arm64
mkdir -p dist

nfpm pkg --config packaging/nfpm.yaml --packager deb --target ./dist
nfpm pkg --config packaging/nfpm.yaml --packager rpm --target ./dist
```

Dependency names differ per family and are declared under `overrides:` in
`nfpm.yaml` (Debian `libgtk-4-1` vs Fedora `gtk4`, etc.).

## Arch Linux — build from source

Uses the [`PKGBUILD`](PKGBUILD). It compiles from a tagged source tarball with
Zig:

```sh
cd packaging
makepkg -si
```

Keep `pkgver` in sync with the repo `VERSION`. For AUR publishing, replace the
`SKIP` in `sha256sums` with the real checksum (or switch `source` to a
`git+...#tag=` VCS source).

## Which artifact for which distro

| Distro / need                     | Recommended artifact |
| --------------------------------- | -------------------- |
| Debian, Ubuntu, Mint, Pop!_OS     | `.deb`               |
| Fedora, RHEL, openSUSE            | `.rpm`               |
| Arch, Manjaro, EndeavourOS        | `PKGBUILD` / AUR     |
| Anything else / no root / testing | AppImage (portable)  |

## Notes for the integrator (verify before shipping)

- **Icon:** packages reuse the app's installed `com.mitchellh.ghostty` hicolor
  icons under the `sarvterminal` name. If you want a distinct Sarv logo, drop
  proper multi-size PNGs and adjust the copy steps. The AppImage script falls
  back to `assets/logo.png`, then to a 1x1 placeholder.
- **Dependency package names** in `nfpm.yaml` (`overrides:`) and `PKGBUILD`
  (`depends`) are best-effort for current Debian/Ubuntu and Fedora/Arch. Verify
  against your target releases — especially `gtk4-layer-shell` naming, which
  varies.
- **`conflicts: ghostty`** is set everywhere because the packages own
  `/usr/bin/ghostty` and the `com.mitchellh.ghostty` desktop/icon files.
