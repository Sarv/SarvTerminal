import SwiftUI
import AppKit

/// An action the command palette can run when a row is confirmed.
enum PaletteAction: Equatable {
    /// Connect to a host discovered in ~/.ssh/config via its SSH command.
    case host(DiscoveredHost)
    /// Connect to one of the user's saved Vaults hosts via the staged popup
    /// flow (askpass, saved password, auto-reconnect).
    case savedHost(SavedHost)
    /// Ad-hoc SSH connect to whatever the user typed (`ssh <query>`).
    case quickConnect(String)
    /// Open a plain local shell tab — no command injection.
    case localTerminal
    /// Serial console — not wired up yet.
    case serial
}

/// One rendered row in the palette. Rows are grouped under a `section`
/// header (Termius-style) and navigated linearly via the highlight index.
struct PaletteRow: Identifiable, Equatable {
    enum Section: String {
        case quickConnect = "Quick connect"
        case hosts = "Hosts"
    }

    let id: String
    let action: PaletteAction
    let title: String
    let subtitle: String?
    let systemImage: String
    let trailingText: String?
    let section: Section

    static func == (lhs: PaletteRow, rhs: PaletteRow) -> Bool { lhs.id == rhs.id }
}

/// Observable state for the palette so the controller can drive
/// navigation from its NSEvent monitor without leaking monitors
/// through SwiftUI view lifetime.
final class HostSearchModel: ObservableObject {
    @Published var hosts: [DiscoveredHost] = []
    /// The user's saved Vaults hosts (managed in the Hosts dashboard).
    @Published var savedHosts: [SavedHost] = []
    @Published var search: String = ""
    @Published var highlightIndex: Int = 0

    func loadHosts() {
        savedHosts = SavedHostsStore.shared.hosts
        hosts = SSHConfigDiscovery.loadAll()
    }

    func reset() {
        search = ""
        highlightIndex = 0
    }

    /// Saved hosts matching the current query.
    private var filteredSavedHosts: [SavedHost] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return savedHosts }
        return savedHosts.filter { host in
            if host.displayLabel.lowercased().contains(q) { return true }
            if host.hostname.lowercased().contains(q) { return true }
            if host.username.lowercased().contains(q) { return true }
            return false
        }
    }

    /// Discovered (~/.ssh/config) hosts matching the current query.
    private var filteredHosts: [DiscoveredHost] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return hosts }
        return hosts.filter { host in
            if host.label.lowercased().contains(q) { return true }
            if let h = host.hostname?.lowercased(), h.contains(q) { return true }
            if let u = host.user?.lowercased(), u.contains(q) { return true }
            return false
        }
    }

    /// The full, ordered list of rows the palette renders. Quick-connect
    /// actions come first (the typed host, Local Terminal, Serial), then
    /// any matching saved hosts.
    var rows: [PaletteRow] {
        var result: [PaletteRow] = []
        let q = search.trimmingCharacters(in: .whitespaces)

        if !q.isEmpty {
            result.append(PaletteRow(
                id: "quick-connect",
                action: .quickConnect(q),
                title: q,
                subtitle: "Connect via SSH",
                systemImage: "bolt.horizontal.circle",
                trailingText: nil,
                section: .quickConnect
            ))
        }
        result.append(PaletteRow(
            id: "local-terminal",
            action: .localTerminal,
            title: "Local Terminal",
            subtitle: nil,
            systemImage: "terminal",
            trailingText: "⌘L",
            section: .quickConnect
        ))
        result.append(PaletteRow(
            id: "serial",
            action: .serial,
            title: "Serial",
            subtitle: nil,
            systemImage: "cable.connector",
            trailingText: "soon",
            section: .quickConnect
        ))

        // The user's own saved hosts first — they're the curated Vaults list.
        for host in filteredSavedHosts {
            result.append(PaletteRow(
                id: "saved-\(host.id)",
                action: .savedHost(host),
                title: host.displayLabel,
                subtitle: host.subtitle.isEmpty ? nil : host.subtitle,
                systemImage: "server.rack",
                trailingText: "saved",
                section: .hosts
            ))
        }

        // Then anything discovered in ~/.ssh/config (skipping labels already
        // covered by a saved host so we don't list the same name twice).
        let savedLabels = Set(filteredSavedHosts.map { $0.displayLabel.lowercased() })
        for host in filteredHosts where !savedLabels.contains(host.label.lowercased()) {
            result.append(PaletteRow(
                id: "host-\(host.id)",
                action: .host(host),
                title: host.label,
                subtitle: host.subtitle.isEmpty ? nil : host.subtitle,
                systemImage: "server.rack",
                trailingText: "ssh_config",
                section: .hosts
            ))
        }
        return result
    }

    func stepHighlight(_ delta: Int) {
        let n = rows.count
        guard n > 0 else { return }
        highlightIndex = (highlightIndex + delta + n) % n
    }

    func confirmSelection() -> PaletteRow? {
        let all = rows
        guard !all.isEmpty else { return nil }
        let safe = max(0, min(highlightIndex, all.count - 1))
        return all[safe]
    }
}

/// SwiftUI palette view. Pure renderer — all state + key handling
/// lives in `HostSearchModel` (driven by `HostSearchController`).
struct HostSearchPalette: View {
    @ObservedObject var model: HostSearchModel
    let onRun: (PaletteAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
                .frame(minHeight: 240, maxHeight: 360)
            Divider()
            footer
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: $model.search,
                prompt: Text("Search hosts or tabs").foregroundColor(.secondary)
            )
                .textFieldStyle(.plain)
                .font(.title3)
                // Explicit high-contrast color for typed text — the default
                // inherited color rendered nearly invisible on the dark panel.
                .foregroundStyle(.primary)
                .tint(.accentColor)
                .onChange(of: model.search) { _ in
                    model.highlightIndex = 0
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        let rows = model.rows
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                        if idx == 0 || rows[idx - 1].section != item.section {
                            sectionHeader(item.section.rawValue)
                        }
                        row(item: item, index: idx)
                            .id(idx)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.highlightIndex) { newIndex in
                withAnimation(.easeOut(duration: 0.1)) {
                    scroll.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(item: PaletteRow, index: Int) -> some View {
        let isHighlighted = index == model.highlightIndex
        return Button {
            onRun(item.action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .fontWeight(.medium)
                        .foregroundStyle(isHighlighted ? Color.accentColor : .primary)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let trailing = item.trailingText {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted ? Color.secondary.opacity(0.18) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { model.highlightIndex = index }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Quick connect, or pick a saved host")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            keyHint("↑↓ navigate")
            keyHint("⏎ open")
            keyHint("Esc cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func keyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .foregroundStyle(.secondary)
    }
}
