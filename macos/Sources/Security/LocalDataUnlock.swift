import AppKit

/// A store whose encrypted file can fail to load (e.g. Keychain access to the
/// encryption key was denied) and can try again.
protocol EncryptedReloadable: AnyObject {
    var loadFailed: Bool { get }
    func reload()
}

/// When saved data can't be unlocked at launch, tell the user why instead of
/// silently showing empty lists, and offer what can actually fix that cause.
/// Nothing is overwritten while a file is locked: `EncryptedStore.write`
/// refuses to write any file that failed to load.
enum LocalDataUnlock {
    private static var stores: [(name: String, store: EncryptedReloadable)] {
        [
            ("hosts", SavedHostsStore.shared),
            ("snippets", SnippetsStore.shared),
            ("saved sessions", SavedSessionsStore.shared),
            ("port forwards", PortForwardStore.shared),
            ("scratchpad", ScratchpadStore.shared),
            ("AI settings", AIConfigStore.shared),
            ("pinned commands", PinnedHistoryStore.shared),
            ("host history", HostUsageStore.shared),
        ]
    }

    /// What a button in the alert does.
    enum Action: Equatable {
        case retry
        case unlockAndRetry
        case useMasterPassword
        case checkForUpdates
        case restoreFromSync
        case startFresh
        case later

        var title: String {
            switch self {
            case .retry, .unlockAndRetry: return "Retry"
            case .useMasterPassword: return "Use Master Password"
            case .checkForUpdates: return "Check for Updates"
            case .restoreFromSync: return "Restore from Sync"
            case .startFresh: return "Start Fresh"
            case .later: return "Later"
            }
        }
    }

    // MARK: Pure

    /// Names of the stores that failed, in display order.
    static func lockedNames(_ entries: [(name: String, failed: Bool)]) -> [String] {
        entries.filter(\.failed).map(\.name)
    }

    /// The alert's buttons, default first and `later` (cancel) last.
    static func actions(for remedy: LocalDataRemedy, canSync: Bool, hasBackup: Bool) -> [Action] {
        switch remedy {
        case .unlockKeychain: return [.unlockAndRetry, .later]
        case .allowAccess, .retry: return [.retry, .later]
        case .update: return [.checkForUpdates, .later]
        case .unrecoverable:
            return (hasBackup ? [.useMasterPassword] : []) + (canSync ? [.restoreFromSync] : []) + [.startFresh, .later]
        }
    }

    static func title(for remedy: LocalDataRemedy) -> String {
        switch remedy {
        case .update: return "Saved Data Needs a Newer Version"
        case .unrecoverable: return "Saved Data Can't Be Opened on This Mac"
        case .unlockKeychain, .allowAccess, .retry: return "Couldn't Unlock Your Saved Data"
        }
    }

    static func message(for names: [String], remedy: LocalDataRemedy, canSync: Bool,
                        hasBackup: Bool = false) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        let untouched = "Your data is still on disk and hasn't been changed."
        switch remedy {
        case .unlockKeychain:
            return "Sarv Terminal couldn't read the key that unlocks your saved \(list) because the Keychain is locked.\n\n"
                + "\(untouched) Choose Retry and enter your Mac login password when macOS asks to unlock the Keychain."
        case .allowAccess:
            return "Sarv Terminal couldn't read the key that unlocks your saved \(list) because Keychain access was denied.\n\n"
                + "\(untouched) Choose Retry and click Always Allow when macOS asks."
        case .retry:
            return "Sarv Terminal couldn't load your saved \(list).\n\n\(untouched) Choose Retry to try again."
        case .update:
            return "Your saved \(list) were saved by a newer version of Sarv Terminal, which this version can't read.\n\n"
                + "\(untouched) Update Sarv Terminal to open it."
        case .unrecoverable:
            let way: String
            if hasBackup {
                way = "Your master password unlocks a backup of the key and opens everything again."
            } else if canSync {
                way = "Restore from Sync to get your data back, or start fresh. Starting fresh keeps the old files aside, unread."
            } else {
                way = "If you still have the Mac this data came from, turn on Sync there, then turn it on here and restore. "
                    + "Or start fresh: the old files are kept aside, unread."
            }
            return "Your saved \(list) were encrypted with a key this Mac doesn't have. This happens after moving "
                + "to a new Mac, restoring from a backup, resetting the Keychain, or (in versions up to 1.12.0) "
                + "after the Keychain couldn't be read once.\n\nNothing has been deleted. \(way)"
        }
    }

    /// One line per failed file, for support.
    static func details(_ failures: [URL: LocalDataFailure]) -> String {
        failures.map { "\($0.key.lastPathComponent): \($0.value.detail)" }.sorted().joined(separator: "\n")
    }

    /// Files to set aside to start fresh. A key that can't open anything on
    /// this Mac takes every encrypted file with it; otherwise only the files
    /// the working key can't open.
    static func filesToSetAside(_ failures: [URL: LocalDataFailure], allEncrypted: [URL]) -> [URL] {
        if LocalDataRemedy.needsNewKey(Array(failures.values)) { return allEncrypted }
        return failures.filter { $0.value == .decrypt }.map(\.key).sorted { $0.path < $1.path }
    }

    // MARK: Alert

    /// Show the alert if anything is locked.
    @MainActor
    static func checkAndPrompt() {
        let failures = EncryptedStore.lockedFiles
        let names = lockedNames(stores.map { ($0.name, $0.store.loadFailed) })
        guard !names.isEmpty, let remedy = LocalDataRemedy.choose(for: Array(failures.values)) else { return }
        ActivityLog.shared.log(.error, "Saved data couldn't be unlocked", detail: details(failures), success: false)
        let canSync = SyncSettings.shared.canSync
        let hasBackup = LocalKeyBackup.exists
        let actions = actions(for: remedy, canSync: canSync, hasBackup: hasBackup)
        SarvAlert.present(
            title: title(for: remedy),
            message: message(for: names, remedy: remedy, canSync: canSync, hasBackup: hasBackup),
            buttons: actions.enumerated().map { index, action in
                SarvAlert.Button(action.title, isDefault: index == 0,
                                 isDestructive: action == .startFresh, isCancel: action == .later)
            },
            copyableText: details(failures)
        ) { result in
            guard actions.indices.contains(result.buttonIndex) else { return }
            perform(actions[result.buttonIndex], failures: failures)
        }
    }

    @MainActor
    private static func perform(_ action: Action, failures: [URL: LocalDataFailure]) {
        switch action {
        case .retry:
            reloadAll()
            checkAndPrompt()
        case .unlockAndRetry:
            LocalDataCrypto.unlockKeychain()
            reloadAll()
            checkAndPrompt()
        case .useMasterPassword:
            Task { await unlockWithMasterPassword() }
        case .checkForUpdates:
            (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
        case .startFresh:
            startFresh(failures)
        case .restoreFromSync:
            guard startFresh(failures) else { return }
            Task { await restoreFromSync() }
        case .later:
            break
        }
    }

    /// Ask the Keychain again and reload every store.
    @MainActor
    private static func reloadAll() {
        LocalDataCrypto.resetForRetry()
        stores.forEach { $0.store.reload() }
    }

    /// Set the unreadable files (and, if needed, the key) aside, then reload
    /// so the stores start empty and writable. Returns false if a file
    /// couldn't be moved (then nothing else changes).
    @MainActor @discardableResult
    private static func startFresh(_ failures: [URL: LocalDataFailure]) -> Bool {
        let stamp = LocalDataFiles.stamp(for: Date())
        let files = filesToSetAside(failures, allEncrypted: LocalDataFiles.encryptedFiles(in: AppPaths.configDir))
        let stuck = LocalDataFiles.setAside(files, stamp: stamp)
        guard stuck.isEmpty else {
            SarvAlert.present(
                title: "Couldn't Start Fresh",
                message: "These files couldn't be moved aside, so nothing was changed.",
                buttons: [SarvAlert.Button("OK", isDefault: true)],
                copyableText: stuck.map(\.path).joined(separator: "\n"))
            return false
        }
        if LocalDataRemedy.needsNewKey(Array(failures.values)) { LocalDataCrypto.retireKey(stamp: stamp) }
        ActivityLog.shared.log(.info, "Started fresh", detail: "Set aside: "
            + files.map(\.lastPathComponent).joined(separator: ", "))
        EncryptedStore.clearFailures()
        reloadAll()
        return true
    }

    /// Try the saved master password first (no prompt), then ask for it.
    private static func unlockWithMasterPassword() async {
        if let saved = try? SyncKeychain.retrieveMasterPassword(),
           case .recovered = await recover(password: saved) {
            await finishRecovery()
            return
        }
        await askForMasterPassword(retrying: false)
    }

    private static func askForMasterPassword(retrying: Bool) async {
        let result = await SarvAlert.present(
            title: retrying ? "Wrong Master Password" : "Enter Your Master Password",
            message: (retrying ? "That password doesn't open the key backup. " : "")
                + "Enter the Sync master password that was set on this Mac to open your saved data again.",
            buttons: [SarvAlert.Button("Unlock", isDefault: true), SarvAlert.Button("Cancel", isCancel: true)],
            inputInitial: "",
            inputSecure: true)
        guard result.buttonIndex == 0 else {
            await MainActor.run { checkAndPrompt() }
            return
        }
        switch await recover(password: result.inputText) {
        case .recovered:
            await finishRecovery()
        case .wrongPassword:
            await askForMasterPassword(retrying: true)
        case .noBackup, .noMatchingKey, .saveFailed:
            _ = await SarvAlert.present(
                title: "Couldn't Open Your Saved Data",
                message: "The key backup doesn't hold the key this data was saved with. It was probably replaced "
                    + "before the backup existed. Restore from Sync or start fresh instead.",
                buttons: [SarvAlert.Button("OK", isDefault: true)])
            await MainActor.run { checkAndPrompt() }
        }
    }

    private static func recover(password: String) async -> LocalDataRecovery.Outcome {
        await Task.detached(priority: .userInitiated) { LocalDataRecovery.recover(password: password) }.value
    }

    /// Reload with the restored key; anything still locked shows the alert again.
    private static func finishRecovery() async {
        await MainActor.run {
            reloadAll()
            if EncryptedStore.hasLockedData {
                checkAndPrompt()
            } else {
                SarvAlert.present(title: "Your Data Is Back",
                                  message: "Your saved data was unlocked with your master password.",
                                  buttons: [SarvAlert.Button("OK", isDefault: true)])
            }
        }
    }

    private static func restoreFromSync() async {
        do {
            try await SyncCoordinator.shared.pullLatest()
            let count = await MainActor.run { SavedHostsStore.shared.hosts.count }
            _ = await SarvAlert.present(
                title: "Restored from Sync",
                message: "Your data was restored from Sync (\(count) hosts).",
                buttons: [SarvAlert.Button("OK", isDefault: true)])
        } catch {
            let choice = await SarvAlert.present(
                title: "Couldn't Restore from Sync",
                message: "\(error.localizedDescription)\n\nOpen Sync settings to enter your sync password or pick a saved version.",
                buttons: [SarvAlert.Button("Open Sync Settings", isDefault: true),
                          SarvAlert.Button("Later", isCancel: true)])
            guard choice.buttonIndex == 0 else { return }
            await MainActor.run { SettingsController.shared.show(section: .sync) }
        }
    }
}
