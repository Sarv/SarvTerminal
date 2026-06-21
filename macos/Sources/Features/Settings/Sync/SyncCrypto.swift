import Foundation
import CryptoKit
import CommonCrypto

/// Symmetric encryption for the sync payloads.
///
/// The master password never leaves the device; we derive a 256-bit key from
/// it with PBKDF2-HMAC-SHA256 (a random per-vault salt lives in the plaintext
/// manifest) and encrypt each payload with AES-256-GCM. GCM's authentication
/// tag is what lets us detect a *wrong* master password on another machine:
/// decryption simply fails rather than yielding garbage.
///
/// This is deliberately one-way — there is no key escrow or recovery. If the
/// user forgets the master password the synced data is unrecoverable (the UI
/// warns about this).
enum SyncCrypto {
    /// PBKDF2 work factor. High enough to be costly to brute-force, low enough
    /// to run in well under a second on a manual push/pull.
    static let pbkdf2Iterations = 310_000
    static let saltByteCount = 16
    static let keyByteCount = 32   // AES-256

    enum CryptoError: LocalizedError {
        case keyDerivationFailed
        case wrongPasswordOrCorrupt

        var errorDescription: String? {
            switch self {
            case .keyDerivationFailed:
                return "Could not derive an encryption key from the master password."
            case .wrongPasswordOrCorrupt:
                return "Wrong master password, or the synced data is corrupt."
            }
        }
    }

    /// Fresh random salt for a brand-new vault.
    static func newSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Derive the AES key from the master password + salt via PBKDF2-SHA256.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyByteCount)

        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                passwordData.withUnsafeBytes { passPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: Data(derived))
    }

    /// Encrypt `plaintext` with AES-256-GCM. The returned blob is the combined
    /// representation (nonce ‖ ciphertext ‖ tag) — self-describing for `decrypt`.
    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.keyDerivationFailed }
        return combined
    }

    /// Decrypt a combined AES-256-GCM blob. Throws `wrongPasswordOrCorrupt` when
    /// the key doesn't match (authentication-tag mismatch) or the data is bad.
    static func decrypt(_ combined: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.wrongPasswordOrCorrupt
        }
    }
}
