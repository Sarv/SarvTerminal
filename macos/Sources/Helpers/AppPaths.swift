import Foundation

/// Central filesystem + preference locations for SarvTerminal's own data
/// (hosts, groups, snippets, port-forwards, logs, sync assets).
///
/// Debug builds use a SEPARATE directory (`~/.config/sarvterminal-dev`) so the
/// dev build can never read or clobber the data your daily (release) app relies
/// on. Release builds keep using the original `~/.config/sarvterminal`.
enum AppPaths {
    #if DEBUG
    /// True when running the demo build (scripts/demo.sh copies the bundle to
    /// `/tmp/SarvTerminal_Demo.app`). We key off the bundle PATH rather than a
    /// launch argument because the Ghostty engine parses `--flags` as config and
    /// would reject an unknown one. Demo mode uses a fully isolated data dir +
    /// `.ssh` seeded with sample data for README screenshots — it never reads or
    /// writes your dev/release data.
    static let isDemo = Bundle.main.bundlePath.contains("SarvTerminal_Demo")
    #endif

    /// `~/.config/sarvterminal` (release), `~/.config/sarvterminal-dev` (debug),
    /// or `~/.config/sarvterminal-demo` (debug `--demo`). Created if missing.
    static var configDir: URL {
        #if DEBUG
        let name = isDemo ? "sarvterminal-demo" : "sarvterminal-dev"
        #else
        let name = "sarvterminal"
        #endif
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The user's `~/.ssh` — except in demo mode, where it's an isolated
    /// `<configDir>/.ssh` so seeded sample keys/known_hosts never touch the real
    /// `~/.ssh`. Created (0700) if missing when isolated.
    static var sshDir: URL {
        #if DEBUG
        if isDemo {
            let dir = configDir.appendingPathComponent(".ssh", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return dir
        }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
    }

    /// One-time migration of preferences from the old `com.mitchellh.ghostty*`
    /// UserDefaults domains into this build's domain. macOS keys UserDefaults by
    /// bundle id, so after the rebrand to `com.sarv.terminal[.debug]` the app's
    /// settings (background image, keybinds, SFTP prefs, sync config, …) would
    /// otherwise start empty. We copy any keys not already set, preferring the
    /// `.debug` legacy domain (where day-to-day settings currently live).
    /// Safe to call on every launch — it no-ops after the first run.
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "SarvDidMigrateDefaults") else { return }
        let current = Bundle.main.bundleIdentifier ?? ""
        for domain in ["com.mitchellh.ghostty.debug", "com.mitchellh.ghostty"] where domain != current {
            guard let dict = defaults.persistentDomain(forName: domain), !dict.isEmpty else { continue }
            for (key, value) in dict where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            break   // first non-empty legacy domain wins
        }
        defaults.set(true, forKey: "SarvDidMigrateDefaults")
    }
}
