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

## Package managers (Homebrew, etc.)

There is no Homebrew cask or other package-manager distribution yet — it's on
the [roadmap](README.md#roadmap--status), and contributions to set up that
pipeline are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
