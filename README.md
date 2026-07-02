# Sarv Terminal

**An open-source, full-fledged terminal _and_ SSH connection manager for macOS.**
Fast GPU-accelerated terminal, a built-in host vault, SFTP/SCP file manager, SSH key & tunnel
manager, and end-to-end-encrypted settings sync — in one native app.

[Features](#features) · [Security & Privacy](#security--privacy) · [Install](#install) · [Build](#build-from-source) · [Contributing](#contributing) · [Credits](#credits--license)

![Platform: macOS](https://img.shields.io/badge/platform-macOS-black)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Built on Ghostty](https://img.shields.io/badge/built%20on-Ghostty-7B68EE)

---

> ### Built on Ghostty 👻
> Sarv Terminal is a **fork of [Ghostty](https://github.com/ghostty-org/ghostty)** by
> [Mitchell Hashimoto](https://github.com/mitchellh) and the Ghostty contributors. The blazing-fast,
> GPU-accelerated terminal engine at the heart of this app is entirely their work, and we are deeply
> grateful for it. Sarv Terminal layers a **connection-manager workflow** (hosts, SFTP, keys, tunnels,
> encrypted sync) on top of that engine. **Huge thanks to the Ghostty team** — please consider
> [supporting the upstream project](https://github.com/ghostty-org/ghostty). See
> [Credits & License](#credits--license).

## About

Most terminals make you choose: a *fast native terminal* **or** a *connection manager* (like the
commercial SSH clients). Sarv Terminal aims to be both — a single, native macOS app where your
terminal, your saved servers, your SSH keys, your tunnels, and your file transfers all live together,
with your whole setup optionally synced between machines under your own end-to-end encryption.

It is built for developers and operators who live in the terminal and manage more than one server.

## Features

Everything Ghostty gives you — fast GPU rendering, ligatures, true color, native macOS feel — **plus
the Sarv Terminal layer.** Each section below shows the feature in action.

### 🗄️ Connection Manager (Vaults)
- **Saved hosts** with a full SSH profile: user, port, identity file, agent forwarding, compression,
  keep-alives, proxy jump, host-key policy, and a startup command.
- **Groups & tags** — organize servers into a workspace → project folder tree.
- **Per-host themes** — each server can open with its own color theme so you always know where you are.
- **Guided connect popup** with **auto-reconnect** on network drops / wake-from-sleep, and clean
  inline error handling.
- **Import** hosts from a CSV or from your existing `~/.ssh/config`.
- **Command palette / quick-connect** to jump to any host or action.

![Vaults — saved hosts, groups and tags](assets/screenshots/hosts.png)

### 🔑 SSH Keychain
- See every key in `~/.ssh` with its type, size, fingerprint, and comment.
- **Generate** new keys (Ed25519 / ECDSA / RSA-4096) with an optional passphrase and comment.
- **Copy the public key** in one click (to paste into a server's `authorized_keys` or GitHub),
  copy the path, reveal in Finder, or delete safely.

![SSH Keychain — generate and manage keys](assets/screenshots/keychain.png)

### ↔️ Port Forwarding
- Save **Local (`-L`)**, **Remote (`-R`)**, and **Dynamic / SOCKS (`-D`)** tunnels.
- Each tunnel runs over one of your saved hosts; **start/stop** with a live status indicator and
  inline error reporting (e.g. "port already in use").

![Port Forwarding — local, remote and SOCKS tunnels](assets/screenshots/port-forwarding.png)

### 🧩 Snippets
- A library of your most-used commands; run them straight into the focused terminal or copy them.
- **Shell History** — browse your recent shell commands (zsh / bash / fish) in a side panel and
  **save any of them as a snippet** in one click.

![Snippets — one-click command library](assets/screenshots/snippets.png)

### ✅ Known Hosts & 🪵 Activity Logs
- Browse and manage `~/.ssh/known_hosts`.
- A running activity log of connections and session events.

![Known Hosts — browse and manage known_hosts](assets/screenshots/known-hosts.png)

![Activity Logs — connection and session events](assets/screenshots/logs.png)

### 🖥️ Terminal Workspace
- **Embedded tabs and splits** in a single window, with **focus mode**, **input broadcasting**
  across panes, tab colors & renaming, an **all-tabs overview**, and **reopen-closed-tab**.

![Terminal — tabs, split panes and background image](assets/screenshots/terminal-splits.png)

### 🔌 Serial Console
- Connect to a device over a **USB-serial adapter** (console cables for routers/switches, Raspberry
  Pi, microcontrollers, etc.) right from the Hosts screen or the command palette.
- Pick a detected `/dev/cu.*` device and a baud rate; opens a session in a terminal tab (8-N-1, via
  the built-in `screen`).
- A built-in **"report an issue"** helper opens a pre-filled GitHub issue — serial behavior is
  hardware-specific, so this makes it easy to tell us your adapter/chipset when something's off.

### 📁 SFTP / SCP Dual-Pane File Manager
- Transfers run over **both SFTP and SCP** — SFTP for local ⇄ remote browsing/transfer, and **SCP for
  direct server-to-server (server ⇄ server) transfers**.
- Browse **local ⇄ remote** side by side and transfer between them.
- **Direct server-to-server transfers** — copy a file from one server straight to another (via SCP)
  without it passing through your Mac, with an automatic **relay-through-this-Mac fallback** when the
  two servers can't reach each other directly.
- **Live transfer progress** (file name, size, speed, %, bytes) with a **Cancel** button, and a clear
  *Server → Server* vs *Via this Mac* indicator.
- **In-app file viewer & editor** for remote and config files.
- **Two-way permissions editor** — set permissions with `rwx` checkboxes **or** an octal field, kept
  in sync live.

![SFTP / SCP — dual-pane file manager](assets/screenshots/sftp.png)

### 🎨 Customization
- Appearance: themes, **background image** with adjustable opacity & blur.
- Font, cursor, window, tabs, and shell-integration settings.
- **Fully rebindable app keybinds** that never clobber Ghostty's defaults.

![Appearance — themes, opacity, blur and background image](assets/screenshots/appearance.png)

## Security & Privacy

Sarv Terminal is **local-first**. Your hosts, keys, snippets, and tunnel rules are stored on your
machine under `~/.config/sarvterminal/`; nothing is sent anywhere unless you explicitly enable sync.

### 🔐 End-to-end-encrypted settings sync
Move your entire setup between machines under encryption only *you* can open:
- **AES-256-GCM** encryption with a key derived via **PBKDF2-HMAC-SHA256** from a master password.
- The **master password is stored only in the macOS Keychain**, unlocked with **Touch ID**, marked
  *this-device-only* so it can never leave your Mac (not even via iCloud Keychain) — **it is never
  synced**.
- Choose your own backend: a **private GitHub repository** (public repos are rejected) **or** a
  **local / cloud folder** (iCloud Drive, Dropbox, Google Drive — any synced directory).
- Syncs your terminal config, app settings, keybinds, and saved hosts. **Blank/default values are
  never synced** and never overwrite a populated value on pull, so sync can't silently wipe data.
- A small **plaintext manifest** carries only version + timestamp so status can be shown without
  decrypting anything. Encryption is **one-way**: if you forget the master password, the synced data
  is unrecoverable (this is surfaced clearly in the UI).

![Encrypted Sync — end-to-end-encrypted backup of settings, keybinds and hosts](assets/screenshots/sync.png)

### 🛡️ Credential handling
- SSH passwords are fed to `ssh`/`scp` **out-of-band via `SSH_ASKPASS`** — never typed on the TTY and
  never echoed into the terminal or shell history.
- **Pre-flight host-key verification** (out-of-band `ssh-keyscan`) so trust prompts are explicit and
  can't be hijacked by the password helper.
- Sensitive material lives in the **macOS Keychain** with *this-device-only* accessibility.

> **Note:** saved-host passwords are currently stored in the local `hosts.json`. Prefer SSH keys, and
> see the [roadmap](#roadmap--status) — moving host passwords into the Keychain is a tracked
> follow-up where help is welcome.

## Install

Pre-built releases are not published yet. For now, [build from source](#build-from-source). Once the
project stabilizes, signed builds will be attached to GitHub Releases — contributions to set up that
pipeline are welcome.

## Build from source

**Requirements:** macOS, [Zig](https://ziglang.org/) (matching the version in
[`build.zig`](build.zig) / [HACKING.md](HACKING.md)), and Xcode (for the macOS app bundle).

```sh
git clone https://github.com/Sarv/SarvTerminal.git
cd SarvTerminal

# Build the macOS app bundle
zig build

# The app is produced at:
open zig-out/SarvTerminal.app
```

For deeper build details and the core engine internals, see [HACKING.md](HACKING.md).

## Roadmap & Status

- ✅ **macOS app** — actively developed; all features above work today.
- 🐧 **Linux UI — the big open item.** The terminal *engine* (from Ghostty) is cross-platform, but
  the Sarv Terminal experience (Vaults, SFTP, Keychain, Port Forwarding, Sync) is currently built in
  **SwiftUI for macOS only**. **A Linux UI is not yet built, and this is where we'd love help most.**
  If you know GTK/Qt (or have ideas for a shared cross-platform UI), please jump in — see
  [Contributing](#contributing).
- 🔜 Move saved-host passwords into the Keychain; published signed releases; more sync providers.

## Contributing

**Everyone is welcome — let's make this a wonderful, full-fledged open-source terminal together.** 🎉

Whether you're fixing a bug, polishing the UI, improving docs, or taking on a big feature, your help
matters. A few especially valuable areas:

- **🐧 A Linux UI** — the single biggest opportunity. If you're a GTK/Qt developer, we'd love your help.
- **🔒 Security hardening** — moving host passwords into the Keychain, audits, threat-model review.
- **🚀 Releases & packaging** — CI, signed/notarized builds, Homebrew.
- **📸 Docs & screenshots** — including the gallery above (see [`assets/screenshots/`](assets/screenshots)).

How to get started:

1. **Open an issue or discussion** describing the bug or idea before large changes, so we can align.
2. Fork, branch, and send a focused pull request. Keep commits small and logically grouped, using
   [Conventional Commit](https://www.conventionalcommits.org/) messages (`feat:`, `fix:`, `docs:`…).
3. Build locally with `zig build` and make sure the app launches.
4. See [HACKING.md](HACKING.md) for engine/build internals and [CONTRIBUTING.md](CONTRIBUTING.md) for
   general guidelines.

Be kind and constructive — we want this to be a friendly community.

## Credits & License

Sarv Terminal stands on the shoulders of **[Ghostty](https://github.com/ghostty-org/ghostty)**. The
core terminal engine, rendering, and `libghostty` are the work of **Mitchell Hashimoto and the
Ghostty contributors**, and Sarv Terminal would not exist without them. 🙏

This project — both the inherited Ghostty code and the Sarv Terminal additions — is released under the
**[MIT License](LICENSE)**.

```
Ghostty:       Copyright (c) Mitchell Hashimoto, Ghostty contributors
Sarv Terminal: Copyright (c) Sarv Terminal contributors
```

If you find Sarv Terminal useful, please ⭐ the repo, contribute, and consider supporting upstream
Ghostty as well.
