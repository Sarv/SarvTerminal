import CryptoKit
import Foundation

/// Opens local data again with the key from the master-password backup
/// (`LocalKeyBackup`), when this Mac's own key no longer opens it.
enum LocalDataRecovery {
    enum Outcome: Equatable {
        /// The key was restored; `reopened` files open again.
        case recovered(reopened: Int)
        /// No backup file on this Mac.
        case noBackup
        /// The password opens none of the backed-up keys.
        case wrongPassword
        /// The password is right but no backed-up key opens the locked files.
        case noMatchingKey
        /// The key couldn't be saved to the Keychain. Nothing changed.
        case saveFailed
    }

    /// What to do with one encrypted file when switching to the recovered key.
    enum FileStep: Equatable {
        /// Already opens with the recovered key.
        case keep
        /// Opens only with the current key: re-encrypt it with the recovered one.
        case reseal(Data)
        /// Opens with neither: left as is.
        case skip
    }

    // MARK: Pure

    /// The key that opens the most of `blobs`; nil if none opens any.
    static func bestKey(_ candidates: [SymmetricKey], for blobs: [Data]) -> SymmetricKey? {
        let scored = candidates.map { key in (key, blobs.filter { opens($0, with: key) }.count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    static func step(for blob: Data, recovered: SymmetricKey, current: SymmetricKey?) -> FileStep {
        if opens(blob, with: recovered) { return .keep }
        if let current, let plain = try? LocalDataCrypto.open(blob, with: current) { return .reseal(plain) }
        return .skip
    }

    private static func opens(_ blob: Data, with key: SymmetricKey) -> Bool {
        (try? LocalDataCrypto.open(blob, with: key)) != nil
    }

    // MARK: I/O

    /// Find the backed-up key that opens the locked files, make it this Mac's
    /// key, and re-encrypt files saved since under the replaced key so every
    /// file opens with one key. Slow (PBKDF2 per backup entry): call off the
    /// main thread. The caller reloads the stores afterwards.
    static func recover(password: String, in directory: URL = AppPaths.configDir) -> Outcome {
        guard let backup = LocalKeyBackup.load(from: LocalKeyBackup.url(in: directory)) else { return .noBackup }
        let candidates = LocalKeyBackup.keys(in: backup, password: password)
        guard !candidates.isEmpty else { return .wrongPassword }

        let files = LocalDataFiles.encryptedFiles(in: directory).compactMap { url in
            (try? Data(contentsOf: url)).flatMap(EncryptedStore.envelope).map { (url: url, blob: $0) }
        }
        let locked = Set(EncryptedStore.lockedFiles.keys)
        let lockedBlobs = files.filter { locked.contains($0.url.standardizedFileURL) }.map(\.blob)
        let target = lockedBlobs.isEmpty ? files.map(\.blob) : lockedBlobs
        guard let recovered = bestKey(candidates, for: target) else {
            return .noMatchingKey
        }

        // Read the current key before it's replaced: files saved under it are
        // re-encrypted below.
        let current = try? LocalDataCrypto.key()
        do { try LocalDataCrypto.adopt(recovered) } catch { return .saveFailed }

        var reopened = 0
        for (url, blob) in files {
            switch step(for: blob, recovered: recovered, current: current) {
            case .keep:
                reopened += 1
            case .reseal(let plain):
                guard let sealed = try? LocalDataCrypto.seal(plain, with: recovered),
                      let contents = try? EncryptedStore.fileContents(sealing: sealed),
                      (try? contents.write(to: url, options: .atomic)) != nil else { continue }
                reopened += 1
            case .skip:
                break
            }
        }
        EncryptedStore.clearFailures()
        ActivityLog.shared.log(.info, "Restored the local data key from the master password backup",
                               detail: "\(reopened) files open again")
        return .recovered(reopened: reopened)
    }
}
