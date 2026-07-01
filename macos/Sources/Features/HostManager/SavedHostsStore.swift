import Foundation
import Combine

/// Owns the persisted list of `SavedHost`s. Singleton; safe to observe
/// from SwiftUI via `@ObservedObject var store = SavedHostsStore.shared`.
///
/// Storage: `~/.config/sarvterminal/hosts.json` (created lazily).
final class SavedHostsStore: ObservableObject {
    static let shared = SavedHostsStore()

    @Published private(set) var hosts: [SavedHost] = []

    /// True when `hosts.json` exists on disk but couldn't be read/parsed. In
    /// that state the empty `hosts` array is NOT authoritative — sync must not
    /// push it (doing so would wipe the remote backup).
    private(set) var loadFailed = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "SavedHostsStore.io", qos: .utility)

    private init() {
        let dir = AppPaths.configDir
        fileURL = dir.appendingPathComponent("hosts.json")
        load()
    }

    // MARK: - Public CRUD

    func upsert(_ host: SavedHost) {
        var updated = host
        updated.updatedAt = Date()
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = updated
        } else {
            hosts.append(updated)
        }
        sortInPlace()
        persist()
    }

    func delete(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    /// Create a copy with a fresh UUID and a "(copy)" suffix on the label.
    /// Same group, same tags, same everything else.
    @discardableResult
    func duplicate(_ host: SavedHost) -> SavedHost {
        var copy = host
        copy.id = UUID()
        let now = Date()
        copy.createdAt = now
        copy.updatedAt = now
        let base = host.label.isEmpty ? host.hostname : host.label
        copy.label = "\(base) (copy)"
        hosts.append(copy)
        sortInPlace()
        persist()
        return copy
    }

    /// Move a host to a (possibly new) group — `nil` for root level.
    func setGroup(_ host: SavedHost, to groupID: UUID?) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        if hosts[idx].groupID == groupID { return }
        hosts[idx].groupID = groupID
        hosts[idx].updatedAt = Date()
        persist()
    }

    func contains(_ id: UUID) -> Bool {
        hosts.contains { $0.id == id }
    }

    /// Replace the entire host set with `incoming` (a sync mirror). Used on pull
    /// so deletions made on another machine propagate here. Timestamps preserved.
    func replaceAll(_ incoming: [SavedHost]) {
        hosts = incoming
        sortInPlace()
        persist()
    }

    /// Merge synced hosts in by `id`, keeping whichever copy is newer by
    /// `updatedAt`. Timestamps are preserved as-is (NOT bumped) so future merges
    /// stay deterministic. Local-only hosts are never deleted.
    func ingest(_ incoming: [SavedHost]) {
        var changed = false
        for host in incoming {
            if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
                if host.updatedAt >= hosts[idx].updatedAt {
                    hosts[idx] = host
                    changed = true
                }
            } else {
                hosts.append(host)
                changed = true
            }
        }
        if changed { sortInPlace(); persist() }
    }

    /// The current saved host for `id`, if any (e.g. to re-read a password the
    /// user just changed via the editor).
    func host(withID id: UUID) -> SavedHost? {
        hosts.first { $0.id == id }
    }

    // MARK: - Group queries

    /// Hosts directly inside a group (not its descendants).
    /// `groupID == nil` returns root-level (ungrouped) hosts.
    func hosts(in groupID: UUID?) -> [SavedHost] {
        hosts.filter { $0.groupID == groupID }
    }

    /// Total host count including all descendant groups.
    func recursiveCount(in groupID: UUID, groupsStore: HostGroupsStore) -> Int {
        let descendants = groupsStore.descendants(of: groupID).union([groupID])
        return hosts.reduce(0) { partial, host in
            partial + ((host.groupID.map { descendants.contains($0) } ?? false) ? 1 : 0)
        }
    }

    /// Strip a `groupID` from every host that referenced it — call after
    /// deleting a group so dangling references don't hide hosts in the tree.
    func unsetGroup(_ id: UUID) {
        var changed = false
        for i in hosts.indices where hosts[i].groupID == id {
            hosts[i].groupID = nil
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - IO

    private func load() {
        // Stored encrypted at rest (AES-256-GCM, Secure-Enclave-protected key).
        // Legacy plaintext files migrate on first load — the original is backed
        // up to hosts.pre-encryption.bak before the encrypted file is written.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch EncryptedStore.read([SavedHost].self, from: fileURL, decoder: decoder) {
        case .none:
            loadFailed = false                 // fresh install
        case .failed:
            loadFailed = true                  // exists but unreadable/undecryptable — unsafe to sync
        case .loaded(let decoded):
            hosts = decoded; sortInPlace(); loadFailed = false
        case .migrated(let decoded):
            hosts = decoded; sortInPlace(); loadFailed = false
            persist()                          // rewrite encrypted (backup already taken)
        }
    }

    private func persist() {
        let snapshot = hosts
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // If the key is unavailable, skip the write rather than clobber the
            // existing file with plaintext/empty data.
            try? EncryptedStore.write(snapshot, to: url, encoder: encoder)
        }
    }

    private func sortInPlace() {
        hosts.sort { a, b in
            a.displayLabel.localizedCaseInsensitiveCompare(b.displayLabel) == .orderedAscending
        }
    }
}
