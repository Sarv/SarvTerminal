# Upstream Merge Guide

This document lists every custom change made to this fork so that when we pull
in upstream commits from [warpdotdev/warp](https://github.com/warpdotdev/warp)
we can re-apply or verify each one.

## Merge strategy

This repo is a fork of the public OSS repo.  The safest workflow is:

```bash
# 1. Add upstream remote (one-time)
git remote add upstream https://github.com/warpdotdev/warp.git

# 2. Fetch latest upstream commits
git fetch upstream

# 3. Rebase our custom commits on top of upstream/master
#    (cherry-pick one commit at a time if the rebase gets messy)
git rebase upstream/master

# 4. Re-check every file listed below for conflicts and re-apply any
#    hunk that was lost.

# 5. Build to confirm
bash Ankur/build.sh
```

Last upstream commit included in this branch as of writing: **a4d19abd**
(`Use searchable dropdown for run_agents model picker (#11753)`)

---

## Custom changes (by file)

### `Ankur/build.sh` _(new file)_
Convenience script that sets `WARP_OSS_QUIET=1` and calls `./script/run`.
No conflicts expected — file did not exist upstream.

---

### `script/run`
- Guard around `./script/install_channel_config` — skipped when
  `WARP_OSS_QUIET=1`.
- Guard around common-skills install — set `INSTALL_COMMON_SKILLS=0` when
  `WARP_OSS_QUIET=1`.

**Why:** Suppresses noisy "no repo access" and skills-lock messages that are
irrelevant for a local OSS build.

**Conflict risk:** Medium — upstream touches this file occasionally.  
**Re-apply:** After merge, check that both `if [[ "${WARP_OSS_QUIET:-}" != "1" ]]`
guards are still present around the channel-config and common-skills blocks.

---

### `crates/warp_features/src/lib.rs`
Added three flags to `DOGFOOD_FLAGS` (or equivalent always-on list):
- `FeatureFlag::SshManager`
- `FeatureFlag::SyncManager`
- `FeatureFlag::SkipFirebaseAnonymousUser`

**Why:** These flags are gated off in the OSS channel by default; enabling them
here avoids the Firebase login screen and surfaces SSH Manager + Sync Manager.

**Conflict risk:** Low — upstream rarely changes individual flag lists.  
**Re-apply:** After merge, grep for `DOGFOOD_FLAGS` or `SkipFirebaseAnonymousUser`
and confirm the three flags are still present.

---

### `app/src/bin/oss.rs`
After `ChannelState::set(state)`, apply extra feature flags:

```rust
use warp_core::features::FeatureFlag;
// …
state = state.with_additional_features(&[
    FeatureFlag::SshManager,
    FeatureFlag::SyncManager,
    FeatureFlag::SkipFirebaseAnonymousUser,
]);
ChannelState::set(state);
```

**Why:** Belt-and-suspenders — ensures the flags are on even if the
`warp_features` crate approach above is insufficient in OSS channel.

**Conflict risk:** Low.  
**Re-apply:** Check the block after `ChannelState::set(state)`.

---

### `app/src/settings_view/about_page.rs`
Version string shows `"Ankur-custom-build"` when
`FeatureFlag::SkipFirebaseAnonymousUser` is enabled, instead of the real version
number.

```rust
let version = if FeatureFlag::SkipFirebaseAnonymousUser.is_enabled() {
    "Ankur-custom-build"
} else {
    ChannelState::app_version().unwrap_or("v#.##.###")
};
```

**Conflict risk:** Low.  
**Re-apply:** Look for the `version` binding near the top of `AboutPageWidget::render`.

---

### `app/src/settings_view/nav.rs`
Added `ActionButton` variant to `SettingsNavItem` enum and a
`render_action_button` method:

```rust
pub enum SettingsNavItem {
    Page(SettingsSection),
    Umbrella(SettingsUmbrella),
    ActionButton { label: &'static str, state: MouseStateHandle },
}
```

**Why:** Lets us add sidebar entries that open tool panels (SSH Manager, Sync
Settings) without touching the `SettingsSection` enum (which is referenced in
43+ files).

**Conflict risk:** Medium — upstream may evolve `SettingsNavItem`.  
**Re-apply:** After merge, check that the `ActionButton` variant and its render
method are still present and that all `match` sites compile.

---

### `app/src/settings_view/mod.rs`

Three related changes:

1. **`MouseStateHandle` added to `warpui::elements` import** (line ~37).

2. **`local_mode` block** (after `nav_items` vec is built): removes
   Warp-account-specific sections from the sidebar and injects
   `ActionButton` items for SSH Manager and Sync Settings:

   ```rust
   let local_mode = FeatureFlag::SkipFirebaseAnonymousUser.is_enabled();
   // … nav_items vec …
   if local_mode {
       nav_items.retain(/* remove Account, BillingAndUsage, Teams, Warpify,
                           WarpDrive, Referrals, Agents umbrella,
                           Code umbrella, Cloud platform umbrella */);
       // insert SSH Manager + Sync Settings ActionButtons after Keybindings
   }
   ```

3. **`ActionButton` arm in sidebar render loop** (~line 2510): calls
   `render_action_button` and dispatches `WorkspaceAction::ToggleSshManager`
   or `WorkspaceAction::ToggleSyncManager`.

4. **`ActionButton` arm in `build_nav_stops`** and in the
   `first_visible` flat_map: returns `vec![]` so arrow-key nav ignores them.

**Conflict risk:** High — this file is large (~2 600 lines) and frequently
changed upstream.  
**Re-apply:** After merge, search for `local_mode` to find the filter block and
sidebar loop arm. Confirm all four touch-points are intact.

---

### `app/src/workspace/action.rs`
Added:

```rust
ToggleSshManager,
ConnectSshHost { … },
ToggleSyncManager,
```

and their `is_sensitive` / `requires_user_action` arms.

**Conflict risk:** Medium — upstream adds workspace actions regularly.  
**Re-apply:** Check `WorkspaceAction` enum and the relevant `match` arms.

---

### `app/src/workspace/mod.rs` and `app/src/workspace/view.rs`
Wire-up for `ToggleSshManager`, `ToggleSyncManager`, and `ConnectSshHost`
in the workspace action handler. Three additional changes:

1. **Password-free SSH** (`ConnectSshHost` handler, ~line 22002): when `pass`
   is non-empty, wraps the SSH command with `expect` to inject the password
   automatically before handing the session to the user via `interact`. Falls
   back to plain `ssh -o StrictHostKeyChecking=no` when password is empty.

   ```rust
   let cmd = if pass.is_empty() {
       format!("ssh -o StrictHostKeyChecking=no -p {port} {user}@{host}")
   } else {
       let escaped = pass.replace('\\', "\\\\").replace('"', "\\\"");
       format!("expect -c 'set timeout 30; spawn ssh … ; expect -re {{[Pp]assword:}}; send \"{escaped}\\r\"; interact'")
   };
   ```

2. **Gear menu cleanup** (`user_menu_items`, ~line 8530): early-returns a
   minimal two-item list (Settings + Keyboard shortcuts) when
   `FeatureFlag::SkipFirebaseAnonymousUser` is enabled, hiding all Warp
   account-specific items.

3. **Left panel always shown** (`compute_left_panel_views`, ~line 21561):
   forces `ToolPanelView::ProjectExplorer` into the views list when
   `SkipFirebaseAnonymousUser` is enabled, regardless of the
   `show_project_explorer` user setting.

**Conflict risk:** Medium-High — workspace view is very large.  
**Re-apply:** Search for `ToggleSshManager`, `SkipFirebaseAnonymousUser`, and
`ConnectSshHost` in both files.

---

### `app/src/lib.rs`
Declares the `ssh_manager` and `sync_manager` modules:

```rust
pub mod ssh_manager;
pub mod sync_manager;
```

---

### `app/src/ssh_manager/` _(new directory)_
Entire SSH Manager feature: `manager.rs`, `host_form.rs`, `model.rs`, `db.rs`.
No upstream conflict — files did not exist before.

---

### `app/src/persistence/mod.rs` and `persistence/sqlite.rs`
Database initialisation updated to run SSH / Sync schema migrations.

---

### `crates/persistence/src/model.rs` and `schema.rs`
Diesel model and schema for `ssh_groups` and `ssh_hosts` tables.

---

### `crates/persistence/migrations/`
Two new migration directories:
- `2026-05-28-100000_create_ssh_groups/`
- `2026-05-28-100001_create_ssh_hosts/`

No upstream conflict — new files.

---

## Checklist after each upstream merge

- [ ] `cargo check --bin warp-oss` passes with no errors
- [ ] About page shows "Ankur-custom-build"
- [ ] No Firebase login screen on launch
- [ ] Settings sidebar shows: Appearance, Features, Keybindings, SSH Manager,
      Sync Settings, Shared Blocks, Privacy, About — and hides Account,
      BillingAndUsage, Agents, Teams, Code, Cloud platform, Warpify,
      WarpDrive, Referrals
- [ ] Clicking "SSH Manager" in sidebar opens the SSH Manager panel
- [ ] Clicking "Sync Settings" in sidebar opens the Sync Settings panel
- [ ] Top-right gear menu shows only "Settings" and "Keyboard shortcuts"
- [ ] Left panel (Project Explorer) button visible in header toolbar
- [ ] Connecting to an SSH host with a saved password logs in without prompting
- [ ] `bash Ankur/build.sh` launches the app without noisy channel-config or
      skills-lock messages
