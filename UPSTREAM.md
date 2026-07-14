# Merging Upstream Ghostty

SarvTerminal is built on top of [ghostty](https://github.com/ghostty-org/ghostty).
This document is the single source of truth for pulling upstream improvements
into our tree **safely**, without silently clobbering our customizations.

---

## 1. Fork model (read this first)

We are a **snapshot fork**, not a full-history fork. Ghostty's entire tree was
imported as one squashed commit; we do **not** carry upstream's commit history.

| | |
|---|---|
| Local baseline snapshot commit | `18b6f57` ("Initial commit") — pristine ghostty |
| Ghostty version at baseline | **1.3.2-dev** (min zig 0.15.2) |
| **Corresponding upstream commit** | **`b831ef6b`** (`ghostty-org/ghostty`) |
| Upstream remote | `https://github.com/ghostty-org/ghostty.git` |

`b831ef6b` is the **newest** upstream commit whose `src/`, `include/`, and
`pkg/` trees are byte-identical to our baseline — so it is the exact point from
which upstream changes must be applied. (Verified: those three trees match
`18b6f57` exactly.)

### Where we diverged
Relative to the baseline, our tree contains:

- **227 added files** — our own code (all of `macos/Sources/Features/…`,
  `src/termio/colorize.zig`, docs, assets). Upstream does not have these, so they
  **can never conflict**.
- **23 deleted files** — upstream CI/community files we removed. Keep removed.
- **61 modified files** — **the conflict-guard set** (see §2). Upstream is the
  origin of these files *and* we changed them, so an upstream change to any of
  them must be merged **by hand**.

We changed mostly the **Swift / macOS** side, but also **12 core files**
(11 `.zig` + 1 `.h`):

```
include/ghostty.h                       src/input/Binding.zig
src/Surface.zig                         src/input/command.zig
src/apprt/action.zig                    src/input/paste.zig
src/apprt/gtk/class/application.zig     src/termio/Exec.zig
src/build/GhosttyXcodebuild.zig         src/termio/Termio.zig
src/config/Config.zig                   src/termio/colorize.zig   (NEW — ours)
```

---

## 2. The "files we own" set (conflict-guard) — always compute, never hardcode

This set grows as we add features, and some paths contain spaces, so **derive it
live** rather than trusting a static list:

```sh
BASE=18b6f57   # pristine ghostty baseline

# Files we MODIFIED → upstream changes here need MANUAL merge (halt).
git diff --diff-filter=M --name-only "$BASE" HEAD

# Files we ADDED → ours; upstream can't touch them (safe).
git diff --diff-filter=A --name-only "$BASE" HEAD

# Files we DELETED → keep deleted; if upstream changes them, decide manually.
git diff --diff-filter=D --name-only "$BASE" HEAD
```

**Rule:** a file is "ours" (guarded) if it appears in the **M** or **D** lists.
Any upstream commit that changes an M/D file is a **manual** merge.

---

## 3. The merge rule (commit-by-commit)

Go through new upstream commits **in chronological order**, one at a time. For
each commit, look at the files it changes:

1. **File we never touched** (not in the M/D set) → **replace** our copy with the
   upstream version verbatim. We changed nothing there, so this is a safe
   fast-forward of that file. Advance that file's "synced-up-to" marker to this
   commit.
2. **File in our conflict-guard set** (M or D) → **STOP. Do not merge
   automatically.** Record it in the Conflict Log (§6) and wait for human input
   before touching it.

Because untouched files are just replaced, the next time the same file changes
upstream (and we still haven't touched it) it merges trivially again. Only our
guarded files ever require thought.

> Never run `git merge upstream/main`. That would try to merge all 200+ commits
> at once and bury our changes in mass conflicts. We advance deliberately,
> file-by-file, commit-by-commit.

---

## 4. One-time setup

```sh
git remote add upstream https://github.com/ghostty-org/ghostty.git 2>/dev/null \
  || git remote set-url upstream https://github.com/ghostty-org/ghostty.git
# Blobless keeps it fast; drop --filter for a full mirror if you prefer.
git fetch --filter=blob:none --no-tags upstream main
```

---

## 5. Procedure (each sync session)

Work on a branch, never directly on `main` (which is protected):

```sh
git switch -c chore/upstream-sync
git fetch upstream main

FROM=<RECONCILED_UP_TO>        # from §7 below; start at b831ef6b
TO=upstream/main               # or a specific SHA you want to stop at

# The commits to process, oldest first:
git rev-list --reverse --no-merges "$FROM..$TO"
```

For each commit `C` in that list:

```sh
# Files this upstream commit changes:
git diff-tree --no-commit-id --name-only -r "$C"
```

Split them against the conflict-guard set (§2):

- **Not guarded** → `git checkout "$C" -- <path>` (replace with upstream), then
  `git add <path>`.
- **Guarded (M/D)** → stop; log in §6; port the change by hand or ask the user.

A skeleton that automates the safe half and halts on the rest:

```sh
BASE=18b6f57
mapfile -t OURS < <(git diff --diff-filter=MD --name-only "$BASE" HEAD)
is_ours() { local f; for f in "${OURS[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

for C in $(git rev-list --reverse --no-merges "$FROM..$TO"); do
  conflict=0
  while IFS= read -r f; do
    if is_ours "$f"; then
      echo "HALT  $C  touches guarded file: $f"; conflict=1
    else
      git checkout "$C" -- "$f" 2>/dev/null && git add "$f"
    fi
  done < <(git diff-tree --no-commit-id --name-only -r "$C")
  [ "$conflict" -eq 1 ] && { echo "Stopping at $C — resolve, then continue."; break; }
done
```

After a clean run: build (`zig build -Demit-macos-app=false`, then the app),
`zig build test`, sanity-check, commit, update §7, open a PR.

---

## 6. Conflict log (files that needed a manual merge)

Record every guarded-file collision so the reconciliation is auditable.

| Sync | File | Resolution | Notes |
|---|---|---|---|
| →55a3e33a | `src/config/Config.zig` | clean 3-way | pulled scrollback-compression + gtk-horizontal-tab-scroll + color-parse refactor; our config fields preserved |
| →55a3e33a | `src/termio/Exec.zig` | clean 3-way | pulled pty-read pipelining rewrite; our +7 lines preserved |
| →55a3e33a | `macos/…/SurfaceView_AppKit.swift` | clean 3-way | pulled IME/drag-drop/retain-cycle fixes; our edits preserved |
| →55a3e33a | `src/termio/Termio.zig` | clean 3-way | color-scheme report encoder API |
| →55a3e33a | `src/Surface.zig` | clean 3-way | `node.data`→`node.page()` API |
| →55a3e33a | `src/shell-integration/…/ghostty.nu` | clean 3-way | nushell `@complete external` |
| →55a3e33a | `src/termio/colorize.zig` (ours) | **build fix** | not an upstream file, but the new `PageList.Node.Data` union broke it: `&pin.node.data` → `pin.node.page()` |

---

## 7. Sync state

Update this section every time you reconcile.

| | |
|---|---|
| Upstream base (fork point) | `b831ef6b` (ghostty 1.3.2-dev) |
| **Reconciled up to** | `55a3e33a` (merged 2026-07-13 on branch `chore/upstream-sync-1.3.x`) |
| Upstream tip at last check | `55a3e33a` |
| Last checked | 2026-07-13 |

Sync of 2026-07-13: 114 untouched files fast-forwarded to `55a3e33a`; 6 owned files
3-way merged cleanly (see §6); 8 files we'd deleted left deleted; one build fix in
our `colorize.zig` for the new `PageList.Node` union. zig core + full macOS app both
build; new upstream option `scrollback-compression` added to Settings → General
(`gtk-horizontal-tab-scroll` skipped — GTK/Linux only). **Next base for the following
sync is `55a3e33a`.**

---

## 8. Intentional divergences (must survive every upstream merge)

Some edits to Ghostty-origin files exist for a deliberate product reason. A 3-way
merge usually keeps them, but **after every sync, VERIFY each one survived** and
re-apply if an upstream refactor drops it.

### 8.1 Isolated terminal-config path (no collision with a co-installed Ghostty)
- **Why:** SarvTerminal is a Ghostty fork. If a user runs both, they must NOT share
  `~/.config/ghostty/config` — that's two writers on one file, and our sync feature
  would otherwise mutate the user's real Ghostty config.
- **What we do:** read/write our terminal config ONLY at `~/.config/sarvterminal/config`
  (release) / `~/.config/sarvterminal-dev/config` (debug), seeded once from the legacy
  `~/.config/ghostty/config`. We deliberately do NOT call `ghostty_config_load_default_files`.
- **Rename knob:** `macos/Sources/Helpers/AppIdentity.swift` — OURS. SINGLE
  source of truth for the on-disk dir names (`sarvterminal[-dev]`), the legacy
  seed dirs (`ghostty[-dev]`), and the bundle-id accessor + legacy migration
  domains. Rename the app = change these constants (plus the one mirrored Zig
  literal in `src/config/theme.zig`; see 8.2). NOTE: Keychain service names and
  UserDefaults suite names are deliberately NOT here — they are frozen storage
  keys, and rewiring them to the rename knob would orphan users' saved secrets.
- **Anchors to preserve:**
  - `macos/Sources/Helpers/AppPaths.swift` — OURS (not an upstream file → no merge
    risk). Owns `ghosttyConfigFile` (sarv dir) + `seedTerminalConfigIfNeeded`,
    plus `terminalThemesDir`/`seedTerminalThemesIfNeeded` and
    `terminalCustomIconFile` (see 8.2). All dir names come from `AppIdentity`.
  - `macos/Sources/Ghostty/Ghostty.Config.swift` — **guarded upstream file.**
    `loadUserBaseConfig(into:)` must call `ghostty_config_load_file(cfg,
    AppPaths.ghosttyConfigFile.path)` and must NOT be reverted to
    `ghostty_config_load_default_files(cfg)`. ← re-check this after every sync.
  - `macos/Sources/Ghostty/Ghostty.App.swift` — **guarded upstream file.**
    `openConfig()` must open `AppPaths.ghosttyConfigFile.path`, NOT the core's
    `ghostty_config_open_path()` (which resolves to `~/.config/ghostty/config`
    for anyone who has one). Covers both the "Open Configuration File" menu and
    the in-terminal `open_config` action.
- **No known residuals.** The SSH terminfo cache is now isolated too (see 8.3).
  The `xterm-ghostty` terminfo NAME installed on remotes stays shared (it's the
  `TERM` value — a protocol identity, not a local file), but our local cache of
  "which host already has it" is no longer shared.

### 8.2 Isolated user **themes** dir + custom-icon default (core divergence)
- **Why:** with `theme = <name>` in our config, the *core* resolves the theme file
  from a user themes dir. Leaving that at the shared `~/.config/ghostty/themes`
  meant we still read out of a co-installed Ghostty's dir. Full isolation moves it
  to `~/.config/sarvterminal/themes`.
- **What we do:** the core resolves user themes from `sarvterminal/themes`, and the
  macOS app seeds that dir once from the legacy `ghostty/themes` (copy, never move)
  so existing custom themes keep working. NOT build-split — the core hardcodes one
  path, so debug + release share `sarvterminal/themes` (themes are read-only assets).
- **Anchors to preserve:**
  - `src/config/theme.zig` — **guarded core file.** `Location.dir` for `.user`
    must join `{"sarvterminal", "themes"}`, NOT `{"ghostty", "themes"}`.
    ← re-check after every sync (upstream will show `"ghostty"`). This `"sarvterminal"`
    literal MUST equal `AppIdentity.releaseConfigDirName` on the Swift side.
  - `macos/Sources/Features/Settings/ThemePicker.swift` and
    `.../ThemePreviewPopover.swift` (`ThemeFileResolver`) — the Swift theme
    discovery/preview must read `AppPaths.terminalThemesDir`, matching the core.
  - `macos/Sources/Ghostty/Ghostty.Config.swift` — `macosCustomIcon` default is
    `AppPaths.terminalCustomIconFile.path` (`sarvterminal/Ghostty.icns`), not
    `~/.config/ghostty/Ghostty.icns`.

### 8.3 Isolated SSH terminfo cache (core divergence)
- **Why:** the bundled `+ssh` wrapper records "host X already has `xterm-ghostty`
  terminfo" in `${XDG_STATE_HOME}/<program>/ssh_cache`. Upstream keys it on
  `"ghostty"`, sharing the file with a co-installed Ghostty (and our upgrade-purge
  would delete that shared file). We key it on `"sarvterminal"` instead. The
  terminfo NAME on remotes stays `xterm-ghostty` (that's the `TERM` protocol
  value, deliberately unchanged); only the LOCAL cache path is isolated. Existing
  users' caches are NOT migrated — the cache self-heals on the next SSH, and NOT
  copying avoids dragging any stale pre-1.8 entries into the fresh cache.
- **Anchors to preserve:**
  - `src/cli/ssh-cache/DiskCache.zig` — **guarded core file.** Defines
    `pub const default_program = "sarvterminal"` (upstream has no such constant
    and hardcodes `"ghostty"`). MUST equal `AppIdentity.releaseConfigDirName`.
  - `src/cli/ssh.zig` and `src/cli/ssh_cache.zig` — **guarded core files.** Both
    `DiskCache.defaultPath(alloc, …)` calls must pass `DiskCache.default_program`,
    NOT the literal `"ghostty"`. ← re-check after every sync.
  - `macos/Sources/Helpers/AppPaths.swift` — `sshTerminfoCacheFile` uses
    `AppIdentity.releaseConfigDirName`, matching the core.

### 8.4 Core bundle id + crash dirs + selection pasteboard (core divergence)
- **Why:** the core's `build_config.bundle_id` was `com.mitchellh.ghostty`, so any
  macOS App Support/Caches path it derives (live one: the Sentry crash-DB cache,
  written every launch) landed under a dir shared with a co-installed Ghostty.
  Crash reports and the selection pasteboard were likewise ghostty-named.
- **What we do:** point them all at our own name. NOTE: this does NOT touch sync —
  the Swift Keychain service names (`com.sarv.terminal.*`) are independent hardcoded
  literals, and the macOS bundle id is set by Xcode `PRODUCT_BUNDLE_IDENTIFIER`
  (already `com.sarv.terminal`), not by this Zig constant.
- **Anchors to preserve:**
  - `src/build_config.zig` — **guarded core file.** `bundle_id = "com.sarv.terminal"`
    (upstream has `"com.mitchellh.ghostty"`). ← re-check after every sync.
  - `src/build/GhosttyI18n.zig` — **guarded core file.** `domain` must equal
    `bundle_id` (`"com.sarv.terminal"`), and `po/<domain>.pot` is renamed to match,
    so the compiled `<domain>.mo` matches the runtime `bindtextdomain(bundle_id)`
    (else core gettext strings fall back to English — only affects GTK/Linux; macOS
    doesn't call core `_()`).
  - `src/crash/dir.zig` — **guarded core file.** crash reports subdir
    `"sarvterminal/crash"`, not `"ghostty/crash"`.
  - `src/crash/sentry.zig` — **guarded core file.** XDG cache fallback subdir
    `"sarvterminal/sentry"` (macOS uses the NSCaches branch, scoped by `bundle_id`);
    crash-report file extension is `.sarvcrash`, not `.ghosttycrash`.
  - `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift` — the selection
    pasteboard is named `com.sarv.terminal.selection`, not the ghostty name.

### Upstream activity on our guarded **core** files (base → tip, at last check)

| File | Upstream commits since base |
|---|---|
| `src/config/Config.zig` | 7 |
| `src/termio/Exec.zig` | 5 |
| `src/Surface.zig` | 1 |
| `src/termio/Termio.zig` | 1 |
| `include/ghostty.h`, `src/apprt/action.zig`, `src/apprt/gtk/class/application.zig`, `src/build/GhosttyXcodebuild.zig`, `src/input/{Binding,command,paste}.zig`, `src/termio/colorize.zig` | 0 |

So the *core* hand-merge burden is small — concentrated in `Config.zig` and
`Exec.zig`. Everything else upstream is either a file we never touched (safe
replace) or a file upstream hasn't changed. The larger review surface is our
**modified macOS Swift files** (see the M list in §2), which upstream also
evolves.
