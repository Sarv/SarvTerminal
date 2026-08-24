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
| **Current min zig** | **0.16.0** (since upstream `e8525c0fd`) |
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
| →74d0c72f | `src/terminal/Terminal.zig` | clean 3-way | resize rework (`89b103dd5`) + cursor defaults moved into terminal state (`c594031d5`) |
| →74d0c72f | `src/terminal/Screen.zig` | clean 3-way | safe resize-failure paths (`a3c1caba5`, `dde3d4d6b`) |
| →74d0c72f | `src/terminal/PageList.zig` | clean 3-way | page-capacity error handling in `cursorScrollAbove`/`eraseRow` (`043326249`, `ee9d5b352`) |
| →74d0c72f | `src/terminal/stream_terminal.zig` | clean 3-way | semantic stream failure marking (`439d35e27`) |
| →74d0c72f | `src/terminal/c/terminal.zig` | clean 3-way | libghostty-vt resize/cursor API follow-through |
| →74d0c72f | `src/terminal/kitty/graphics_{command,image,storage}.zig` | clean 3-way | transient usage hints (`a65e11cc9`) |
| →74d0c72f | `src/config/Config.zig` | clean 3-way | `background-blur` default change (`2da02f4d2`); our fields preserved |
| →74d0c72f | `src/crash/dir.zig` | clean 3-way | §8.4 `sarvterminal/crash` preserved |
| →74d0c72f | `src/termio/{Termio,stream_handler}.zig` | clean 3-way | resize/stream plumbing |
| →74d0c72f | `include/ghostty/vt/terminal.h` | clean 3-way | C API for the resize rework |
| →74d0c72f | `build.zig.zon{,.json,.nix,.txt}`, `flatpak/zig-packages.json` | clean 3-way | iTerm2 colorschemes bump (`b513f1b20`); md4c dep + zig 0.15.2 preserved |
| →42a161aa | 96 guarded files | clean 3-way | no manual intervention needed |
| →42a161aa | `src/crash/dir.zig` | **re-applied** | upstream changed the signature to `(io, alloc, environ_map)`; kept `sarvterminal/crash` |
| →42a161aa | `src/crash/sentry.zig` | **re-applied at new site** | upstream moved cache-dir resolution into a helper; re-applied `sarvterminal/sentry` + `.sarvcrash` there |
| →42a161aa | `src/cli/ssh.zig`, `src/cli/ssh_cache.zig` | **re-applied at new site** | upstream refactored cache setup and re-hardcoded `"ghostty"`; restored `DiskCache.default_program` |
| →42a161aa | `src/config/url.zig` | ours + restore | kept our two-tier path regex; upstream deleted `trailing_spaces_at_eol`, so its definition and the 2 test expectations were restored |
| →42a161aa | `src/config/Config.zig` | kept both | our `output-colorize` + upstream's new `link-osc8` |
| →42a161aa | `include/ghostty.h`, `src/apprt/action.zig` | kept both | our `reopen_closed_tab` + upstream's `move_tab_to_new_window` |
| →42a161aa | `src/Surface.zig` | ours + 0.16 API | upstream's `lockUncancelable(global.io())` combined with our `reset_tty` and `linkAtPos(pos, false)` |
| →42a161aa | `src/build/GhosttyXcodebuild.zig` | ours + 0.16 API | upstream's `b.graph.environ_map`; kept `Sarv Terminal.app` |
| →42a161aa | `macos/…/Ghostty.Config.swift` | ours | kept `AppPaths.terminalCustomIconFile`; dropped the now-dead `#if os(macOS)` (see note below) |
| →42a161aa | `macos/…/URLHoverBanner.swift` | ours | upstream added its own URL-preview banner; we keep the "⌘ click to open" hint (§8.5) |
| →42a161aa | `macos/…/SurfaceView.swift`, `OSSurfaceView.swift` | ours | kept `showScrollToBottom` and the grep-filter state |
| →42a161aa | `macos/…/Update/{UpdateDelegate,UpdateDriver,UpdatePopoverView}.swift` | ours | kept our SarvAlert-based update prompts |
| →42a161aa | `macos/Ghostty.xcodeproj/project.pbxproj` | theirs | completed upstream's **iOS target removal**; validated with `plutil -lint`, 0 dangling iOS refs |
| →42a161aa | `HACKING.md`, `PACKAGING.md`, `po/README_TRANSLATORS.md` | ours | our fork rewrites; upstream's versions reintroduce ghostty-org clone URLs and GitHub teams |
| →42a161aa | `.gitignore` | kept both | then deduped |
| →42a161aa | 4 guarded renames | `git mv` + clean 3-way | `macos/Sources/App/macOS/{AppDelegate,AppDelegate+Ghostty,main}.swift`, `MainMenu.xib` → `macos/Sources/App/` |
| →42a161aa | `pkg/md4c/build.zig`, `src/build/SharedDeps.zig` (ours) | **zig 0.16 migration** | `link_libc` is a module option; `linkLibrary`/`addIncludePath`/`addCSourceFiles` moved to `root_module` |
| →42a161aa | `src/main_c.zig` (ours) | **zig 0.16 migration** | `state.alloc` → `global.alloc()` |
| →42a161aa | `macos/…/VaultsTabsModel.swift` (ours) | **API migration** | upstream replaced the `confirmClipboard` notification + userInfo keys with a one-shot `Ghostty.ClipboardConfirmationRequest` published on the surface; we now subscribe per-surface and call `complete()`/`cancel()` |
| →42a161aa | `macos/…/UpdatePopoverView.swift` (ours) | **API migration** | `UpdateState.Installing.dismiss()` removed upstream; "Restart Later" just closes |
| →42a161aa | `macos/…/SurfaceSearchFilter.swift` (ours) | **API migration** | `SearchState.needle` is now a `Needle` struct → `.needle.text` |
| →42a161aa | `macos/…/SurfaceView.swift` (ours) | **API migration** | `OSColor` alias removed with iOS support → `NSColor` |
| →42a161aa | 5 stale unowned files | **fast-forwarded (pre-existing gap)** | `images/Ghostty.icon/icon.json`, `macos/…/App Intents/{Entities/TerminalEntity,NewTerminalIntent,QuickTerminalIntent}.swift`, `macos/…/TitlebarTabsTahoeTerminalWindow.swift` — stale since BEFORE this sync (see §9) |
| →42a161aa | `macos/Sources/App/AppDelegate.swift` | **completed the merge** | the clean 3-way brought upstream's `quickTerminalControllerState` machine but dropped the `quickControllerInitialized` computed property beside it; restored (upstream's `QuickTerminalIntent` needs it) |

---

## 7. Sync state

Update this section every time you reconcile.

| | |
|---|---|
| Upstream base (fork point) | `b831ef6b` (ghostty 1.3.2-dev) |
| **Reconciled up to** | `42a161aad` (2026-08-21 on branch `chore/upstream-sync-1.4.x`) |
| Upstream tip at last check | `42a161aad` (**fully reconciled**) |
| Last checked | 2026-08-21 |

Sync of 2026-07-13: 114 untouched files fast-forwarded to `55a3e33a`; 6 owned files
3-way merged cleanly (see §6); 8 files we'd deleted left deleted; one build fix in
our `colorize.zig` for the new `PageList.Node` union. zig core + full macOS app both
build; new upstream option `scrollback-compression` added to Settings → General
(`gtk-horizontal-tab-scroll` skipped — GTK/Linux only).

Sync of 2026-08-21 (`55a3e33a` → `74d0c72fd`, 24 commits): **deliberately stopped one
commit short of upstream `e8525c0fd` ("Update to Zig 0.16.0")** so the tree still builds
with zig 0.15.2. 31 files changed: 1 untouched file fast-forwarded, 12 `.github`
workflow files we'd deleted left deleted, and 18 owned files 3-way merged — **all clean,
zero conflicts** (see §6). Content is mostly terminal resize robustness and page-capacity
error handling, plus kitty transient image hints and a macOS hidden-titlebar
`NSScrollPocket` fix. All §8 anchors in range verified intact (`sarvterminal/crash`,
`sarvterminal/themes`, `default_program`, `com.sarv.terminal`, md4c dep,
`hover_activate_mods`). Verification: `zig build -Demit-macos-app=false` passes;
`zig build test` = **3074/3090 passed, 16 skipped, 0 test failures**. The one failing
build step, `xcodebuild test`, is **pre-existing and unrelated** — `project.pbxproj`
(untouched by this sync) sets `TEST_HOST` to `SarvTerminal.app/…/ghostty`, but our
executables are `SarvTerminalDev` (Debug) / `SarvTerminal` (Release) and the bundle is
`Sarv Terminal.app`; the same broken setting is present on `main`. **Next base for the
following sync is `74d0c72fd`, and that sync MUST begin with the zig 0.16.0 migration**
— upstream's 499 post-bump commits migrated upstream files only; our ~227 added files
need migrating by us.

Sync of 2026-08-21, stage 2 (`74d0c72fd` → `42a161aad`, 499 commits): **crosses upstream
`e8525c0fd` "Update to Zig 0.16.0"**, so the tree now requires zig 0.16.0. 687 files net
(93 A / 16 D / 573 M / 5 R): 537 untouched files fast-forwarded, 14 upstream deletions
applied, 12 `.github` workflows we'd deleted left deleted, and 119 owned files 3-way
merged — 96 clean, 23 resolved by hand (see §6). The 4 guarded renames were handled as
`git mv` + 3-way and all merged clean.

**Upstream dropped iOS entirely.** `macos/Sources/App/iOS/` is gone, the `Ghostty-iOS`
target was removed from `project.pbxproj`, and every `#if os(macOS)` / `#if canImport(AppKit)`
platform guard was deleted (upstream tip has 0 of each). Two of our files kept a guard
whose `#endif` upstream had removed, leaving them unbalanced — both guards were dropped to
follow upstream. Watch for this pattern in any future Swift merge.

**Zig 0.16 migration of our own files was small** — upstream migrated only upstream files,
but our added code is mostly Swift, so only 4 Zig sites needed work (`pkg/md4c/build.zig`,
`src/build/SharedDeps.zig`, `src/main_c.zig`, `src/Surface.zig`) plus 4 Swift API
migrations (see §6). Key 0.16 idioms: `link_libc` is a `createModule` option and
`Compile.linkLibC()` is gone; `linkLibrary`/`addIncludePath`/`addCSourceFiles` live on
`root_module`; `renderer_state.mutex` is `lockUncancelable(global.io())` / `unlock(global.io())`;
error formatting is `{t}`; `xdg.state`/`xdg.cache` take `(io, alloc, environ_map, …)`.

Verification: `zig build` (core **and** the full macOS app) succeeds on zig 0.16.0 and
produces `zig-out/Sarv Terminal.app`; `zig build test` = **3463/3480 passed, 17 skipped,
0 failures**. All §8 anchors re-verified. The single failing build step, `xcodebuild test`,
is the **same pre-existing failure as before this sync** — `project.pbxproj` sets
`TEST_HOST` to `SarvTerminal.app/…/ghostty`, but our executables are `SarvTerminalDev`
(Debug) / `SarvTerminal` (Release) and the bundle is `Sarv Terminal.app`. It fails
identically on `main` and is unrelated to the merge; it deserves its own fix commit.

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

### 8.5 In-app Markdown viewer + openable file-path links (core divergence)
- **Why:** open `.md` files in an in-app viewer (rendered + editable source) and
  make file paths in terminal output discoverable/clickable, without holding ⌘ to
  even see them.
- **What we do & anchors to preserve:**
  - `pkg/md4c/` + `build.zig.zon` + `src/build/SharedDeps.zig` — vendor md4c and
    link it into the core (see [[third-party-c-libs-in-pkg]] pattern).
  - `src/markdown.zig`, `src/main_c.zig`, `include/ghostty.h` — the
    `ghostty_markdown_to_html` C API (GFM, raw-HTML-escaped). **Guarded** (main_c.zig,
    ghostty.h).
  - `src/config/url.zig` — **guarded.** Added a 4th regex branch for bare openable
    filenames (`README.md`) and split `regex` into `url_regex` + `path_regex`.
  - `src/config/Config.zig` — **guarded.** Two default links: URLs (`hover_mods`)
    and file paths (`hover_activate_mods`).
  - `src/input/Link.zig` — **guarded.** New `Highlight.hover_activate_mods` =
    highlight on plain hover, activate only with mods.
  - `src/Surface.zig` — **guarded.** `linkAtPos`/`linkAtPin` gained a
    `for_activation` param; the mouse-leave path now clears the renderer hover
    highlight (`hyperlink_hover` dirty + reset `mouse.point`/`over_link`).
  - `src/renderer/link.zig` — **guarded.** `hover_activate_mods` draws like `hover`.
  - macOS UI (ours): `MarkdownHTML.swift` (md4c-backed), `Ghostty.App.swift`
    (`openURL` routes local `.md` to the viewer), `URLHoverBanner.swift` +
    `SurfaceView.swift` (cursor-adjacent "⌘ click to open" hint).

### 8.6 Scrollback limits readable by the settings UI + 500 MB default (core divergence)
- **Why:** two problems. (1) `Limit(usize, …)` (added upstream in 1.4 when
  `scrollback-limit` split into `scrollback-limit-bytes` / `-lines`) is a
  non-packed struct, and `c_get` rejects those — so every C-API reader, i.e. our
  macOS settings UI, silently fell back to its own hardcoded default and could
  never show or round-trip the real value. (2) Upstream's 50 MB default is about
  48k lines at 120 columns (page memory runs ~1 KB/line); SarvTerminal is
  SSH-first and log-heavy, where that truncates a normal session.
- **What we do & anchors to preserve:**
  - `src/config/limit.zig` — **guarded.** `Limit.cval` returns the raw value so
    `c_get`'s struct branch accepts it; `unlimited` surfaces as `maxInt(T)`, the
    same sentinel Zig uses. Without this the settings UI silently lies.
  - `src/config/Config.zig` — **guarded.** `scrollback-limit-bytes` defaults to
    **500 MB**, not upstream's 50 MB (doc comment carries the reasoning). Two
    tests in the same file assert the default; they move with it.
  - `src/config/CApi.zig` — **guarded.** `test "ghostty_config_get: scrollback
    limits"` is the regression guard for the `cval` path; it fails if an upstream
    refactor drops `cval` or changes the default.
  - macOS UI (ours): `ScrollbackLimit.swift` (pure helpers: `UInt.max` sentinel,
    `unlimited` serialization, presets, labels — `defaultBytes` MUST match the Zig
    default), plus the Buffer size / Line limit pickers in `GeneralSectionView.swift`,
    the diff in `SettingsView.swift` (writes the new keys and `remove`s the
    pre-1.4 `scrollback-limit` alias), and `SettingsConfigExtensions.swift`.
- **Measured, for future reference:** page memory is ~1 KB/line at 120 cols
  regardless of content; `scrollback-compression` takes historical pages to ~6% of
  raw on realistic text; `unlimited` maps ~3 GB for a 3M-line flood (macOS jetsams
  the app rather than trimming). Keep `unlimited` opt-in only.

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

---

## 9. Completeness audit (added 2026-08-21)

After the stage-2 sync, a full tree-vs-upstream audit found **5 files we do not own that
were still on older upstream content**. They were **not** introduced by this sync — they
predate it, and neither the 2026-07-13 sync nor stage 1/2 would have caught them, because
upstream never modified them inside the reconciled ranges.

**Root cause:** §1 states the baseline snapshot is byte-identical to `b831ef6b` for
`src/`, `include/`, and `pkg/` — **that claim was never verified for `macos/`, `images/`,
or the repo root**. The baseline import differs from `b831ef6b` in those trees, so any file
there that upstream changed *before* our recorded fork point stays stale forever: it never
appears in a `FROM..TO` diff.

The 5 were pure upstream evolution with no SarvTerminal customization (an async
`TerminalEntity(view:)` initializer, `"glass": false` icon keys), so they were replaced
verbatim per §3. One follow-on was needed: upstream's `QuickTerminalIntent` calls
`AppDelegate.quickControllerInitialized`, which a clean 3-way had silently dropped from our
guarded `AppDelegate.swift` (it kept the `quickTerminalControllerState` machine but not the
computed property). That is the general hazard of a *clean* 3-way on a heavily-diverged
file: it can drop an upstream addition without ever reporting a conflict.

**Run this audit at the end of every sync** — it is the only check that catches both
failure modes (missed fast-forwards and silently-dropped additions):

```sh
TO=<the upstream SHA you reconciled to>
BASE=18b6f57

# Every path that differs between upstream's tree and our working tree
git diff --name-only "$TO" | sort > /tmp/diff_vs_up.txt
# Everything we legitimately own
git diff --diff-filter=AM --name-only "$BASE" HEAD | sort > /tmp/owned.txt
git diff --diff-filter=D  --name-only "$BASE" HEAD | sort > /tmp/deleted.txt

# Anything left is a MISSED merge (expect only guarded renames + our own new files)
comm -23 /tmp/diff_vs_up.txt /tmp/owned.txt | comm -23 - /tmp/deleted.txt
```

Expected residue after a complete sync: the guarded renames (they live at new paths, so the
baseline diff cannot see them) and our own added-but-uncommitted files. Anything else is a
real gap. Note this audit only proves *content* parity — it cannot prove a hand-merge was
*semantically* right, so guarded files still need the §8 anchor checks and a build.
