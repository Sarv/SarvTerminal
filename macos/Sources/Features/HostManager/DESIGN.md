# Sarv Terminal Host Manager — Design Document

**Status:** Draft v1 — pre-implementation
**Owner:** Ankur Dubey (Sarv Terminal, a Ghostty fork)
**Platform priority:** macOS first, GTK/Linux second
**Goal:** Bring Termius-class SSH host management *inside* Sarv Terminal's window without subscriptions or vendor lock-in.

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Data Model](#3-data-model)
4. [Storage Layout](#4-storage-layout)
5. [Encryption Scheme](#5-encryption-scheme)
6. [Git-Backed Sync](#6-git-backed-sync)
7. [SSH Config Two-Way Sync](#7-ssh-config-two-way-sync)
8. [Connection Flow](#8-connection-flow)
9. [UI Specification](#9-ui-specification)
    - 9.5 [Master Password UX](#95-master-password-ux)
10. [Settings & First-Run Wizard](#10-settings--first-run-wizard)
11. [Terminal Engine Core (Zig) Touchpoints](#11-terminal-engine-core-zig-touchpoints)
12. [Phased Implementation Plan](#12-phased-implementation-plan)
13. [Security Threat Model](#13-security-threat-model)
14. [Open Decisions](#14-open-decisions)
15. [Migration & Imports](#15-migration--imports)

---

## 1. Goals and Non-Goals

### Goals

- **Termius-equivalent host management UI** inside Sarv Terminal's main window: sidebar listing hosts, click-to-connect, form-based editor, groups, tags, drag-reorder.
- **Self-hosted sync** via the user's own private Git repo + PAT (no Sarv Terminal cloud service, no subscription).
- **Two-way sync with `~/.ssh/config`** so non-Sarv Terminal tools (VS Code Remote, `scp`, `ssh` CLI, `rsync`) keep working.
- **Encrypted secrets** with a master password the user controls; secrets never in plaintext on disk and never in Git history unencrypted.
- **Biometric unlock** (Touch ID) via macOS Keychain for the master password after first entry on a device.
- **Resumable, conflict-tolerant Git sync** that doesn't silently drop changes.
- **No rolled-our-own crypto** — every cryptographic primitive comes from Apple CryptoKit or a vetted library.

### Non-goals (v1)

- Server-side multi-user team vaults (single user, multi-device only).
- Mobile clients (iOS/Android).
- AI command generation.
- Real-time collaboration / shared sessions.
- Cross-platform parity on Day 1 (Linux/GTK arrives in Phase 6).
- Importing every commercial-tool format (PuTTY, MobaXterm, SecureCRT) — only `~/.ssh/config` and Termius JSON export for v1.

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    Sarv Terminal macOS App                       │
│                                                                  │
│  ┌────────────────────┐    ┌──────────────────────────────────┐  │
│  │  Host Sidebar      │    │  Terminal Surface(s)             │  │
│  │  (SwiftUI)         │    │  (existing)                      │  │
│  │                    │───▶│                                  │  │
│  │  click → connect   │    │  spawned with `command = ssh …`  │  │
│  └──────────┬─────────┘    └──────────────────────────────────┘  │
│             │                                                    │
│             ▼                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              HostManagerStore (ObservableObject)         │    │
│  │  • In-memory model (Hosts, Groups, Identities, Tags)     │    │
│  │  • Diff/dirty tracking                                   │    │
│  │  • Publishes changes to Sidebar via @Published           │    │
│  └────┬───────────────┬──────────────────┬────────────────┬─┘    │
│       │               │                  │                │      │
│       ▼               ▼                  ▼                ▼      │
│  ┌─────────┐   ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │
│  │ Plain   │   │ Encrypted    │  │ Keychain     │  │ SSH      │  │
│  │ JSON    │   │ Secrets      │  │ Store        │  │ Config   │  │
│  │ file    │   │ files        │  │ (master pw,  │  │ Bridge   │  │
│  │         │   │ (per-host)   │  │  PAT)        │  │          │  │
│  └────┬────┘   └──────┬───────┘  └──────────────┘  └─────┬────┘  │
│       │               │                                  │       │
│       └───────┬───────┘                                  │       │
│               ▼                                          ▼       │
│        ┌────────────────────┐                  ┌────────────────┐│
│        │ Git Sync Engine    │                  │ ~/.ssh/        ││
│        │ (libgit2 / shell)  │                  │  ghostty.conf  ││
│        └────────┬───────────┘                  └────────────────┘│
│                 │                                                │
└─────────────────┼────────────────────────────────────────────────┘
                  ▼
         ┌──────────────────────────┐
         │ User's private Git repo  │
         │ (GitHub / GitLab / self) │
         └──────────────────────────┘
```

**Core principle:** The `HostManagerStore` is the single source of truth in-memory. Every persistence layer (JSON, encrypted files, ssh config, git) is a downstream serialization. On change, store dispatches to all layers; on conflict, store reconciles.

---

## 3. Data Model

### Swift types

```swift
// PLAINTEXT model — safe to commit unencrypted
struct Host: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String                  // "web-1"
    var hostname: String               // "10.0.1.10" or "web-1.prod.example.com"
    var port: UInt16                   // 22
    var `protocol`: HostProtocol       // .ssh, .mosh, .telnet, .serial
    var username: String?              // nil → inherit from identity/group
    var identityID: UUID?              // → Identity.id; nil → use system default
    var groupID: UUID?                 // → Group.id; nil → root
    var tags: [String]                 // ["prod", "db"]
    var jumpChain: [UUID]              // ordered list of Host.id to hop through
    var startupCommand: String?        // run after connect
    var portForwards: [PortForward]    // saved -L/-R/-D rules
    var environment: [String: String]  // env vars to set
    var sshOptions: [String: String]   // raw ssh -o pairs for power users
    var lastConnectedAt: Date?
    var color: String?                 // hex; sidebar accent
    var notes: String?
}

struct Group: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var parentID: UUID?                // nested groups
    var defaults: GroupDefaults        // inherited by child hosts
    var collapsed: Bool                // sidebar UI state, syncs across devices
    var sortIndex: Int                 // manual order within parent
}

struct GroupDefaults: Codable, Hashable {
    var username: String?
    var identityID: UUID?
    var port: UInt16?
    var environment: [String: String]
    var sshOptions: [String: String]
    var jumpChain: [UUID]
    var theme: String?                 // terminal theme override
}

struct Identity: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String                  // "Personal Key", "Work Bastion"
    var username: String
    var authMethod: AuthMethod
}

enum AuthMethod: Codable, Hashable {
    case password                                     // secret in encrypted vault
    case keyFile(path: String, hasPassphrase: Bool)   // path on disk + optional passphrase in vault
    case sshAgent                                     // delegate to ssh-agent
    case sshIDPasskey(handle: String)                 // future: device-bound passkey
}

struct PortForward: Codable, Hashable {
    var kind: ForwardKind              // .local, .remote, .dynamic
    var localBind: String              // "127.0.0.1:8080"
    var remoteTarget: String?          // "10.0.1.10:3306" (not for dynamic)
    var enabled: Bool                  // start with connection?
}

enum HostProtocol: String, Codable { case ssh, mosh, telnet, serial }
enum ForwardKind: String, Codable { case local, remote, dynamic }
```

### Identity → secret resolution

```
Identity.id ─────► encrypted file at vault/<id>.enc
                   ↓ (after decrypt with master key)
                   { "password": "..." }  or
                   { "passphrase": "..." }
```

Identity references its secret by ID only. The plaintext model never contains the password itself.

---

## 4. Storage Layout

### On-disk structure

```
~/Library/Application Support/com.sarv.terminal/host-manager/
├── plaintext.json          ← non-sensitive: hosts, groups, identities (metadata only), tags
├── vault/                  ← encrypted secrets
│   ├── meta.enc            ← verifier blob + KDF params (proves correct master pw)
│   ├── <identity-id>.enc   ← one file per Identity that has a secret
│   └── ...
├── .git/                   ← Git repo, syncs vault/ AND plaintext.json
├── .gitignore              ← excludes any local caches
├── README.md               ← auto-generated, explains repo contents
└── known_hosts             ← optional: synced known_hosts copy
```

### Why per-Identity encrypted files (not one big vault file)

| One big vault.enc | Per-Identity .enc (chosen) |
|---|---|
| Any change rewrites whole file | Only the changed identity's file changes |
| Git conflict = catastrophic (whole vault) | Git conflict = one identity; resolve or pick one side |
| Smaller filesystem footprint | Slightly more inodes, negligible |
| Slightly faster on huge vaults | Better collaboration, better diffs |

Per-Identity wins by a wide margin for git-backed sync.

### `plaintext.json` schema

Single JSON document. Pretty-printed for git diff readability.

```json
{
  "schemaVersion": 1,
  "hosts": [ /* Host objects */ ],
  "groups": [ /* Group objects */ ],
  "identities": [ /* Identity objects, secrets stripped */ ],
  "preferences": {
    "sidebarWidth": 280,
    "showTags": true
  }
}
```

### macOS Keychain entries

| Service | Account | Purpose | Access |
|---|---|---|---|
| `com.sarv.terminal.hostmgr` | `master-password` | The master pw, after first manual entry | biometryCurrentSet |
| `com.sarv.terminal.hostmgr` | `git-pat` | GitHub/GitLab PAT for sync | biometryCurrentSet |
| `com.sarv.terminal.hostmgr` | `key-passphrase-<identity-id>` | SSH key passphrase | biometryCurrentSet |

All entries use `kSecAccessControlBiometryCurrentSet | kSecAccessControlOr | kSecAccessControlDevicePasscode` so Touch ID unlocks them, falling back to device passcode.

---

## 5. Encryption Scheme

### Primitives (all from Apple CryptoKit)

- **KDF:** PBKDF2-HMAC-SHA512, **600,000 iterations** (OWASP 2024 baseline), salt = 32 random bytes per vault.
  - CryptoKit doesn't include Argon2id; PBKDF2-SHA512 via `CommonCrypto` is the strongest available without third-party deps. If we later add SwiftArgon2 (or similar), the file format already supports a `kdf` discriminator.
- **AEAD:** ChaCha20-Poly1305 via `CryptoKit.ChaChaPoly`. Random 12-byte nonce per file.
- **Random:** `SystemRandomNumberGenerator` / `SecRandomCopyBytes`.

### File format (each `.enc` file)

Binary layout:

```
┌────────────────────────────────────────────────┐
│ magic:   "GHTV"           4 bytes              │
│ version: u16              2 bytes  (= 1)       │
│ kdf:     u8               1 byte   (0=pbkdf2)  │
│ kdf_iter: u32             4 bytes  (=600000)   │
│ salt:    32 bytes                              │
│ nonce:   12 bytes                              │
│ ciphertext_len: u32       4 bytes              │
│ ciphertext:    N bytes    (Poly1305 tag at end)│
└────────────────────────────────────────────────┘
```

- **Plaintext payload** is JSON: `{"password": "...", "passphrase": "..."}`.
- Salt is **per-file**, not per-vault. The same master password produces different keys per file. This prevents nonce-reuse attacks even if the same nonce were ever picked twice.
- Master key derivation: `key = PBKDF2(master_password, salt, iter, 32)`.

### `meta.enc` — the verifier

`vault/meta.enc` contains a known plaintext (`"ghostty-host-vault-v1"`) encrypted with the master password using the same scheme. On unlock:

1. Read salt+iter+nonce from `meta.enc`
2. Derive key from user-provided master pw
3. Decrypt
4. If plaintext == `"ghostty-host-vault-v1"` → password correct, cache derived key for session
5. Else → wrong password, fail fast with clear error (no garbage decryption attempted)

### Master password lifecycle

```
First run on Mac #1:
  user sets master pw → store in Keychain w/ Touch ID → use for all encrypts

Subsequent runs same Mac:
  app reads master pw from Keychain (Touch ID prompt) → done

First run on Mac #2 (after cloning the repo):
  Keychain empty → app shows "Enter master password" dialog
  user types pw → app verifies against meta.enc → stores in Keychain w/ Touch ID

Master pw change:
  re-encrypt meta.enc + every <id>.enc with new key → commit → push
  update Keychain entry
```

### What if master password is forgotten?

**Data is unrecoverable.** This must be communicated clearly at setup:

> Your master password protects the encrypted secrets. If you forget it, your saved passwords and key passphrases cannot be recovered — you'll need to delete the vault and re-enter your secrets. Store this password somewhere safe (a password manager).

**Optional v2:** offer a "recovery key" (random 256-bit base32 string, shown once at setup, encrypts a second copy of the master key). User stashes it in 1Password / paper. Adds complexity but saves people from disasters.

---

## 6. Git-Backed Sync

### Repo layout (user's side)

The user provides:
- A **private** Git repo URL (HTTPS, e.g. `https://github.com/user/ghostty-vault.git`)
- A **PAT** with `repo` scope (single-repo PATs preferred — GitHub fine-grained, GitLab project-scoped)

The repo's contents are exactly the `host-manager/` directory tree from §4. No app-specific layout enforced beyond the schema.

### Library choice

| Option | Pros | Cons |
|---|---|---|
| **Shell out to `git` CLI** | Zero deps, well-understood | Requires `git` installed; awkward error handling |
| **libgit2 via SwiftGit2** | Native, embeddable | Dependency, larger binary |
| **Swift-only impl** | Pure Swift | Massive scope, off the table |

**Recommended: shell out to `git`** for v1. macOS ships Git via Command Line Tools (any dev machine has it). If `git` is missing, show a clear setup instruction. Migrate to libgit2 only if shelling out becomes a real friction point.

### PAT handling

- Stored in Keychain (`account = "git-pat"`), Touch ID protected.
- Injected at push/pull time via Git's credential helper protocol:
  ```bash
  git -c credential.helper='!f() { echo "username=x-access-token"; echo "password=<PAT>"; }; f' push
  ```
- Never written to disk in clear, never logged.
- Settings UI offers PAT rotation.

### Sync triggers

| Trigger | Action |
|---|---|
| App launch | `git fetch && git pull --rebase` (async, blocks UI for ≤2s) |
| App becomes active after >5min idle | `git pull --rebase` |
| Local edit committed | Debounced 10s, then `git push` |
| Manual "Sync now" button | `git pull --rebase && git push` |
| Periodic background | Every 5 minutes if changes are pending |

### Commit strategy

- One auto-commit per debounced batch of edits.
- Commit message format: `chore(host-manager): <N> change(s) [<device-name>]`, e.g. `chore(host-manager): edit web-1, add db-2 [macbook-pro]`.
- Author identity: `<user-email> <hostname>` (so multi-device history is legible).

### Conflict resolution

The hard part. Strategy by file:

**`plaintext.json`** — text file, Git can sometimes auto-merge, but for safety:
1. Always `pull --rebase` before push.
2. On rebase conflict in `plaintext.json`:
   - Parse both sides as JSON.
   - Three-way merge at the entity level (host/group/identity by `id`):
     - If only one side modified an entity → take that side.
     - If both sides modified the same entity → conflict UI: show diff, user picks one or merges fields manually.
3. Auto-merge handles 95% of cases (different devices editing different hosts).

**`vault/<id>.enc`** — binary blobs, Git cannot merge:
1. On conflict, both sides are valid encrypted versions.
2. UI shows: "Identity `<label>` was changed on another device. Keep local / keep remote / view both passwords."
3. The chosen version wins; we re-encrypt with the current key and commit.

**`vault/meta.enc`** — only changes on master password rotation. Conflicts here mean two devices rotated simultaneously: extremely rare; resolve by accepting whichever was first.

### First-time setup flow

```
User: "Set up sync"
  ↓
App: prompts for Git URL + PAT
  ↓
App: validates by `git ls-remote <url>`
  ↓
  branch A) repo is empty:
    init local, set remote, push initial commit (plaintext.json + meta.enc)
  branch B) repo has existing vault:
    clone → if local has changes too, merge UI (rare; usually a fresh install)
  branch C) repo doesn't exist:
    show error with instructions; we DO NOT auto-create repos
```

---

## 7. SSH Config Two-Way Sync

You chose two-way sync with `~/.ssh/config`. This is the harder option but keeps `vscode`/`scp`/`rsync`/`ssh` CLI working unchanged. Here's how to do it without sharp edges.

### Approach: `Include`-based shadow file

We **do not** edit `~/.ssh/config` after the initial one-line addition. Instead:

1. On first run, with user consent, prepend `Include ~/.ssh/ghostty.conf` to `~/.ssh/config`.
2. We own `~/.ssh/ghostty.conf` entirely — regenerate it from our model on every change.
3. The user's hand-written entries in `~/.ssh/config` are never touched.
4. SSH's `Include` directive merges them transparently; `ssh web-1` works whether the entry is in the user's section or our generated file.

This solves several problems:
- No risk of corrupting the user's existing config on bad emission.
- Diffs are clean (one file = our state, no interleaving).
- User can `rm ~/.ssh/ghostty.conf` to "uninstall" the integration without losing their own hosts.

### Inbound parse (one-time import)

- On first run, parse `~/.ssh/config` (and any existing includes).
- Convert each `Host` block to a `Host` model entry.
- Detect wildcards (`Host *.prod`) → become Group defaults.
- Detect `ProxyJump` → `jumpChain`.
- Detect `LocalForward`/`RemoteForward`/`DynamicForward` → `PortForward` entries.
- Detect `IdentityFile` → create an `Identity` (label = filename) referencing the key path.
- Imported entries are tagged `imported-from-ssh-config` and shown grouped in the sidebar so the user can review and organize.

### Outbound emission (continuous)

Regenerate `~/.ssh/ghostty.conf` on every model change:

```
# AUTOGENERATED BY GHOSTTY HOST MANAGER — DO NOT EDIT
# Last updated: 2026-06-11T10:42:00Z
# This file is overwritten on every change. Edit hosts in Ghostty's sidebar.

# Ghostty: {"groupId":"a1b2","tags":["prod","db"],"color":"#ff8800"}
Host web-1
    HostName 10.0.1.10
    User deploy
    Port 2222
    IdentityFile ~/.ssh/keys/prod_ed25519
    ProxyJump bastion

# Ghostty: {"tags":["jump"]}
Host bastion
    HostName bastion.example.com
    User jumper
    IdentityFile ~/.ssh/keys/bastion_ed25519
```

**Round-tripping Sarv Terminal-only fields:** the `# Ghostty: {…}` JSON comment immediately before each `Host` block carries data ssh_config can't natively express (tags, group membership, color, notes, port-forward labels, etc.). Our parser reads these; non-Sarv Terminal tools ignore them.

### Field mapping

| Model field | ssh_config directive | Notes |
|---|---|---|
| `label` | `Host <label>` | The block header |
| `hostname` | `HostName` | |
| `port` | `Port` | Omitted if 22 |
| `username` | `User` | |
| `identityID` → keyFile | `IdentityFile` | Resolved to absolute path |
| `identityID` → password | (none) | Password auth not in ssh_config; handled at connect time |
| `jumpChain` | `ProxyJump host1,host2` | |
| `portForwards` (.local) | `LocalForward <bind> <target>` | One line per |
| `portForwards` (.remote) | `RemoteForward <bind> <target>` | |
| `portForwards` (.dynamic) | `DynamicForward <bind>` | |
| `environment` | `SendEnv FOO=bar` | Only env vars marked "send" |
| `sshOptions` | direct (key/value) | Passed through verbatim |
| `tags`, `groupID`, `color`, `notes`, `startupCommand` | `# Ghostty: {…}` | Comment metadata |

### Inbound file watcher

We watch `~/.ssh/config` (and the user's `Include`d files, excluding our own) with FSEvents. On external change:
1. Re-parse.
2. Diff against last-seen state.
3. For new hosts → add to model (in "Imported" group).
4. For modified hosts → show a banner: "Host `web-1` was changed in ssh_config. Reload?" with merge UI.
5. For deleted hosts → soft-delete in model after user confirmation.

This keeps the user in control. Silent two-way overwrite is too dangerous when the file is shared with so many other tools.

### What if the user edits `~/.ssh/ghostty.conf` directly?

Detect via FSEvents → on next emission, our changes overwrite theirs. We show a one-time warning the first time this happens, suggesting they make the change via Sarv Terminal instead.

---

## 8. Connection Flow

When user clicks a host in the sidebar:

```
1. HostManagerStore.resolve(host) → ResolvedConnection
   walks group chain, merges defaults, picks identity, applies overrides
   ↓
2. ConnectionLauncher.connect(resolved) → Ghostty.Surface
   builds the ssh command:
     ssh -p <port> -i <keyfile> -J <jumpChain> -L <forwards> <user>@<hostname>
   ↓
3. Ghostty.Surface(command: [...]) — uses existing surface init pathway
   spawns surface in a new tab (or split, or window, per user pref)
   ↓
4. If password auth: we don't pass it on CLI. We pre-launch sshpass
   OR pipe via expect-style spawn (TBD — see §14)
   ↓
5. If startupCommand: send it after connection settle (~500ms) via PTY write
```

### Password authentication concern

We're not going to put passwords on the CLI. Options:

- **`sshpass` (vendored or `brew install sshpass`)** — well-understood, but uses TTY trick and some `sshd` configs reject it.
- **expect-style pseudo-terminal feeding** — write password to PTY when prompt appears. We own the surface, this is doable.
- **SSH askpass helper** — set `SSH_ASKPASS` to a helper binary that retrieves the password from our process via env-passed FD.

Recommendation: **SSH askpass helper**. Set `SSH_ASKPASS=/path/to/ghostty-askpass-helper`, `SSH_ASKPASS_REQUIRE=force`, helper retrieves password from a Unix socket the parent process serves. Most secure, standard pattern.

For key passphrases: `ssh-add` the key on first use (passphrase from Keychain), let ssh-agent handle re-use during the session.

### Connection on split/new-tab choice

User preference (settings):
- Always new tab
- Always new split (with direction)
- New window if no Sarv Terminal window open, else new tab
- Per-host override

Bonus: cmd-click → new split; opt-click → new window.

---

## 9. UI Specification

### Sidebar (`HostSidebarView`)

```
┌────────────────────────────┐
│ ╔══ Sarv Terminal ════╗ ⌘N │  ← title bar (existing)
├────────────────────────────┤
│ 🔍 Filter hosts…           │  ← search field, filters by label/hostname/tags
│                            │
│ ── + ⊕ ↻ ⚙ ────────────── │  ← toolbar: add host, add group, sync, settings
│                            │
│ ▼ 📁 Production       (4)  │  ← group, count
│   ● web-1                  │  ← green dot = connected tab open
│   ○ web-2                  │
│   ○ db-1                   │
│   ○ cache-1                │
│ ▼ 📁 Development      (3)  │
│   ○ dev-jump        [jump] │  ← jump-host tag
│   ▼ via dev-jump           │  ← indented children that use this as jump
│     ○ app-1                │
│     ○ app-2                │
│ ▶ 📁 Personal         (2)  │  ← collapsed
│                            │
│ ── 🏷  prod (4)            │  ← tag filters
│    🏷  db (1)              │
│                            │
│ ── status ────             │
│ 🟢 Synced 2 min ago        │
└────────────────────────────┘
```

**Components:**
- `NavigationSplitView` with `.sidebar` on left and `TerminalTabBar + Surface` content on right.
- List uses `OutlineGroup` for nested groups.
- Each row: leading status dot + label + trailing tags + accent color stripe.
- Click → connect (with preference for new-tab/split).
- Cmd+click → new split.
- Right-click → context menu: Edit / Duplicate / Connect in… / Delete / Add Tag.
- Drag-reorder within a group; drag-into another group; drag onto root.

### Host editor sheet

The form is **flat and host-centric** — the user fills in everything including the password, the way Termius works. The Identity object is created/looked-up transparently on save (see §14 D9).

```
┌────────────────────────────────────────────────────────┐
│ Edit Host: web-1                                  [×]  │
├────────────────────────────────────────────────────────┤
│ Label          │ web-1                                 │
│ Hostname       │ 10.0.1.10                             │
│ Port           │ 22                                    │
│ Protocol       │ SSH ▾                                 │
│ Username       │ deploy                                │
│                                                        │
│ Authentication │ ● Password                            │
│                │ ○ SSH key (file)                      │
│                │ ○ SSH agent                           │
│                │ ○ Use saved identity ▾                │
│                                                        │
│ Password       │ ••••••••••           [show]           │
│                                                        │
│ Group          │ Production ▾                          │
│ Tags           │ prod ⊗  db ⊗  + add                   │
│ Jump chain     │ bastion → dev-jump  [ Edit chain… ]   │
│ Color          │ ▓▓▓ #ff8800                           │
│                                                        │
│ ▼ Advanced                                             │
│   Startup cmd  │ tmux attach -t main                   │
│   Env vars     │ NODE_ENV=prod                         │
│   SSH options  │ ServerAliveInterval=60                │
│                                                        │
│ ▼ Port forwards                                        │
│   Local  127.0.0.1:5432 → db-1:5432  [✓]              │
│   + Add forward                                        │
│                                                        │
│              [ Cancel ]  [ Save ]                      │
└────────────────────────────────────────────────────────┘
```

**Auth section semantics:**
- **Password / SSH key / SSH agent** → fields appear inline; on save we auto-create a hidden Identity (see §14 D9 for details).
- **Use saved identity** → dropdown of user-created Identities (auto-created ones excluded). For users who want to share one credential across many hosts.
- Switching radio resets dependent fields with a confirmation if data would be lost.

### Identity manager

Separate window or sidebar tab. List of identities; for each:
- Label (rename in place)
- Username
- Auth method (password / key-file / agent / ssh-id)
- For key-file: path picker, "Has passphrase" toggle, "Test connection" button
- For password: "Set password" → secret prompt (stored in encrypted vault on save)
- "Used by N hosts" → click to see referencing hosts

### First-run wizard

A multi-step sheet:
1. Welcome & explain (host manager, encryption, optional sync)
2. Set master password (twice) + recovery acknowledgement
3. (Optional) Set up Git sync — URL + PAT + test connection
4. (Optional) Import from `~/.ssh/config` — preview list, deselect what you don't want
5. (Optional) Import from Termius export
6. Done

### Settings pane

A new tab in Sarv Terminal's existing settings UI:
- Master password (change / test)
- Git sync (URL, PAT, branch, "Sync now", history)
- SSH config integration (toggle Include line, regenerate now, file path)
- Connection defaults (new tab / split / window)
- Sidebar visibility (always / toggle keybind / hidden)

---

### 9.5 Master Password UX

The master password surfaces in four distinct moments. Pinning each down before Phase 3.

#### 9.5.1 — First-run creation

Step inside the first-run wizard (§10). Window-modal sheet, cannot be skipped if the user opts into encrypted secrets.

```
┌────────────────────────────────────────────────────────┐
│ ② Set master password                                  │
├────────────────────────────────────────────────────────┤
│ This password protects your saved passwords and SSH    │
│ key passphrases. It is only stored on your devices.    │
│                                                        │
│ ⚠ If you forget it, the encrypted data cannot be       │
│   recovered. Store it in a password manager.           │
│                                                        │
│ Master password         │ •••••••••••                  │
│ Confirm                 │ •••••••••••                  │
│ Strength                │ ████████░░  Strong           │
│                                                        │
│ ☐ I understand it cannot be recovered if lost.         │
│                                                        │
│              [ Back ]  [ Continue → ]                  │
└────────────────────────────────────────────────────────┘
```

**Requirements:**
- Minimum 12 characters. Recommended: a passphrase (4+ words) or a manager-generated random string.
- zxcvbn-style strength meter (estimated guess time, not just length).
- The acknowledgement checkbox must be ticked to continue (prevents accidental commitment).

**Flow on Continue:**
1. Generate random 32-byte salt → derive master key with PBKDF2 (600k iter, SHA-512).
2. Encrypt the verifier blob `"ghostty-host-vault-v1"` → write `vault/meta.enc`.
3. Store the master password in Keychain (`account = master-password`, biometryCurrentSet).
4. Cache the derived key in memory for the session.

#### 9.5.2 — New-device unlock (after Git clone of an existing vault)

Triggered when: `vault/meta.enc` exists on disk but Keychain has no master pw entry. App is otherwise locked from secret access.

```
┌────────────────────────────────────────────────────────┐
│ Unlock Host Vault                                      │
├────────────────────────────────────────────────────────┤
│ 🔒 Your encrypted vault was loaded from sync. Enter    │
│    the master password to decrypt it on this device.   │
│                                                        │
│ Master password  │ •••••••••••           [show]       │
│                                                        │
│ ☑ Remember on this Mac (Touch ID / passcode)           │
│                                                        │
│              [ Cancel ]  [ Unlock ]                    │
└────────────────────────────────────────────────────────┘
```

**Flow on Unlock:**
1. Read salt + KDF params from `vault/meta.enc`.
2. Derive key from typed password.
3. Attempt to decrypt verifier blob.
4. If plaintext matches `"ghostty-host-vault-v1"` → success.
   - If "Remember" toggled: write to Keychain with `biometryCurrentSet`.
   - Cache derived key in memory.
5. If decryption fails → red error: "Incorrect password. Try again."
   - After 5 consecutive failures, throttle with exponential backoff (1s, 2s, 4s, 8s, 30s).

**Cancel behavior:** Vault stays locked; sidebar shows the graceful-lock state (§9.5.5). Terminal is still usable.

#### 9.5.3 — Daily launches (the common case)

User types nothing.

1. App launch → `HostManagerStore.unlock()` reads master pw from Keychain.
2. macOS shows the standard Touch ID prompt: *"Sarv Terminal wants to use your password to unlock the Host Vault."*
3. Fingerprint succeeds → vault unlocks transparently. Time: ~500ms.
4. Sidebar populates.

**Fallback paths:**
- Touch ID hardware absent → device passcode prompt instead.
- User cancels Touch ID → drop into the §9.5.2 typed-password screen.
- User has biometric disabled in Settings → typed password every launch.
- Keychain returns `errSecUserCanceled` (user dismissed prompt) → graceful-lock state (§9.5.5).

#### 9.5.4 — Settings → Security (rotation, lock, disable)

A new section under Sarv Terminal's existing Settings window, accessible at `Settings → Host Manager → Security`.

```
┌────────────────────────────────────────────────────────┐
│ Sarv Terminal Settings  →  Host Manager  →  Security   │
├────────────────────────────────────────────────────────┤
│ Vault status            │ 🔓 Unlocked                  │
│                         │ [ Lock now ]                 │
│                                                        │
│ Master password         │ Last changed: 12 days ago    │
│                         │ [ Change… ]                  │
│                                                        │
│ Biometric unlock        │ ☑ Use Touch ID on launch     │
│                                                        │
│ Auto-lock when idle     │ ☑ After  [ 15 min ▾ ]        │
│                                                        │
│ Recovery                │ ☐ I have stored this pw in   │
│                         │    a password manager        │
│                                                        │
│ [ Reset vault and start fresh… ]                       │
└────────────────────────────────────────────────────────┘
```

**Change Master Password sheet** (opens from `[ Change… ]`):

```
┌────────────────────────────────────────────────────────┐
│ Change Master Password                                 │
├────────────────────────────────────────────────────────┤
│ Current password   │ •••••••••••                       │
│ New password       │ •••••••••••                       │
│ Confirm            │ •••••••••••                       │
│ Strength           │ ████████░░  Strong                │
│                                                        │
│ ⚠ This will re-encrypt every saved secret and create   │
│   a sync commit. Other devices will need to enter the  │
│   new password on next launch.                         │
│                                                        │
│              [ Cancel ]  [ Change password ]           │
└────────────────────────────────────────────────────────┘
```

**Flow on Change password:**
1. Verify current password against `vault/meta.enc` — if wrong, fail.
2. Derive new key from new password (fresh salt).
3. For each file in `vault/`: decrypt with old key, re-encrypt with new key (atomic per-file: write `.tmp`, rename).
4. Write new `vault/meta.enc`.
5. Update Keychain entry.
6. Commit + push to Git with message `chore(host-manager): rotate master password [<device-name>]`.

**Lock now:** Wipes the in-memory derived key. Sidebar enters locked state. Keychain entry untouched (next unlock attempt is just Touch ID).

**Auto-lock when idle:** Timer based on app-level activity (no key/mouse in any Sarv Terminal surface). On expiry → same as Lock now.

**Reset vault and start fresh:** Big-red-button confirmation. Deletes local `host-manager/` directory, removes Keychain entries, leaves Git repo on remote untouched. User has to re-clone or set up fresh.

#### 9.5.5 — The graceful-lock pattern

**Critical UX choice: a locked vault does not block Sarv Terminal.** The terminal is fully usable; only host-list features are gated.

When the vault is locked, the sidebar shows:

```
┌────────────────────────────┐
│ Host Sidebar               │
├────────────────────────────┤
│                            │
│         🔒                 │
│                            │
│   Host Vault locked        │
│                            │
│   [ Unlock with Touch ID ] │
│   [ Use password… ]        │
│                            │
└────────────────────────────┘
```

Triggers that produce this state:
- App launch on a new device before unlock (§9.5.2).
- User clicks "Lock now" in Settings.
- Auto-lock timer fires.
- User cancels the Touch ID prompt at launch.

While locked:
- ✅ Local terminal sessions work normally.
- ✅ Existing SSH sessions keep running (the secret was already used; no need to re-decrypt).
- ✅ Quick Terminal works.
- ❌ Sidebar host list hidden (only unlock affordance).
- ❌ Clicking a host (from history, command palette, etc.) prompts unlock first.
- ❌ Git sync paused (no encryption key in memory).

The pattern is the same as 1Password's lock model — your other apps don't crash when 1Password locks.

#### Implementation surface

Key types this section implies:

```swift
final class VaultUnlocker: ObservableObject {
    @Published private(set) var state: VaultState = .locked

    enum VaultState {
        case uninitialized              // no meta.enc on disk
        case locked                     // meta.enc exists, no key in memory
        case unlocked(key: SymmetricKey, expiresAt: Date?)
    }

    func setUp(masterPassword: String) async throws       // first-run
    func unlockWithBiometric() async throws               // §9.5.3
    func unlockWithPassword(_ pw: String, remember: Bool) async throws  // §9.5.2
    func lockNow()                                        // user-initiated lock
    func changeMasterPassword(current: String, new: String) async throws
    func resetVault() async throws
}
```

Sidebar binds to `vaultUnlocker.state` and renders the appropriate view.

---



(Detailed flows already specified in §9. Below: edge cases.)

### Edge case: Keychain access denied / Touch ID disabled

- Master pw fetch fails with `errSecUserCanceled` → show normal password prompt as fallback. Don't lock the user out.
- Allow disabling biometric in settings → falls back to typed password every launch.

### Edge case: Vault file missing but Keychain has pw

- User deleted `~/Library/Application Support/.../host-manager/`?
- App detects empty dir, offers: "Restore from Git" / "Start fresh".

### Edge case: Git push rejected (someone else pushed)

- Auto `pull --rebase`; if clean, push again.
- If conflict, surface conflict UI (see §6).
- Never auto-`push --force`. Period.

---

## 11. Terminal Engine Core (Zig) Touchpoints

Most work is Swift. Zig side needs only these:

### 11.1 New binding action

`src/input/Binding.zig` — add:

```zig
toggle_host_sidebar,
focus_host_sidebar_search,
```

### 11.2 New apprt action

`src/apprt/action.zig` — add to `Action` union and `Key` enum:

```zig
toggle_host_sidebar: void,
focus_host_sidebar_search: void,
```

(Append at end of `Key` enum to preserve ABI for `include/ghostty.h`.)

### 11.3 Config field

`src/config/Config.zig`:

```zig
/// Host sidebar visibility on launch. macOS only currently.
/// Valid values: visible, hidden
@"host-sidebar": HostSidebarVisibility = .hidden,
```

### 11.4 GTK / embedded

GTK noop in v1 (logs "not implemented"). Embedded apprt routes the action to its callback so the macOS app can handle it.

### 11.5 No core data model changes

Hosts/groups/identities live entirely in Swift. The Zig core only knows: "spawn a surface with this command, in this tab/split, with these env vars." That's the existing API.

---

## 12. Phased Implementation Plan

Each phase = a committable, usable milestone.

### Phase 0 — Read-only sidebar (1–2 days)
- Sidebar UI showing hosts parsed from `~/.ssh/config` (read-only)
- Click → new tab with `ssh <host>`
- Keybind action `toggle_host_sidebar` wired up
- **Usable: yes.** Single-source ssh_config workflow, no editing.

### Phase 1 — Own data model + editor (3–4 days)
- `HostManagerStore` with full Swift model
- `plaintext.json` persistence
- Host editor sheet (Add / Edit / Delete)
- Migration from Phase 0: one-time import of ssh_config → JSON
- Identity entries (without secrets yet — agent + key-file with no passphrase only)
- **Usable: yes.** Full CRUD of hosts with persistence.

### Phase 2 — Groups + inheritance + tags + drag (2–3 days)
- Nested groups in sidebar (`OutlineGroup`)
- Group defaults editor
- Tags + tag filter
- Drag-reorder within/across groups
- Search field
- **Usable: yes.** Full Termius-style organization.

### Phase 3 — Encrypted secrets + master password (3 days)
- CryptoKit-based encryption (§5)
- Master password setup + Keychain storage + Touch ID
- `vault/<id>.enc` per identity with secrets
- Identity editor for password + key-with-passphrase auth
- **Usable: yes.** Secure secrets, biometric unlock.

### Phase 4 — Two-way ssh_config sync (3–4 days)
- `~/.ssh/ghostty.conf` emitter
- `Include` injection into `~/.ssh/config` (with consent)
- FSEvents watcher on user's ssh_config
- Inbound merge UI
- **Usable: yes.** Other tools (vscode, scp) see Sarv Terminal hosts seamlessly.

### Phase 5 — Git sync (4–5 days)
- Git CLI integration
- PAT handling, Keychain storage
- First-time setup wizard for sync
- Conflict resolution UI for `plaintext.json` and `vault/*.enc`
- Periodic + on-launch + on-edit sync
- **Usable: yes.** Multi-device sync working.

### Phase 6 — Polish + QoL (ongoing)
- Connection status dots (which hosts are open right now)
- Multi-connect (cmd-click multiple → tabs)
- Jump-chain visual builder
- Port-forward UI in editor
- Per-host startup commands
- SSH askpass helper for password identities
- Termius `.termius` export importer
- **Then:** decide on Phase 7.

### Phase 7 — Linux/GTK port (later)
- Port data model + storage (already cross-platform — just JSON+files)
- libsecret instead of Keychain
- GTK sidebar in `src/apprt/gtk/class/host_sidebar.zig`
- Reuse the encrypted vault format and git sync logic
- **Estimated:** 1–2 weeks once macOS is settled.

### Critical-path timeline

If you work evenings/weekends:
- Phases 0–2: **week 1–2** — host management without sync or encryption
- Phases 3–4: **week 3** — secure secrets, ssh_config integration
- Phase 5: **week 4** — Git sync
- Phase 6: **week 5+** — incremental quality of life

**End of week 4 = feature-complete v1 on macOS.**

---

## 13. Security Threat Model

### What we protect against

- **Lost/stolen Mac (locked)** — FileVault + Keychain protect everything. Master pw never on disk in clear.
- **Lost/stolen Mac (unlocked, screen-saver off)** — Keychain entries protected by `biometryCurrentSet`; require Touch ID/passcode to use. Idle re-lock after 5 min of inactivity in app.
- **Git repo compromise / GitHub takeover** — encrypted blobs require master pw. Plaintext.json reveals: host labels, IPs, usernames, groups, tags — **so be aware**, that metadata is in cleartext for git history.
- **PAT leak** — PAT scope should be single-repo (GitHub fine-grained tokens). Even if leaked, attacker can push malicious config but can't decrypt secrets.
- **Master password brute-force on stolen encrypted blob** — PBKDF2 at 600k iterations slows offline attacks to ~10 attempts/sec on a beefy GPU; entropy on user side matters. Wizard enforces ≥12 chars + suggests a passphrase.

### What we do NOT protect against

- **Compromised Mac with malware running as user** — game over. Keychain APIs return secrets to any process running as the user (with Touch ID for some entries, but only on first prompt of each app).
- **Adversary with access to filesystem + Keychain** — see above. This is the standard "your password manager assumes the host isn't pwned" model.
- **Metadata leaks via plaintext.json** — host names, IPs, group names, tags, timestamps. If this is a concern, the model can be extended to encrypt `plaintext.json` too, but at the cost of git-mergeability.

### Compliance posture

- All crypto via Apple frameworks (FIPS-validated paths available).
- No telemetry, no network calls beyond user-provided Git remote and the user-initiated SSH connections.
- Self-hosted by default; user owns the repo.

---

## 14. Open Decisions

Items I want your call on before coding starts.

### D1. Recovery key for master password — yes or no?

**Option A:** No recovery key. Forgotten pw = lost data. Simpler, more secure.
**Option B:** Optional recovery key shown once at setup. User stores externally; can decrypt vault without master pw. Adds risk surface (a second secret to protect).

**My lean:** **A**. Tell the user clearly; treat master pw like a 1Password vault password. Anyone serious already uses a password manager.

### D2. Encrypt `plaintext.json` too?

**Option A:** Leave it cleartext (faster, mergeable). Host labels/IPs/tags visible in git history.
**Option B:** Encrypt it too. Conflict resolution becomes binary-blob territory; harder UX.

**My lean:** **A.** This is your private repo, encrypted at rest by GitHub, accessed only via a scoped PAT. The metadata is not what attackers extract value from.

### D3. Connection default — new tab, new split, or new window?

Pick a default; user can override per-host or per-click-modifier.

**My lean:** new tab; cmd-click → new split; opt-click → new window.

### D4. `git` CLI vs SwiftGit2 (libgit2 wrapper)

Already covered in §6. CLI is simpler; libgit2 is more polished. I lean CLI for v1.

### D5. Phase 4 vs Phase 5 order

Two-way ssh_config sync (Phase 4) vs Git sync (Phase 5). Equally hard. Which first?

**My lean:** Phase 4 first — it adds value on a single Mac immediately. Phase 5 needs multiple Macs to demonstrate value.

### D6. Auto-start sshd port-forwards on connect?

If a host has saved forwards, do we auto-enable them on connection or require explicit click?

**My lean:** auto-enable if `enabled: true` on the forward; user toggles in editor.

### D7. Snippets in v1?

Termius has snippets. Worth including v1 or defer to v2?

**My lean:** Defer to v2. Phase 6 if at all. Focus on host management; snippets are a separate problem.

### D8. Identity sharing between hosts when ssh_config import has multiple `IdentityFile` referring to the same key

Auto-dedupe to one Identity? Or one Identity per Host (more duplication)?

**My lean:** auto-dedupe by file path; one Identity per unique key.

### D9. Inline credentials UX — host-centric form, Identity hidden under the hood (DECIDED)

**Decided 2026-06-11.** The host editor sheet exposes a flat form with Username + Authentication + Password (or key/agent) fields directly on the host. The user never has to think about "Identities" to add a host.

**Implementation:**
- On save with inline auth (password/key/agent radios), auto-create a hidden Identity:
  - `label` = `"<host-label> (auto)"`
  - `authMethod` = chosen radio
  - `username` = entered value
  - Secret encrypted into `vault/<identity-id>.enc` if applicable
  - Hidden by default in the Identity Manager (toggle: "Show auto-created")
- On save with "Use saved identity", reuse the picked Identity unchanged.
- **No auto-deduplication of inline-created Identities in v1.** If a user types the same password across 10 hosts, that's 10 hidden Identities. Trade-off: simpler code, slightly larger vault.
- The Identity Manager has a **"Merge into…"** action so a user can consolidate auto-Identities into a real shared Identity post-hoc.
- Editing a host that uses an auto-Identity edits the auto-Identity in place (transparent to the user).
- Deleting a host with an auto-Identity also deletes the Identity (auto-Identities are not shared).

**Why not de-dupe automatically?**
- Hard to do right — by hostname pattern? username? password hash? Each heuristic has false positives.
- Hidden Identities cost almost nothing — one small encrypted file per host.
- Manual merge gives the user control; automatic merge can surprise them.

---

## 15. Migration & Imports

### From `~/.ssh/config`

Already covered (§7 inbound parse).

### From Termius export

Termius offers `.termius` export (JSON). Parser:
- Top level: `personal_vault: { hosts: [...], groups: [...], identities: [...] }`
- Map to our model 1:1 where fields align
- Decrypt secrets from export's encrypted blob (Termius uses AES-GCM with user password — same input prompt)
- Drop unsupported fields (snippets, port-forwards in v1) with warning
- Show preview before import; user picks what to bring in

### From other tools (later)

- PuTTY `.reg` / `.ppk` (key conversion via `puttygen`)
- MobaXterm sessions
- SecureCRT XML
- Not in v1.

---

## End of Design Doc

**Next step after sign-off:**

1. Resolve open decisions in §14.
2. Begin **Phase 0** — read-only sidebar with click-to-connect. ~1–2 days, lands as a usable feature.
3. Set up a tracking issue or todo list to manage phase progression.

**Files to be created (Phase 0 footprint):**

```
macos/Sources/Features/HostManager/
├── DESIGN.md                       (this file)
├── HostManagerStore.swift          (ObservableObject)
├── Views/HostSidebarView.swift     (SwiftUI sidebar)
├── Views/HostRow.swift
├── Services/SSHConfigParser.swift  (read-only ssh_config import)
└── Services/ConnectionLauncher.swift

src/input/Binding.zig                (add toggle_host_sidebar action)
src/apprt/action.zig                 (add apprt action)
src/config/Config.zig                (add host-sidebar field)
macos/Sources/App/macOS/AppDelegate.swift  (host action handler)
macos/Sources/Features/Terminal/TerminalController.swift  (embed sidebar)
```

Plus updates to `macos/Ghostty.xcodeproj/project.pbxproj` to include the new files in the build.
