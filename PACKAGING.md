# Packaging Sarv Terminal for Distribution

Sarv Terminal is currently distributed as a **signed and notarized macOS app**
via [GitHub Releases](https://github.com/Sarv/SarvTerminal/releases).

## Official releases

Official builds are produced by maintainers with:

```sh
./scripts/release.sh
```

This performs a Release (`ReleaseFast`) build, signs the app inside-out with a
Developer ID certificate, notarizes it with Apple, and staples the ticket —
so the app opens cleanly on any Mac without Gatekeeper warnings.

> [!IMPORTANT]
> Never distribute a debug build. Debug builds use a different bundle id
> (`com.sarv.terminal.debug`), a different icon, and are not signed for
> distribution. Always use `scripts/release.sh` for anything you plan to ship.

## Building from source

If you want to build your own copy, see the
[Build from source](README.md#build-from-source) section of the README and
[HACKING.md](HACKING.md) for the details. The short version:

```sh
git clone https://github.com/Sarv/SarvTerminal.git
cd SarvTerminal
zig build -Doptimize=ReleaseFast
```

The required Zig version is pinned by `minimum_zig_version` in
[`build.zig.zon`](build.zig.zon).

## Linux artifacts (AppImage, .deb, .rpm, Arch)

Sarv Terminal can be packaged for the major Linux distributions. All artifacts
install the binary as `ghostty` plus a user-facing `sarvterminal` symlink, and
present the app as **Sarv Terminal** via a branded `.desktop` entry. The
internal application id stays `com.mitchellh.ghostty` (renaming it is out of
scope).

The assets live in [`packaging/`](packaging/) — see
[`packaging/README.md`](packaging/README.md) for full build steps. In short,
build a prefix once:

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out
```

then produce the artifact you need:

| Distro / need                  | Artifact | How |
| ------------------------------ | -------- | --- |
| Any distro (portable)          | AppImage | `packaging/build-appimage.sh` |
| Debian / Ubuntu                | `.deb`   | `nfpm pkg --config packaging/nfpm.yaml --packager deb` |
| Fedora / RHEL / openSUSE       | `.rpm`   | `nfpm pkg --config packaging/nfpm.yaml --packager rpm` |
| Arch / Manjaro                 | pkg      | `makepkg -si` with [`packaging/PKGBUILD`](packaging/PKGBUILD) |

The **AppImage** is the "runs on any distro" portable option and needs no
system packages installed.

The existing per-arch tarball release
([`.github/workflows/linux-release.yml`](.github/workflows/linux-release.yml))
remains the from-tarball install path.

## Package managers (Homebrew, etc.)

There is no Homebrew cask yet — it's on the
[roadmap](README.md#roadmap--status), and contributions to set up that pipeline
are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
