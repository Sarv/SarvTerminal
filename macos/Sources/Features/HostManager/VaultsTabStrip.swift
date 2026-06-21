import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Termius-style unified tab strip across the top of the Vaults window.
/// One row contains everything — section pills (Vaults / SFTP / SCP) first,
/// then embedded terminal tabs, then the trailing "+".
///
/// Selection is a single source of truth in `VaultsTabsModel`: a section pill
/// shows the dashboard at that section; a terminal chip shows that terminal's
/// surface. There is no native macOS tab bar behind this — terminals are
/// embedded in the one window.
struct VaultsTabStrip: View {
    @ObservedObject var tabs: VaultsTabsModel = .shared
    @ObservedObject var section: HostManagerSelection = .shared
    @ObservedObject private var syncSettings: SyncSettings = .shared
    /// Opens the command palette (quick connect / Local Terminal / Serial).
    let newTabAction: () -> Void

    @State private var renamingTab: VaultsTabsModel.TerminalTab?
    @State private var renameText: String = ""

    private var dashboardActive: Bool {
        tabs.selection == .dashboard
    }

    var body: some View {
        HStack(spacing: 6) {
            // Section pills stay pinned on the left — always visible.
            vaultsPill
            sftpPill
            divider
            // Only the terminal tabs scroll horizontally when they overflow.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(tabs.terminals.enumerated()), id: \.element.id) { index, tab in
                            TabChip(
                                tab: tab,
                                number: index + 1,
                                isActive: tabs.selection == .terminal(tab.id),
                                onRename: { renameText = tab.displayName; renamingTab = tab }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Bring the active tab into view — e.g. a newly created tab at
                // the end, or one selected via ⌘-number.
                .onChange(of: tabs.selection) { newValue in
                    guard case let .terminal(id) = newValue else { return }
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            // The "+" stays pinned on the right of the scroll area.
            newTabButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .alert(
            "Rename Tab",
            isPresented: Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
        ) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if let tab = renamingTab { tabs.renameTab(tab.id, to: renameText) }
                renamingTab = nil
            }
            Button("Cancel", role: .cancel) { renamingTab = nil }
        }
    }

    // MARK: - Section pills

    /// The Vaults pill: an animated sync-status cloud + label that selects the
    /// dashboard, plus a chevron that opens the vault (Personal / Team) menu.
    private var vaultsPill: some View {
        let (icon, tint) = syncCloudIcon
        let isSelected = dashboardActive && section.section == .vaults
        return HStack(spacing: 5) {
            Button {
                tabs.selectDashboard(section: .vaults)
            } label: {
                HStack(spacing: 5) {
                    SyncStatusIcon(icon: icon, tint: tint, spinning: syncSettings.status == .syncing)
                    Text("Vaults").lineLimit(1).fixedSize()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(syncCloudHelp)

            Menu {
                vaultMenuContent
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Switch vault")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08))
        )
    }

    /// Personal (the active vault, with its live sync status) + Team (later).
    @ViewBuilder
    private var vaultMenuContent: some View {
        Section("Personal") {
            Label("Personal", systemImage: syncCloudIcon.0)
            Text(vaultSyncSummary)
        }
        Section {
            Button {} label: { Label("Team — coming soon", systemImage: "person.2") }
                .disabled(true)
        }
    }

    /// One-line sync status shown under "Personal" in the vault menu.
    private var vaultSyncSummary: String {
        let s = syncSettings
        if !s.enabled { return "Sync is off" }
        if !s.isConfigured { return "Sync not set up" }
        switch s.status {
        case .syncing: return "Syncing…"
        case .error(let reason): return "Error: \(reason)"
        case .remoteNewer: return "Update available · pull to refresh"
        default:
            if let date = s.lastSyncDate {
                return "Synced · v\(s.lastSyncedVersion) · \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Enabled · not synced yet"
        }
    }

    /// Cloud glyph + tint reflecting sync status. Default `icloud.slash` look
    /// when sync is off/unconfigured; green when working.
    private var syncCloudIcon: (String, Color?) {
        switch syncSettings.status {
        case .disabled:    return ("icloud.slash", nil)
        case .idle:        return ("checkmark.icloud.fill", .green)
        case .syncing:     return ("arrow.triangle.2.circlepath.icloud", .blue)
        case .remoteNewer: return ("exclamationmark.icloud.fill", .orange)
        case .error:       return ("exclamationmark.icloud.fill", .red)
        }
    }

    private var syncCloudHelp: String {
        switch syncSettings.status {
        case .disabled:    return "Vaults — saved hosts, keychain, snippets (sync off)"
        case .idle:        return "Vaults — sync on and up to date"
        case .syncing:     return "Vaults — syncing…"
        case .remoteNewer: return "Vaults — a newer version is available to pull"
        case .error:       return "Vaults — sync error"
        }
    }

    private var sftpPill: some View {
        sectionPill(
            section: .sftp,
            icon: "folder",
            label: "SFTP",
            trailingChevron: false,
            comingSoon: false,
            help: "SFTP — local ⇄ remote file transfer"
        )
    }

    private func sectionPill(
        section pillSection: HostManagerSelection.Section,
        icon: String,
        iconTint: Color? = nil,
        label: String,
        trailingChevron: Bool,
        comingSoon: Bool,
        help: String
    ) -> some View {
        // A pill is selected only when the dashboard is showing AND points to
        // this section. While a terminal tab is active, no pill is selected —
        // the terminal chip is the visual focus instead.
        let isSelected = dashboardActive && (section.section == pillSection)
        return Button {
            tabs.selectDashboard(section: pillSection)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(iconTint ?? (isSelected ? Color.primary : .secondary))
                Text(label).lineLimit(1).fixedSize()
                if comingSoon {
                    Text("soon")
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.25))
                        )
                        .foregroundStyle(.secondary)
                }
                if trailingChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .opacity(comingSoon && !isSelected ? 0.65 : 1.0)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Color.primary.opacity(0.12)
                          : Color.secondary.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Divider + new-tab button

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private var newTabButton: some View {
        Button(action: newTabAction) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                )
                // Stroke-only backgrounds have a clear interior, so without an
                // explicit hit shape clicks in the padding fall through.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip("New terminal tab")
    }
}

// MARK: - Terminal tab item

/// One embedded terminal tab. Hover reveals an "×" close button; click body
/// activates the terminal. Drag is attached by the strip (reorder / inject).
private struct TerminalTabItem: View {
    let title: String
    /// 1-based position; shown as a ⌘-shortcut badge for the first 9 tabs.
    let number: Int
    let isActive: Bool
    /// Optional accent color set via the Tab Color menu.
    var color: Color?
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var fillColor: Color {
        if let color { return color.opacity(isActive ? 0.28 : 0.16) }
        return isActive ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)
    }

    // NOTE: this is intentionally NOT a `Button`. A `Button` swallows the
    // press gesture and `.draggable`/`.onDrag` (attached by the strip) never
    // starts. A plain view with `.onTapGesture` lets tap = select and
    // press-drag = drag coexist.
    var body: some View {
        HStack(spacing: 6) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.secondary.opacity(0.20)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color ?? (isActive ? Color.primary : .secondary.opacity(0.7)))
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            if number <= 9 {
                Spacer(minLength: 4)
                Text("⌘\(number)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, weight: isActive ? .semibold : .medium))
        .foregroundStyle(isActive ? Color.primary : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor)
        )
        // Clearer active indicator: accent border + a bottom underline bar.
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? (color ?? .accentColor).opacity(0.9) : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(color ?? .accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onHover { hovering = $0 }
        .help(title)
    }
}

// MARK: - Tab chip wrapper (observes the tab for live name/color updates)

/// Wraps `TerminalTabItem` and observes the tab so renames / color changes
/// reflect immediately, and owns the drag/drop, context menu, and the color
/// picker popover.
private struct TabChip: View {
    @ObservedObject var tab: VaultsTabsModel.TerminalTab
    let number: Int
    let isActive: Bool
    let onRename: () -> Void

    @State private var showColorPicker = false
    private var tabs: VaultsTabsModel { .shared }

    var body: some View {
        TerminalTabItem(
            title: tab.displayName,
            number: number,
            isActive: isActive,
            color: tab.color,
            onActivate: { tabs.selectTerminal(tab.id) },
            onClose: { tabs.closeTerminal(tab.id) }
        )
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, let dragged = UUID(uuidString: s) else { return }
                DispatchQueue.main.async { VaultsTabsModel.shared.moveTab(dragged, before: tab.id) }
            }
            return true
        }
        .contextMenu {
            Button { tabs.closeTerminal(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
            Button { tabs.closeOtherTabs(keep: tab.id) } label: { Label("Close Other Tabs", systemImage: "xmark") }
            Button { tabs.closeTabsToRight(of: tab.id) } label: { Label("Close Tabs to the Right", systemImage: "xmark") }
            Button { tabs.showAllTabs = true } label: { Label("Show All Tabs", systemImage: "square.grid.2x2") }
            Button { tabs.duplicateTab(tab.id) } label: { Label("Duplicate Tab", systemImage: "plus.square.on.square") }
            Divider()
            Button { onRename() } label: { Label("Rename Tab…", systemImage: "pencil") }
            Button { showColorPicker = true } label: { Label("Tab Color…", systemImage: "paintpalette") }
        }
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
            TabColorPicker(selected: tab.color) { color in
                tabs.setColor(color, for: tab.id)
                showColorPicker = false
            }
        }
    }
}

/// A small grid of colored swatches for picking a tab color (visible colors +
/// a ring on the current selection). Replaces the monochrome context submenu.
private struct TabColorPicker: View {
    let selected: Color?
    let onPick: (Color?) -> Void

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tab Color").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 10) {
                // "None" swatch.
                swatch(color: nil, isSelected: selected == nil) {
                    Image(systemName: "circle.slash").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(VaultsTabsModel.tabColorOptions) { option in
                    swatch(color: option.color, isSelected: selected == option.color) {
                        Circle().fill(option.color)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private func swatch<Content: View>(color: Color?, isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        Button { onPick(color) } label: {
            content()
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(Color.primary, lineWidth: isSelected ? 2 : 0)
                )
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Selected" : "")
    }
}

/// Sync-status cloud glyph. While syncing, the cloud stays still and only the
/// inner circular arrows rotate (blue). Otherwise it shows the static status
/// symbol (green check / grey slash / red exclamation).
private struct SyncStatusIcon: View {
    let icon: String
    let tint: Color?
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        Group {
            if spinning {
                ZStack {
                    Image(systemName: "icloud.fill")
                        .foregroundStyle(.blue)
                    Image(systemName: "arrow.2.circlepath")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(angle))
                        .offset(y: 1)
                }
            } else {
                Image(systemName: icon)
                    .foregroundStyle(tint ?? Color.secondary)
            }
        }
        .onChange(of: spinning) { startStop($0) }
        .onAppear { startStop(spinning) }
    }

    private func startStop(_ on: Bool) {
        if on {
            angle = 0
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.default) { angle = 0 }
        }
    }
}
