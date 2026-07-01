import SwiftUI
import UniformTypeIdentifiers

/// Like Ghostty's `TerminalSplitTreeView`, but a leaf can show an inline
/// chooser ("blank pane" UX) when its surface is awaiting a choice — i.e. a
/// freshly created split pane. The chooser lets the user pick a saved host,
/// quick-connect via SSH, or use the already-running local shell. Pane
/// drag-and-drop is preserved (delegate ported from `TerminalSplitLeaf`).
struct VaultsSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    /// Surface IDs whose pane should present the chooser instead of the shell.
    let awaiting: Set<UUID>
    /// Whether the tab is broadcasting input to all panes (header indicator).
    let broadcasting: Bool
    /// The currently focused surface's id — drives the solid/dotted pane border.
    let focusedID: UUID?
    let onResolve: (Ghostty.SurfaceView, PaletteAction) -> Void
    let onDismiss: (Ghostty.SurfaceView) -> Void
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            // A split root means there's >1 pane → show the per-pane header.
            let multiPane: Bool = { if case .split = tree.root { return true }; return false }()
            VaultsSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                multiPane: multiPane,
                broadcasting: broadcasting,
                focusedID: focusedID,
                awaiting: awaiting,
                onResolve: onResolve,
                onDismiss: onDismiss,
                action: action
            )
            .id(node.structuralIdentity)
        }
    }
}

private struct VaultsSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let multiPane: Bool
    let broadcasting: Bool
    let focusedID: UUID?
    let awaiting: Set<UUID>
    let onResolve: (Ghostty.SurfaceView, PaletteAction) -> Void
    let onDismiss: (Ghostty.SurfaceView) -> Void
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            VaultsSplitLeaf(
                surfaceView: leafView,
                isSplit: !isRoot,
                showHeader: multiPane,
                broadcasting: broadcasting,
                isFocused: multiPane ? (focusedID == leafView.id) : false,
                awaiting: awaiting.contains(leafView.id),
                onResolve: onResolve,
                onDismiss: onDismiss,
                action: action
            )

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
            SplitView(
                splitViewDirection,
                .init(get: { CGFloat(split.ratio) },
                      set: { action(.resize(.init(node: node, ratio: $0))) }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    VaultsSplitSubtreeView(node: split.left, multiPane: multiPane, broadcasting: broadcasting, focusedID: focusedID, awaiting: awaiting, onResolve: onResolve, onDismiss: onDismiss, action: action)
                },
                right: {
                    VaultsSplitSubtreeView(node: split.right, multiPane: multiPane, broadcasting: broadcasting, focusedID: focusedID, awaiting: awaiting, onResolve: onResolve, onDismiss: onDismiss, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct VaultsSplitLeaf: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject private var tabs: VaultsTabsModel = .shared
    let isSplit: Bool
    /// Show the per-pane header (only when the tab has more than one pane).
    let showHeader: Bool
    /// Whether the tab is broadcasting input (drives the header icon state).
    let broadcasting: Bool
    /// Focused pane → solid border; unfocused → dotted. Only meaningful when
    /// the tab has multiple panes (single-pane tabs get no border).
    let isFocused: Bool
    let awaiting: Bool
    let onResolve: (Ghostty.SurfaceView, PaletteAction) -> Void
    let onDismiss: (Ghostty.SurfaceView) -> Void
    let action: (TerminalSplitOperation) -> Void

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false

    var body: some View {
        Group {
            if showHeader {
                // Multi-pane: bordered, spaced card (Termius-style).
                VStack(spacing: 0) {
                    header
                        // Draw the header (and its hover tooltips) above the
                        // surface so a tooltip extending into the pane isn't
                        // hidden by the chooser overlay on an awaiting pane.
                        .zIndex(1)
                    surface
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.accentColor : Color.secondary.opacity(0.4),
                            style: StrokeStyle(
                                lineWidth: isFocused ? 1.5 : 1,
                                dash: isFocused ? [] : [4, 3]
                            )
                        )
                )
                .padding(5)
            } else {
                surface
            }
        }
    }

    private var surface: some View {
        GeometryReader { geometry in
            Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: isSplit)
                .background {
                    if !isSelfDragging {
                        Color.clear
                            .onDrop(of: [.ghosttySurfaceId, .vaultsTabID], delegate: SplitDropDelegate(
                                dropState: $dropState,
                                viewSize: geometry.size,
                                destinationSurface: surfaceView,
                                action: action
                            ))
                    }
                }
                .overlay {
                    if !isSelfDragging, case .dropping(let zone) = dropState {
                        zone.overlay(in: geometry)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if awaiting {
                        SplitChooserView(
                            onChoose: { onResolve(surfaceView, $0) },
                            onDismiss: { onDismiss(surfaceView) },
                            onDropTab: { draggedID in
                                VaultsTabsModel.shared.injectTabIntoAwaiting(awaiting: surfaceView, draggedTabID: draggedID)
                            }
                        )
                    }
                }
                // Staged SSH connection popup for this pane. The connection is
                // keyed by surface id, so it shows over whichever pane the surface
                // currently lives in — including after being dragged into a split.
                // Close cancels just this pane (collapsing the split / closing the
                // tab if it's the last pane). SSHConnectionView hides itself once
                // connected, revealing the live terminal.
                .overlay {
                    if let conn = tabs.connections[surfaceView.id] {
                        SSHConnectionView(
                            model: conn.model,
                            controller: conn.controller,
                            onCancel: { VaultsTabsModel.shared.closePane(surface: surfaceView) }
                        )
                        .clipped()
                    }
                }
                .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                    isSelfDragging = value == surfaceView.id
                    if isSelfDragging { dropState = .idle }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal pane")
        }
    }

    /// Header label: a sticky override (e.g. the name of a tab dragged into this
    /// split, or a split-off pane's source name) wins over the surface's live
    /// title — which for a freshly-split or SSH pane is the generic ghost default.
    private var paneTitle: String {
        if let override = tabs.paneTitleOverride(for: surfaceView.id) { return override }
        return surfaceView.title.isEmpty ? "Terminal" : surfaceView.title
    }

    /// Per-pane header (Termius-style), shown only when a tab has >1 pane.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
            Text(paneTitle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.95))
                // Take the flexible space and TRUNCATE — otherwise a long title
                // pushes the trailing buttons off a narrow pane and they get
                // clipped by the rounded-rect mask.
                .frame(maxWidth: .infinity, alignment: .leading)
            headerButton(
                "dot.radiowaves.left.and.right",
                help: broadcasting ? "Stop broadcasting input" : "Broadcast input to all panes",
                active: broadcasting
            ) { VaultsTabsModel.shared.toggleBroadcast(surface: surfaceView) }
            headerButton("sidebar.left", help: "Focus mode (⌘⇧M)") {
                VaultsTabsModel.shared.toggleFocusMode()
            }
            headerButton("xmark", help: "Close pane") {
                VaultsTabsModel.shared.closePane(surface: surfaceView)
            }
        }
        .layoutPriority(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A solid dark scrim keeps the title legible over any background image.
        .background(Color.black.opacity(0.55))
    }

    private func headerButton(
        _ icon: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.green : .white.opacity(0.75))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip(help)
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        /// A tab can't be split into itself — reject (and hide zones) when the
        /// dragged tab owns this destination surface.
        private var isSelfTabDrag: Bool {
            VaultsTabsModel.shared.isSelfTabDrag(over: destinationSurface)
        }

        func validateDrop(info: DropInfo) -> Bool {
            guard !isSelfTabDrag else { return false }
            return info.hasItemsConforming(to: [.ghosttySurfaceId, .vaultsTabID])
        }

        func dropEntered(info: DropInfo) {
            guard !isSelfTabDrag else { dropState = .idle; return }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            if isSelfTabDrag { dropState = .idle; return DropProposal(operation: .forbidden) }
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            dropState = .idle
            guard !isSelfTabDrag else { return false }
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)

            // A tab chip dragged from the strip (carries its UUID under the
            // custom `vaultsTabID` type): inject that tab as a new pane here,
            // split in the hovered direction.
            let tabProviders = info.itemProviders(for: [.vaultsTabID])
            if let tabProvider = tabProviders.first {
                tabProvider.loadVaultsTabID { [weak destinationSurface] id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        guard let destinationSurface else { return }
                        VaultsTabsModel.shared.injectTab(id, into: destinationSurface, zone: zone)
                    }
                }
                return true
            }

            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }
                case .failure:
                    break
                }
            }
            return true
        }
    }
}

/// Inline "what should this split run?" chooser shown over a fresh split pane.
/// Reuses the command-palette model (search + saved hosts + quick connect).
struct SplitChooserView: View {
    let onChoose: (PaletteAction) -> Void
    let onDismiss: () -> Void
    /// A tab chip (public.text = its UUID) was dropped onto this empty split.
    let onDropTab: (UUID) -> Void

    @StateObject private var model = HostSearchModel()
    @FocusState private var searchFocused: Bool
    @State private var dropTargeted = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.96)
                .ignoresSafeArea()
                .overlay(
                    dropTargeted
                        ? Color.accentColor.opacity(0.12).ignoresSafeArea()
                        : nil
                )

            // One outer scroll so the whole chooser is reachable even in a tiny
            // split pane (centred when it fits, scrollable when it doesn't).
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        VStack(spacing: 4) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Open in this split")
                                .font(.headline)
                            Text("Pick a host, quick-connect, or use a local terminal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        searchField

                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { idx, item in
                                row(item: item, index: idx)
                            }
                        }

                        Text("Tip: drag a tab here to open it in this split")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Button("Dismiss") { onDismiss() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(24)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .onAppear {
            model.loadHosts()
            model.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
            installKeyMonitor()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        // Accept a tab chip dropped onto this empty split.
        .onDrop(of: [.vaultsTabID], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadVaultsTabID { id in
                guard let id else { return }
                DispatchQueue.main.async { onDropTab(id) }
            }
            return true
        }
    }

    /// Arrow-key navigation + Enter-to-connect, scoped to while the chooser's
    /// search field is focused so it doesn't steal keys from other panes.
    private func installKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard searchFocused else { return event }
            switch event.keyCode {
            case 125: model.stepHighlight(+1); return nil      // ↓
            case 126: model.stepHighlight(-1); return nil      // ↑
            case 36, 76:                                       // Return / Enter
                if let row = model.confirmSelection() { onChoose(row.action) }
                return nil
            case 53: onDismiss(); return nil                   // Esc
            default: return event
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                "",
                text: $model.search,
                prompt: Text("Search hosts or ssh user@host").foregroundColor(.secondary)
            )
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .focused($searchFocused)
            .onSubmit {
                if let row = model.confirmSelection() { onChoose(row.action) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func row(item: PaletteRow, index: Int) -> some View {
        Button {
            onChoose(item.action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).fontWeight(.medium)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let trailing = item.trailingText {
                    Text(trailing).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(index == model.highlightIndex ? Color.secondary.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.highlightIndex = index } }
    }
}
