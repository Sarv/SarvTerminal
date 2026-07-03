# Developing Sarv Terminal

This document describes the technical details behind Sarv Terminal's
development. If you'd like to open a pull request or implement a new feature,
please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Requirements

- **macOS** (the app is currently macOS-only — see the
  [roadmap](README.md#roadmap--status) for the Linux UI effort)
- **[Zig](https://ziglang.org/)** — version `0.15.2` or newer (see
  `minimum_zig_version` in [`build.zig.zon`](build.zig.zon))
- **Xcode** with the macOS SDK and Metal Toolchain installed

If the wrong Xcode is selected, point `xcode-select` at the right one:

```shell
sudo xcode-select --switch /Applications/Xcode.app
```

## Getting started

```shell
git clone https://github.com/Sarv/SarvTerminal.git
cd SarvTerminal
zig build
open "zig-out/Sarv Terminal.app"
```

`zig build` without any `-Doptimize` flags produces a **debug** build — that's
what you want while developing.

## Build & test commands

| Command                              | Description                                                          |
| ------------------------------------ | -------------------------------------------------------------------- |
| `zig build`                          | Builds the macOS app bundle (debug)                                  |
| `zig build -Demit-macos-app=false`   | Builds only the core (skips the app bundle — much faster iteration)  |
| `zig build test`                     | Runs the Zig unit tests                                              |
| `zig build test -Dtest-filter=<t>`   | Runs only tests matching `<t>` (the full suite is slow — prefer this) |
| `./scripts/dev.sh`                   | Builds the debug app and (re)launches it as **Sarv Terminal Dev**    |
| `./scripts/release.sh`               | Maintainer script: Release build, Developer ID signing, notarization |

### The dev app

`./scripts/dev.sh` is the everyday development loop. It builds the debug app,
copies it to `/tmp/SarvTerminal_Dev.app`, and relaunches it. The dev app uses
its own bundle id (`com.sarv.terminal.debug`) and its own data directory
(`~/.config/sarvterminal-dev`), so it never collides with a release install in
`/Applications`.

## Directory structure

- `src/` — shared Zig core (terminal engine, config, rendering)
- `macos/` — the macOS app (SwiftUI): Vaults, SFTP, Keychain, Port Forwarding,
  Snippets, Sync, and the rest of the Sarv Terminal layer
- `src/apprt/gtk/` — GTK app runtime (Linux/FreeBSD; engine-level, no Sarv
  Terminal UI yet)
- `assets/` — logo and README screenshots
- `scripts/` — `dev.sh` (debug loop) and `release.sh` (signed releases)

## libghostty-vt (terminal emulation library)

The core VT emulation can be built as a standalone library:

- Build: `zig build -Demit-lib-vt`
- WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`

All C enums in `include/ghostty/vt/` must end with a
`_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` sentinel to force int enum sizing
(pre-C23 portability).

## Logging

On macOS, logs go to the unified log by default. View them with:

```shell
sudo log stream --level debug --predicate 'subsystem=="com.sarv.terminal"'
```

(Use `com.sarv.terminal.debug` for the dev app.)

Debug builds also log to `stderr`. The `GHOSTTY_LOG` environment variable
(an engine-level setting) controls destinations: `stderr`, `macos`, combined
with commas, `no-` prefix to disable, `true`/`false` for all/none.

## Formatting & linting

Run these before committing:

| Language   | Command                          |
| ---------- | -------------------------------- |
| Zig        | `zig fmt .`                      |
| Swift      | `swiftlint lint --strict --fix`  |
| Everything else (Markdown, YAML, …) | `prettier -w .` |

## Testing your changes

1. Build and relaunch the dev app: `./scripts/dev.sh`
2. Run targeted Zig tests: `zig build test -Dtest-filter=<name>`
3. Make sure the app launches and the feature you touched works end to end
   (connect to a host, transfer a file, etc. as relevant).
