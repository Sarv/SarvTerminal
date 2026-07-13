# Testing settings sync safely (without touching your release app)

Sync is the one feature where a mistake can lose data or half-migrate a machine, so
test it against a **fresh, isolated instance** — never your daily (release) app.

Good news: the **debug build already isolates all of its data**, so it can't read or
clobber your release app's hosts, config, or preferences. You simulate a "new machine"
just by wiping the debug locations.

## Why the debug build is safe

`AppPaths` points debug builds at separate locations for every kind of data:

| Data | Release app | Debug ("Sarv Terminal Dev") build |
|---|---|---|
| Terminal config | `~/.config/sarvterminal/config` | `~/.config/sarvterminal-dev/config` |
| App data (hosts, groups, snippets, port-forwards, sync assets) | `~/.config/sarvterminal` | `~/.config/sarvterminal-dev` |
| App preferences (`UserDefaults`) | `com.sarv.terminal` domain | `com.sarv.terminal.debug` domain |

So the debug build **cannot touch your real data** — the isolation is built in.

> **Note:** the terminal config now lives **inside** the app-data dir (`…/config`).
> SarvTerminal no longer uses the shared `~/.config/ghostty/config`, so it never
> collides with a co-installed Ghostty — and the whole debug instance is one dir
> (`~/.config/sarvterminal-dev`). The sync feature reads/writes this same isolated
> file, so a sync pull can never overwrite a real Ghostty install's config.

## Build & launch the debug build

```sh
./scripts/dev.sh
```

This builds **Sarv Terminal Dev** to `/tmp/SarvTerminal_Dev.app` and launches it
(distinct name, icon, and bundle id so it never collides with the release app).

## ⚠️ One gotcha: the config is re-seeded from your existing config

When `~/.config/sarvterminal-dev/config` is **missing**, the debug build **seeds it on
launch** — copying the first that exists of: an old `~/.config/ghostty-dev/config`, your
release `~/.config/sarvterminal/config`, or the legacy `~/.config/ghostty/config` — so the
dev build starts usable. That means a plain `rm -rf ~/.config/sarvterminal-dev` does **not**
give you a blank terminal config — it gets re-seeded (you'll see your real theme/font). To
get a truly fresh config, **leave an empty config file** so the seed is skipped:

```sh
rm -rf ~/.config/sarvterminal-dev
mkdir -p ~/.config/sarvterminal-dev && : > ~/.config/sarvterminal-dev/config
```

## The round-trip test (push → wipe → pull)

Do the whole loop on the **debug build** — your release data is never involved.
**Push before you wipe**: the remote must already hold the data for the pull to restore it.

1. **Seed data** in the dev app: add a host, a **port-forward**, set the file-viewer
   **indent width to 2**, add a snippet, tweak notifications, pick a terminal theme.
2. **Configure sync** (a private GitHub repo or a synced folder + a master password)
   and **push** (Sync ↑).
3. **Back up** the debug instance (optional but recommended):
   ```sh
   cp -R ~/.config/sarvterminal-dev ~/sarvterminal-dev.bak   # includes the terminal config
   defaults export com.sarv.terminal.debug ~/sarv-debug-defaults.bak.plist
   ```
4. **Wipe to a fresh "new machine"** (quit the dev app first):
   ```sh
   pkill -f "SarvTerminal_Dev.app/Contents/MacOS/SarvTerminalDev"
   rm -rf ~/.config/sarvterminal-dev
   mkdir -p ~/.config/sarvterminal-dev && : > ~/.config/sarvterminal-dev/config
   defaults delete com.sarv.terminal.debug 2>/dev/null
   defaults write com.sarv.terminal.debug SarvDidMigrateDefaults -bool true
   ```
   The empty `config` file stops the terminal-config re-seed; the last line stops the
   app from re-importing legacy `com.mitchellh.ghostty` preferences — so the instance
   is genuinely blank.
5. **Relaunch** (`open -n /tmp/SarvTerminal_Dev.app`) → confirm it's empty: default
   theme, no hosts, no tunnels.
6. **Configure sync** to the **same** repo/folder + master password → **pull**.
7. **Verify everything came back** — terminal theme, host, port-forward, indent = 2,
   snippet, notification settings.

## Restore your debug instance when done (optional)

```sh
pkill -f "SarvTerminal_Dev.app/Contents/MacOS/SarvTerminalDev"
rm -rf ~/.config/sarvterminal-dev
cp -R ~/sarvterminal-dev.bak ~/.config/sarvterminal-dev
defaults import com.sarv.terminal.debug ~/sarv-debug-defaults.bak.plist
```

## Notes

- The **master password** and any **GitHub token** live in the macOS **Keychain**
  (per-machine, never synced), so you re-enter them when you set sync up on the fresh
  instance — that's expected.
- `pkill -f` here matches only the **debug** binary path, so it never touches the
  release app. Don't use a broad `pkill`.
- This same isolated-debug approach works for testing any data-touching feature, not
  just sync.
