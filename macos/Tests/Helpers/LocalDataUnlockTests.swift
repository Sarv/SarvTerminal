import Foundation
import Security
import Testing
@testable import Ghostty

@Suite
struct LocalDataUnlockTests {
    private let enclave = Data([1])
    private let wrapped = Data([2])

    @Test func bothKeysFoundAreUsed() {
        #expect(LocalDataCrypto.plan(enclave: .found(enclave), wrapped: .found(wrapped))
            == .use(enclaveKey: enclave, wrappedKey: wrapped))
    }

    @Test func missingKeysAreCreatedOnFirstRun() {
        #expect(LocalDataCrypto.plan(enclave: .missing, wrapped: .missing) == .create)
    }

    @Test func deniedReadIsLockedNeverRecreated() {
        let denied = errSecAuthFailed
        #expect(LocalDataCrypto.plan(enclave: .unavailable(denied), wrapped: .found(wrapped)) == .locked(denied))
        #expect(LocalDataCrypto.plan(enclave: .found(enclave), wrapped: .unavailable(denied)) == .locked(denied))
        #expect(LocalDataCrypto.plan(enclave: .unavailable(denied), wrapped: .missing) == .locked(denied))
    }

    @Test func alertListsOnlyLockedStores() {
        let names = LocalDataUnlock.lockedNames([("hosts", true), ("snippets", false), ("port forwards", true)])
        #expect(names == ["hosts", "port forwards"])
        #expect(LocalDataUnlock.lockedNames([("hosts", false)]).isEmpty)
        #expect(LocalDataUnlock.message(for: names).contains("hosts and port forwards"))
    }
}
