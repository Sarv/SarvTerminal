# SarvTerminal Roadmap

A living document for feature planning. It captures where SarvTerminal stands
against the 2025-2026 terminal / SSH-client market, the gaps worth closing, and
a prioritized plan. Add to it as ideas land; keep the "Already have" list current
so we never re-plan shipped work.

> **Legend for evidence:** ✅ **verified** = confirmed by fact-checked competitor
> docs (see [Sources](#sources)); 🔸 **indicative** = from our own code knowledge
> or secondary sources, not independently verified; 🧭 **synthesis** = our
> strategic judgement, not a sourced fact.
>
> Last market scan: **2026-07-15** (Warp / Termius / WezTerm covered in depth;
> others partial — see [Open items](#open-items-unassessed-competitors)).

---

## 1. What SarvTerminal is

A macOS terminal emulator built on a **Ghostty** fork, positioned as **terminal +
team SSH/connection manager + zero-knowledge team vault + settings sync**. It
competes in three markets at once: modern GPU terminals, AI/next-gen terminals,
and SSH/connection managers.

### Already have (don't re-plan these)
- **Terminal core (from Ghostty):** GPU rendering, Kitty graphics protocol,
  splits, tabs, themes, font ligatures, shell integration, SSH terminfo install.
- **SSH / connection manager:** saved hosts + groups, HostConnect, SFTP file
  browser, port forwarding, snippets/command library, serial connections, saved
  sessions / session restore, ssh-config discovery, known_hosts management, host
  import, host search palette.
- **Secrets & collaboration:** zero-knowledge E2E **Team Vault** (share hosts +
  secrets across a team; X25519 + per-team AES-256-GCM DEK wrapped per member),
  git-backed **settings sync** across machines.
- **App / workflow:** Command Palette, Quick Terminal (dropdown), global keybinds,
  macOS Shortcuts / AppleScript automation, notifications, custom app icon,
  Sparkle auto-update, secure keyboard entry.

### Known constraint
- **macOS-only.** Upstream Ghostty is Linux + macOS; Windows is not near-term
  (they are building `libghostty` first). ✅

---

## 2. Gap analysis — what competitors have that we don't

### Theme A — AI / agentic ⭐ (biggest gap) ✅
The defining shift of the market. We have **nothing** here. Warp rebuilt its
identity around it:
- Natural-language → command generation (⌘I); "Universal Input" auto-detects
  command vs. prompt.
- **Agent Mode**: task agents that gather context via CLI, MCP, and codebase
  indexing; run/monitor **multiple agents at once** via a management UI.
- First-class integration of **Claude Code, Codex, Gemini CLI**.
- **Block-based, editor-style UI**: command+output grouped into atomic,
  navigable, shareable blocks; multi-line IDE-style input; integrated code review.

### Theme B — Live collaboration ⭐ ✅
On-strategy for a team product; we only share *stored* vault data, not a *live
session*.
- **Warp:** share a live session via link — viewable in app / **browser / mobile
  with no install**, real-time sync, granular edit permissions; **Warp Drive**
  shared knowledge store (workflows, notebooks, env vars, prompts); shareable MCP
  configs.
- **Termius "Multiplayer":** turn-based live terminal sharing, no server install.

### Theme C — Cross-platform ⭐ (structural ceiling) ✅
We are macOS-only; every verified competitor is not:
- **Warp:** macOS / Windows / Linux (unified Rust codebase).
- **Termius:** macOS / Windows / Linux / **iOS / Android** + cross-device sync.
- **WezTerm:** all desktop platforms.

A team SSH/secrets product cannot win a mixed-OS team while macOS-only.

### Theme D — Terminal-core
- **Multiplexing** 🔸/✅ — WezTerm ships a built-in tmux-like multiplexer
  (persistent detachable sessions, workspaces) ✅; iTerm2's tmux control-mode
  (remote tmux → native tabs/splits) 🔸. We (like Ghostty) have none.
- **Sixel** 🔸 — we have Kitty graphics but likely not Sixel (only WezTerm /
  Windows Terminal among the compared set). Minor.
- **Ligatures** — **not a gap** (inherited from Ghostty).

---

## 3. Where we're ahead — and where it's contested

- **vs. GPU terminals (Ghostty / WezTerm / Kitty / Warp):** our built-in SSH
  connection manager + secrets vault + sync is a clear, unmatched advantage. ✅
- **vs. Termius (our closest competitor): contested, not a moat.** ✅ Termius has a
  near-identical zero-knowledge E2E team vault (hosts, keys, port-forwards,
  known_hosts, snippets), granular per-member access, SAML SSO + enforced 2FA,
  cross-platform sync, and live multiplayer — from ~$20/user/mo. Our edge is
  "**terminal-first + vault**," not "vault" alone.

---

## 4. Prioritized roadmap 🧭

Strategic judgement, ordered by leverage. Revisit as the market moves.

| # | Initiative | Why it matters | Effort |
|---|---|---|---|
| **P1** | **AI command assist + agent integration** | The market's defining gap; pairs with our SSH context (AI that knows *which host*). Start by embedding an agent CLI (e.g. Claude Code) rather than building an LLM UI from scratch. | High (phased) |
| **P2** | **Live session sharing** | Completes the team story — share the *secret* **and** the *session*; differentiates the vault. | Med-High |
| **P3** | **Cross-platform — Linux first, then Windows** | Neutralizes Termius's structural win. Linux is comparatively cheap (Ghostty already has a GTK apprt); Windows is the hard, long-horizon lift (blocked on `libghostty`). | Linux: Low-Med / Windows: High |
| **P4** | **tmux / multiplexer integration** | Table-stakes vs WezTerm / iTerm2 for power users; persistent/detachable sessions. | Medium |
| **P5** | **Ansible-native connection sync** | Meets Infra-as-Code teams where they live; unique angle vs Warp (no SSH manager) / Termius (no IaC). Read-only import of Ansible inventory → hosts + groups, plus group-driven theming. See §5. | Low-Med (phased) |

### The wedge (recommended focus) 🧭
Our most **defensible** play is **P1 + P2 fused**: an **AI agent that operates
across our saved hosts and team vault, with shareable live sessions.** Neither
Warp (no SSH manager / vault) nor Termius (no AI) has this intersection — it's
unique to our positioning.

---

## 5. DevOps / Ansible integration — meet IaC teams where they live 🧭

assessed here against our architecture.
**Strategic thesis:** teams that have fully adopted Ansible treat their **inventory as
the single source of truth**; a manual visual connection manager feels like a step
backward. The pitch flips ownership: *"don't manage connections in SarvTerminal —
manage them in Ansible, and let SarvTerminal give those servers a high-performance,
visually secure UI."* This is a differentiator **neither Warp (no SSH manager) nor
Termius (no IaC integration) covers** — confirmed against the 2026-07-15 scan. ✅

Three ideas, ordered by leverage / feasibility:

### 5.1 Ansible Dynamic Vault — auto-sync inventory → host list ⭐
- **Idea (Ankur):** parse the team's Ansible inventory (static `hosts.yml`/INI, or a
  **dynamic inventory** script / AWS/GCP plugin) and auto-populate the host list,
  preserving Ansible groups (`[webservers]`, `[databases]`) as our host groups. Watch
  the path so new servers appear automatically; zero manual entry.
- **Feasibility 🧭:** **strong fit, Low-Med effort.** This is an extension of our
  existing **host import** + **ssh-config discovery**. Static inventory is plain
  INI/YAML; dynamic inventory is `ansible-inventory --list` → JSON, which is a solved
  parse. Ansible groups map 1:1 onto our existing host **groups**.
- **Design constraints 🧭:**
  - **Read-only, one-way sync.** Imported hosts are managed *in Ansible*; don't let
    edits diverge from the inventory. Tag them as inventory-sourced; refresh on change.
  - **Security 🔸:** dynamic inventory scripts execute arbitrary code and may call cloud
    APIs — run them explicitly / with consent, not silently on a watched path.
    `group_vars` may be `ansible-vault`-encrypted; handle/skip gracefully.
  - Prefer Ansible's own tooling (`ansible-inventory`) over hand-rolling INI/YAML edge
    cases — matches our "use a maintained parser for solved problems" standard.

### 5.2 Context-aware per-host theming driven by Ansible groups/vars ⭐
- **Idea (Ankur):** map themes to **Ansible groups / vars** rather than to specific IPs.
  On SSH into a host in `[prod]` (or with `env: production` in `group_vars`), the window
  tints red — a visual safety net against acting on production by mistake.
- **Feasibility 🧭:** **good, Med effort.** We already have **per-host themes**; this
  generalizes the key from host→theme to group/var→theme, fed by the 5.1 importer. The
  "prod = red" guardrail is a cheap, memorable win that pairs naturally with 5.1.

### 5.3 Playbook-failure debugging + bastion/proxy-jump mapping
- **Idea (Ankur):** (a) right-click a host in the parsed inventory to instantly open an
  SSH session or **SFTP** tab to check logs (`/var/log/...`) — one-click post-failure
  debugging; (b) parse `ansible_ssh_common_args` **ProxyJump/bastion** args and visually
  map the active tunnels so engineers see how traffic routes.
- **Feasibility 🧭:** (a) is **mostly already there** — HostConnect + the SFTP browser;
  the new part is wiring them to inventory rows. (b) is the **most novel / highest
  effort**: parsing `ansible_ssh_common_args` for `-o ProxyJump=` / `ProxyCommand` is
  tractable, but a *live tunnel visualization* is new UI. The high-value, lower-cost
  slice is parse-and-connect (honor the proxy jump when opening a session); defer the
  visualization to a later phase.

**Recommended slice 🧭:** ship **5.1 (read-only importer) + 5.2 (group-driven theming)**
first — together they deliver the whole pitch with the least new surface, reusing host
import, groups, and per-host themes. 5.3(a) rides along nearly for free; defer 5.3(b).

---

## 6. Backlog / smaller ideas
Unranked; promote into the table above when scoped.
- **In-app Markdown viewer/editor** (Warp-style) — Cmd+Click a `.md` path opens an
  in-app viewer with **Rendered** (WKWebView) + **Source** (editable) modes and
  Save. Rendering is shared C in the core via **md4c** (already vendored at
  `pkg/md4c/`, GFM tables + task lists, SAFE/`NOHTML` mode); each platform builds
  only the viewer UI. Hook point: `Ghostty.App.swift` `openURL` (intercept local
  `.md`/text before `NSWorkspace`). Precedent: `HostManager/Files/FileViewerView`.
- Sixel image protocol (alongside existing Kitty graphics). 🔸
- Broadcast input to all panes/hosts.
- Command blocks / notebooks (Warp-style structured output), even without AI.
- Shareable "workflows" (parameterized command templates) beyond snippets.

---

## 7. Open items (unassessed competitors)
Not covered by the last verified scan — research before relying on these:
- **iTerm2** — tmux control-mode integration, triggers, Python API.
- **Wave Terminal** — AI + graphical widgets / blocks.
- **SecureCRT / Royal TSX** — enterprise credential brokering, non-SSH connection
  types (RDP/VNC/serial/telnet), session organization at scale.
- Terminal-core parity details (undercurl, precise image-protocol coverage) vs
  Kitty / WezTerm.

---

## 8. Caveats
- Verified sources are largely **vendor docs/changelogs** — reliable for
  confirming a feature *exists*, not for quality/performance benchmarks.
- Coverage skewed to **Warp / Termius / WezTerm**; other named competitors are
  partial (see Open items).
- Some Warp features are very recent (Nov 2025); the AI space moves fast — re-scan
  before committing large bets.

---

## Sources
Market scan 2026-07-15 (fact-checked, 25 verified claims):
- Warp — https://docs.warp.dev/changelog/2025/ , https://docs.warp.dev/terminal/comparisons/ , https://www.warp.dev/blog/reimagining-coding-agentic-development-environment , https://docs.warp.dev/knowledge-and-collaboration/session-sharing/
- Termius — https://termius.com/vault , https://termius.com/enterprise , https://termius.com/blog/meet-vaults , https://termius.com/pricing
- WezTerm — https://github.com/wezterm/wezterm
- Ghostty cross-platform — https://github.com/ghostty-org/ghostty/discussions/12290
