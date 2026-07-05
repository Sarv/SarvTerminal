import Foundation
import SwiftUI

/// A persisted snapshot of one terminal tab's full split layout, so the exact
/// arrangement (panes, split directions, ratios) can be reopened on demand.
/// Each local pane respawns at its saved working directory; each SSH pane
/// auto-connects. No secrets are stored: an SSH pane references a `SavedHost`
/// by id (its password stays in the host store / Keychain) or carries only the
/// plain `ssh` command as a fallback.
struct SavedSession: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Tab color option id (e.g. "blue"), if the tab had one.
    var colorID: String?
    /// Tab name follows the session name: renamed at save time, and kept in
    /// sync when the session is renamed later. Optional for back-compat with
    /// sessions saved before the setting existed — nil reads as true.
    var linkTabName: Bool?
    /// Used only in RESTART snapshots: the library session the tab was linked
    /// to, so ⌘S on a restored tab still offers "update existing session".
    var linkedSessionID: UUID?
    /// The root of the saved split tree.
    var layout: PaneNode

    /// `linkTabName` with the back-compat default applied.
    var linksTabName: Bool { linkTabName ?? true }

    /// One node of the saved split tree: a single pane, or a split of two children.
    indirect enum PaneNode: Codable {
        case leaf(Pane)
        case split(Split)

        struct Split: Codable {
            var direction: Direction
            var ratio: Double
            var left: PaneNode
            var right: PaneNode
        }

        enum Direction: String, Codable {
            case horizontal   // left | right
            case vertical     // top / bottom
        }
    }

    /// A single saved pane.
    struct Pane: Codable {
        enum Kind: String, Codable { case local, ssh }
        var kind: Kind
        /// Working directory for a local shell, so it reopens where it was.
        var workingDirectory: String?
        /// Saved host id for an SSH pane (preferred — keeps password handling).
        var hostID: UUID?
        /// Plain `ssh …` command fallback when there's no saved host.
        var command: String?
        /// Sidebar display label captured at save time.
        var title: String?
    }
}

extension SavedSession {
    /// Total number of panes in the layout.
    var paneCount: Int { Self.count(layout) }
    /// Number of SSH panes in the layout.
    var sshCount: Int { Self.countSSH(layout) }

    /// A short one-line summary, e.g. "4 panes · 2 SSH" or "1 pane".
    var summary: String {
        let panes = paneCount
        let paneText = panes == 1 ? "1 pane" : "\(panes) panes"
        guard sshCount > 0 else { return paneText }
        return "\(paneText) · \(sshCount) SSH"
    }

    private static func count(_ node: PaneNode) -> Int {
        switch node {
        case .leaf: return 1
        case .split(let s): return count(s.left) + count(s.right)
        }
    }

    private static func countSSH(_ node: PaneNode) -> Int {
        switch node {
        case .leaf(let p): return p.kind == .ssh ? 1 : 0
        case .split(let s): return countSSH(s.left) + countSSH(s.right)
        }
    }
}

/// Owns the persisted saved-session library. Storage:
/// `~/.config/sarvterminal/saved-sessions.json`, encrypted at rest like the
/// other local stores.
final class SavedSessionsStore: ObservableObject {
    static let shared = SavedSessionsStore()

    @Published private(set) var sessions: [SavedSession] = []
    /// True when the file exists but couldn't be read (the empty array is then
    /// not authoritative).
    private(set) var loadFailed = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "SavedSessionsStore.io", qos: .utility)

    private init() {
        fileURL = AppPaths.configDir.appendingPathComponent("saved-sessions.json")
        load()
    }

    // MARK: - CRUD

    func upsert(_ session: SavedSession) {
        var updated = session
        updated.updatedAt = Date()
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = updated
        } else {
            sessions.append(updated)
        }
        sortInPlace()
        persist()
    }

    func rename(_ session: SavedSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].name = trimmed
        sessions[idx].updatedAt = Date()
        sortInPlace()
        persist()
    }

    func delete(_ session: SavedSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    /// Recolor a saved session (nil clears the color). Applied to the tab when
    /// the session is reopened. Sort order is by `createdAt`, so this doesn't
    /// move the row.
    func setColor(_ session: SavedSession, colorID: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].colorID = colorID
        persist()
    }

    /// Toggle whether the tab name follows this session's name.
    func setLinkTabName(_ session: SavedSession, linked: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].linkTabName = linked
        persist()
    }

    // MARK: - IO

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch EncryptedStore.read([SavedSession].self, from: fileURL, decoder: decoder) {
        case .none:    loadFailed = false
        case .failed:  loadFailed = true
        case .loaded(let decoded):   sessions = decoded; sortInPlace(); loadFailed = false
        case .migrated(let decoded): sessions = decoded; sortInPlace(); loadFailed = false; persist()
        }
    }

    private func persist() {
        let snapshot = sessions
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? EncryptedStore.write(snapshot, to: url, encoder: encoder)
        }
    }

    /// Newest first — the list reads as a recent-sessions history.
    private func sortInPlace() {
        sessions.sort { $0.createdAt > $1.createdAt }
    }
}
