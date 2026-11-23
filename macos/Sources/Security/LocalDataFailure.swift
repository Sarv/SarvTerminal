import Foundation
import Security

/// Why the key that unlocks local data couldn't be had. Pure.
enum LocalKeyFailure: Equatable {
    /// The Keychain is locked and macOS won't ask for its password on its own.
    case keychainLocked(OSStatus)
    /// macOS asked and access was denied, or the prompt was dismissed.
    case accessDenied(OSStatus)
    /// Any other Keychain error.
    case keychainError(OSStatus)
    /// The key's Keychain items are gone but encrypted data is on disk
    /// (Keychain reset or deleted, data copied from another Mac).
    case keyLost
    /// The key was found but this Mac's Secure Enclave can't use it. It was
    /// made on another Mac: Migration Assistant and backup restores copy the
    /// login Keychain, but a Secure Enclave key only works on the Mac that
    /// made it.
    case enclaveUnusable
    /// A new key couldn't be saved to the Keychain.
    case persistFailed

    static func from(status: OSStatus) -> LocalKeyFailure {
        switch status {
        case errSecInteractionNotAllowed: return .keychainLocked(status)
        case errSecUserCanceled, errSecAuthFailed: return .accessDenied(status)
        default: return .keychainError(status)
        }
    }

    var detail: String {
        switch self {
        case .keychainLocked(let status): return "the Keychain is locked (status \(status))"
        case .accessDenied(let status): return "Keychain access was denied (status \(status))"
        case .keychainError(let status): return "Keychain error (status \(status))"
        case .keyLost: return "the encryption key is missing from the Keychain"
        case .enclaveUnusable: return "the encryption key belongs to another Mac's Secure Enclave"
        case .persistFailed: return "a new encryption key couldn't be saved"
        }
    }
}

struct LocalKeyError: LocalizedError {
    let failure: LocalKeyFailure
    var errorDescription: String? { "Couldn't get the local data key: \(failure.detail)." }
}

/// Why one encrypted file couldn't be loaded. Pure.
enum LocalDataFailure: Equatable {
    case key(LocalKeyFailure)
    /// The key loaded but doesn't open this file: it was encrypted with a
    /// different key.
    case decrypt
    /// Opened, but the contents don't match what this version expects
    /// (usually written by a newer version).
    case decode
    /// The file exists but couldn't be read from disk.
    case unreadableFile

    var detail: String {
        switch self {
        case .key(let failure): return failure.detail
        case .decrypt: return "the file was encrypted with a different key"
        case .decode: return "the contents couldn't be read by this version"
        case .unreadableFile: return "the file couldn't be read from disk"
        }
    }
}

/// What the user can do about the current failures. Pure.
enum LocalDataRemedy: Equatable {
    /// Retry unlocks the login Keychain (macOS asks for its password), then reads again.
    case unlockKeychain
    /// Retry reads again; macOS asks for access and "Always Allow" fixes it for good.
    case allowAccess
    /// Retry may help.
    case retry
    /// Written by a newer version: update the app.
    case update
    /// The data can't be opened on this Mac: restore it from Sync or start fresh.
    case unrecoverable

    /// The remedy for the most serious failure. Every file shares one key, so
    /// a key failure decides for all of them.
    static func choose(for failures: [LocalDataFailure]) -> LocalDataRemedy? {
        let remedies = failures.map(remedy)
        let order: [LocalDataRemedy] = [.unrecoverable, .unlockKeychain, .allowAccess, .update, .retry]
        return order.first(where: remedies.contains)
    }

    private static func remedy(for failure: LocalDataFailure) -> LocalDataRemedy {
        switch failure {
        case .key(.keychainLocked): return .unlockKeychain
        case .key(.accessDenied): return .allowAccess
        case .key(.keychainError), .key(.persistFailed), .unreadableFile: return .retry
        case .key(.keyLost), .key(.enclaveUnusable), .decrypt: return .unrecoverable
        case .decode: return .update
        }
    }

    /// Whether the key itself has to be replaced to start fresh (rather than
    /// only the files it can't open).
    static func needsNewKey(_ failures: [LocalDataFailure]) -> Bool {
        failures.contains { $0 == .key(.keyLost) || $0 == .key(.enclaveUnusable) }
    }
}

/// Finding and setting aside encrypted local data files.
enum LocalDataFiles {
    /// Top-level `.json` files in `directory` that hold encrypted data.
    static func encryptedFiles(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { url in
            url.pathExtension == "json"
                && (try? Data(contentsOf: url)).map(EncryptedStore.isEncryptedEnvelope) == true
        }
    }

    /// `hosts.json` → `hosts.unreadable-<stamp>.json.bak`: no longer read as
    /// data, kept so it can still be recovered on the Mac that has its key. Pure.
    static func asideURL(for url: URL, stamp: String) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(name).unreadable-\(stamp).\(url.pathExtension).bak")
    }

    /// A file-name-safe timestamp, e.g. `20261123-101500`. Pure.
    static func stamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Rename each file aside. Returns the files that couldn't be moved.
    static func setAside(_ urls: [URL], stamp: String) -> [URL] {
        urls.filter { url in
            (try? FileManager.default.moveItem(at: url, to: asideURL(for: url, stamp: stamp))) == nil
        }
    }
}
