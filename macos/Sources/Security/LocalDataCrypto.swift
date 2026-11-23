import Foundation
import CryptoKit
import Security

struct LocalCryptoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// At-rest encryption for local data files (hosts, snippets, …).
///
/// A random 256-bit data key encrypts each file (AES-256-GCM). The data key is
/// itself protected by a **Secure Enclave** P256 key that is non-exportable and
/// hardware-bound to this Mac: the data key is wrapped (ECIES) to the Enclave
/// key and only the Enclave can unwrap it. So a copied `.json` file is opaque
/// ciphertext, and the key cannot be extracted even with full disk access.
/// On Macs without a Secure Enclave we fall back to a random data key stored in
/// the device-only Keychain.
enum LocalDataCrypto {
    #if DEBUG
    private static let service = "com.sarv.terminal.localdata.debug"
    #else
    private static let service = "com.sarv.terminal.localdata"
    #endif
    private static let seAccount = "se-key"
    private static let wrappedAccount = "data-key-wrapped"
    private static let rawAccount = "data-key-raw"
    private static let salt = Data("sarvterminal-local-at-rest-salt-v1".utf8)
    private static let info = Data("sarvterminal-local-at-rest-v1".utf8)

    private static let lock = NSLock()
    private static var cached: SymmetricKey?
    /// Remembered until `resetForRetry`, so one launch asks the Keychain once,
    /// not once per store.
    private static var cachedFailure: LocalKeyFailure?

    // MARK: Seal / open

    static func seal(_ plaintext: Data) throws -> Data {
        try seal(plaintext, with: key())
    }

    static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw LocalCryptoError(message: "seal produced no output")
        }
        return combined
    }

    static func open(_ combined: Data) throws -> Data {
        try open(combined, with: key())
    }

    static func open(_ combined: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key)
    }

    // MARK: Key

    /// Whether the encryption key can be read right now (false while Keychain
    /// access is denied). Anything that replaces local data must check this
    /// first, or its writes fail and the change is lost on the next launch.
    static var isKeyAvailable: Bool { (try? key()) != nil }

    /// The data key. It is read once and kept for the life of the process,
    /// so it never changes while the app runs. Throws `LocalKeyError`.
    static func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let cachedFailure { throw LocalKeyError(failure: cachedFailure) }
        do {
            let k = SecureEnclave.isAvailable ? try secureEnclaveKey() : try rawKeychainKey()
            cached = k
            return k
        } catch let error as LocalKeyError {
            cachedFailure = error.failure
            throw error
        }
    }

    /// Forget a failed lookup so the next `key()` asks the Keychain again.
    static func resetForRetry() {
        lock.lock(); defer { lock.unlock() }
        cachedFailure = nil
    }

    /// Whether any encrypted data exists, i.e. creating a new key would
    /// orphan it.
    private static func encryptedDataExists() -> Bool {
        !LocalDataFiles.encryptedFiles(in: AppPaths.configDir).isEmpty
    }

    /// What a Keychain lookup found. `unavailable` (access denied, prompt
    /// dismissed, Keychain locked…) is NOT "missing": the key exists but we
    /// couldn't read it, so a new one must never be created over it.
    enum KeyLookup: Equatable {
        case found(Data)
        case missing
        case unavailable(OSStatus)
    }

    /// What to do with the Enclave key pair's two Keychain items.
    enum KeyPlan: Equatable {
        case use(enclaveKey: Data, wrappedKey: Data)
        case create
        case locked(OSStatus)
        /// The key is gone (fully or half) but encrypted data exists: never
        /// create a new key over it, that would orphan the data for good.
        case lost
    }

    static func plan(enclave: KeyLookup, wrapped: KeyLookup, encryptedDataExists: Bool) -> KeyPlan {
        switch (enclave, wrapped) {
        case (.unavailable(let status), _), (_, .unavailable(let status)):
            return .locked(status)
        case (.found(let enclaveKey), .found(let wrappedKey)):
            return .use(enclaveKey: enclaveKey, wrappedKey: wrappedKey)
        default:
            return encryptedDataExists ? .lost : .create
        }
    }

    /// The raw-key (no Secure Enclave) equivalent of `plan`.
    static func rawPlan(_ lookup: KeyLookup, encryptedDataExists: Bool) -> KeyPlan {
        switch lookup {
        case .found(let raw): return .use(enclaveKey: Data(), wrappedKey: raw)
        case .unavailable(let status): return .locked(status)
        case .missing: return encryptedDataExists ? .lost : .create
        }
    }

    private static func secureEnclaveKey() throws -> SymmetricKey {
        switch plan(enclave: kcRead(seAccount), wrapped: kcRead(wrappedAccount),
                    encryptedDataExists: encryptedDataExists()) {
        case .locked(let status):
            throw LocalKeyError(failure: .from(status: status))
        case .lost:
            throw LocalKeyError(failure: .keyLost)
        case .use(let seData, let wrapped):
            do {
                let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: seData)
                return try unwrap(wrapped, with: se)
            } catch {
                throw LocalKeyError(failure: .enclaveUnusable)
            }
        case .create:
            break
        }
        // First run: create the Enclave key + a random data key wrapped to it.
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let dataKey = SymmetricKey(size: .bits256)
            let wrapped = try wrap(dataKey, to: se.publicKey)
            guard kcWrite(seAccount, se.dataRepresentation), kcWrite(wrappedAccount, wrapped) else {
                throw LocalKeyError(failure: .persistFailed)
            }
            return dataKey
        } catch {
            throw LocalKeyError(failure: .persistFailed)
        }
    }

    private static func rawKeychainKey() throws -> SymmetricKey {
        switch rawPlan(kcRead(rawAccount), encryptedDataExists: encryptedDataExists()) {
        case .use(_, let raw): return SymmetricKey(data: raw)
        case .locked(let status): throw LocalKeyError(failure: .from(status: status))
        case .lost: throw LocalKeyError(failure: .keyLost)
        case .create: break
        }
        let k = SymmetricKey(size: .bits256)
        let raw = k.withUnsafeBytes { Data($0) }
        guard kcWrite(rawAccount, raw) else { throw LocalKeyError(failure: .persistFailed) }
        return k
    }

    // MARK: Recovery

    /// Ask macOS to unlock the login Keychain; it shows its password prompt.
    /// The only API that does this explicitly is deprecated, but it still works
    /// and has no replacement.
    static func unlockKeychain() {
        SecKeychainUnlock(nil, 0, nil, false)
    }

    /// Move the key's items aside (renamed, not deleted) so the next `key()`
    /// creates a new one. Only for a key that can't open anything on this Mac;
    /// the caller sets the encrypted files aside first.
    static func retireKey(stamp: String) {
        lock.lock(); defer { lock.unlock() }
        for account in [seAccount, wrappedAccount, rawAccount] {
            kcRename(account, to: "\(account).retired-\(stamp)")
        }
        cached = nil
        cachedFailure = nil
    }

    /// Make `dataKey` (recovered from the master-password backup) this Mac's
    /// key: protect it with a new Secure Enclave key and store it. The items
    /// it replaces are renamed aside, not deleted.
    static func adopt(_ dataKey: SymmetricKey) throws {
        lock.lock(); defer { lock.unlock() }
        if SecureEnclave.isAvailable {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let wrapped = try wrap(dataKey, to: se.publicKey)
            guard kcWrite(seAccount, se.dataRepresentation), kcWrite(wrappedAccount, wrapped) else {
                throw LocalKeyError(failure: .persistFailed)
            }
        } else {
            guard kcWrite(rawAccount, dataKey.withUnsafeBytes { Data($0) }) else {
                throw LocalKeyError(failure: .persistFailed)
            }
        }
        cached = dataKey
        cachedFailure = nil
    }

    // ECIES wrap/unwrap of the data key to the Enclave key (P256 rawRepresentation = 64B).
    private static func wrap(_ dataKey: SymmetricKey, to pub: P256.KeyAgreement.PublicKey) throws -> Data {
        let eph = P256.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: pub)
        let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let dk = dataKey.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(dk, using: wrapKey).combined else {
            throw LocalCryptoError(message: "wrap failed")
        }
        return eph.publicKey.rawRepresentation + sealed
    }

    private static func unwrap(_ blob: Data, with se: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard blob.count > 64 else { throw LocalCryptoError(message: "wrapped key too short") }
        let ephPub = try P256.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(64))
        let sealed = blob.suffix(from: 64)
        let shared = try se.sharedSecretFromKeyAgreement(with: ephPub)
        let wrapKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        return SymmetricKey(data: try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: wrapKey))
    }

    // MARK: Key-material storage
    //
    // Release: device-only generic-password Keychain items. The release app is
    // stably code-signed, so its Keychain ACL matches on every launch and macOS
    // never prompts.
    //
    // Debug: the dev app is ad-hoc signed and re-signed on every rebuild, so its
    // code identity (cdhash) changes each launch — the Keychain ACL never
    // matches and macOS re-prompts for the login password every time. Instead we
    // keep the key material in files under the dev data dir. The Secure-Enclave
    // wrapping is unchanged, so these blobs stay opaque without this Mac's
    // Enclave; only the storage location moves. On first run we migrate any
    // existing key out of the legacy Keychain — one final prompt, then silent.

    /// Never overwrites: whatever is stored under `account` is renamed to
    /// `<account>.replaced-<time>` first. Up to v1.12.0 the Keychain item was
    /// deleted here, so any failed read that fell through to "first run"
    /// destroyed the real key for good.
    private static func kcWrite(_ account: String, _ data: Data) -> Bool {
        kcRename(account, to: "\(account).replaced-\(LocalDataFiles.stamp(for: Date()))")
        #if DEBUG
        return (try? writeKeyFile(account, data)) != nil
        #else
        return keychainWrite(account, data)
        #endif
    }

    private static func kcRead(_ account: String) -> KeyLookup {
        #if DEBUG
        if let fromFile = readKeyFile(account) { return .found(fromFile) }
        // One-time migration from the legacy Keychain (prompts once), then
        // persist to a file so every later launch is silent.
        let legacy = keychainRead(account)
        if case .found(let data) = legacy { try? writeKeyFile(account, data) }
        return legacy
        #else
        return keychainRead(account)
        #endif
    }

    private static func kcRename(_ account: String, to newAccount: String) {
        #if DEBUG
        guard let dir = try? keyStoreDir() else { return }
        try? FileManager.default.moveItem(at: dir.appendingPathComponent(account),
                                          to: dir.appendingPathComponent(newAccount))
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemUpdate(query as CFDictionary, [kSecAttrAccount as String: newAccount] as CFDictionary)
    }

    private static func keychainRead(_ account: String) -> KeyLookup {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable(status) }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    #if !DEBUG
    private static func keychainWrite(_ account: String, _ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    #endif

    #if DEBUG
    /// Directory holding the dev build's key-material files (perms 0700).
    private static func keyStoreDir() throws -> URL {
        let dir = AppPaths.configDir.appendingPathComponent("keystore", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static func readKeyFile(_ account: String) -> Data? {
        guard let url = try? keyStoreDir().appendingPathComponent(account) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeKeyFile(_ account: String, _ data: Data) throws {
        let url = try keyStoreDir().appendingPathComponent(account)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #endif
}

/// Envelope written to disk for an encrypted store file.
private struct SarvEncEnvelope: Codable {
    var sarvEnc: Int
    var blob: String // base64 AES-GCM
}

/// Read/write a Codable value to an **encrypted** JSON file, with one-time safe
/// migration from a legacy plaintext file (original is backed up first).
///
/// Every file that fails to load is remembered with its reason, and writes to
/// it are refused until it loads or is set aside. A store whose load failed
/// holds empty data in memory, so writing it would replace the user's real
/// data. This is the one check that keeps every store from doing that.
enum EncryptedStore {
    enum ReadResult<T> { case none; case loaded(T); case failed(LocalDataFailure); case migrated(T) }

    struct LockedFileError: LocalizedError {
        let url: URL
        var errorDescription: String? { "\(url.lastPathComponent) couldn't be loaded, so it isn't overwritten." }
    }

    private static let failuresLock = NSLock()
    private static var failures: [URL: LocalDataFailure] = [:]

    /// Files that failed to load, with why.
    static var lockedFiles: [URL: LocalDataFailure] {
        failuresLock.lock(); defer { failuresLock.unlock() }
        return failures
    }

    static var hasLockedData: Bool { !lockedFiles.isEmpty }

    /// Forget every failure: after the files were set aside, or before a retry
    /// reloads them (a reload records whatever still fails).
    static func clearFailures() {
        failuresLock.lock(); defer { failuresLock.unlock() }
        failures = [:]
    }

    private static func record<T>(_ result: ReadResult<T>, for url: URL) -> ReadResult<T> {
        failuresLock.lock(); defer { failuresLock.unlock() }
        if case .failed(let failure) = result {
            failures[url.standardizedFileURL] = failure
        } else {
            failures[url.standardizedFileURL] = nil
        }
        return result
    }

    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        envelope(in: data) != nil
    }

    /// The sealed blob inside an encrypted file's contents, or nil if it isn't one.
    static func envelope(in data: Data) -> Data? {
        guard let env = try? JSONDecoder().decode(SarvEncEnvelope.self, from: data), env.sarvEnc >= 1 else {
            return nil
        }
        return Data(base64Encoded: env.blob)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> ReadResult<T> {
        record(load(type, from: url, decoder: decoder), for: url)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> ReadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else { return .failed(.unreadableFile) }

        // Encrypted but unreadable is never treated as empty.
        if let blob = envelope(in: data) {
            let key: SymmetricKey
            do {
                key = try LocalDataCrypto.key()
            } catch let error as LocalKeyError {
                return .failed(.key(error.failure))
            } catch {
                return .failed(.key(.persistFailed))
            }
            guard let plain = try? LocalDataCrypto.open(blob, with: key) else { return .failed(.decrypt) }
            guard let value = try? decoder.decode(T.self, from: plain) else { return .failed(.decode) }
            return .loaded(value)
        }

        // Legacy plaintext → decode, back up the original, signal migration.
        guard let value = try? decoder.decode(T.self, from: data) else { return .failed(.decode) }
        let bak = url.deletingPathExtension().appendingPathExtension("pre-encryption.bak")
        if !FileManager.default.fileExists(atPath: bak.path) {
            try? data.write(to: bak, options: .atomic)
        }
        return .migrated(value)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        guard lockedFiles[url.standardizedFileURL] == nil else { throw LockedFileError(url: url) }
        try fileContents(sealing: try LocalDataCrypto.seal(try encoder.encode(value))).write(to: url, options: .atomic)
    }

    /// An encrypted file's contents for a sealed blob.
    static func fileContents(sealing blob: Data) throws -> Data {
        try JSONEncoder().encode(SarvEncEnvelope(sarvEnc: 1, blob: blob.base64EncodedString()))
    }
}
