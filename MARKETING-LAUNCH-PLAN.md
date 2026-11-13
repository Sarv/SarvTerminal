# Sarv Terminal launch plan

Updated **2026-07-21** for Sarv Terminal **1.9.4**.

## Positioning decision

**The open-source Mac terminal for people who manage servers.**

Sarv Terminal should not compete on a generic "fast terminal" claim. Its wedge is the combination of
the Ghostty engine with a visual server-operations workspace: saved connections, SSH keys, SFTP/SCP,
tunnels, encrypted sync, container attach, and command-failure assistance.

### Primary audience

Mac-based developers, DevOps engineers, infrastructure engineers, consultants, and homelab users who
manage two or more remote systems and currently combine a terminal with separate SSH/SFTP tools.

### Proof points

1. Native macOS app built on the Ghostty engine.
2. Terminal and server operations in one workspace.
3. MIT licensed, no mandatory account, no bundled product telemetry.
4. Homebrew install plus signed and notarized releases.
5. User-controlled encrypted sync and BYOK/local AI options.

### Messaging guardrails

- Say **local-first**, not "nothing ever leaves the Mac." Optional sync and remote AI providers
  communicate externally when enabled.
- Do not lead with "zero knowledge" until the exact scope is explained.
- Disclose that saved-host passwords currently live in local `hosts.json`; recommend SSH keys until
  the Keychain migration ships.
- Describe Termius and SecureCRT as mature alternatives. The differentiation is the combined
  Mac-native, open-source workflow—not a claim that competitors cannot manage servers.
- Use reproducible evidence for performance claims; do not claim "fastest."

## Phase 0 — Trust and launch readiness

**Goal:** make every install safe, credible, and easy to evaluate.

### Work

- Move saved-host passwords into macOS Keychain. This is the primary security-marketing blocker.
- Test the DMG and Homebrew path on a clean Mac with Gatekeeper enabled.
- Verify signing, notarization, checksums, auto-update, uninstall, and rollback behavior.
- Run a compatibility pass covering zsh, bash, fish, tmux, SSH through a jump host, popular TUIs,
  Docker attach, Kubernetes attach, Unicode, and non-US keyboard layouts.
- Keep `README.md`, `COMPARISON.md`, screenshots, release notes, and the shipped feature set aligned.
- Publish a plain-language privacy and threat-model document.
- Add an opt-in first-run feedback link and a public known-issues section.

### Exit criteria

- No plaintext saved-host passwords.
- Ten clean-machine installs without a signing, Gatekeeper, or update failure.
- No known critical/high security defect.
- Every comparison row has a source and verification date.
- A new user can install and connect to a host in under five minutes.

## Phase 1 — Positioning and proof

**Goal:** show one memorable outcome instead of a long feature inventory.

### Core demonstration

Create a 20–30 second, silent captioned demo:

1. Open the host workspace.
2. Connect through a saved profile or proxy jump.
3. Transfer a file in SFTP.
4. start a tunnel or attach to a container.
5. End on: **"We bring the terminal and server workspace together. Open source on Mac."**

### Assets

- One hero screenshot showing terminal + host workspace.
- One short workflow video and one GIF under a practical file-size limit.
- Three feature screenshots: connections, SFTP, and tunnels.
- An honest comparison page covering terminals and SSH managers separately.
- A founder story: why another terminal was necessary and why it is built on Ghostty.
- A technical post describing the architecture and upstream relationship.

### Customer discovery

Interview at least ten target users. Ask what they use today, how many systems they manage, the last
time remote work caused friction, and what would stop them from switching. Do not ask whether they
"like" the feature list.

### Exit criteria

- At least five target users install without live help.
- At least three use Sarv Terminal again after seven days.
- Users can repeat the positioning in their own words.
- Two attributable testimonials or case studies are approved.

## Phase 2 — Focused beta and contributor flywheel

**Goal:** earn evidence before a broad launch.

### Distribution

- Find 30–50 Mac-based developers/operators from existing relationships and relevant communities.
- Use GitHub Discussions for support and product feedback so answers stay searchable.
- Label several genuinely small, well-scoped contributor tasks.
- Publish weekly development notes and acknowledge every external contribution.
- Approach maintainers of complementary tools—Starship, tmux, Neovim, yazi, Zellij, Docker and
  Kubernetes TUIs—for compatibility testing, not promotional endorsement.

### Exit criteria

- 30 activated testers.
- Seven-day return rate of at least 25% among testers who consent to measurement.
- Five resolved usability or compatibility issues from outside feedback.
- First maintainer response within 24 hours during the beta.
- At least two external contributors or documentation improvements.

## Phase 3 — Public launch sequence

**Goal:** compound attention across two weeks while the team remains available to respond.

### Day 0 — GitHub and release

- Publish a stable release with signed DMG, checksums, release notes, known limitations, and direct
  Homebrew instructions.
- Pin a welcome Discussion for feedback and migration questions.
- Update the website, repository social preview, and screenshots at the same time.

### Day 1 — macOS community

For `r/macapps`, use the main feed only after satisfying the community's current rules: 10 local
karma, the required promotion template/approval path, relationship disclosure, and no more than one
developer promotion in 30 days. Otherwise use the monthly promotion megathread.

Current account check (2026-07-21): `u/NetworkDue5038` has no recorded `r/macapps` local karma.
The eligible route is the pinned July 2026 **App Pile** megathread, but its moderator warning says a
first linked comment is likely to be auto-removed until the account has earned 10 local karma without
promotional comments or links. Participate genuinely before submitting; do not manufacture engagement.

Megathread PCP-format draft (post only after the account is eligible):

> **[OS] Sarv Terminal: a native Mac terminal for people who manage servers**
>
> **Problem:** We work on Sarv Terminal. We built it for Mac users who want a fast terminal but also
> need to manage saved SSH hosts, move files, and create tunnels without switching between several
> tools. It includes tabs and splits, saved SSH profiles, SSH key management, SFTP and SCP, local,
> remote and SOCKS tunnels, Docker and Kubernetes attach, and optional encrypted settings sync. No
> account is required.
>
> **Comparison:** Ghostty and iTerm2 are excellent terminal emulators, but server management is not
> their main workflow. Termius and SecureCRT offer stronger connection management, but they are
> proprietary products. Sarv Terminal combines a Ghostty-based terminal with built-in server tools
> and is free under the MIT license. It is currently Mac-only. Saved-host passwords have not yet
> moved to Keychain, so we recommend SSH keys.
>
> **Pricing:** Free and open source. Download or install with Homebrew:
> https://github.com/Sarv/SarvTerminal
>
> We would value feedback on SSH compatibility, SFTP workflows, and any blockers to daily use.

Suggested title:

> [OS] Sarv Terminal — a native Mac terminal with saved SSH hosts, SFTP and tunnels

Suggested body:

> Disclosure: We work on Sarv Terminal. It is a free MIT-licensed macOS terminal built on Ghostty for
> people who manage multiple servers. Alongside tabs and splits, it includes saved SSH profiles,
> SSH-key management, SFTP/SCP, local/remote/SOCKS tunnels, Docker/Kubernetes attach, and optional
> encrypted settings sync. No account is required.
>
> The project is still Mac-only, and saved-host passwords have not yet moved to Keychain, so SSH
> keys are recommended. We would especially value feedback on SSH compatibility, SFTP workflows,
> and any blockers to daily use.
>
> GitHub and downloads: https://github.com/Sarv/SarvTerminal

Respond to every substantive comment. Do not ask for votes or coordinate artificial engagement.

### Day 3 — Show HN

Suggested title:

> Show HN: Sarv Terminal – an open-source Mac terminal for managing servers

The founder must write the submission personally. Hacker News currently prohibits generated or
AI-edited comments, requires a product people can try without a signup barrier, and prohibits vote
solicitation. Explain the origin, architecture, Ghostty relationship, trade-offs, and security scope.

### Days 5–7 — Technical communities

Create distinct posts for `r/commandline`, `r/opensource`, `r/developersIndia`, and any community
for the implementation language where the engineering story is genuinely relevant. Check each
community's current rules immediately before posting. Do not cross-post identical promotional copy.

### Days 8–14 — Product Hunt and editorial outreach

- Launch on Product Hunt only after the first feedback round is resolved.
- Tagline: **A native Mac terminal with server operations built in.**
- Prepare the maker comment, demo, screenshots, and direct product URL in advance.
- Submit to developer-tool newsletters and small creators with a factual three-line pitch, demo, and
  clear disclosure. Prioritize editorial fit over audience size.

## Phase 4 — Compounding growth

**Goal:** turn releases and community work into repeatable discovery.

Publish one useful artifact each week:

- a transparent performance or memory investigation;
- an SSH/SFTP compatibility report;
- a migration guide from iTerm2, Ghostty, Termius, SecureCRT, or Tabby;
- an engineering deep dive into a real problem;
- a contributor story;
- a short workflow video;
- a meaningful release note with before/after evidence.

Build search pages around user jobs, not keyword stuffing: "open-source SSH manager for Mac," "Mac
terminal with SFTP," "GUI SSH tunnel manager for macOS," and "Ghostty-based SSH client."

## Measurement

GitHub stars are useful social proof, not the north-star metric.

| Funnel stage | Metric | Initial target |
|---|---|---:|
| Discovery | Qualified website/repository visits | 1,000 in first 30 launch days |
| Acquisition | Visit-to-download conversion | 25% |
| Activation | Successful first terminal + first saved connection | 60% of installers |
| Retention | Seven-day return rate | 25% |
| Quality | Install/signing failure rate | under 2% |
| Community | Meaningful external feedback conversations | 25 in 90 days |
| Contribution | External contributors with merged work | 5 in 90 days |
| Responsiveness | First maintainer response during launch | under 24 hours |

Use transparent, privacy-respecting measurement. If application analytics are added, make the event
schema public, collect the minimum required data, and provide a clear opt-in choice.

## Manual approval gates

The following actions require a maintainer or account owner:

1. Security approval before making credential-safety claims.
2. Moderator approval and local-karma eligibility for an `r/macapps` main-feed post.
3. Founder-written Hacker News submission.
4. Final confirmation immediately before publishing any external post or sending outreach.
5. Account login, CAPTCHA, verification code, payment, or legal/trademark decision.

## Distribution audit (2026-07-21)

- Latest release: `v1.9.4`, published 2026-07-17 with a 35 MB DMG, SHA-256 digest, source archives,
  and a GitHub release attestation.
- Homebrew cask: `sarv/tap/sarv-terminal` points to `v1.9.4` and its SHA-256 exactly matches the
  GitHub release asset.
- The Homebrew cask requires macOS Ventura or newer and declares Sparkle-managed auto-updates.
- Launch-page copy should state the macOS version requirement next to the install call to action.

## Current platform references

- [Show HN guidelines](https://news.ycombinator.com/showhn.html)
- [Hacker News guidelines](https://news.ycombinator.com/newsguidelines.html)
- [Product Hunt launch guide](https://www.producthunt.com/launch)
- [GitHub repository best practices](https://docs.github.com/en/repositories/creating-and-managing-repositories/best-practices-for-repositories)
- [Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Homebrew acceptable casks](https://docs.brew.sh/Acceptable-Casks)
