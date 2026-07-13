import Foundation
import AppKit
import CryptoKit

extension Notification.Name {
    /// Posted after a successful Pull so live UI (SettingsViewModel) can re-read
    /// from disk. UserInfo is empty.
    static let sarvSyncDidPull = Notification.Name("SarvSyncDidPull")
}

/// Orchestrates Test / Push / Pull / remote-version checks. Pure async logic:
/// it takes the master password as a parameter (the UI decides whether that
/// came from the Keychain biometric prompt or a fresh entry) and talks to a
/// `SyncProvider`.
enum SyncEngine {
    private static let settings = SyncSettings.shared

    enum EngineError: LocalizedError, Equatable {
        case notConfigured
        case nothingRemote
        case wrongPassword
        case passwordMismatchRemote
        case localDataUnreadable
        case suspiciousEmptyPush
        case remoteIncomplete
        case integrityCheckFailed
        case remoteHasUnpulledData
        case remoteUnreadable

        var errorDescription: String? {
            switch self {
            case .notConfigured:        return "Sync isn't fully configured yet."
            case .nothingRemote:        return "Nothing has been synced to this destination yet."
            case .wrongPassword:        return "Wrong master password for this synced data."
            case .passwordMismatchRemote:
                return "Your master password doesn't match the existing synced data. Use the original password, or reset the remote."
            case .localDataUnreadable:
                return "Local hosts couldn't be read, so sync was paused to protect your backup. Restart the app; if it persists your hosts file may be corrupt."
            case .suspiciousEmptyPush:
                return "Sync paused: everything is empty locally but your backup has data. If you really cleared everything, press “Sync ↑” to confirm."
            case .remoteIncomplete:
                return "The remote sync data is incomplete or corrupt — nothing was changed locally."
            case .integrityCheckFailed:
                return "Sync was aborted: the data failed a pre-upload integrity check, so nothing was uploaded and your backup is untouched."
            case .remoteHasUnpulledData:
                return "The remote has data this device hasn't pulled yet, so nothing was uploaded (to avoid overwriting it). Press “Pull” to bring it in first, then sync."
            case .remoteUnreadable:
                return "The remote backup exists but couldn't be read (its manifest is missing or corrupt), so nothing was uploaded — your backup is untouched. Check the sync destination."
            }
        }
    }

    // MARK: - Provider factory

    static func makeProvider() throws -> SyncProvider {
        switch settings.provider {
        case .github:
            guard let pat = SyncKeychain.retrievePAT() else { throw EngineError.notConfigured }
            return GitHubSyncProvider(
                owner: settings.githubOwner.trimmingCharacters(in: .whitespaces),
                repo: settings.githubRepo.trimmingCharacters(in: .whitespaces),
                token: pat
            )
        case .folder:
            guard let bookmark = settings.folderBookmark else { throw EngineError.notConfigured }
            // historyKeepCount == 0 → unlimited (no pruning).
            let limit = settings.historyKeepCount == 0 ? nil : settings.historyKeepCount
            return FolderSyncProvider(bookmark: bookmark,
                                      writeHistory: settings.historyEnabled,
                                      historyLimit: limit)
        }
    }

    // MARK: - Public operations

    static func test() async throws {
        try await makeProvider().testConnection()
    }

    /// Read the remote manifest version (nil if remote empty), and update the
    /// "remote is newer" flag.
    @discardableResult
    static func checkRemote() async throws -> Int? {
        let provider = try makeProvider()
        guard let data = try await provider.readManifest(),
              let manifest = try? JSONDecoder.sync.decode(SyncManifest.self, from: data) else {
            return nil
        }
        await MainActor.run {
            settings.remoteNewerVersion = manifest.version > settings.lastSyncedVersion ? manifest.version : nil
        }
        return manifest.version
    }

    /// Encrypt and upload everything. Returns the manifest written.
    ///
    /// Upload-safety algorithm — a push may write ONLY when it cannot destroy
    /// data this device hasn't incorporated:
    ///   1. Local-state guards (skippable by `force`): refuse if local data is
    ///      unreadable, or if everything's empty locally but our own last sync
    ///      had data (a suspicious wipe — `Sync ↑` overrides to confirm).
    ///   2. Read the remote manifest with certainty: the provider returns nil
    ///      ONLY for a genuine "empty remote" and throws on any I/O error; an
    ///      existing-but-undecodable manifest is a hard error (`remoteUnreadable`).
    ///   3. Remote-overwrite guard (NOT skippable by `force`): if the remote's
    ///      version is newer than what we last pulled, refuse — pull first. This
    ///      is the fresh-machine case where a blank push would wipe the backup.
    ///   4. Only a genuinely-empty remote (first-ever seed) or a remote at
    ///      exactly our last-synced version may be written.
    ///
    /// So `force` (manual "Sync ↑") only overrides the LOCAL guards in step 1;
    /// it can never overwrite a remote this device is behind on. Auto-pushes
    /// always pass `force: false`.
    @discardableResult
    static func push(masterPassword: String, force: Bool = false) async throws -> SyncManifest {
        // Step 1 — local-state guards. Never let a bad local state wipe the backup.
        if !force {
            if SavedHostsStore.shared.loadFailed || HostGroupsStore.shared.loadFailed
                || PortForwardStore.shared.loadFailed {
                throw EngineError.localDataUnreadable
            }
            let hostCount = SavedHostsStore.shared.hosts.count
            let groupCount = HostGroupsStore.shared.groups.count
            let everythingEmpty = hostCount == 0 && groupCount == 0
            let backupHadData = settings.lastSyncedHostCount > 0 || settings.lastSyncedGroupCount > 0
            if everythingEmpty && backupHadData {
                throw EngineError.suspiciousEmptyPush
            }
        }

        let provider = try makeProvider()
        // Re-validate the destination before writing anything — this enforces the
        // private-repo / writability guard so we never upload secrets to a public repo.
        try await provider.testConnection()

        // Reuse the existing salt/version if the remote already has data; verify
        // our password matches it so we never orphan previously-synced files.
        let remoteManifest = try await readManifest(provider)

        // Whole-data-loss guard: never overwrite a remote version this device has
        // never pulled. On a brand-new machine `lastSyncedVersion` is 0, so a
        // stray auto-push (e.g. closing Settings right after configuring sync) —
        // or even a forced "Sync ↑" — would otherwise upload blank local state
        // over the real backup. This is exactly the case `force` must NOT bypass:
        // pull first to bring the data in, then sync.
        if let rm = remoteManifest, rm.version > settings.lastSyncedVersion {
            throw EngineError.remoteHasUnpulledData
        }

        let salt: Data
        let iterations: Int
        if let rm = remoteManifest {
            salt = rm.kdfSalt
            iterations = rm.kdfIterations
            let key = try SyncCrypto.deriveKey(password: masterPassword, salt: salt, iterations: iterations)
            // Validate against the remote verifier.
            guard (try? SyncCrypto.decrypt(rm.verifier, key: key)) != nil else {
                throw EngineError.passwordMismatchRemote
            }
        } else {
            salt = SyncCrypto.newSalt()
            iterations = SyncCrypto.pbkdf2Iterations
        }

        let key = try SyncCrypto.deriveKey(password: masterPassword, salt: salt, iterations: iterations)

        // A faithful mirror of current state — including removals/deletes — so
        // clearing a value or deleting a host propagates. We always write both
        // files (e.g. an empty hosts list must overwrite a previously-synced one).
        let settingsPayload = buildSettingsPayload()
        let hostsPayload = buildHostsPayload()
        let settingsData = try JSONEncoder.sync.encode(settingsPayload)
        let hostsData = try JSONEncoder.sync.encode(hostsPayload)
        let fingerprint = contentFingerprint(settingsData, hostsData)

        // Skip a no-op push: the plaintext is byte-identical to our last sync
        // and the remote still holds exactly that version, so there's nothing to
        // upload. (Closing the Settings window flushes a push even when the user
        // didn't change anything — this stops the version churn from that.)
        if !force,
           let rm = remoteManifest,
           rm.version == settings.lastSyncedVersion,
           fingerprint == settings.lastSyncedFingerprint {
            return rm
        }

        var files: [String: Data] = [:]
        files[SyncManifest.settingsFile] = try SyncCrypto.encrypt(settingsData, key: key)
        files[SyncManifest.hostsFile] = try SyncCrypto.encrypt(hostsData, key: key)

        // Integrity gate: never upload anything we can't read back. Decrypt each
        // freshly-encrypted payload and confirm it round-trips to byte-identical,
        // decodable plaintext. Any mismatch aborts the push *before* the atomic
        // commit is created, leaving the last good backup untouched.
        try verifyRoundTrip(files[SyncManifest.settingsFile], source: settingsData, key: key, as: SyncSettingsPayload.self)
        try verifyRoundTrip(files[SyncManifest.hostsFile], source: hostsData, key: key, as: SyncHostsPayload.self)

        let verifier = try SyncCrypto.encrypt(Data(SyncManifest.verifierToken.utf8), key: key)
        let nextVersion = max(remoteManifest?.version ?? 0, settings.lastSyncedVersion) + 1
        let now = Date()
        let manifest = SyncManifest(
            schema: 1,
            version: nextVersion,
            lastSyncDate: now,
            deviceName: settings.deviceName,
            kdfSalt: salt,
            kdfIterations: iterations,
            verifier: verifier,
            files: Array(files.keys)
        )
        files[SyncManifest.manifestFile] = try JSONEncoder.sync.encode(manifest)
        // Human-readable status, rendered as a table by GitHub on the repo home.
        files["README.md"] = Data(readmeMarkdown(manifest: manifest).utf8)

        try await provider.writeFiles(files)
        await MainActor.run {
            settings.recordSync(version: nextVersion, date: now,
                                hostCount: hostsPayload.hosts.count,
                                groupCount: hostsPayload.groups.count,
                                fingerprint: fingerprint)
            ActivityLog.shared.log(.sync, "Synced to \(settings.provider.label)", detail: "v\(nextVersion)", success: true)
        }
        return manifest
    }

    /// SHA-256 of the two plaintext payloads — a stable content fingerprint.
    /// (Encrypted bytes differ every push due to the GCM nonce, so we hash the
    /// plaintext to detect "nothing actually changed".)
    static func contentFingerprint(_ settingsData: Data, _ hostsData: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: settingsData)
        hasher.update(data: hostsData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a freshly-encrypted payload decrypts and decodes back to the exact
    /// source bytes — the guarantee that a push never uploads data it can't read
    /// back. Throws `integrityCheckFailed` on any mismatch so the push aborts.
    private static func verifyRoundTrip<T: Decodable>(
        _ encrypted: Data?, source: Data, key: SymmetricKey, as type: T.Type
    ) throws {
        guard let encrypted,
              let decrypted = try? SyncCrypto.decrypt(encrypted, key: key),
              decrypted == source,
              (try? JSONDecoder.sync.decode(T.self, from: decrypted)) != nil
        else {
            throw EngineError.integrityCheckFailed
        }
    }

    /// Fingerprint of the CURRENT local state — recorded after a pull so a
    /// later settings-close doesn't re-push identical content.
    static func currentFingerprint() -> String {
        let s = (try? JSONEncoder.sync.encode(buildSettingsPayload())) ?? Data()
        let h = (try? JSONEncoder.sync.encode(buildHostsPayload())) ?? Data()
        return contentFingerprint(s, h)
    }

    /// Download, decrypt, and merge into local state.
    static func pull(masterPassword: String) async throws {
        let provider = try makeProvider()
        // Same guard as push — refuse to operate against a public repo.
        try await provider.testConnection()
        guard let manifestData = try await provider.readManifest(),
              let manifest = try? JSONDecoder.sync.decode(SyncManifest.self, from: manifestData) else {
            throw EngineError.nothingRemote
        }

        let key = try SyncCrypto.deriveKey(
            password: masterPassword, salt: manifest.kdfSalt, iterations: manifest.kdfIterations
        )
        // Validate the master password before touching local state.
        guard (try? SyncCrypto.decrypt(manifest.verifier, key: key)) != nil else {
            throw EngineError.wrongPassword
        }

        // Decode every payload up front. `readEncrypted` THROWS on a decrypt or
        // decode failure (so a corrupt payload aborts the whole pull before we
        // touch local state). A file the manifest lists but that's missing is
        // also treated as incomplete — we apply all-or-nothing, never a partial
        // snapshot that could blank out one side.
        let settingsPayload = try await readEncrypted(
            provider, name: SyncManifest.settingsFile, key: key, as: SyncSettingsPayload.self)
        let hostsPayload = try await readEncrypted(
            provider, name: SyncManifest.hostsFile, key: key, as: SyncHostsPayload.self)

        if manifest.files.contains(SyncManifest.settingsFile) && settingsPayload == nil {
            throw EngineError.remoteIncomplete
        }
        if manifest.files.contains(SyncManifest.hostsFile) && hostsPayload == nil {
            throw EngineError.remoteIncomplete
        }

        // Apply on the main actor: config file, UserDefaults, image, stores.
        await MainActor.run {
            // Suppress the auto-push that our own mutations below would trigger.
            SyncCoordinator.shared.beginApplyingRemote()

            if let p = settingsPayload { applySettings(p) }
            if let h = hostsPayload {
                // First pull on a machine that already has local data: MERGE so
                // we never wipe hosts created before sync was enabled. After that
                // we MIRROR (replace), so deletes made elsewhere propagate.
                let firstPull = settings.lastSyncedVersion == 0
                let snippets = h.snippets ?? []
                let savedSessions = h.savedSessions ?? []
                let portForwards = h.portForwards ?? []
                if firstPull && !SavedHostsStore.shared.hosts.isEmpty {
                    HostGroupsStore.shared.ingest(h.groups)
                    SavedHostsStore.shared.ingest(h.hosts)
                    SnippetsStore.shared.ingest(snippets)
                    SavedSessionsStore.shared.ingest(savedSessions)
                    PortForwardStore.shared.ingest(portForwards)
                } else {
                    HostGroupsStore.shared.replaceAll(h.groups)
                    SavedHostsStore.shared.replaceAll(h.hosts)
                    SnippetsStore.shared.replaceAll(snippets)
                    SavedSessionsStore.shared.replaceAll(savedSessions)
                    PortForwardStore.shared.replaceAll(portForwards)
                }
            }
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            NotificationCenter.default.post(name: .sarvSyncDidPull, object: nil)
            settings.recordSync(version: manifest.version, date: manifest.lastSyncDate,
                                hostCount: SavedHostsStore.shared.hosts.count,
                                groupCount: HostGroupsStore.shared.groups.count,
                                fingerprint: currentFingerprint())
            ActivityLog.shared.log(.sync, "Pulled from \(settings.provider.label)", detail: "v\(manifest.version)", success: true)
        }
    }

    // MARK: - README (human-readable status)

    /// A plaintext status page GitHub renders as a table on the repo home.
    /// Contains only non-secret manifest metadata — never the encrypted data
    /// or the master password.
    private static func readmeMarkdown(manifest: SyncManifest) -> String {
        let when = manifest.lastSyncDate.formatted(date: .abbreviated, time: .shortened)
        let payloads = manifest.files.isEmpty ? "—" : manifest.files.joined(separator: ", ")
        var contents: [String] = []
        if manifest.files.contains(SyncManifest.settingsFile) {
            contents.append("terminal settings, appearance, keybinds")
        }
        if manifest.files.contains(SyncManifest.hostsFile) {
            contents.append("saved hosts & groups")
        }
        let contentsLine = contents.isEmpty ? "—" : contents.joined(separator: "; ")

        return """
        # SarvTerminal — Encrypted Settings Sync

        This repository holds your **encrypted** SarvTerminal settings. The payload
        files are AES‑256‑GCM encrypted with your master password and can't be read
        without it. This page is generated automatically — don't edit it by hand.

        | | |
        |---|---|
        | **Last synced** | \(when) |
        | **Version** | \(manifest.version) |
        | **Device** | \(manifest.deviceName) |
        | **Contents** | \(contentsLine) |
        | **Encryption** | AES‑256‑GCM · PBKDF2‑SHA256 (\(manifest.kdfIterations) iterations) |
        | **Files** | \(payloads) |

        > ⚠️ Keep `manifest.json` — it stores the key‑derivation salt needed to
        > decrypt your data. Your master password is **never** stored here, and there
        > is no way to recover the data if you forget it.
        """
    }

    // MARK: - Remote reads

    /// Strict manifest read for the PUSH guard. The provider returns nil ONLY for
    /// a genuine "not found" (true 404 / missing file) and THROWS on any I/O
    /// error — so nil here authoritatively means "remote is empty". Crucially, a
    /// manifest that EXISTS but won't decode must never collapse to nil (which
    /// the push path reads as "empty" and would overwrite): that's a hard error.
    private static func readManifest(_ provider: SyncProvider) async throws -> SyncManifest? {
        guard let d = try await provider.readManifest() else { return nil }
        guard let manifest = try? JSONDecoder.sync.decode(SyncManifest.self, from: d) else {
            throw EngineError.remoteUnreadable
        }
        return manifest
    }

    private static func readEncrypted<T: Decodable>(
        _ provider: SyncProvider, name: String, key: SymmetricKey, as type: T.Type
    ) async throws -> T? {
        guard let enc = try await provider.readFile(name) else { return nil }
        let plain = try SyncCrypto.decrypt(enc, key: key)
        return try JSONDecoder.sync.decode(T.self, from: plain)
    }

    // MARK: - Payload assembly (push)

    private static func buildSettingsPayload() -> SyncSettingsPayload {
        let d = UserDefaults.standard
        var p = SyncSettingsPayload()

        // Faithful current state — carry values even when empty so a cleared
        // value (e.g. a removed background image) propagates on the next sync.
        // BUT if the config file can't be read, leave `ghosttyConfig` nil so we
        // never overwrite the remote config with a blank (read-failure ≠ empty).
        p.ghosttyConfig = try? String(contentsOf: ghosttyConfigURL(), encoding: .utf8)
        p.bgShared = d.bool(forKey: "SarvBgShared")
        p.sftpAutoSave = d.bool(forKey: "SarvSFTPAutoSave")
        p.sftpConfirmDelete = d.object(forKey: "SarvSFTPConfirmDelete") as? Bool ?? true
        p.sftpShowHidden = d.object(forKey: "SarvSFTPShowHidden") as? Bool ?? true
        p.bgVisibility = d.double(forKey: "SarvBgVisibility")
        p.appKeybinds = (d.dictionary(forKey: "SarvAppKeybinds") as? [String: [String]]) ?? [:]

        // Background image: empty path = "no image" (mirrors a removal). When
        // present, carry the bytes too so it survives across machines.
        let imagePath = activeBackgroundImagePath(config: p.ghosttyConfig ?? "") ?? ""
        p.bgImagePath = imagePath
        if !imagePath.isEmpty {
            let expanded = (imagePath as NSString).expandingTildeInPath
            if let bytes = try? Data(contentsOf: URL(fileURLWithPath: expanded)) {
                p.backgroundImage = .init(name: URL(fileURLWithPath: expanded).lastPathComponent, data: bytes)
            }
        }
        // Generic snapshot of every syncable pref — covers current & future
        // settings without a per-key change here.
        p.defaults = syncableDefaultsBlob()
        return p
    }

    private static func buildHostsPayload() -> SyncHostsPayload {
        // Faithful mirror — sync every host/group/snippet as-is. A deleted item
        // is simply absent here, so the deletion propagates on pull.
        SyncHostsPayload(hosts: SavedHostsStore.shared.hosts,
                         groups: HostGroupsStore.shared.groups,
                         snippets: SnippetsStore.shared.snippets,
                         savedSessions: SavedSessionsStore.shared.sessions,
                         portForwards: PortForwardStore.shared.forwards)
    }

    // MARK: - Generic preferences snapshot

    /// `UserDefaults` keys that must NOT sync — device-specific / internal state.
    /// (All `SarvSync*` keys — the sync config itself — are excluded by prefix
    /// separately, so pushing can never poison the remote's own settings.)
    private static let defaultsDenylist: Set<String> = [
        "SarvConfigDidCommit",          // internal write-coalescing flag
        "SarvDidMigrateDefaults",       // one-time migration flag
        "SarvSSHCachePurgedForVersion", // per-version local cache state
        "SarvSettingsClosed",           // a notification name, not a stored pref
        "SarvNewTabDirectory",          // a machine-specific filesystem path
        "SarvBgImagePath",              // handled specially (repointed to the local image copy)
    ]

    /// A `Sarv*` pref that is safe to sync (a real, device-independent setting).
    private static func isSyncableDefaultsKey(_ key: String) -> Bool {
        key.hasPrefix("Sarv") && !key.hasPrefix("SarvSync") && !defaultsDenylist.contains(key)
    }

    /// JSON blob of all syncable prefs with **sorted keys** (at every level), so
    /// identical content always encodes to byte-identical output. This keeps the
    /// content-fingerprint stable across app launches — a no-op settings-close
    /// never bumps the sync version. (A binary plist would NOT be stable: its
    /// dictionary key order is randomized per process.) Values that aren't
    /// JSON-representable are skipped rather than breaking the whole snapshot.
    private static func syncableDefaultsBlob() -> Data? {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var dict: [String: Any] = [:]
        for (k, v) in all where isSyncableDefaultsKey(k) && JSONSerialization.isValidJSONObject([v]) {
            dict[k] = v
        }
        guard !dict.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// Apply a synced prefs blob back into `UserDefaults` (present keys only).
    private static func applyDefaultsBlob(_ blob: Data) {
        guard let dict = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any] else { return }
        let d = UserDefaults.standard
        for (k, v) in dict where isSyncableDefaultsKey(k) { d.set(v, forKey: k) }
    }

    // MARK: - Apply (pull)

    private static func applySettings(_ p: SyncSettingsPayload) {
        let d = UserDefaults.standard

        // Background image bytes first, so we can point paths at the local copy.
        var localImagePath: String?
        if let blob = p.backgroundImage {
            if let dir = assetsDir() {
                let dest = dir.appendingPathComponent(blob.name)
                try? blob.data.write(to: dest, options: .atomic)
                localImagePath = dest.path
            }
        }

        // Config file: back up, overwrite wholesale, then repoint the image path.
        if let config = p.ghosttyConfig {
            let url = ghosttyConfigURL()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: url) {
                try? existing.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }
            try? Data(config.utf8).write(to: url, options: .atomic)
            if let editor = try? ConfigFileEditor() {
                if let localImagePath {
                    // Repoint the synced image to its local copy.
                    editor.set("background-image", localImagePath)
                    try? editor.commit()
                } else if (p.bgImagePath ?? "").isEmpty {
                    // Mirror a removal — drop any stale background-image line.
                    editor.remove("background-image")
                    try? editor.commit()
                }
            }
        }

        // UserDefaults — mirror the incoming state (apply removals too).
        if let v = p.bgShared { d.set(v, forKey: "SarvBgShared") }
        if let v = p.sftpAutoSave { d.set(v, forKey: "SarvSFTPAutoSave") }
        if let v = p.sftpConfirmDelete { d.set(v, forKey: "SarvSFTPConfirmDelete") }
        if let v = p.sftpShowHidden { d.set(v, forKey: "SarvSFTPShowHidden") }
        if let v = p.bgVisibility { d.set(v, forKey: "SarvBgVisibility") }
        if let kb = p.appKeybinds { d.set(kb, forKey: "SarvAppKeybinds") }

        // Generic prefs snapshot (payloads written by this version): applies every
        // synced Sarv* key, covering settings the explicit fields above don't
        // (indent width, font weight, notifications, hosts-UI, session restore, …).
        // Excludes SarvBgImagePath (handled below) and SarvSync*/internal keys.
        if let blob = p.defaults { applyDefaultsBlob(blob) }

        // Background image path: set to the local copy, or clear it if removed.
        let imagePath = localImagePath ?? (p.bgImagePath ?? "")
        if imagePath.isEmpty {
            d.removeObject(forKey: "SarvBgImagePath")
        } else {
            d.set(imagePath, forKey: "SarvBgImagePath")
        }
    }

    // MARK: - Paths

    private static func ghosttyConfigURL() -> URL {
        return AppPaths.ghosttyConfigFile
    }

    private static func assetsDir() -> URL? {
        let dir = AppPaths.configDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The active background-image path: shared-mode keeps it in UserDefaults,
    /// per-pane keeps it as `background-image = …` in the config.
    private static func activeBackgroundImagePath(config: String) -> String? {
        if UserDefaults.standard.bool(forKey: "SarvBgShared") {
            let p = UserDefaults.standard.string(forKey: "SarvBgImagePath") ?? ""
            return p.isEmpty ? nil : p
        }
        // Scan the config for `background-image = <path>` (ignore comments).
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("background-image") else { continue }
            if let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
