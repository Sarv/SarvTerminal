import Foundation
import Security

/// Keychain storage for the two sync secrets that must never be written to
/// disk in plaintext and must never leave the device: the **master password**
/// (the encryption key) and the **GitHub PAT**.
///
/// Both live in a SINGLE Keychain item (a small JSON blob), so macOS asks for
/// access at most once — not once per secret. There is no biometric gate, and
/// the decoded blob is cached in memory for the session, so frequent checks
/// (`isConfigured`, the Vaults icon) never re-hit the Keychain. Net result: the
/// user enters the master password once at setup and sync runs silently.
///
/// The item is `…WhenUnlockedThisDeviceOnly` — excluded from iCloud Keychain
/// and never synced.
enum SyncKeychain {
    private static let service = "com.sarv.terminal.sync"
    private static let account = "syncSecrets"

    private struct Secrets: Codable {
        var master: String?
        var pat: String?
    }

    private static let lock = NSLock()
    private static var cache: Secrets?

    enum KeychainError: LocalizedError {
        case storeFailed(OSStatus)
        case notFound

        var errorDescription: String? {
            switch self {
            case .storeFailed(let s): return "Keychain error (\(s))."
            case .notFound:           return "No master password is set."
            }
        }
    }

    // MARK: - Master password

    static func storeMasterPassword(_ password: String) throws {
        try mutate { $0.master = password }
    }

    /// Retrieve the master password silently. `prompt` is unused (kept for
    /// call-site compatibility — there's no biometric gate anymore).
    static func retrieveMasterPassword(prompt: String = "") throws -> String {
        guard let master = read().master, !master.isEmpty else { throw KeychainError.notFound }
        return master
    }

    static func hasMasterPassword() -> Bool { (read().master?.isEmpty == false) }

    static func deleteMasterPassword() { try? mutate { $0.master = nil } }

    // MARK: - GitHub PAT

    static func storePAT(_ token: String) throws { try mutate { $0.pat = token } }

    static func retrievePAT() -> String? { read().pat }

    static func hasPAT() -> Bool { (read().pat?.isEmpty == false) }

    static func deletePAT() { try? mutate { $0.pat = nil } }

    // MARK: - Backing store (single item + in-memory cache)

    /// Decode the secrets blob, hitting the Keychain at most once per session.
    /// The first read may show macOS's one-time "allow access" prompt.
    private static func read() -> Secrets {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let secrets = loadLocked()
        cache = secrets
        return secrets
    }

    private static func mutate(_ change: (inout Secrets) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var secrets = cache ?? loadLocked()
        change(&secrets)
        try persistLocked(secrets)
        cache = secrets
    }

    /// Load the combined item, migrating from the old two-item layout if needed.
    /// Assumes the lock is held.
    private static func loadLocked() -> Secrets {
        if let combined = decodeItem(account: account) { return combined }

        // Migrate: older builds stored two separate items. Fold them into the
        // combined item and remove the old ones so there's a single ACL prompt.
        let legacyMaster = rawString(account: "masterPassword")
        let legacyPAT = rawString(account: "githubPAT")
        if legacyMaster != nil || legacyPAT != nil {
            let migrated = Secrets(master: legacyMaster, pat: legacyPAT)
            try? persistLocked(migrated)
            SecItemDelete(query(account: "masterPassword") as CFDictionary)
            SecItemDelete(query(account: "githubPAT") as CFDictionary)
            // Also clear any biometric/data-protection variant from old builds.
            var dp = query(account: "masterPassword"); dp[kSecUseDataProtectionKeychain as String] = true
            SecItemDelete(dp as CFDictionary)
            return migrated
        }
        return Secrets()
    }

    private static func persistLocked(_ secrets: Secrets) throws {
        let data = (try? JSONEncoder().encode(secrets)) ?? Data()
        SecItemDelete(baseQuery as CFDictionary)
        var attrs: [String: Any] = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // A friendly label/description so the macOS access prompt and Keychain
        // Access read clearly, e.g. "SarvTerminal wants to use 'SarvTerminal
        // Encrypted Sync' …".
        attrs[kSecAttrLabel as String] = "SarvTerminal Encrypted Sync"
        attrs[kSecAttrDescription as String] = "Master password and Git token used to encrypt and sync your settings."
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.storeFailed(status) }
    }

    private static func decodeItem(account: String) -> Secrets? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }

    private static func rawString(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var baseQuery: [String: Any] { query(account: account) }
}
