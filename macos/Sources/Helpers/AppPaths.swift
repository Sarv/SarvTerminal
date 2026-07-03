import Foundation

/// Central filesystem + preference locations for SarvTerminal's own data
/// (hosts, groups, snippets, port-forwards, logs, sync assets).
///
/// Debug builds use a SEPARATE directory (`~/.config/sarvterminal-dev`) so the
/// dev build can never read or clobber the data your daily (release) app relies
/// on. Release builds keep using the original `~/.config/sarvterminal`.
enum AppPaths {
    /// `~/.config/sarvterminal` (release) or `~/.config/sarvterminal-dev` (debug).
    /// The directory is created if it doesn't exist.
    static var configDir: URL {
        #if DEBUG
        let name = "sarvterminal-dev"
        #else
        let name = "sarvterminal"
        #endif
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The Ghostty **terminal** config file (`theme`, `font-*`, `background-*`,
    /// keybinds, …) — distinct from the app's own data in ``configDir``.
    ///
    /// Honors `XDG_CONFIG_HOME`, falling back to `~/.config`. **Debug builds use
    /// a separate `ghostty-dev/config`** so experiments in the dev build never
    /// touch the release app's `~/.config/ghostty/config`. This is the single
    /// source of truth — EVERY reader/writer of the terminal config must use it
    /// (never re-derive `~/.config/ghostty/config` by hand).
    static var ghosttyConfigFile: URL {
        #if DEBUG
        let dirName = "ghostty-dev"
        #else
        let dirName = "ghostty"
        #endif
        let file = xdgConfigBaseDir
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("config")
        #if DEBUG
        seedDebugGhosttyConfigIfNeeded(devFile: file)
        #endif
        return file
    }

    /// `$XDG_CONFIG_HOME` if set, otherwise `~/.config`.
    private static var xdgConfigBaseDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config", isDirectory: true)
    }

    #if DEBUG
    /// Seed the dev terminal config once from the release config so the dev build
    /// starts identical, then diverges. No-op once the dev file exists.
    private static func seedDebugGhosttyConfigIfNeeded(devFile: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: devFile.path) else { return }
        try? fm.createDirectory(at: devFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let releaseFile = xdgConfigBaseDir
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config")
        if fm.fileExists(atPath: releaseFile.path) {
            try? fm.copyItem(at: releaseFile, to: devFile)
        } else {
            fm.createFile(atPath: devFile.path, contents: nil)
        }
    }
    #endif

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
