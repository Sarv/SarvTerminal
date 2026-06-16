import AppKit
import Combine
import SwiftUI
import GhosttyKit
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    /// Drag payload content type for a Vaults terminal tab.
    static let vaultsTabID = UTType(exportedAs: "com.sarvterminal.vaultsTabID")
}

/// Transferable drag payload for a terminal tab (modern SwiftUI
/// `.draggable`/`.dropDestination` API). Used to reorder tab chips and to
/// inject a single-terminal tab into a split pane.
struct TabDragID: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vaultsTabID)
    }
}

/// Single-window tab model for the Vaults window.
///
/// The window shows EITHER the Vaults dashboard OR one embedded terminal tab
/// at a time. Each terminal tab owns a `SplitTree` of `Ghostty.SurfaceView`s
/// (one or more split panes) created directly — there are no separate terminal
/// windows and no native macOS window tabbing. See the `vaults-window-tabbing`
/// memory for the history.
///
/// Split handling (⌘D / ⌘⇧D etc.) is ported from `BaseTerminalController`:
/// libghostty posts notifications targeting the focused surface and we mutate
/// the owning tab's split tree.
final class VaultsTabsModel: ObservableObject {
    static let shared = VaultsTabsModel()

    /// A single terminal tab: a split tree of surfaces + its live title.
    final class TerminalTab: ObservableObject, Identifiable {
        let id = UUID()
        @Published var surfaceTree: SplitTree<Ghostty.SurfaceView>
        /// Auto-assigned base label ("Terminal", host label, …).
        @Published var title: String
        /// User-set name from "Rename Tab…", overrides `title` when present.
        @Published var customName: String?
        /// Optional accent color set via the "Tab Color" menu.
        @Published var color: Color?
        /// The command this tab launched with (e.g. an `ssh …` invocation), so
        /// "Duplicate Tab" can re-run it. nil for a plain local shell.
        var launchCommand: String?
        /// When true, input typed in the focused pane is mirrored to every
        /// other pane in the tab.
        @Published var broadcasting: Bool = false
        /// Sidebar display-name overrides per pane. A duplicated pane gets the
        /// source pane's name here so it doesn't show a bare "~" before its
        /// shell sets a title.
        @Published var paneTitleOverrides: [UUID: String] = [:]
        /// The surface within this tab that currently has focus — used as the
        /// anchor when splitting from the palette.
        weak var focusedSurface: Ghostty.SurfaceView?

        /// The label shown on the chip (custom name wins).
        var displayName: String {
            if let customName, !customName.isEmpty { return customName }
            return title
        }

        init(surface: Ghostty.SurfaceView, name: String) {
            self.surfaceTree = .init(view: surface)
            self.title = name
        }
    }

    /// Preset tab colors (matches Ghostty's tab-color palette).
    struct TabColorOption: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    static let tabColorOptions: [TabColorOption] = [
        .init(id: "blue", name: "Blue", color: .blue),
        .init(id: "purple", name: "Purple", color: .purple),
        .init(id: "pink", name: "Pink", color: .pink),
        .init(id: "red", name: "Red", color: .red),
        .init(id: "orange", name: "Orange", color: .orange),
        .init(id: "yellow", name: "Yellow", color: .yellow),
        .init(id: "green", name: "Green", color: .green),
        .init(id: "teal", name: "Teal", color: .teal),
        .init(id: "gray", name: "Gray", color: .gray),
    ]

    /// What the window's content area currently shows.
    enum Selection: Equatable {
        case dashboard
        case terminal(UUID)
    }

    @Published private(set) var terminals: [TerminalTab] = []
    @Published var selection: Selection = .dashboard
    /// Surface IDs of freshly-split panes that are showing the inline chooser
    /// (blank pane) and waiting for the user to pick what to run.
    @Published private(set) var awaitingChoice: Set<UUID> = []
    /// Focus mode (⌘⇧M): show the active tab as a sidebar list of panes + one
    /// main pane, instead of the split grid. It's just an alternate view of the
    /// same split tree, so toggling back restores the grid.
    @Published var focusMode: Bool = false
    /// Which pane fills the main area in focus mode.
    @Published var focusModeSurfaceID: UUID?
    /// Show the "all tabs" overview grid.
    @Published var showAllTabs: Bool = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        installObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Queries

    var activeTerminal: TerminalTab? {
        guard case let .terminal(id) = selection else { return nil }
        return terminals.first { $0.id == id }
    }

    private func tab(containing surface: Ghostty.SurfaceView) -> TerminalTab? {
        terminals.first { $0.surfaceTree.contains(surface) }
    }

    // MARK: - Tab mutations

    /// Create a new embedded terminal tab, select it, and bring the Vaults
    /// window forward. `name` is the base tab label ("Terminal" for a local
    /// shell, the host label for SSH) — deduped with "(1)", "(2)", … suffixes.
    /// Optionally inject a command once the shell is ready.
    @discardableResult
    func newTerminal(command: String? = nil, name: String = "Terminal") -> TerminalTab? {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return nil }
        let surface = Ghostty.SurfaceView(app)
        let tab = TerminalTab(surface: surface, name: uniqueTabName(base: name))
        tab.launchCommand = command
        terminals.append(tab)
        selection = .terminal(tab.id)
        HostManagerController.shared.show()
        Ghostty.moveFocus(to: surface)

        if let command {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                surface.surfaceModel?.sendText("\(command)\n")
            }
        }
        return tab
    }

    /// A tab label unique among open tabs: `base`, else `base (1)`, `base (2)`…
    private func uniqueTabName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "Terminal" : trimmed
        let existing = Set(terminals.map { $0.displayName })
        if !existing.contains(name) { return name }
        var n = 1
        while existing.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// Split the active terminal tab in `direction` and present the inline
    /// chooser ("blank pane") on the new pane. The new surface spawns a local
    /// shell immediately (hidden behind the chooser); resolving the choice
    /// either reveals it (Local Terminal) or runs an SSH command in it.
    func splitAwaitingChoice(direction: SplitTree<Ghostty.SurfaceView>.NewDirection) {
        guard let tab = activeTerminal,
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        let anchor = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        guard let anchor else { return }
        let newView = Ghostty.SurfaceView(app)
        guard let newTree = try? tab.surfaceTree.inserting(view: newView, at: anchor, direction: direction) else { return }
        tab.surfaceTree = newTree
        // Don't steal focus to the surface — the chooser overlay wants it.
        awaitingChoice.insert(newView.id)
    }

    /// Resolve a pending split pane's chooser selection.
    func resolveChoice(surface: Ghostty.SurfaceView, action: PaletteAction) {
        switch action {
        case .serial:
            // Not supported in a split; leave the chooser up.
            return
        case .localTerminal:
            dismissChoice(surface: surface)
        case .host(let host):
            send(host.sshCommand, to: surface)
            dismissChoice(surface: surface)
        case .quickConnect(let query):
            let target = query.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return }
            let command = target.hasPrefix("ssh ") ? target : "ssh \(target)"
            send(command, to: surface)
            dismissChoice(surface: surface)
        }
    }

    /// Reveal the already-running local shell behind the chooser (Local
    /// Terminal choice).
    func dismissChoice(surface: Ghostty.SurfaceView) {
        awaitingChoice.remove(surface.id)
        Ghostty.moveFocus(to: surface)
    }

    /// Replace an awaiting (chooser) pane with a single-terminal tab dragged
    /// from the strip — the empty split becomes that tab, and it's removed from
    /// the strip.
    func injectTabIntoAwaiting(awaiting: Ghostty.SurfaceView, draggedTabID: UUID) {
        guard let destTab = tab(containing: awaiting),
              let awaitingNode = destTab.surfaceTree.root?.node(view: awaiting),
              let srcIdx = terminals.firstIndex(where: { $0.id == draggedTabID }),
              terminals[srcIdx].id != destTab.id else { return }
        let srcTab = terminals[srcIdx]
        let leaves = srcTab.surfaceTree.root?.leaves() ?? []
        guard leaves.count == 1, let draggedSurface = leaves.first else { return }
        guard let newTree = try? destTab.surfaceTree.replacing(
            node: awaitingNode, with: .leaf(view: draggedSurface)) else { return }
        awaitingChoice.remove(awaiting.id)
        terminals.remove(at: srcIdx)
        destTab.surfaceTree = newTree
        Ghostty.moveFocus(to: draggedSurface)
    }

    /// Close a single split pane (from its header's × button). Collapses the
    /// split, or closes the tab if it was the last pane.
    func closePane(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        awaitingChoice.remove(surface.id)
        let remaining = tab.surfaceTree.removing(node)
        if remaining.isEmpty {
            closeTerminal(tab.id)
        } else {
            tab.surfaceTree = remaining
            if let next = remaining.root?.leftmostLeaf() {
                Ghostty.moveFocus(to: next)
            }
        }
    }

    /// Duplicate a single pane (focus-mode sidebar → Duplicate). Splits off a
    /// new pane next to it. If the source is still an unresolved "blank" pane,
    /// the duplicate is also blank (shows the chooser); otherwise it re-runs the
    /// tab's launch command (SSH) or `cd`s a local shell to the source's cwd.
    func duplicatePane(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        // Split along the pane's longer axis so the new pane gets usable space.
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection =
            surface.bounds.width >= surface.bounds.height ? .right : .down
        let newView = Ghostty.SurfaceView(app)
        let sourceAwaiting = awaitingChoice.contains(surface.id)
        if !sourceAwaiting {
            // Show the source pane's name in the sidebar immediately (the new
            // shell's own title arrives later and can read as a bare "~").
            let sourceName = tab.paneTitleOverrides[surface.id]
                ?? (surface.title.isEmpty ? "Terminal" : surface.title)
            tab.paneTitleOverrides[newView.id] = sourceName
        }
        guard let newTree = try? tab.surfaceTree.inserting(
            view: newView, at: surface, direction: direction) else { return }
        tab.surfaceTree = newTree
        if sourceAwaiting {
            // Mirror the blank/selection state — don't steal focus or run a
            // shell command; the chooser overlay handles it.
            awaitingChoice.insert(newView.id)
            return
        }
        Ghostty.moveFocus(to: newView)
        if let command = tab.launchCommand {
            send(command, to: newView)
        } else if let cwd = surface.pwd, !cwd.isEmpty {
            send("cd \"\(cwd)\"", to: newView)
        }
    }

    /// Toggle "focus mode" (zoom) on a pane — the pane fills the tab; toggle
    /// again to restore the split layout.
    func toggleZoom(surface: Ghostty.SurfaceView) {
        guard let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        if tab.surfaceTree.zoomed != nil {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: nil)
        } else {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: node)
        }
    }

    // MARK: - Tab drag & drop

    /// Reorder: move the dragged tab onto `targetID`'s slot — works in both
    /// directions (dragging right inserts after the target, dragging left
    /// inserts before it, so the dropped tab lands where you dropped it).
    /// Animated so chips slide into place instead of snapping.
    func moveTab(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = terminals.firstIndex(where: { $0.id == draggedID }),
              let originalTo = terminals.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            let tab = terminals.remove(at: from)
            guard let newTo = terminals.firstIndex(where: { $0.id == targetID }) else {
                terminals.append(tab)
                return
            }
            // Dragging rightward (from before the target) → land after it;
            // dragging leftward → land before it.
            let insertIndex = from < originalTo ? newTo + 1 : newTo
            terminals.insert(tab, at: insertIndex)
        }
    }

    /// Inject a single-terminal tab into another tab's split, at
    /// `destinationSurface` in the drop `zone`'s direction. Multi-pane source
    /// tabs are rejected (a tab that already has a split can't be dragged in).
    func injectTab(_ sourceTabID: UUID, into destinationSurface: Ghostty.SurfaceView, zone: TerminalSplitDropZone) {
        guard let sourceIdx = terminals.firstIndex(where: { $0.id == sourceTabID }) else { return }
        let sourceTab = terminals[sourceIdx]
        let leaves = sourceTab.surfaceTree.root?.leaves() ?? []
        guard leaves.count == 1, let surface = leaves.first else { return }
        guard let destTab = tab(containing: destinationSurface), destTab.id != sourceTabID else { return }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        guard let newTree = try? destTab.surfaceTree.inserting(view: surface, at: destinationSurface, direction: direction) else { return }
        // Remove the source tab WITHOUT freeing the surface — it now lives in
        // the destination tab's tree.
        terminals.remove(at: sourceIdx)
        destTab.surfaceTree = newTree
        selection = .terminal(destTab.id)
        Ghostty.moveFocus(to: surface)
    }

    /// Toggle input broadcasting for the pane's tab.
    func toggleBroadcast(surface: Ghostty.SurfaceView) {
        tab(containing: surface)?.broadcasting.toggle()
    }

    func isBroadcasting(surface: Ghostty.SurfaceView) -> Bool {
        tab(containing: surface)?.broadcasting ?? false
    }

    /// When the active tab is broadcasting, send `event` to every OTHER pane
    /// (not the one that natively handles it). The focused pane keeps its
    /// native key handling — including IME, backspace, and ⌘K — so we DON'T
    /// consume the event. The other panes get the key via the core
    /// (`ghostty_surface_key`), bypassing the NSView/IME pipeline that caused
    /// the doubled input. No-op (and irrelevant) when not broadcasting or the
    /// tab has a single pane.
    func broadcastKeyEvent(_ event: NSEvent) {
        guard let tab = activeTerminal, tab.broadcasting else { return }
        let panes = tab.surfaceTree.root?.leaves() ?? []
        guard panes.count > 1 else { return }

        // The pane that will handle this event natively (the first responder).
        let responder = event.window?.firstResponder as? NSView
        let source = panes.first { pane in
            guard let responder else { return false }
            return responder === pane || responder.isDescendant(of: pane)
        }

        for pane in panes where pane !== source {
            guard let surface = pane.surface else { continue }
            sendKeyToCore(event, surface: surface)
        }
    }

    /// Send a key event straight to a surface's core, mirroring the encode
    /// rules in `SurfaceView.keyAction`: pass `text` only for plain printable
    /// characters; let Ghostty encode control keys (backspace, ctrl-c, ctrl-l,
    /// arrows…) from the keycode + mods.
    private func sendKeyToCore(_ event: NSEvent, surface: ghostty_surface_t) {
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        var keyEvent = event.ghosttyKeyEvent(action)
        let text = event.characters ?? ""
        if let cp = text.utf8.first, cp >= 0x20, cp != 0x7f {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func send(_ command: String, to surface: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            surface.surfaceModel?.sendText("\(command)\n")
        }
    }

    /// Show the dashboard at the given section (Vaults / SFTP / SCP).
    func selectDashboard(section: HostManagerSelection.Section) {
        HostManagerSelection.shared.section = section
        selection = .dashboard
    }

    func selectTerminal(_ id: UUID) {
        selection = .terminal(id)
    }

    /// Select the Nth terminal tab (0-based) — backs ⌘1…⌘8.
    func selectTab(index: Int) {
        guard terminals.indices.contains(index) else { return }
        selection = .terminal(terminals[index].id)
    }

    // MARK: - Keybind-driven navigation (Ghostty defaults; wired in AppDelegate)
    //
    // These mirror Ghostty's macOS default keybinds. libghostty normally posts
    // these actions to a BaseTerminalController / native tab group — neither of
    // which the embedded Vaults window is — so the core handlers no-op and we
    // perform the equivalent here.

    /// `next_tab` / `previous_tab` — cycle the selection with wraparound.
    func cycleTab(_ delta: Int) {
        guard !terminals.isEmpty else { return }
        let current: Int = {
            if case let .terminal(id) = selection,
               let idx = terminals.firstIndex(where: { $0.id == id }) { return idx }
            return 0
        }()
        let n = terminals.count
        let next = ((current + delta) % n + n) % n
        selection = .terminal(terminals[next].id)
    }

    /// `last_tab` — select the final tab.
    func selectLastTab() {
        guard let last = terminals.last else { return }
        selection = .terminal(last.id)
    }

    /// `goto_split` — move keyboard focus to the adjacent split in the active tab.
    func focusSplit(_ direction: Ghostty.SplitFocusDirection) {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf(),
              let node = tab.surfaceTree.root?.node(view: current),
              let next = tab.surfaceTree.focusTarget(
                for: direction.toSplitTreeFocusDirection(), from: node)
        else { return }
        Ghostty.moveFocus(to: next, from: current)
    }

    /// `toggle_split_zoom` — on the active tab's focused pane.
    func toggleZoomActive() {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        else { return }
        toggleZoom(surface: current)
    }

    /// `close_surface` — close the active tab's focused pane (closes the tab if
    /// it was the last pane).
    func closeFocusedPane() {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf()
        else { return }
        closePane(surface: current)
    }

    /// `close_tab:this` — close the whole active tab.
    func closeActiveTab() {
        if case let .terminal(id) = selection { closeTerminal(id) }
    }

    /// `resize_split` — grow the active pane by `amount` points in `direction`.
    func resizeSplit(_ direction: SplitTree<Ghostty.SurfaceView>.Spatial.Direction, amount: UInt16) {
        guard let tab = activeTerminal,
              let current = tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf(),
              let node = tab.surfaceTree.root?.node(view: current) else { return }
        let bounds = CGRect(origin: .zero, size: tab.surfaceTree.viewBounds())
        if let newTree = try? tab.surfaceTree.resizing(node: node, by: amount, in: direction, with: bounds) {
            tab.surfaceTree = newTree
        }
    }

    /// Toggle focus mode (⌘⇧M) for the active terminal tab.
    func toggleFocusMode() {
        guard let tab = activeTerminal else { return }
        withAnimation(.smooth(duration: 0.2)) {
            focusMode.toggle()
        }
        if focusMode {
            focusModeSurfaceID = tab.focusedSurface?.id
                ?? tab.surfaceTree.root?.leftmostLeaf().id
        }
    }

    func selectFocusModePane(_ surface: Ghostty.SurfaceView) {
        focusModeSurfaceID = surface.id
        Ghostty.moveFocus(to: surface)
    }

    /// Close a terminal tab, selecting a sensible neighbor afterward.
    func closeTerminal(_ id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals.remove(at: idx)
        guard case let .terminal(selected) = selection, selected == id else { return }
        if terminals.isEmpty {
            selection = .dashboard
        } else {
            selection = .terminal(terminals[min(idx, terminals.count - 1)].id)
        }
    }

    /// Duplicate a tab (right-click → Duplicate Tab). An SSH/command tab
    /// re-runs its launch command; a local tab opens a fresh shell at the
    /// focused pane's current directory.
    func duplicateTab(_ id: UUID) {
        guard let tab = terminals.first(where: { $0.id == id }) else { return }
        if let command = tab.launchCommand {
            newTerminal(command: command, name: tab.displayName)
            return
        }
        // Local shell: reopen at the focused pane's cwd.
        let cwd = (tab.focusedSurface ?? tab.surfaceTree.root?.leftmostLeaf())?.pwd
        let newTab = newTerminal(command: nil, name: tab.displayName)
        if let cwd, !cwd.isEmpty, let surface = newTab?.surfaceTree.root?.leftmostLeaf() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                surface.surfaceModel?.sendText("cd \"\(cwd)\"\n")
            }
        }
    }

    /// Rename a tab (right-click → Rename Tab…). Empty clears the override.
    func renameTab(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        terminals.first { $0.id == id }?.customName = trimmed.isEmpty ? nil : trimmed
    }

    /// Set (or clear, with nil) a tab's accent color.
    func setColor(_ color: Color?, for id: UUID) {
        terminals.first { $0.id == id }?.color = color
    }

    /// Close every terminal tab except `id` (right-click → Close Other Tabs).
    func closeOtherTabs(keep id: UUID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        terminals.removeAll { $0.id != id }
        selection = .terminal(id)
    }

    /// Close all tabs positioned after `id` (right-click → Close Tabs to the Right).
    func closeTabsToRight(of id: UUID) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        let removed = Set(terminals[(idx + 1)...].map(\.id))
        guard !removed.isEmpty else { return }
        terminals.removeAll { removed.contains($0.id) }
        if case let .terminal(selected) = selection, removed.contains(selected) {
            selection = .terminal(id)
        }
    }

    /// Apply a resize/drop operation from the split-tree view to a tab.
    func performSplitOperation(_ op: TerminalSplitOperation, in tab: TerminalTab) {
        switch op {
        case .resize(let resize):
            let resized = resize.node.resizing(to: resize.ratio)
            if let newTree = try? tab.surfaceTree.replacing(node: resize.node, with: resized) {
                tab.surfaceTree = newTree
            }
        case .drop(let drop):
            // Same-tab pane move only (single window).
            guard let sourceNode = tab.surfaceTree.root?.node(view: drop.payload) else { return }
            let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch drop.zone {
            case .top: .up
            case .bottom: .down
            case .left: .left
            case .right: .right
            }
            let without = tab.surfaceTree.removing(sourceNode)
            if let newTree = try? without.inserting(view: drop.payload, at: drop.destination, direction: direction) {
                tab.surfaceTree = newTree
                Ghostty.moveFocus(to: drop.payload)
            }
        }
    }

    // MARK: - libghostty notification handling

    private func installObservers() {
        let nc = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note)
            })
        }

        observe(Ghostty.Notification.ghosttyCloseSurface) { [weak self] in self?.handleClose($0) }
        observe(Ghostty.Notification.ghosttyNewSplit) { [weak self] in self?.handleNewSplit($0) }
        observe(Ghostty.Notification.ghosttyFocusSplit) { [weak self] in self?.handleFocusSplit($0) }
        observe(Ghostty.Notification.didEqualizeSplits) { [weak self] in self?.handleEqualize($0) }
        observe(Ghostty.Notification.didToggleSplitZoom) { [weak self] in self?.handleToggleZoom($0) }
        // These fire only for CUSTOM keybinds (the default combos are consumed by
        // AppDelegate's monitor before reaching the surface). libghostty matches
        // the user's config and posts here; we perform the single-window action.
        observe(Ghostty.Notification.ghosttyGotoTab) { [weak self] in self?.handleGotoTab($0) }
        observe(.ghosttyMoveTab) { [weak self] in self?.handleMoveTab($0) }
        observe(Ghostty.Notification.didResizeSplit) { [weak self] in self?.handleResizeSplitNote($0) }
        observe(Ghostty.Notification.ghosttyToggleFullscreen) { [weak self] in self?.handleToggleFullscreen($0) }
        observe(.ghosttyCloseTab) { [weak self] in self?.handleCloseTabNote($0, kind: .this) }
        observe(.ghosttyCloseOtherTabs) { [weak self] in self?.handleCloseTabNote($0, kind: .other) }
        observe(.ghosttyCloseTabsOnTheRight) { [weak self] in self?.handleCloseTabNote($0, kind: .right) }
        // App-wide config change (Settings save / live reload). libghostty
        // applies new config to NEW surfaces, but our existing embedded surfaces
        // need an explicit push so live changes (cursor, colors, font, padding…)
        // take effect without relaunching. Deferred so `ghostty.config` is the
        // freshly-applied config by the time we read it.
        observe(.ghosttyConfigDidChange) { [weak self] note in
            guard note.object == nil else { return }
            DispatchQueue.main.async { self?.applyConfigToExistingSurfaces() }
        }
    }

    /// Push the current config to every live embedded surface so settings apply
    /// immediately to existing terminals, not just newly-opened ones.
    private func applyConfigToExistingSurfaces() {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        for tab in terminals {
            for pane in tab.surfaceTree.root?.leaves() ?? [] {
                guard let surface = pane.surface else { continue }
                ghostty.reloadConfig(surface: surface, soft: true)
            }
        }
    }

    private enum CloseTabKind { case this, other, right }

    private func handleGotoTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView, tab(containing: surface) != nil,
              let tabEnum = note.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e
        else { return }
        let raw = tabEnum.rawValue
        if raw == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue { cycleTab(-1) }
        else if raw == GHOSTTY_GOTO_TAB_NEXT.rawValue { cycleTab(1) }
        else if raw == GHOSTTY_GOTO_TAB_LAST.rawValue { selectLastTab() }
        else if raw >= 1 { selectTab(index: min(Int(raw) - 1, terminals.count - 1)) }
    }

    private func handleMoveTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface),
              let action = note.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab,
              action.amount != 0,
              let from = terminals.firstIndex(where: { $0.id == t.id }) else { return }
        let target = max(0, min(terminals.count - 1, from + action.amount))
        guard target != from else { return }
        withAnimation(.smooth(duration: 0.2)) {
            let moved = terminals.remove(at: from)
            terminals.insert(moved, at: target)
        }
    }

    private func handleResizeSplitNote(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface),
              let node = t.surfaceTree.root?.node(view: surface),
              let dir = note.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] as? Ghostty.SplitResizeDirection,
              let amount = note.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] as? UInt16 else { return }
        let spatial: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch dir {
        case .up: spatial = .up
        case .down: spatial = .down
        case .left: spatial = .left
        case .right: spatial = .right
        }
        let bounds = CGRect(origin: .zero, size: t.surfaceTree.viewBounds())
        if let newTree = try? t.surfaceTree.resizing(node: node, by: amount, in: spatial, with: bounds) {
            t.surfaceTree = newTree
        }
    }

    private func handleToggleFullscreen(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView, tab(containing: surface) != nil else { return }
        surface.window?.toggleFullScreen(nil)
    }

    private func handleCloseTabNote(_ note: Notification, kind: CloseTabKind) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let t = tab(containing: surface) else { return }
        switch kind {
        case .this: closeTerminal(t.id)
        case .other: closeOtherTabs(keep: t.id)
        case .right: closeTabsToRight(of: t.id)
        }
    }

    private func handleNewSplit(_ note: Notification) {
        guard let src = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: src),
              let app = (NSApp.delegate as? AppDelegate)?.ghostty.app else { return }
        guard let dirAny = note.userInfo?["direction"],
              let dir = dirAny as? ghostty_action_split_direction_e else { return }
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch dir {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: direction = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT:  direction = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN:  direction = .down
        case GHOSTTY_SPLIT_DIRECTION_UP:    direction = .up
        default: return
        }
        let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        let newView = Ghostty.SurfaceView(app, baseConfig: config)
        guard let newTree = try? tab.surfaceTree.inserting(view: newView, at: src, direction: direction) else { return }
        tab.surfaceTree = newTree
        Ghostty.moveFocus(to: newView, from: src)
    }

    private func handleClose(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: surface),
              let node = tab.surfaceTree.root?.node(view: surface) else { return }
        awaitingChoice.remove(surface.id)
        let remaining = tab.surfaceTree.removing(node)
        if remaining.isEmpty {
            closeTerminal(tab.id)
        } else {
            tab.surfaceTree = remaining
            if let next = remaining.root?.leftmostLeaf() {
                Ghostty.moveFocus(to: next)
            }
        }
    }

    private func handleFocusSplit(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target),
              let targetNode = tab.surfaceTree.root?.node(view: target),
              let dirAny = note.userInfo?[Ghostty.Notification.SplitDirectionKey],
              let direction = dirAny as? Ghostty.SplitFocusDirection,
              let next = tab.surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode)
        else { return }
        Ghostty.moveFocus(to: next, from: target)
    }

    private func handleEqualize(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target) else { return }
        tab.surfaceTree = tab.surfaceTree.equalized()
    }

    private func handleToggleZoom(_ note: Notification) {
        guard let target = note.object as? Ghostty.SurfaceView,
              let tab = tab(containing: target),
              let node = tab.surfaceTree.root?.node(view: target) else { return }
        if tab.surfaceTree.zoomed != nil {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: nil)
        } else {
            tab.surfaceTree = SplitTree(root: tab.surfaceTree.root, zoomed: node)
        }
    }
}
