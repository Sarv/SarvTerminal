import SwiftUI

/// Root content of the Vaults window. Swaps the content area between the
/// Vaults dashboard and the selected embedded terminal tab, driven by
/// `VaultsTabsModel`. Terminal surfaces persist as objects in the model, so
/// switching away and back keeps the session running.
struct VaultsRootView: View {
    @ObservedObject var tabs: VaultsTabsModel = .shared
    @ObservedObject var background: BackgroundDisplayStore = .shared
    /// The shared libghostty app. Non-nil in practice (set post-launch); if it
    /// were ever nil we fall back to a dashboard-only window rather than
    /// constructing a second libghostty instance.
    let ghostty: Ghostty.App?
    /// Opens the command palette (the "+" button).
    let newTabAction: () -> Void

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
            // Focus mode (the pane sidebar) is opened with ⌘⇧M — no top-bar
            // button. The sidebar carries its own "Split view" button to return.
            VaultsBellView()
            VaultsGearView()
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
            onDismiss: { surface in VaultsTabsModel.shared.closePane(surface: surface) },
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
        HStack(spacing: 0) {
            // Dimmed scrim over the rest of the screen; click to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            HostEditorView(
                draft: $draft,
                isNew: false,
                onSave: {
                    SavedHostsStore.shared.upsert(draft)
                    onClose()
                },
                onCancel: onClose,
                onDelete: nil,
                onConnect: nil
            )
            .frame(width: 480)
            .frame(maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(alignment: .leading) {
                Divider()
            }
        }
    }
}
