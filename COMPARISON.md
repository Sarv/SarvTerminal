# One app for your terminal and your servers

Sarv Terminal is a fast, GPU-accelerated terminal **and** a full SSH client in one native macOS
app — saved hosts, SSH keys, SFTP, tunnels, and end-to-end-encrypted sync, all built in. No
plugins, no separate SSH manager, no config-file spelunking.

## Everything you get

- **Import — switch in minutes.** Bring hosts in from `~/.ssh/config` (including `Include`d files),
  iTerm2, CSV, PuTTY, MobaXterm and SecureCRT, and pull your appearance & keybindings from Ghostty,
  Alacritty, Kitty, iTerm2 and WezTerm.
- **Saved-host vault.** Every server with its full SSH profile — user, port, identity file, agent
  forwarding, proxy jump, host-key policy, startup command — in workspace → project folders with
  tags and per-host color themes.
- **SSH key manager.** See every key in `~/.ssh`, generate Ed25519 / ECDSA / RSA-4096, copy the
  public key, reveal in Finder, or delete — no `ssh-keygen` incantations.
- **SFTP + SCP file manager.** Dual-pane local↔remote browsing plus direct server-to-server copies,
  live progress, an in-app file editor, and an rwx / octal permissions editor.
- **Port-forward manager.** Save and run Local (`-L`), Remote (`-R`) and Dynamic / SOCKS (`-D`)
  tunnels over any saved host, with start/stop and live status.
- **Zero-knowledge sync.** Move your whole setup between Macs under encryption only you can open —
  AES-256-GCM, master password in the Keychain behind Touch ID, your own GitHub repo or synced folder.
- **AI command assist.** When a command fails, get a one-click explanation and a suggested fix you
  can paste straight in — bring your own key, using Claude, OpenAI or a local Ollama model. Your key
  is stored encrypted on your Mac and never synced.
- **Docker & Kubernetes attach.** List your running containers and pods and open a shell inside any
  of them in a click — no `docker exec` / `kubectl exec` to remember.
- **Snippets & shell history.** A library of your most-used commands; browse recent shell history
  and save any command as a snippet in a click.
- **Serial console.** Connect to routers, switches, a Raspberry Pi or a microcontroller over
  USB-serial — pick the device and baud rate, opens right in a tab.
- **Terminal workspace.** Tabs and splits, focus mode, input broadcasting, tab colors and renaming,
  an all-tabs overview, and reopen-closed-tab.
- **Known-hosts manager & activity logs.**
- **Customization.** Themes and per-host themes, background image with opacity and blur,
  font / cursor / window controls, and fully rebindable keybinds.

---

## How it compares

Other terminals can run `ssh` — but the connection-manager layer that makes servers easy to live
with isn't built in.

**Legend:** ✅ built-in · 🟡 partial · ⬜ not offered.
🟡 usually means the tool can run `ssh`, but has no proper GUI to manage it — no host vault, key
manager, or tunnel UI.

| | **Sarv Terminal** | Ghostty | iTerm2 | Warp | Terminal.app | WezTerm |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Saved-host vault (groups, per-host identity & proxy-jump) | ✅ | ⬜ | 🟡 | ⬜ | 🟡 | 🟡 |
| SSH key manager (generate / list / copy in-app) | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| SFTP / SCP dual-pane file manager | ✅ | ⬜ | 🟡 | ⬜ | ⬜ | ⬜ |
| Port-forward / tunnel manager (GUI) | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Import hosts & settings from other apps | ✅ | ⬜ | 🟡 | ⬜ | ⬜ | 🟡 |
| End-to-end-encrypted settings sync | ✅ | ⬜ | 🟡 | 🟡 | ⬜ | ⬜ |
| AI explain/fix for failed commands (bring-your-own-key, local option) | ✅ | ⬜ | ⬜ | 🟡 | ⬜ | ⬜ |
| One-click Docker / Kubernetes container attach | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| Serial console (USB-serial) | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ✅ |
| Known-hosts manager | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ |
| GPU-accelerated rendering | ✅ | ✅ | ✅ | ✅ | ⬜ | ✅ |
| GUI settings (no config file required) | ✅ | 🟡 | ✅ | ✅ | ✅ | ⬜ |
| Local-first · no account · no telemetry | ✅ | ✅ | ✅ | 🟡 | ✅ | ✅ |
| Open source & free | ✅ | ✅ | ✅ | 🟡 | ⬜ | ✅ |
| License | MIT | MIT | GPL-2.0 | AGPLv3 (client) | Proprietary | MIT |

> If you manage more than one server, Sarv Terminal is the only app here that puts your terminal,
> saved hosts, SSH keys, tunnels and file transfers in **one place** — fast, local-first, and
> zero-knowledge, with nothing leaving your Mac. That's the whole workflow the others leave you to
> assemble by hand.

<sub>Sarv Terminal is macOS-only today (the Ghostty engine is cross-platform; a Linux UI is the
project's biggest open item). Comparison reflects built-in GUI capabilities as of 2026.</sub>
