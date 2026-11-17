# A native Mac terminal built for server work

Sarv Terminal combines the fast, GPU-accelerated Ghostty engine with the workflows normally found
in dedicated SSH clients: saved connections, SSH keys, SFTP/SCP, tunnels, encrypted settings sync,
container attach, and command-failure assistance.

That places Sarv Terminal between two established categories. Terminal emulators optimize the local
command-line experience. Dedicated SSH managers optimize fleets of remote connections. Sarv Terminal
is for Mac users who want both in one open-source app.

## Where we fit

| Product | Positioning | Main trade-off |
|---|---|---|
| **Sarv Terminal** | We combine a native macOS terminal with visual SSH operations for people who manage multiple servers. | macOS-only today; saved-host passwords are not yet stored in Keychain. |
| **Ghostty / iTerm2 / WezTerm** | Excellent terminal experiences with remote workflows assembled from `ssh`, `scp`, `tmux`, and other tools. | No full built-in server-operations workspace. |
| **Termius / SecureCRT** | Cross-platform coverage, mature enterprise SSH administration, and mobile access. | Proprietary/commercial products rather than an open-source Mac-native stack. |
| **Warp** | Agentic coding and an editor-like command workflow. | Different focus from a saved-host, SFTP, key, and tunnel manager. |
| **Tabby** | Cross-platform open-source terminal access with SSH, Telnet, and serial support. | Electron-based and less focused on a native macOS server workspace. |

## Compared with terminal emulators

**Legend:** ✅ built in · 🟡 partial, optional, or adjacent capability · ⬜ not documented as built in.

| Capability | **Sarv Terminal** | Ghostty | iTerm2 | Warp | WezTerm |
|---|:---:|:---:|:---:|:---:|:---:|
| GPU-accelerated terminal | ✅ | ✅ | ✅ | ✅ | ✅ |
| Saved-host workspace with groups, identity, and proxy jump | ✅ | ⬜ | 🟡 | ⬜ | 🟡 |
| SSH key-management UI | ✅ | ⬜ | ⬜ | ⬜ | ⬜ |
| SFTP/SCP file-management UI | ✅ | ⬜ | 🟡 | ⬜ | ⬜ |
| GUI for local, remote, and SOCKS tunnels | ✅ | ⬜ | ⬜ | ⬜ | ⬜ |
| Failure explanation + suggested fix with BYOK/local-model option | ✅ | ⬜ | 🟡 | 🟡 | ⬜ |
| One-click Docker/Kubernetes shell attach | ✅ | ⬜ | ⬜ | ⬜ | ⬜ |
| No account required for the core terminal | ✅ | ✅ | ✅ | 🟡 | ✅ |
| Open-source license | MIT | MIT | GPL-2.0 | AGPL-3.0 client | MIT |

iTerm2 offers an optional generative-AI plugin, so it is marked partial rather than absent. Warp has
broad built-in AI/agent capabilities, but its product focus is agentic development rather than the
BYOK/local failed-command workflow described in this row.

## Compared with SSH and connection managers

This is the more important competitive set for Sarv Terminal's server-management features.

| Capability | **Sarv Terminal** | Termius | SecureCRT | Tabby |
|---|:---:|:---:|:---:|:---:|
| Terminal + saved connections | ✅ | ✅ | ✅ | ✅ |
| Keys/credentials managed through the app | ✅ | ✅ | ✅ | 🟡 |
| GUI port-forwarding workflow | ✅ | ✅ | ✅ | 🟡 |
| Encrypted multi-device settings/host sync | ✅ user-controlled backend | ✅ Termius cloud vault | ⬜ not documented as built in | ⬜ not documented as built in |
| BYOK/local command-failure assistance | ✅ | ⬜ | ⬜ | ⬜ |
| One-click Docker/Kubernetes shell attach | ✅ | ⬜ | ⬜ | ⬜ |
| Desktop platforms | macOS | macOS, Windows, Linux + mobile | macOS, Windows, Linux | macOS, Windows, Linux |
| Product model | Free, open source | Proprietary, subscription tiers | Commercial | Free, open source |

## The honest positioning

Sarv Terminal's advantage is not that other products cannot connect to servers. Termius and
SecureCRT are mature connection managers, while Ghostty, iTerm2, Warp, WezTerm, and Tabby are strong
terminal products.

The differentiator is the combination: **a native macOS terminal built on Ghostty, plus a visual
server-operations workspace, released under MIT and usable without a mandatory account.** We focus
on a Mac-first, open-source and local-first workflow. Cross-platform SSH managers remain the stronger
fit when mixed-device and mobile support are the priority.

## Security and privacy scope

Sarv Terminal does not require an account and does not bundle product telemetry. Local data stays on
the Mac unless an optional feature that communicates externally is enabled:

- encrypted sync writes to the selected private GitHub repository or synced folder;
- AI assistance sends the relevant request to the configured provider, or stays local with
  Ollama;
- saved-host passwords currently remain in local `hosts.json`; SSH keys are recommended until the
  planned Keychain migration lands.

## Sources and methodology

Checked **2026-07-21** against vendor documentation and public repositories. The table covers
built-in, user-visible product capabilities rather than everything achievable with scripts or
third-party extensions. Features, editions, and pricing can change; corrections are welcome.

- [Sarv Terminal README](README.md)
- [Ghostty features](https://ghostty.org/docs/features)
- [iTerm2 features](https://iterm2.com/features.html) and [AI plugin](https://iterm2.com/ai-plugin.html)
- [Warp repository](https://github.com/warpdotdev/warp)
- [WezTerm repository](https://github.com/wezterm/wezterm)
- [Termius Vault](https://termius.com/vault)
- [SecureCRT features](https://www.vandyke.com/products/securecrt/features.html)
- [Tabby repository](https://github.com/Eugeny/tabby)

<sub>Sarv Terminal is macOS-only today. Its Ghostty-derived terminal engine is cross-platform, but
the connection-manager interface is currently implemented in SwiftUI.</sub>
