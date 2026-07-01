import Foundation
import Security

/// One signed-in account: identity + session token + that user's device
/// private key (base64 X25519 raw representation). The private key is per
/// account — each user identity has its own keypair.
struct VaultAccount: Codable, Identifiable, Equatable {
    let id: String // OAuth subject / Vault user id
    var email: String
    var token: String
    var privateKey: String
}

/// Keychain storage for team-vault accounts. Mirrors `SyncKeychain` — a single
/// JSON item per build flavor, `WhenUnlockedThisDeviceOnly`, cached + locked.
/// Holds *multiple* accounts so the user can switch between them.
enum VaultKeychain {
    #if DEBUG
    private static let service = "com.sarv.terminal.vault.debug"
    #else
    private static let service = "com.sarv.terminal.vault"
    #endif
    private static let account = "vaultAccounts"

    private struct Blob: Codable {
        var accounts: [VaultAccount] = []
        var activeID: String?
    }

    private static let lock = NSLock()
    private static var cache: Blob?

    // MARK: Public API

    static func accounts() -> [VaultAccount] { load().accounts }
    static func activeID() -> String? { load().activeID }
    static func active() -> VaultAccount? {
        let b = load()
        return b.accounts.first { $0.id == b.activeID } ?? b.accounts.first
    }

    /// Insert or update an account (matched by id) and make it active.
    static func upsert(_ acct: VaultAccount, makeActive: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        var b = loadLocked()
        if let i = b.accounts.firstIndex(where: { $0.id == acct.id }) {
            b.accounts[i] = acct
        } else {
            b.accounts.append(acct)
        }
        if makeActive || b.activeID == nil { b.activeID = acct.id }
        store(b)
    }

    static func setActive(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var b = loadLocked()
        guard b.accounts.contains(where: { $0.id == id }) else { return }
        b.activeID = id
        store(b)
    }

    static func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var b = loadLocked()
        b.accounts.removeAll { $0.id == id }
        if b.activeID == id { b.activeID = b.accounts.first?.id }
        store(b)
    }

    // MARK: Internals

    private static func load() -> Blob {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    // Release stores the accounts in the Keychain. Debug stores them in a
    // Secure-Enclave-encrypted file under the dev data dir instead: the dev app
    // is ad-hoc re-signed on every rebuild, so its Keychain ACL never matches
    // and macOS would re-prompt for the login password on every launch. The
    // file is sealed with `LocalDataCrypto` (also file-backed in debug), so the
    // tokens/keys stay Enclave-protected on disk. On first run we migrate any
    // existing Keychain accounts into the file — one final prompt, then silent.
    private static func loadLocked() -> Blob {
        if let cache { return cache }
        let blob: Blob
        #if DEBUG
        if let fromFile = readEncryptedFile() {
            blob = fromFile
        } else if let migrated = keychainBlob() {
            try? writeEncryptedFile(migrated)
            blob = migrated
        } else {
            blob = Blob()
        }
        #else
        blob = keychainBlob() ?? Blob()
        #endif
        cache = blob
        return blob
    }

    /// Read the accounts blob from the Keychain. nil when nothing is stored.
    private static func keychainBlob() -> Blob? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return nil }
        return blob
    }

    private static func store(_ blob: Blob) {
        cache = blob
        #if DEBUG
        try? writeEncryptedFile(blob)
        #else
        guard let data = try? JSONEncoder().encode(blob) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        #endif
    }

    #if DEBUG
    /// The dev build's Secure-Enclave-encrypted accounts file (perms 0600).
    private static func accountsFileURL() throws -> URL {
        let dir = AppPaths.configDir.appendingPathComponent("keystore", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("vault-accounts")
    }

    private static func readEncryptedFile() -> Blob? {
        guard let url = try? accountsFileURL(),
              let sealed = try? Data(contentsOf: url),
              let plain = try? LocalDataCrypto.open(sealed) else { return nil }
        return try? JSONDecoder().decode(Blob.self, from: plain)
    }

    private static func writeEncryptedFile(_ blob: Blob) throws {
        let url = try accountsFileURL()
        let sealed = try LocalDataCrypto.seal(try JSONEncoder().encode(blob))
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #endif
}
