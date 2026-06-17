import SwiftUI

/// Termius-style "focus mode": a sidebar listing the active tab's panes plus a
/// single main pane. It's an alternate view of the same `SplitTree`, so the
/// grid is preserved and ⌘⇧M toggles back to it. New panes added while here
/// simply appear in the sidebar and re-grid when you switch back.
struct VaultsFocusModeView: View {
    @ObservedObject var tab: VaultsTabsModel.TerminalTab
    let ghostty: Ghostty.App
    @ObservedObject private var tabs: VaultsTabsModel = .shared

    private var panes: [Ghostty.SurfaceView] { tab.surfaceTree.root?.leaves() ?? [] }

    private var selected: Ghostty.SurfaceView? {
        if let id = tabs.focusModeSurfaceID, let match = panes.first(where: { $0.id == id }) {
            return match
        }
        return panes.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
            Divider()
            main
        }
        .environmentObject(ghostty)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + actions all on one line.
            HStack(spacing: 6) {
                Text("Terminals").font(.system(size: 13, weight: .semibold))
                Text("•").foregroundStyle(.tertiary)
                Text("\(panes.count)").foregroundStyle(.secondary).font(.system(size: 13))
                Spacer()
                // Return to the split grid.
                headerAction(
                    icon: "rectangle.split.2x1",
                    help: "Split view (⌘⇧M)",
                    active: false
                ) { tabs.toggleFocusMode() }
                // Broadcast input to all panes. Green when active; rows then
                // show on/off indicators (display only).
                headerAction(
                    icon: "dot.radiowaves.left.and.right",
                    help: tab.broadcasting ? "Broadcasting input to all panes" : "Broadcast input to all panes",
                    active: tab.broadcasting
                ) { tab.broadcasting.toggle() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(panes, id: \.id) { pane in
                        FocusSidebarRow(
                            surfaceView: pane,
                            overrideTitle: tab.paneTitleOverrides[pane.id],
                            isSelected: selected?.id == pane.id,
                            broadcasting: tab.broadcasting,
                            onSelect: { tabs.selectFocusModePane(pane) },
                            onDuplicate: { tabs.duplicatePane(surface: pane) },
                            onClose: { tabs.closePane(surface: pane) }
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    /// An icon-only header action. The name (and shortcut) live in the hover
    /// tooltip rather than inline text.
    private func headerAction(
        icon: String,
        help: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.green : Color.primary.opacity(0.85))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.green.opacity(0.15) : Color.secondary.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip(help)
    }

    // MARK: - Main pane

    @ViewBuilder
    private var main: some View {
        if let surface = selected {
            Ghostty.SurfaceWrapper(surfaceView: surface)
                .id(surface.id)
                // A still-unresolved split pane shows the same "Open in this
                // split" chooser here as it would in the grid, so focus mode
                // stays consistent with the split view.
                .overlay {
                    if tabs.awaitingChoice.contains(surface.id) {
                        SplitChooserView(
                            onChoose: { tabs.resolveChoice(surface: surface, action: $0) },
                            onDismiss: { tabs.closePane(surface: surface) },
                            onDropTab: { draggedID in
                                tabs.injectTabIntoAwaiting(awaiting: surface, draggedTabID: draggedID)
                            }
                        )
                    }
                }
                // Staged SSH connection popup over the focused pane (mirrors the
                // split-grid behavior).
                .overlay {
                    if let conn = tabs.connections[surface.id] {
                        SSHConnectionView(
                            model: conn.model,
                            controller: conn.controller,
                            onCancel: { tabs.closePane(surface: surface) }
                        )
                        .clipped()
                    }
                }
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }
}

// MARK: - Hover tooltips (window-level, always-on-top, edge-aware)

/// A single presenter that the window-level `TooltipOverlay` (mounted once in
/// `VaultsRootView`) observes. Each `.hoverTip(...)` reports its text and the
/// hovered view's frame here, so the tip is drawn at the very top of the
/// hierarchy — never clipped by an ancestor mask, never pushed off-screen.
final class TooltipPresenter: ObservableObject {
    static let shared = TooltipPresenter()
    /// Shared coordinate space the anchors and the overlay both resolve in.
    static let space = "vaultsRoot"

    @Published var text: String?
    @Published var anchor: CGRect = .zero
    private var activeID: UUID?

    private init() {}

    func show(_ text: String, anchor: CGRect, id: UUID) {
        activeID = id
        self.text = text
        self.anchor = anchor
    }

    func hide(id: UUID) {
        // Only clear if we're still the one showing — avoids a stale hover-out
        // wiping a newer tooltip.
        if activeID == id {
            activeID = nil
            text = nil
        }
    }
}

extension View {
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTip(text: text))
    }
}

private struct HoverTip: ViewModifier {
    let text: String
    @State private var id = UUID()
    @State private var frame: CGRect = .zero
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frame = geo.frame(in: .named(TooltipPresenter.space)) }
                        .onChange(of: geo.frame(in: .named(TooltipPresenter.space))) { newValue in
                            frame = newValue
                        }
                }
            )
            .onHover { hovering in
                pending?.cancel()
                if hovering {
                    let work = DispatchWorkItem {
                        TooltipPresenter.shared.show(text, anchor: frame, id: id)
                    }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                } else {
                    TooltipPresenter.shared.hide(id: id)
                }
            }
    }
}

/// Draws the active tooltip once, at the top of the window, positioned near the
/// hovered control and clamped/flipped to stay fully on-screen.
struct TooltipOverlay: View {
    @ObservedObject private var presenter = TooltipPresenter.shared
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let text = presenter.text {
                let pos = tipPosition(anchor: presenter.anchor, container: geo.size, size: size)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                    .fixedSize()
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { size = g.size }
                                .onChange(of: g.size) { newValue in size = newValue }
                        }
                    )
                    .position(pos)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// Position the tip near the control: below by default, flipped above if it
    /// would clip the bottom, and horizontally clamped so it never runs off an
    /// edge of the window.
    private func tipPosition(anchor a: CGRect, container: CGSize, size: CGSize) -> CGPoint {
        let gap: CGFloat = 6
        let halfW = size.width / 2
        let halfH = size.height / 2
        var y = a.maxY + gap + halfH
        if y + halfH > container.height - 4 {
            y = a.minY - gap - halfH
        }
        y = max(halfH + 4, y)
        let minX = halfW + 4
        let maxX = container.width - halfW - 4
        let x = min(max(a.midX, minX), max(minX, maxX))
        return CGPoint(x: x, y: y)
    }
}

/// One row in the focus-mode sidebar. Observes the surface for a live title.
private struct FocusSidebarRow: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    /// A fixed display name (e.g. a duplicated pane inherits the source's name).
    let overrideTitle: String?
    let isSelected: Bool
    /// Whether the tab is broadcasting (drives the per-pane indicator).
    let broadcasting: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var displayName: String {
        if let overrideTitle, !overrideTitle.isEmpty { return overrideTitle }
        return surfaceView.title.isEmpty ? "Terminal" : surfaceView.title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            if broadcasting {
                // Display-only icon indicator: the selected pane is the
                // broadcast source (dimmed); every other pane receives (green).
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.secondary.opacity(0.5) : Color.green)
                    .help(isSelected ? "Broadcast source (input typed here)" : "Receives broadcast input")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { onClose() } label: { Label("Close", systemImage: "xmark") }
        }
    }
}
