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
            // Section pills stay pinned on the left — always visible. Grouped in
            // a subtle "island" so the navigation cluster (Vaults / SFTP) reads
            // as distinct from the terminal tabs and isn't mistaken for one.
            navSegment
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
                                needsAttention: tabs.attentionTabs.contains(tab.id),
                                onRename: { renameText = tab.displayName; renamingTab = tab },
                                onSaveSession: { tabs.promptSaveSession(for: tab) }
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
        // Centered-logo SarvAlert with input — same dialog semantics as
        // everywhere else in the app.
        .onChange(of: renamingTab?.id) { _ in
            guard let tab = renamingTab else { return }
            SarvAlert.present(
                title: "Rename Tab",
                buttons: [
                    .init("Rename", isDefault: true),
                    .init("Cancel", isCancel: true),
                ],
                inputInitial: renameText) { result in
                if result.buttonIndex == 0 { tabs.renameTab(tab.id, to: result.inputText) }
            }
            renamingTab = nil
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
        .modifier(ActivePillHighlight(isActive: isSelected))
    }

    /// Personal (the active vault, with its live sync status) + Team (later).
    @ViewBuilder
    private var vaultMenuContent: some View {
        Section("Personal") {
            // ONE enabled item on a single line (native menus don't render a
            // multi-line button label): the vault name + its live sync status
            // (provider, version, time). Enabled so it reads as active. Opens
            // the Vaults dashboard.
            Button { tabs.selectDashboard(section: .vaults) } label: {
                Label("Personal — \(vaultSyncSummary)", systemImage: syncCloudIcon.0)
            }
        }
        Section {
            Button {} label: { Label("Team — coming soon", systemImage: "person.2") }
                .disabled(true)
        }
    }

    /// Human name of the configured sync backend.
    private var syncProviderName: String {
        switch syncSettings.provider {
        case .github: return "GitHub"
        case .folder: return "Folder"
        }
    }

    /// One-line sync status shown under "Personal" in the vault menu.
    private var vaultSyncSummary: String {
        let s = syncSettings
        if !s.enabled { return "Sync is off" }
        if !s.isConfigured { return "Sync not set up" }
        let via = syncProviderName
        switch s.status {
        case .syncing: return "Syncing via \(via)…"
        case .error(let reason): return "\(via) · error: \(reason)"
        case .remoteNewer: return "\(via) · update available"
        default:
            if let date = s.lastSyncDate {
                return "Synced · \(via) · v\(s.lastSyncedVersion) · \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Enabled · \(via) · not synced yet"
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
            .modifier(ActivePillHighlight(isActive: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Accent border + bottom underline marking the selected section — mirrors
    /// the active terminal-tab chip so selection reads consistently.
    private struct ActivePillHighlight: ViewModifier {
        let isActive: Bool
        func body(content: Content) -> some View {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 1.5)
                )
                .overlay(alignment: .bottom) {
                    if isActive {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 1)
                    }
                }
        }
    }

    // MARK: - Divider + new-tab button

    /// Vaults + SFTP grouped into one bordered "island" so the navigation
    /// cluster is visually separate from the terminal tabs to its right.
    private var navSegment: some View {
        HStack(spacing: 4) {
            vaultsPill
            sftpPill
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
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

/// Purely-visual tab chip. Interaction (tap/drag/hover/cursor/menu) lives in the
/// AppKit `TabChipInteraction` layer the wrapper places on top; this view is
/// non-interactive. Hover reveals a close button, drawn by the wrapper over the
/// leading icon slot (which is left blank here while hovering).
private struct TerminalTabItem: View {
    let title: String
    /// 1-based position; shown as a ⌘-shortcut badge for the first 9 tabs.
    let number: Int
    let isActive: Bool
    /// Optional accent color set via the Tab Color menu.
    var color: Color?
    /// The tab rang the bell while off-screen (e.g. a Claude Code prompt).
    var needsAttention: Bool = false
    /// Mouse is over the chip — blank the leading slot for the close overlay.
    let hovering: Bool

    private var fillColor: Color {
        if let color { return color.opacity(isActive ? 0.28 : 0.16) }
        return isActive ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Leading slot: attention dot / terminal icon, or blank while
            // hovering (the wrapper overlays the close button here).
            Group {
                if hovering {
                    Color.clear
                } else if needsAttention {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color ?? (isActive ? Color.primary : .secondary.opacity(0.7)))
                }
            }
            .frame(width: 14, height: 14)
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
    }
}

/// Reorders tab chips on drop, mirroring the split-pane `SplitDropDelegate`.
/// Using a `DropDelegate` (rather than the closure-style `.onDrop`) is what
/// makes the custom `vaultsTabID` type match reliably and drives the green
/// insertion indicator via `dropEntered`/`dropExited`.
private struct TabReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var dropTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vaultsTabID])
    }

    func dropEntered(info: DropInfo) { dropTargeted = true }
    func dropExited(info: DropInfo) { dropTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargeted = false
        guard let provider = info.itemProviders(for: [.vaultsTabID]).first else { return false }
        provider.loadVaultsTabID { dragged in
            guard let dragged else { return }
            DispatchQueue.main.async { VaultsTabsModel.shared.moveTab(dragged, before: targetID) }
        }
        return true
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
    var needsAttention: Bool = false
    let onRename: () -> Void
    let onSaveSession: () -> Void

    @State private var showColorPicker = false
    /// True while a dragged tab is hovering this chip as a drop target — drives
    /// the green insertion indicator so it's clear where the tab will land.
    @State private var dropTargeted = false
    /// Mouse over the chip (from the AppKit interaction layer) — reveals close.
    @State private var hovering = false
    /// Mouse directly over the close button — turns the X red.
    @State private var hoveringClose = false
    private var tabs: VaultsTabsModel { .shared }

    /// Leading region (points) that closes on click: left padding (10) + the
    /// 14pt icon slot the close button occupies. Matches `TabChipInteraction`.
    private let closeHitWidth: CGFloat = 26

    private var menuItems: [TabChipMenuItem] {
        [
            .init(title: "Close Tab", action: { tabs.closeTerminal(tab.id) }),
            .init(title: "Close Other Tabs", action: { tabs.closeOtherTabs(keep: tab.id) }),
            .init(title: "Close Tabs to the Right", action: { tabs.closeTabsToRight(of: tab.id) }),
            .init(title: "Show All Tabs", action: { tabs.showAllTabs = true }),
            .init(title: "Duplicate Tab", action: { tabs.duplicateTab(tab.id) }),
            .init(title: "Save Session…", action: onSaveSession),
            .init(title: "Rename Tab…", action: onRename, separatorBefore: true),
            .init(title: "Tab Color…", action: { showColorPicker = true }),
        ]
    }

    var body: some View {
        TerminalTabItem(
            title: tab.displayName,
            number: number,
            isActive: isActive,
            color: tab.color,
            needsAttention: needsAttention,
            hovering: hovering
        )
        // Close button, drawn over the leading icon slot on hover. Visual only —
        // the AppKit layer below handles the click (by location).
        .overlay(alignment: .leading) {
            if hovering {
                // On direct hover the button goes red. White-on-red (not a red
                // X on the neutral circle) so it stays legible when the tab
                // color itself is red.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hoveringClose ? Color.red : Color.secondary.opacity(0.20)))
                    .foregroundStyle(hoveringClose ? Color.white : .primary)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }
        }
        // Insertion indicator: a green bar on the leading edge + a faint green
        // wash show the dragged tab will drop *before* this one.
        .overlay(alignment: .leading) {
            if dropTargeted {
                Capsule()
                    .fill(Color.green)
                    .frame(width: 3)
                    .padding(.vertical, 3)
                    .offset(x: -5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTargeted ? Color.green.opacity(0.18) : .clear)
        )
        // AppKit interaction on top (transparent): tap-select, press-drag with
        // the open→closed-hand grab cursor, hover, and the right-click menu.
        .overlay(
            TabChipInteraction(
                tabID: tab.id,
                closeHitWidth: closeHitWidth,
                onActivate: { tabs.selectTerminal(tab.id) },
                onClose: { tabs.closeTerminal(tab.id) },
                onHoverChanged: { hovering = $0 },
                onCloseHoverChanged: { hoveringClose = $0 },
                menuItems: menuItems)
        )
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .onDrop(of: [.vaultsTabID], delegate: TabReorderDropDelegate(
            targetID: tab.id,
            dropTargeted: $dropTargeted))
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
/// Shared by the tab strip and the Saved Sessions list.
struct TabColorPicker: View {
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
