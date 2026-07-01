import Foundation

/// Legacy single-pane session entry (pre split-restore). Kept ONLY so an old
/// `session.json` written by a prior build still restores after upgrading — new
/// sessions are stored as full `SavedSession` snapshots (see `TabSessionStore`).
struct TabSessionEntry: Codable {
    var hostID: UUID?
    var launchCommand: String?
    var title: String
    var customName: String?
    /// Working directory of a local-shell tab, so it reopens where it was.
    var workingDirectory: String?

    /// Convert a legacy flat entry into a single-leaf `SavedSession`.
    func asSavedSession() -> SavedSession {
        let isSSH = hostID != nil && (launchCommand?.hasPrefix("ssh ") ?? false)
        let name = (customName?.isEmpty == false ? customName! : title)
        let pane = SavedSession.Pane(
            kind: isSSH ? .ssh : .local,
            workingDirectory: isSSH ? nil : workingDirectory,
            hostID: hostID,
            command: launchCommand,
            title: name.isEmpty ? nil : name)
        let now = Date()
        return SavedSession(name: name, createdAt: now, updatedAt: now,
                            colorID: nil, layout: .leaf(pane))
    }
}

/// Reads/writes the last-session tab list to `session.json` in the (build-
/// specific) config directory. Each open tab is stored as a full `SavedSession`
/// snapshot, so splits, per-pane working directories / SSH hosts, and pane
/// titles all survive a relaunch.
enum TabSessionStore {
    private static var fileURL: URL {
        AppPaths.configDir.appendingPathComponent("session.json")
    }

    static func load() -> [SavedSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // Current format: an array of full per-tab snapshots.
        if let sessions = try? JSONDecoder().decode([SavedSession].self, from: data) {
            return sessions
        }
        // Migrate a legacy flat array written by an older build.
        if let legacy = try? JSONDecoder().decode([TabSessionEntry].self, from: data) {
            return legacy.map { $0.asSavedSession() }
        }
        return []
    }

    static func save(_ sessions: [SavedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
