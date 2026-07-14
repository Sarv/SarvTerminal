import Foundation

/// SINGLE SOURCE OF TRUTH for the app's on-disk directory names and identity.
///
/// Renaming the app? Change the constants HERE and nothing else in Swift
/// hardcodes them. The only sibling that must be kept in sync is one mirrored
/// literal in the Zig core (`src/config/theme.zig`, the user-themes dir) —
/// see `UPSTREAM.md` §8.2.
///
/// NOTE ON WHAT IS **NOT** HERE (deliberately): Keychain service names, the
/// UserDefaults suite names, and the `com.*.<feature>` notification / menu
/// identifiers are FROZEN storage keys, not "the app name". Deriving them from
/// a rename knob would orphan every user's saved secrets, sync credentials, and
/// preferences the moment the app is renamed, so they stay as literals next to
/// the code that owns them.
enum AppIdentity {
    // MARK: - On-disk config dir name

    /// XDG config subdir for this build's terminal config + data
    /// (`~/.config/<name>`). Release and debug are isolated so a dev build never
    /// reads or clobbers the daily app's data.
    static let releaseConfigDirName = "sarvterminal"
    static let debugConfigDirName = "sarvterminal-dev"

    /// This build's config dir name (release vs debug).
    static var configDirName: String {
        #if DEBUG
        debugConfigDirName
        #else
        releaseConfigDirName
        #endif
    }

    /// Legacy Ghostty config dirs we SEED FROM on first launch (copy, never
    /// write). Historical values — they do NOT change when the app is renamed.
    static let legacyReleaseConfigDirName = "ghostty"
    static let legacyDebugConfigDirName = "ghostty-dev"

    // MARK: - Bundle identity (runtime)

    /// This build's macOS bundle identifier, read at runtime. The fallback is
    /// only hit in the practically-impossible case `Bundle.main` has no id
    /// (e.g. some unit-test hosts).
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? releaseBundleID
    }

    static let releaseBundleID = "com.sarv.terminal"
    static let debugBundleID = "com.sarv.terminal.debug"

    /// Legacy Ghostty bundle IDs we migrate preferences FROM (see
    /// `AppPaths.migrateLegacyDefaultsIfNeeded`). Frozen historical values,
    /// ordered most-preferred first.
    static let legacyBundleIDs = ["com.mitchellh.ghostty.debug", "com.mitchellh.ghostty"]
}
