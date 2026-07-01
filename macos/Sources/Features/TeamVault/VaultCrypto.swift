import Foundation
import CryptoKit

/// Client-side end-to-end crypto for team vaults.
///
/// The server is zero-knowledge: it only ever stores opaque ciphertext and
/// *public* keys. This type is the only place that touches plaintext or the
/// private key.
///
/// Scheme (all available on macOS 13; HPKE would need 14+):
/// - Each user has a long-term X25519 (`Curve25519.KeyAgreement`) keypair.
/// - Each team has a random 256-bit symmetric DEK; the vault blob is sealed
///   with AES-256-GCM under the DEK.
/// - The DEK is "wrapped" to a member by ECDH(ephemeral, memberPub) → HKDF →
///   AES-GCM seal. Wrapped form = ephemeralPublicKey(32B) ‖ AESGCM.combined.
enum VaultCrypto {
    private static let wrapSalt = Data("sarv-vault-dek-wrap-v1".utf8)

    // MARK: Device keypair

    static func generatePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func privateKey(fromBase64 s: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let d = Data(base64Encoded: s) else { throw VaultError("Invalid private key encoding") }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d)
    }

    static func base64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    static func publicKeyBase64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: DEK

    static func generateDEK() -> SymmetricKey { SymmetricKey(size: .bits256) }

    // MARK: Wrap / unwrap

    static func wrapDEK(_ dek: SymmetricKey, toPublicKeyBase64 pub: String) throws -> String {
        guard let pubData = Data(base64Encoded: pub) else { throw VaultError("Invalid recipient public key") }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let ephPubData = ephemeral.publicKey.rawRepresentation
        let symKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: wrapSalt,
            sharedInfo: ephPubData + pubData,
            outputByteCount: 32,
        )
        let dekData = dek.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(dekData, using: symKey).combined else {
            throw VaultError("Failed to seal DEK")
        }
        return (ephPubData + combined).base64EncodedString()
    }

    static func unwrapDEK(_ wrappedBase64: String, with priv: Curve25519.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard let blob = Data(base64Encoded: wrappedBase64), blob.count > 32 else {
            throw VaultError("Invalid wrapped key")
        }
        let ephPubData = blob.prefix(32)
        let sealed = blob.suffix(from: 32)
        let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData)
        let shared = try priv.sharedSecretFromKeyAgreement(with: ephPub)
        let symKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: wrapSalt,
            sharedInfo: Data(ephPubData) + priv.publicKey.rawRepresentation,
            outputByteCount: 32,
        )
        let box = try AES.GCM.SealedBox(combined: sealed)
        return SymmetricKey(data: try AES.GCM.open(box, using: symKey))
    }

    // MARK: Blob seal / open (under the team DEK)

    static func sealBlob(_ plaintext: Data, dek: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: dek).combined else {
            throw VaultError("Failed to seal vault blob")
        }
        return combined
    }

    static func openBlob(_ combined: Data, dek: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: dek)
    }
}
