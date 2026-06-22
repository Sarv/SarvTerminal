import Foundation

/// Owns the persisted list of `HostGroup`s.
///
/// Storage: `~/.config/sarvterminal/groups.json`.
final class HostGroupsStore: ObservableObject {
    static let shared = HostGroupsStore()

    @Published private(set) var groups: [HostGroup] = []

    /// True when `groups.json` exists but couldn't be read/parsed — the empty
    /// array is then NOT authoritative and sync must not push it.
    private(set) var loadFailed = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "HostGroupsStore.io", qos: .utility)

    private init() {
        let dir = AppPaths.configDir
        fileURL = dir.appendingPathComponent("groups.json")
        load()
    }

    // MARK: - CRUD

    func upsert(_ group: HostGroup) {
        var u = group
        u.updatedAt = Date()
        if let idx = groups.firstIndex(where: { $0.id == u.id }) {
            groups[idx] = u
        } else {
            groups.append(u)
        }
        sortInPlace()
        persist()
    }

    /// Move a group to a new parent. No-op if the move would create a cycle
    /// (moving a group into one of its own descendants).
    func setParent(_ groupID: UUID, to newParent: UUID?) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // Cycle check.
        if let np = newParent {
            if np == groupID { return }
            if descendants(of: groupID).contains(np) { return }
        }
        if groups[idx].parentID == newParent { return }
        groups[idx].parentID = newParent
        groups[idx].updatedAt = Date()
        persist()
    }

    /// Delete a group. Sub-groups are re-parented to the deleted group's
    /// parent (preserving the tree structure). Hosts that referenced this
    /// group lose their `groupID` (caller responsibility).
    func delete(_ id: UUID) {
        guard let target = groups.first(where: { $0.id == id }) else { return }
        let newParent = target.parentID
        groups.removeAll { $0.id == id }
        for i in groups.indices where groups[i].parentID == id {
            groups[i].parentID = newParent
        }
        persist()
    }

    /// Merge synced groups in by `id`, keeping whichever copy is newer by
    /// `updatedAt`. Timestamps preserved; local-only groups never deleted.
    func ingest(_ incoming: [HostGroup]) {
        var changed = false
        for group in incoming {
            if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                if group.updatedAt >= groups[idx].updatedAt {
                    groups[idx] = group
                    changed = true
                }
            } else {
                groups.append(group)
                changed = true
            }
        }
        if changed { sortInPlace(); persist() }
    }

    /// Replace the entire group set with `incoming` (a sync mirror). Used on
    /// pull so deletions made elsewhere propagate. Timestamps preserved.
    func replaceAll(_ incoming: [HostGroup]) {
        groups = incoming
        sortInPlace()
        persist()
    }

    // MARK: - Tree queries

    /// Direct children of a given parent (`nil` = root level).
    func children(of parentID: UUID?) -> [HostGroup] {
        groups
            .filter { $0.parentID == parentID }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Walks up from a group to root, returning the display path
    /// `"Workspace > Dev > frontend"`. Empty string for `nil`.
    func path(for id: UUID?) -> String {
        guard let id else { return "" }
        var parts: [String] = []
        var seen = Set<UUID>()
        var current: UUID? = id
        while let c = current, !seen.contains(c),
              let g = groups.first(where: { $0.id == c }) {
            parts.insert(g.displayName, at: 0)
            seen.insert(c)
            current = g.parentID
        }
        return parts.joined(separator: " > ")
    }

    /// All descendants of a group (used to forbid picking a sub-group as
    /// its own ancestor's parent — that would create a cycle).
    func descendants(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var stack: [UUID] = [id]
        while let current = stack.popLast() {
            for child in children(of: current) where result.insert(child.id).inserted {
                stack.append(child.id)
            }
        }
        return result
    }

    /// All groups flattened in tree order with depth — useful for menus.
    func flatTree() -> [(group: HostGroup, depth: Int)] {
        var out: [(HostGroup, Int)] = []
        func walk(parent: UUID?, depth: Int) {
            for g in children(of: parent) {
                out.append((g, depth))
                walk(parent: g.id, depth: depth + 1)
            }
        }
        walk(parent: nil, depth: 0)
        return out
    }

    // MARK: - IO

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadFailed = false
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            loadFailed = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HostGroup].self, from: data) {
            groups = decoded
            sortInPlace()
            loadFailed = false
        } else {
            loadFailed = true
        }
    }

    private func persist() {
        let snapshot = groups
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func sortInPlace() {
        groups.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
