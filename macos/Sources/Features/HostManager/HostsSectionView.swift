import SwiftUI
import AppKit

/// Vaults > Hosts main area.
///
/// Layout is Termius-style:
/// - Sticky header: quick-connect + actions + view/tag/sort
/// - Breadcrumb (only visible when drilled into a group)
/// - **Groups** section: sub-groups at the current level
/// - **Hosts** section: hosts in the current scope (root = all; group = recursive)
///
/// Grid view is the default. List view renders the same two sections as
/// full-width rows.
struct HostsSectionView: View {
    @ObservedObject private var hostsStore  = SavedHostsStore.shared
    @ObservedObject private var groupsStore = HostGroupsStore.shared
    @ObservedObject private var hostSelection = HostManagerSelection.shared

    /// Single input that doubles as filter (live, as you type) and as an
    /// ssh-command runner (press Enter / click Connect). Matches the
    /// Termius dashboard's "Find a host or ssh user@hostname…" bar.
    @State private var quickConnect: String = ""
    @State private var hostDraft: SavedHost? = nil
    @State private var groupDraft: HostGroup? = nil
    @State private var isNew: Bool = false
    @State private var newHostSeed: String = ""
    /// Auto-label given to an unnamed in-progress draft ("Unnamed",
    /// "Unnamed (2)", …) — assigned once per editing session so the list
    /// entry doesn't jump around while typing.
    @State private var draftAutoLabel: String? = nil

    /// nil = root level ("All hosts"). When set, the user has drilled into
    /// a group. Backed by the shared selection store so drilling survives a
    /// switch to a terminal tab and back.
    private var focusedGroupID: UUID? {
        get { hostSelection.hostsFocusedGroupID }
        nonmutating set { hostSelection.hostsFocusedGroupID = newValue }
    }

    /// Root-level view mode — the default for every level without an override
    /// of its own. Persisted across launches.
    @State private var defaultViewMode: HostsViewMode =
        HostsViewMode(rawValue: UserDefaults.standard.string(forKey: HostsSectionView.defaultViewModeKey) ?? "") ?? .grid
    /// Per-group view overrides, keyed by group id. Set when the user picks a
    /// view while drilled into a group; levels without an entry fall back to
    /// `defaultViewMode`. Persisted across launches.
    @State private var viewModeOverrides: [UUID: HostsViewMode] = HostsSectionView.loadViewModeOverrides()
    @State private var sortMode: HostsSortMode = .azAscending
    @State private var tagFilter: String? = nil
    @State private var showImporter = false
    @State private var contentWidth: CGFloat = 0

    // MARK: - View mode persistence

    private static let defaultViewModeKey = "SarvHostsViewModeDefault"
    private static let viewModeOverridesKey = "SarvHostsViewModeByGroup"

    private static func loadViewModeOverrides() -> [UUID: HostsViewMode] {
        guard let raw = UserDefaults.standard.dictionary(forKey: viewModeOverridesKey) as? [String: String]
        else { return [:] }
        var result: [UUID: HostsViewMode] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), let mode = HostsViewMode(rawValue: value) else { continue }
            result[id] = mode
        }
        return result
    }

    /// View mode for the current level: the group's own override if it has
    /// one, otherwise the root default.
    private var viewMode: HostsViewMode {
        if let id = focusedGroupID, let override = viewModeOverrides[id] { return override }
        return defaultViewMode
    }

    /// At root the picker sets the default; inside a group it saves an
    /// override for just that group.
    private func setViewMode(_ mode: HostsViewMode) {
        if let id = focusedGroupID {
            viewModeOverrides[id] = mode
            let raw = Dictionary(uniqueKeysWithValues:
                viewModeOverrides.map { ($0.key.uuidString, $0.value.rawValue) })
            UserDefaults.standard.set(raw, forKey: Self.viewModeOverridesKey)
        } else {
            defaultViewMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultViewModeKey)
        }
    }

    private var viewModeBinding: Binding<HostsViewMode> {
        Binding(get: { viewMode }, set: { setViewMode($0) })
    }

    enum HostsViewMode: String, CaseIterable, Identifiable {
        case grid   // adaptive card grid
        case list   // full-width rows

        var id: String { rawValue }

        var label: String {
            switch self {
            case .grid: return "Grid"
            case .list: return "List"
            }
        }

        /// Icon for *this* mode — shown in the toolbar for the active mode and
        /// beside each option in the menu.
        var systemImage: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    enum HostsSortMode: String, CaseIterable {
        case azAscending, azDescending, newestFirst, oldestFirst
        var label: String {
            switch self {
            case .azAscending:   return "A–Z"
            case .azDescending:  return "Z–A"
            case .newestFirst:   return "Newest first"
            case .oldestFirst:   return "Oldest first"
            }
        }
        var systemImage: String {
            switch self {
            case .azAscending:   return "textformat.abc"
            case .azDescending:  return "textformat.abc.dottedunderline"
            case .newestFirst:   return "calendar.badge.clock"
            case .oldestFirst:   return "calendar"
            }
        }
    }

    var body: some View {
        listMode
        // Editors slide in as a trailing side panel over the dashboard (same
        // pattern as the SSH popup's "Edit host"), so the list stays visible
        // and navigation is never lost.
        .overlay {
            if hostDraft != nil {
                VaultsEditorSidebar(onClose: { cancel() }) {
                    HostEditorView(
                        // The set ignores writes after close: fields committing
                        // on focus-loss during the dismiss animation must not
                        // resurrect the draft (= the panel popping back open).
                        draft: Binding(get: { hostDraft ?? .blank() },
                                       set: { if hostDraft != nil { hostDraft = $0 } }),
                        isNew: isNew,
                        onCancel: { cancel() },
                        onDelete: isNew
                            ? { discardNewHostDraft() }
                            : { confirmDeleteHost(hostDraft!, fromEditor: true) },
                        onConnect: { connectHostDraft() },
                        onAutosave: { autosaveDraftNow() }
                    )
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if groupDraft != nil {
                VaultsEditorSidebar(onClose: { cancel() }) {
                    GroupEditorView(
                        draft: Binding(get: { groupDraft ?? .blank() },
                                       set: { if groupDraft != nil { groupDraft = $0 } }),
                        isNew: isNew,
                        onSave:   { saveGroupDraft() },
                        onCancel: { cancel() },
                        onDelete: isNew ? nil : { confirmDeleteGroup(groupDraft!, fromEditor: true) }
                    )
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hostDraft == nil)
        .animation(.easeOut(duration: 0.12), value: groupDraft == nil)
        // "Edit host" from the SSH connection popup sets a pending host id;
        // open its editor when we appear / when it changes (using the freshest
        // host from the store so a just-saved password shows).
        .onAppear { openPendingEditHostIfNeeded() }
        .onChange(of: hostSelection.pendingEditHostID) { _ in openPendingEditHostIfNeeded() }
        .sheet(isPresented: $showImporter) { ImportHostsView() }
    }

    private func openPendingEditHostIfNeeded() {
        guard let id = hostSelection.pendingEditHostID,
              let host = hostsStore.hosts.first(where: { $0.id == id }) else { return }
        hostSelection.pendingEditHostID = nil
        editExistingHost(host)
    }

    // MARK: - List mode (the dashboard)

    private var listMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickConnectBar
            actionRow
            Divider()
            if hostsStore.hosts.isEmpty && groupsStore.groups.isEmpty {
                emptyState
            } else {
                contentArea
            }
        }
    }

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if focusedGroupID != nil { breadcrumb }
                groupsSection
                hostsSection
                if isFilteringAndEmpty { noMatchesState }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { contentWidth = geo.size.width }
                        .onChange(of: geo.size.width) { contentWidth = $0 }
                }
            )
        }
    }

    // MARK: - Top bars

    /// Termius-style dashboard bar — one input, two jobs:
    /// - Live-filters hosts/groups as the user types.
    /// - Pressing Enter or clicking the trailing "Connect" pill runs the
    ///   text as an ssh command (when it looks like one).
    private var quickConnectBar: some View {
        HStack(spacing: 8) {
            TextField("Find a host or ssh user@hostname…", text: $quickConnect)
                .textFieldStyle(.plain)
                .onSubmit { quickConnectGo() }
            if !quickConnect.isEmpty {
                Button { quickConnect = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button(action: quickConnectGo) {
                Text("Connect")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(canConnectQuick
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(canConnectQuick ? Color.white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canConnectQuick)
            .help(canConnectQuick
                  ? "Run as ssh command"
                  : "Type ssh user@hostname to connect")
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
        .padding(.horizontal, 16).padding(.top, 16)
    }

    /// True when the quick-connect text looks like something we can ssh
    /// into (contains `@` or starts with `ssh `). Plain filter strings
    /// don't enable the Connect button.
    private var canConnectQuick: Bool {
        let t = quickConnect.trimmingCharacters(in: .whitespaces).lowercased()
        return !t.isEmpty && (t.hasPrefix("ssh ") || t.contains("@"))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            newHostSplitButton
            actionPill(label: "Import", systemImage: "square.and.arrow.down") {
                showImporter = true
            }
            actionPill(label: "Terminal", systemImage: "terminal") {
                VaultsTabsModel.shared.newTerminal(command: nil, name: "Terminal")
            }
            actionPill(label: "Serial",   systemImage: "cable.connector") {
                VaultsTabsModel.shared.presentingSerialConnect = true
            }
            Spacer()
            rightActionIcons
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var newHostSplitButton: some View {
        HStack(spacing: 0) {
            Button {
                startNewHost(seedHostname: "", parentGroupID: focusedGroupID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New host")
                }
                .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16).opacity(0.4)

            Menu {
                Button("New Group", systemImage: "folder.badge.plus") {
                    startNewGroup(parentID: focusedGroupID)
                }
                Divider()
                Section("Cloud (coming soon)") {
                    Button("AWS Integration", systemImage: "cloud") {} .disabled(true)
                    Button("DigitalOcean Integration", systemImage: "cloud") {} .disabled(true)
                    Button("Azure Integration", systemImage: "cloud") {} .disabled(true)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
        )
    }

    private func actionPill(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var rightActionIcons: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("View", selection: viewModeBinding) {
                    ForEach(HostsViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                rightIcon(systemImage: viewMode.systemImage)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("View: \(viewMode.label)")

            Menu {
                Button("Show all (clear filter)", systemImage: "xmark.circle") {
                    tagFilter = nil
                }
                .disabled(tagFilter == nil)
                Divider()
                let tags = allKnownTags
                if tags.isEmpty {
                    Text("No tags yet").foregroundStyle(.secondaryText)
                } else {
                    ForEach(tags, id: \.self) { t in
                        Button {
                            tagFilter = (tagFilter == t) ? nil : t
                        } label: {
                            if tagFilter == t {
                                Label(t, systemImage: "checkmark")
                            } else {
                                Text(t)
                            }
                        }
                    }
                }
            } label: {
                rightIcon(systemImage: "tag", highlighted: tagFilter != nil)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tagFilter == nil ? "Filter by tag" : "Filtering: \(tagFilter ?? "")")

            Menu {
                ForEach(HostsSortMode.allCases, id: \.self) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        if sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Label(mode.label, systemImage: mode.systemImage)
                        }
                    }
                }
            } label: {
                // Calendar glyph matches the Termius dashboard's third
                // right-side icon. The actual sort mode is still reflected
                // in the menu (checkmark on the selected row) — only the
                // bar icon is fixed.
                rightIcon(systemImage: "calendar")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Sort: \(sortMode.label)")

            avatarPlusGroup
        }
    }

    /// Decorative avatar circle + small "+" pill, matching the screenshot's
    /// top-right cluster. Non-functional for now — single-user fork doesn't
    /// have profiles yet.
    private var avatarPlusGroup: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                    .frame(width: 26, height: 26)
                Image(systemName: "person.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondaryText)
            }
            .help("Profile (coming soon)")

            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Add profile (coming soon)")
        }
        .padding(.leading, 4)
    }

    private func rightIcon(systemImage: String, highlighted: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14))
            .frame(width: 28, height: 28)
            .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private var allKnownTags: [String] {
        var set = Set<String>()
        var ordered: [String] = []
        for h in hostsStore.hosts {
            for t in h.tags where !set.contains(t) {
                set.insert(t); ordered.append(t)
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        let items = breadcrumbItems()
        return HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiaryText)
                }
                Button {
                    focusedGroupID = item.id
                } label: {
                    Text(item.name)
                        .foregroundStyle(i == items.count - 1 ? .primary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(i == items.count - 1)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func breadcrumbItems() -> [(name: String, id: UUID?)] {
        var items: [(String, UUID?)] = [("All hosts", nil)]
        guard let focused = focusedGroupID else { return items }
        var stack: [HostGroup] = []
        var current: UUID? = focused
        var seen = Set<UUID>()
        while let id = current, !seen.contains(id),
              let g = groupsStore.groups.first(where: { $0.id == id }) {
            stack.insert(g, at: 0)
            seen.insert(id)
            current = g.parentID
        }
        for g in stack { items.append((g.displayName, g.id)) }
        return items
    }

    // MARK: - Sections

    /// Responsive grid, always ≥4 cards per row: an extra column appears per
    /// ~342pt of width, and the cards STRETCH to fill the row at every size —
    /// no max cap, so small windows shrink the cards and big screens give each
    /// card the extra width instead of leaving dead space.
    private var gridColumns: [GridItem] {
        let spacing: CGFloat = 12
        let preferredCardWidth: CGFloat = 330
        let fit = Int((contentWidth + spacing) / (preferredCardWidth + spacing))
        let count = max(4, fit)
        return Array(repeating: GridItem(.flexible(minimum: 200), spacing: spacing), count: count)
    }

    private var groupsSection: some View {
        let groups = sortGroups(
            groupsStore.children(of: focusedGroupID).filter { groupShouldBeVisible($0) }
        )
        return Group {
            if !groups.isEmpty {
                sectionHeader("Groups")
                if viewMode == .grid {
                    LazyVGrid(
                        columns: gridColumns,
                        alignment: .leading, spacing: 12
                    ) {
                        ForEach(groups) { group in
                            groupCardView(group)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(groups) { group in
                            groupListRowView(group)
                        }
                    }
                }
            }
        }
    }

    private var hostsSection: some View {
        let hosts = sortHosts(currentHosts())
        return Group {
            if !hosts.isEmpty {
                sectionHeader("Hosts")
                if viewMode == .grid {
                    LazyVGrid(
                        columns: gridColumns,
                        alignment: .leading, spacing: 12
                    ) {
                        ForEach(hosts) { host in
                            hostCardView(host)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(hosts) { host in
                            hostListRowView(host)
                        }
                    }
                }
            } else if !groupsStore.children(of: focusedGroupID).isEmpty {
                // Don't show empty "Hosts" header when there are only groups.
                EmptyView()
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    // MARK: - Current scope

    /// Hosts to show in the current scope. At root, ALL hosts (matches
    /// Termius dashboard). Inside a group, hosts directly in that group
    /// (not recursive — sub-groups have their own pages).
    private func currentHosts() -> [SavedHost] {
        let base: [SavedHost]
        if let id = focusedGroupID {
            // Same pattern as root: a group level shows EVERY host beneath it
            // (its own + all descendant groups'), not just direct children.
            base = hostsStore.recursiveHosts(in: id, groupsStore: groupsStore)
        } else {
            base = hostsStore.hosts
        }
        return base.filter(hostPassesAllFilters)
    }

    // MARK: - Cards & rows

    private func groupCardView(_ group: HostGroup) -> some View {
        GroupCard(
            onConnectAll:  { connectGroup(group) },
            group: group,
            parentPath: parentPath(for: group),
            hostCount: hostsStore.recursiveCount(in: group.id, groupsStore: groupsStore),
            onOpen:        { focusedGroupID = group.id },
            onEdit:        { editExistingGroup(group) },
            onAddHost:     { startNewHost(seedHostname: "", parentGroupID: group.id) },
            onAddSubgroup: { startNewGroup(parentID: group.id) },
            onDelete:      { confirmDeleteGroup(group, fromEditor: false) },
            onMoveToBuilder: { moveMenuContent(for: group) }
        )
    }

    private func groupListRowView(_ group: HostGroup) -> some View {
        GroupListRow(
            onConnectAll:  { connectGroup(group) },
            group: group,
            parentPath: parentPath(for: group),
            hostCount: hostsStore.recursiveCount(in: group.id, groupsStore: groupsStore),
            onOpen:        { focusedGroupID = group.id },
            onEdit:        { editExistingGroup(group) },
            onAddHost:     { startNewHost(seedHostname: "", parentGroupID: group.id) },
            onAddSubgroup: { startNewGroup(parentID: group.id) },
            onDelete:      { confirmDeleteGroup(group, fromEditor: false) },
            onMoveToBuilder: { moveMenuContent(for: group) }
        )
    }

    private func hostCardView(_ host: SavedHost) -> some View {
        HostCard(
            host: host,
            groupPath: groupsStore.path(for: host.groupID),
            onOpen:    { editExistingHost(host) },
            onConnect: { connect(host) },
            onDuplicate: {
                let copy = hostsStore.duplicate(host)
                editExistingHost(copy)
            },
            onDelete:  { confirmDeleteHost(host, fromEditor: false) },
            onMoveToBuilder: { moveMenuContent(for: host) }
        )
    }

    private func hostListRowView(_ host: SavedHost) -> some View {
        HostListRow(
            host: host,
            groupPath: groupsStore.path(for: host.groupID),
            onOpen:    { editExistingHost(host) },
            onConnect: { connect(host) },
            onDuplicate: {
                let copy = hostsStore.duplicate(host)
                editExistingHost(copy)
            },
            onDelete:  { confirmDeleteHost(host, fromEditor: false) },
            onMoveToBuilder: { moveMenuContent(for: host) }
        )
    }

    private func parentPath(for group: HostGroup) -> String {
        guard let pid = group.parentID else { return "" }
        return groupsStore.path(for: pid)
    }

    // MARK: - Filtering / sorting

    private func sortGroups(_ list: [HostGroup]) -> [HostGroup] {
        switch sortMode {
        case .azAscending:
            return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .azDescending:
            return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .newestFirst: return list.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst: return list.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func sortHosts(_ list: [SavedHost]) -> [SavedHost] {
        switch sortMode {
        case .azAscending:
            return list.sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending }
        case .azDescending:
            return list.sorted { $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedDescending }
        case .newestFirst: return list.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst: return list.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func hostPassesAllFilters(_ host: SavedHost) -> Bool {
        if let tag = tagFilter, !host.tags.contains(tag) { return false }
        return hostMatches(host)
    }

    /// Text from the quick-connect bar that should be applied as a filter.
    /// Skipped when the user is mid-typing an ssh command (looks like one)
    /// so the list doesn't collapse to nothing while they finish.
    private var filterText: String {
        canConnectQuick ? "" : quickConnect.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func hostMatches(_ host: SavedHost) -> Bool {
        SearchMatcher.matches(filterText, in: [host.displayLabel, host.hostname, host.username] + host.tags)
    }

    private func groupShouldBeVisible(_ group: HostGroup) -> Bool {
        if filterText.isEmpty && tagFilter == nil {
            return true
        }
        let ids = groupsStore.descendants(of: group.id).union([group.id])
        return hostsStore.hosts.contains { h in
            guard let gid = h.groupID, ids.contains(gid) else { return false }
            return hostPassesAllFilters(h)
        }
    }

    private var isFilteringAndEmpty: Bool {
        guard !filterText.isEmpty || tagFilter != nil else { return false }
        let anyGroupVisible = groupsStore.children(of: focusedGroupID).contains(where: groupShouldBeVisible)
        let anyHostVisible = !currentHosts().isEmpty
        return !anyGroupVisible && !anyHostVisible
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiaryText)
            Text("No matches").font(.headline)
            Text("Try a different search term.").font(.caption).foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - "Move to" submenu

    @ViewBuilder
    private func moveMenuContent(for host: SavedHost) -> some View {
        Button("No group (root)") { hostsStore.setGroup(host, to: nil) }
            .disabled(host.groupID == nil)
        Divider()
        ForEach(groupsStore.flatTree(), id: \.group.id) { (group, depth) in
            Button(String(repeating: "    ", count: depth) + group.displayName) {
                hostsStore.setGroup(host, to: group.id)
            }
            .disabled(host.groupID == group.id)
        }
    }

    @ViewBuilder
    private func moveMenuContent(for group: HostGroup) -> some View {
        let blocked = groupsStore.descendants(of: group.id).union([group.id])
        Button("No parent (root)") { groupsStore.setParent(group.id, to: nil) }
            .disabled(group.parentID == nil)
        Divider()
        ForEach(groupsStore.flatTree(), id: \.group.id) { (g, depth) in
            Button(String(repeating: "    ", count: depth) + g.displayName) {
                groupsStore.setParent(group.id, to: g.id)
            }
            .disabled(blocked.contains(g.id) || group.parentID == g.id)
        }
    }

    // MARK: - Empty / state actions

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: "server.rack")
                        .font(.system(size: 30))
                        .foregroundStyle(.primary)
                }
                VStack(spacing: 4) {
                    Text("Create host").font(.title2.weight(.semibold))
                    Text("Save your connection details as hosts to connect in one click.")
                        .foregroundStyle(.secondaryText)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    TextField("Type IP or Hostname", text: $newHostSeed)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                        )
                        .onSubmit {
                            startNewHost(seedHostname: newHostSeed, parentGroupID: nil)
                        }
                    Button {
                        startNewHost(seedHostname: newHostSeed, parentGroupID: nil)
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        newHostSeed.trimmingCharacters(in: .whitespaces).isEmpty
                                            ? Color.accentColor.opacity(0.4)
                                            : Color.accentColor
                                    )
                            )
                            .foregroundStyle(.white)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(newHostSeed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(maxWidth: 480)
            }
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func startNewHost(seedHostname: String, parentGroupID: UUID?) {
        var seed = SavedHost.blank(hostname: seedHostname.trimmingCharacters(in: .whitespaces))
        seed.groupID = parentGroupID
        hostDraft = seed
        groupDraft = nil
        isNew = true
    }

    private func editExistingHost(_ host: SavedHost) {
        hostDraft = host
        groupDraft = nil
        isNew = false
    }

    private func startNewGroup(parentID: UUID?) {
        groupDraft = HostGroup.blank(parentID: parentID)
        hostDraft = nil
        isNew = true
    }

    private func editExistingGroup(_ group: HostGroup) {
        groupDraft = group
        hostDraft = nil
        isNew = false
    }

    private func saveGroupDraft() {
        guard let d = groupDraft,
              !d.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        groupsStore.upsert(d)
        cancel()
    }

    private func cancel() {
        // With no explicit Save button, Close is the commit point for any
        // still-focused field — flush the draft (new or edit) before closing.
        autosaveDraftNow()
        draftAutoLabel = nil
        hostDraft = nil
        groupDraft = nil
        newHostSeed = ""
    }

    /// Throw away a new-host draft entirely: remove any autosaved copy from
    /// the store and close WITHOUT the usual close-flush (which would re-save).
    private func discardNewHostDraft() {
        if let d = hostDraft { hostsStore.delete(d) }   // no-op if never autosaved
        hostDraft = nil
        draftAutoLabel = nil
        groupDraft = nil
        newHostSeed = ""
    }

    // MARK: - Draft autosave

    /// Persists the in-progress host draft (new AND edit) — fired by the
    /// editor whenever a field with data loses focus or a toggle/picker
    /// changes, so the list card updates live field by field. New drafts
    /// with no label get a unique "Unnamed" label until the user names them.
    @discardableResult
    private func autosaveDraftNow() -> Bool {
        guard var d = hostDraft, hostDraftHasContent(d) else { return false }
        if isNew, d.label.trimmingCharacters(in: .whitespaces).isEmpty {
            if draftAutoLabel == nil { draftAutoLabel = nextUnnamedLabel() }
            d.label = draftAutoLabel ?? "Unnamed"
        }
        // No-op when nothing actually changed (e.g. focusing a field and
        // leaving without editing) — the "Saved" flash only shows real saves.
        if let existing = hostsStore.hosts.first(where: { $0.id == d.id }),
           existing.contentEquals(d) {
            return false
        }
        d.updatedAt = Date()
        hostsStore.upsert(d)
        return true
    }

    /// "Filled at least one info" — any non-default field worth keeping.
    private func hostDraftHasContent(_ h: SavedHost) -> Bool {
        let texts = [h.hostname, h.label, h.username, h.password, h.note,
                     h.identityFile, h.proxyJump, h.initialCommand]
        if texts.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { return true }
        return !h.tags.isEmpty || !h.localForwards.isEmpty || !h.remoteForwards.isEmpty
            || h.dynamicForwardPort != 0 || h.port != 22
    }

    private func nextUnnamedLabel() -> String {
        let existing = Set(hostsStore.hosts.map(\.label))
        if !existing.contains("Unnamed") { return "Unnamed" }
        var n = 2
        while existing.contains("Unnamed (\(n))") { n += 1 }
        return "Unnamed (\(n))"
    }

    private func confirmDeleteHost(_ host: SavedHost, fromEditor: Bool) {
        // Shared centered-logo confirm — ONE delete semantic everywhere.
        DeleteConfirmation.confirm(
            host.displayLabel,
            detail: "This removes the saved host from Sarv Terminal. The remote server isn't affected.") { confirmed in
            guard confirmed else { return }
            hostsStore.delete(host)
            if fromEditor {
                // Drop the draft BEFORE cancel() — its close-flush would
                // otherwise re-upsert (resurrect) the host just deleted.
                hostDraft = nil
                cancel()
            }
        }
    }

    private func confirmDeleteGroup(_ group: HostGroup, fromEditor: Bool) {
        let inGroup = hostsStore.recursiveCount(in: group.id, groupsStore: groupsStore)
        let subGroups = groupsStore.descendants(of: group.id).count
        var detail: [String] = []
        if inGroup > 0 {
            detail.append("\(inGroup) host\(inGroup == 1 ? "" : "s") inside will become ungrouped (the hosts aren't deleted).")
        }
        if subGroups > 0 {
            detail.append("\(subGroups) sub-group\(subGroups == 1 ? "" : "s") will move up to this group's parent.")
        }
        if detail.isEmpty { detail.append("This group is empty.") }
        // Shared centered-logo confirm — ONE delete semantic everywhere.
        DeleteConfirmation.confirm(group.displayName, detail: detail.joined(separator: "\n")) { confirmed in
            guard confirmed else { return }
            // Drill out if we were focused on this group.
            if focusedGroupID == group.id { focusedGroupID = group.parentID }
            hostsStore.unsetGroup(group.id)
            groupsStore.delete(group.id)
            if fromEditor { cancel() }
        }
    }

    private func connectHostDraft() {
        guard var d = hostDraft, d.canConnect else { return }
        // Normalize, keeping the session's "Unnamed (n)" identity if assigned.
        if d.label.trimmingCharacters(in: .whitespaces).isEmpty {
            d.label = draftAutoLabel ?? d.hostname
        }
        if d.port <= 0 || d.port > 65_535 { d.port = 22 }
        hostsStore.upsert(d)
        // Clear before cancel() so its flush can't re-upsert the
        // pre-normalization draft over the version saved above.
        hostDraft = nil
        cancel()
        connect(d)
    }

    private func connect(_ host: SavedHost) {
        guard host.canConnect else { return }
        // Guided staged connect: the popup walks handshake → host key →
        // password → connected over the real ssh session in the new tab.
        HostConnect.run(
            command: host.sshCommand(staged: true),
            name: host.label,
            host: host,
            staged: true)
    }

    /// Connect to every host in a group (and its subgroups) at once — opens one
    /// tab per host and runs each guided connect, matching the count shown on
    /// the group row.
    private func connectGroup(_ group: HostGroup) {
        let ids = groupsStore.descendants(of: group.id).union([group.id])
        let hosts = hostsStore.hosts.filter { host in
            guard let gid = host.groupID else { return false }
            return ids.contains(gid)
        }
        for host in hosts where host.canConnect { connect(host) }
    }

    private func quickConnectGo() {
        let cmd = quickConnect.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        HostConnect.run(command: cmd.hasPrefix("ssh ") ? cmd : "ssh \(cmd)", name: cmd)
        quickConnect = ""
    }

    private func importFromSSHConfig() {
        let discovered = SSHConfigDiscovery.loadAll()
        var added = 0
        for d in discovered {
            let host = d.hostname ?? d.label
            let user = d.user ?? ""
            let alreadySaved = hostsStore.hosts.contains {
                $0.hostname.lowercased() == host.lowercased() &&
                $0.username.lowercased() == user.lowercased()
            }
            if alreadySaved { continue }
            var saved = SavedHost.blank(hostname: host)
            saved.label = d.label
            saved.username = user
            saved.port = d.port ?? 22
            hostsStore.upsert(saved)
            added += 1
        }
        SarvAlert.present(
            title: added == 0 ? "Nothing to import"
                              : "Imported \(added) host\(added == 1 ? "" : "s")",
            message: added == 0
                ? "All hosts in ~/.ssh/config are already saved."
                : "Imported from ~/.ssh/config.",
            buttons: [.init("OK", isDefault: true)])
    }
}

// MARK: - Group card / row

private struct GroupCard<MoveMenu: View>: View {
    let onConnectAll: () -> Void
    let group: HostGroup
    let parentPath: String
    let hostCount: Int
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onAddHost: () -> Void
    let onAddSubgroup: () -> Void
    let onDelete: () -> Void
    let onMoveToBuilder: () -> MoveMenu

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(GroupColorPalette.color(for: group.colorHex).opacity(0.95))
                        .frame(width: 44, height: 44)
                    Image(systemName: group.iconSystemName.isEmpty ? "folder.fill" : group.iconSystemName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if hovering {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiaryText)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if hostCount > 0 {
                Button("Connect \(hostCount) host\(hostCount == 1 ? "" : "s")", action: onConnectAll)
                Divider()
            }
            Button("Open", action: onOpen)
            Button("Edit", action: onEdit)
            Button("Add host here", action: onAddHost)
            Button("Add subgroup", action: onAddSubgroup)
            Menu("Move to") { onMoveToBuilder() }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var subtitle: String {
        let countText = "\(hostCount) Host\(hostCount == 1 ? "" : "s")"
        if parentPath.isEmpty { return countText }
        return "\(parentPath) · \(countText)"
    }
}

private struct GroupListRow<MoveMenu: View>: View {
    let onConnectAll: () -> Void
    let group: HostGroup
    let parentPath: String
    let hostCount: Int
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onAddHost: () -> Void
    let onAddSubgroup: () -> Void
    let onDelete: () -> Void
    let onMoveToBuilder: () -> MoveMenu

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: group.iconSystemName.isEmpty ? "folder.fill" : group.iconSystemName)
                    .font(.system(size: 16))
                    .foregroundStyle(GroupColorPalette.color(for: group.colorHex).opacity(0.95))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondaryText)
                }
                Spacer()
                if hovering {
                    Menu {
                        Button("Open", action: onOpen)
                        Button("Edit", action: onEdit)
                        Divider()
                        Button("Add host here", action: onAddHost)
                        Button("Add subgroup", action: onAddSubgroup)
                        Menu("Move to") { onMoveToBuilder() }
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondaryText)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if hostCount > 0 {
                Button("Connect \(hostCount) host\(hostCount == 1 ? "" : "s")", action: onConnectAll)
                Divider()
            }
            Button("Open", action: onOpen)
            Button("Edit", action: onEdit)
            Button("Add host here", action: onAddHost)
            Button("Add subgroup", action: onAddSubgroup)
            Menu("Move to") { onMoveToBuilder() }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var subtitle: String {
        let countText = "\(hostCount) Host\(hostCount == 1 ? "" : "s")"
        if parentPath.isEmpty { return countText }
        return "\(parentPath) · \(countText)"
    }
}

// MARK: - Host card / row

/// How a click on a host card/row triggers an SSH connection.
/// Configurable from Settings → General → "Hosts connect on".
enum HostConnectClickMode: String, CaseIterable, Identifiable {
    case single
    case double

    static let storageKey = "SarvHostsConnectClick"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "Single Click"
        case .double: return "Double Click"
        }
    }

    var tapCount: Int {
        switch self {
        case .single: return 1
        case .double: return 2
        }
    }
}

private struct HostCard<MoveMenu: View>: View {
    let host: SavedHost
    let groupPath: String
    let onOpen: () -> Void
    let onConnect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onMoveToBuilder: () -> MoveMenu

    @State private var hovering = false
    @AppStorage(HostConnectClickMode.storageKey)
    private var connectClick: HostConnectClickMode = .double

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // OS logo when known (manual pick or auto-detected), generic
            // server glyph otherwise — shared with the list row.
            HostOSIconView(host: host)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayLabel)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(host.subtitle.isEmpty ? host.hostname : host.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
                if !groupPath.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.caption2)
                        Text(groupPath).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.tertiaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: connectClick.tapCount) {
            if host.canConnect { onConnect() } else { onOpen() }
        }
        .contextMenu {
            Button("Connect", action: onConnect).disabled(!host.canConnect)
            Button("Edit", action: onOpen)
            Button("Duplicate", action: onDuplicate)
            Menu("Move to") { onMoveToBuilder() }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        // Edit pill ABOVE (after) the card's tap gesture — inside it, every
        // click waits out double-click disambiguation and sometimes loses,
        // making Edit feel laggy / needing two clicks.
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: onOpen) {
                    Image(systemName: "square.and.pencil")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                        )
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverCursor(.pointingHand)
                .help("Edit")
                .padding(.trailing, 12)
            }
        }
        // AFTER the overlay so the tracking area covers the pill too —
        // otherwise entering the pill reads as "left the card" and hides it.
        .onHover { hovering = $0 }
    }
}

private struct HostListRow<MoveMenu: View>: View {
    let host: SavedHost
    let groupPath: String
    let onOpen: () -> Void
    let onConnect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onMoveToBuilder: () -> MoveMenu

    @State private var hovering = false
    @AppStorage(HostConnectClickMode.storageKey)
    private var connectClick: HostConnectClickMode = .double

    var body: some View {
        HStack(spacing: 12) {
            // Same OS-aware icon as the grid card, row-sized.
            HostOSIconView(host: host, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayLabel).fontWeight(.medium)
                Text(host.subtitle.isEmpty ? host.hostname : host.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                if !groupPath.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.caption2)
                        Text(groupPath).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.tertiaryText)
                }
            }
            Spacer()
            if !host.tags.isEmpty {
                Text(host.tags.first ?? "")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.18))
                    )
                    .foregroundStyle(.secondaryText)
            }
            // Space reserved for the edit pill, drawn in the overlay below so
            // its clicks bypass the row's double-click gesture arena.
            Color.clear.frame(width: 44, height: 28)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: connectClick.tapCount) {
            if host.canConnect { onConnect() } else { onOpen() }
        }
        .contextMenu {
            Button("Connect", action: onConnect).disabled(!host.canConnect)
            Button("Edit", action: onOpen)
            Button("Duplicate", action: onDuplicate)
            Menu("Move to") { onMoveToBuilder() }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        // Edit pill ABOVE (after) the row's tap gesture — inside it, every
        // click waits out double-click disambiguation and sometimes loses.
        .overlay(alignment: .trailing) {
            Button(action: onOpen) {
                Image(systemName: "square.and.pencil")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(hovering ? 1.0 : 0.85))
                    )
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)
            .help("Edit")
            .padding(.trailing, 12)
        }
        // AFTER the overlay so the tracking area covers the pill too.
        .onHover { hovering = $0 }
    }
}
