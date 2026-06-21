import Foundation
import Combine

extension Notification.Name {
    /// Posted after the Ghostty config file is (re)written by the Settings UI.
    static let sarvConfigDidCommit = Notification.Name("SarvConfigDidCommit")
    /// Posted when the Settings window closes — the commit point at which we
    /// push the whole editing session as a single version (avoids per-change churn).
    static let sarvSettingsClosed = Notification.Name("SarvSettingsClosed")
}

/// Drives automatic sync: pushes (debounced) whenever any synced data changes,
/// pulls on app launch and hourly, and prevents the apply-a-pull → auto-push
/// feedback loop. Holds the master password in memory for the session so
/// auto-pushes don't re-prompt for Touch ID on every change.
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    private var cancellables = Set<AnyCancellable>()
    private var pushWork: DispatchWorkItem?
    private var hourlyTimer: Timer?
    private var cachedMasterPassword: String?

    /// Push serialization (main-actor only): one push at a time; coalesce
    /// changes that arrive mid-push into a single follow-up push.
    private var isPushing = false
    private var pendingPush = false

    /// While true, change notifications do NOT trigger an auto-push. Set while
    /// applying a pulled snapshot (which itself mutates the stores/config).
    private(set) var isApplyingRemote = false

    /// Small debounce so a burst (e.g. importing several hosts, or a
    /// settings-close flush) collapses into one push. Settings no longer push
    /// per-change — they flush on window close — so this stays short.
    private let pushDebounce: TimeInterval = 3
    /// How long to suppress auto-push after beginning to apply a pull — long
    /// enough to absorb the debounced config commit (~150ms) + push debounce.
    private let applySuppression: TimeInterval = 9

    private init() {}

    /// Wire up observers and kick off the launch pull + hourly timer. Call once
    /// at app launch.
    func start() {
        let onChange: () -> Void = { [weak self] in self?.scheduleAutoPush() }

        // Vaults data is deliberate/discrete → push on change (debounced to batch
        // bulk edits like an import).
        SavedHostsStore.shared.objectWillChange.sink { _ in onChange() }.store(in: &cancellables)
        HostGroupsStore.shared.objectWillChange.sink { _ in onChange() }.store(in: &cancellables)
        SnippetsStore.shared.objectWillChange.sink { _ in onChange() }.store(in: &cancellables)
        // Everything edited in the Settings window (config, appearance, keybinds,
        // SFTP prefs) is flushed as ONE version when that window closes — not per
        // change — to avoid version churn from slider/colour fiddling.
        NotificationCenter.default.publisher(for: .sarvSettingsClosed)
            .sink { _ in onChange() }.store(in: &cancellables)

        Task { await pullIfRemoteNewer() }

        // Pull hourly to pick up changes pushed from other machines.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.pullIfRemoteNewer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hourlyTimer = timer
    }

    // MARK: - Master password (session cache)

    /// Remember the master password for the session so auto-sync doesn't prompt
    /// repeatedly. Called by the Settings UI after the user sets/uses it.
    func cacheMasterPassword(_ password: String) { cachedMasterPassword = password }

    private func masterPassword() async throws -> String {
        if let cached = cachedMasterPassword { return cached }
        let pw = try await Task.detached(priority: .userInitiated) {
            try SyncKeychain.retrieveMasterPassword(prompt: "Unlock sync encryption")
        }.value
        cachedMasterPassword = pw
        return pw
    }

    // MARK: - Push

    func scheduleAutoPush() {
        guard SyncSettings.shared.canSync, !isApplyingRemote else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.performPush() } }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pushDebounce, execute: work)
    }

    private func performPush() async {
        // Serialize pushes — overlapping uploads to the same remote cause 409
        // conflicts. If a change arrives while a push is running, remember it and
        // push once more when this one finishes.
        let canStart = await MainActor.run { () -> Bool in
            guard SyncSettings.shared.canSync, !isApplyingRemote else { return false }
            if isPushing { pendingPush = true; return false }
            isPushing = true
            SyncSettings.shared.isSyncing = true
            return true
        }
        guard canStart else { return }

        do {
            let pw = try await masterPassword()
            _ = try await SyncEngine.push(masterPassword: pw)
            await MainActor.run { SyncSettings.shared.lastError = nil }
        } catch {
            // Transient conflicts are handled internally — stay silent and let
            // the next sync resolve them. Only surface genuine errors.
            if !isTransientConflict(error) {
                await MainActor.run {
                    SyncSettings.shared.lastError = error.localizedDescription
                    ActivityLog.shared.log(.error, "Sync failed", detail: error.localizedDescription, success: false)
                }
            }
        }

        let runAgain = await MainActor.run { () -> Bool in
            isPushing = false
            SyncSettings.shared.isSyncing = false
            if pendingPush { pendingPush = false; return true }
            return false
        }
        if runAgain { scheduleAutoPush() }
    }

    // MARK: - Pull

    /// Pull only when the remote manifest is strictly newer than what we last
    /// synced — so we never clobber our own just-pushed state.
    func pullIfRemoteNewer() async {
        guard SyncSettings.shared.canSync else { return }
        await MainActor.run { SyncSettings.shared.isSyncing = true }
        defer { Task { @MainActor in SyncSettings.shared.isSyncing = false } }
        do {
            let remote = try await SyncEngine.checkRemote()
            guard let remote, remote > SyncSettings.shared.lastSyncedVersion else { return }
            let pw = try await masterPassword()
            try await SyncEngine.pull(masterPassword: pw)
        } catch {
            // Launch/interval pulls are best-effort. Stay silent on transient
            // conflicts; surface only genuine errors.
            if !isTransientConflict(error) {
                await MainActor.run {
                    SyncSettings.shared.lastError = error.localizedDescription
                    ActivityLog.shared.log(.error, "Pull failed", detail: error.localizedDescription, success: false)
                }
            }
        }
    }

    /// True for transient sync conflicts we handle internally (not user-facing).
    private func isTransientConflict(_ error: Error) -> Bool {
        (error as? SyncProviderError)?.isConflict ?? false
    }

    // MARK: - Feedback-loop guard

    /// Called by `SyncEngine.pull` right before it mutates local state.
    func beginApplyingRemote() {
        isApplyingRemote = true
        pushWork?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + applySuppression) { [weak self] in
            self?.isApplyingRemote = false
        }
    }
}
