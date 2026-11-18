import Foundation

/// A store whose encrypted file can fail to load (e.g. Keychain access to the
/// encryption key was denied) and can try again.
protocol EncryptedReloadable: AnyObject {
    var loadFailed: Bool { get }
    func reload()
}

/// When saved data can't be unlocked at launch, tell the user instead of
/// silently showing empty lists, and let them retry (which asks the Keychain
/// again). Nothing is overwritten while a store is locked: writes need the
/// same key, so they fail rather than replace the encrypted file.
enum LocalDataUnlock {
    private static var stores: [(name: String, store: EncryptedReloadable)] {
        [
            ("hosts", SavedHostsStore.shared),
            ("snippets", SnippetsStore.shared),
            ("saved sessions", SavedSessionsStore.shared),
            ("port forwards", PortForwardStore.shared),
            ("scratchpad", ScratchpadStore.shared),
        ]
    }

    /// Names of the stores that failed, in display order.
    static func lockedNames(_ entries: [(name: String, failed: Bool)]) -> [String] {
        entries.filter(\.failed).map(\.name)
    }

    static func message(for names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        return "Sarv Terminal couldn't read the key that unlocks your saved \(list). "
            + "This usually means Keychain access was denied or the Keychain is locked.\n\n"
            + "Your data is still on disk and hasn't been changed. Choose Retry and allow access when macOS asks."
    }

    /// Show the alert if anything is locked; Retry reloads and checks again.
    @MainActor
    static func checkAndPrompt() {
        let names = lockedNames(stores.map { ($0.name, $0.store.loadFailed) })
        guard !names.isEmpty else { return }
        SarvAlert.present(
            title: "Couldn't Unlock Your Saved Data",
            message: message(for: names),
            buttons: [
                SarvAlert.Button("Retry", isDefault: true),
                SarvAlert.Button("Later", isCancel: true),
            ]
        ) { result in
            guard result.buttonIndex == 0 else { return }
            stores.filter(\.store.loadFailed).forEach { $0.store.reload() }
            checkAndPrompt()
        }
    }
}
