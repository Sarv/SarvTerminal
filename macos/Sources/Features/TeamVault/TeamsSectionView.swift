import SwiftUI

/// Vaults → Teams. Two tabs:
///   • **Hosts** — a collapsible tree Org ▸ Workspace ▸ Team ▸ Group ▸ Host,
///     with search, counts, lazy decrypt-on-expand, and double-click connect.
///   • **Files** — encrypted files shared with this user across teams.
struct TeamsSectionView: View {
    @ObservedObject private var store = VaultStore.shared

    enum Tab: String, CaseIterable, Identifiable { case hosts = "Hosts", files = "Files"; var id: String { rawValue }
        var icon: String { self == .hosts ? "server.rack" : "doc.on.doc" }
    }
    @State private var tab: Tab = .hosts
    @State private var query = ""

    // Expansion state. Orgs/workspaces default expanded (tracked by what's
    // collapsed); teams/groups default collapsed (tracked by what's expanded).
    @State private var collapsedOrgs: Set<String> = []
    @State private var collapsedWorkspaces: Set<String> = []
    @State private var expandedTeams: Set<String> = []
    @State private var expandedGroups: Set<String> = []

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if store.isAuthenticated {
                VStack(spacing: 0) {
                    header
                    Divider()
                    tabBar
                    Divider()
                    switch tab {
                    case .hosts: hostsTab
                    case .files: filesTab
                    }
                }
            } else {
                VaultsEmptyState(icon: "clock", title: "Team Vaults — coming soon",
                                 subtitle: "Shared team vaults aren't available yet. This feature is coming soon.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if store.isAuthenticated && store.teams.isEmpty { store.refreshTeams() } }
    }

    // MARK: Header + tabs

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.accentColor)
            Text(store.activeEmail ?? "Signed in").font(.callout.weight(.medium))
            if store.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            if let status = store.statusMessage { Text(status).font(.caption).foregroundStyle(.secondaryText).lineLimit(1) }
            Button { store.refreshTeams() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon)
                        Text(t.rawValue)
                    }
                    .font(.callout.weight(tab == t ? .semibold : .regular))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tab == t ? Color.accentColor : Color.secondary.opacity(0.12)))
                    .foregroundStyle(tab == t ? Color.white : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Hosts tab

    private var visibleTeams: [TeamSummary] {
        switch store.filter {
        case .all: return store.teams
        case .team(let id): return store.teams.filter { $0.id == id }
        }
    }

    private var visibleOrgs: [OrgRef] {
        var seen = Set<String>(); var result: [OrgRef] = []
        for t in visibleTeams where !seen.contains(t.org.id) { seen.insert(t.org.id); result.append(t.org) }
        return result
    }

    private var hostsTab: some View {
        VStack(spacing: 0) {
            searchAndFilter
            Divider()
            if store.teams.isEmpty {
                VaultsEmptyState(icon: "person.2", title: "No teams", subtitle: "You're not a member of any team vault yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleOrgs, id: \.id) { org in orgNode(org) }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var searchAndFilter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText).font(.caption)
                TextField("Search hosts", text: $query).textFieldStyle(.plain)
                if searching { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondaryText) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All teams", filter: .all)
                    ForEach(store.teams) { team in chip(team.name, filter: .team(team.id)) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func chip(_ label: String, filter: VaultFilter) -> some View {
        let selected = store.filter == filter
        return Button { store.filter = filter } label: {
            Text(label).font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(selected ? Color.white : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Tree nodes

    @ViewBuilder
    private func orgNode(_ org: OrgRef) -> some View {
        let expanded = searching || !collapsedOrgs.contains(org.id)
        DisclosureRow(level: 0, icon: "building.2", title: org.name, expanded: expanded) {
            toggle(&collapsedOrgs, org.id, collapsedDefault: false)
        }
        if expanded {
            let teams = visibleTeams.filter { $0.org.id == org.id }
            ForEach(workspaces(in: teams), id: \.id) { ws in
                let wsExpanded = searching || !collapsedWorkspaces.contains(ws.id)
                DisclosureRow(level: 1, icon: "rectangle.stack", title: ws.name, expanded: wsExpanded) {
                    toggle(&collapsedWorkspaces, ws.id, collapsedDefault: false)
                }
                if wsExpanded {
                    ForEach(teams.filter { $0.workspace.id == ws.id }) { team in teamNode(team) }
                }
            }
        }
    }

    @ViewBuilder
    private func teamNode(_ team: TeamSummary) -> some View {
        let expanded = searching || expandedTeams.contains(team.id)
        let count = store.teamPayloads[team.id]?.hosts.count
        DisclosureRow(level: 2, icon: "person.2.fill", title: team.name,
                      trailing: count.map { "\($0)" }, loading: store.loadingTeamIDs.contains(team.id),
                      expanded: expanded) {
            toggle(&expandedTeams, team.id, collapsedDefault: true)
            store.ensureHostsLoaded(for: team)
        }
        .onAppear { if expanded { store.ensureHostsLoaded(for: team) } }

        if expanded { teamBody(team) }
    }

    @ViewBuilder
    private func teamBody(_ team: TeamSummary) -> some View {
        if let err = store.teamErrors[team.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(friendlyError(err)).font(.caption).foregroundStyle(.orange)
                #if DEBUG
                Button("Initialize vault with sample data") { store.initializeVaultWithSampleData(team) }
                    .controlSize(.small).disabled(store.isBusy)
                #endif
            }
            .padding(.leading, 64).padding(.trailing, 16).padding(.bottom, 6)
        } else {
            let hosts = filtered(store.hosts(for: team.id))
            let groups = store.groups(for: team.id)
            ForEach(groups) { group in
                let gHosts = hosts.filter { $0.groupID == group.id }
                if !gHosts.isEmpty || !searching {
                    let gExpanded = searching || expandedGroups.contains(group.id.uuidString)
                    DisclosureRow(level: 3, icon: "folder", title: group.name, trailing: "\(gHosts.count)", expanded: gExpanded) {
                        toggle(&expandedGroups, group.id.uuidString, collapsedDefault: true)
                    }
                    if gExpanded { ForEach(gHosts) { host in hostRow(host) } }
                }
            }
            ForEach(hosts.filter { $0.groupID == nil }) { host in hostRow(host) }
            if hosts.isEmpty && store.teamPayloads[team.id] != nil {
                Text(searching ? "No matches." : "Empty vault.").font(.caption).foregroundStyle(.secondaryText)
                    .padding(.leading, 64).padding(.vertical, 4)
            }
        }
    }

    private func hostRow(_ host: SavedHost) -> some View {
        HostRowView(host: host) { store.connect(to: host) }
    }

    // MARK: Files tab

    private var filesTab: some View {
        Group {
            if store.teams.isEmpty {
                VaultsEmptyState(icon: "doc.on.doc", title: "No teams", subtitle: "Files shared in your teams will appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.teams) { team in filesForTeam(team) }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear { store.teams.forEach { store.ensureFilesLoaded(for: $0) } }
            }
        }
    }

    @ViewBuilder
    private func filesForTeam(_ team: TeamSummary) -> some View {
        let files = store.filesByTeam[team.id] ?? []
        if !files.isEmpty {
            DisclosureRow(level: 0, icon: "person.2.fill", title: "\(team.org.name) › \(team.name)", trailing: "\(files.count)", expanded: true) {}
            ForEach(files) { file in
                HStack(spacing: 12) {
                    Image(systemName: fileIcon(file)).foregroundStyle(.secondaryText).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).fontWeight(.medium)
                        Text("\(byteString(file.sizeBytes)) · \(file.contentType)").font(.caption).foregroundStyle(.secondaryText)
                    }
                    Spacer()
                    Button { store.downloadFile(file, from: team) } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless).help("Decrypt & download to ~/Downloads")
                }
                .padding(.leading, 36).padding(.trailing, 16).padding(.vertical, 7)
            }
        }
    }

    // MARK: Helpers

    private func workspaces(in teams: [TeamSummary]) -> [WorkspaceRef] {
        var seen = Set<String>(); var result: [WorkspaceRef] = []
        for t in teams where !seen.contains(t.workspace.id) { seen.insert(t.workspace.id); result.append(t.workspace) }
        return result
    }

    private func filtered(_ hosts: [SavedHost]) -> [SavedHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return hosts }
        return hosts.filter {
            $0.label.lowercased().contains(q) || $0.hostname.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String, collapsedDefault: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
        }
    }

    private func friendlyError(_ err: String) -> String {
        err.contains("CryptoKit")
            ? "Couldn't decrypt this vault — your device key changed. Re-initialize (debug) or ask a member to re-share access."
            : err
    }

    private func fileIcon(_ file: TeamFileMeta) -> String {
        let n = file.name.lowercased()
        if n.hasSuffix(".pem") || n.hasSuffix(".key") || n.contains("id_") { return "key" }
        if n.hasSuffix(".crt") || n.hasSuffix(".cert") || n.hasSuffix(".pub") { return "checkmark.seal" }
        if n.hasSuffix(".txt") { return "doc.text" }
        return "doc"
    }

    private func byteString(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}

/// A collapsible tree row: chevron + icon + title, indented by `level`, with an
/// optional trailing count and a spinner.
private struct DisclosureRow: View {
    let level: Int
    let icon: String
    let title: String
    var trailing: String? = nil
    var loading: Bool = false
    let expanded: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondaryText).frame(width: 10)
                Image(systemName: icon).font(.caption).foregroundStyle(.secondaryText).frame(width: 16)
                Text(title).font(level <= 1 ? .subheadline.weight(.semibold) : .callout.weight(.medium))
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiaryText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15))) }
            }
            .padding(.leading, CGFloat(12 + level * 16)).padding(.trailing, 14).padding(.vertical, 5)
            .background(hovering ? Color.secondary.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A team host row with double-click / hover-Connect auto-connect.
private struct HostRowView: View {
    let host: SavedHost
    let connect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.secondaryText).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.label).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondaryText)
            }
            Spacer()
            if hovering { Button("Connect", action: connect).controlSize(.small) }
        }
        .padding(.leading, 72).padding(.trailing, 16).padding(.vertical, 6)
        .background(hovering ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: connect)
        .help("Double-click to connect")
    }

    private var subtitle: String {
        let user = host.username.isEmpty ? "" : "\(host.username)@"
        return "\(user)\(host.hostname) · port \(host.port)"
    }
}
