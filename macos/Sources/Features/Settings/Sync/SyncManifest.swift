import Foundation

/// Plaintext index file (`manifest.json`) at the root of the remote. It carries
/// everything needed to (a) show sync status without decrypting and (b) derive
/// the key + validate the master password on another machine.
///
/// Nothing secret lives here: the salt is not a secret, and `verifier` is an
/// AES-GCM blob that only *confirms* the password — it can't reveal it.
struct SyncManifest: Codable {
    /// On-disk format version, for future migrations.
    var schema: Int = 1
    /// Monotonically increasing; bumped on every push. Drives "remote is newer".
    var version: Int
    var lastSyncDate: Date
    /// Human label for "last pushed from <device>".
    var deviceName: String

    // KDF parameters (public by design).
    var kdfSalt: Data           // JSON-encoded as base64
    var kdfIterations: Int

    /// AES-GCM encryption of `SyncManifest.verifierToken`. Decrypting it with a
    /// derived key proves the master password is correct.
    var verifier: Data

    /// Names of the encrypted payload files this manifest describes.
    var files: [String]

    static let verifierToken = "sarv-sync-verifier-v1"
    static let settingsFile = "settings.enc"
    static let hostsFile = "hosts.enc"
    static let manifestFile = "manifest.json"
}

/// Decrypted contents of `settings.enc`. Every field is optional so we only
/// ever serialize values that were actually set — never blanks that could
/// clobber a populated value on the receiving machine.
struct SyncSettingsPayload: Codable {
    var ghosttyConfig: String?
    var bgShared: Bool?
    var bgImagePath: String?
    var bgVisibility: Double?
    var appKeybinds: [String: [String]]?
    var sftpAutoSave: Bool?
    var sftpConfirmDelete: Bool?
    var sftpShowHidden: Bool?
    /// The background image bytes, so it survives across machines.
    var backgroundImage: BackgroundImageBlob?

    struct BackgroundImageBlob: Codable {
        var name: String
        var data: Data
    }

    /// True when there is nothing worth syncing (used to skip writing an
    /// empty payload).
    var isEmpty: Bool {
        ghosttyConfig == nil && bgShared == nil && bgImagePath == nil &&
        bgVisibility == nil && appKeybinds == nil && sftpAutoSave == nil &&
        sftpConfirmDelete == nil && sftpShowHidden == nil && backgroundImage == nil
    }
}

/// Decrypted contents of `hosts.enc`.
struct SyncHostsPayload: Codable {
    var hosts: [SavedHost]
    var groups: [HostGroup]

    var isEmpty: Bool { hosts.isEmpty && groups.isEmpty }
}

extension JSONEncoder {
    /// Shared encoder for sync payloads — matches the iso8601 dates used by the
    /// host/group stores so round-trips are stable.
    static var sync: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var sync: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
