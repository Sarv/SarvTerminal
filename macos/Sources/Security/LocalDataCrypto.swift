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

    // MARK: Seal / open

    static func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key()).combined else {
            throw LocalCryptoError(message: "seal produced no output")
        }
        return combined
    }

    static func open(_ combined: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key())
    }

    // MARK: Key

    /// Whether the encryption key can be read right now (false while Keychain
    /// access is denied). Anything that replaces local data must check this
    /// first, or its writes fail and the change is lost on the next launch.
    static var isKeyAvailable: Bool { (try? key()) != nil }

    static func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let k = SecureEnclave.isAvailable ? try secureEnclaveKey() : try rawKeychainKey()
        cached = k
        return k
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
    }

    static func plan(enclave: KeyLookup, wrapped: KeyLookup) -> KeyPlan {
        switch (enclave, wrapped) {
        case (.unavailable(let status), _), (_, .unavailable(let status)):
            return .locked(status)
        case (.found(let enclaveKey), .found(let wrappedKey)):
            return .use(enclaveKey: enclaveKey, wrappedKey: wrappedKey)
        default:
            return .create
        }
    }

    static func lockedError(_ status: OSStatus) -> LocalCryptoError {
        LocalCryptoError(message: "Couldn't read the encryption key from the Keychain (status \(status)).")
    }

    private static func secureEnclaveKey() throws -> SymmetricKey {
        switch plan(enclave: kcRead(seAccount), wrapped: kcRead(wrappedAccount)) {
        case .locked(let status):
            throw lockedError(status)
        case .use(let seData, let wrapped):
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: seData)
            return try unwrap(wrapped, with: se)
        case .create:
            break
        }
        // First run: create the Enclave key + a random data key wrapped to it.
        let se = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let dataKey = SymmetricKey(size: .bits256)
        let wrapped = try wrap(dataKey, to: se.publicKey)
        guard kcWrite(seAccount, se.dataRepresentation), kcWrite(wrappedAccount, wrapped) else {
            throw LocalCryptoError(message: "failed to persist Secure Enclave key")
        }
        return dataKey
    }

    private static func rawKeychainKey() throws -> SymmetricKey {
        switch kcRead(rawAccount) {
        case .found(let raw): return SymmetricKey(data: raw)
        case .unavailable(let status): throw lockedError(status)
        case .missing: break
        }
        let k = SymmetricKey(size: .bits256)
        let raw = k.withUnsafeBytes { Data($0) }
        guard kcWrite(rawAccount, raw) else { throw LocalCryptoError(message: "failed to persist data key") }
        return k
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

    private static func kcWrite(_ account: String, _ data: Data) -> Bool {
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
        SecItemDelete(base as CFDictionary)
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
enum EncryptedStore {
    enum ReadResult<T> { case none; case loaded(T); case failed; case migrated(T) }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> ReadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else { return .failed }

        // Encrypted envelope?
        if let env = try? JSONDecoder().decode(SarvEncEnvelope.self, from: data),
           env.sarvEnc >= 1, let blob = Data(base64Encoded: env.blob) {
            guard let plain = try? LocalDataCrypto.open(blob),
                  let value = try? decoder.decode(T.self, from: plain) else {
                return .failed // encrypted but unreadable (key missing/changed) — never treat as empty
            }
            return .loaded(value)
        }

        // Legacy plaintext → decode, back up the original, signal migration.
        guard let value = try? decoder.decode(T.self, from: data) else { return .failed }
        let bak = url.deletingPathExtension().appendingPathExtension("pre-encryption.bak")
        if !FileManager.default.fileExists(atPath: bak.path) {
            try? data.write(to: bak, options: .atomic)
        }
        return .migrated(value)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        let plain = try encoder.encode(value)
        let blob = try LocalDataCrypto.seal(plain)
        let env = SarvEncEnvelope(sarvEnc: 1, blob: blob.base64EncodedString())
        try JSONEncoder().encode(env).write(to: url, options: .atomic)
    }
}
