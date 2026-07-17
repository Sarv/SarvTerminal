# Linux / GTK Port Roadmap

This file is the **single hand-off document** for porting the macOS *Vaults* terminal
behavior to the Linux/GTK app (`src/apprt/gtk`). Each section captures one landed
macOS change: the **symptom**, the **root-cause reasoning**, the
**platform-agnostic logic** (the actual algorithm/behavior, independent of
toolkit), the **macOS → Linux/GTK equivalents** (which AppKit/Swift/libproc/ARC
mechanism maps to which GTK/Zig one), and **how to verify on Linux**.

Goal: a future engineer or AI agent can read *only this file* and reproduce the
exact same behavior on Linux, without re-deriving the reasoning.

> **Shared core, two apprts.** The pty, child process, IO/render threads, titles,
> pwd (OSC 7), and the `needs_confirm_quit` signal all live in **libghostty**,
> which both apprts share. Most of these fixes are apprt-level policy over that
> shared core — the same C/Zig APIs the macOS layer calls are available to the GTK
> apprt. Reuse them; don't reinvent process detection, pty lifecycle, or title/pwd
> tracking.

### Maintenance rule
Update this file **at commit time** (not per edit): whenever a change under
`macos/` is committed, add a matching section here in the same commit. Commits land
only after multiple test/fix iterations once the code runs correctly, so the entry
records the final working logic — not intermediate churn. See `AGENTS.md`
("Linux/GTK Port Roadmap").

### Source commits (macOS)
| # | Commit | Summary |
|---|---|---|
| 1 | `4b8e19d85` | `fix(vaults): release closed tabs' surfaces immediately to stop process/thread leak` |
| 2 | `72519e1b2` | `fix(vaults): make tab-chip close, select, and drag hit detection reliable` |
| 3 | `d794f9515` | `feat(vaults): derive pane titles from foreground process and cwd` |
| 4 | `8f2a0952d` | `feat(vaults): confirm before closing a tab or pane with a running process` |
| 5 | `bdcbe43a7` | `refactor(vaults): make bare tab/pane closers private so the close confirmation can't be bypassed` |

---

# Part I — Reliability fixes & hardening (recent)

_The five focused fixes/refactors from the latest hardening pass. Sections 6+ (Part II) document the foundational Sarv subsystems from source across the full macOS history._

## 1. Release closed-tab surfaces immediately (leak fix)

### Symptom
After a normal work session of opening and closing terminal tabs, the whole machine degrades: new shells fail to spawn (`zsh: fork failed: resource temporarily unavailable`), opening a new terminal errors with `error starting IO thread: error.SystemResources`, Activity Monitor shows a large and growing pile of `node`/shell processes, and the OS starts killing background services. Force-quitting the stray processes restores the machine instantly. It looks like a slow memory/handle leak but is really **resource (process/thread/FD) exhaustion**.

### Root cause & reasoning
The "reopen last closed tab" feature retained each closed tab as the **live tab object**, keeping its entire surface tree alive in a `closedTabs` buffer (capped at 25). A closed tab was therefore never actually torn down — every one of its panes kept:
- a live child process (login shell, and **anything it spawned** — dev servers, `node`, agents),
- the pty, plus the per-surface IO thread and render thread.

So each close leaked ~1 shell + N child processes + several threads, bounded only by the 25-entry buffer — but the child processes those shells had spawned (e.g. `node`) were **not** bounded and kept accumulating and re-parenting.

Confirmed empirically via macOS jetsam reports: **4 jetsam events across 2 days**, kill reasons `vm-compressor-space-shortage` and `per-process-limit`, with **hundreds of system daemons jettisoned** (111 → 1241 → 291 in three of the events). The aggregate `node` footprint across the stranded processes was **75–118 GB**, and the app itself sat at 1.4–2.5 GB. That is the direct cause of the compressor shortage and the `fork()` failures — exactly the fork-exhaustion symptom above.

### The fix (platform-agnostic logic)
Stop retaining live tabs. On **every** close path (single tab, "close others", "close to the right"):

1. **Snapshot, don't retain.** Capture the closing tab as a lightweight immutable **value**: its split-tree layout plus, per pane, its working directory (local) or its SSH host/reconnect info (remote). A few KB — no live handles.
2. **Release live resources immediately.** Drop the last reference to the tab's surfaces so they are destroyed *now*: this kills each pane's child process, closes the pty, and joins the IO + render threads. Also tear down any per-pane SSH connection controllers/popups. Snapshot **before** teardown so the reconnect info can still be read from the live connection registry.
3. **Bounded, time-limited reopen buffer.** Keep only the last `maxClosedTabs` snapshots (10), and only for `closedTabRetention` (5 min); evict older ones on reopen. Because entries are values, not live surfaces, this cap is a UX choice with negligible memory cost — never a resource cap.
4. **Reopen = recreate from snapshot.** "Reopen closed tab" rebuilds the tab from the value: local panes respawn at their saved cwd, SSH panes reconnect, inserted back at (near) the original index.

Invariant: **a closed tab owns zero live processes/threads the instant it leaves the tab list.** The reopen buffer can never strand a running terminal.

### macOS specifics → Linux/GTK equivalents
- **ARC drop → explicit teardown.** macOS relied on Swift ARC: dropping the last strong reference to the surface view triggered `deinit`, which freed the libghostty surface (killing the pty/child, joining threads). The GTK/Zig apprt has no ARC — the port must **explicitly call the surface close/free** for every pane of the closed tab (the libghostty surface destroy path), rather than merely removing the tab from a list/model. Removing the widget from the container is **not** enough; the underlying surface must be freed.
- **libghostty owns the pty + threads.** On both platforms the pty, child process, and IO/render threads live inside libghostty's surface, not the apprt. So the fix is the same shape everywhere: the apprt must invoke the surface-destroy entry point immediately on close. Verify the GTK apprt isn't caching surface pointers (e.g. for undo/reopen) — if it is, apply this same snapshot-and-release change there.
- **Snapshot type.** macOS reused its existing `SavedSession` value type (session persistence). The GTK port should reuse whatever session/layout serialization it already has (or a small struct: tree layout + per-pane {cwd | ssh host}); do **not** stash the live tab/surface struct.
- **Reopen buffer.** A plain in-memory ring/list of snapshots with count + age eviction — no platform APIs needed. Timestamp source differs (use the GTK/Zig monotonic clock) but the 10-entry / 5-min policy ports directly.

### How to verify on Linux
- **Process/thread accounting:** note `ps -A | wc -l` and the app's thread count (`ps -M <pid>` / `/proc/<pid>/task | wc -l`) with a tab open running `node` (or any long-lived child); close the tab; both must drop back. Repeat 20× — counts must return to baseline, not climb.
- **No orphaned shells:** after closing tabs, `pgrep -P 1 -fl node` / `zsh` (and descendants of the app pid) must show nothing stranded from closed tabs.
- **Reopen still works:** close a tab, reopen within 5 min → layout + cwd/SSH restored at the original position; reopen after 5 min or after 10 newer closes → correctly gone.
- **Under pressure:** open/close many child-bearing tabs in a loop while watching `free -m` / `/proc/pressure/memory`; memory and process count must stay flat. Confirm no OOM-killer activity in `dmesg` / `journalctl -k` (the Linux analogue of the jetsam events) attributable to stranded terminals.

---

## 2. Reliable tab-chip close / select / drag hit detection

A single low-level input view (`TabChipInteractionView`, wrapped for SwiftUI by `TabChipInteraction`) owns **all** pointer handling for a tab chip — cursor, hover highlight, close-✕ highlight, click→close-vs-select, and drag-to-reorder — so there is exactly one hit-test authority and no framework hit-test race between the platform toolkit and the declarative UI layer.

### Symptom
Without this logic the tab strip misfires in three ways:
- **Accidental close on select** — a click meant to switch to a tab closes it, because the click grazed the leading edge where the ✕ lives (or the whole chip counted as "close").
- **Drag treated as click** — a quick drag-to-reorder ends by closing/selecting the tab out from under the reorder, because the drag-started signal arrives asynchronously and a fast `release` beats it.
- **Stale close-✕ on the wrong chip** — the ✕ stays lit on a chip the pointer is no longer over (or fails to light on the one it now is over) after the strip moves under a stationary cursor (auto-scroll on ⌘-number, a neighbor tab closing, a new tab inserted).

### The behavior (platform-agnostic logic)
- **Close-hit band.** The ✕ occupies a band on the chip's **leading** edge defined by two values in points from the leading edge: `closeHitLeadingInset` (default **8**) and `closeHitWidth` (default **26**); the visible ✕ is drawn with ~10pt padding over a 14pt icon slot (≈ x 10–24), and the band adds a little slack on each side. A point is "on the close button" iff it is inside the chip bounds **and** `leadingInset ≤ x ≤ hitWidth`. This single predicate (`isInCloseRegion`) is the one source of truth for the cursor, the close-hover highlight, and the close-on-click decision — never re-derive it inline anywhere.
- **Press+release-both-in-region to close.** A release is a **close** only when **both** the original press **and** the release land inside the close band; otherwise it is a **select**. Requiring the press to start there too stops a tab-switch click that merely grazes the leading edge from closing. A release that drifts entirely off the chip (implicit pointer capture still delivers it) is **neither** close nor select — ignore it.
- **Drag vs click.** A drag session starts once the pointer moves past a **3pt** threshold from the press point. At that instant set a **synchronous `didBeginDrag` flag** (cleared on the next press). The release handler treats the gesture as a click only when neither the toolkit's own "drag in progress" state **nor** `didBeginDrag` is set. This flag exists because the toolkit's drag-begin callback is **asynchronous**, so a fast gesture can reach the release handler before the toolkit marks the drag as active — the synchronous flag closes that window.
- **Hover reconcile on geometry change.** Hover/close-hover are normally driven by enter/exit/move events, but a chip that **moves under a stationary pointer** emits no such event, so the state goes stale. On every frame-origin/size change, schedule a **reconcile** that reads the pointer's *actual* current position and recomputes hover + close-hover directly. Coalesce all reconciles to **one per event-loop tick** (a `reconcileScheduled` guard + async dispatch) so a burst of layout changes triggers a single recompute; skip it entirely while a drag owns the pointer, and clear both hover states when the window is hidden. Run it asynchronously so you never mutate declarative-UI state from inside a layout pass and so you read the pointer after geometry settles.

### macOS specifics → Linux/GTK equivalents

| macOS (AppKit) | Linux / GTK4 equivalent |
| --- | --- |
| `NSView` subclass owning events | A custom widget (or a plain `GtkDrawingArea`/`GtkBox`) with attached event controllers |
| `updateTrackingAreas` + `mouseEntered/Exited/Moved` | `GtkEventControllerMotion` (`enter`, `leave`, `motion` signals) |
| `mouseDown` / `mouseDragged` / `mouseUp` | `GtkGestureClick` (`pressed`/`released`) for the click, `GtkGestureDrag` (`drag-begin`/`drag-update`/`drag-end`) for the reorder |
| `resetCursorRects` + `NSCursor` (`.arrow`, `.openHand`, `.closedHand`) | `gtk_widget_set_cursor` with `GdkCursor` (`default`, `grab`, `grabbing`), swapped in the motion handler per `isInCloseRegion` |
| `NSDraggingSource` + `NSPasteboardItem` (drag payload = tab id) | GTK drag source via `GtkDragSource` with a `GdkContentProvider` carrying the tab id |
| `window.mouseLocationOutsideOfEventStream` (poll pointer) | `gdk_device_get_position` / `gdk_surface_get_device_position` on the pointer device |
| `setFrameOrigin` / `setFrameSize` overrides → reconcile | `size-allocate` / `notify::` on position, or a `GtkEventControllerMotion` re-query after layout |
| `DispatchQueue.main.async` coalescing | `g_idle_add_once` (or a single-shot flag guarding a `g_idle_add`) on the main context |

The async-drag-start race is **not** macOS-specific: GTK's `GtkGestureDrag::drag-begin` also fires only after GTK's own drag threshold, and gestures in the same group can resolve in either order. Reproduce the guard exactly: set your own `did_begin_drag` boolean synchronously inside `drag-update` the first time movement exceeds the 3pt threshold (or in `drag-begin`), clear it on the next `pressed`, and have the `GtkGestureClick::released` handler bail if it is set. Do **not** rely solely on `gtk_gesture_is_active`/`GTK_EVENT_SEQUENCE_CLAIMED` — the whole point is to cover the window before the toolkit claims the sequence. Also mirror the "release drifted off the widget" guard by checking the release coordinates against the widget allocation.

### How to verify on Linux
- **Select vs close:** click the body of a tab → it activates, does not close. Click squarely on the ✕ → it closes. Click that starts just left of the ✕ (in the dead padding) and releases → selects, does not close.
- **Press/release split:** press on the ✕ but release off it (or off the chip) → nothing closes; press off the ✕ and release on it → selects, does not close.
- **Grazing click:** a fast tab-switch click whose path clips the leading close band → selects, never closes.
- **Drag not a click:** quickly drag a chip past the threshold and release over another chip → it reorders and neither closes nor selects; a sub-threshold micro-move still counts as a click.
- **Hover freshness:** with the pointer held perfectly still over one chip, trigger a strip shift (jump to a tab via ⌘/Ctrl-number, close a neighbor, add a tab) → the hover highlight and ✕ move to whatever chip is now under the pointer, with no stale ✕ left behind; verify a burst of changes causes a single reconcile, and that hover clears when the window hides.

---

## 3. Shell-independent pane titles (process + cwd)

### Symptom
Pane and tab titles were whatever the shell emitted via the OSC 0/1/2 title escape. With oh-my-zsh's `precmd`/`preexec` hooks, an idle pane showed `user@host:~` while a busy pane showed the raw command line — so two panes in the same split "disagreed," and the format differed for every user depending on their shell/theme (Powerlevel10k, a bare `sh`, etc.). It could not be normalized by editing the user's shell, because we don't control every user's dotfiles.

A second, subtler bug surfaced after the first fix: a transient command title (e.g. `node -e "…"`) got captured into the pane's **sticky override** (on split-seed and on session save/restore), so it stayed pinned as the pane title forever — even after the process exited and the pane went idle. Inspection showed all panes were idle `zsh` yet still displaying `node`.

### Why not fix it in the shell
The terminal title is a single OSC channel and **whoever writes last wins** — the shell's `precmd`/`preexec` will always overwrite anything the app injects (even the app's own shell integration). We cannot reach into every user's shell config, and racing the shell on the same channel is unwinnable. The correct fix is to stop trusting the OSC title as the source of truth and **derive the title in the app** from signals the app owns (foreground process + cwd), i.e. own it at the app/action layer, not the shell layer. The shell's OSC title is used only for one case: an explicit in-app rename (see precedence).

### The derivation (platform-agnostic logic)
One pure, shared function is the single source of truth for every pane title (used by both the split header and the focus-mode sidebar, so they can't drift). Strict precedence:

1. **User rename** — an explicit "Change Terminal Title" the user set through the app. This is the ONE case where the surface's own title is authoritative.
2. **Sticky override** — a meaningful name attached to the pane: an SSH host label, or a name carried in when a tab was dragged into a split / a pane was split off.
3. **Foreground process name** — `node`, `ssh`, `vim`, … when a real command is running.
4. **Working-directory folder** — when idle at the shell.
5. **`"Terminal"`** — last resort.

Supporting rules:
- **Shell-name denylist** (`zsh`, `bash`, `sh`, `fish`, `dash`, `tcsh`, `csh`, `ksh`, `login`): when the foreground process is one of these, treat the pane as *idle* and fall through to the cwd instead of showing "zsh". Compare case-insensitively and strip a leading `-` (login shells carry `-zsh` in `argv[0]`, though `p_comm`/`/proc/<pid>/comm` usually omits it — strip defensively).
- **cwd folder rules**: home → `~`; root → `/`; otherwise the last path component. nil when there's no usable cwd.
- **Reactivity**: the derivation is recomputed whenever the surface's title or pwd change signal fires (these fire on command boundaries via shell integration / OSC 7), so the pane updates live without polling.

**Core invariant (do not violate on any platform):** sticky overrides and persisted titles must **never** hold a transient live OSC title. Only stable names belong there — a user rename or an SSH host label. Concretely:
- **Split seed**: when splitting/duplicating, inherit the source pane's override ONLY if it's already a stable override; never seed from the source's live title (that's what pinned `node`). A fresh pane's derived title (process/cwd) is correct immediately, so no seed is needed.
- **Persist (save)**: save `title` only if it's a user rename or a stable override; a plain local pane persists `nil` and re-derives on reopen. Add a `titleIsUserSet` flag to the saved pane so restore can tell a real rename from a captured command.
- **Restore**: re-pin a title override ONLY for an SSH pane (host label — a blank SSH surface has no title of its own) or when `titleIsUserSet == true`. A local pane is left to derive live. This also self-heals sessions saved before the flag existed (`nil` ⇒ treated as not-user-set ⇒ not pinned).

### macOS specifics → Linux/GTK equivalents
- **Foreground process name.** macOS: `ghostty_surface_foreground_pid` → libproc `proc_name(pid, …)` returns `p_comm`. Linux: resolve the pty's foreground process group id, then read the name from `/proc/<pid>/comm` (or `/proc/<pid>/stat` field 2, stripping the parens). Prefer using libghostty's foreground-pid API if exposed to the GTK apprt (same call the macOS side uses under the hood) and only do the `/proc` read for the name. Return nil if the pid can't be read.
- **Reactivity.** macOS relies on SwiftUI `@Published` `title`/`pwd` on the surface to re-run the derivation. On GTK, wire the equivalent notify/signal — re-derive and update the tab/pane header label when libghostty reports a title change or an OSC 7 pwd change (libghostty already tracks pwd via OSC 7 on both platforms). If no such signal is convenient, a low-frequency poll of the foreground pid is an acceptable fallback, but the signal path is preferred.
- **cwd source.** Already provided by libghostty (OSC 7); no platform-specific work beyond reading the surface's reported pwd. Home-directory detection: use `$HOME` / `getpwuid` instead of macOS `FileManager.homeDirectoryForCurrentUser`.
- **Persistence.** Mirror the `titleIsUserSet` field and the save/restore pinning rules in whatever the GTK app uses for session persistence. The rule is platform-agnostic; only the serialization format differs.
- **Keep it one function.** Implement the precedence as a single pure function shared by every place that renders a pane/tab title, exactly as macOS does — this is what prevents the two-sites-drift bug.

### How to verify on Linux
- Idle pane shows the **cwd folder** (`~`, project name), not `zsh` and not `user@host:~`.
- Run `node -e "setInterval(()=>{},1000)"` → the pane header shows **`node`**; a sibling idle pane still shows its cwd.
- `cd` somewhere → header updates to the new folder name.
- Ctrl-C the process → header flips back to the cwd (no stale `node`).
- SSH pane shows the **host label**, not `ssh`.
- Split a pane **while a command is running** → the new pane shows its **own** cwd/process, never the source's running command.
- Save a session with a running command, reopen it → the restored pane shows cwd/process, **not** the command that happened to be running at save time.
- Titles look identical across users regardless of shell (test with a bare `sh`, bash, zsh+oh-my-zsh).

---

## 4. Confirm before closing a tab/pane with a running process

### Behavior
Closing anything that would kill a live process first shows a modal: **"Close Tab? / Close Terminal? — This … still has a running process. If you close … the process will be killed."** with a destructive **Close** and a **Cancel**. It prompts when a tab/pane is *busy* and closes silently when it is not. "Busy" covers a running foreground command, an interactive AI agent (e.g. Claude Code), and an active SSH connection; a bare idle shell is **not** busy and never nags. Bulk closes ("Close Other Tabs", "Close Tabs to the Right") prompt if *any* affected tab is busy. Quitting the whole app is guarded the same way, app-wide.

### The design (platform-agnostic logic)
- **One shared checkpoint.** A single helper — `confirmCloseIfRunning(surfaces, title, message, perform)` — is given the exact set of surfaces that the close would destroy. If none is busy it runs `perform()` immediately; if any is busy it shows the dialog and runs `perform()` only on confirm. All wording and the busy-test live in this one function so they can never drift between close paths.
- **The "busy" signal is a libghostty call**, not a bespoke heuristic: per-surface `ghostty_surface_needs_confirm_quit` (surfaced in the macOS layer as `needsConfirmQuit`). It already encodes "a process other than the shell is running" and honors the `confirm-close-surface` config. This is the same signal the quit path uses, so behavior is consistent everywhere. **It exists on both platforms — reuse it; do not reinvent process detection.**
- **Every user-initiated close routes through a thin `request…` wrapper** (`requestCloseTerminal`, `requestClosePane`, `requestCloseOtherTabs`, `requestCloseTabsToRight`) that gathers the doomed surfaces and calls the shared helper. The wrappers are the *only* public way to close; the actual teardown functions are private (see section 5) so a caller physically cannot skip the prompt.
- **The confirmation is anchored at the ACTION-dispatch layer, not at any key combo.** This is the key insight that makes it future-proof: the core emits a *close action* (e.g. `close_tab:this`, `close_surface`) regardless of which key/menu/gesture triggered it, and the app handles that action in one place, where the confirm lives. Therefore **any user-rebound shortcut, custom keybind, or menu item that maps to a close action is covered automatically** — there is nothing per-key to update. On macOS the core action callback posts a notification and the handler routes it through the wrapper; the Linux apprt has the equivalent action-handler chokepoint — put the check there.
- **Deliberately silent paths:** a process that exited on its own (user typed `exit`, or it crashed) needs no prompt — nothing left to kill; and SSH connect-dialog **Cancel/Dismiss** on a still-connecting/blank pane is an abort-the-connection gesture, not a close-a-running-terminal gesture. These call the no-prompt teardown directly.

### Full list of close paths that must be covered
Checklist for the Linux dev — each must funnel through the shared confirm:
1. Tab strip chip **×** button.
2. Tab context-menu **"Close Tab"**.
3. **"Close Other Tabs"** (menu + core action).
4. **"Close Tabs to the Right"** (menu + core action).
5. All-tabs / overview grid per-tab **×**.
6. `close_tab:this` **core action / keybind** (default and any rebind).
7. Pane header **×** button.
8. Close-focused-pane **keybind** (macOS ⌘W; whatever it's bound to on Linux).
9. Close-active-tab **keybind** (macOS ⌘⌥W; ditto).
10. Core **`close_surface`** action **when the process is still alive** (explicit close; auto-close on process-exit stays silent).
11. **Quit / window-close** — app-wide guard if *any* surface anywhere is busy.

Intentionally NOT prompted (call the no-prompt teardown): process-exited auto-close; SSH connect-dialog cancel/dismiss on a blank/connecting pane.

### macOS specifics → Linux/GTK equivalents
- **`SarvAlert` (@MainActor modal)** → a GTK modal dialog (`GtkAlertDialog`, or a `GtkMessageDialog`/`adw` dialog) with destructive-styled **Close** and a **Cancel**; run it async and only perform the teardown in the confirm callback.
- **Notification-based action dispatch** → the GTK apprt's action/keybind handler layer. Put the busy-check at that single chokepoint (where close actions are dispatched), **not** duplicated per keybind — this is what gives you automatic coverage of rebound keys.
- **`ghostty_surface_needs_confirm_quit`** is a libghostty C call available to the GTK app too — call it per surface; gather the surfaces a close would free and prompt if any returns true.
- **Ignore the Swift actor-isolation detail.** macOS needed `MainActor.assumeIsolated` because `SarvAlert` is `@MainActor` and keybind/notification handlers arrive on the main queue; Zig/GTK has no actor model — just ensure the dialog is shown on the GTK main thread as usual.

### How to verify on Linux
- Run a long-lived process (`node -e "setInterval(()=>{},1000)"` or `sleep 1000`) in a pane, then trigger **each** path in the checklist above — every one must prompt; **Cancel** must leave the process alive, **Close** must kill it.
- Idle shell (no child process): every path must close instantly with **no** dialog.
- **Rebind test:** map a *custom* key (and/or menu item) to the close action, then use it with a running process — it must still prompt (proves the check is at the action layer, not the key).
- SSH: with a live SSH session, closing its tab/pane must prompt; cancelling the *connect dialog* on a still-connecting pane must NOT prompt.
- Bulk: with a busy tab among others, "Close Other Tabs" / "Close Tabs to the Right" must prompt; with all-idle it must not.
- Quit with any busy surface anywhere must prompt app-wide.

---

## 5. Make the close-confirmation impossible to bypass (compile-time hardening)

### Why
The close-confirmation logic (section 4) only works if every caller remembers to go through a confirming entry point. Before this change the real closers were still callable from anywhere, so the guarantee was **convention-only**: a future keybind, menu item, or refactor could call the bare `closeTerminal`/`closePane` directly and silently ship a close with **no** running-process warning — killing a user's process (agent run, SSH session, long command) with no prompt. Code review is the only thing that catches a convention slip, and it eventually misses one. This change converts the invariant from "everyone remembers" to "the compiler enforces it": a close that skips the confirmation should not be *expressible*, so a wrong call site fails the **build** instead of shipping a missing warning.

### The pattern (platform-agnostic)
Three roles, enforced by visibility:

1. **Private performers** — the functions that actually tear down a tab/pane (`performCloseTerminal`, `performClosePane`). These do the real work (snapshot + release surfaces, collapse split, select neighbor) and are **not reachable from outside the tab-model module**. Renamed with a `perform*` prefix so their "raw, unguarded" nature is obvious at the definition.
2. **Public confirming wrappers** — the only close entry points the rest of the app can call: `requestCloseTerminal`, `requestClosePane`, `requestCloseOtherTabs`, `requestCloseTabsToRight`. Each checks "is anything running?" and prompts before delegating to a private performer.
3. **One explicitly-named opt-out** — `closePaneSkippingConfirm`, the *single* public way to close without a prompt. It exists only for the SSH connect-dialog **cancel/dismiss** gestures (aborting a still-connecting/blank pane, where prompting would be wrong). Its name states the risk at every call site, so an audit for "who skips the confirm?" is one grep.

Principle: **make the wrong thing impossible to express, and make the one legitimate exception loud.** The safe path (`request…`) is the easy/default path; the unsafe path is private; the exception is public but self-incriminating by name.

### macOS specifics → Linux/GTK equivalents
- Swift `private` on `performCloseTerminal`/`performClosePane` scopes them to the file/type — SwiftUI views, keybind handlers, and notification observers in other files literally cannot name them. In the **Zig/GTK apprt**, get the same effect with visibility: keep the raw close routines **unexported** (no `pub`) so they're private to the tab-model module/struct that owns them, and expose **only** the confirming wrappers (`pub fn requestCloseTab…`) plus the one loudly-named opt-out (`pub fn closePaneSkippingConfirm…`) across the module boundary. If the model lives in one file, file-private (plain non-`pub` fns) is enough; if it spans files, put the performers in the model struct and gate access so callers outside the struct only see the `request*`/opt-out surface.
- Swift's `perform*` rename → mirror the naming in Zig (`performCloseTab`, `performClosePane`) so the raw closers read as internal-only at a glance.
- The internal delegation must also be updated: the confirming wrappers and any internal collapse-to-tab path call the **performers** directly (they're inside the module); only cross-module callers are forced through `request*`.

### How to verify on Linux
- Grep the GTK app for the raw closer names — every hit must be inside the tab-model module (the wrappers and internal teardown), never in view/widget code, keybind dispatch, or notification/action handlers.
- Add a throwaway call to the raw closer from a view/keybind file and confirm it **fails to compile** (unexported/out-of-scope). Delete it.
- Confirm every user-facing close path (widget ×, keybind, menu, action-callback) resolves to a `request*` wrapper or the named opt-out — i.e. there is no compiling way to reach a close without either prompting or explicitly saying "skip confirm."
- Confirm `closePaneSkippingConfirm` (or its Zig equivalent) is called **only** from the SSH connect-dialog cancel/dismiss sites.

---

# Part II — Core Vaults subsystems (the Sarv divergence from upstream Ghostty)

_These are documented from source + git history across the whole macOS app, not tied to a single commit. They are the layer the GTK app must rebuild; base Ghostty terminal behavior already exists on GTK._

## 6. Vaults window & navigation shell

### What it is

Stock Ghostty is multi-window: every terminal is its own `NSWindow` (macOS) / `GtkWindow` (GTK), managed by `BaseTerminalController` / `ApplicationWindow`, and macOS adds native window-tabs on top. SarvTerminal throws that model out. The whole app lives in **exactly one window** whose content area swaps between two things:

- the **Vaults dashboard** (host manager, saved sessions, teams, keychain, port-forwarding, snippets, known-hosts, logs, plus an SFTP surface), and
- **embedded terminal tabs** (each a split tree of terminal surfaces) rendered inside that same window.

Terminals are never separate OS windows. A custom Termius-style tab strip sits in the content region just below the titlebar; native macOS window-tabbing is hard-disabled. Around the content sit three chrome pieces: a left **section sidebar** (on the dashboard), a right **command sidebar** (snippets/history/themes/search, shown only on terminal tabs), and a slide-in **editor sidebar** overlay (host/group editor over a dimmed scrim). The window opens maximized, refuses to go transparent, confirms before quitting if any session has a live process, and quits on the red close button instead of hiding.

Sarv added this because the product is a connection manager first (like Termius), not a window-spawning terminal. A single stable shell lets host lists, tab strip, sidebars, shared background image, and session state coexist and persist; the multi-window model can't express that.

Why a custom window and not `BaseTerminalController`: the embedded terminals are children of this one controller, so Ghostty's standard per-window machinery never sees them. Most consequentially, the app's normal quit-confirmation only inspects `BaseTerminalController` windows, so the Vaults window has to run its own quit-confirm (see below). `BaseTerminalController` is still used for stock behaviors elsewhere (e.g. `New Window` fallbacks), but the Vaults shell deliberately bypasses it.

### Key logic & data model

**Files (macOS):**
- `HostManagerController.swift` — the single `NSWindowController`/`NSWindowDelegate`; window creation, lifecycle, quit-confirm, shared-background compositing.
- `VaultsRootView.swift` — root SwiftUI layout: top bar + content swap + sidebars + overlays.
- `VaultsView.swift` — dashboard with the left section sidebar (`VaultsView.Section`).
- `HostManagerView.swift` — inner switch between `vaults` and `sftp` surfaces.
- `HostManagerSelection.swift` — cross-teardown navigation state (see schema below).
- `VaultsToolbar.swift` — reusable per-section top bar + empty-state + scaffold.
- `VaultsEditorSidebar.swift` — generic scrim + 400pt trailing editor panel.
- `VaultsTabsModel.swift` — the model that owns tabs, selection, and session persistence.
- `SavedSession.swift` / `TabSession.swift` — persisted session schema + stores.

**Content selection.** `VaultsTabsModel.shared.selection` is an enum `Selection { case dashboard; case terminal(UUID) }`. `VaultsRootView` renders `HostManagerView()` for `.dashboard` and a `VaultsTerminalPane(tab:)` for `.terminal(id)`, `.id(tab.id)` so switching tabs rebuilds and re-focuses. Terminal tabs are **live objects** kept in `terminals: [TerminalTab]` — switching away does not tear the session down; only the dashboard view is rebuilt. `selection`'s `didSet` records `lastTerminalID` (snippet/target routing) and clears the tab's attention dot.

**Layout tree (`VaultsRootView`):**
- `topBar` (fixed 42pt): `VaultsTabStrip` (owns the `+`/new-tab action) · notification bell (`VaultsBellView`) · command-sidebar toggle (disabled, not hidden, off terminal tabs) · `AccountMenuButton`.
- content `HStack`: main content (`maxWidth/.infinity`) + optional `VaultsCommandSidebar` (only when `sidebarVisible && inTerminal`, slide-in from trailing edge).
- Overlays, top to bottom: `VaultsAllTabsView` (when `tabs.showAllTabs`), `VaultsHostEditorSidebar` (when `tabs.editingHost != nil`), a serial-connect sheet (`tabs.presentingSerialConnect`), and a single window-level `TooltipOverlay` in the named coordinate space `TooltipPresenter.space`.

**Dashboard sidebar.** `VaultsView.Section` = `hosts, savedSessions, teams, keychain, portForwarding, snippets, knownHosts, logs` (each with `label`/`icon`), a 180pt list, selection stored in shared state (below) so it survives the dashboard being torn down when a terminal shows. `HostManagerView` first switches on `HostManagerSelection.section` (`vaults` | `sftp`).

**Navigation state — `HostManagerSelection` (shared `ObservableObject`, must persist across dashboard teardown):**
- `section: Section` (`.vaults` | `.sftp`)
- `vaultsSection: VaultsView.Section` (default `.hosts`)
- `hostsFocusedGroupID: UUID?` (which host group is drilled into; nil = root)
- `pendingEditHostID: UUID?` (one-shot request to open a host editor; consumed by `HostsSectionView`)

**Shared background.** The window content is an AppKit container with an `NSImageView` (shared background image) behind the SwiftUI hosting view; in "shared" mode the SwiftUI content is `Color.clear` and translucent panes blend against that image. Driven by `BackgroundDisplayStore` (`useShared`, `sharedImage`, `imageVisibility`).

**Window lifecycle (`HostManagerController`):**
- `OpaqueWindow` overrides `isOpaque` to always return true (Ghostty flips it false for translucent surfaces; here panes must blend against the window's own image, not the desktop).
- `NSWindow.allowsAutomaticWindowTabbing = false`, `window.tabbingMode = .disallowed`, `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isReleasedWhenClosed = false`, `minSize 900x560`, `backgroundColor ~#1F1F1F` (dark-gray so inactive traffic-light buttons stay visible behind the transparent titlebar). `hideNativeChrome()` defensively hides any stray native tab bar at several delays.
- `show()` maximizes to the screen's `visibleFrame` (deferred one runloop tick because `window.screen` isn't set immediately); later shows `clampToScreen()`.
- **Red button quits** (not hides): `windowShouldClose` always returns `false` and drives quit itself. If `ghostty.needsConfirmQuit` is false → `NSApp.terminate(nil)` immediately; otherwise it shows a `SarvAlert` confirm ("A terminal session still has a running process…") and terminates only on the destructive button. `needsConfirmQuit` is the libghostty **core** signal (`src/App.zig` `needsConfirmQuit`), already wired on GTK.
- `AppDelegate`: on launch `HostManagerController.shared.show()` when `initialWindow`; `applicationWillTerminate` calls `VaultsTabsModel.shared.persistSession()`; `applicationShouldHandleReopen` opens a stock `TerminalController.newWindow`, and the dock menu's New Window / New Tab items open the command palette (`HostSearchController`). Note the evolution: the close button first *hid* the window (`c9fb35131`), then was changed to *quit* (`1ad9509c2`), then gained the running-process confirm (`c59bb4ecc`).

**PERSISTED SESSION SCHEMA (a port must match this exactly).**

Two files under the build-specific config dir (`AppPaths.configDir`, i.e. `~/.config/sarvterminal/`):

- `session.json` — last open tabs, restored on next launch. Written **plaintext** (`TabSessionStore`, plain `Data.write`), an **array of `SavedSession`**. Autosaved on every tab mutation (`terminals` `didSet` → `persistSession()`), coalesced one write per runloop tick (`schedulePersist`), plus a final write on terminate. Per-tab and per-surface observers re-persist on color/rename/split/pane-title changes.
- `saved-sessions.json` — the user's saved-session library (`SavedSessionsStore`). **Encrypted at rest** (`EncryptedStore`), dates ISO-8601, sorted newest-first by `createdAt`.

`SavedSession` (`Codable, Identifiable`):
- `id: UUID`
- `name: String`
- `createdAt: Date`, `updatedAt: Date`
- `colorID: String?` — tab color option id (`"blue"`, `"purple"`, `"pink"`, `"red"`, `"orange"`, `"yellow"`, `"green"`, `"teal"`, `"gray"`)
- `linkTabName: Bool?` — tab name follows session name; nil ⇒ true (back-compat)
- `linkedSessionID: UUID?` — restart-snapshot only; the library session a restored tab is linked to
- `layout: PaneNode` — root of the split tree

`PaneNode` (indirect enum, `Codable`):
- `.leaf(Pane)` or `.split(Split)`
- `Split { direction: Direction; ratio: Double; left: PaneNode; right: PaneNode }`
- `Direction: String` = `"horizontal"` (left|right) | `"vertical"` (top/bottom)

`Pane` (`Codable`):
- `kind: String` = `"local"` | `"ssh"`
- `workingDirectory: String?` (local pane respawn cwd)
- `hostID: UUID?` (SSH pane → `SavedHost` id; keeps password out of the file)
- `command: String?` (plain `ssh …` fallback when no saved host)
- `title: String?` (stable label only — user rename or SSH host label, never a live command title)
- `titleIsUserSet: Bool?` (restore re-pins a local pane's title only when true; nil ⇒ not user-set)

No secrets are ever stored in either file — SSH panes reference a `SavedHost` by id.

**Legacy migration:** `TabSessionEntry` (flat single-pane: `hostID`, `launchCommand`, `title`, `customName`, `workingDirectory`) from old builds is decoded and mapped to a single-leaf `SavedSession` via `asSavedSession()`. A port should preserve this fallback decode.

**Restore-on-launch:** `offerSessionRestoreIfNeeded()` reads `pendingRestore` (loaded at init before any mutation), respects the `SarvRestoreSession` `UserDefaults` bool (default true), and shows a "Reopen your last session?" modal; declining overwrites the saved session with the current (empty) state.

### macOS → Linux/GTK equivalents

| macOS piece | Purpose | GTK4 / Linux equivalent |
|---|---|---|
| `NSWindowController` + single `OpaqueWindow` | The one Vaults window | One `GtkApplicationWindow` (extend the existing `src/apprt/gtk/class/window.zig`); never spawn a second for terminals |
| `NSWindow.allowsAutomaticWindowTabbing=false`, `tabbingMode=.disallowed` | Kill native window-tabs | No equivalent needed — GTK has no native window-tab feature; simply keep one window + the custom tab strip |
| `titleVisibility=.hidden`, `titlebarAppearsTransparent`, dark titlebar color | Custom strip fills titlebar; keep controls visible | `GtkHeaderBar` with a custom title widget (or CSD off + custom top bar); window-control visibility is themed by the compositor, so the dark-gray traffic-light hack is N/A |
| `NSHostingView` + SwiftUI view tree (`VaultsRootView`, sidebars, toolbar) | All chrome/layout | Native GTK4 widgets: `GtkStack` for dashboard↔terminal swap, `GtkBox`/`GtkPaned` for the section + command sidebars, `GtkRevealer` for slide-in sidebars, `GtkOverlay` for the editor scrim/all-tabs/tooltip layers. Blueprint or hand-built in Zig. No SwiftUI — rebuild from scratch |
| `@Published`/Combine (`VaultsTabsModel`, `HostManagerSelection`) | Reactive state | GObject properties + signals, or a plain Zig model struct emitting change signals |
| `NSImageView` behind clear SwiftUI content (shared background) | Translucent panes blend on a window image | `GtkPicture`/CSS `background-image` on a base widget under a `GtkOverlay`, or draw in a `GtkDrawingArea`; wire to the background store |
| `windowShouldClose` delegate returning false + `SarvAlert` | Red-button quit + running-process confirm | `GtkWindow::close-request` signal (return true to stop default); confirm with `AdwMessageDialog`/`GtkAlertDialog`. **The core signal already exists on GTK** — `App.needsConfirmQuit` is consumed in `src/apprt/gtk/class/application.zig` and `split_tree.zig`; reuse it |
| `NSApp.terminate` / `applicationShouldTerminate` / `applicationWillTerminate` | Quit + final persist | `GApplication`/`AdwApplication` shutdown handler; persist session in the shutdown/`close-request` path |
| `applicationShouldHandleReopen`, dock menu | Re-show the single window | `GApplication::activate` (re-present the window if it exists instead of creating one) |
| `SarvAlert.runModal` / `.present` | Restore prompt, quit confirm | `AdwMessageDialog` (async) — do not block; mirror the deferred-present pattern |
| `UserDefaults` (`SarvRestoreSession`) | Reopen-on-launch pref | `GSettings` (or the app's existing config store) |
| `AppPaths.configDir` → `session.json` (plaintext) + `saved-sessions.json` (encrypted) | Session persistence | Same filenames under `$XDG_CONFIG_HOME/sarvterminal/`; keep JSON byte-compatible (Zig `std.json`, ISO-8601 dates, enum raw strings). Encryption at rest is a separate subsystem (see the encryption section) — the plaintext `session.json` needs no crypto |
| `NWPathMonitor` (reachability) | Instant reconnect when network returns | GLib `GNetworkMonitor` `network-changed` |
| `NSWorkspace.didWakeNotification` (wake from sleep) | Reconnect after resume | `org.freedesktop.login1` `PrepareForSleep(false)` D-Bus signal via GDBus |
| `NSScreen.visibleFrame` maximize + `clampToScreen` | Open maximized, stay on-screen | `gtk_window_maximize()`; the compositor handles clamping — the manual clamp is largely N/A |
| Tab color palette (9 preset `colorID`s) | Persisted tab colors | Keep the exact string ids so `session.json` round-trips |

**No clean Linux equivalent / caveats:**
- The `OpaqueWindow` transparency-forcing hack is macOS-specific compositing; on GTK, terminal transparency and background compositing work differently — decide the background strategy fresh, don't port the AppKit trick.
- Secure-Enclave/Keychain-backed encryption for `saved-sessions.json` has no direct Linux analog; that's covered by the encryption subsystem (fallback is typically libsecret / a software-wrapped key). The window shell only needs the *plaintext* `session.json`, so restore can ship before the encrypted store is ported.

### How to verify on Linux

1. **Single window:** launch the app; confirm exactly one window opens, maximized, showing the Vaults dashboard (not a shell). Opening a terminal must reuse the same window (no new OS window); `New Tab`/`+` adds an embedded tab, never a window.
2. **Content swap:** switch between a terminal tab and the dashboard and back — the terminal session keeps running (process not restarted, scrollback intact).
3. **Section navigation persists:** drill into a host group / pick a non-default section, open a terminal, return — the section and drilled group are preserved (`HostManagerSelection` state).
4. **Sidebars:** command sidebar toggle is enabled only on terminal tabs and disabled on the dashboard; the editor sidebar opens as a 400pt panel over a dimmed, click-to-dismiss scrim without losing the screen underneath.
5. **Red button quits (with confirm):** with an idle local shell, closing the window quits the app immediately. With a running process (e.g. `sleep 300` or an SSH session), it shows a "running process" confirm dialog; Cancel keeps the app alive, Quit terminates. Verify this reuses the core `needsConfirmQuit`.
6. **Session persistence round-trip:** open two tabs, one with a split and an SSH pane; quit; confirm `~/.config/sarvterminal/session.json` contains an array of `SavedSession` with the `layout` `PaneNode` tree, correct `kind`/`workingDirectory`/`hostID`, and `colorID`s. Relaunch → "Reopen your last session?" prompt appears; Reopen restores tabs, splits, cwds, colors, and reconnects SSH panes at their saved layout.
7. **Restore preference:** set the reopen-on-launch pref off, relaunch → no prompt, empty session; the file is still rewritten (re-enabling restores on a later launch).
8. **Legacy migration:** drop an old flat `[TabSessionEntry]` `session.json` in place; confirm it decodes to single-leaf tabs.
9. **Reactivate:** with the window closed/hidden edge cases, activating the app again re-presents the single window rather than creating a second one.

## 7. Saved hosts, groups & tags

### What it is

Stock Ghostty has no concept of a saved connection — you type `ssh …` yourself every time. SarvTerminal adds a full Termius-style **host inventory**: a Vaults dashboard where users save SSH connections as first-class "hosts", organize them into arbitrarily-nested **groups** (folders), tag them, give each host an OS/appearance identity, and connect with one click. This subsystem is purely the *data + editor* layer (the connection/staging machinery is a separate subsystem). A Linux port must rebuild:

- **SavedHost** — the connection record: identity, auth, ssh options, port-forwards, startup command, organization (group + tags), appearance (theme, OS platform icon), timestamps.
- **HostGroup** — a nestable folder (self-referential `parentID` tree) with a name, SF-Symbol icon, and color.
- Two JSON stores (`hosts.json`, `groups.json`) plus a small `pinned-history.json`, all under the app config dir, hosts encrypted at rest.
- The dashboard UI: grid/list views, breadcrumb drill-down, quick-connect/filter bar, tag filter, sort modes, and the slide-in host/group editors with **autosave** (no explicit Save button for hosts).
- OS auto-detection: a silent post-connect SSH probe of `/etc/os-release` that stamps a distro icon on the host.

Source: everything under `macos/Sources/Features/HostManager/`.

### Key logic & data model

**Storage locations** (`macos/Sources/Helpers/AppPaths.swift`, `AppIdentity.swift`)
- Config dir = `~/.config/sarvterminal` (release) or `~/.config/sarvterminal-dev` (debug). Always rooted at `~/.config` — `AppPaths.configDir` does NOT honor `XDG_CONFIG_HOME` (only the terminal config file and themes do). This is the app's *own* data dir, separate from the terminal config. A Linux port should keep the same path so synced/copied data is compatible.
- `hosts.json` — encrypted (see below), array of `SavedHost`.
- `groups.json` — **plaintext** JSON (pretty-printed, sorted keys), array of `HostGroup`.
- `pinned-history.json` — encrypted, array of strings.
- Dates are ISO-8601 encoded/decoded on both sides.

**SavedHost schema** (`SavedHost.swift`) — every field is decoded with `decodeIfPresent … ?? default`, so old/partial files never fail to load. A port MUST match these JSON keys and defaults exactly:

| field | type | default | notes |
|---|---|---|---|
| `id` | UUID string | new UUID | identity for upsert/merge |
| `label` | string | `""` | display name |
| `hostname` | string | `""` | IP or DNS |
| `port` | int | `22` | |
| `username` | string | `""` | empty = ssh default user |
| `note` | string | `""` | |
| `authMethod` | enum | `password` | `password` / `publicKey` / `agent` / `ask` |
| `identityFile` | string | `""` | key path; `~` expanded at command build |
| `password` | string | `""` | **stored in plaintext inside the JSON** (file is then encrypted at rest) |
| `forwardAgent` | bool | `false` | `-A` |
| `strictHostKeyChecking` | enum | `ask` | `yes` / `no` / `ask` / `accept-new` (rawValue `accept-new`) |
| `connectTimeoutSeconds` | int | `0` | 0 = OS default |
| `serverAliveIntervalSeconds` | int | `0` | 0 = disabled |
| `useCompression` | bool | `false` | `-C` |
| `requestTTY` | bool | `false` | `-t` |
| `proxyJump` | string | `""` | `-J` |
| `termOverride` | string | `""` | `""`→`xterm-256color`; `xterm-ghostty` opts into `+ssh` terminfo install |
| `localForwards` | [string] | `[]` | raw `-L` operands |
| `remoteForwards` | [string] | `[]` | raw `-R` operands |
| `dynamicForwardPort` | int | `0` | `-D`; 0 = off |
| `initialCommand` | string | `""` | typed into the shell *after* connect, NOT passed as ssh remote cmd |
| `groupID` | UUID? | `nil` | first-class group ref; `nil` = root |
| `group` | string | `""` | **legacy** free-form group name, migration only |
| `tags` | [string] | `[]` | |
| `themeName` | string | `""` | Ghostty theme applied to the host's tab; `""` = inherit |
| `platform` | string | `"auto"` | manual `HostPlatform` rawValue |
| `detectedPlatform` | string | `""` | last auto-detected `HostPlatform` rawValue |
| `createdAt` / `updatedAt` | ISO-8601 date | now | |

Notable derived logic on `SavedHost` a port should replicate:
- `sshCommand(staged:)` — builds the full `ssh …` line, turning every knob into explicit `-o Key=Value` so the host need not exist in `~/.ssh/config`. `staged` mode adds `NumberOfPasswordPrompts=1`, `accept-new`, and default keepalives. `SetEnv TERM=…`/`COLORTERM=truecolor` is added unless `termOverride` is `xterm-ghostty`. `shellQuote()` (single-quote escaping) and `~` expansion are used.
- `canConnect` (hostname non-empty), `passwordRequirementMet` (password auth needs a stored password), `canSave = canConnect && passwordRequirementMet`.
- `contentEquals` — equality ignoring timestamps, used to skip no-op autosaves.

**HostGroup schema** (`HostGroup.swift`): `id` (UUID), `name` (string), `parentID` (UUID?, `nil`=root), `iconSystemName` (string, default `"folder.fill"` — an SF Symbol name), `colorHex` (string, `""`=accent, else `#RRGGBB`), `createdAt`, `updatedAt`. Same default-tolerant decoder.

**Stores** (`SavedHostsStore.swift`, `HostGroupsStore.swift`) — singletons, `@Published` arrays, async serial-queue writes (atomic file write):
- CRUD: `upsert` (bumps `updatedAt`, sorts, persists), `delete`, `duplicate` (fresh UUID + " (copy)" label), `setGroup`, `unsetGroup(id)` (clears dangling refs after a group delete).
- Sync hooks: `replaceAll` (mirror pull), `ingest` (merge by `id`, newer `updatedAt` wins, never deletes local-only). `loadFailed` flag: if the file exists but won't decode, the empty array is **not** authoritative and must not be pushed to sync.
- Group-tree algorithms in `HostGroupsStore`: `children(of:)`, `descendants(of:)` (DFS with a visited-set), `path(for:)` (breadcrumb string, cycle-guarded), `flatTree()` (pre-order with depth for menus), and `setParent` with a **cycle check** (can't move a group into its own descendant). `delete` re-parents orphaned sub-groups up to the deleted group's parent; hosts are separately un-grouped by the caller (`unsetGroup`).
- Host scoping: `hosts(in:)` (direct children), `recursiveHosts(in:groupsStore:)` / `recursiveCount` (a group level shows every host in it *and all descendants*, same as the root "all hosts" view).
- Hosts are sorted case-insensitively by display label; groups by display name.

**Encryption at rest** (`macos/Sources/Security/LocalDataCrypto.swift`) — this is the trickiest port piece. `hosts.json`/`pinned-history.json` are written as an envelope `{"sarvEnc":1,"blob":"<base64 AES-256-GCM>"}`. The AES data key is random, wrapped (ECIES: ephemeral P-256 ECDH → HKDF-SHA256 → AES-GCM) to a **Secure Enclave** P-256 key; on Macs without an Enclave it falls back to a raw 256-bit key in the device-only Keychain. `EncryptedStore.read` also transparently migrates a legacy *plaintext* `hosts.json`: it decodes it, backs the original up to `hosts.pre-encryption.bak`, and rewrites encrypted. The salt is `"sarvterminal-local-at-rest-salt-v1"`, info `"sarvterminal-local-at-rest-v1"`.

**Editor UX logic** (`HostsSectionView.swift`):
- Host editor is **autosave-first**: no Save button. Every field commit / toggle change fires `onAutosave`; an unnamed new draft gets `Unnamed`, `Unnamed (2)`, … A draft with no real content is never persisted (`hostDraftHasContent`). "Cancel/Close" is the final commit point; deleting-from-editor clears the draft *before* close so the flush can't resurrect it.
- View mode (grid/list) is persisted in `UserDefaults`: a root default (`SarvHostsViewModeDefault`) plus per-group overrides (`SarvHostsViewModeByGroup`, a `[groupID-string: "grid"/"list"]` dict).
- Connect-on-click mode (`SarvHostsConnectClick` = `single`/`double`) in `UserDefaults`, default double.
- Quick-connect bar doubles as a live filter and an ssh runner (text with `@` or `ssh ` prefix). Tag filter + 4 sort modes (A–Z, Z–A, newest, oldest).
- `allKnownTags` is derived by scanning all hosts (tags are not a stored entity — just the union of per-host `tags`). `TagsField.swift` provides chip input with autocomplete + "Create Tag X".

**OS platform** (`HostPlatform.swift`): enum of `auto` + ~16 distros/OSes, each mapping to a bundled logo asset (`os_*.svg`, template-rendered white) and a brand hex color used for the icon tile. `HostPlatformDetector.probeIfNeeded` runs a one-shot background `ssh … cat /etc/os-release || uname -s` after connect (BatchMode for key/agent, askpass-fed password otherwise, never interactive), parses the `ID=` line via `HostPlatform.from(osReleaseID:)`, and stores `detectedPlatform`. A manual `platform` choice always beats detection (`effective(for:)`).

### macOS → Linux/GTK equivalents

| macOS / Apple piece | Used for | Linux / GTK4 / Zig equivalent |
|---|---|---|
| SwiftUI (`HostsSectionView`, editors, `TagsField`, `ParentGroupPicker`, `GroupAppearancePickers`) | entire dashboard + editors | GTK4 widgets: `GtkFlowBox`/`GtkGridView` for the card grid, `GtkListView` for list mode, `GtkPopover` for pickers, `GtkEntry` + a chip flowbox for tags. This whole UI is a from-scratch rebuild. |
| `Codable` + `JSONEncoder/Decoder` (ISO-8601) | JSON persistence | Zig `std.json` (parse into structs with optional fields + defaults to mirror the tolerant decoder). Preserve exact key names and defaults above. Emit ISO-8601 dates. |
| `UserDefaults` / `@AppStorage` | view mode, sort, connect-click prefs | GSettings, or a small JSON/keyfile under the config dir. Keep the same semantic keys. |
| Secure Enclave P-256 + Keychain (`LocalDataCrypto`) | wrapping the AES data key for at-rest encryption of `hosts.json` | **No clean equivalent.** No Secure Enclave on Linux. Options: (a) libsecret / GNOME Keyring (`org.freedesktop.Secrets`) to store the raw AES-256 key device-only; (b) TPM-sealed key where available. Encryption itself (AES-256-GCM, ECIES wrap, HKDF-SHA256) is portable via libsodium/OpenSSL. The on-disk envelope format (`{"sarvEnc":1,"blob":…}`) and the plaintext→encrypted migration (with `.pre-encryption.bak`) must be reproduced so files stay cross-readable *only if* the key were shared — in practice keys are per-device, so cross-machine transfer relies on the sync subsystem, not the local key. Keep the same salt/info constants. |
| SF Symbols (`iconSystemName`, e.g. `folder.fill`) | group icons | No SF Symbols on Linux. Either bundle an equivalent named-icon set and map the stored SF-Symbol strings to GTK icon names, or bundle the same glyphs. Note: `iconSystemName` values are **persisted**, so a Linux build must accept and round-trip the SF-Symbol strings (map them at render time; don't rewrite the stored value). |
| Bundled `os_*.svg` logos, `NSImage` template tinting | OS platform icons | Ship the same SVGs; render via `GdkTexture`/`GtkImage` (librsvg). Brand-hex tile logic ports directly. |
| `Process` + `SSH_ASKPASS`/askpass helper (`HostPlatformDetector`) | silent post-connect OS probe | `std.process.Child` / GLib subprocess spawning `ssh`; same `BatchMode`/askpass approach. |
| `DispatchQueue` serial IO queue | async atomic file writes | a worker thread or GLib async; write to temp + rename for atomicity. |
| `NSColor`/`Color(hex:)` | group palette colors | parse the same `#RRGGBB` hex to `GdkRGBA`; the `GroupColorPalette` and `HostPlatform.brandHex` tables port verbatim. |

### How to verify on Linux

1. **Schema round-trip**: point the Linux build at an existing macOS `~/.config/sarvterminal/groups.json` and a *decrypted* `hosts.json`; confirm all hosts and the full nested group tree load with correct labels, ports, tags, group membership, platform icons, and timestamps. Then re-save and diff — key names, defaults, and ISO-8601 dates must be unchanged.
2. **Tolerant decode**: hand-write a `hosts.json` with several fields omitted; confirm it loads with the documented defaults (port 22, authMethod password, strictHostKeyChecking ask, etc.) and no crash.
3. **Group tree ops**: create nested groups; verify `setParent` refuses to move a group under its own descendant (no cycle); delete a mid-tree group and confirm sub-groups re-parent to the deleted group's parent and its hosts become ungrouped (root), not deleted.
4. **Recursive scope**: drill into a top-level group and confirm the host list shows hosts from that group *and all descendants*, and the count on the card matches.
5. **Autosave**: open "New host", type only a hostname, close without a Save button → a host named `Unnamed` persists; a truly empty draft persists nothing.
6. **ssh command**: for a host with a non-default port, identity file, proxy jump, and a local forward, dump `sshCommand()` and confirm the exact `-p/-i -o IdentitiesOnly=yes/-J/-L/-o SetEnv=TERM=…` operands, with proper shell-quoting of paths containing spaces.
7. **Encryption at rest**: after saving a host, confirm `hosts.json` on disk is the `{"sarvEnc":1,"blob":…}` envelope (not readable plaintext), that a legacy plaintext file migrates and leaves a `hosts.pre-encryption.bak`, and that a missing/rotated key yields a *failed* (not empty) load so sync won't wipe the backup.
8. **Tag + OS**: add tags to a host and confirm they appear in the tag filter and autocomplete; set `platform` manually and confirm the brand-colored distro tile renders; leave it `auto`, connect, and confirm the background probe stamps `detectedPlatform`.

## 8. Host import & SSH config discovery

### What it is

Stock Ghostty has no notion of a saved-host inventory, so it has nothing to import into. SarvTerminal added a Vaults layer (saved hosts, groups, tags) and, on top of it, a **"Add hosts to your vault"** import wizard so users migrating from other tools don't have to re-enter every server by hand. The wizard is a Termius-style multi-step sheet reached from the Hosts section (`HostsSectionView.swift:182`, `.sheet { ImportHostsView() }`).

It imports from five sources:

- **`~/.ssh/config`** — one-click discovery/parse of the user's existing SSH config (no file picker; reads the well-known path directly).
- **CSV** — a fixed-schema CSV (with a downloadable template and "Save template…" action).
- **PuTTY** — a Windows registry `.reg` export of `HKCU\...\PuTTY\Sessions`.
- **MobaXterm** — a `.mxtsessions` file.
- **SecureCRT** — either a single session `.ini` or a whole `Sessions` folder (recursively walked), with the on-disk folder structure mapped to Sarv group paths.

The flow is: pick a format → (CSV only) see the required header + choose file → **preview** every parsed host with per-row checkboxes and a filter box (all selected by default) → **import**, which shows a summary ("Imported N hosts · M already saved"). Parsing has no side effects; only the final commit writes to the stores. Imports dedupe against already-saved hosts and auto-create the group tree.

### Key logic & data model

**Files:** `HostImport.swift` (all parsers + commit logic, no UI), `SSHConfigDiscovery.swift` (the ssh_config parser + `DiscoveredHost` model), `ImportHostsView.swift` (SwiftUI wizard). The port target is `SavedHost` (`SavedHost.swift`), `HostGroup`, and the stores.

**`ParsedHost`** — the intermediate, not-yet-saved shape shown in preview (`HostImport.swift:6`). Fields: `id: UUID`, `label: String`, `hostname: String`, `port: Int = 22`, `username: String = ""`, `auth: SavedHost.AuthMethod = .agent`, `identityFile: String = ""`, `password: String = ""`, `groupPath: String = ""` (a `/`-separated path resolved into the group tree only at commit), `tags: [String] = []`, `note: String = ""`.

**Persisted target schema — `SavedHost`** (`SavedHost.swift`, `Codable`, default-tolerant so missing JSON keys fall back to defaults — a port must preserve this leniency). Relevant fields the importer writes via `toSavedHost()`: `label`, `hostname`, `username`, `port`, `authMethod`, `identityFile` (absolute path; `""` disables), `password`, `tags: [String]`, and `note`; `groupID: UUID?` is not set in `toSavedHost()` but assigned later in `commit()` via `resolveGroup`. `AuthMethod` is a string enum with **exact raw values** `"password"`, `"publicKey"`, `"agent"`, `"ask"` (`SavedHost.swift:73`) — match these strings exactly in any port. Saved hosts are stored **encrypted at rest** (AES-256-GCM, Secure-Enclave-protected key) by `SavedHostsStore.persist()`.

**`DiscoveredHost`** (`SSHConfigDiscovery.swift:4`): `id`, `label` (the `Host` token), `hostname: String?` (resolved `HostName`, nil if same as label), `user: String?`, `port: Int?`, `source` (`.sshConfig` | `.userHosts`). Also carries a `sshCommand` used by the launcher (for `.sshConfig` it just runs `ssh <label>` so ssh itself applies the config).

**Algorithms to reproduce exactly:**

- **ssh_config parse** (`SSHConfigDiscovery.parse`): line-based; skip blank/`#`; split each line into `key value` on whitespace **or** `=` (handles both `Keyword Value` and `Keyword=Value`); recognize only `host`/`hostname`/`user`/`port` (case-insensitive key). On a new `Host`, flush the previous block and take only the **first token** of a multi-pattern Host line. **Reject** labels containing `*` or `?` (wildcards/patterns, not connectable). Results sorted case-insensitively. `loadAll()` reads `NSHomeDirectory()/.ssh/config` and returns `[]` if absent/unreadable.
- **CSV** (`parseCSV`): header row required; canonical header is `label,hostname,port,username,auth,identity_file,password,group,tags,note`; only `hostname` is mandatory (else a user-facing error). Columns are resolved by name (order-independent, lowercased). `tags` split on `;`. `auth` normalized via `parseAuth` (lowercased, spaces stripped: `password`→.password, `publickey`/`key`→.publicKey, `ask`→.ask, else `.agent`). Includes a minimal RFC-4180 single-row parser `parseRow` (quoted fields, `""` escapes) — port this, don't hand-roll a naive `split(",")`.
- **PuTTY** (`parsePuTTY`): INI/reg sections; key is the percent-decoded name after `\Sessions\`; skip `Default Settings`; read `hostname`, `protocol` (accept only empty or `ssh`), `portnumber`, `username`; `dword:` hex values decoded to int.
- **MobaXterm** (`parseMobaXterm`): `SubRep=` sets the group path (`\`→`/`); session lines contain `#109#` (109 = SSH); value is `%`-split into host/port/user.
- **SecureCRT** (`parseSecureCRT`): walk a folder for `*.ini` (or a single file); parse quoted `"Key"=value` lines for `Hostname`, `Username`, `Protocol Name` (accept only ssh), and `Port` (hex when prefixed `D:`); the file's relative path becomes label + group path.
- **Commit** (`commit`, `@MainActor`): for each chosen `ParsedHost`, skip if `isDuplicate` (case-insensitive `hostname`+`username` match against existing hosts), else `resolveGroup(path:)` walks/creates the `/`-separated group tree (cached per path) and `SavedHostsStore.shared.upsert(host)`. Returns `HostImportResult { imported, skipped, note, summary }`.

### macOS → Linux/GTK equivalents

| macOS piece used | Purpose | Linux/GTK / Zig equivalent |
|---|---|---|
| SwiftUI `ImportHostsView` sheet, `formatCard`s, preview list, filter | the wizard UI | Rebuild as a GTK4 `GtkDialog`/modal (or `AdwWindow`) with a `GtkStack` for the 4 steps; format buttons as a `GtkFlowBox`; preview as a `GtkListView`/`GtkListBox` with check buttons and a `GtkSearchEntry` filter. |
| `NSOpenPanel` (files + directories, `allowsMultipleSelection=false`) | pick CSV/PuTTY/Moba/SecureCRT source | `GtkFileDialog` (GTK 4.10+) / `GtkFileChooserNative`; for SecureCRT allow selecting a folder (`select_folder`). |
| `NSSavePanel` + `allowedContentTypes` | "Save template…" CSV | `GtkFileDialog.save`. |
| `UniformTypeIdentifiers` (`.commaSeparatedText`, `.plainText`) | file-type filtering | `GtkFileFilter` with MIME `text/csv`, `text/plain`. |
| `FileManager.enumerator` (recursive `.ini` walk) | SecureCRT folder scan | Zig `std.fs.Dir.walk` or GLib `GFileEnumerator`. |
| `String(contentsOf:encoding:.utf8)` | read source files | Zig `std.fs`/`readFileAlloc` or GLib `g_file_get_contents`. |
| `NSHomeDirectory()` | locate `~/.ssh/config` | `std.posix.getenv("HOME")` / `g_get_home_dir()`. |
| `removingPercentEncoding` (PuTTY names) | URL-decode session names | GLib `g_uri_unescape_string`. |
| `Foundation` `Codable` persistence of `SavedHost` | write imported hosts | Whatever the GTK Vaults port uses for `SavedHost` JSON (match field names + `AuthMethod` raw strings). |
| **Secure-Enclave-wrapped AES-256-GCM at-rest encryption** (in `SavedHostsStore.persist`, downstream of import) | encrypt saved hosts on disk | **No Secure Enclave on Linux.** This is a Vaults-store concern, not the importer's, but the importer's `commit()` depends on it. Fallbacks: libsecret / GNOME Keyring (or KWallet) to wrap the key, or TPM 2.0; document that on Linux the key is software-wrapped unless a TPM is present. The importer itself needs no crypto — it just calls `store.upsert`. |

Nothing in the parsers requires macOS APIs — they are pure string processing and are the cleanest part to port 1:1. The only genuinely Linux-hard dependency is the at-rest key protection inherited from the store, and only PuTTY/SecureCRT hex/`dword` decoding needs care.

### How to verify on Linux

1. **ssh_config discovery:** create a `~/.ssh/config` with mixed syntax (`Host web-1` + `HostName=...`, a multi-pattern `Host a b`, a wildcard `Host *.prod`, `User`/`Port` lines). Open the wizard → `~/.ssh/config`. Expect: `web-1` and `a` present, wildcard excluded, entries sorted case-insensitively, subtitles showing `user@host` and non-22 ports.
2. **CSV round-trip:** "Save template…", then re-import the saved file. Expect 3 hosts parsed with correct auth methods, `Workspace/Dev` groups auto-created, `prod;web` split into two tags. Import a CSV missing the `hostname` column → user-facing error, no crash. Import a row with quoted commas → field integrity preserved.
3. **Other formats:** feed a sample PuTTY `.reg`, a `.mxtsessions`, and a SecureCRT `Sessions` folder; confirm only SSH-protocol sessions appear, non-SSH (telnet/serial) are skipped, and SecureCRT/Moba folder structure maps to group paths.
4. **Dedupe + commit:** import the same source twice; the second run's summary should report the hosts as "already saved" (skipped), matching case-insensitively on hostname+username.
5. **Persistence + encryption:** after import, confirm hosts survive an app restart and that the on-disk hosts file is not plaintext (encrypted at rest, per the Vaults store), with `AuthMethod` serialized as exactly `password`/`publicKey`/`agent`/`ask`.
6. **Cancel paths:** cancelling any file picker leaves the wizard on its current step with no partial import.

## 9. SSH connection flow

### What it is

Stock Ghostty has no concept of a "connection" — you type `ssh …` into a shell and OpenSSH handles the TTY prompts (password, host-key `yes/no`) inline. SarvTerminal replaces that with a **guided, staged SSH connect** (Termius-style): opening a saved host spawns `ssh` directly (no interactive login shell in front of it) and drives it through an overlay **connection popup** that shows staged progress, collects the password out-of-band, resolves host-key trust *before* `ssh` runs, classifies failures into friendly cards, and auto-reconnects dropped sessions. An SSH tab **never shows a dead terminal** — when the session ends the popup returns with Reconnect.

User-visible behavior a port must reproduce:
- A popup card appears for the whole lifecycle (asking → connecting → failed/disconnected) and hides only once `connected` so the live terminal shows. Even a silent saved-password connect flashes the card.
- Password never appears on the TTY (no `password:` echo). It is fed to `ssh` via an `SSH_ASKPASS` helper.
- A new/unknown host key shows an "Add and continue / Continue / Cancel" trust card *before* connecting; a **changed** key shows a red "Replace" card.
- Auth failures show an error card (with "Show logs" / "Copy logs"); network/server failures auto-retry with back-off; a dropped session after a successful connect auto-reconnects.
- Per-pane: each split pane owns its own connection + popup; "Reconnect all" recovers every dropped pane at once.

Source files (all under `macos/Sources/Features/HostManager/`):
- `SSH/SSHConnectionStage.swift` — lifecycle enum + failure taxonomy.
- `SSH/SSHConnectionModel.swift` — observable per-connection state.
- `SSH/SSHConnectionController.swift` — the state machine (polling, host-key actions, reconnect).
- `SSH/SSHConnectionView.swift` — the popup UI (not required reading for logic; ~18KB of SwiftUI cards).
- `SSH/SSHAskpass.swift` — out-of-band password plumbing.
- `SSH/HostKeyScanner.swift` — pre-flight host-key scan/add/remove via system `ssh-keygen`/`ssh-keyscan`.
- `KnownHosts.swift` (`KnownHostsStore`) + `KnownHostsSectionView.swift` — the known-hosts manager UI/store.
- `KeychainSectionView.swift` + `SSHKeys.swift` (`SSHKeyManager`, `SSHKey`) — the "Keychain" section (see note: it is an `~/.ssh` **key-file** manager, NOT the macOS Keychain).
- `SavedHost.swift` — the host model + `sshCommand(staged:)` builder.
- `VaultsTabsModel.swift` — orchestration: `startSSHConnection`, `runHostKeyPreflight`, `proceedConnect`, `launchSSHConnection`, `reconnect`, `connectionDidConnect`, `handleProcessExited`, per-surface `connections` map.

### Key logic & data model

**Per-surface binding.** `VaultsTabsModel.connections: [UUID: ActiveConnection]` is keyed by the **current surface id**, not the tab, so the popup follows a pane when it is dragged into another tab's split. `ActiveConnection { model, controller, command }`. On every (re)launch the old surface's entry is deleted and a new one re-keyed to the freshly spawned surface (`launchSSHConnection`), replacing just that pane's node in the tab's split tree.

**Staged spawn (no shell in front).** The tab starts over a blank placeholder surface. `ssh` is spawned only after the host-key pre-flight (and password step) resolve. The command comes from `SavedHost.sshCommand(staged: true)`, which in staged mode adds:
- `-o StrictHostKeyChecking=accept-new` (GUI handles trust pre-flight; interactive `yes/no` would deadlock against the askpass helper).
- `-o NumberOfPasswordPrompts=1` (a wrong password exits immediately → clean failure card).
- Default keepalive `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` if none configured, so a dead socket is detected and auto-reconnect can fire.
- `SetEnv=TERM=…` / `COLORTERM=truecolor` unless the host opts into `xterm-ghostty` (that path routes through `ghostty +ssh` for remote terminfo install).

**Askpass plumbing** (`SSHAskpass`):
- A one-shot helper script `sarv-askpass.sh` (mode `0700`) is written once into the app support dir; it just `cat`s `$SARV_ASKPASS_FILE`.
- Per connect, the password is written newline-terminated to a temp file `sarv-ssh-<uuid>` (mode `0600`).
- The surface command is prefixed with `env SSH_ASKPASS='…' SSH_ASKPASS_REQUIRE='force' SARV_ASKPASS_FILE='…' <ssh…>` (uses `env` so assignments survive the `exec -l` shell wrapper).
- An empty password sets no env (key/agent auth). The temp file is deleted on connect, on relaunch (previous attempt), and on connection close.

**Host-key pre-flight** (`HostKeyScanner`, all via system binaries, run off-main):
- Token: `host` for port 22, else `[host]:port`.
- `isKnown` = `ssh-keygen -F <token>` (status 0 + non-empty; matches hashed entries).
- `scan` = `ssh-keyscan -p <port> -T 6 <host>` → raw known_hosts lines; preferred-key fingerprint chosen ed25519 > ecdsa > rsa > first, prettified type, SHA256 fingerprint.
- `add` appends lines to `~/.ssh/known_hosts`; `remove` = `ssh-keygen -R <token>`.
- Flow: unknown host → scan → show `.needsHostKey(HostKeyInfo)` card → user picks Add (save) / Continue (added then removed on connect via `pendingHostKeyRemoval`) / Cancel. A **changed** key surfaced at connect time (`host key verification failed` in the terminal, `accept-new` refused it) triggers `handleChangedHostKey`: re-scan, show `changed: true` card with "Replace" (drop stale entry + add new).

**Detection state machine** (`SSHConnectionController`, main-run-loop `Timer` at 0.2s). There is no `ssh` API to observe — success/failure is inferred by **polling the surface's visible text** (`SurfaceView.liveVisibleText()`) and its `childExitedMessage`:
- `looksConnected`: last non-empty line ends in `$ # % ❯ >` after a 1.2s handshake grace.
- `failure(in:)`: substring-matches lowercased terminal text → `SSHFailure` (`permission denied`, `connection refused`, `could not resolve` / `name or service not known` / `nodename nor servname`, `connection timed out` / `operation timed out`, `host key verification failed`, plus `not allowed at this time` and handshake-closed heuristics).
- 20s optimistic timeout → `.timeout` (never silently "succeeds").
- Once `connected`, keeps polling; `childExitedMessage` → `.disconnected` then `scheduleReconnect()`.

**Reconnect / back-off:** `reconnectBackoff = [3,5,10,15,30]` (last repeats). Auto-retry only for `isAutoRetriable` failures (refused/unreachable/timeout/unknown = server/network; auth + host-key are NOT). A "connection lost" OS notification fires **once**, only after `reconnectAlertAfter = 3` failed attempts. A successful connect resets `reconnectAttempts` to 0. `permissionDenied` on an **Ask** host re-prompts inline up to `maxPasswordAttempts = 3`; a **Password** host goes straight to the failure card (fix via Edit host).

**Process-exit path:** libghostty posts a surface close; `VaultsTabsModel` suppresses the normal tab-close for SSH panes (`connections[pane.id]?.model.showsCard`) and calls `controller.handleProcessExited()`, state-guarded so `tick()` and it don't double-fire.

**Persisted schema a port must match:**
- **Hosts** — `~/.config/sarvterminal/hosts.json`, an array of `SavedHost` (see `SavedHost.swift`), **encrypted at rest** (AES-256-GCM via `EncryptedStore`). Auth-relevant fields: `authMethod` (`password`|`publicKey`|`agent`|`ask`), `password` (plaintext inside the encrypted blob; **Password** auth requires it, **Ask** never stores it), `identityFile`, `forwardAgent`, `strictHostKeyChecking` (`yes`|`no`|`ask`|`accept-new`), `connectTimeoutSeconds`, `serverAliveIntervalSeconds`, `proxyJump`, `localForwards`/`remoteForwards`/`dynamicForwardPort`, `termOverride`, `initialCommand` (typed into the shell *after* login, never passed as ssh remote command). Decoding is default-tolerant (missing keys → safe defaults).
- **Known hosts** — standard OpenSSH `~/.ssh/known_hosts`, edited directly (app is unsandboxed). `KnownHostEntry` is parsed, not a Sarv format; `@cert-authority`/`@revoked` prefixes stripped, `|1|` = hashed. Fingerprints computed as OpenSSH-style `SHA256:<base64-no-pad>` over the decoded key blob.
- **SSH keys** — no registry; the files in `~/.ssh` ARE the source of truth. `SSHKey` is derived by scanning with `ssh-keygen -l -f <path>`.

### macOS → Linux/GTK equivalents

| macOS / Apple API | Used for | Linux / GTK4 / Zig equivalent |
|---|---|---|
| SwiftUI overlay popup (`SSHConnectionView`) | The staged connection card over the pane | GTK4 overlay (`GtkOverlay`) with a card widget over the terminal `GtkWidget`; rebuild the stage → view mapping. |
| `Timer` + `RunLoop.main` (0.2s poll, 1s countdown) | Detection loop, reconnect countdown | `g_timeout_add` on the GLib main loop. |
| `ObservableObject` / `@Published` | Model → view binding | GObject properties + signals, or manual re-render on state change. |
| `Foundation.Process` (off-main via GCD) | `ssh-keygen`, `ssh-keyscan`, `ssh-keygen -l` | `GSubprocess` or Zig `std.process.Child`; the binaries (`ssh-keygen`, `ssh-keyscan`) are identical on Linux (`/usr/bin/…`). |
| `SurfaceView.liveVisibleText()` / `childExitedMessage` | Polling for prompt/error/exit | Same libghostty core surface data — expose the equivalent readers to the GTK apprt (`src/apprt/gtk`). This is core, not AppKit-specific. |
| `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` | Out-of-band password | **Works identically on Linux** with OpenSSH ≥ 8.4. Same helper-script + temp-file approach. (On some distros `SSH_ASKPASS_REQUIRE` requires a recent OpenSSH — verify; older ssh needs `setsid`/no controlling TTY for askpass to trigger.) |
| `CryptoKit.SHA256` (`KnownHostsStore.fingerprint`) | known_hosts SHA256 fingerprints | Zig `std.crypto.hash.sha2.Sha256`, or libgcrypt/GnuTLS; base64 with `=` stripped to match OpenSSH. |
| `FileManager.applicationSupportDirectory` / `AppIdentity.bundleID` | Askpass helper location | XDG: `$XDG_DATA_HOME` (`~/.local/share/sarvterminal`) for the helper; `$XDG_CONFIG_HOME` (`~/.config/sarvterminal`) for `hosts.json`. |
| `NSHomeDirectory()` | `~/.ssh/known_hosts`, `~/.ssh` | `getenv("HOME")`. Paths are already POSIX-standard. |
| `FileManager.temporaryDirectory` + `posixPermissions 0600/0700` | Password temp file, helper script | `$TMPDIR`/`/tmp` + `chmod` (0600/0700). Same semantics. |
| `NSPasteboard`, `NSWorkspace.activateFileViewerSelecting` (Keychain section) | Copy public key, reveal in file manager | `GdkClipboard`; open the folder via `xdg-open` / `GtkFileLauncher`. |
| `SarvNotifications` (host-key-changed, disconnected) | OS notifications | `GNotification` / libnotify. |

**No clean Linux equivalent — call out explicitly:**
- **Secure Enclave + macOS Keychain.** `hosts.json` (which holds saved SSH passwords) is encrypted at rest with an AES-256-GCM key wrapped by the Secure Enclave. Linux has no Secure Enclave. Fallback options, in order of preference: (1) store passwords in the **Secret Service API** via `libsecret` (GNOME Keyring / KWallet) instead of in the JSON blob; (2) derive the file-encryption key from a TPM2-sealed key where available; (3) as a last resort, a passphrase-derived key (Argon2) — and if none is available, fall back to plaintext with a visible security warning, matching the app's existing "surfaces a security note" stance. The **schema is portable**; only the key-wrapping mechanism must be re-implemented.
- **Naming caveat:** the "Keychain" section (`KeychainSectionView`) does **not** use the macOS Keychain at all — it is a manager for private/public **key files in `~/.ssh`** (generate/copy/reveal/delete via `ssh-keygen`). Port it as-is against `~/.ssh`; do not wire it to Secret Service.

### How to verify on Linux

1. **Silent password connect:** save a Password host, connect. The popup card appears, no `password:` prompt echoes on the TTY, and it lands at a shell prompt; the card hides. Confirm no `sarv-ssh-*` temp file remains under `$TMPDIR` afterward.
2. **Ask host re-prompt:** an Ask host with a wrong password re-prompts inline up to 3 times, then shows the failure card. The typed password is NOT written back to `hosts.json`.
3. **Unknown host key:** connect to a host absent from `~/.ssh/known_hosts` → trust card shows type + `SHA256:` fingerprint. "Add and continue" appends to `known_hosts` (verify with `ssh-keygen -F <host>`); "Continue" connects but leaves no entry after success.
4. **Changed host key:** alter the stored key, reconnect → red "Replace" card; Replace drops the stale line and adds the new one; a host-key-changed notification fires once.
5. **Auto-reconnect:** connect, then `sudo iptables`/kill the server; the session drops and the popup counts down `3,5,10,15,30s`; a "connection lost" notification appears only on the 3rd failed attempt; restoring the server auto-reconnects and the back-off resets.
6. **Error classification:** point a host at a closed port (refused, auto-retries), a bad DNS name (host not found, auto-retries), and a host that rejects the password (auth failed, does NOT auto-retry) — each maps to the right card title/detail.
7. **Per-pane / Reconnect all:** open two split panes to two hosts, drop the network, confirm each pane's popup is independent and one "Reconnect all" recovers both.
8. **Keychain section:** generate an ed25519 key → files appear in `~/.ssh`, list refreshes, "Copy public key" yields the `.pub` contents, delete removes both files.
9. **Askpass env sanity:** `SSH_ASKPASS_REQUIRE=force` is honored by the target distro's OpenSSH (check `ssh -V` ≥ 8.4); if not, the helper won't be invoked and the connect will hang on the TTY prompt — that is the key portability risk to test first.

## 10. SSH key management

### What it is

Vaults includes a **Keychain** section (Vaults → Keychain) that manages the SSH keys in the user's `~/.ssh` directory. From the user's view it lets them:

- **Generate** a new key pair (Ed25519 / ECDSA-521 / RSA-4096), with an optional passphrase and a free-form comment, written straight into `~/.ssh/<name>`.
- **Browse** an existing key list scanned from `~/.ssh`, each row showing the key name, type, bit size, fingerprint, comment, and a "no .pub" badge when the public half is missing.
- **Copy the public key** (to paste into a server's `authorized_keys` or GitHub), **copy the private key path**, **reveal in Finder**, and **delete** a key (removes both the private and `.pub` files).
- **Bind a key to a host**: in the host editor, when auth method is "Public key", the identity-file field takes an absolute path to a private key, which is passed to `ssh` as `-i <path> -o IdentitiesOnly=yes`.

Stock Ghostty has no host/vault concept at all, so none of this exists upstream. Sarv added it so users can manage keys and wire them to saved hosts without leaving the terminal. Note the naming is historical: the section is called "Keychain" in the UI but it does **not** use the macOS Keychain — the on-disk `~/.ssh` files are the single source of truth.

Key files:
- `macos/Sources/Features/HostManager/SSHKeys.swift` — model + `SSHKeyManager` (scan/generate/delete).
- `macos/Sources/Features/HostManager/KeychainSectionView.swift` — the list UI + generator sheet.
- `macos/Sources/Features/HostManager/SavedHost.swift` — `identityFile` field + `ssh` command assembly.
- `macos/Sources/Features/HostManager/HostEditorView.swift` — identity-file field + `Browse…` picker (`pickIdentityFile`).
- `macos/Sources/Features/HostManager/Files/FileBackend.swift` — `RemoteFileBackend.runProcess` (the subprocess runner used to shell out to `ssh-keygen`).

### Key logic & data model

There is **no persisted registry of keys** — the manager rebuilds its list from disk every time by scanning `~/.ssh`. The critical detail for a port is that the schema to match is not a JSON file but the disk layout and the shell-out contracts.

**`SSHKey` (in-memory model, built per scan):**
- `name: String` — the private key's file name (e.g. `id_ed25519`); doubles as `id` via `privatePath`.
- `privatePath: String` — absolute path to the private key.
- `publicPath: String?` — absolute path to the sibling `<name>.pub`, or nil if absent.
- `type: String` — `"ED25519"` / `"RSA"` / `"ECDSA"` … (as reported by `ssh-keygen`).
- `bits: Int`, `fingerprint: String` (`"SHA256:…"`), `comment: String`.
- `hasPublicKey: Bool` = `publicPath != nil`.

**Scan algorithm (`refresh`):**
1. `contentsOfDirectory` of `~/.ssh`; missing dir → empty list, not an error.
2. Candidate filter: exclude `.pub` files, dotfiles (`hasPrefix(".")`), and an ignore set: `known_hosts`, `known_hosts.old`, `config`, `authorized_keys`, `environment`, `rc`, `.DS_Store`, `agent.sock`. Sort remaining names.
3. Skip directories.
4. For each candidate, prefer fingerprinting the `.pub` when present (never prompts for a passphrase); else fingerprint the private key.
5. Fingerprint = run `/usr/bin/ssh-keygen -l -f <path>` and parse the single output line `"<bits> <fingerprint> <comment...> (<TYPE>)"`: `tokens[0]`=bits, `tokens[1]`=fingerprint, `tokens.last` stripped of `()`=type, middle tokens joined=comment. A port must replicate this exact token parsing (comment may contain spaces).

**Generate (`generate`):** validates a non-empty trimmed name; **fails if a file already exists** at `~/.ssh/<name>` (no overwrite prompt); ensures `~/.ssh` exists with mode `0o700`; runs `/usr/bin/ssh-keygen <type args> -f <path> -N <passphrase> -C <comment> -q`. Type args: ed25519 → `-t ed25519`; ecdsa → `-t ecdsa -b 521`; rsa → `-t rsa -b 4096`. Empty passphrase (`-N ""`) means no passphrase. On success, re-scans.

**Delete:** removes the private file and the `.pub` (if any) via filesystem removal, then drops it from the published list.

**Host binding (the persisted part):** the key↔host link lives in the encrypted host store as a single field on `SavedHost`:
- `identityFile: String` — absolute path; `""` disables (decoded with `decodeIfPresent … ?? ""`).
- `SavedHost.sshCommand` emits `-i <shellQuoted(expandTilde(identityFile))>` **plus** `-o IdentitiesOnly=yes` whenever `identityFile` is non-empty (**not** gated on `authMethod`); `HostPlatform.swift` (the OS-detection probe) emits `-i <expandedTilde path>` as separate argv elements and there does gate on `authMethod == .publicKey`. A port must keep both the `IdentitiesOnly=yes` pairing and tilde expansion. Note `identityFile` is a free-form path string, **not** a foreign key into the key list — the two subsystems are only loosely coupled through the path.

### macOS → Linux/GTK equivalents

- **`ssh-keygen` shell-out** (`/usr/bin/ssh-keygen -l -f` and generation): identical on Linux — invoke `ssh-keygen` from `PATH` (do not hardcode `/usr/bin`; on many distros it is `/usr/bin/ssh-keygen`, but resolve via `PATH`). This is the core of the subsystem and ports directly. In Zig use `std.process.Child` with captured stdout/stderr; the GTK apprt already spawns subprocesses.
- **`RemoteFileBackend.runProcess`** (async `Process` with piped stdout/stderr, cancellation): map to `std.process.Child.run`/`collectOutput` or GLib's `GSubprocess` (`g_subprocess_communicate_async`).
- **`FileManager` directory scan / `createDirectory` with `0o700` / `removeItem`**: `std.fs.cwd()`/`std.fs.Dir` (`iterate`, `makePath`, `deleteFile`) or GLib GIO (`GFileEnumerator`). Enforce `0700` on `~/.ssh` and `0600` on generated private keys — `ssh-keygen` sets key perms itself, but the directory-create must pass mode `0o700`.
- **`NSHomeDirectory()` + `.ssh`**: `std.posix.getenv("HOME")` (or `g_get_home_dir()`), then join `.ssh`.
- **`ObservableObject`/`@Published` (`keys`, `loading`, `error`)**: reactive UI state → a GObject with signals, or the apprt's existing state-notify pattern; the GTK list re-reads on a manual Refresh action.
- **`NSPasteboard`** (copy public key / path): `GdkClipboard` (`gdk_clipboard_set_text`).
- **`NSWorkspace.activateFileViewerSelecting`** (Reveal in Finder): open the file manager via `gtk_file_launcher` / `g_app_info_launch_default_for_uri` on the containing directory (there is no cross-DE "select this file" API — opening `~/.ssh` is an acceptable fallback).
- **`NSOpenPanel`** (Browse for identity file, defaulting to `~/.ssh`, hidden files shown): `GtkFileDialog` (`gtk_file_dialog_open`) with initial folder `~/.ssh`.
- **`Host.current().localizedName` / `NSUserName()`** (default comment `user@machine`): `g_get_user_name()` + `g_get_host_name()` (or `gethostname`).
- **Secure Enclave / macOS Keychain**: **not used here at all** despite the "Keychain" section name — nothing to port. (The at-rest encryption of the *host* store is a separate subsystem; SSH private keys themselves are protected only by their file permissions and the optional passphrase, exactly as on Linux.) So there is no missing-hardware fallback to design for this subsystem.

### How to verify on Linux

1. **Empty state**: with no `~/.ssh`, open Vaults → Keychain; expect an empty-state prompt, no error, no crash.
2. **Generate**: create an Ed25519 key named `id_ed25519_test` with a comment; confirm `~/.ssh/id_ed25519_test` (mode `0600`) and `id_ed25519_test.pub` exist, `~/.ssh` is `0700`, and the row shows type `ED25519`, correct bits, and a `SHA256:` fingerprint matching `ssh-keygen -l -f ~/.ssh/id_ed25519_test.pub`.
3. **Passphrase**: generate with a passphrase and confirm the private key is encrypted (its header shows it is passphrase-protected) and the list still fingerprints it via the `.pub` without prompting.
4. **Duplicate guard**: generating a second key with an existing name fails with an "already exists" error and does not overwrite.
5. **Scan filtering**: `config`, `known_hosts`, `authorized_keys`, and dotfiles never appear as keys; a private key whose `.pub` is deleted shows the "no .pub" badge and its Copy-public-key action is disabled.
6. **Copy / reveal / delete**: Copy public key puts the `.pub` contents on the clipboard; Delete removes both files from `~/.ssh` and the row disappears.
7. **Host binding round-trip**: set a host's auth to Public key and Browse to the generated key; confirm the built command contains `-i <path> -o IdentitiesOnly=yes`, that a `~`-relative path is tilde-expanded, and that an actual `ssh` connection authenticates with that key.

## 11. Session model & persistence

> Scope note: this section covers the terminal **tab/session model** — tab lifecycle, split-layout save/restore, per-pane cwd/SSH capture, linked sessions, tab colors, input broadcasting, and restore-on-launch. The surface-leak fix (§1), pane-title derivation (§3), the manual-title-wins logic (§4), and the close-with-running-process confirmation (§5) are documented elsewhere; they are referenced but not re-explained here.

### What it is

Stock Ghostty treats a window/tab as ephemeral: close it and it's gone, quit and nothing comes back. Sarv embeds all terminals in one window (`VaultsTabsModel`, `macos/Sources/Features/HostManager/VaultsTabsModel.swift`) and layers a full session model on top:

- **Restore on launch** — on quit the open tabs (with their split layouts) are serialized; on next launch the user is asked "Reopen your last session?" and, if yes, every tab is rebuilt: local panes respawn in their old working directory, SSH panes reconnect. Gated by a Settings toggle (`SarvRestoreSession`, default on).
- **Saved Sessions library** — a named, persisted snapshot of a tab's exact split arrangement (tree shape, split directions, ratios, per-pane kind/cwd/host). Reopen one from the sidebar (`SavedSessionsSectionView`) to recreate the layout on demand. Each row shows a live **layout preview** diagram (`SessionLayoutPreview`).
- **Reopen-closed-tab (⌘⇧T)** — a closed tab is captured as a lightweight value snapshot and can be recreated at its original position for a limited window (10 most-recent, 5-minute retention). Note the snapshot is deliberately a value, not the live tab, because closing must free surfaces immediately (see §1 leak fix).
- **Linked sessions** — a tab can be linked to a library session so renaming one renames the other; ⌘S re-saves the tab into its linked session (or forks a new one).
- **Tab colors** — an accent color per tab, chosen from a fixed 9-color palette, persisted with the session.
- **Input broadcasting** — mirror keystrokes from the focused pane to every other live pane in the same tab.

### Key logic & data model

**The single serialization type is `SavedSession`** (`macos/Sources/Features/HostManager/SavedSession.swift`). Every feature above (library, launch-restore, closed-tab undo) snapshots a tab into this same shape. A Linux port must match this JSON schema exactly for cross-platform sync (§ sync) and for reading files written by macOS.

`SavedSession` (Codable):
- `id`: UUID
- `name`: String
- `createdAt`, `updatedAt`: Date — **encoded ISO-8601 in the library file, but with the default (numeric, seconds-since-2001 reference date) strategy in `session.json`** (see storage note below). A port must honor both.
- `colorID`: String? — one of the fixed palette ids: `blue purple pink red orange yellow green teal gray` (`VaultsTabsModel.tabColorOptions`). nil = no color.
- `linkTabName`: Bool? — whether the tab name follows the session name. **nil reads as true** (`linksTabName` computed accessor) for back-compat.
- `linkedSessionID`: UUID? — used only in restore/closed-tab snapshots: the library session the tab was linked to, so ⌘S on a restored tab still offers "update existing".
- `layout`: `PaneNode` — the split tree root.

`PaneNode` is an `indirect enum` with two cases, encoded by Codable's default enum strategy (a keyed container with `leaf` / `split` keys):
- `.leaf(Pane)`
- `.split(Split)` where `Split = { direction: "horizontal" | "vertical", ratio: Double, left: PaneNode, right: PaneNode }`. `horizontal` = left|right, `vertical` = top/bottom.

`Pane`:
- `kind`: `"local"` | `"ssh"`
- `workingDirectory`: String? — set for local panes (from `surface.pwd`), nil for SSH.
- `hostID`: UUID? — a `SavedHost` id for SSH panes (preferred: keeps password handling in the host store/Keychain). **No secrets are ever stored in the session.**
- `command`: String? — raw `ssh …` fallback when there's no saved host.
- `title`: String? — a **stable** label only (explicit user rename or SSH host label), never a transient live/OSC title.
- `titleIsUserSet`: Bool? — true only when `title` came from an explicit "Change Terminal Title". Restore re-pins a *local* pane's title only when this is true; otherwise the pane derives its title live (see §3). nil = not user-set.

**Snapshot (save)** — `makeSavedSession(from:name:)` → `savedNode` (recurses the live `SplitTree`) → `savedPane` per leaf. `savedPane` decides kind by looking up the pane in the live SSH connection registry (`connections[view.id]`), falling back to the tab's `launchCommand` for a single-pane quick-connect `ssh …` tab; everything else is local with `view.pwd` as the cwd. Title capture: `view.isUserTitled && !view.title.isEmpty` picks the user title, else the sticky `tab.paneTitleOverrides[view.id]`.

**Restore (open)** — `openSavedSession(_:at:)` → `buildNode` recursively rebuilds a `SplitTree`. Local panes spawn directly with `cfg.workingDirectory = pane.workingDirectory`; SSH panes are created as *blank placeholder surfaces* and collected, then after the tree is mounted (`DispatchQueue.main.async`) each is connected — via `connectSavedHostInPane` if the `hostID` still resolves, else by sending the raw `command` into the placeholder shell. `titleOverrides` are re-pinned only for SSH panes or `titleIsUserSet == true` locals.

**Persistence triggers** — `terminals` `didSet` calls `persistSession()`; additionally `observeTabChanges()` subscribes to each tab's `objectWillChange` (color, rename, layout, pane-title overrides) and to each **surface's** `$title` (pane titles live on surfaces, not the tab). Writes are coalesced to one per runloop tick via `schedulePersist()`. This dual observation matters: splits/pane-drags add surfaces without mutating the `terminals` array.

**Two files, two stores:**
- `session.json` (`TabSessionStore` in `TabSession.swift`) — the last-session tab list, an **array of `SavedSession`**. Written **plaintext** with a default `JSONEncoder`. Has a legacy migration path: an older flat `TabSessionEntry` array (`hostID/launchCommand/title/customName/workingDirectory`) is decoded and upconverted via `asSavedSession()` to single-leaf sessions.
- `saved-sessions.json` (`SavedSessionsStore`) — the named library, an **array of `SavedSession`**, written **encrypted at rest** via `EncryptedStore` (AES-GCM, see § encryption), with ISO-8601 dates. Sorted newest-first by `createdAt`. Has CRUD + sync helpers (`ingest` = merge by id, newest `updatedAt` wins, never deletes local-only; `replaceAll` = mirror deletes).

**Broadcasting** (`broadcastKeyEvent`) — the focused pane keeps native key handling (IME, ⌘K); the event is *not* consumed. Other eligible panes receive the key straight through the core (`ghostty_surface_key`), bypassing the NSView/IME pipeline (which caused doubled input). `paneAcceptsBroadcast` excludes panes still showing the SSH popup or the blank chooser. `broadcasting` is a live `@Published` on `TerminalTab` — **not persisted**.

**In-memory-only tab state** (not in the schema): `TerminalTab.broadcasting`, `focusedSurface`, `connectHost`, and `sessionID` (the last is re-derived on restore from `linkedSessionID ?? session.id`).

### macOS → Linux/GTK equivalents

| macOS / Swift piece | Purpose | Linux / GTK4 / Zig equivalent |
|---|---|---|
| `SplitTree<Ghostty.SurfaceView>` | live split tree per tab | GTK app already has split containers; the port must add a serializable mirror of the tree (direction/ratio/leaf) — the `PaneNode` schema is the target shape. |
| `Codable` (`JSONEncoder`/`Decoder`, ISO-8601 & default date strategies) | JSON (de)serialization | Zig `std.json`. **Must reproduce Swift's enum encoding** for `PaneNode` (keyed `{"leaf":{…}}` / `{"split":{…}}`) and both date encodings (ISO-8601 string for the library, numeric reference-date seconds for `session.json`) to stay wire-compatible. |
| `EncryptedStore` (AES-GCM, key wrapped by Secure Enclave) | encrypt `saved-sessions.json` at rest | **No Secure Enclave on Linux.** Wrap the AES key with the platform secret store (libsecret / GNOME Keyring / KWallet via Secret Service), or fall back to a passphrase-derived key / file-permission-only plaintext. This is the same fallback problem as the other encrypted stores — solve it once. See §encryption. |
| `SavedHostsStore` + Keychain (password lookup by `hostID`) | SSH reconnect without storing secrets in the session | GTK host store + libsecret. Sessions only carry `hostID`; the secret lives in the host store, so this rides on the hosts port. |
| `UserDefaults` (`SarvRestoreSession`, new-tab-directory key) | preferences | GSettings / config file. |
| `AppPaths.configDir` | file location — macOS uses `~/.config/sarvterminal/` (`-dev` suffix in debug), i.e. `NSHomeDirectory()/.config/<id>`, **not** `~/Library/Application Support/` | `$XDG_CONFIG_HOME/sarvterminal/` (or `~/.config/…`) — effectively the same path macOS already uses. The doc comment on `SavedSessionsStore` confirms `~/.config/sarvterminal/`. |
| `ObservableObject` / `@Published` / Combine (`objectWillChange`, `$title` sinks, coalesced persist) | auto-persist on any tab/surface change | GTK signals / property-notify handlers → a debounced (idle-callback) save. Replicate the "observe both the tab and every surface title" rule or pane-title/layout edits won't persist. |
| `RelativeDateTimeFormatter`, `NSHomeDirectory()` | "Saved 3 minutes ago", `~` display | glib date formatting / `g_get_home_dir()`. |
| `NSItemProvider` / `Transferable` (tab drag ids) | drag panes/tabs between tabs | GTK drag-and-drop; affects layout but not the persisted schema. |
| `ghostty_surface_key` / `SurfaceView.sendText` | broadcast keys, send raw ssh command to a placeholder pane | Same libghostty core call from GTK; the placeholder-then-connect pattern for SSH restore is app-layer and must be reimplemented. |

**No clean Linux equivalent:** Secure Enclave (key wrapping) — use Secret Service; and Keychain (SSH passwords) — use libsecret. Both are shared with other subsystems; do them once and this feature inherits them.

### How to verify on Linux

1. **Launch restore:** open 3 tabs (one plain local, one with a 2-pane vertical split, one SSH). Quit. Relaunch → confirm the "Reopen your last session?" prompt, accept, and verify all three tabs return with the correct split shape/ratios, local panes at their old cwd, and the SSH pane reconnecting.
2. **Restore toggle:** turn the restore preference off, quit, relaunch → no prompt, no tabs; turn it back on and confirm autosave still captured a later session (it should keep saving while off).
3. **Saved session round-trip:** build a mixed split, "Save Session…", quit the app entirely, relaunch, open it from the sidebar → identical layout; confirm the sidebar **layout preview** matches.
4. **Schema/wire compat:** inspect `session.json` (plaintext) — confirm the `PaneNode` encoding is `{"leaf":…}`/`{"split":{"direction":"horizontal","ratio":…,"left":…,"right":…}}` and dates are numeric; confirm a macOS-written `saved-sessions.json` decrypts and decodes (ISO-8601 dates) on Linux and vice-versa.
5. **No secrets in files:** grep both files for any password — only `hostID`/`command` should appear for SSH panes.
6. **Closed-tab undo:** close a tab, press ⌘⇧T → it returns at its original index with layout/cwd/SSH intact. Close a tab and wait past the retention window → it is not recoverable.
7. **Linked rename:** save a session (linked on), rename the library entry → the open tab's chip renames too; rename the tab via ⌘S save → the library entry follows.
8. **Tab color:** set a tab color, save+reopen → color persists and matches the palette id.
9. **Broadcasting:** open a 2-pane tab, enable broadcast, type → both shells receive input with no doubled characters; a pane still on the SSH connect popup receives nothing. Confirm broadcasting state is **not** restored after relaunch.
10. **Legacy migration:** drop an old flat `TabSessionEntry`-format `session.json` in place and confirm it still restores as single-pane tabs.

## 12. Splits, panes & focus mode

### What it is

Inside a single Vaults window, one terminal *tab* can hold multiple *panes* arranged as a split grid — the same split model stock Ghostty has, but wrapped in Sarv-specific chrome and workflows that stock Ghostty (which splits within a native window and tears panes off into new windows) does not have:

- **Per-pane header (Termius-style card).** When a tab has more than one pane, each pane is drawn as a rounded, inset card with a title header (process/cwd-derived — see section 3), plus a broadcast toggle, a focus-mode button, and a close ✕. The focused pane gets a solid accent border; unfocused panes get a dotted grey border. A single-pane tab has no header and no border.
- **The inline split chooser ("blank pane" UX).** Splitting does not immediately spawn a shell you must configure. The new pane spawns a local shell but overlays an "Open in this split" chooser (search + saved-hosts list + quick-connect) so the user picks *what to run* (a saved host, an `ssh user@host`, or the already-running local shell). Arrow keys + Enter navigate it.
- **Drag to rearrange / detach.** A pane's header is a drag handle (open/closed-hand cursor). Drag it onto another pane to re-split within the tab; drag it onto the tab strip to detach it into its own standalone tab. Conversely a single-pane tab chip can be dragged *into* another pane to become a split. The live surface moves as-is, so a running process / SSH session survives the move.
- **Focus mode (⌘⇧M).** An alternate rendering of the same split tree: a 240px sidebar listing every pane + one large main pane. Toggling back restores the exact grid. New panes added while in focus mode appear in the sidebar and re-grid on switch-back.

Sarv added all of this because it is a **single-window** embedded-terminal app: panes must never tear off into a chrome-less native window (that would lose the Vaults UI, shared background image, and the per-pane SSH connection popup), and the split/pane surface is the primary product workspace rather than a power-user extra.

### Key logic & data model

**The split tree (`macos/Sources/Features/Splits/SplitTree.swift`).** `SplitTree<ViewType>` is an immutable value type over an `indirect enum Node`:

- `Node = .leaf(view:)` or `.split(Split)` where `Split { direction: Direction, ratio: Double, left: Node, right: Node }`, and `Direction = .horizontal | .vertical` (horizontal = left|right, vertical = top/bottom).
- Plus an optional `zoomed: Node`.
- All mutations return a new tree: `inserting(view:at:direction:)`, `removing(_:)` (sibling collapses into the parent's place), `replacing(node:with:)`, `resizing(...)`, `equalized()`. `NewDirection = .left/.right/.up/.down` maps to (splitDirection, which side the new leaf lands on).
- Spatial navigation (`Spatial`/`spatial()`) assigns relative bounds to every node so left/right/up/down focus moves resolve to the nearest leaf by euclidean distance. Structural identity (`structuralIdentity`, hashes structure + view object identity, deliberately ignoring ratios) drives SwiftUI's `.id()`.
- **Persisted schema for the LIVE tree:** `SplitTree` is `Codable` with `CodingKeys { version, root, zoomed }`, `currentVersion = 1`; a node encodes as `{ "view": ... }` or `{ "split": {...} }`; `zoomed` is stored as a **path** (array of `.left`/`.right`) and re-resolved on decode because leaves are reference types. A port must match this shape byte-for-byte to interop with saved state.

**Sarv views layered on top.** `VaultsSplitTreeView.swift` mirrors stock `TerminalSplitTreeView.swift` but adds: the per-pane header/card, `awaiting: Set<UUID>` (surface IDs showing the chooser), `broadcasting`, `focusedID` (border state), the `SplitChooserView` overlay, and the per-surface `SSHConnectionView` overlay. Operations flow out via `TerminalSplitOperation` (`.resize` / `.drop`) — the tree is immutable, so the view emits intent and `VaultsTabsModel` applies it.

**Drag/drop wiring:**
- Drag source: `Ghostty.SurfaceDragSource` (`macos/Sources/Ghostty/Surface View/SurfaceDragSource.swift`) runs an AppKit `NSDraggingSession`, writing the surface id as **16 raw UUID bytes** under pasteboard type `ghosttySurfaceId`. It publishes the in-flight drag id via the `DraggingSurfaceKey` SwiftUI preference (used to hide a pane's own drop zone while it is the one being dragged). `endedAt` with no target is a deliberate **no-op** (single-window: never tear off).
- Drop target: `PaneDropTarget.swift` is a bespoke AppKit `NSView` (`registerForDraggedTypes([ghosttySurfaceId, vaultsTabID])`) overlaid on each pane, `isFlipped = true`, `hitTest → nil` (transparent to normal mouse; only drag sessions land). This exists because SwiftUI `.onDrop` over the Metal surface delivers hover callbacks but silently drops `performDrop`. It computes a `TerminalSplitDropZone` (`.top/.bottom/.left/.right`, triangular regions by proximity to edge) and emits a `Payload`: `.surface(UUID)` (pane rearrange) or `.tab(UUID)` (tab chip injected).
- Tab-chip payload uses a **custom** UTType `vaultsTabID` (`com.sarvterminal.vaultsTabID`), a UUID **string**, deliberately NOT `public.text` — the terminal surface registers for `.string` and would otherwise swallow/paste it (`VaultsTabsModel.swift` top: `UTType.vaultsTabID`, `NSItemProvider.vaultsTab`/`loadVaultsTabID`).

**Model operations (`macos/Sources/Features/HostManager/VaultsTabsModel.swift`):**
- `splitAwaitingChoice(direction:)` — inserts a new local-shell surface at the focused anchor (inheriting its `pwd`), inserts its id into `awaitingChoice` (does NOT move focus, so the chooser keeps it).
- `resolveChoice(surface:action:)` — dispatches on `PaletteAction` (`.localTerminal` reveals the running shell; `.host`/`.quickConnect` send an ssh command; `.savedHost` runs a staged in-pane connect; `.serial` unsupported in a split).
- `.drop` handling — same-tab pane move: `removing(sourceNode)` then `inserting(view:at:direction:)` from the zone.
- `injectTab(_:into:zone:)` — single-pane source tab merged into a destination pane's split (multi-pane sources rejected); source tab removed *without freeing the surface*.
- `detachPane(surfaceID:before:)` — reverse: pane pulled out into a standalone tab (names it from the sticky override or a deduped "Terminal"); a single-pane tab degenerates to a plain reorder.
- `injectTabIntoAwaiting(...)` — a tab chip dropped onto an empty (chooser) pane replaces it.
- `toggleBroadcast` / `broadcastKeyEvent` — mirror keystrokes to all other live panes (`paneAcceptsBroadcast` excludes chooser/connecting panes).
- Focus mode: `focusMode: Bool`, `focusModeSurfaceID: UUID?`, `toggleFocusMode()`, `selectFocusModePane(_:)`. `VaultsFocusModeView.swift` renders the sidebar+main split from `tab.surfaceTree.root?.leaves()`.
- Pane naming: `paneTitleOverrides: [UUID: String]` on each `TerminalTab` (sticky per-pane names — host label, dragged-in name); title resolution is the pure static `paneDisplayTitle(...)` (see section 3).

**Persisted schema for SAVED sessions** (`macos/Sources/Features/HostManager/SavedSession.swift`, distinct from the live-tree Codable above): `SavedSession { id, name, createdAt, updatedAt, colorID?, linkTabName?, linkedSessionID?, layout: PaneNode }`. `PaneNode = .leaf(Pane) | .split(Split{direction, ratio, left, right})`, `Direction = "horizontal"|"vertical"`. `Pane { kind: "local"|"ssh", workingDirectory?, hostID?, command?, title?, titleIsUserSet? }`. **No secrets stored** — SSH panes reference a `SavedHost` by `hostID` (password stays in the host store) or carry only the plain `ssh` command as a fallback. Stored at `~/.config/sarvterminal/saved-sessions.json`, encrypted at rest (JSON, ISO-8601 dates, via `EncryptedStore`). A port must match these field names/shapes to read existing session files.

### macOS → Linux/GTK equivalents

| macOS piece used | Purpose here | Linux/GTK equivalent |
| --- | --- | --- |
| `SplitTree<SurfaceView>` (SwiftUI `SplitView` + `GeometryReader`) | Recursive resizable split grid | A recursive tree of `GtkPaned` (or a custom widget), or reuse the GTK apprt's existing split container. Keep the **same immutable tree + ratio model** so persisted JSON stays compatible. GTK's Ghostty already has base splits to build on. |
| AppKit `NSDraggingSession` (`SurfaceDragSource`) | Start a pane drag from the header handle | GTK4 `GtkDragSource` with a `GdkContentProvider`; preview via `gtk_drag_source_set_icon` (surface snapshot). |
| AppKit `NSView` drop target (`PaneDropTarget`, needed because SwiftUI drop over Metal fails) | Reliable drop onto a GPU surface | GTK4 `GtkDropTarget` / `GtkDropTargetAsync` attached to the pane widget. GTK's drop delivery is not tied to the SwiftUI-over-Metal problem, so the AppKit workaround itself is not needed — but keep the same **zone math** (`TerminalSplitDropZone.calculate`, triangular regions) and the **hidden-self-zone** behavior. |
| Pasteboard UTTypes `ghosttySurfaceId` (16 raw UUID bytes) and `vaultsTabID` (UUID string) | Distinguish pane-drag vs tab-chip drag, and avoid the terminal swallowing the payload | GDK content mime types, e.g. `application/x-sarvterminal-surface-id` and `application/x-sarvterminal-tab-id`. Registering a **custom, non-text** mime is the same trick to keep the payload from reaching the terminal's own text-drop handler. |
| `NSCursor.openHand` / `.closedHand` | Grab-handle affordance | `GdkCursor` named `"grab"` / `"grabbing"`. |
| `DraggingSurfaceKey` SwiftUI preference | Broadcast which surface is mid-drag (to suppress its own drop zone) | Plain shared model/signal state in the GTK view model. |
| SwiftUI overlays (`SplitChooserView`, `SSHConnectionView`, dotted/solid border, tooltip presenter) | Chooser, connection popup, focus/border chrome, hover tips | GTK4 `GtkOverlay` + CSS (dashed vs solid border, rounded card), `GtkPopover`/tooltips. The chooser reuses the command-palette model — build once, share with the palette port. |
| `Codable` / `JSONEncoder` (SplitTree v1 + SavedSession) | Serialize live tree and saved sessions | Zig `std.json` (or the Zig core's serialization). Must reproduce: SplitTree `{version:1, root, zoomed(as path)}`, node `{view}|{split}`; SavedSession/PaneNode/Pane exactly. |
| `EncryptedStore` (AES-GCM key wrapped by Secure Enclave) for `saved-sessions.json` | Encrypt saved layouts at rest | **No Secure Enclave / Keychain on Linux.** This is a cross-cutting concern shared with the hosts/vault subsystem — follow that section's fallback (libsecret-wrapped key, or TPM where available). The splits code itself only needs the store to round-trip; it doesn't touch the crypto directly. |
| `foregroundProcessName`, `pwd`, `isUserTitled` from the libghostty surface | Derive pane titles | Same libghostty-vt / core surface API is available on GTK; wire the GTK surface view to expose them. Title derivation logic lives in section 3. |

Nothing in this subsystem is macOS-only in *concept* — the split tree, zones, and persistence are pure logic. The only genuinely non-portable pieces are (a) the Secure-Enclave-backed encryption of the saved-session file (cross-referenced to the vault/crypto section) and (b) the AppKit drop workaround, which GTK simply doesn't need.

### How to verify on Linux

1. **Split + chooser:** Split a pane; confirm the new pane shows the "Open in this split" chooser over a (hidden) live local shell, with search, saved-host rows, arrow-key + Enter navigation, and Esc to dismiss. Choosing "Local Terminal" reveals the shell; choosing a saved host opens the staged SSH connection in that pane.
2. **Header/border states:** With >1 pane, each pane shows a header card; the focused pane has a solid accent border, others a dotted grey border; a single-pane tab has neither.
3. **Rearrange within a tab:** Drag a pane by its header onto another pane; confirm the green drop-zone overlay tracks the top/bottom/left/right region and the pane re-splits accordingly, keeping its running process alive.
4. **Detach:** Drag a pane onto the tab strip; it becomes a standalone tab (named from its sticky/host name, not the live shell title) with its process intact. Detaching a single-pane tab just reorders it.
5. **Inject a tab into a split:** Drag a single-pane tab chip onto a pane; it merges as a split and the source chip disappears. A multi-pane tab chip must be rejected.
6. **Focus mode:** Press ⌘⇧M-equivalent; confirm the sidebar lists all panes with live titles, selecting a row swaps the main pane and moves focus, and toggling back restores the identical grid (ratios preserved).
7. **Persistence round-trip:** Save a session with a non-trivial layout (mixed local/SSH panes, custom ratios), quit, reopen; the tree, directions, ratios, and pane names restore. Inspect the on-disk JSON to confirm it matches the `SavedSession`/`PaneNode`/`Pane` field names and the `SplitTree` `{version:1,...}` shapes so files interop with the macOS build.
8. **Broadcast:** Enable broadcast; typing in one pane mirrors to all other *live* panes but not to panes still showing the chooser or a connecting SSH popup.

## 13. Snippets

### What it is

A per-user library of saved shell commands ("snippets") that live in the Vaults sidebar. Stock Ghostty has no notion of saved commands. Sarv added Snippets so a user can keep their most-used commands (deploy scripts, SSH one-liners, long `docker`/`kubectl` invocations, etc.) and, in one click, **run or paste** any of them into an open terminal, or **copy** the command to the clipboard.

Key user-facing behaviors:
- **Management UI**: create / edit / delete snippets with a name (optional) and a multi-line command body. A snippet with a blank name displays its first command line; a fully blank command cannot be saved.
- **Run into a terminal**: each row has a play menu that lists every open terminal tab, split into **"Execute in"** (paste + press a real Enter to run) and **"Paste to"** (paste only, no run). Selecting a target switches the UI to show that terminal.
- **Copy**: copy the raw command to the clipboard.
- **Pinned** flag (added later — commit `fb2b38d52`) so favored snippets can be surfaced (currently sorting is alphabetical by display name; the flag is persisted and intended to float pinned entries to the top).
- **Shell History panel** (commit `fd391e765`): a trailing panel that reads the user's real shell history (`zsh`/`bash`/`fish`) and lets any past command be saved as a snippet in one click.
- **Search/filter** over name + command.
- Snippets participate in the Vault **sync** subsystem (ingest/replaceAll) and are **encrypted at rest**.

macOS source: `macos/Sources/Features/HostManager/Snippets.swift` (model + store), `macos/Sources/Features/HostManager/SnippetsSectionView.swift` (UI), `macos/Sources/Features/HostManager/ShellHistory.swift` (history reader + panel). Terminal insertion lives in `macos/Sources/Features/HostManager/VaultsTabsModel.swift` (`sendSnippet`). Encryption in `macos/Sources/Security/LocalDataCrypto.swift`. Paths in `macos/Sources/Helpers/AppPaths.swift`.

### Key logic & data model

**Persisted schema.** The store is a JSON array of `Snippet` objects. Field names/shapes a port MUST match (the macOS decoder tolerates missing fields via defaults, so a port should emit all of them):

```jsonc
// Snippet (element of the array)
{
  "id":        "UUID string",          // stable identity; generated if absent
  "name":      "string",               // may be empty -> display falls back to first command line
  "command":   "string",               // the command body; may contain newlines
  "pinned":    false,                   // bool, default false
  "createdAt": "ISO-8601 date string",
  "updatedAt": "ISO-8601 date string"  // bumped on every upsert; drives sync conflict resolution
}
```

- **Dates** are encoded/decoded ISO-8601 (`JSONEncoder.dateEncodingStrategy = .iso8601`). Match exactly for sync interop.
- **On disk** the array is NOT stored as this plaintext JSON. It is wrapped in an encrypted envelope (see below):

```jsonc
// snippets.json actual on-disk contents
{ "sarvEnc": 1, "blob": "<base64 AES-256-GCM ciphertext of the JSON array>" }
```

**Storage location.** `~/.config/sarvterminal/snippets.json` (release) or `~/.config/sarvterminal-dev/snippets.json` (debug). Honors `XDG_CONFIG_HOME`. A Linux port should use `$XDG_CONFIG_HOME/sarvterminal/snippets.json` falling back to `~/.config/sarvterminal/snippets.json`.

**`SnippetsStore`** (singleton `ObservableObject`) — the persisted library. CRUD + sync semantics a port must reproduce:
- `upsert`: sets `updatedAt = now`, replaces by matching `id` else appends, re-sorts, persists.
- `delete`: removes by `id`, persists.
- `sortInPlace`: alphabetical, case-insensitive, by `displayName`.
- `ingest(incoming)` (sync merge): per `id`, incoming wins **iff** `incoming.updatedAt >= local.updatedAt`; never deletes local-only entries.
- `replaceAll(incoming)` (authoritative sync mirror): replaces the whole set, so deletes propagate.
- `loadFailed` flag: set true when the file exists but can't be decrypted/decoded. The resulting empty array is then **NOT authoritative** — sync must not push it. A port MUST preserve this distinction (missing file vs. unreadable file) or it will wipe synced data when the key is unavailable.

**Read result contract** (`EncryptedStore.read`): `.none` (no file), `.loaded`, `.failed` (exists but unreadable — treat as `loadFailed`, never empty), `.migrated` (legacy plaintext successfully read; store re-persists encrypted and backs up the original to `snippets.pre-encryption.bak`). A port needs the same four-way outcome.

**Terminal insertion** (`VaultsTabsModel.sendSnippet`, the load-bearing bit):
- Locates the target terminal tab, then its last leaf surface.
- Calls `sendText(command)` — this is a **bracketed paste**, which by design does NOT auto-run even if the text ends in a newline (a shell safety feature).
- If `execute` is requested: strips trailing `\n`/`\r`, pastes, then sends a **real Enter key event** (`key: .enter, action: .press`) which the shell treats as a genuine submit and runs the command.
- On success it selects/reveals the terminal so output is visible.
- A Linux port must replicate the two-step "bracketed paste, then synthesize a real Enter" pattern — pasting a trailing newline alone will not execute.

**Shell History** (`ShellHistory.recent`): reads `$HISTFILE` if set, else the first existing of `~/.zsh_history`, `~/.bash_history`, `~/.local/share/fish/fish_history`. Parses per-shell formats: strips zsh extended-history prefixes (`: <ts>:<dur>;<cmd>`), unwraps fish YAML (`- cmd: <cmd>`, skipping `when:` lines), trims, then returns newest-first, de-duplicated (most-recent occurrence kept), capped at 400. This logic is already POSIX/Linux-friendly and ports almost verbatim.

**Display fallback**: `displayName` = trimmed `name`, else first non-empty command line, else `"Untitled snippet"`. `isEmpty` = command is blank after trimming whitespace/newlines (gates the Save button).

### macOS → Linux/GTK equivalents

| macOS / Apple piece | Used for | Linux / GTK4 / Zig equivalent |
|---|---|---|
| SwiftUI (`SnippetsSectionView`, editor sheet, rows) | Management UI | GTK4 widgets: a list/`ListView` of rows, `GtkPopoverMenu` for the run menu, a modal `GtkWindow`/dialog with `GtkEntry` (name) + `GtkTextView` (command) for the editor. Follow the existing GTK Vaults section layout. |
| `NSPasteboard` | Copy command | GDK clipboard (`gdk_clipboard_set_text` / `gtk_widget_get_clipboard`). |
| `Codable` + `JSONEncoder/Decoder` (ISO-8601) | Serialization | Zig `std.json` (or the app's existing JSON layer). Emit ISO-8601 dates and the exact field names above for sync compatibility. |
| `UUID` | Snippet id | Any RFC-4122 UUID generator; keep string form. |
| `DispatchQueue` (async persist) | Off-main-thread writes | Zig thread / GLib worker; or simply atomic write. |
| Foundation file APIs + `AppPaths.configDir` | Path resolution | `$XDG_CONFIG_HOME` (fallback `~/.config`) + `sarvterminal[-dev]`. |
| `CryptoKit` `AES.GCM` (`LocalDataCrypto`/`EncryptedStore`) | At-rest encryption of `snippets.json` | AES-256-GCM via the core's crypto (Zig std.crypto / the same lib the shared core uses). Envelope shape `{ "sarvEnc": 1, "blob": <base64> }` must match. |
| **Secure Enclave** (P256 non-exportable key wrapping the AES data key via ECIES) | Hardware-bound key protection | **No clean Linux equivalent.** There is no Secure Enclave. Fallback path: use the macOS "no Enclave" branch as the model — a random 256-bit data key stored in the OS secret store. On Linux that means **Secret Service / libsecret (GNOME Keyring / KWallet)** via D-Bus. If no keyring is available (headless), fall back to a key file at `0600` under the config dir (mirrors the DEBUG keystore-file fallback already in `LocalDataCrypto`). Document clearly that Linux at-rest protection is keyring- or file-based, not hardware-bound. |
| Keychain (`kSecClassGenericPassword`, device-only) | Key material storage | **Secret Service / libsecret** collection item, or the `0600` key file fallback. Service/account naming can mirror `com.sarv.terminal.localdata` / `data-key-raw`. |
| Ghostty `SurfaceView` / `sendText` / `sendKeyEvent` | Insert + execute in terminal | GTK apprt already has surface objects and a text/paste path plus key-event injection into the PTY. Reuse them: bracketed-paste the text, then inject a synthetic Enter key press for execute. This is the one integration point that must hook the existing GTK terminal surface. |
| `SearchMatcher.filter` | Snippet search | Reuse whatever shared search helper the GTK Vaults port already uses; matches over `[displayName, command]`. |

**Sync note:** the ingest/replaceAll/`loadFailed` semantics are shared with the hosts store and the broader Vault sync module — the Linux Snippets store must expose the same three operations and the "unreadable file is not empty" guarantee so it plugs into the ported sync layer identically.

### How to verify on Linux

1. **Create/persist**: add a snippet with a name and a multi-line command, restart the app, confirm it reloads. Inspect `~/.config/sarvterminal/snippets.json` — it must be the encrypted envelope `{"sarvEnc":1,"blob":"..."}`, NOT plaintext.
2. **Schema round-trip**: decrypt the blob (or cross-load a file written by the macOS app) and confirm the fields `id, name, command, pinned, createdAt, updatedAt` with ISO-8601 dates. A snippet created on macOS should load on Linux and vice versa.
3. **Execute**: with a terminal open, choose "Execute in" for a snippet like `echo hi` — the command must actually run (prompt returns with `hi`), not just sit at the prompt awaiting Enter. Test a command with a trailing newline to confirm trailing newlines are stripped before the synthetic Enter.
4. **Paste**: "Paste to" must insert the text WITHOUT running it (cursor left on an unsubmitted line).
5. **Copy**: copy places the exact command on the clipboard (`xclip -o` / `wl-paste`).
6. **Display fallback**: a snippet with an empty name shows its first command line; a fully blank command cannot be saved.
7. **Shell history**: with `~/.zsh_history` (or bash/fish, or `$HISTFILE`) populated, the history panel lists recent commands newest-first and de-duplicated; "Save" turns one into a snippet.
8. **loadFailed safety**: simulate a missing/rotated key so the file can't be decrypted — the app must show an empty/error state but must **not** overwrite the file with an empty array or push an empty set to sync.
9. **Sync**: `ingest` keeps the newer `updatedAt` and never drops local-only snippets; `replaceAll` mirrors deletions.

## 14. Port forwarding

### What it is

Stock Ghostty has no notion of saved SSH tunnels. Sarv adds a **Port Forwarding** area under Vaults where the user saves named SSH port-forward rules and starts/stops each one with a single Start/Stop button. Three tunnel kinds are supported, mapping 1:1 to OpenSSH flags:

- **Local (`-L`)** — listen on a local address, forward through the server to a destination (e.g. reach a remote DB at `127.0.0.1:5432`).
- **Remote (`-R`)** — listen on the server, forward back to a destination reachable from this machine.
- **Dynamic / SOCKS (`-D`)** — a local SOCKS5 proxy.

Each rule tunnels **through one of the user's saved hosts** (from the Hosts vault) — it reuses that host's hostname, port, username, identity file, agent-forwarding and password. A tunnel is a long-lived `ssh -N` process; the manager tracks per-rule running state and surfaces errors/notifications when a tunnel fails to bind or drops unexpectedly. Rules persist across launches; the running processes do not (they must be re-started, or started manually).

Source files (all macOS-only, must be rebuilt for GTK):
- `macos/Sources/Features/HostManager/PortForwarding.swift` — model + `PortForwardStore` (persistence).
- `macos/Sources/Features/HostManager/PortForwardManager.swift` — process lifecycle.
- `macos/Sources/Features/HostManager/PortForwardingSectionView.swift` — SwiftUI list + editor sheet.

### Key logic & data model

**Persisted schema.** Rules are stored as a JSON array of `PortForward` at `~/.config/sarvterminal/portforwards.json` (release) / `~/.config/sarvterminal-dev/` (debug) — **encrypted at rest** (see the crypto note below). Each element:

| Field | Type | Notes |
|---|---|---|
| `id` | UUID string | rule identity (also sync key) |
| `name` | string | user label; empty → shown as "Untitled tunnel" |
| `kind` | string enum | `"local"` \| `"remote"` \| `"dynamic"` |
| `hostID` | UUID string | FK into the Hosts vault — the host tunneled through |
| `bindAddress` | string | listen address, default `"127.0.0.1"` |
| `listenPort` | int | port opened on the bind side, default `8080` |
| `destinationHost` | string | target as seen from the far end; unused for `dynamic`, default `"localhost"` |
| `destinationPort` | int | target port; unused for `dynamic`, default `80` |
| `createdAt` | ISO-8601 date | |
| `updatedAt` | ISO-8601 date | drives sync merge |

Dates use `.iso8601` en/decoding. The decoder is **tolerant**: every field is `decodeIfPresent` with a default, so partial/older JSON still loads (a port must replicate this defaulting so it never hard-fails on missing keys).

**Store (`PortForwardStore`, singleton).** CRUD is `upsert` (stamps `updatedAt`, replaces by `id` or appends) and `delete` (removes by `id`); the list is kept sorted case-insensitively by display name. Two sync helpers exist for the Vault sync layer: `ingest` (last-writer-wins per `id` by `updatedAt`) and `replaceAll`. Writes are serialized onto a background queue. `loadFailed` is set (and the list left empty but NOT overwritten) when the encrypted file exists but can't be decrypted — a port must preserve this "never treat unreadable as empty" invariant so it doesn't silently wipe data.

**Manager (`PortForwardManager`, singleton, `@MainActor`).** Holds `running: Set<UUID>` and `errors: [UUID: String]` published to the UI, plus a private `tunnels: [UUID: Tunnel]` map. Key behaviors:
- `start(forward)`: no-op if already running; resolves the `SavedHost` by `hostID` (errors if the host was deleted); launches `/usr/bin/ssh` with `stdin=/dev/null`, `stdout=/dev/null`, stderr captured to a pipe.
- The **ssh argument vector** is built directly from host fields (NOT from the host's normal `sshCommand`, so the host's own forwards/initial-command don't leak in):
  ```
  ssh -N
      -o ExitOnForwardFailure=yes
      -o StrictHostKeyChecking=accept-new
      -o NumberOfPasswordPrompts=1
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3
      [-p <host.port> if != 22]
      [-i <expanded identityFile> -o IdentitiesOnly=yes  if set]
      [-A if host.forwardAgent]
      (-L|-R) <bindAddress>:<listenPort>:<destinationHost>:<destinationPort>   # local/remote
      (-D) <bindAddress>:<listenPort>                                          # dynamic
      [user@]hostname
  ```
- **Password auth** (host `authMethod == .password || .ask` with a non-empty password): rather than a TTY prompt, it injects `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` + a `SARV_ASKPASS_FILE` env pointing at a `0600` temp file holding the password; a tiny helper script `cat`s that file. The temp file is cleaned up when the tunnel exits. (See `SSH/SSHAskpass.swift`.)
- `stop(id)`: marks `manualStop`, sends `SIGTERM`; the process `terminationHandler` does the bookkeeping.
- `tunnelDidExit`: removes from `running`, cleans up the askpass temp file. A non-zero exit that was **not** a manual stop is recorded as an error and fires a notification (`.tunnelDropped` if stderr empty, else `.tunnelFailed` with the stderr text). `toggle` and `stopAll` are conveniences.

### macOS → Linux/GTK equivalents

| macOS piece | Used for | Linux/GTK equivalent |
|---|---|---|
| Foundation `Process` + `terminationHandler` | spawn/track `ssh -N`, async exit callback | GLib `GSubprocess` / `g_spawn_async` with a child-watch, or Zig `std.process.Child`; keep exit handling on the GTK main loop (GLib main context) since UI state is updated on exit |
| `Pipe` / `FileHandle` (stderr capture, `/dev/null` for stdin/stdout) | capture ssh error output; suppress prompts | `GSubprocess` stderr pipe; redirect stdin/stdout to `/dev/null` |
| `SwiftUI` list + `.sheet` editor + `@Published`/`ObservableObject` | the whole UI + reactive running/error state | GTK4 (`GtkListView`/`GtkListBox`, `GtkDialog`/`AdwDialog` for the editor); drive UI from a signal/observer over the store + manager state |
| `SSH_ASKPASS` password injection | non-interactive password auth | **Identical** — `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE=force`/temp file work the same on Linux OpenSSH (8.4+). Reuse the exact scheme; set the temp file `0600`. Note: on Linux, `SSH_ASKPASS_REQUIRE=force` is honored regardless of TTY presence. |
| `JSONEncoder/Decoder` (`.iso8601`) | persistence format | Any JSON lib; keep exact field names/shapes and ISO-8601 dates for cross-platform sync compatibility |
| `AppPaths.configDir` (`~/.config/sarvterminal[-dev]`) | file location | Same XDG path — already how the config dir is derived; honor `XDG_CONFIG_HOME` |
| **`EncryptedStore` + `LocalDataCrypto`** (AES-256-GCM data key wrapped by a **Secure Enclave** P256 key, Keychain fallback) | encryption at rest | **No clean Linux equivalent.** There is no Secure Enclave and no Keychain. This is the port's main crypto decision — see below. |
| `SavedHostsStore` / `SavedHost` fields (`hostname`, `port`, `username`, `identityFile`, `forwardAgent`, `authMethod`, `password`, `displayLabel`) | source of connection params | Must be ported first — port forwarding depends on the Hosts vault |
| `SarvNotifications` (`.tunnelFailed`, `.tunnelDropped`) | drop/failure alerts | GTK notifications (`GNotification` / `libnotify`) via the ported notifications subsystem |
| `NSHomeDirectory()` tilde expansion for identity file | key path | `getenv("HOME")` / `std.posix.getenv` |

**Encryption-at-rest fallback (critical).** The on-disk envelope is `{"sarvEnc":1,"blob":"<base64 AES-256-GCM>"}`, with a one-time migration path that reads a legacy plaintext file, backs it up as `portforwards.pre-encryption.bak`, then re-writes encrypted. To match this on Linux you need a data-key store. Options, roughly in order of preference: (1) the **Secret Service API** (`libsecret`, backed by GNOME Keyring / KWallet) to hold the AES key — closest analogue to Keychain; (2) TPM-sealed key where available; (3) a `0600` key file under the config dir as a last-resort fallback (matches the existing `readKeyFile`/`writeKeyFile` fallback already present in `LocalDataCrypto`). Whatever is chosen, keep the same envelope format and the "unreadable != empty" guarantee. Note the port-forward passwords themselves live in the Hosts vault, not here — but rules still contain internal hostnames worth protecting.

### How to verify on Linux

1. **Persistence round-trip.** Create a Local (`-L`) rule through a saved host, restart the app, confirm it reloads with the same fields. Inspect `~/.config/sarvterminal/portforwards.json` and confirm it's the `{"sarvEnc":1,"blob":...}` envelope (not plaintext).
2. **Local forward works.** Start a `-L` rule to a reachable service; from another terminal:
   ```
   ssh -V           # confirm OpenSSH >= 8.4 for askpass-force
   nc -vz 127.0.0.1 <listenPort>
   ```
   Then hit the service through the local port. Stop the rule and confirm the port stops listening (`ss -ltnp | grep <listenPort>`).
3. **Dynamic/SOCKS.** Start a `-D` rule; verify with `curl --socks5 127.0.0.1:<listenPort> https://example.com`.
4. **Remote forward.** Start a `-R` rule; on the server confirm the listen port is open and reaches the destination on this machine.
5. **Password auth path.** Use a password-auth host; confirm the tunnel comes up with no TTY prompt, and that the `SARV_ASKPASS_FILE` temp file (0600) is deleted after the tunnel exits (`ls` the temp dir before/after stop).
6. **Failure surfaces.** Start two rules bound to the same `listenPort`; the second must fail fast (ExitOnForwardFailure), show the stderr in the row, and fire a `tunnelFailed` notification. Kill a running `ssh` externally and confirm a `tunnelDropped` notification + error state (and that a manual Stop produces neither).
7. **Missing host.** Delete the host a rule points to, then Start it — expect the "host no longer exists" error, not a crash.
8. **Argument fidelity.** Run with `ssh` traced (or a wrapper) and confirm the exact flag set above, including `-p` only when port != 22, `-i ... -o IdentitiesOnly=yes` only when an identity file is set, and `-A` only when agent forwarding is on.

## 15. Files / SFTP browser

### What it is
A dual-pane graphical file manager (Finder/Termius-style) built into the Vaults dashboard. Each pane independently points at either **Local** (this machine) or any **saved host**, and the "Copy to target directory" action transfers the selection into the *other* pane's current folder. It supports the full matrix of transfers — local⇄local, local⇄remote, and **server⇄server** — plus directory listing with sort/filter/breadcrumb navigation, new-folder/rename/delete, a two-way POSIX permissions editor, and an in-app syntax-highlighted file viewer/editor. This replaced the fork's earlier separate "SFTP" and "SCP" tabs (commit `067499883`).

Stock Ghostty has no file browser at all; this is entirely Sarv-added. The design deliberately **shells out to the system `ssh`/`sftp`/`scp` CLIs** rather than linking a libssh — it reuses the same auth path (identity file, agent, or password-via-askpass) already used elsewhere in the app, and works against both GNU coreutils and BusyBox/Alpine hosts.

Key files (all under `macos/Sources/Features/HostManager/Files/`):
- `FileBackend.swift` — the `FileBackend` protocol + `LocalFileBackend` + `RemoteFileBackend` (the core; includes the process runner + cancellation model + `ls` parser).
- `FileItem.swift` — the row model + `FileLocation` enum.
- `FileTransfer.swift` — transfer engine (sftp put/get, direct server-to-server, relay).
- `SFTPBrowserModel.swift` — per-pane view-model (listing, history, sort/filter).
- `SFTPView.swift` — the coordinator: two panes, transfer orchestration, progress overlay + cancel, conflict dialog.
- `FilePaneView.swift` — one pane's UI (toolbar, breadcrumb, sortable columns, context menu, host chooser, conflict dialog).
- `SFTPSettings.swift` — persisted preferences.
- `PermissionsSheet.swift` — octal ⇄ rwx checkbox editor.
- `FileViewerView.swift` / `FileViewerModel` / `FileEditorWindowController.swift` / `MarkdownHTML.swift` — the read/edit viewer (native `NSTextView` `CodeSyntax` highlighter for code; WebKit renders only md4c-generated Markdown).
- `../SSH/SSHAskpass.swift` — non-interactive password feeding (shared with the rest of the app).

### Key logic & data model

**Backend abstraction.** `FileBackend` is a protocol with POSIX-path (`/`-separated) semantics for both local and remote. Two implementations:
- `LocalFileBackend` — `FileManager` + `URLResourceValues`. Note the deliberate use of `contentsOfDirectory(includingPropertiesForKeys:)` with `.fileSecurityKey` rather than `attributesOfItem` — the latter *opens* each item and tripped macOS Desktop/Documents/Downloads privacy prompts. POSIX mode is read via `CFFileSecurityGetMode` and rendered to `"rwxr-xr-x"` by `LocalFileBackend.symbolic(from:)`.
- `RemoteFileBackend` — every operation is a shelled-out `ssh <host> <cmd>`. Commands are intentionally portable (GNU + BusyBox): `ls -la` (no `--time-style`), `wc -c < file` for size, `mkdir`/`mv`/`rm -rf|-f`/`chmod`/`test -e`. All remote path args go through `sftpQuote()` (single-quote shell escaping). Listing is parsed by `RemoteFileBackend.parseLS()` — column split on whitespace, `perms links owner group size MON DAY TIME|YEAR name…`, name is field 9+ joined (keeps spaces), symlink `name -> target` is trimmed to `name`, `.`/`..` dropped. Dates parsed best-effort by `parseDate` (current-year `HH:mm` vs `MMM d yyyy`).

**Process holder / cancellation model (port this carefully).** `RemoteFileBackend.runProcess` is the single choke point for every external command. It runs the `Process` on a background GCD queue wrapped in `withTaskCancellationHandler { withCheckedThrowingContinuation … }`. A thread-safe `ProcessBox` (an `NSLock`-guarded holder) is `attach`-ed the live `Process`; on Swift-`Task` cancellation the handler calls `box.cancel()`, which `terminate()`s the process (and also terminates if cancel arrives before `attach`, via a `cancelled` flag). This is how the transfer "Cancel" button works — cancelling the tracked `Task` kills the underlying CLI. A cancel produces a non-zero exit that callers explicitly treat as "not an error" (checked via `Task.isCancelled`), so it neither surfaces an error nor fires a notification.

**Transfer engine (`FileTransfer`).** Dispatches on the `(source, dest)` backend pair:
- local→local: `FileManager.copyItem`.
- local⇄remote: writes a one-line `sftp` **batch file** (`put`/`get`, `-r` for dirs), runs `/usr/bin/sftp -b batch`.
- server→server **direct** (`directServerToServer`): runs `scp` *on the source host* so bytes flow A→B without touching this machine. Key/agent destinations authenticate via forwarded agent (`ssh -A` + `scp -o BatchMode=yes`); password destinations get the saved password through a **one-shot `SSH_ASKPASS` helper written on host A** (password passed base64-encoded in an env var, helper `mktemp`'d, `chmod 700`, deleted after). 
- server→server **relay** (`relayViaLocal`): download to a local temp with the source's credentials, then upload with the destination's — this is the fallback used when the two servers can't reach each other, and unlike `scp -3` it works when the two hosts have *different* credentials.

`SFTPView.performCopy` **always tries direct first, silently falls back to relay** on failure; a relay failure is surfaced to the pane, a direct failure is not (it just relays). Conflict handling (`ConflictResolution`: stop/skip/replace/duplicate/merge) is resolved before transfer by `prepareDestination` (deletes existing target for replace/merge; `finalName` appends `(copy)` for duplicate).

**Progress model.** There is no byte-level callback from the CLIs. `withProgress` seeds `TransferState { fileName, total, transferred, bytesPerSecond, direct }` from the *source* size, then runs a **poller** (`Task` on a 800 ms loop) that calls `destBackend.fileSize(destPath)` and computes throughput = size / elapsed. Directories report `total = 0` (indeterminate spinner). State lives on the `SFTPSession.shared` singleton (`transfer` + `transferTask`) so the overlay survives the dashboard being torn down when a terminal tab is shown.

**Per-pane state (`SFTPBrowserModel`).** In-memory only: `location`, `path`, `items`, `history` + `historyIndex` (back/forward, with forward-history truncation on new navigation), `sortColumn`/`sortAscending`, in-pane `search`. `displayItems` = hidden-file filter (from settings) → `SearchMatcher.filter` → sort with directories always grouped first. `SFTPSession.shared` holds the two panes (`left`/`right`) and connects both to Local exactly once via `startIfNeeded()`.

**PERSISTED schema.** The browser's live state is *not* persisted (session-only, in memory). The only persisted data is **`SFTPSettings`, stored in `UserDefaults`** (4 keys, note the non-obvious defaults — a port must match key names and defaults exactly so cross-device sync stays compatible):

| UserDefaults key | Type | Default | Meaning |
|---|---|---|---|
| `SarvSFTPAutoSave` | Bool | `false` | viewer auto-saves edits (debounced) vs manual ⌘S |
| `SarvSFTPConfirmDelete` | Bool | `true` | confirm before delete |
| `SarvSFTPShowHidden` | Bool | `true` | show dot-files |
| `SarvSFTPIndentWidth` | Int | `4` | default soft-tab width in the viewer |

These keys are also written directly by the cloud-sync "pull" path (bypassing the singleton), so `SFTPSettings` re-reads them on the `.sarvSyncDidPull` notification. `FileItem` is the row shape a listing must produce: `{ name, path (absolute POSIX), isDirectory, isSymlink, size: Int64, modified: Date?, permissions: String? ("rwxr-xr-x", no leading type char) }`.

The `SavedHost` fields the remote backend depends on (owned by another section): `username`, `hostname`, `port`, `identityFile`, `password`, `authMethod` (`.publicKey`/`.agent`/password), `connectTimeoutSeconds`.

### macOS → Linux/GTK equivalents

| macOS / Foundation / AppKit piece | Used for | Linux / GTK4 / Zig equivalent |
|---|---|---|
| `Process` + `Pipe` + `waitUntilExit` | run `ssh`/`sftp`/`scp` | Zig `std.process.Child` (with `stdout`/`stderr` pipes) or GLib `GSubprocess`. Keep the same "collect stdout+stderr, wait, return {status, out, err}" shape. |
| `ProcessBox` (NSLock holder) + `withTaskCancellationHandler` + `withCheckedThrowingContinuation` | cancellable process | A mutex-guarded holder of the child's PID/handle; on cancel call `child.kill()` / `kill(pid, SIGTERM)`. Zig has no Swift structured-concurrency cancellation — model cancel with an atomic flag + storing the `Child` so the UI's Cancel button can signal it. This is the single most important thing to re-implement correctly. |
| `/usr/bin/ssh`, `/usr/bin/sftp` (hard-coded paths) | transfers | Do **not** hard-code `/usr/bin`; resolve `ssh`/`sftp`/`scp` from `PATH` (Linux distros vary). |
| `SSHAskpass` (`SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`, helper script in App Support) | non-interactive password auth | Works identically on Linux with OpenSSH ≥ 8.4 — but on a headless/no-DISPLAY session OpenSSH may still refuse; `SSH_ASKPASS_REQUIRE=force` is the correct flag and is honored on Linux. Put the helper + per-connection password file under `$XDG_RUNTIME_DIR` (or `$XDG_DATA_HOME`) with `0700`/`0600`. The base64-in-env one-shot askpass written on the *remote* host in `directServerToServer` is pure POSIX `sh` and ports verbatim. |
| `FileManager` (`contentsOfDirectory`, `copyItem`, `moveItem`, `removeItem`, `createDirectory`, `setAttributes(.posixPermissions)`) | local FS ops | Zig `std.fs` (`Dir.iterate`, `copyFile`, `rename`, `deleteTree`, `makeDir`, `chmod`) or GLib GIO. |
| `URLResourceValues` + `CFFileSecurityGetMode` | local mode/size/mtime without opening files | `lstat(2)` / `statx`. Read `st_mode & 0o777` directly. Reproduce `symbolic(from:)` yourself. Preserve the "don't open the file" property — on Linux there's no privacy-prompt issue, but `stat` is still the right, cheap call. |
| `UserDefaults` (`SarvSFTP*` keys) | settings persistence | GTK app's existing config store (GSettings, or the keyfile the Vaults layer already uses). Preserve the 4 key names/defaults and the "re-read on sync-pull" behavior. Not encrypted — plain preferences. |
| Keychain / Secure Enclave | **not used directly here** | The host password arrives already decrypted via `SavedHost.password` (decryption is the encrypted-host-store section's concern). No new Keychain/Enclave surface in this subsystem — no Linux fallback needed here beyond whatever that section provides. |
| `ByteCountFormatter` | size/throughput labels | `g_format_size()` (GLib) or a small helper. |
| `DateFormatter` (`en_US_POSIX`) for `ls` date parsing | remote mtime | GLib `GDateTime` or manual parse; keep the two-format (current-year `HH:mm` vs `MMM d yyyy`) logic. |
| SwiftUI dual-pane (`HStack` + `Divider`), sortable columns, breadcrumb, context menus, sheets/overlays | the UI | `Gtk.Paned` (two panes); `Gtk.ColumnView` (sortable columns) or a custom list; a breadcrumb bar of buttons; `GtkPopoverMenu` for the right-click context menu; `Gtk.Window`/`AdwDialog` for the host chooser, permissions editor, conflict prompt, and transfer-progress overlay (`Gtk.ProgressView`). |
| `WebKit` `WKWebView` (Markdown render only, in `FileViewerView`) + native `NSTextView` `CodeSyntax` highlighter | rendered-Markdown web view + syntax-highlighted code viewer/editor | WebKitGTK (`WebKit.WebView`). The viewer is secondary; the browser/transfer core matters more. Markdown rendering already goes through this repo's Zig path (`pkg/md4c`, per project memory). |
| `SearchMatcher.filter` (shared Sarv helper) | in-pane filter | Reuse/port the shared matcher the Vaults layer uses; don't hand-roll. |

No component here has *no* Linux equivalent — everything reduces to spawning `ssh`/`sftp`/`scp` and local `stat`/FS calls, all of which are first-class on Linux. The two porting risks are (1) faithfully reproducing the process-holder cancellation without Swift structured concurrency, and (2) `SSH_ASKPASS` behavior under a possibly-headless GTK session.

### How to verify on Linux
- **Local listing:** open both panes on Local, navigate into a folder; confirm names, sizes, mtimes, and `rwxr-xr-x` permission strings match `ls -la`, dot-files respect the `SarvSFTPShowHidden` setting, and directories sort first under every column sort.
- **Remote listing against BusyBox:** connect a pane to an Alpine/BusyBox host and to a GNU-coreutils host; confirm `parseLS` handles both (names with spaces intact, symlink `a -> b` shows `a`, `.`/`..` hidden).
- **Auth paths:** verify listing/transfer works for a key host, an agent host, and a **password** host (the `SSH_ASKPASS` helper must feed the password with no TTY prompt). Test on a headless run (no `DISPLAY`) to confirm `SSH_ASKPASS_REQUIRE=force` still works.
- **Transfers:** local→remote and remote→local via sftp; **server→server direct** (key dest → should not touch the local machine; verify with `tcpdump`/bandwidth that bytes go A→B) and **server→server relay** fallback (two password hosts with different passwords, or hosts that can't reach each other → progress overlay shows "Via this Mac"/relay label).
- **Progress + cancel:** start a large-file transfer; confirm the progress overlay updates (poller reads dest size every ~0.8 s and shows throughput) and that **Cancel terminates the underlying `ssh`/`sftp` process** (check `ps` — no orphaned process) and surfaces no error/notification.
- **Mutating ops:** New Folder, Rename, Delete (with/without the `SarvSFTPConfirmDelete` prompt), and the octal⇄rwx Permissions editor applying `chmod` correctly, each against both a local and a remote pane, with the pane auto-reloading after.
- **Conflict handling:** copy a file whose name already exists in the target pane and exercise stop/skip/replace/duplicate/merge.
- **Settings persistence + sync:** toggle each `SarvSFTP*` setting, restart the app, confirm it persisted; simulate a sync-pull and confirm settings update live without restart.

## 16. Local data encryption at rest

### What it is

Stock Ghostty stores nothing like this — it has no concept of saved SSH hosts, snippets, or port-forwards. SarvTerminal adds a Vaults layer that persists that user data as JSON under `~/.config/sarvterminal/` (release) or `~/.config/sarvterminal-dev/` (debug). Because those files hold connection details and **plaintext SSH passwords** (`SavedHost.password` is stored in the clear inside the JSON payload), Sarv encrypts every one of these files **at rest**.

From the user's view there is no visible feature and no passphrase prompt: the app silently encrypts on write and decrypts on read, keyed to hardware that never leaves the machine. The security properties Sarv is buying:

- A copied `.json` file is opaque ciphertext — useless on another machine or to anyone with the file but not the running app.
- On a Mac with a Secure Enclave, the key **cannot be extracted even with full disk access** — it is hardware-bound and non-exportable.
- Existing plaintext files from older builds are migrated transparently, with the original backed up first (never silently destroyed).

A hard design rule (see below) is that the key is a **random 256-bit key**, never derived from MAC address, hostname, or any machine/user identifier. A Linux port MUST preserve that rule.

Key source file: `macos/Sources/Security/LocalDataCrypto.swift` (contains both `LocalDataCrypto` — the key/seal/open layer — and `EncryptedStore` — the file envelope + migration layer).

### Key logic & data model

**Two-layer key architecture (envelope encryption):**

1. A random 256-bit **data key** (`SymmetricKey(size: .bits256)`) encrypts each file with **AES-256-GCM** (`AES.GCM.seal` / `.open`, using the `.combined` representation = nonce ‖ ciphertext ‖ tag).
2. The data key is itself **wrapped** so it can be persisted safely:
   - **Secure Enclave path** (`SecureEnclave.isAvailable == true`): a non-exportable P-256 `KeyAgreement` private key lives in the Enclave. The data key is wrapped to it with **ECIES**: generate an ephemeral P-256 keypair, ECDH with the Enclave public key, run **HKDF-SHA256** (salt `"sarvterminal-local-at-rest-salt-v1"`, info `"sarvterminal-local-at-rest-v1"`, 32-byte output) to derive a wrap key, then AES-GCM-seal the raw data-key bytes under it. Stored blob = `ephemeralPublicKey.rawRepresentation (64 bytes)` ‖ `AES-GCM combined`. Unwrap reverses this using the Enclave key's `sharedSecretFromKeyAgreement`.
   - **Fallback path** (no Secure Enclave): the random data key is stored **raw** in the device-only Keychain. No hardware binding, but still device-scoped and not derived from any identifier.
3. The unwrapped data key is cached in-process behind an `NSLock` for the app's lifetime.

**Where key material lives (three logical items, `service = com.sarv.terminal.localdata[.debug]`):**

| account key | contents |
|---|---|
| `se-key` | Enclave P-256 private key `dataRepresentation` (an opaque, Enclave-bound handle — not usable off-device) |
| `data-key-wrapped` | the ECIES-wrapped data key blob |
| `data-key-raw` | the raw data key (fallback path only) |

- **Release builds:** items live in the macOS **Keychain** as `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-only, never synced to iCloud, available after first unlock). The stably code-signed release app's ACL matches on every launch, so macOS never prompts.
- **Debug builds:** the ad-hoc dev signature changes on every rebuild, so the Keychain ACL never matches and macOS would re-prompt for the login password each launch. Debug therefore stores the same (still Enclave-wrapped) blobs as **files** under `<configDir>/keystore/` — dir `0700`, files `0600` — with a one-time migration out of the legacy Keychain on first run.

**On-disk file envelope** (`SarvEncEnvelope`, written by `EncryptedStore.write`):

```json
{ "sarvEnc": 1, "blob": "<base64 of AES-GCM combined ciphertext>" }
```

`sarvEnc` is an integer version tag (reader accepts `>= 1`). `blob` is base64 of the AES-GCM `.combined` output whose plaintext is the store's normal JSON.

**Read path & migration** (`EncryptedStore.read` returns `.none | .loaded | .failed | .migrated`):

- If the file parses as a `SarvEncEnvelope` with `sarvEnc >= 1` → base64-decode `blob`, `LocalDataCrypto.open`, then JSON-decode. If decryption/decoding fails → `.failed` (key missing or changed). **Critical invariant: `.failed` is never treated as "empty".** Callers set a `loadFailed` flag and refuse to persist/sync over it, so an unreadable file can't be silently overwritten with an empty array (this is what stops a bad key from wiping the user's — and the remote sync backup's — data).
- Otherwise the file is treated as **legacy plaintext**: decode it directly, copy the original to `<name>.pre-encryption.bak` (only if that backup doesn't already exist), and return `.migrated`. The store then immediately re-persists encrypted.

**Files encrypted through this path** (all under `configDir`, each a store that calls `EncryptedStore.read/write`):

| file | payload type | source |
|---|---|---|
| `hosts.json` | `[SavedHost]` | `SavedHostsStore.swift` |
| `snippets.json` | `[Snippet]` | `Snippets.swift` |
| `portforwards.json` | `[PortForward]` | `PortForwarding.swift` |
| `saved-sessions.json` | `[SavedSession]` | `SavedSession.swift` |
| `pinned-history.json` | `[String]` | `PinnedHistoryStore.swift` |

Dates in these payloads use `JSONEncoder`/`Decoder` with `.iso8601`. The `SavedHost` schema itself (the largest payload; see §on Hosts) uses a default-tolerant manual `init(from:)` so new fields never break old files — a port should mirror that forward/backward tolerance.

**The MAC/machine-id rule.** `AppIdentity.swift` documents that Keychain service names and storage keys are **frozen literals**, deliberately NOT derived from the app name — deriving them from a renamable name would orphan every user's data on rename. The crypto layer follows the same principle: the data key is random, and its *protection* is bound to hardware (Enclave) or a device-scoped keystore, **not** derived from MAC address, `sarvId`, hostname, or serial. A Linux implementation must not "solve" the missing-Enclave problem by hashing a machine identifier into a key — that would be trivially reproducible off-device and defeats the whole design.

### macOS → Linux/GTK equivalents

| macOS piece used | What it does here | Linux / GTK4 / Zig equivalent |
|---|---|---|
| `CryptoKit AES.GCM` | AES-256-GCM file encryption (`.combined` = nonce‖ct‖tag) | Any vetted AEAD lib: libsodium (`crypto_aead_*`), OpenSSL EVP AES-256-GCM, or Zig `std.crypto.aead.aes_gcm.Aes256Gcm`. Keep the same combined layout so the envelope is portable. |
| `CryptoKit HKDF-SHA256` | derive the ECIES wrap key | libsodium `crypto_kdf`/HKDF, OpenSSL HKDF, or Zig `std.crypto.kdf.hkdf`. |
| `SecureEnclave.P256` (non-exportable, hardware-bound key) | wraps the data key so it can't be extracted even with disk access | **No clean Linux equivalent.** Options in order of strength: (1) **TPM 2.0** via `tpm2-tss` — seal the data key to a TPM-resident key (closest analog to the Enclave: hardware-bound, non-exportable); (2) **kernel keyring** (`keyctl`, `KEY_SPEC_USER_KEYRING`) — session/user-scoped, not persisted across reboot; (3) **Secret Service / libsecret** (GNOME Keyring / KWallet over D-Bus) — the natural analog of the Keychain, unlocked with the login session. Most GTK apps standardize on **libsecret** as the baseline. Whichever is chosen, the data key must stay **random**, not derived. |
| Keychain `kSecClassGenericPassword` + `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (release key storage) | device-only, non-synced, post-first-unlock secret store | **libsecret / Secret Service** (`secret_password_store`) with a `schema` acting as the `service`, and attributes acting as the `account`. There is no per-item "after first unlock, this-device-only" attribute — Secret Service items are unlocked with the login keyring; document that the security bar is "collection unlocked by login", not hardware. |
| File keystore (`<configDir>/keystore/`, dir `0700` / file `0600`) — debug fallback | store wrapped blobs as files when the ACL is unstable | Directly portable: plain files under `$XDG_CONFIG_HOME/sarvterminal/keystore/` with `0700`/`0600` POSIX perms. This is a reasonable Linux fallback when neither TPM nor Secret Service is available (e.g. headless), but note it only protects against other users, not against the file owner. |
| `SecureEnclave.isAvailable` branch | pick Enclave vs raw-Keychain path | Runtime capability probe: TPM present? Secret Service reachable on D-Bus? Fall through TPM → Secret Service → file keystore, recording which was used. |
| `Bundle.main.bundleIdentifier`, code-signing ACL | stable identity that makes the Keychain ACL match silently | N/A on Linux; Secret Service is scoped to the login session, not the binary signature. No re-prompt concern like the debug-signing one, so the debug/release storage split can collapse into one path on Linux (still keep release/debug **config-dir** isolation). |
| `Foundation` `JSONEncoder/Decoder` (`.iso8601`), `Codable` `SarvEncEnvelope` | the `{ "sarvEnc", "blob" }` envelope + `.pre-encryption.bak` migration | Any JSON library in the GTK app's language. The envelope shape and the plaintext-migration/backup behavior must be reproduced byte-for-compatible so files written by either platform interoperate if sync is ever cross-platform. |

Portability call-out: the **only** irreducible gap is hardware-bound non-exportable key protection. macOS gets Secure Enclave for free; Linux has no universally-present equivalent. Pick a documented fallback ladder (TPM → Secret Service → 0600 file), and — non-negotiable — never substitute a machine-id-derived key to paper over the gap.

### How to verify on Linux

1. **Ciphertext at rest.** Add a host/snippet/port-forward, then inspect the file:
   ```
   cat ~/.config/sarvterminal/hosts.json
   ```
   It must be the envelope `{"sarvEnc":1,"blob":"<base64>"}` — no readable hostname, username, or password. `grep` for a known hostname must return nothing.
2. **Round-trip.** Restart the app; the saved host/snippet/port-forward reappears intact (decrypt path works).
3. **Copied file is opaque / key is device-bound.** Copy `hosts.json` to another user account or machine (with a *different* key store) and point a build at it — it must fail to decrypt and surface as load-failed, **not** as an empty list.
4. **No-clobber on failure.** Simulate a missing/rotated key (delete or corrupt the keystore item), launch, add nothing, and confirm the app does **not** overwrite `hosts.json` with an empty payload — the existing ciphertext and any sync backup must survive.
5. **Legacy migration.** Drop a plaintext `hosts.json` (a bare JSON array) in place, launch, and confirm: it is read correctly, re-written as an encrypted envelope, and `hosts.pre-encryption.bak` now holds the original plaintext.
6. **Key is random, not derived.** Confirm two installs on machines with identical MAC/hostname produce **different** key material, and that no code path feeds MAC address, hostname, machine-id, or `sarvId` into key derivation (`grep` the crypto module for any such identifier).
7. **Permissions.** If the file-keystore fallback is used, verify the keystore dir is `0700` and each key file `0600`.
8. **Every store covered.** Repeat step 1 for `snippets.json`, `portforwards.json`, `saved-sessions.json`, and `pinned-history.json` — all must be encrypted, none left plaintext.

## 17. Command palette & host search

### What it is

SarvTerminal replaces stock Ghostty's "New Tab" / "New Window" behavior with a **host-search command palette** — a Termius-style centered overlay that opens on `⌘T`, `⌘N`, and the tab strip's `+` button. Instead of blindly spawning a local shell, it lets the user type to filter their connections and press Enter to open a session. It exists because SarvTerminal is connection-centric (a Vaults/SSH manager), so the primary "new tab" gesture should be "pick or type a host", not "open bash".

What the palette indexes (see `HostSearchModel.rows` in `HostSearchPalette.swift`):
- **Quick-connect action** — whatever the user typed, run as `ssh <query>` (or verbatim if it already starts with `ssh `). Only shown when the query is non-empty.
- **Local Terminal** — a plain local shell tab (`⌘L`), no command injection.
- **Serial** — opens the Vaults dashboard's serial-connect sheet (stub-ish; routes to dashboard).
- **Saved hosts** — the user's curated Vaults hosts from `SavedHostsStore.shared.hosts`.
- **`~/.ssh/config` hosts** — discovered via `SSHConfigDiscovery`, de-duplicated against saved hosts by lowercased label.

Important scope correction: **this palette does NOT index snippets or shell sessions/history.** Those live in a separate subsystem, `VaultsCommandSidebar.swift` (a right-hand sidebar with Snippets / Shell history / Themes tabs) — document/port that separately. There is also a *second, unrelated* palette: `Command Palette/CommandPalette.swift` + `TerminalCommandPalette.swift`. That one is **stock Ghostty** (terminal actions, "Focus: <surface>" jump list, update commands) and already exists on GTK — it is not Sarv-specific. Only `HostSearchPalette`/`HostSearchController` are the Sarv build target here.

### Key logic & data model

Key files:
- `macos/Sources/Features/HostManager/HostSearchPalette.swift` — SwiftUI view + `HostSearchModel` (state, row assembly, filtering).
- `macos/Sources/Features/HostManager/HostSearchController.swift` — the floating panel singleton, key/mouse monitors, action dispatch.
- `macos/Sources/Helpers/SearchMatcher.swift` — the shared matcher.
- `macos/Sources/Features/HostManager/SavedHost.swift` + `SavedHostsStore.swift` — persisted host schema/store.
- `macos/Sources/Features/HostManager/SSHConfigDiscovery.swift` — `~/.ssh/config` parser.

**Matching algorithm (`SearchMatcher`)** — note this is *token-substring*, NOT true fuzzy/subsequence matching:
- Query is lowercased and split on whitespace into tokens.
- Every token must appear as a case-insensitive substring in at least one of the row's fields (AND across tokens, OR across fields). Empty query matches everything.
- Saved hosts match on `[displayLabel, hostname, username]`; discovered hosts match on `[label, hostname, user]`.
- This one matcher is reused across every filterable list in the app (palette, dashboard, snippets, port forwards, SFTP) — keep it a single shared helper on the port. (The *stock* Ghostty palette in `CommandPalette.swift` uses a different, genuinely fuzzy `String.matchedIndices(for:)` — substring first, then first-letter-of-each-word initials fallback, with match-index highlighting. Don't confuse the two.)

**Row/navigation state (`HostSearchModel`):** `search`, `highlightIndex` (wraps modulo row count), `focusToken` (bumped on each show to re-grab focus in the reused panel). Rows are rebuilt as a computed `[PaletteRow]` grouped into two sections — `"Quick connect"` and `"Hosts"`. `PaletteAction` is the confirmed intent enum: `.host`, `.savedHost`, `.quickConnect(String)`, `.localTerminal`, `.serial`.

**Action dispatch (`HostSearchController.run`):** `.savedHost` goes through the staged connect popup `HostConnect.run(command: host.sshCommand(staged: true), …)` (askpass + saved password + auto-reconnect); `.host` and `.quickConnect` call `VaultsTabsModel.shared.newTerminal(command:name:)` directly.

**PERSISTED SCHEMA — `SavedHost` (`hosts.json`), must match field-for-field.** Stored at `~/.config/sarvterminal/hosts.json` as a JSON array; decoding is default-tolerant (every missing key falls back to a default, so the port must tolerate old/partial files). Fields:

| field | type | default / notes |
|---|---|---|
| `id` | UUID string | random if missing |
| `label` | string | display name |
| `hostname` | string | IP/DNS |
| `port` | int | 22 |
| `username` | string | "" = SSH default user |
| `note` | string | "" |
| `authMethod` | enum string | `password` \| `publicKey` \| `agent` \| `ask` (default `password`) |
| `identityFile` | string | abs path; "" disables |
| `password` | string | **plaintext in JSON** (file is encrypted at rest, see below) |
| `forwardAgent` | bool | false |
| `strictHostKeyChecking` | enum string | `yes` \| `no` \| `ask` \| `accept-new` (default `ask`) |
| `connectTimeoutSeconds` | int | 0 = OS default |
| `serverAliveIntervalSeconds` | int | 0 = disabled |
| `useCompression` | bool | false |
| `requestTTY` | bool | false |
| `proxyJump` | string | "" = none |
| `termOverride` | string | "" → `xterm-256color`; `xterm-ghostty` opts into `+ssh` terminfo |
| `localForwards` | [string] | e.g. `"8080:localhost:80"` |
| `remoteForwards` | [string] | e.g. `"9000:localhost:9000"` |
| `dynamicForwardPort` | int | 0 = disabled |
| `initialCommand` | string | typed into shell post-connect, NOT passed as ssh remote cmd |
| `groupID` | UUID string? | nil = root |
| `group` | string | legacy free-form group (migration only) |
| `tags` | [string] | |
| `themeName` | string | Ghostty theme for the tab |
| `platform` | string | `HostPlatform` raw, default `auto` |
| `detectedPlatform` | string | last auto-detected, "" = never |
| `createdAt` / `updatedAt` | date | ISO/`Date` |

Only `displayLabel`, `hostname`, `username` feed the palette search, but the port must read/write the whole schema so nothing is dropped on save. `sshCommand(staged:)` (in `SavedHost.swift`) is the canonical builder that turns these fields into an explicit `ssh -o …` command line — reuse its exact flag logic on Linux (it's shared by the palette and every other connect path).

**`DiscoveredHost` / `SSHConfigDiscovery`:** in-memory only (not persisted). The parser reads `~/.ssh/config` line-by-line, handles both `Keyword Value` and `Keyword=Value`, extracts `Host`/`HostName`/`User`/`Port`, takes only the first concrete token of a multi-pattern `Host` line, skips wildcard entries (`*`/`?`), and sorts case-insensitively. Fully portable pure logic.

### macOS → Linux/GTK equivalents

| macOS piece | Purpose | GTK4 / Zig / Linux equivalent |
|---|---|---|
| `KeyablePanel: NSPanel` (`.titled`+`.fullSizeContentView`, `.floating`, `hidesOnDeactivate`, chromeless) | The overlay window | Borderless `GtkWindow` set transient-for the main window, or a `GtkPopover`; center over the active window (`positionOverActiveWindow` logic). GTK popovers auto-dismiss on focus-out. |
| `NSHostingView` + SwiftUI view tree | Rendering the palette | Native GTK4 widgets built in Zig: `GtkSearchEntry` (field), `GtkListView`/`GtkListBox` in a `GtkScrolledWindow` (rows), `GtkLabel`s for section headers/footer hints. |
| `NSEvent.addLocalMonitorForEvents(.keyDown)` hand-rolled key handling + `model.search` mutation via `DispatchQueue.main.async` | Arrows/Enter/Esc/Backspace/typing/⌘V, worked around AppKit field-editor suppressing SwiftUI updates inside an NSPanel | **This whole workaround is unnecessary on GTK.** Use a real `GtkSearchEntry` — its `changed` signal drives the query directly, `activate` = Enter. Add a `GtkEventControllerKey` for Up/Down/Escape. No manual keystroke accumulation, no async re-render hop. |
| Local + global `NSEvent` mouse monitors for click-outside dismiss | Dismiss on outside click | `GtkPopover` dismisses automatically; for a window, a focus-leave controller or `GDK` grab. |
| SF Symbols (`server.rack`, `terminal`, `bolt.horizontal.circle`, `cable.connector`, `magnifyingglass`) | Row/field icons | Named icons from the GTK/Adwaita icon theme (e.g. `network-server-symbolic`, `utilities-terminal-symbolic`, `system-search-symbolic`) or bundled symbolic SVGs. |
| `AppKeybindStore.shared.action(matching:)` `.commandPalette`, fixed `⌘T`/`⌘N` menu items | Keybind to open | Wire into the GTK apprt keybind/action system (`src/apprt/gtk`); map the configured command-palette binding + New Tab to "show host palette". |
| `SearchMatcher` (Swift) | Token-substring filtering | Reimplement as a small pure Zig fn (lowercase, split whitespace, all-tokens-in-any-field). Trivial; keep it shared. |
| `SSHConfigDiscovery` (Foundation string parsing) | `~/.ssh/config` hosts | Reimplement with `std.fs` + line splitting in Zig; logic ports 1:1. |
| `SavedHostsStore` JSON via `Codable` | Load/save hosts | `std.json` in Zig; must honor the exact field names/defaults above and tolerate missing fields. |
| **AES-256-GCM at rest with a Secure-Enclave-wrapped key** (`SavedHostsStore`, see memory) | Encrypting `hosts.json` (which holds plaintext passwords) | **No Secure Enclave on Linux — this is the hard blocker, owned by the Vaults storage subsystem, not the palette.** The palette only calls `SavedHostsStore.shared.hosts`; it inherits whatever the storage port decides. Fallback options to document there: wrap the data key via the Secret Service API (`libsecret` — GNOME Keyring / KWallet), or a TPM, or `age`/GPG; do NOT ship plaintext passwords unencrypted. |

Everything except the encryption-key wrapping has a clean Linux equivalent, and the GTK version is actually simpler (a real search entry removes the NSPanel/field-editor workarounds that dominate the macOS controller).

### How to verify on Linux

1. **Open:** Press the command-palette keybind (and New Tab / the `+` button) with the Vaults window focused — the centered palette appears over the active window and the search field has focus immediately (test opening it twice; the reused-panel focus bug is the macOS regression to avoid).
2. **Sections & sources:** With `hosts.json` populated and some `Host` entries in `~/.ssh/config`, confirm two sections render — "Quick connect" (Local Terminal, Serial) and "Hosts" (saved hosts first, then ssh_config hosts, with no label appearing twice).
3. **Filter:** Type a multi-word query like `loc 2222` and confirm token-AND-substring matching (matches "Local SSH 2222"); confirm it filters saved + discovered hosts on label/hostname/username; empty query shows everything.
4. **Navigation:** Up/Down wrap around the list and scroll the highlighted row into view; Esc dismisses; clicking outside dismisses.
5. **Actions:**
   - Typed text + Enter → opens a tab running `ssh <query>`.
   - A saved host + Enter → goes through the staged connect flow (password/askpass/reconnect), not a bare `ssh`.
   - Local Terminal → local shell tab; Serial → serial connect UI.
6. **Schema round-trip:** Create a host with all fields set, restart, reopen the palette — the host still matches and connects (verifies `hosts.json` read/write matches the schema and old/partial files decode with defaults).
7. **Encryption:** Confirm `hosts.json` on disk is not plaintext (`grep` for a known password must not hit it) and that the key is wrapped via the chosen Linux secret store.

## 18. Activity log, shell history, pinned history & serial connect

### What it is

Four small Sarv-only features layered on top of the stock Ghostty terminal, all surfaced inside the Vaults UI:

- **Activity log** — an app-wide, persistent history of connections, syncs, transfers, and errors, shown in the Vaults → **Logs** section. Stock Ghostty has no notion of "connections" or "sync", so there is nothing to log; Sarv adds this because the Vaults layer performs SSH connections, cloud sync, and SFTP transfers that the user wants an auditable, searchable record of. This is distinct from any ephemeral per-connection log panel — it is a durable, cross-app ring buffer.
- **Shell history capture** — a "Shell History" side panel (in the Snippets area) that reads the user's *own shell* history file (zsh/bash/fish) and lets any past command be saved as a snippet in one click.
- **Pinned history** — the History tab of the Vaults command sidebar shows recent shell-history commands; the user can **pin** commands so they stay at the top and are exempt from the recent-history display cap.
- **Serial connect** — an ad-hoc "Serial Console" sheet that detects USB-serial adapters, lets the user pick a device + baud rate, and opens a `screen` session in a new terminal tab. Includes a "report an issue" helper because serial behavior is hardware-dependent.

Key files: `ActivityLog.swift`, `LogsSectionView.swift`, `ShellHistory.swift`, `PinnedHistoryStore.swift`, `SerialConnect.swift` (all in `macos/Sources/Features/HostManager/`); serial tab spawning in `VaultsTabsModel.newSerial`; pinned/history UI in `VaultsCommandSidebar.swift`.

### Key logic & data model

**Activity log** (`ActivityLog.swift`) — a singleton `ObservableObject`, capped ring buffer of the most recent **1000** entries, newest-first (new entries `insert(at: 0)`, overflow trimmed from the end). Writes are dispatched onto a serial utility queue and written atomically (no debouncing/coalescing). `log(category, title, detail:, success:)` is thread-safe (hops to main to mutate the published array). `clear()` empties it. Call sites to replicate: `SyncEngine` / `SyncCoordinator` log `.sync` success and `.error` failures; serial/SSH connects should log `.connection`.

- **Storage:** `~/.config/sarvterminal/activity.json` (release) — plain JSON, **NOT encrypted** (unlike hosts/snippets/pinned-history). Path from `AppPaths.configDir`.
- **Dates:** encoded/decoded as **ISO-8601** strings (`JSONEncoder.dateEncodingStrategy = .iso8601`).
- **Schema** — a JSON array of `ActivityEntry`:
  - `id`: UUID string
  - `date`: ISO-8601 timestamp string
  - `category`: enum string, one of `connection` | `sync` | `transfer` | `error` | `info`
  - `title`: string
  - `detail`: string or null (optional)
  - `success`: bool — when `false`, the row's icon renders red regardless of category (a failed connection still lives under "Connections" but reads as a failure).

`LogsSectionView` filters by category (nil = All) and by a case-insensitive substring search over `title` + `detail`; rows show icon/tint per category (overridden to a red `xmark.octagon.fill` when `success == false`), title, detail, and a formatted date; right-click "Copy" yields `"<date> — <title> · <detail>"`.

**Shell history capture** (`ShellHistory.swift`) — pure parsing, no persistence of its own. `recent(limit: 400)` resolves the history file, decodes it leniently (`String(decoding:as: UTF8.self)`, since history files can hold non-UTF8 bytes), and returns up-to-`limit` unique commands, newest-first.
- File resolution order: `$HISTFILE` (tilde-expanded, if it exists) → `~/.zsh_history` → `~/.bash_history` → `~/.local/share/fish/fish_history` (first that exists).
- Per-line normalization: strip zsh extended-history prefix `": <epoch>:<dur>;"` (take text after the first `;`); for fish YAML-ish lines, take text after `"- cmd: "` and skip `"  when:"` / `"- when:"` metadata lines; trim whitespace, drop empties.
- De-dup: iterate the list **reversed** (newest last in file → first out) keeping the first occurrence of each command, stop at `limit`.

**Pinned history** (`PinnedHistoryStore.swift`) — singleton `ObservableObject` holding an ordered `[String]` of pinned commands, newest-pinned first (`insert(at: 0)`). `toggle(command)` adds/removes; `isPinned(command)` tests membership.
- **Storage:** `~/.config/sarvterminal/pinned-history.json` — **encrypted at rest** via `EncryptedStore` (`LocalDataCrypto.swift`), same scheme as hosts/snippets. Payload is a JSON `[String]`.
- Sidebar rule (`VaultsCommandSidebar.swift`): pinned rows always shown; non-pinned recent rows fill the remainder up to a cap (`cap - pinned.count`); both filtered by the search query.

**Serial connect** (`SerialConnect.swift`) — `SerialPorts.list()` scans `/dev` for entries prefixed `cu.`, excluding the noise stubs `cu.Bluetooth-Incoming-Port` and `cu.debug-console`, mapped to `/dev/<name>` and sorted. `label()` strips the `/dev/cu.` prefix for display. The sheet offers bauds `[9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]` (default **115200**). `connect()` calls `VaultsTabsModel.newSerial(device:baud:)`, which spawns a terminal surface whose command is `screen '<device>' <baud>` directly (no shell first; framing is `screen`'s default 8-N-1, no flow control). No serial config is persisted. The "report an issue" popover opens a pre-filled GitHub issue URL (title `Serial: `, label `serial`, templated body embedding device, baud, OS version, app version).

### macOS → Linux/GTK equivalents

| macOS piece | Used for | Linux/GTK equivalent |
| --- | --- | --- |
| `Codable` + `JSONEncoder/Decoder`, `.iso8601` dates | activity.json (de)serialization | Zig `std.json` + explicit ISO-8601 timestamp formatting; keep field names/enum rawValues identical for cross-platform sync compatibility |
| `AppPaths.configDir` (`~/.config/sarvterminal`; hardcodes `~/.config` under `NSHomeDirectory()`, does NOT honor `XDG_CONFIG_HOME`) | file locations | Make it XDG-native on Linux — honor `$XDG_CONFIG_HOME` (fall back to `~/.config/sarvterminal`); keep the dev/release split (`sarvterminal-dev`) |
| `DispatchQueue` + atomic `Data.write(options:.atomic)` | debounced background writes | Zig background thread / GLib worker; write to temp file + `rename()` for atomicity |
| `ObservableObject` / `@Published` | reactive UI updates | GObject signals or a GTK list model (`GListModel`/`GtkListStore`) that the Logs/History views observe |
| SwiftUI `LogsSectionView`, `ShellHistoryPanel`, `SerialConnectSheet`, SF Symbols, `.contextMenu`, `NSPasteboard`, `.popover` | all UI | GTK4 widgets: `GtkListView`/`GtkListBox` in a `GtkScrolledWindow`, a `GtkSearchEntry` for filtering, `GtkDropDown` for category/baud pickers, `GtkPopoverMenu`/right-click for Copy, `GdkClipboard` for copy, `GtkDialog`/`AdwDialog` for the serial sheet, `GtkLinkButton`/`gtk_show_uri` to open the GitHub issue URL. Icons via themed icon names instead of SF Symbols |
| `NSHomeDirectory()`, `ProcessInfo.environment["HISTFILE"]`, `FileManager` | shell-history file resolution | `std.posix.getenv("HISTFILE")` / `getenv("HOME")`, `std.fs`. The candidate paths (`.zsh_history`, `.bash_history`, `fish_history`) are already Linux-correct. Note fish's XDG path may be `$XDG_DATA_HOME/fish/fish_history` — resolve XDG rather than hardcoding `~/.local/share` |
| `/dev/cu.*` device scan | serial device discovery | **Different on Linux**: enumerate `/dev/ttyUSB*`, `/dev/ttyACM*`, `/dev/ttyS*` (or, better, walk `/dev/serial/by-id/`). The `cu.`/Bluetooth noise filter is macOS-specific and drops out |
| `screen '<dev>' <baud>` command | opening the serial session | `screen` exists on Linux but is often not preinstalled; prefer detecting `screen`/`picocpm`/`minicom` or documenting the dependency. Same 8-N-1 default applies. Serial device access typically requires the user be in the `dialout` group — surface a clear permission error |
| `EncryptedStore` / `LocalDataCrypto` — AES-256-GCM data key wrapped by **Secure Enclave** P-256 (fallback: raw key in device-only **Keychain**, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | encrypting `pinned-history.json` | **No clean Linux equivalent.** No Secure Enclave; the Keychain analog is the Secret Service API (libsecret / gnome-keyring / KWallet). Port must reuse whatever `LocalDataCrypto` fallback the Linux Vaults port already establishes (see the encryption/at-rest section) so pinned-history uses the same key path as hosts/snippets — do **not** invent a separate scheme. If no secret store is available, fall back consistently with the rest of the encrypted stores (documented tradeoff). Note: activity.json is plaintext and needs no crypto |
| `Bundle.main` version, `ProcessInfo.operatingSystemVersionString` | issue-report template | app version constant + `uname`/`/etc/os-release` for the Linux OS string |

### How to verify on Linux

- **Activity log:** trigger a sync and a sync failure; confirm entries appear newest-first in Vaults → Logs with the correct category icon/tint (failure row shows red). Confirm `~/.config/sarvterminal/activity.json` is written as a plain JSON array with the exact field names (`id`, `date` ISO-8601, `category`, `title`, `detail`, `success`) and reloads on restart. Insert >1000 entries and confirm the buffer caps at 1000. Test category filter, substring search over title+detail, and the "Clear" confirmation. Verify right-click Copy puts `"<date> — <title> · <detail>"` on the clipboard.
- **Shell history:** with a populated `~/.zsh_history` (including extended-history `": <epoch>:0;cmd"` lines) confirm commands appear newest-first, de-duplicated, in the panel; repeat with bash and a fish `fish_history` file; set `HISTFILE` to a custom path and confirm it takes precedence. Confirm "Save" turns a row into a snippet. Confirm a file with non-UTF8 bytes doesn't crash.
- **Pinned history:** pin a command; confirm it moves to the top of the History tab, survives restart, is exempt from the recent cap, and that `pinned-history.json` on disk is encrypted (not readable plaintext JSON). Toggle off and confirm removal persists.
- **Serial connect:** with a USB-serial adapter plugged in, confirm it appears in the picker (`/dev/ttyUSB*` / `ttyACM*`); pick a baud and Connect, and confirm a new tab opens running `screen '<device>' <baud>` and shows live serial output. Confirm the empty-state and Refresh work with no adapter. Confirm a non-`dialout` user gets a clear permission error rather than a silent failure. Confirm "report an issue" opens the pre-filled GitHub issue in the browser with device/baud/OS populated.

## 19. TeamVault (shared team vaults)

### What it is

TeamVault is SarvTerminal's **paid, backend-synced shared-vault** feature — the only part of the Vaults layer that talks to a server. Stock Ghostty has nothing like it. Where the local Hosts/Snippets/PortForwards stores keep everything on one machine, TeamVault lets a signed-in Sarv user see the SSH hosts, host groups, and shared files that belong to their **teams** (organized org → workspace → team), synced through a hosted API so a whole team shares one connection book.

The defining constraint is **zero-knowledge end-to-end encryption**: the server only ever stores opaque ciphertext and users' *public* keys. All plaintext and every private key live only on the client. A user signs in (via the "Login" button — panel titled "Sign in to Sarv Vault" — by pasting an auth token; automatic browser sign-in exists only as an unused `VaultConfig.urlScheme` constant that is **not** registered in Info.plist and has no redirect handler, so manual token paste is the only working path today; a dev email-only bypass exists in debug), the app registers that account's X25519 public key with the server, and thereafter fetches per-team encrypted blobs and decrypts them locally on demand. Team data is **never written to disk** on the client — it is fetched, decrypted in memory, and shown.

From the user's view (`AccountMenuButton.swift`): an account button in the Vaults top bar; logged out it offers sign-in, logged in it shows the account, a team/account switcher, and "Open Team Vaults", which reveals the team hosts/files in the unified browser alongside local hosts.

Files: `macos/Sources/Features/TeamVault/` — `VaultCrypto.swift`, `VaultKeychain.swift`, `VaultClient.swift`, `VaultConfig.swift`, `VaultModels.swift`, `VaultStore.swift`, `AccountMenuButton.swift`, `TeamsSectionView.swift`. Shared dependency: `macos/Sources/Security/LocalDataCrypto.swift`.

### Key logic & data model

**Crypto scheme** (`VaultCrypto.swift`, the heart of the port — see the porting warning below). All primitives are chosen to work on macOS 13 (no HPKE):

- Each **user/account** has a long-term **X25519** keypair (`Curve25519.KeyAgreement`). The private key is stored client-side (base64 raw representation, 32 B); the public key is uploaded to the server.
- Each **team** has a random 256-bit symmetric **DEK** (data encryption key). The vault payload and each shared file are sealed with **AES-256-GCM** under the DEK. `sealBlob`/`openBlob` use CryptoKit's `AES.GCM` `.combined` form (nonce ‖ ciphertext ‖ tag).
- The DEK is **wrapped** to each member via ECIES: generate an ephemeral X25519 key, `ECDH(ephemeral, memberPublicKey)` → **HKDF-SHA256** (salt = UTF-8 `"sarv-vault-dek-wrap-v1"`, `sharedInfo = ephemeralPub ‖ recipientPub`, 32-byte output) → AES-GCM seal of the 32-byte DEK. Wrapped form on the wire = **`ephemeralPublicKey(32 B) ‖ AESGCM.combined`, base64-encoded**. Unwrap reverses this; note `sharedInfo` on unwrap is `ephPub ‖ self.publicKey` (recipient's own public key), which must byte-match the wrap side.

**Versioning / concurrency:** each team carries a `dekVersion` (integer, key generation) and the vault blob carries a `version`. `putVaultBlob` sends `baseVersion` for optimistic concurrency — the server rejects a write whose base is stale. A port must send and honor these.

**API endpoints** (`VaultClient.swift`, base from `VaultConfig`, Bearer-token auth):
- `POST /auth/dev-login` `{email}` → `{token, user}` (debug-only)
- `GET /me` → identity + `publicKey`/`hasPublicKey`
- `PUT /me/public-key` `{publicKey}` — register this account's X25519 public key
- `GET /me/teams` → `{teams:[…]}`
- Team base path: `/orgs/{org.id}/workspaces/{workspace.id}/teams/{team.id}`
- `GET  {teamBase}/keys/me` → `{dekVersion, wrappedKey}`
- `POST {teamBase}/keys` `{dekVersion, keys:[{userId, wrappedKey}]}`
- `GET  {teamBase}/vault` → `{version, ciphertext?}`
- `PUT  {teamBase}/vault` `{ciphertext, baseVersion}` → `{version, ciphertext?}`
- `GET  {teamBase}/files` → `{files:[…]}`
- `GET  {teamBase}/files/{id}` → single file with `ciphertext`
- `POST {teamBase}/files` `{name, contentType, dekVersion, ciphertext}`

Error responses are parsed from `{error:{message}}`.

**Persisted / wire schema** (`VaultModels.swift`, `VaultKeychain.swift`) — a port must match these field names exactly:

- `VaultAccount` (client-persisted): `{ id (OAuth subject / vault user id), email, token, privateKey (base64 X25519 raw) }`.
- Keychain/file blob: `{ accounts: [VaultAccount], activeID: String? }` — supports multiple signed-in accounts, one active. Each account has its own keypair.
- `TeamSummary` (`GET /me/teams` rows): `{ id, name, role, dekVersion:Int, workspace:{id,name}, org:{id,name} }`.
- `MeResponse`: `{ id, email, displayName?, publicKey?, hasPublicKey:Bool }`.
- `WrappedKeyResponse`: `{ dekVersion:Int, wrappedKey:String }`.
- `VaultBlobResponse`: `{ version:Int, ciphertext:String? }` (base64 of AES-GCM combined).
- `TeamVaultPayload` — the plaintext inside the sealed vault blob: `{ hosts:[SavedHost], groups:[HostGroup] }`, i.e. the **same shapes as the local hosts store** (see the Hosts subsystem for `SavedHost`/`HostGroup` fields). The port must serialize these identically or cross-client decryption produces unreadable payloads.
- `TeamFileMeta`: `{ id, name, contentType, sizeBytes:Int, dekVersion:Int, createdAt? }`; `TeamFileDownload`: `{ id, name, contentType, dekVersion:Int, ciphertext }`.

**State machine** (`VaultStore.swift`, a `@MainActor ObservableObject` singleton): holds `accounts`, `activeAccountID`, `teams`, lazily-populated `teamPayloads[teamID]`, `filesByTeam[teamID]`, per-team error/loading sets, and an in-memory `dekCache[teamID]`. `adoptSession` is the common sign-in path: reuse or mint a keypair, upsert the account, `PUT /me/public-key`, then load teams. `ensureHostsLoaded` fetches `keys/me` → unwrap DEK → fetch vault blob → AES-GCM open → JSON-decode payload. Downloaded files are decrypted and written to `~/Downloads`. Debug builds have `initializeVaultWithSampleData` which generates a DEK, wraps it to the caller, seals a sample payload + a sample file, and PUTs them — useful as a reference implementation of the full write path.

### macOS → Linux/GTK equivalents

**PORTING WARNING — crypto/auth is the hard part.** Everything else in this subsystem is ordinary HTTP + JSON and ports trivially; the risk is entirely in reproducing the crypto **byte-for-byte** and in secret storage. Get one HKDF input, salt string, or concatenation order wrong and the Linux client silently cannot decrypt anything a Mac wrote (and vice versa). Interop-test against the same server before trusting it.

| macOS piece | Purpose | Linux / GTK / Zig equivalent |
| --- | --- | --- |
| `CryptoKit` `Curve25519.KeyAgreement` (X25519) | user keypair, ECDH for DEK wrap | libsodium `crypto_scalarmult` / `crypto_kx`, or OpenSSL X25519, or a vetted Zig X25519. Match raw 32-byte encodings. |
| `CryptoKit` `AES.GCM` `.combined` | seal/open DEK, blob, files | AES-256-GCM from libsodium/OpenSSL. Reproduce the **combined layout** (nonce ‖ ciphertext ‖ tag) CryptoKit uses (12-byte nonce, 16-byte tag). |
| `CryptoKit` `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256, salt:, sharedInfo:, outputByteCount: 32)` | derive wrap key | HKDF-SHA256 from the same lib. Exact salt (`sarv-vault-dek-wrap-v1`) and `sharedInfo` (`ephPub ‖ recipientPub`) bytes are load-bearing. |
| `SecItem*` Keychain (`kSecClassGenericPassword`, `WhenUnlockedThisDeviceOnly`) storing the accounts blob (release) | at-rest storage of tokens + private keys | **No clean Linux equivalent.** Use libsecret / GNOME Keyring (Secret Service API) as the primary store; that is the standard GTK-app secret backend. Fallback: an encrypted file under the config dir (see next row). |
| Secure Enclave (`SecureEnclave.P256`) via `LocalDataCrypto` — wraps the on-disk key material (debug file path, and the general local-data key) to non-exportable hardware key | hardware-bound key protection | **No Linux equivalent** on typical hardware. Options in descending strength: TPM 2.0 (via tpm2-tss) to seal a data key; else a Secret-Service-stored key; else a passphrase-derived key (Argon2id). Whatever is chosen, the on-disk file format is a local implementation detail — it does **not** need to interop with macOS (only the *server-side* ciphertext/wrapped-key formats must). So the Linux port can pick any sound at-rest scheme for `VaultAccount` storage; only `VaultCrypto`'s wire formats are fixed. |
| `URLSession.shared` + async/await (`VaultClient`) | HTTP client | Ghostty's existing Zig HTTP path, or libsoup3 (already a GTK dependency), or curl. Bearer header, JSON bodies, `{error:{message}}` parsing. |
| `NSWorkspace.shared.open(loginURL)` + a custom URL-scheme constant `sarvterminal://auth?token=…` (`VaultConfig.urlScheme` — **not** registered in Info.plist, no redirect handler, currently unused) | "Login" button / manual token paste (automatic redirect-back is unimplemented) | GTK: `gtk_uri_launcher` / `xdg-open` to open the browser. Custom-scheme handoff needs an XDG desktop-file `MimeType=x-scheme-handler/sarvterminal;` registration and a single-instance D-Bus activation to receive the redirect; today even macOS falls back to manual token paste, so a paste-token field is an acceptable v1. |
| `JSONEncoder`/`JSONDecoder` over `Codable` DTOs | wire (de)serialization | any JSON lib; match the field names in the schema table above verbatim. |
| SwiftUI `AccountMenuButton` / `TeamsSectionView` | sign-in popover, team browser | GTK4 widgets (popover, list boxes), wired to the ported store. |
| `#if DEBUG` in `VaultConfig` (localhost:4500 API, localhost:4520 login, dev-login enabled) vs release (`vault.sarv.com`) | dev-vs-prod endpoints | mirror with a build-flag / env switch; keep the **dev-login bypass off in release** (matches the API's `AUTH_DEV_BYPASS`). |

### How to verify on Linux

Bring up the local Vault API (`SarvTerminalVault`, `docker compose up`, API on `localhost:4500`, login console on `localhost:4520`) and, in a debug build:

1. **Sign in:** dev-login with an email; confirm an account is persisted, `PUT /me/public-key` succeeds, and `GET /me/teams` populates the team list.
2. **Key registration round-trip:** confirm the public key the server stores matches the base64 of the account's X25519 public key.
3. **Vault decrypt:** on a team seeded from a Mac client, `GET keys/me` → unwrap DEK → `GET vault` → AES-GCM open → JSON-decode; assert the hosts/groups render identically to the Mac. This is the definitive cross-client crypto-interop check.
4. **Vault write-back:** seal a modified payload and `PUT vault` with the correct `baseVersion`; re-open on a Mac client and confirm it decrypts. Also confirm a stale `baseVersion` is rejected.
5. **Files:** list, download (decrypt to `~/Downloads` or XDG downloads dir), and upload a sealed file; verify the Mac can download and decrypt it.
6. **Wrap/unwrap unit test:** `wrapDEK` then `unwrapDEK` on the Linux implementation must round-trip, and a DEK wrapped on macOS must unwrap on Linux with the same keypair (feed identical test vectors both ways).
7. **Secret storage:** confirm the token + private key survive an app restart via the chosen backend (libsecret/TPM/encrypted file) and are not left in plaintext on disk.
8. **Multi-account:** add a second account, switch active, confirm the visible teams and DEK cache reset per account (`resetTeamState`).
9. **Release safety:** in a release build, confirm dev-login is disabled and endpoints point at `vault.sarv.com`.

## 20. Settings, sync & rebindable keybinds

### What it is

Stock Ghostty configures itself through a single text file (`config`) and a fixed, config-file-only keybind system, and its quit-confirmation / keybind routing all assume Ghostty's own `BaseTerminalController` windows. SarvTerminal's Vaults layer is a **single custom window** (`HostManagerController`) that embeds terminal surfaces directly, so none of those assumptions hold. Sarv therefore rebuilds three things on top of Ghostty:

1. **A native Settings UI** (`SettingsController` + `Sections/*`) that edits the Ghostty config file *plus* a large set of Sarv-only preferences (background image, SFTP defaults, notifications, tabs/session-restore behavior, import-from-other-terminal, etc.) that have no Ghostty config equivalent.
2. **An end-to-end-encrypted settings sync engine** — the user picks a GitHub private repo or a cloud-synced folder, sets a master password, and their config + appearance + keybinds + saved hosts/groups/snippets/sessions/port-forwards replicate across machines. Nothing readable is ever uploaded; only the master password decrypts it, and the password never leaves the device.
3. **A rebindable app-level keybind store** (`AppKeybindStore`) layered on top of Ghostty keybinds, because Sarv adds actions Ghostty has no binding for (open command palette, new local terminal tab, split-with-chooser, reopen closed tab, show Vaults/SFTP, save session) and the single-window model means app shortcuts must be intercepted in `AppDelegate` before a focused terminal surface swallows them.

The close-before-quit confirmation (`HostManagerController.windowShouldClose`) is part of the same story: Ghostty's built-in "confirm quit while a process runs" only inspects `BaseTerminalController` windows, which Vaults isn't — so it never fires. Sarv re-implements it manually (checks `ghostty.needsConfirmQuit`, shows a `SarvAlert`, always drives the actual quit via `NSApp.terminate`). This is the same reason app keybinds are hand-wired: the single-window model bypasses Ghostty's own controllers, so any Sarv dev on Linux must expect to route these at the apprt level, not via libghostty.

### Key logic & data model

**Rebindable app keybinds — `Settings/Keybinds/AppKeybindStore.swift`**

- `AppShortcutAction` enum: the app-level actions. Raw values are the stable IDs used everywhere (and in the sync payload): `app:command_palette`, `app:new_local_terminal`, `app:split_right`, `app:split_down`, `app:reopen_closed_tab`, `app:show_vaults`, `app:show_sftp`, `app:save_session`. Each has `defaultCombos: [String]` in Ghostty config combo syntax (e.g. `["cmd+t","cmd+p"]`). Deliberately avoids `cmd+k` (Ghostty's clear-screen default).
- Persisted in `UserDefaults` under key **`SarvAppKeybinds`** as a dictionary `{ actionID: [combo, …] }` (multiple combos per action allowed; an absent/empty entry = unbound). Legacy single-string-per-action format is migrated on load (`loadStored`). Two one-time flag-gated migrations exist (`SarvAppKeybinds.paletteKey.v2`, `SarvAppKeybinds.sftpKey.v1`) that move stale defaults without clobbering user edits.
- Core algorithm: combos are compared by `KeybindParser.splitModsAndKey` (mods set + key string), never by raw string. `addCombo` enforces **global uniqueness** — the combo is stripped from every *other* action first so a combo triggers exactly one action. `action(matching: NSEvent)` maps a live key event to an action; `conflictingActionID` powers conflict warnings in the editor.
- `Keybind.swift` also defines **fixed (non-rebindable) shortcuts** the single-window model wires by hard-coded key codes in `AppDelegate.localEventKeyDown`: `kLockedShortcuts` (shown as non-removable chips) and `kReservedCombos` (blocked from being assigned elsewhere: tab nav, tab numbers `cmd+1…8`, split focus/resize `cmd+opt+arrows` / `cmd+ctrl+arrows`, `cmd+w` close pane, `cmd+opt+w` close tab, `cmd+enter` fullscreen, `cmd+shift+enter` zoom, `cmd+shift+m` focus mode). **These lists must be kept in sync with the actual handler** (`AppDelegate.localEventKeyDown`, lines ~700–745). A port must reproduce both the handler and these catalogs together.

**Ghostty-keybind parsing/editing — `Settings/Keybinds/KeybindParser.swift`, `Keybind.swift`**

- Parses `keybind = …` lines from the config file directly in Swift (not the C API — upstream doesn't expose `RepeatableKeybind`). `KeybindEntry` keeps the original `rawLine` for round-trip find-and-replace on edit/delete. `loadActiveBindings()` shells out to `<self> +list-keybinds` for the effective defaults+overrides list. `KeybindModifiers` OptionSet renders both config strings (`ctrl+cmd+shift+`, note `opt`→`alt`) and symbolic labels (⌃⌥⇧⌘). `splitModsAndKey` handles the literal `+` key edge case. The editor (`KeybindEditorSheet`) writes back `trigger=action` strings.

**Sync manifest & payload schema — `Settings/Sync/SyncManifest.swift` (a port MUST match these exactly)**

- Remote layout: `manifest.json` (plaintext), `settings.enc`, `hosts.enc` (AES-GCM blobs), plus a generated `README.md`. GitHub keeps history via git commits; the folder provider snapshots each version into `SarvTerminal/history/v<N>/`. All folder-provider files live under a `SarvTerminal/` subfolder (with legacy-root migration).
- `SyncManifest` (Codable JSON, `.sortedKeys`, iso8601 dates): `schema:Int=1`, `version:Int` (monotonic, bumped every push), `lastSyncDate:Date`, `deviceName:String`, `kdfSalt:Data` (base64), `kdfIterations:Int`, `verifier:Data` (AES-GCM of the constant string `"sarv-sync-verifier-v1"` — decrypting it proves the password), `files:[String]`. Nothing secret is in the manifest by design.
- `SyncSettingsPayload` (contents of `settings.enc`, every field optional): `ghosttyConfig:String?`, `bgShared:Bool?`, `bgImagePath:String?`, `bgVisibility:Double?`, `appKeybinds:[String:[String]]?`, `sftpAutoSave/sftpConfirmDelete/sftpShowHidden:Bool?`, `backgroundImage:{name:String,data:Data}?`, and `defaults:Data?` — a JSON blob (sorted keys) of **all** syncable `Sarv*` UserDefaults. The `defaults` blob is the forward-looking source of truth (new prefs sync automatically); the explicit fields are kept only for back-compat with older readers.
- `SyncHostsPayload` (contents of `hosts.enc`): `hosts:[SavedHost]`, `groups:[HostGroup]`, `snippets:[Snippet]?`, `savedSessions:[SavedSession]?`, `portForwards:[PortForward]?` (last three optional for back-compat). Those model types are owned by the Vaults section, not this one.

**Crypto — `Settings/Sync/SyncCrypto.swift`**

- Key = PBKDF2-HMAC-SHA256(password, salt), **310,000 iterations**, 16-byte salt, 32-byte key (AES-256). Payloads = AES-256-GCM; the stored blob is CryptoKit's *combined* form `nonce ‖ ciphertext ‖ tag`. A wrong password fails the GCM auth tag rather than yielding garbage. One-way by design — no recovery.

**Engine invariants — `Settings/Sync/SyncEngine.swift` (the hard part to port correctly)**

- **Push safety ladder** (see the `push` doc comment): (1) local-state guards — refuse if any store's `loadFailed`, or if everything is empty locally but the last sync had data (`suspiciousEmptyPush`); `force` (manual "Sync ↑") overrides only these. (2) Strict manifest read: nil means genuinely-empty remote; an existing-but-undecodable manifest is a hard `remoteUnreadable` error, never treated as empty. (3) **Not** overridable by force: if `remoteManifest.version > lastSyncedVersion` → `remoteHasUnpulledData` (pull first). (4) Password validated against the remote `verifier` before reusing its salt.
- **No-op suppression**: SHA-256 `contentFingerprint` of the two plaintext payloads; if remote is at our last version and the fingerprint matches, skip the push (stops version churn when the Settings window closes without edits).
- **Integrity gate**: every freshly-encrypted payload is decrypted + decoded and byte-compared to source *before* the commit (`verifyRoundTrip`), else abort.
- **Pull**: all-or-nothing decode of every listed file before touching local state; first pull on a machine with existing data **merges** (`ingest`), subsequent pulls **mirror** (`replaceAll`) so deletes propagate. Reloads Ghostty config, posts `.sarvSyncDidPull`.
- **Settings persistence — `SyncSettings.swift`**: all under `SarvSync*` UserDefaults keys (`SarvSyncEnabled`, `SarvSyncProvider`, `SarvSyncGitHubURL`, `SarvSyncFolderBookmark`, `SarvSyncFolderPath`, `SarvSyncLastVersion`, `SarvSyncLastDate`, `SarvSyncLastHostCount`, `SarvSyncLastGroupCount`, `SarvSyncLastFingerprint`, `SarvSyncHistoryEnabled`, `SarvSyncHistoryLimitEnabled`, `SarvSyncHistoryKeepCount`). All `SarvSync*` keys are excluded from the synced `defaults` blob so a push can't poison the remote's own config.
- **Auto-sync orchestration — `SyncCoordinator.swift`**: subscribes to store `objectWillChange` + `.sarvSettingsClosed` + `.sarvConfigDidCommit` (skipping commits tagged with `SettingsViewModel` to avoid per-tweak churn); debounces pushes (3s), serializes them (one at a time, coalesce), pulls on launch and hourly, and guards the pull→apply→push feedback loop via `beginApplyingRemote()` (9s suppression). Caches the master password in memory for the session.

**Providers — `Settings/Sync/SyncProvider.swift`**: `SyncProvider` protocol (`testConnection`/`readManifest`/`readFile`/`writeFiles`). GitHub provider uses a PAT + REST, **enforces private-repo-only and push permission**, and writes all files in **one commit** via the Git Data API (blobs→tree→commit→ref) with 409/422 retry. Folder provider uses a security-scoped bookmark, writes atomically into `SarvTerminal/`, keeps `history/v<N>/` snapshots with pruning.

### macOS → Linux/GTK equivalents

| macOS / Apple API used | Purpose | Linux / GTK4 / Zig equivalent |
|---|---|---|
| SwiftUI `SettingsController`, `Sections/*`, sheets | Settings UI | Rebuild in GTK4 (`Adw.PreferencesWindow` / `Gtk.Builder` UI in `src/apprt/gtk`); this is a full re-implementation, not a port |
| `UserDefaults` (`Sarv*` keys) | All Sarv preferences + `SarvAppKeybinds` | `GSettings`/`GKeyFile`, or a plain JSON/INI file under `$XDG_CONFIG_HOME/sarvterminal/`. **Keep the exact key names and the `{actionID:[combo]}` / sorted-JSON `defaults` blob shape** or sync breaks cross-platform |
| `CryptoKit` `AES.GCM` (combined form) | Payload encryption | libsodium (`crypto_aead_aes256gcm` or XChaCha20-Poly1305), or OpenSSL EVP AES-256-GCM. Must reproduce the `nonce‖ciphertext‖tag` layout to interop with existing Mac backups |
| `CommonCrypto` `CCKeyDerivationPBKDF` | PBKDF2-HMAC-SHA256, 310k iters | OpenSSL `PKCS5_PBKDF2_HMAC` / libgcrypt — identical algorithm, salt, iteration count, 32-byte output |
| `SecRandomCopyBytes` | Salt/nonce entropy | `getrandom(2)` / `/dev/urandom` / `randombytes_buf` |
| **Keychain** (`SecItem*`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), `SyncKeychain.swift` | Store master password + GitHub PAT, device-only, never synced | **No clean equivalent.** Use Secret Service API / libsecret (GNOME Keyring / KWallet) via D-Bus. Fallback where no keyring exists: an on-disk file with `0600` perms (mirrors the existing DEBUG-build fallback below). Single-item JSON-blob pattern still applies |
| **Secure Enclave** (`LocalDataCrypto` sealing the DEBUG secrets file) | Enclave-wrapped at-rest key | **No equivalent** (no TPM-backed CryptoKit analog). Fall back to a keyring-stored or password-derived key; if using TPM, `tpm2-tss` is the closest, but plan for the plain `0600`-file fallback |
| Security-scoped bookmarks (`URL(resolvingBookmarkData:)`, `startAccessingSecurityScopedResource`) | Persist folder access across launches (sandbox) | Not needed on unsandboxed Linux — store the plain folder path; if Flatpak, use the XDG Desktop Portal / document portal to retain access |
| `Host.current().localizedName` | `deviceName` in the manifest | `gethostname(2)` / `g_get_host_name()` |
| `Process` running `<self> +list-keybinds` / `+list-actions` | Enumerate effective bindings/actions | Same subprocess call via `GSubprocess`; the ghostty CLI works identically on Linux |
| `NSEvent` local monitor + `AppKeybindStore.action(matching:)` in `AppDelegate.localEventKeyDown` | Intercept app-level shortcuts before the surface | GTK4 `GtkEventControllerKey` / a `capture`-phase key handler on the Vaults window, matching against the same `SarvAppKeybinds` data and the `kReservedCombos`/`kLockedShortcuts` catalogs |
| `NSWindowDelegate.windowShouldClose` + `SarvAlert` + `ghostty.needsConfirmQuit` | Confirm-before-quit with running process | GTK `GtkWindow::close-request` signal returning `true` to veto, plus an `AdwMessageDialog`; call the same libghostty "needs confirm quit" check |
| `PropertyListSerialization` (iTerm2 `.itermcolors` import) | Parse Apple plist | A plist parser lib, or skip/degrade the iTerm2 importer on Linux (Ghostty/Alacritty/kitty/WezTerm importers are plain-text and port directly) |
| `NSNotification` (`.sarvSettingsClosed`, `.sarvConfigDidCommit`, `.sarvSyncDidPull`) | Decoupled change signals | GObject signals or a small internal event bus |
| `Combine` `objectWillChange` (SyncCoordinator observers) | Fire auto-push on store changes | GObject `notify` signals / manual observer callbacks |

`Global Keybinds/GlobalEventTap.swift` is essentially **unmodified upstream Ghostty** (macOS `CGEvent` tap for system-wide quick-terminal keybinds while the app is inactive) — its git history is just the initial commit. GTK already has its own global-shortcut path; nothing Sarv-specific to port here.

### How to verify on Linux

1. **App keybinds round-trip**: rebind an action (e.g. command palette to a new combo) in Settings, confirm it fires, and confirm the old combo no longer does; verify the `{actionID:[combo]}` structure is written under the `SarvAppKeybinds` key and reloads after restart. Confirm assigning a `kReservedCombos` entry (e.g. `cmd+w`) is blocked, and that locked shortcuts render as non-removable.
2. **Migration**: seed the old single-string-per-action format and confirm it upgrades to arrays on launch; confirm the `.v1`/`.v2` migration flags apply once and don't re-clobber a user edit.
3. **Crypto interop with an existing Mac backup**: point Linux at a repo/folder already synced from macOS and Pull. It must derive the key (PBKDF2-SHA256/310k), pass the `verifier` check with the correct password, and fail cleanly with a wrong one. Encrypt a payload on Linux, Pull it on macOS — byte-compatible AES-256-GCM combined form is the acceptance bar.
4. **Push safety**: on a fresh Linux machine with sync configured but never pulled, confirm an auto-push is refused (`remoteHasUnpulledData`) and does not blank the remote; confirm a no-op close of Settings produces no version bump (fingerprint match); confirm the pre-upload integrity round-trip runs.
5. **Both providers**: GitHub path rejects a public repo and a read-only token; folder path writes under `SarvTerminal/`, snapshots `history/v<N>/`, and prunes to the configured limit.
6. **Secrets at rest**: master password + PAT land in the system keyring (libsecret) and never in any synced file or plaintext on disk; verify the `0600`-file fallback when no keyring is present.
7. **Quit confirmation**: with a running process in a terminal tab, closing the window / quitting shows the confirm dialog and only terminates on "Quit"; with nothing running it quits immediately.
8. **Import**: import an Alacritty/kitty/WezTerm config — appearance auto-applies, keybinds land in the review sheet as suggestions with conflict flags.

## 21. App-level customizations

This is a grab-bag of smaller Sarv-specific behaviors layered on top of stock Ghostty. Some of these subsystems (Quick Terminal, Secure Input, Clipboard-paste confirmation) already exist in Ghostty and therefore in the GTK app — those are called out as "mostly stock, port only the Sarv delta". The two things a Linux dev must genuinely **rebuild** are the **app-level notification system** (entirely Sarv-built) and the **new-tab/split working-directory policy**.

### What it is

- **App-level notifications + in-app inbox.** Stock Ghostty only raises surface-bound notifications (a program's OSC 9 desktop notification for a given surface). Sarv adds a separate, app-level notification stream for events that aren't tied to one terminal surface: SFTP transfer finished/failed, port-forward tunnel dropped/failed, settings-sync finished/failed/remote-newer, SSH disconnect (only after auto-reconnect retries are exhausted), host-key change (possible MITM), app update available, and background-tab attention/AI-agent prompts. These are shown as macOS banners **and** mirrored into an in-app inbox (a toolbar "bell" with an unread badge) so the user can review what happened while away. There is a debounced custom alert sound and per-category on/off preferences.
- **New-tab / split working directory.** Stock spawn logic could land a local terminal in the *app process's* cwd (e.g. `/` or the config dir). Sarv guarantees new local tabs open in a user-configurable "New tab directory" (home by default), and new splits inherit the directory of the pane they were split from (falling back to that same new-tab directory).
- **Custom app icon / branding.** Rebranded app icon asset sets (release + a badged `AppIconDebug` "Dev" variant), and a shared brand-logo image used as the icon in every in-app alert/dialog so confirmation popups look consistent across debug/release. The icon *selection* machinery (blueprint/chalkboard/etc. styles, dock-tile plugin) is stock Ghostty.
- **Quick Terminal, Secure Input, Clipboard-paste confirmation.** These are stock Ghostty features. The only Sarv delta worth noting is `QuickTerminalScreenStateCache` (restores the quick terminal's last frame per physical display) and the alert-routing/brand-icon touch-ups.

### Key logic & data model

Key files (all under `macos/Sources/Features/Notifications/`): `SarvNotifications.swift` (delivery + copy + click routing), `SarvNotificationCenter.swift` (inbox model + persistence), `SarvNotificationSettings.swift` (prefs), `NotificationsInboxView.swift` (bell UI). Working-directory logic lives in `macos/Sources/Features/HostManager/VaultsTabsModel.swift` and `macos/Sources/App/macOS/AppDelegate.swift`. Branding: `macos/Sources/Helpers/AppBrandIcon.swift`, `macos/Sources/Features/Custom App Icon/`.

**Notification routing model.** Two parallel enums a port must reproduce:
- `SarvNotificationRoute` (raw strings, stored in `userInfo`/inbox): `hosts`, `transfers`, `portForwarding`, `sync`, `knownHosts`, `update`, `tab`. Each route knows where a click should navigate.
- `SarvNotificationCategory` (user-toggleable): `transfers`, `tunnels`, `sync`, `ssh`, `security`, `update`, `tabs`. `SarvNotifications.settingsCategory(for:route)` maps route → category; a disabled category is dropped entirely (no banner, no sound, no inbox entry).

Behaviors to preserve: notifications carry `userInfo[sarvKind]` so the app-level stream is distinguished from Ghostty's surface notifications; a stable identifier `com.sarv.terminal.<route>.<dedupe>` collapses repeat events (e.g. a flapping tunnel or per-file transfer) rather than stacking; the alert sound is played by the app (not the OS notification) so it can be **debounced to at most once per 5s**, and is suppressed entirely while the inbox popover is open.

**Persisted schema — inbox (`notifications.json` in `AppPaths.configDir`):** a JSON array of `SarvNotificationItem`, capped at the newest 100:

```
{
  "id":          "UUID string",
  "date":        Date (JSONEncoder default: seconds since 2001 reference date, a Double),
  "title":       "String",
  "body":        "String",
  "routeRaw":    "String (one of the route raw values above)",
  "urlString":   "String | null",   // for .update routes
  "tabIDString": "String | null",   // for .tab routes, a UUID string
  "read":        Bool
}
```

**Persisted schema — preferences (UserDefaults / GSettings on Linux):**
- `SarvNotifEnabled` — Bool, master switch, default `true`.
- `SarvNotifSoundEnabled` — Bool, default `true`.
- `SarvNotifDisabledCategories` — array of category raw-value strings that are turned OFF (default all on/empty). Note the inverted sense: absence = enabled.
- `SarvNewTabDirectory` — String; empty means "use home".

**New-tab directory logic** (`VaultsTabsModel.newTabWorkingDirectory`): read `SarvNewTabDirectory`, trim whitespace; if empty return the home dir, else expand a leading `~`. New tabs always pass an explicit cwd (never let the core inherit the app process cwd). Splits use `anchor.pwd ?? newTabWorkingDirectory` (the pane's live pwd, else the fallback).

### macOS → Linux/GTK equivalents

- **`UNUserNotificationCenter` / `UNMutableNotificationContent` / notification categories & actions** → freedesktop desktop notifications via the `org.freedesktop.Notifications` D-Bus interface (GTK: `GNotification` + `g_application_send_notification`, or direct libnotify/`Notify`). The "Show" action and click-to-navigate map to notification actions and the `app.<action>` activation callback. Dedup-by-identifier maps to `GNotification` IDs (send with the same id to replace). Ghostty's GTK apprt already talks to this interface for its surface notifications, so reuse that plumbing.
- **`NSSound` for the debounced alert sound** → GStreamer / `canberra-gtk-play` / libcanberra, or play `notification_sound.wav` via the audio stack the GTK app already links. Keep the 5s debounce and inbox-open suppression in shared logic.
- **`UserDefaults`** → `GSettings`/`GKeyFile` or the config store the GTK app already uses; replicate the four keys above with identical defaults and the inverted "disabled categories" semantics.
- **Inbox persistence (`Data`/`JSONEncoder` → `notifications.json`)** → plain JSON to the GTK app's config dir; **caution:** Swift's `JSONEncoder` writes `Date` as a Double (Apple reference-date epoch, 2001-01-01) — a Linux reader/writer should standardize the on-disk `date` format (ISO-8601 or Unix epoch) rather than blindly matching Apple's reference epoch. The files are per-platform, so a clean format is fine.
- **Secure input (`Carbon EnableSecureEventInput`)** → **no clean Linux equivalent.** This is a macOS-global keyboard-isolation API. On Wayland/X11 there is no portable equivalent; treat it as a macOS-only feature and omit it (Ghostty's GTK app does not implement it). No fallback is required.
- **Custom app icon (`NSWorkspace.setIcon`, dock-tile plugin, `DistributedNotificationCenter`)** → on Linux the icon comes from the `.desktop` file + installed hicolor theme PNGs/SVGs; there is no runtime dock-icon swap, so the AppIcon picker/dock-tile plugin has no Linux analog. The one portable Sarv delta is `AppBrandIcon` — bundle the brand logo and use it as the icon in in-app GTK alert dialogs.
- **Quick Terminal + `QuickTerminalScreenStateCache`** → Ghostty's GTK quick-terminal is a separate implementation; the per-display frame-restore cache (keyed by a stable display UUID, TTL-pruned at 14 days, capped at 10 screens, invalidated on scale/size change) is a nice-to-have refinement, not required for parity.
- **Working-directory policy** is pure logic (no AppKit dependency) — port it directly into the GTK new-tab/split spawn path; just ensure an explicit cwd is always passed to the surface config.

### How to verify on Linux

1. **Notifications end-to-end:** trigger each event class (start/fail an SFTP transfer, drop a port-forward tunnel, force a sync failure, disconnect an SSH host after retries, change a host key, an available update). Confirm a desktop banner appears, it is mirrored as an inbox row with the correct route, and clicking either the banner's "Show" action or the inbox row navigates to the right screen.
- 2. **Dedup:** fire the same event twice (e.g. re-fail the same file/tunnel) and confirm the banner replaces rather than stacks.
- 3. **Sound debounce:** fire several events within 5s and confirm the sound plays at most once; open the inbox and confirm new arrivals are silent and land already-read (no unread-badge bump).
4. **Preferences:** flip the master switch off (no banners at all), turn off a single category and confirm only that class is suppressed, then re-enable and confirm other choices were preserved. Confirm the `SarvNotif*` keys and `notifications.json` (capped at 100 newest) round-trip across a relaunch.
5. **Working directory:** with `SarvNewTabDirectory` empty, open a new local tab and run `pwd` → home dir (never `/` or the config dir). Set it to a path (with a `~`) and confirm expansion. Split a pane that is `cd`'d into a project dir and confirm the new split's `pwd` matches the parent pane.
6. **Branding:** confirm in-app alert/confirmation dialogs show the Sarv brand logo, and the app's `.desktop`/theme icon resolves in the launcher and window decorations.

---

## Appendix A. Visual design reference

This appendix documents the concrete visual specification of the macOS "Vaults" host-manager surfaces so a GTK/Adwaita implementation can match the look. Values are extracted verbatim from the SwiftUI source under `macos/Sources/Features/HostManager/`. Where a value is not present in source, it is marked **"not specified in source."**

### A.0. Cross-cutting tokens (shared by every surface)

**Semantic text colors** (`Sources/Helpers/Extensions/Color+SemanticText.swift`) — these replace SwiftUI's built-in `.secondary`/`.tertiary` because those fail WCAG-AA on the light theme. Every muted label routes through them:

| Token | Light | Dark | Intended meaning |
|---|---|---|---|
| `.secondaryText` | `white 0.29` ≈ `#4A4A4A` (~7:1 on white, ~4.6:1 on gray sidebar) | `white 0.78` ≈ `#C7C7C7` | Secondary/muted labels, icons, captions |
| `.tertiaryText` | `white 0.42` ≈ `#6B6B6B` (~4.9:1 on white) | `white 0.62` ≈ `#9E9E9E` | De-emphasized captions, breadcrumbs, ⌘-badges, hints |

GTK equivalent: define two named CSS colors (e.g. `@define-color secondary_text`, `@define-color tertiary_text`) with light/dark variants rather than using Adwaita's `dim-label` (which is opacity-based and would reproduce the same low-contrast problem). Target the same contrast ratios.

**Accent color:** macOS `Color.accentColor` — the **system accent** (user-configurable in System Settings; defaults to blue). Used for selection fills, active borders, primary buttons, checkmarks, pin icons. No custom brand asset is defined (no `AccentColor` asset or hardcoded brand hex found in the host-manager sources). GTK equivalent: Adwaita `@accent_bg_color` / `@accent_color` (libadwaita 1.6+ accent system), or `@theme_selected_bg_color`.

**Standard corner radii** (continuous/"squircle" style throughout — `style: .continuous`):
- `5` — small inline capsules/value chips, tab-color swatch inner
- `6` — pills, chips, toolbar buttons, small icon buttons, hover rows (default `listRowHover`)
- `7` — sidebar section rows, command-sidebar switcher buttons, snippet buttons
- `8` — editor field rows, host cards, search fields, command rows
- `9` — the nav "island" grouping Vaults+SFTP
- `10`–`12` — larger cards / connection popups
- `12` — `EditorCard` grouped card
- `14`, `18` — large empty-state icon tiles

GTK: continuous-corner squircles aren't native to GTK; approximate with standard `border-radius` at the same px values (circular corners are an acceptable approximation).

**Standard fill/stroke opacities** (applied to `Color.secondary` or `Color.primary`):
- Card fill: `Color.secondary.opacity(0.08)`; card stroke: `0.10` at `lineWidth 0.5`
- Pill inactive fill: `Color.secondary.opacity(0.08)`; selected pill fill: `Color.primary.opacity(0.12)`
- Row hover fill: `Color.secondary.opacity(0.10)`–`0.14`; `listRowHover` default `Color.secondary.opacity(0.14)`
- Field row border: `Color.secondary.opacity(0.22)` (`lineWidth 1`), hover `0.35`, focused `Color.accentColor.opacity(0.7)` at `lineWidth 1.5`
- Dashboard host card: fill `Color.secondary.opacity(0.10)`, stroke `0.20` `lineWidth 1`
- Stroke-only "+" buttons: `Color.secondary.opacity(0.25–0.30)` `lineWidth 1`

**Drop / drag feedback:** green. Insertion bar = `Color.green` capsule width `3`, offset `x: -5`; target wash = `Color.green.opacity(0.14–0.18)`.

**Scrim (modal dim):** `Color.black.opacity(0.35)` full-bleed, tap-to-dismiss.

**Window content backgrounds:** opaque surfaces use `Color(NSColor.windowBackgroundColor)`; in "shared background" mode the content area is `Color.clear` so translucent terminal panes blend against a window-level `NSImageView`. GTK equivalent: `@window_bg_color` / `@view_bg_color`.

**Animations (specified):**
- Host-editor side panel: `.easeInOut(duration: 0.18)`, slide from trailing edge combined with opacity
- Command sidebar show/hide: `.easeInOut(duration: 0.18)`, `.move(edge: .trailing)`
- Tab drop-target highlight: `.easeOut(duration: 0.12)`
- Tab scroll-to-active: `.smooth(duration: 0.2)`
- Font section expand: `.easeInOut(duration: 0.15)`
- All-tabs overlay: `.transition(.opacity)`
- Sync-cloud spinner: inner arrows rotate `0→360°`, `.linear(duration: 1).repeatForever(autoreverses: false)`

**Icons:** all glyphs are **SF Symbols** (`Image(systemName:)`). Each surface below lists the exact symbol name and meaning; the rightmost column of each icon table gives an Adwaita/icon-theme equivalent. GTK equivalent generally: use the symbolic icon set (`-symbolic` names from the Adwaita/GNOME icon theme) rendered via `GtkImage`/`gtk_image_new_from_icon_name`.

---

### A.1. Top bar & tab strip

Files: `VaultsRootView.swift` (top bar container), `VaultsTabStrip.swift` (the strip).

**Window** (`HostManagerController.swift`): default content `1100×720`; opens maximized to `screen.visibleFrame`; `minSize 900×560`. Titled/closable/miniaturizable/resizable. Title text hidden (`titleVisibility = .hidden`), `titlebarAppearsTransparent = true` — the custom strip occupies the full titlebar row, Termius-style. Window is kept opaque (`isOpaque = true`); `backgroundColor = NSColor(white: 0.122, alpha: 1)` (≈`#1F1F1F`, matching Claude's dark titlebar) which shows behind the traffic-light buttons. Native window tabbing disabled. GTK equivalent: `GtkHeaderBar` with an empty title widget, or a `GtkWindowHandle` custom titlebar; window min-size via `gtk_widget_set_size_request`.

**Top bar container** (`VaultsRootView.topBar`): `HStack(spacing: 8)`, fixed `height: 42`. Background `Color(NSColor.windowBackgroundColor)` (always opaque), `zIndex(1)` over content, followed by a `Divider()`. Order: tab strip (fills) · bell (`VaultsBellView`) · command-sidebar toggle · account menu (`AccountMenuButton`, trailing padding `6`).
- **Command-sidebar toggle:** SF Symbol `sidebar.right`, `.system(size: 14, weight: .medium)`, frame `28×28`. Color: disabled/non-terminal `Color.secondary.opacity(0.35)`; active `Color.accentColor`; else `.secondary`. Disabled (not hidden) outside terminal tabs.
- No gear/settings icon (Settings follows the macOS app-menu convention, ⌘,). GTK: this convention differs — a hamburger/primary menu button in the header bar is the Adwaita norm.

**Tab strip** (`VaultsTabStrip`): outer `HStack(spacing: 6)`, padding `.leading 8`, `.trailing 4`, `.vertical 4`.

**Nav "island"** (`navSegment`) — Vaults + SFTP pills grouped: `HStack(spacing: 4)`, padding `.horizontal 4 / .vertical 3`, background `RoundedRectangle(cornerRadius: 9)` fill `Color.secondary.opacity(0.10)`, stroke `Color.secondary.opacity(0.22)` `lineWidth 1`. This visually separates navigation from terminal tabs.

**Section pill metrics** (Vaults pill, SFTP pill, `sectionPill`):
- Layout `HStack(spacing: 5)`, label font `.system(size: 12, weight: .medium)`, padding `.horizontal 10 / .vertical 6`, background `RoundedRectangle(cornerRadius: 6)`.
- Selected: fill `Color.primary.opacity(0.12)`, label `Color.primary`; unselected: fill `Color.secondary.opacity(0.08)`, label `.secondary`.
- **Active highlight** (`ActivePillHighlight`): accent border `RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)` **plus** a bottom underline `Capsule().fill(Color.accentColor).frame(height: 2)` inset `.horizontal 10 / .bottom 1`.
- "soon" badge: `.system(size: 9, weight: .semibold)`, padding `.horizontal 4 / .vertical 1`, `Capsule` fill `Color.secondary.opacity(0.25)`, `.secondaryText`; whole pill `opacity 0.65` when not selected.
- Chevron (vault menu / `trailingChevron`): `chevron.down`, `.system(size: 9, weight: .semibold)`, `.secondaryText`.

**Vaults pill sync-cloud icon** (`syncCloudIcon`, driven by sync status) — SF Symbol + tint:

| Status | Symbol | Tint | GTK/Adwaita equivalent |
|---|---|---|---|
| disabled | `icloud.slash` | none (`.secondary`) | `weather-overcast-symbolic` / custom |
| idle (synced) | `checkmark.icloud.fill` | `.green` | `emblem-ok-symbolic` |
| syncing | `arrow.triangle.2.circlepath.icloud` (animated) | `.blue` | `emblem-synchronizing-symbolic` (spinning) |
| remote newer | `exclamationmark.icloud.fill` | `.orange` | `software-update-available-symbolic` |
| error | `exclamationmark.icloud.fill` | `.red` | `dialog-warning-symbolic` |

`SyncStatusIcon` while syncing: static `icloud.fill` (blue) with an inner `arrow.2.circlepath` (`.system(size: 7, weight: .bold)`, white, offset `y: 1`) rotating 0→360° linearly, 1s, forever.

**Section-pill icons:** SFTP = `folder`. (Vaults uses the sync-cloud above.)

**Divider between nav island and tabs** (`divider`): `Rectangle().fill(Color.secondary.opacity(0.35))`, `width 1, height 22`, `.horizontal 4` padding.

**Terminal tab chip** (`TerminalTabItem`): `HStack(spacing: 6)`, font `.system(size: 12, weight: isActive ? .semibold : .medium)`, padding `.horizontal 10 / .vertical 6`, `frame(minWidth: 110, maxWidth: 220, alignment: .leading)`, background `RoundedRectangle(cornerRadius: 6)`.
- Leading slot frame `14×14`: shows `terminal` symbol (`.system(size: 10, weight: .medium)`) when idle; an orange attention dot `Circle().fill(Color.orange).frame(width: 8, height: 8)` when `needsAttention`; blank while hovering (close button overlays).
- Fill: with custom color → `color.opacity(isActive ? 0.28 : 0.16)`; else active `Color.primary.opacity(0.12)`, inactive `Color.secondary.opacity(0.08)`.
- Active indicator: border `strokeBorder((color ?? .accentColor).opacity(0.9), lineWidth: 1.5)` + bottom `Capsule` underline `height 2`, inset `.horizontal 10 / .bottom 1` (mirrors section pills).
- ⌘-number badge (tabs 1–9): `"⌘\(number)"`, `.system(size: 10, weight: .medium, design: .rounded)`, `.tertiaryText`.
- Text label `.lineLimit(1)`, `.truncationMode(.tail)`, active `Color.primary` else `.secondary`.
- **Close button** (hover overlay, leading): `xmark` `.system(size: 9, weight: .bold)`, frame `14×14`, `Circle` background — hovering-close `Color.red` with white glyph, else `Color.secondary.opacity(0.20)` with `.primary` glyph; `.padding(.leading, 10)`.

**"+" new-tab button** (`newTabButton`): `plus` `.system(size: 13, weight: .medium)`, `.secondaryText`, padding `.horizontal 8 / .vertical 6`, stroke-only `RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.30), lineWidth: 1)`. Tooltip "New terminal tab".

**Tab color picker** (`TabColorPicker` popover): width `220`, padding `14`; 5-column `LazyVGrid` of `GridItem(.fixed(26), spacing: 10)`, spacing `10`; swatch `24×24` circles; selected = `Circle().strokeBorder(Color.primary, lineWidth: 2)`, unselected = `Color.secondary.opacity(0.25)` `lineWidth 1`; a "None" swatch uses `circle.slash`. Header "Tab Color" `.system(size: 12, weight: .semibold)`, `.secondaryText`.

**Tab context menu** items: Close Tab / Close Other Tabs / Close Tabs to the Right / Show All Tabs / Duplicate Tab / Save Session… / (separator) Rename Tab… / Tab Color…

---

### A.2. Dashboard + section sidebar (Vaults window content)

Files: `VaultsView.swift` (section sidebar + content switch), `VaultsToolbar.swift` (per-section top bar / empty states), `HostsSectionView.swift` (Hosts dashboard).

**Section sidebar** (`VaultsView.sidebar`): fixed `width: 180`, background `Color.black.opacity(0.18)`, followed by a `Divider()`. Content: `VStack(alignment: .leading, spacing: 2)`, padding `.horizontal 8 / .vertical 12`, trailing `Spacer()`. GTK: a `GtkListBox`/`GtkStackSidebar`-style rail; the semi-transparent black wash approximates a slightly darker sidebar than the content (`@sidebar_bg_color` in libadwaita).

**Section row** (`sidebarRow`): `HStack(spacing: 10)` — leading `Image(systemName:)` `frame(width: 18)`, label, `Spacer`. Font `.callout.weight(isSelected ? .semibold : .regular)`. Padding `.horizontal 12 / .vertical 8`. Background `RoundedRectangle(cornerRadius: 7)`:
- Selected: fill `Color.accentColor`, icon+label `Color.white`.
- Hover: fill `Color.primary.opacity(0.08)`.
- Idle: clear, icon+label `Color.primary.opacity(0.78)`.
- Label `.lineLimit(1).fixedSize()` (never truncates; sidebar width tuned to the longest label "Port Forwarding"/"Saved Sessions").

**Section list + icons** (SF Symbol → meaning → Adwaita equivalent):

| Section | Symbol | Meaning | Adwaita equivalent |
|---|---|---|---|
| Hosts | `server.rack` | saved SSH/Mosh/Telnet/serial hosts | `network-server-symbolic` |
| Saved Sessions | `rectangle.split.2x2` | saved multi-pane layouts | `view-grid-symbolic` |
| Teams | `person.2` | team vaults (later) | `system-users-symbolic` |
| Keychain | `key` | credentials | `dialog-password-symbolic` |
| Port Forwarding | `arrow.triangle.swap` | tunnel rules | `network-transmit-receive-symbolic` |
| Snippets | `curlybraces` | shell-script library | `utilities-terminal-symbolic` / `text-x-script-symbolic` |
| Known Hosts | `checkmark.shield` | `known_hosts` browser | `security-high-symbolic` |
| Logs | `clock` | session logs | `document-open-recent-symbolic` |

**Per-section toolbar** (`VaultsToolbar`): `HStack(spacing: 8)`, padding `.horizontal 14 / .vertical 8`. Three slots: `primary` "+ New…" button, `actions` (text+icon), `Spacer(minLength: 12)`, `trailing` (icon-only). Followed by a `Divider()`.
- **Primary button:** font `.callout.weight(.medium)`, icon+title `HStack(spacing: 6)`, padding `.leading 12 / .trailing 12 (or 10 with menu) / .vertical 6`, background `RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.18))`. Optional split-button menu: a `Divider().frame(height: 16).opacity(0.4)` then a `chevron.down` (`.caption`) menu, padding `.horizontal 8 / .vertical 6`. Disabled → `opacity 0.5`.
- **Action button:** `.callout`, `.secondaryText`, icon+title spacing `6`, padding `.horizontal 10 / .vertical 6`.
- **Trailing icon button:** `Image` `.system(size: 14)`, `.secondaryText`, padding `6`.

**Empty state** (`VaultsEmptyState`): icon `.system(size: 30)`, `.secondaryText`, in an `84×84` tile (`RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.12))`); title `.title3.weight(.semibold)`; subtitle `.secondaryText`, centered, `maxWidth 420`; optional badge `.caption.weight(.semibold)` in a `Capsule().fill(Color.secondary.opacity(0.2))`.

**Hosts dashboard** (`HostsSectionView`) selected metrics:
- **Search/quick-connect bar:** padding `.leading 14 / .trailing 6 / .vertical 6`; background `RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))` + stroke `0.20` `lineWidth 1`; outer padding `.horizontal 16 / .top 16`. Connect button `.system(size: 12, weight: .semibold)`, padding `.horizontal 14 / .vertical 6`, `RoundedRectangle(cornerRadius: 6)` — enabled `Color.accentColor` white text, disabled `Color.secondary.opacity(0.15)` `.secondary`. Clear icon `xmark.circle.fill`.
- **Host grid:** `GridItem(.flexible(minimum: 200), spacing: <spacing>)`, responsive column count.
- **Add-host tile "+":** `plus` `.system(size: 12, weight: .medium)`, `22×22`, stroke `RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.30), lineWidth: 1)`.
- **Account chip:** `person.fill` in a `Circle().stroke(Color.accentColor.opacity(0.9), lineWidth: 2).frame(26×26)`.
- **Breadcrumbs:** `chevron.right` `.caption2` separators; last crumb `.primary`, others `Color.accentColor`.
- **Toolbar icon tiles:** `28×28`, highlighted `Color.accentColor` glyph + `Color.accentColor.opacity(0.15)` fill, else `.secondary` glyph; stroke `Color.secondary.opacity(0.25)`.
- **Large empty/hero icon tiles:** `72×72` `RoundedRectangle(cornerRadius: 14)`; connection-popup avatar `44×44` `cornerRadius 9`.
- **"No matches" state:** `magnifyingglass` `.title2` `.tertiaryText`, title `.headline`, hint `.caption` `.secondaryText`.

Host connected-state status dot color/size: **not specified in source** in the read excerpts (the DESIGN.md mock shows a green `●` for a connected host, but the concrete metric was not located in `HostsSectionView`).

---

### A.3. Host / group editor sidebar

Files: `VaultsEditorSidebar.swift` (panel shell), `VaultsRootView.swift` (`VaultsHostEditorSidebar` wrapper), `HostEditorComponents.swift` (row/card components).

**Panel shell** (`VaultsEditorSidebar`): full-height trailing panel, fixed `width: 400`, background `Color(NSColor.windowBackgroundColor)`, leading-edge `Divider()`. To its left, a full-bleed scrim `Color.black.opacity(0.35)` (tap-to-dismiss). Slides in from the trailing edge with `.move(edge: .trailing).combined(with: .opacity)`, `.easeInOut(duration: 0.18)`, `zIndex(2)`. Autosaves on blur/change; closing is the commit point. GTK equivalent: an `AdwFlap`/overlay split or a `GtkRevealer` sliding from the right with a dimmed `GtkOverlay` behind it.

**Grouped card** (`EditorCard`): background `RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08))` + stroke `0.10` `lineWidth 0.5`. Optional title `.headline`, `.primary`, padding `.horizontal 14 / .top 14 / .bottom 10`. Fields `VStack(spacing: 8)`, padding `.horizontal 12 / .bottom 12`.

**Field row shell** (`RowShell`, used by text/int/secure/picker/bool/expand rows): padding `.horizontal 12 / .vertical 11`, `RoundedRectangle(cornerRadius: 8)`. Border: idle `Color.secondary.opacity(0.22)` `lineWidth 1`; hover (interactive) fill `Color.secondary.opacity(0.10)` + border `0.35`; focused `Color.accentColor.opacity(0.7)` `lineWidth 1.5`. Leading field icon `.system(size: 14)`, `.secondaryText`, `frame(width: 18)`; row content spacing `10`. Hover cursor: I-beam for text rows, pointing-hand for pickers/toggles/expanders.

**Row types:**
- **Text row** (`EditorTextRow`): plain `TextField`, `.body` (or monospaced). `EditorPortField` shows placeholder `22`; `EditorIntRow` treats `0` as unset (placeholder shown).
- **Secure row** (`EditorSecureRow`): AppKit-backed `NSSecureTextField`; reveal toggle `eye`/`eye.slash` (`.secondaryText`).
- **Picker row** (`EditorPickerRow`): trailing value "capsule" — label `.callout` + `chevron.up.chevron.down` `.caption2` `.secondaryText`, padding `.horizontal 8 / .vertical 3`, `RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlColor))`. Opens a popover list (`minWidth 220`, padding `6`); rows padding `.horizontal 10 / .vertical 6`, checkmark `Color.accentColor`, each `.listRowHover()`. Closes the moment the value changes (click or ↑/↓ cycle).
- **Bool row** (`EditorBoolRow`): real macOS `Toggle(.switch)`, `.controlSize(.small)`, whole row is the tap target. GTK: `AdwSwitchRow`.
- **Expand row** (`EditorExpandRow`): trailing summary `.callout` `.secondaryText` + `chevron.up`/`chevron.down` `.caption2` `.tertiaryText`; expanded content indented `.horizontal 12 / .bottom 4`.
- **Subheading** (`EditorSubheading`): uppercased `.caption2.weight(.semibold)`, `tracking 0.5`, `.secondaryText`.

**Editor field icons** (from `EditorTextRow` usages, representative — meanings from field names): `number.square` (port). Others (hostname, label, group, tags, note, username, identity file, etc.) pass their symbol per call site in `HostEditorView.swift` (not enumerated here). GTK: map each to a symbolic icon or use `AdwEntryRow`/`AdwActionRow` which conventionally omit per-field icons.

**Keyboard:** Tab/Shift+Tab custom focus chain (AppKit event monitor), ↑/↓ cycles focused pickers, Space/Return activates toggles/expanders. Autosave flashes "Saved" on blur/change (no explicit Save button).

---

### A.4. Terminal split headers (per-pane chrome)

File: `VaultsSplitTreeView.swift`.

**Multi-pane leaf card:** shown only when a tab has >1 pane. `VStack{ header; surface }` clipped to `RoundedRectangle(cornerRadius: 8)`, `.padding(5)`. Border:
- Focused pane: `Color.accentColor`, solid, `lineWidth 1.5`.
- Unfocused pane: `Color.secondary.opacity(0.4)`, dashed `StrokeStyle(lineWidth: 1, dash: [4, 3])`.

Single-pane tabs get **no** header and no border.

**Pane header** (`header`): `HStack(spacing: 6)`, padding `.horizontal 10 / .vertical 5`, background `Color.black.opacity(0.55)` (solid dark scrim so the title stays legible over any background image). The icon+title region is a drag handle (open/closed-hand cursor).
- Leading icon: `terminal` `.system(size: 10)`, `.white.opacity(0.75)`.
- Title: `.system(size: 11, weight: .semibold)`, `.white.opacity(0.95)`, `.lineLimit(1)`, `.truncationMode(.tail)`, fills flexible width.
- Header buttons (`headerButton`, `20×18`, `.system(size: 11, weight: .medium)`, idle `.white.opacity(0.75)`, active `Color.green`):
  - `dot.radiowaves.left.and.right` — broadcast input to all panes (Adwaita: `network-wireless-symbolic` / custom)
  - `sidebar.left` — Focus mode (⌘⇧M) (Adwaita: `sidebar-show-symbolic`)
  - **Close** (`PaneCloseButton`): `xmark` `.system(size: 11, weight: .medium)`, `20×18`; hover turns `RoundedRectangle(cornerRadius: 4).fill(Color.red)` with white glyph, else `.white.opacity(0.75)`.

**Split divider:** color from `ghostty.config.splitDividerColor` (terminal-engine config, not a fixed value); resize increments `1×1`.

**Split chooser overlay** (`SplitChooserView`, shown over a fresh empty pane): backdrop `Color(NSColor.windowBackgroundColor).opacity(0.96)`; drop-target tint `Color.accentColor.opacity(0.12)`. Header icon `rectangle.split.2x1` `.system(size: 26, weight: .light)` `.secondaryText`, title `.headline`, subtitle `.caption` `.secondaryText`. Search field: `magnifyingglass` `.secondaryText` + plain `TextField`, padding `.horizontal 12 / .vertical 9`, `RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))`. Content `maxWidth 460`, padding `24`, spacing `14`. Rows (`row`): icon `frame(width: 18)` `.secondaryText`, title `.medium`, subtitle `.caption`, trailing `.caption2` `.tertiaryText`; highlighted row fill `Color.secondary.opacity(0.18)`, `cornerRadius 8`, padding `.horizontal 12 / .vertical 8`. Tip line `.caption2` `.tertiaryText`. Arrow-key nav (↓=125, ↑=126, Return=36/76, Esc=53).

---

### A.5. Command sidebar (right-hand Snippets / History / Themes)

File: `VaultsCommandSidebar.swift`. Only rendered on terminal tabs; slides from trailing edge.

**Container:** fixed `width: 300`, background `Color(NSColor.windowBackgroundColor)`, leading `Divider()`. GTK: a right-docked `AdwFlap`/`GtkRevealer`.

**Tab switcher** (`switcher`): `HStack(spacing: 6)`, padding `.horizontal 12 / .vertical 10`, then a `Divider()`. Each tab button: icon `.system(size: 14, weight: .medium)`, `frame(30×26)`, `RoundedRectangle(cornerRadius: 7)` — selected fill `Color.accentColor` + white glyph, else clear + `.secondary`.

**Tab icons:** Snippets `curlybraces`, History (Shell history) `clock`, Themes & font `paintpalette`. GTK: `text-x-script-symbolic`, `document-open-recent-symbolic`, `applications-graphics-symbolic`.

**Command row** (`CommandRow`, shared by Snippets & History): `HStack(spacing: 6)`, padding `.horizontal 12 / .vertical 7` (single-line) or `8` (two-line). Hover tints background `RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))` (row never resizes; actions float in a trailing overlay).
- Pin toggle: `pin.fill`/`pin` `.system(size: 10)`, pinned `Color.accentColor` else `.secondary`; hidden until pinned/hover.
- Primary text: history = `.system(size: 12, design: .monospaced)`; snippet name = `.system(size: 12, weight: .medium)`. Secondary line: `.system(size: 11, design: .monospaced)`, `.secondaryText`.
- Hover actions (trailing overlay with a `LinearGradient` windowBackground fade so text doesn't bleed): "add to snippet" `curlybraces` button `.system(size: 11, weight: .medium)`, padding `.horizontal 7 / .vertical 4`, `RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.22))`; **Run** pill (accent fill, white text) and **Paste** pill (`Color.primary.opacity(0.22)`), both `.system(size: 11, weight: .semibold)`, padding `.horizontal 9 / .vertical 4`, `cornerRadius 6`. Disabled when no active terminal (`opacity 0.4`).

**Sidebar search field** (`SidebarSearchField`): `magnifyingglass` `.system(size: 12)` `.secondaryText` + `TextField` `.system(size: 12)`, padding `.horizontal 10 / .vertical 7`, `RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07))`, outer padding `.horizontal 12 / .top 10`.

**Snippets tab controls:** "New Snippet" button (`curlybraces` + label `.system(size: 12, weight: .medium)`), padding `.horizontal 10 / .vertical 6`, `RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08))`. Sort button `arrow.down`/`arrow.up`, `frame(30×28)`, same fill. Inline editor: rounded-border `TextField`, `TextEditor` monospaced `minHeight 120` with `RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3))`; Save = `.borderedProminent`, `.controlSize(.small)`.

**Themes tab:** collapsible Font section (`chevron.down`/`chevron.right`, header `.system(size: 12, weight: .semibold)`). Font-size steppers `minus`/`plus` `.system(size: 11, weight: .semibold)`, `frame(26×24)`, `RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1))`, size label monospaced `minWidth 26`. Theme rows: `ThemeSwatch` `48×34` mini-terminal thumbnail (theme background + colored "text" bars from palette indices + a cursor, `cornerRadius 5`, stroke `Color.secondary.opacity(0.25)` `lineWidth 0.5`) or `circle.dashed` `34×22` for "Default (no theme)"; selected row fill `Color.accentColor.opacity(0.18)` + `checkmark` `.tint`; each row `.listRowHover(cornerRadius: 8)`.

---

### A.6. Overlays & dialogs

- **Host-editor side panel & scrim:** see A.3 (`Color.black.opacity(0.35)` scrim, `400`-wide panel).
- **Rename Tab dialog:** presented via `SarvAlert.present` with an input field — the app-wide centered-logo alert component (all dialogs route through `SarvAlert`/`DeleteConfirmation`). Concrete SarvAlert visual metrics are defined outside these files — **not specified in source here.** GTK: `AdwMessageDialog`/`AdwAlertDialog`.
- **All-tabs overview** (`VaultsAllTabsView`): overlaid with `.transition(.opacity)`; internal metrics in `VaultsAllTabsView.swift` — not covered by the requested file set.
- **Tooltips:** a single window-level `TooltipOverlay` layer above everything, resolved in the `TooltipPresenter.space` coordinate space; per-control `.hoverTip("…")` / `.help("…")`. GTK: `gtk_widget_set_tooltip_text`.
- **Serial-connect:** presented as a `.sheet` (`SerialConnectSheet`).
- **SSH connection popup** (`SSHConnectionView`): overlaid per-pane, keyed by surface id; opaque so it must sit under the tab strip (`zIndex` management in `VaultsRootView`). Card corner radii in `HostsSectionView` around `10–12`; avatar tile `44×44 cornerRadius 9`. Full internal spec lives in `SSH/`/`HostsSectionView.swift` beyond the requested set.

---

### A.7. macOS-specific styling → GTK translation summary

| macOS mechanism | Where used | GTK/Adwaita equivalent |
|---|---|---|
| SF Symbols (`Image(systemName:)`) | every icon | GNOME/Adwaita **symbolic** icons (`-symbolic`) via `GtkImage`; commission custom symbolics for cloud-sync states |
| System accent (`Color.accentColor`) | selection, active borders, primary buttons | libadwaita `@accent_bg_color`/`@accent_color` (1.6+ runtime accent) |
| `NSColor.windowBackgroundColor` / `controlColor` | panel & value-chip backgrounds | `@window_bg_color`, `@view_bg_color`, `@card_bg_color` |
| `.secondary`/`.primary.opacity(...)` fills | pills, cards, hovers | CSS `rgba()` on named colors, or `alpha()` in CSS |
| Continuous (squircle) corners | all rounded rects | CSS `border-radius` (circular approximation) at the same px |
| Opaque window + window-level `NSImageView` shared background behind translucent Metal panes | `HostManagerController` | GTK: a background `GtkPicture` under a `GtkGLArea`/terminal widget in a `GtkOverlay`; true per-widget translucency is limited — likely a solid theme background |
| Transparent titlebar hosting a custom strip | top bar | `GtkHeaderBar` with custom title widget, or full custom `GtkWindowHandle` titlebar |
| `NSVisualEffectView`/vibrancy | **not used** in these host-manager surfaces (opaque window by design) | n/a — flat opaque surfaces, so no `.blur`/material to reproduce |
| AppKit `NSSecureTextField` (SwiftUI secure field not editable) | password rows | `GtkPasswordEntry` (natively editable — simpler on GTK) |
| Touch-ID / Keychain unlock affordances | (per DESIGN.md §9.5) | libsecret + a "Unlock" affordance; no biometric equivalent assumed |

**Note on vibrancy:** the Vaults window is deliberately **opaque** (`window.isOpaque = true`), and no `NSVisualEffectView`/material is used in the host-manager view layer. The only "translucency" is (a) the optional shared background image drawn behind terminal panes at `imageVisibility` alpha, and (b) the flat `Color.*.opacity()` fills documented above. A GTK port does not need to reproduce macOS vibrancy/blur for these surfaces.

---

## Appendix B. Recommended port order (dependency-first)

This is the sequence in which the GTK/Zig team should build the Vaults subsystems so every phase depends only on earlier ones. Each entry cites the roadmap section by number + title, its hard dependencies, a one-line rationale, and an effort/risk flag (S/M/L; **HIGH-RISK** = crypto/no-clean-Linux-equivalent). The five reliability fixes (§1–§5) are slotted where their prerequisites first exist.

### Two blockers with no clean Linux equivalent — design these first

- **§16 Secure-Enclave-backed at-rest encryption** and **§19 TeamVault zero-knowledge crypto** are the only pieces with *no* drop-in Linux analog (no Secure Enclave, no Keychain). §16 lands in Phase 0 because five stores can't ship without it; **§19's wire crypto should be spiked in Phase 0 too** even though the feature lands last — get the X25519/AES-GCM/HKDF byte layout and the secret-storage ladder (libsecret → TPM2 → `0600` file) proven against the real server early, so a wrong salt/concatenation order isn't discovered in Phase 5. Non-negotiable rule for both: the data key stays **random**, never derived from MAC/hostname/machine-id.

---

### Phase 0 — Window shell + persistence + encryption foundation
Everything else mounts inside this shell and reads/writes through these two stores.

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§6 Vaults window & navigation shell** | base GTK apprt; core `needsConfirmQuit` | One `GtkApplicationWindow` with dashboard↔terminal swap + plaintext `session.json` is the container for all UI. | M |
| **§16 Local data encryption at rest** | secret backend (libsecret/TPM/file) | The `EncryptedStore` envelope + key-wrap ladder that hosts/snippets/port-forwards/sessions/pinned-history all depend on; blocking, so do it before any encrypted store. | L · **HIGH-RISK** |
| **§21 (infra slices) notifications + new-tab/split cwd** | §6 shell | App-level notification stream (bell + D-Bus) is consumed by §9/§14/§15/§20; the working-directory policy is pure logic needed by the very first tab spawn. | M |
| **§19 crypto spike (design only)** | — | Prototype `VaultCrypto` wire formats + secret storage now against the local Vault API; de-risk the hardest interop before Phase 5. | S (spike) · **HIGH-RISK** |

### Phase 1 — Hosts, groups, import & keys
The connection inventory the whole product is built around.

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§7 Saved hosts, groups & tags** | §6, §16 | `SavedHost`/`HostGroup` + encrypted `hosts.json`/`groups.json` — the schema nearly every later subsystem reads. | M |
| **§8 Host import & SSH config discovery** | §7 | Pure string parsers writing into the §7 stores; cleanest 1:1 port, no new deps. | S |
| **§10 SSH key management** | §6; `ssh-keygen` | `~/.ssh` scanner + generator; standalone, and its `identityFile` binding feeds §9. | S |

### Phase 2 — Tabs, splits, sessions + tab-strip reliability
The primary workspace and its persistence, plus the three reliability fixes whose prerequisites now exist.

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§11 Session model & persistence** | §6, §16, §7 (SSH panes ref `hostID`) | `SavedSession`/`PaneNode` schema + restore-on-launch; the snapshot type §1 reuses. | M |
| **§12 Splits, panes & focus mode** | §6, §11 | Split tree, drag/detach, focus mode; SSH-popup overlay wired in Phase 3. | M |
| **§17 Command palette & host search** | §7, §8 | Shares its search/index model with the §12 split chooser — build the model once here. | S |
| **§2 Tab-chip close/select/drag hit detection** | §6 tab strip | The single hit-test authority for the chip strip that §12's reorder/detach relies on. | S |
| **§3 Shell-independent pane titles** | §12 panes; foreground-pid API | One pure title-derivation fn shared by pane header + focus sidebar; needs panes to exist. | S |
| **§1 Release closed-tab surfaces immediately** | §11 snapshot, §12 close paths | The leak fix (snapshot-and-free) requires the value snapshot type and the real close paths. | S |

### Phase 3 — SSH connection flow + close confirmation
The staged connect, then the guards that route every close through a busy-check.

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§9 SSH connection flow** | §7 hosts, §10 keys, §12 per-pane overlay; known-hosts, askpass | Staged spawn, host-key pre-flight, detection state machine, auto-reconnect — the core SSH UX. | L |
| **§4 Confirm before closing tab/pane w/ running process** | §6/§11/§12 close paths, §9 (SSH = busy), core `needsConfirmQuit` | One shared checkpoint at the action-dispatch layer; needs all close paths + SSH busy-state present. | S |
| **§5 Make close-confirmation impossible to bypass** | §4 | Visibility hardening: private `perform*` closers + `request*` wrappers + one named opt-out. | S |

### Phase 4 — Vault productivity features
Independent features that all ride on hosts (§7), askpass (§9), and encryption (§16).

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§14 Port forwarding** | §7, §9 askpass, §16 | `ssh -N` tunnel manager keyed off saved hosts; encrypted `portforwards.json`. | M |
| **§15 Files / SFTP browser** | §7, §9 askpass | Dual-pane manager shelling to `ssh`/`sftp`/`scp`; the cancellable process-holder is the main port risk. | L |
| **§13 Snippets** | §6, §16 (sync in Phase 5) | Command library, encrypted at rest; small and self-contained. | S |
| **§18 Activity log / shell history / pinned / serial** | §6, §16 (pinned), §13 (history→snippet) | Four small features; activity log is plaintext, pinned-history reuses the §16 key path. | M |

### Phase 5 — Cloud: TeamVault + Settings/Sync
The only server-talking and cross-store subsystems — everything they touch now exists.

| Section | Hard deps | Rationale | Flag |
|---|---|---|---|
| **§19 TeamVault (shared team vaults)** | §7 host shapes, §16 crypto/secret patterns, Phase-0 spike | Zero-knowledge E2E shared vault; HTTP/JSON is trivial, the crypto interop is the whole risk. | L · **HIGH-RISK** |
| **§20 Settings, sync & rebindable keybinds** | §6, §16 crypto, all stores (§7/§11/§13/§14), §21 notifications, keybind routing | E2E settings/hosts sync + `AppKeybindStore` + native Settings UI; sync must serialize every earlier store, so it goes last. | L · **HIGH-RISK** (sync crypto) |

---

**Critical path:** §6 → §16 → §7 → §11 → §12 → §9 → (§14/§15/§13/§18) → §19/§20. **Parallelizable within a phase:** §8/§10 (Phase 1); §2/§3 vs §17 (Phase 2); §13/§14/§15/§18 (Phase 4). **Coupling to flag for planners:** §12's split chooser and §17's palette share one search model — assign them together; §4's "busy" test spans §9 (SSH) and the core `needsConfirmQuit`, so it cannot precede §9; and the §16 + §19 + §20 crypto is one cross-cutting concern (Secret Service / TPM / `0600`-file ladder) — solve the key-storage backend **once** in Phase 0 and let all three inherit it.
