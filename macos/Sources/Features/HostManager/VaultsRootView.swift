import SwiftUI

/// Root content of the Vaults window. Swaps the content area between the
/// Vaults dashboard and the selected embedded terminal tab, driven by
/// `VaultsTabsModel`. Terminal surfaces persist as objects in the model, so
/// switching away and back keeps the session running.
struct VaultsRootView: View {
    @ObservedObject var tabs: VaultsTabsModel = .shared
    @ObservedObject var background: BackgroundDisplayStore = .shared
    /// Termius-style right command sidebar (Search / Snippets / History / Themes).
    @State private var sidebarVisible = false
    @State private var sidebarTab: VaultsCommandSidebar.Tab = .snippets
    /// The shared libghostty app. Non-nil in practice (set post-launch); if it
    /// were ever nil we fall back to a dashboard-only window rather than
    /// constructing a second libghostty instance.
    let ghostty: Ghostty.App?
    /// Opens the command palette (the "+" button).
    let newTabAction: () -> Void

    /// Whether the active tab is a terminal — the command sidebar's actions
    /// (run/paste snippets & history) target the focused terminal, so it's
    /// only available there (not on the Vaults dashboard / SFTP).
    private var inTerminal: Bool {
        if case .terminal = tabs.selection { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                // The tab bar is always opaque so it stays readable and the
                // window-level shared image never shows behind it.
                .background(Color(NSColor.windowBackgroundColor))
                // Keep the strip on top: the content below is drawn after it in
                // the VStack, so without this an opaque content overlay (the SSH
                // connection popup) can paint over the strip.
                .zIndex(1)
            Divider()
                .zIndex(1)
            HStack(spacing: 0) {
                // Left-edge scratchpad — only alongside a terminal (its Send/Run
                // target the focused pane).
                if tabs.scratchpadVisible, inTerminal {
                    ScratchpadPanel(onClose: {
                        withAnimation(.easeInOut(duration: 0.18)) { tabs.scratchpadVisible = false }
                    })
                    .transition(.move(edge: .leading))
                    Divider()
                }
                Group {
                    if let ghostty {
                        content(ghostty).environmentObject(ghostty)
                    } else {
                        HostManagerView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // In shared mode the content area is CLEAR so the translucent panes
                // blend against the window's NSImageView backing (the shared image,
                // drawn by HostManagerController). Otherwise it's the opaque window
                // background.
                .background(background.useShared
                            ? Color.clear
                            : Color(NSColor.windowBackgroundColor))
                // Confine the content (and any overlay it hosts, e.g. the SSH
                // connection popup) so it can't bleed up over the tab strip.
                .clipped()

                // The command sidebar targets the focused TERMINAL (run/paste
                // snippets, history), so it only renders on terminal tabs.
                // `sidebarVisible` is kept as-is, so switching back to a
                // terminal restores it.
                if sidebarVisible, inTerminal {
                    VaultsCommandSidebar(tab: $sidebarTab)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0)
        }
        .frame(minWidth: 900, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if tabs.showAllTabs {
                VaultsAllTabsView()
                    .transition(.opacity)
            }
        }
        // Host editor side panel (from the SSH popup's "Edit host"). Sits above
        // the content so it overlays the connection popup; the popup stays put
        // and picks up the saved changes on Connect / Start over.
        .overlay {
            if let host = tabs.editingHost {
                VaultsHostEditorSidebar(host: host, onClose: { tabs.editingHost = nil })
                    .id(host.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: tabs.editingHost?.id)
        .sheet(isPresented: $tabs.presentingSerialConnect) { SerialConnectSheet() }
        // Single window-level tooltip layer, above everything (panes, choosers,
        // sidebar). Sits in the named space that every `.hoverTip` resolves in.
        .overlay { TooltipOverlay() }
        .coordinateSpace(name: TooltipPresenter.space)
    }

    /// The Termius-style strip, now in content (just below the titlebar) so
    /// tab drag works. Carries the gear/bell on the trailing edge.
    private var topBar: some View {
        HStack(spacing: 8) {
            VaultsTabStrip(newTabAction: newTabAction)
            // Trailing order: + (in the tab strip) · bell · sidebar · account.
            // No gear icon — Settings follows the macOS convention (app menu
            // "Sarv Terminal → Settings…", ⌘,) instead of a chrome button.
            VaultsBellView()
            // Scratchpad toggle (left panel). Like the command sidebar, its
            // Send/Run target the focused terminal, so it's terminal-only.
            Button {
                tabs.toggleScratchpad()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(!inTerminal ? Color.secondary.opacity(0.35)
                                     : tabs.scratchpadVisible ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inTerminal)
            .hoverTip(inTerminal
                      ? "Scratchpad — stage & send commands (⌘⇧E)"
                      : "Scratchpad — available in terminal tabs")
            // Focus mode (the pane sidebar) is opened with ⌘⇧M — no top-bar
            // button. The sidebar carries its own "Split view" button to return.
            // Disabled (not hidden) outside terminal tabs so the trailing
            // cluster keeps its layout — mac convention for "temporarily
            // unavailable".
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(!inTerminal ? Color.secondary.opacity(0.35)
                                     : sidebarVisible ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!inTerminal)
            .hoverTip(inTerminal
                      ? "Command sidebar (snippets, history, themes, search)"
                      : "Command sidebar — available in terminal tabs")
            AccountMenuButton()
                .padding(.trailing, 6)
        }
        .frame(height: 42)
    }

    @ViewBuilder
    private func content(_ ghostty: Ghostty.App) -> some View {
        switch tabs.selection {
        case .dashboard:
            HostManagerView()
        case .terminal:
            if let tab = tabs.activeTerminal {
                VaultsTerminalPane(tab: tab, ghostty: ghostty, awaiting: tabs.awaitingChoice)
                    // Rebuild (and re-focus) when the active tab changes.
                    .id(tab.id)
            } else {
                HostManagerView()
            }
        }
    }
}

/// Renders one terminal tab's split tree and manages keyboard focus + title
/// tracking — mirrors the focus plumbing in `TerminalView`.
private struct VaultsTerminalPane: View {
    @ObservedObject var tab: VaultsTabsModel.TerminalTab
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject private var tabs: VaultsTabsModel = .shared
    /// Surface IDs showing the inline split chooser.
    let awaiting: Set<UUID>

    /// Last non-nil focused surface — drives split dimming and title.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?
    @FocusState private var focused: Bool
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    var body: some View {
        Group {
            if tabs.focusMode {
                VaultsFocusModeView(tab: tab, ghostty: ghostty)
            } else {
                grid
            }
        }
        .ghosttyLastFocusedSurface(lastFocusedSurface)
        .focused($focused)
        .onAppear {
            focused = true
            // Restore focus to the pane that was active when we last left this
            // tab (falling back to the first pane), so switching tabs doesn't
            // jump focus back to split #1. Only trust the remembered pane if it
            // still belongs to THIS tab's tree — a stale/cross-tab reference
            // would send focus to a detached surface, leaving the pane visually
            // selected but with no real cursor.
            let remembered = tab.focusedSurface.flatMap {
                tab.surfaceTree.contains($0) ? $0 : nil
            }
            // During a staged SSH connect the popup owns focus (its password
            // field); don't pull it into a connecting terminal underneath.
            if let surface = remembered ?? tab.surfaceTree.root?.leftmostLeaf(),
               tabs.connections[surface.id]?.model.showsCard != true {
                Ghostty.moveFocus(to: surface)
            }
        }
        .onChange(of: focusedSurface) { newValue in
            guard let newValue else { return }
            lastFocusedSurface = .init(newValue)
            tab.focusedSurface = newValue
            // Enforce single focus: inactive split panes default to
            // `focused == true` and would otherwise show a solid blinking
            // cursor, so tell every other pane to render the hollow one.
            for leaf in tab.surfaceTree.root?.leaves() ?? [] where leaf !== newValue {
                leaf.renderUnfocused()
            }
        }
    }

    private var grid: some View {
        VaultsSplitTreeView(
            tree: tab.surfaceTree,
            awaiting: awaiting,
            broadcasting: tab.broadcasting,
            focusedID: lastFocusedSurface?.value?.id,
            onResolve: { surface, action in VaultsTabsModel.shared.resolveChoice(surface: surface, action: action) },
            onDismiss: { surface in VaultsTabsModel.shared.closePaneSkippingConfirm(surface: surface) },
            action: { VaultsTabsModel.shared.performSplitOperation($0, in: tab) }
        )
        .environmentObject(ghostty)
    }
}

/// Trailing side panel that hosts the full `HostEditorView` over the current
/// Vaults screen (opened from the SSH connection popup's "Edit host"). Saving
/// upserts the host and closes the panel; the connection popup stays visible
/// and re-reads the updated host on Connect / Start over.
private struct VaultsHostEditorSidebar: View {
    let onClose: () -> Void
    @State private var draft: SavedHost

    init(host: SavedHost, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _draft = State(initialValue: host)
    }

    var body: some View {
        VaultsEditorSidebar(onClose: onClose) {
            HostEditorView(
                draft: $draft,
                isNew: false,
                onCancel: {
                    // Close is the commit point — flush the last edit first.
                    SavedHostsStore.shared.upsert(draft)
                    onClose()
                },
                onDelete: nil,
                onConnect: nil,
                onAutosave: {
                    // Skip (and don't flash "Saved") when nothing changed.
                    if let current = SavedHostsStore.shared.host(withID: draft.id),
                       current.contentEquals(draft) {
                        return false
                    }
                    SavedHostsStore.shared.upsert(draft)
                    return true
                }
            )
        }
    }
}
