import CryptoKit
import Foundation
import Security
import Testing
@testable import Ghostty

@Suite
struct LocalDataUnlockTests {
    private let enclave = Data([1])
    private let wrapped = Data([2])

    // MARK: Key plan

    @Test func bothKeysFoundAreUsed() {
        for exists in [false, true] {
            #expect(LocalDataCrypto.plan(enclave: .found(enclave), wrapped: .found(wrapped), encryptedDataExists: exists)
                == .use(enclaveKey: enclave, wrappedKey: wrapped))
        }
    }

    @Test func missingKeysAreCreatedOnlyWhenNoEncryptedDataExists() {
        #expect(LocalDataCrypto.plan(enclave: .missing, wrapped: .missing, encryptedDataExists: false) == .create)
    }

    @Test func missingKeyWithEncryptedDataIsLostNeverRecreated() {
        #expect(LocalDataCrypto.plan(enclave: .missing, wrapped: .missing, encryptedDataExists: true) == .lost)
        #expect(LocalDataCrypto.plan(enclave: .found(enclave), wrapped: .missing, encryptedDataExists: true) == .lost)
        #expect(LocalDataCrypto.plan(enclave: .missing, wrapped: .found(wrapped), encryptedDataExists: true) == .lost)
    }

    @Test func deniedReadIsLockedNeverRecreated() {
        let denied = errSecAuthFailed
        for exists in [false, true] {
            #expect(LocalDataCrypto.plan(enclave: .unavailable(denied), wrapped: .found(wrapped),
                                         encryptedDataExists: exists) == .locked(denied))
            #expect(LocalDataCrypto.plan(enclave: .found(enclave), wrapped: .unavailable(denied),
                                         encryptedDataExists: exists) == .locked(denied))
            #expect(LocalDataCrypto.plan(enclave: .unavailable(denied), wrapped: .missing,
                                         encryptedDataExists: exists) == .locked(denied))
        }
    }

    @Test func rawKeyPlanFollowsTheSameRules() {
        #expect(LocalDataCrypto.rawPlan(.found(wrapped), encryptedDataExists: true)
            == .use(enclaveKey: Data(), wrappedKey: wrapped))
        #expect(LocalDataCrypto.rawPlan(.missing, encryptedDataExists: false) == .create)
        #expect(LocalDataCrypto.rawPlan(.missing, encryptedDataExists: true) == .lost)
        #expect(LocalDataCrypto.rawPlan(.unavailable(errSecInteractionNotAllowed), encryptedDataExists: true)
            == .locked(errSecInteractionNotAllowed))
    }

    // MARK: Failure → remedy

    @Test func keychainStatusMapsToCause() {
        #expect(LocalKeyFailure.from(status: errSecInteractionNotAllowed) == .keychainLocked(errSecInteractionNotAllowed))
        #expect(LocalKeyFailure.from(status: errSecUserCanceled) == .accessDenied(errSecUserCanceled))
        #expect(LocalKeyFailure.from(status: errSecAuthFailed) == .accessDenied(errSecAuthFailed))
        #expect(LocalKeyFailure.from(status: errSecNotAvailable) == .keychainError(errSecNotAvailable))
    }

    @Test func eachFailureGetsItsRemedy() {
        let locked = LocalKeyFailure.keychainLocked(errSecInteractionNotAllowed)
        let denied = LocalKeyFailure.accessDenied(errSecAuthFailed)
        #expect(LocalDataRemedy.choose(for: [.key(locked)]) == .unlockKeychain)
        #expect(LocalDataRemedy.choose(for: [.key(denied)]) == .allowAccess)
        #expect(LocalDataRemedy.choose(for: [.key(.keychainError(-1))]) == .retry)
        #expect(LocalDataRemedy.choose(for: [.key(.persistFailed)]) == .retry)
        #expect(LocalDataRemedy.choose(for: [.unreadableFile]) == .retry)
        #expect(LocalDataRemedy.choose(for: [.decode]) == .update)
        #expect(LocalDataRemedy.choose(for: [.decrypt]) == .unrecoverable)
        #expect(LocalDataRemedy.choose(for: [.key(.keyLost)]) == .unrecoverable)
        #expect(LocalDataRemedy.choose(for: [.key(.enclaveUnusable)]) == .unrecoverable)
        #expect(LocalDataRemedy.choose(for: []) == nil)
    }

    @Test func mostSeriousFailureDecides() {
        let locked = LocalDataFailure.key(.keychainLocked(errSecInteractionNotAllowed))
        #expect(LocalDataRemedy.choose(for: [.unreadableFile, .decode, locked]) == .unlockKeychain)
        #expect(LocalDataRemedy.choose(for: [locked, .decrypt]) == .unrecoverable)
        #expect(LocalDataRemedy.choose(for: [.unreadableFile, .decode]) == .update)
    }

    @Test func onlyAMissingOrForeignKeyNeedsANewKey() {
        #expect(LocalDataRemedy.needsNewKey([.decrypt, .key(.keyLost)]))
        #expect(LocalDataRemedy.needsNewKey([.key(.enclaveUnusable)]))
        #expect(!LocalDataRemedy.needsNewKey([.decrypt, .decode]))
        #expect(!LocalDataRemedy.needsNewKey([.key(.accessDenied(errSecAuthFailed))]))
    }

    // MARK: Alert content

    @Test func alertListsOnlyLockedStores() {
        let names = LocalDataUnlock.lockedNames([("hosts", true), ("snippets", false), ("port forwards", true)])
        #expect(names == ["hosts", "port forwards"])
        #expect(LocalDataUnlock.lockedNames([("hosts", false)]).isEmpty)
        #expect(LocalDataUnlock.message(for: names, remedy: .retry, canSync: false).contains("hosts and port forwards"))
    }

    @Test func buttonsMatchTheRemedy() {
        #expect(LocalDataUnlock.actions(for: .unlockKeychain, canSync: true, hasBackup: true) == [.unlockAndRetry, .later])
        #expect(LocalDataUnlock.actions(for: .allowAccess, canSync: true, hasBackup: true) == [.retry, .later])
        #expect(LocalDataUnlock.actions(for: .update, canSync: true, hasBackup: true) == [.checkForUpdates, .later])
        #expect(LocalDataUnlock.actions(for: .unrecoverable, canSync: true, hasBackup: false)
            == [.restoreFromSync, .startFresh, .later])
        #expect(LocalDataUnlock.actions(for: .unrecoverable, canSync: false, hasBackup: false) == [.startFresh, .later])
    }

    @Test func masterPasswordComesFirstWhenABackupExists() {
        #expect(LocalDataUnlock.actions(for: .unrecoverable, canSync: true, hasBackup: true)
            == [.useMasterPassword, .restoreFromSync, .startFresh, .later])
        #expect(LocalDataUnlock.actions(for: .unrecoverable, canSync: false, hasBackup: true)
            == [.useMasterPassword, .startFresh, .later])
        #expect(LocalDataUnlock.message(for: ["hosts"], remedy: .unrecoverable, canSync: true, hasBackup: true)
            .contains("master password"))
    }

    @Test func messagesNameTheFix() {
        #expect(LocalDataUnlock.message(for: ["hosts"], remedy: .allowAccess, canSync: false).contains("Always Allow"))
        #expect(LocalDataUnlock.message(for: ["hosts"], remedy: .unlockKeychain, canSync: false).contains("login password"))
        #expect(LocalDataUnlock.message(for: ["hosts"], remedy: .unrecoverable, canSync: true).contains("Restore from Sync"))
        #expect(!LocalDataUnlock.message(for: ["hosts"], remedy: .unrecoverable, canSync: false).contains("Restore from Sync"))
    }

    @Test func detailsListEveryFileWithItsReason() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let details = LocalDataUnlock.details([
            dir.appendingPathComponent("snippets.json"): .decode,
            dir.appendingPathComponent("hosts.json"): .key(.accessDenied(errSecAuthFailed)),
        ])
        #expect(details == "hosts.json: Keychain access was denied (status \(errSecAuthFailed))\n"
            + "snippets.json: the contents couldn't be read by this version")
    }

    @Test func startFreshSetsAsideOnlyWhatCantBeOpened() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let hosts = dir.appendingPathComponent("hosts.json")
        let snippets = dir.appendingPathComponent("snippets.json")
        let ai = dir.appendingPathComponent("ai.json")
        let all = [ai, hosts, snippets]
        #expect(LocalDataUnlock.filesToSetAside([hosts: .key(.keyLost)], allEncrypted: all) == all)
        #expect(LocalDataUnlock.filesToSetAside([hosts: .decrypt, snippets: .decode], allEncrypted: all) == [hosts])
    }

    // MARK: Files

    @Test func asideNameKeepsTheFileRecoverable() {
        let url = URL(fileURLWithPath: "/cfg/hosts.json")
        #expect(LocalDataFiles.asideURL(for: url, stamp: "20261123-101500").path
            == "/cfg/hosts.unreadable-20261123-101500.json.bak")
    }

    @Test func stampIsUTCAndFileNameSafe() {
        #expect(LocalDataFiles.stamp(for: Date(timeIntervalSince1970: 0)) == "19700101-000000")
    }

    @Test func envelopeIsRecognised() {
        #expect(EncryptedStore.isEncryptedEnvelope(Data(#"{"sarvEnc":1,"blob":"AAEC"}"#.utf8)))
        #expect(!EncryptedStore.isEncryptedEnvelope(Data(#"[{"name":"web"}]"#.utf8)))
        #expect(!EncryptedStore.isEncryptedEnvelope(Data("garbage".utf8)))
    }

    @Test func encryptedFilesAreFoundAndSetAside() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appendingPathComponent("hosts.json")
        try Data(#"{"sarvEnc":1,"blob":"AAEC"}"#.utf8).write(to: hosts)
        try Data(#"[{"id":"a"}]"#.utf8).write(to: dir.appendingPathComponent("groups.json"))
        try Data(#"{"sarvEnc":1,"blob":"AAEC"}"#.utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let found = LocalDataFiles.encryptedFiles(in: dir)
        #expect(found.map(\.lastPathComponent) == ["hosts.json"])

        #expect(LocalDataFiles.setAside(found, stamp: "S").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: hosts.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hosts.unreadable-S.json.bak").path))
        #expect(LocalDataFiles.setAside(found, stamp: "S") == found)
    }

    // MARK: Write guard

    @Test func fileThatFailedToLoadIsNeverOverwritten() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        let original = Data("not json".utf8)
        try original.write(to: url)

        let result = EncryptedStore.read([String].self, from: url, decoder: JSONDecoder())
        guard case .failed(let failure) = result else {
            Issue.record("expected a failed read")
            return
        }
        #expect(failure == .decode)
        #expect(EncryptedStore.lockedFiles[url.standardizedFileURL] == .decode)
        #expect(throws: EncryptedStore.LockedFileError.self) {
            try EncryptedStore.write(["x"], to: url, encoder: JSONEncoder())
        }
        #expect(try Data(contentsOf: url) == original)

        // A file that's gone loads as empty and is no longer locked.
        try FileManager.default.removeItem(at: url)
        guard case .none = EncryptedStore.read([String].self, from: url, decoder: JSONDecoder()) else {
            Issue.record("expected no data")
            return
        }
        #expect(EncryptedStore.lockedFiles[url.standardizedFileURL] == nil)
    }

    // MARK: Master password key backup

    /// Low iteration count: these tests check the format, not PBKDF2 strength.
    private func entry(_ key: SymmetricKey, _ password: String, created: Date = Date()) throws -> LocalKeyBackup.Entry {
        try LocalKeyBackup.seal(key, password: password, salt: Data(repeating: 7, count: 16),
                                iterations: 1000, created: created)
    }

    @Test func backupOpensOnlyWithTheRightPassword() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try entry(key, "correct horse")
        #expect(LocalKeyBackup.open(sealed, password: "correct horse").map(LocalKeyBackup.keyID) == LocalKeyBackup.keyID(key))
        #expect(LocalKeyBackup.open(sealed, password: "wrong") == nil)
        #expect(!sealed.sealedKey.isEmpty)
    }

    @Test func backupKeepsEveryKeyNewestFirstAndReplacesTheSameKey() throws {
        let old = SymmetricKey(size: .bits256)
        let new = SymmetricKey(size: .bits256)
        var file = LocalKeyBackup.File()
        file = LocalKeyBackup.adding(try entry(old, "pw1"), to: file)
        file = LocalKeyBackup.adding(try entry(new, "pw1"), to: file)
        #expect(file.entries.map(\.id) == [LocalKeyBackup.keyID(new), LocalKeyBackup.keyID(old)])

        // Same key under a new password replaces its old entry.
        file = LocalKeyBackup.adding(try entry(old, "pw2"), to: file)
        #expect(file.entries.map(\.id) == [LocalKeyBackup.keyID(old), LocalKeyBackup.keyID(new)])
        #expect(LocalKeyBackup.contains(old, password: "pw2", in: file))
        #expect(!LocalKeyBackup.contains(old, password: "pw1", in: file))
        #expect(LocalKeyBackup.keys(in: file, password: "pw1").map(LocalKeyBackup.keyID) == [LocalKeyBackup.keyID(new)])
    }

    @Test func backupFileRoundTripsAndIsPrivate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = LocalKeyBackup.url(in: dir)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let file = LocalKeyBackup.adding(try entry(SymmetricKey(size: .bits256), "pw", created: created),
                                         to: LocalKeyBackup.File())
        try LocalKeyBackup.save(file, to: url)
        #expect(LocalKeyBackup.load(from: url) == file)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(LocalKeyBackup.load(from: dir.appendingPathComponent("missing.json")) == nil)
    }

    // MARK: Recovery

    @Test func recoveryPicksTheKeyThatOpensTheMostFiles() throws {
        let old = SymmetricKey(size: .bits256)
        let new = SymmetricKey(size: .bits256)
        let stranger = SymmetricKey(size: .bits256)
        let blobs = try [old, old, new].map { try LocalDataCrypto.seal(Data("x".utf8), with: $0) }
        #expect(LocalDataRecovery.bestKey([new, old], for: blobs).map(LocalKeyBackup.keyID) == LocalKeyBackup.keyID(old))
        #expect(LocalDataRecovery.bestKey([stranger], for: blobs) == nil)
        #expect(LocalDataRecovery.bestKey([], for: blobs) == nil)
    }

    @Test func filesSavedUnderTheReplacedKeyAreResealed() throws {
        let recovered = SymmetricKey(size: .bits256)
        let replacement = SymmetricKey(size: .bits256)
        let plain = Data("hosts".utf8)
        let underRecovered = try LocalDataCrypto.seal(plain, with: recovered)
        let underReplacement = try LocalDataCrypto.seal(plain, with: replacement)
        let underNeither = try LocalDataCrypto.seal(plain, with: SymmetricKey(size: .bits256))

        #expect(LocalDataRecovery.step(for: underRecovered, recovered: recovered, current: replacement) == .keep)
        #expect(LocalDataRecovery.step(for: underReplacement, recovered: recovered, current: replacement) == .reseal(plain))
        #expect(LocalDataRecovery.step(for: underNeither, recovered: recovered, current: replacement) == .skip)
        #expect(LocalDataRecovery.step(for: underReplacement, recovered: recovered, current: nil) == .skip)
    }

    @Test func recoveryWithoutABackupChangesNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LocalDataRecovery.recover(password: "pw", in: dir) == .noBackup)
    }

    @Test func recoveryWithTheWrongPasswordChangesNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LocalKeyBackup.adding(try entry(SymmetricKey(size: .bits256), "right"), to: LocalKeyBackup.File())
        try LocalKeyBackup.save(file, to: LocalKeyBackup.url(in: dir))
        #expect(LocalDataRecovery.recover(password: "wrong", in: dir) == .wrongPassword)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDataUnlockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
