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
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(AppIdentity.configDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The Ghostty **terminal** config file (`theme`, `font-*`, `background-*`,
    /// keybinds, …) — distinct from the app's own data in ``configDir``.
    ///
    /// SarvTerminal keeps this in its OWN directory — `sarvterminal/config`
    /// (release) or `sarvterminal-dev/config` (debug) — NOT the shared
    /// `ghostty/config`, so it never collides with a real Ghostty install running
    /// side by side. We only ever WRITE here, and the Ghostty core's default-file
    /// search is deliberately NOT used (see `Ghostty.Config.loadUserBaseConfig`),
    /// so a co-installed Ghostty's `~/.config/ghostty/config` is never touched.
    ///
    /// Honors `XDG_CONFIG_HOME`, falling back to `~/.config`. On first launch the
    /// file is seeded once from the user's existing config (the legacy shared
    /// `ghostty/config`) so upgrading users — and Ghostty users trying us — keep
    /// their settings. This is the single source of truth — EVERY reader/writer of
    /// the terminal config must use it (never re-derive the path by hand).
    static var ghosttyConfigFile: URL {
        let file = xdgConfigBaseDir
            .appendingPathComponent(AppIdentity.configDirName, isDirectory: true)
            .appendingPathComponent("config")
        seedTerminalConfigIfNeeded(file)
        return file
    }

    /// The legacy shared Ghostty config path (`$XDG_CONFIG_HOME/ghostty/config`)
    /// we used before isolating. Kept ONLY as a first-launch seed source — we
    /// never write here, so a real Ghostty install is left untouched.
    private static var legacyGhosttyConfigFile: URL {
        xdgConfigBaseDir
            .appendingPathComponent(AppIdentity.legacyReleaseConfigDirName, isDirectory: true)
            .appendingPathComponent("config")
    }

    /// The user **themes** directory the terminal core resolves `theme = <name>`
    /// against — kept in our OWN `sarvterminal/themes`, NOT the shared
    /// `ghostty/themes`, so a co-installed Ghostty never collides.
    ///
    /// UNLIKE the config file this is NOT build-split: the Zig core resolves a
    /// single hardcoded `sarvterminal/themes` (see `src/config/theme.zig`), and
    /// Swift must agree with it, so debug and release share this dir. That's fine
    /// — themes are read-only user assets, not settings that dev/release diverge
    /// on. Seeded once from the legacy `ghostty/themes` so users who had custom
    /// themes keep them (the source is copied, never moved/deleted).
    static var terminalThemesDir: URL {
        // Uses the RELEASE dir name (not the build-split `configDirName`): the
        // Zig core resolves a single hardcoded path, so both builds must agree
        // on `<releaseConfigDirName>/themes`.
        let dir = xdgConfigBaseDir
            .appendingPathComponent(AppIdentity.releaseConfigDirName, isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        seedTerminalThemesIfNeeded(dir)
        return dir
    }

    /// The legacy shared Ghostty themes dir — first-launch seed source only.
    private static var legacyGhosttyThemesDir: URL {
        xdgConfigBaseDir
            .appendingPathComponent(AppIdentity.legacyReleaseConfigDirName, isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    /// Default location for a user-supplied custom app icon when
    /// `macos-custom-icon` is unset — isolated at `sarvterminal/Ghostty.icns`
    /// (release) / `sarvterminal-dev/Ghostty.icns` (debug), NOT `ghostty/`.
    static var terminalCustomIconFile: URL {
        xdgConfigBaseDir
            .appendingPathComponent(AppIdentity.configDirName, isDirectory: true)
            .appendingPathComponent("Ghostty.icns")
    }

    /// `$XDG_CONFIG_HOME` if set, otherwise `~/.config`.
    private static var xdgConfigBaseDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config", isDirectory: true)
    }

    /// `$XDG_STATE_HOME` if set, otherwise `~/.local/state` — matches where the
    /// Ghostty core writes its state (see `src/cli/ssh-cache/DiskCache.zig`).
    private static var xdgStateBaseDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }

    /// Our ISOLATED SSH terminfo cache: `<state>/sarvterminal/ssh_cache`.
    /// Records remote hosts where `xterm-ghostty` terminfo was installed. Written
    /// by the core CLI (`+ssh` / `+ssh-cache`), which we diverged to key on
    /// `DiskCache.default_program` = `"sarvterminal"` (NOT the shared `ghostty`),
    /// so a co-installed Ghostty never shares this cache. Uses the RELEASE dir
    /// name (not build-split) because the core hardcodes a single program name —
    /// this MUST equal `DiskCache.default_program` in the Zig core.
    static var sshTerminfoCacheFile: URL {
        xdgStateBaseDir
            .appendingPathComponent(AppIdentity.releaseConfigDirName, isDirectory: true)
            .appendingPathComponent("ssh_cache")
    }

    /// Drop Ghostty's SSH terminfo cache once whenever the app version changes
    /// (including first launch). Pre-1.8 builds could cache a host as
    /// "`xterm-ghostty` installed"; after an upgrade that stale entry forces
    /// `xterm-ghostty` on remotes whose terminfo is missing (or a different
    /// remote user), leaving `TERM` unresolved and breaking Ctrl+R / readline.
    /// The cache only speeds up `ssh-terminfo` installs, so dropping it is
    /// safe — it repopulates on demand. Runs only on a version change, never on
    /// every relaunch. Safe to call on every launch — it no-ops within a version.
    static func purgeStaleSSHTerminfoCacheOnUpgrade() {
        let defaults = UserDefaults.standard
        let key = "SarvSSHCachePurgedForVersion"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard defaults.string(forKey: key) != current else { return }
        try? FileManager.default.removeItem(at: sshTerminfoCacheFile)
        defaults.set(current, forKey: key)
    }

    /// One-time seed of our isolated terminal config from the user's existing
    /// config, so upgrading users (and Ghostty users trying us) don't start
    /// blank. Copies the FIRST existing source and NEVER deletes it — a real
    /// Ghostty install keeps its own file. No-op once our file exists.
    private static func seedTerminalConfigIfNeeded(_ dest: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var sources: [URL] = []
        #if DEBUG
        // Keep an existing dev config; otherwise fall back to the release app's.
        sources.append(xdgConfigBaseDir.appendingPathComponent(AppIdentity.legacyDebugConfigDirName, isDirectory: true)
            .appendingPathComponent("config"))
        sources.append(xdgConfigBaseDir.appendingPathComponent(AppIdentity.releaseConfigDirName, isDirectory: true)
            .appendingPathComponent("config"))
        #endif
        sources.append(legacyGhosttyConfigFile) // the old shared ~/.config/ghostty/config

        for src in sources where fm.fileExists(atPath: src.path) {
            try? fm.copyItem(at: src, to: dest)
            return
        }
        fm.createFile(atPath: dest.path, contents: nil)
    }

    /// One-time seed of our isolated themes dir from the legacy shared
    /// `ghostty/themes`, so users who kept custom themes there don't see
    /// `theme = <name>` break after isolation. Copies the whole directory and
    /// NEVER touches the source — a co-installed Ghostty keeps its themes.
    /// No-op once our themes dir exists.
    private static func seedTerminalThemesIfNeeded(_ dest: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = legacyGhosttyThemesDir
        if fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: dest)
        } else {
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        }
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
        for domain in AppIdentity.legacyBundleIDs where domain != current {
            guard let dict = defaults.persistentDomain(forName: domain), !dict.isEmpty else { continue }
            for (key, value) in dict where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            break   // first non-empty legacy domain wins
        }
        defaults.set(true, forKey: "SarvDidMigrateDefaults")
    }
}
