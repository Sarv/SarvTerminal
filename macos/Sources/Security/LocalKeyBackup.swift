import CryptoKit
import Foundation

/// A copy of the local data key, encrypted with the Sync master password, so
/// local data can be opened again when this Mac loses the key (Keychain reset,
/// key replaced, Secure Enclave can't use it).
///
/// The file holds one entry per data key this Mac has used, so files saved
/// under an older key can still be opened. Each entry is the data key sealed
/// with AES-256-GCM under PBKDF2-SHA256(master password, per-entry salt), the
/// same scheme as the Sync payloads. Without the master password the file is
/// useless; with it, it opens the local files on any Mac. That is the point
/// of a backup, and the same exposure the Sync copy already has.
enum LocalKeyBackup {
    struct Entry: Codable, Equatable {
        /// Identifies the data key without revealing it: SHA-256 prefix.
        let id: String
        let created: Date
        let salt: Data
        let iterations: Int
        let sealedKey: Data
    }

    struct File: Codable, Equatable {
        var version = 1
        var entries: [Entry] = []
    }

    static let fileName = "local-key-backup.json"

    // MARK: Pure

    static func keyID(_ key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ key: SymmetricKey, password: String, salt: Data, iterations: Int,
                     created: Date) throws -> Entry {
        let wrapKey = try SyncCrypto.deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try SyncCrypto.encrypt(key.withUnsafeBytes { Data($0) }, key: wrapKey)
        return Entry(id: keyID(key), created: created, salt: salt, iterations: iterations, sealedKey: sealed)
    }

    /// The data key in `entry`, or nil for a wrong password.
    static func open(_ entry: Entry, password: String) -> SymmetricKey? {
        guard let wrapKey = try? SyncCrypto.deriveKey(password: password, salt: entry.salt,
                                                       iterations: entry.iterations),
              let raw = try? SyncCrypto.decrypt(entry.sealedKey, key: wrapKey) else { return nil }
        let key = SymmetricKey(data: raw)
        return keyID(key) == entry.id ? key : nil
    }

    /// `file` with `entry` added, replacing an older entry for the same key
    /// (e.g. sealed with a previous password). Newest first.
    static func adding(_ entry: Entry, to file: File) -> File {
        var updated = file
        updated.entries = [entry] + file.entries.filter { $0.id != entry.id }
        return updated
    }

    /// Whether `file` already holds `key` sealed with `password`.
    static func contains(_ key: SymmetricKey, password: String, in file: File) -> Bool {
        let id = keyID(key)
        return file.entries.contains { $0.id == id && open($0, password: password) != nil }
    }

    /// Every key in `file` that `password` opens.
    static func keys(in file: File, password: String) -> [SymmetricKey] {
        file.entries.compactMap { open($0, password: password) }
    }

    // MARK: I/O

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func load(from url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    static func save(_ file: File, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url(in: AppPaths.configDir).path)
    }

    /// Back up the current data key under `password`, if it isn't already.
    /// Does nothing while the key can't be read, or while any file fails to
    /// open (the key in hand may not be the one that data needs, and backing
    /// it up would offer a recovery that can't work). Slow (PBKDF2): call off
    /// the main thread.
    static func ensure(password: String) {
        guard !password.isEmpty, !EncryptedStore.hasLockedData,
              let key = try? LocalDataCrypto.key() else { return }
        // Checking the file costs a PBKDF2 run; do it once per key + password.
        let marker = keyID(key) + keyID(SymmetricKey(data: SHA256.hash(data: Data(password.utf8))))
        guard claim(marker) else { return }
        let fileURL = url(in: AppPaths.configDir)
        let file = load(from: fileURL) ?? File()
        guard !contains(key, password: password, in: file) else { return }
        do {
            let entry = try seal(key, password: password, salt: SyncCrypto.newSalt(),
                                 iterations: SyncCrypto.pbkdf2Iterations, created: Date())
            try save(adding(entry, to: file), to: fileURL)
            ActivityLog.shared.log(.info, "Backed up the local data key with the master password")
        } catch {
            release(marker)
            ActivityLog.shared.log(.error, "Couldn't back up the local data key",
                                   detail: error.localizedDescription, success: false)
        }
    }

    private static let ensuredLock = NSLock()
    private static var ensured: Set<String> = []

    private static func claim(_ marker: String) -> Bool {
        ensuredLock.lock(); defer { ensuredLock.unlock() }
        return ensured.insert(marker).inserted
    }

    private static func release(_ marker: String) {
        ensuredLock.lock(); defer { ensuredLock.unlock() }
        ensured.remove(marker)
    }
}
