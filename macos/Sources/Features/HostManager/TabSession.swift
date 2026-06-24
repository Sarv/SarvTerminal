import Foundation

/// A lightweight, persisted description of one open tab, used to reopen the
/// last session on launch (Chrome-style). We store only what's needed to
/// recreate the tab — a `SavedHost` reference (by id) plus the launch command —
/// and never any secrets: passwords stay in the host store / Keychain.
struct TabSessionEntry: Codable {
    var hostID: UUID?
    var launchCommand: String?
    var title: String
    var customName: String?
    /// Working directory of a local-shell tab, so it reopens where it was.
    var workingDirectory: String?
}

/// Reads/writes the last-session tab list to `session.json` in the (build-
/// specific) config directory.
enum TabSessionStore {
    private static var fileURL: URL {
        AppPaths.configDir.appendingPathComponent("session.json")
    }

    static func load() -> [TabSessionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([TabSessionEntry].self, from: data) else { return [] }
        return entries
    }

    static func save(_ entries: [TabSessionEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
