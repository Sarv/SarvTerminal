import SwiftUI
import Combine

/// Which backend the encrypted payloads are stored on.
enum SyncProviderKind: String, CaseIterable, Identifiable, Hashable {
    case github
    case folder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .github: return "GitHub"
        case .folder: return "Cloud Folder"
        }
    }
}

/// Coarse status used by the Sync settings screen and the Vaults cloud icon.
enum SyncStatus: Equatable {
    case disabled       // off or not fully configured
    case idle           // configured + up to date
    case syncing        // a push/pull is in flight
    case remoteNewer    // remote manifest version > our last pull
    case error(String)
}

/// Persisted sync configuration (UserDefaults), plus transient runtime state.
/// Mirrors the `SFTPSettings.shared` pattern. Secrets (PAT + master password)
/// are NOT here — they live in `SyncKeychain`.
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()

    private enum Keys {
        static let enabled = "SarvSyncEnabled"
        static let provider = "SarvSyncProvider"
        static let githubURL = "SarvSyncGitHubURL"
        static let folderBookmark = "SarvSyncFolderBookmark"
        static let folderPath = "SarvSyncFolderPath"
        static let lastVersion = "SarvSyncLastVersion"
        static let lastDate = "SarvSyncLastDate"
        static let lastHostCount = "SarvSyncLastHostCount"
        static let lastGroupCount = "SarvSyncLastGroupCount"
        static let historyEnabled = "SarvSyncHistoryEnabled"
        static let historyLimitEnabled = "SarvSyncHistoryLimitEnabled"
        static let historyKeepCount = "SarvSyncHistoryKeepCount"
    }

    // These hold the APPLIED provider config — they are only written by an
    // explicit Save (the Settings form edits a draft until then), so merely
    // viewing/switching the form never disturbs an active sync.
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) } }
    @Published var provider: SyncProviderKind {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider) }
    }
    /// Full repo URL or `owner/repo` shorthand — parsed into owner/repo on use.
    @Published var githubURL: String { didSet { UserDefaults.standard.set(githubURL, forKey: Keys.githubURL) } }
    /// Security-scoped bookmark for the chosen Cloud Folder.
    @Published var folderBookmark: Data? { didSet { UserDefaults.standard.set(folderBookmark, forKey: Keys.folderBookmark) } }
    /// Human-readable path for display only.
    @Published var folderPath: String { didSet { UserDefaults.standard.set(folderPath, forKey: Keys.folderPath) } }

    /// Whether to save a version snapshot on every push (folder provider).
    @Published var historyEnabled: Bool { didSet { UserDefaults.standard.set(historyEnabled, forKey: Keys.historyEnabled) } }

    /// Last manifest version we successfully pushed or pulled.
    @Published var lastSyncedVersion: Int { didSet { UserDefaults.standard.set(lastSyncedVersion, forKey: Keys.lastVersion) } }
    @Published var lastSyncDate: Date? { didSet { UserDefaults.standard.set(lastSyncDate, forKey: Keys.lastDate) } }

    /// Host/group counts at the last successful sync — a "high-water mark" the
    /// catastrophic-shrink guard uses to refuse auto-wiping a populated remote.
    @Published var lastSyncedHostCount: Int { didSet { UserDefaults.standard.set(lastSyncedHostCount, forKey: Keys.lastHostCount) } }
    @Published var lastSyncedGroupCount: Int { didSet { UserDefaults.standard.set(lastSyncedGroupCount, forKey: Keys.lastGroupCount) } }

    /// Folder provider version history: when enabled we keep only the newest
    /// `historyKeepCount` snapshots and prune the oldest; when disabled we keep
    /// every version (unbounded).
    @Published var historyLimitEnabled: Bool { didSet { UserDefaults.standard.set(historyLimitEnabled, forKey: Keys.historyLimitEnabled) } }
    @Published var historyKeepCount: Int { didSet { UserDefaults.standard.set(historyKeepCount, forKey: Keys.historyKeepCount) } }

    // MARK: Transient runtime state (not persisted)
    @Published var isSyncing = false
    @Published var lastError: String?
    /// Version of the remote manifest seen on the last check, if greater than
    /// `lastSyncedVersion`. Drives the "remote is newer — Pull?" banner.
    @Published var remoteNewerVersion: Int?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        provider = SyncProviderKind(rawValue: d.string(forKey: Keys.provider) ?? "") ?? .github
        githubURL = d.string(forKey: Keys.githubURL) ?? ""
        folderBookmark = d.data(forKey: Keys.folderBookmark)
        folderPath = d.string(forKey: Keys.folderPath) ?? ""
        lastSyncedVersion = d.integer(forKey: Keys.lastVersion)
        lastSyncDate = d.object(forKey: Keys.lastDate) as? Date
        lastSyncedHostCount = d.integer(forKey: Keys.lastHostCount)
        lastSyncedGroupCount = d.integer(forKey: Keys.lastGroupCount)
        historyEnabled = d.object(forKey: Keys.historyEnabled) as? Bool ?? true       // keep history by default
        historyLimitEnabled = d.object(forKey: Keys.historyLimitEnabled) as? Bool ?? false
        historyKeepCount = d.integer(forKey: Keys.historyKeepCount)                   // 0 (unset) = Unlimited by default
    }

    // MARK: - Derived

    var deviceName: String { Host.current().localizedName ?? "this Mac" }

    /// Parse `githubURL` into (owner, repo). Accepts:
    /// `https://github.com/owner/repo[.git][/]`, `git@github.com:owner/repo.git`,
    /// or the bare `owner/repo` shorthand. Returns nil if it can't be parsed.
    var githubRepoComponents: (owner: String, repo: String)? { Self.parseGitHubURL(githubURL) }

    /// Parse a GitHub repo string into (owner, repo). Static so the Settings
    /// form can validate a draft URL before committing it.
    static func parseGitHubURL(_ raw: String) -> (owner: String, repo: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    var githubOwner: String { githubRepoComponents?.owner ?? "" }
    var githubRepo: String { githubRepoComponents?.repo ?? "" }

    /// True when the chosen provider has everything it needs AND a master
    /// password is set — i.e. the form is complete (independent of Save).
    var isConfigured: Bool {
        guard SyncKeychain.hasMasterPassword() else { return false }
        switch provider {
        case .github:
            return githubRepoComponents != nil && SyncKeychain.hasPAT()
        case .folder:
            return folderBookmark != nil
        }
    }

    /// Whether automatic sync should actually run. Because the applied config is
    /// only written on Save, this reflects the saved state — editing the form
    /// draft never flips it.
    var canSync: Bool { enabled && isConfigured }

    var status: SyncStatus {
        if !canSync { return .disabled }
        if isSyncing { return .syncing }
        if let err = lastError { return .error(err) }
        if let rv = remoteNewerVersion, rv > lastSyncedVersion { return .remoteNewer }
        return .idle
    }

    /// Record a successful push/pull, including the host/group high-water mark.
    func recordSync(version: Int, date: Date, hostCount: Int, groupCount: Int) {
        lastSyncedVersion = version
        lastSyncDate = date
        lastSyncedHostCount = hostCount
        lastSyncedGroupCount = groupCount
        lastError = nil
        if let rv = remoteNewerVersion, rv <= version { remoteNewerVersion = nil }
    }
}
