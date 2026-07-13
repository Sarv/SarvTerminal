import SwiftUI
import AppKit

/// Settings → Sync. Encrypted backup/restore of config, keybinds, and hosts to
/// a GitHub private repo or a synced folder. Everything below the master enable
/// toggle is disabled + dimmed until sync is turned on.
struct SyncSectionView: View {
    @ObservedObject private var settings = SyncSettings.shared

    @State private var masterPassword = ""
    @State private var masterPasswordConfirm = ""
    @State private var patField = ""
    @State private var busy = false
    @State private var message: Message?

    // Draft provider config — edited by the form, committed to `settings` only
    // on Save. This is what makes "peeking" at another provider non-destructive:
    // switching the picker or choosing a folder never touches the active sync.
    @State private var draftProvider: SyncProviderKind = .github
    @State private var draftGithubURL = ""
    @State private var draftFolderBookmark: Data?
    @State private var draftFolderPath = ""

    private enum Message: Equatable {
        case success(String)
        case error(String)
    }

    /// Load the draft from the applied config (on appear / after save).
    private func loadDraft() {
        draftProvider = settings.provider
        draftGithubURL = settings.githubURL
        draftFolderBookmark = settings.folderBookmark
        draftFolderPath = settings.folderPath
        patField = ""
    }

    /// True when the remote holds a version this device hasn't pulled yet (e.g. a
    /// fresh machine that just configured sync). The user must Pull first, so we
    /// disable "Sync ↑" to stop stale/blank local state from overwriting the
    /// newer backup.
    private var mustPullFirst: Bool { settings.remoteIsNewer }

    /// True when the draft differs from the applied config (Save will change something).
    private var hasUnsavedChanges: Bool {
        draftProvider != settings.provider
            || draftGithubURL != settings.githubURL
            || draftFolderBookmark != settings.folderBookmark
            || !patField.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            enableCard

            Group {
                providerCard
                if draftProvider == .folder { historyCard }
                encryptionCard
                statusCard
                actionsBar
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.45)
        }
        .onAppear {
            loadDraft()
            Task { try? await SyncEngine.checkRemote() }
        }
        .onChange(of: settings.enabled) { isOn in
            // Turning sync on (when already saved/configured) kicks an initial push.
            if isOn, settings.isConfigured { SyncCoordinator.shared.scheduleAutoPush() }
        }
    }

    // MARK: - Enable

    private var enableCard: some View {
        SettingsCard(title: "Sync") {
            row("Settings Sync") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable encrypted sync", isOn: $settings.enabled)
                        .toggleStyle(.switch)
                    Text("Back up your terminal customization, keybinds, and saved hosts — encrypted with a master password — to GitHub or a synced folder.")
                        .font(.caption).foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lock.display")
                        Text("Secure Keyboard Entry (in the app menu) is a per-machine security setting and is **not** synced.")
                    }
                    .font(.caption).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Version history (folder provider)

    private var historyCard: some View {
        SettingsCard(title: "Version History") {
            row("Keep history") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Save a snapshot on every sync", isOn: $settings.historyEnabled)
                        .toggleStyle(.checkbox)
                    Text("Keeps recoverable versions in a `history/` folder so you can roll back. On by default — all versions are kept.")
                        .font(.caption).foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if settings.historyEnabled {
                divider
                row("Versions to keep") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(settings.historyKeepCount == 0 ? "Unlimited" : "\(settings.historyKeepCount)")
                                .monospacedDigit()
                                .frame(minWidth: 64, alignment: .leading)
                            Stepper("", value: $settings.historyKeepCount, in: 0...200)
                                .labelsHidden().fixedSize()
                        }
                        Text(settings.historyKeepCount == 0
                             ? "0 = keep every version (uses more space over time)."
                             : "Oldest snapshots are removed automatically.")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: - Provider

    private var providerCard: some View {
        SettingsCard(title: "Where to store") {
            row("Provider") {
                Picker("", selection: $draftProvider) {
                    ForEach(SyncProviderKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 260)
            }
            divider
            switch draftProvider {
            case .github:
                row("Repository URL") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("https://github.com/owner/repo", text: $draftGithubURL)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        Text("Must be a private repository — public repos are rejected.")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
                divider
                row("Access token") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(SyncKeychain.hasPAT() ? "•••••••• (saved — type to replace)" : "ghp_… personal access token",
                                    text: $patField)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        Text("Needs `contents` write permission. Stored in your Keychain.")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            case .folder:
                row("Folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(draftFolderPath.isEmpty ? "No folder chosen" : draftFolderPath)
                                .font(.callout)
                                .foregroundStyle(draftFolderPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }
                                .controlSize(.small)
                        }
                        Text("Pick a folder your system already syncs (iCloud Drive, Dropbox, Google Drive, …).")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: - Encryption / master password

    private var encryptionCard: some View {
        SettingsCard(title: "Encryption") {
            if SyncKeychain.hasMasterPassword() {
                row("Master password") {
                    HStack(spacing: 8) {
                        Label("Set — stored in Keychain", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green).font(.callout)
                        Spacer()
                        Button("Change…") { SyncKeychain.deleteMasterPassword(); bump() }
                            .controlSize(.small)
                    }
                }
            } else {
                row("Master password") {
                    SecureField("Choose a strong password", text: $masterPassword)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                }
                divider
                row("Confirm") {
                    HStack(spacing: 8) {
                        SecureField("Re-enter password", text: $masterPasswordConfirm)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        Button("Set") { setMasterPassword() }
                            .controlSize(.small)
                            .disabled(masterPassword.isEmpty || masterPassword != masterPasswordConfirm)
                    }
                }
            }
            divider
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("This encryption is one-way. If you forget your master password there is **no way** to recover your synced data. It is stored only on this device (Touch ID / passcode) and is never uploaded.")
                    .font(.caption).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        SettingsCard(title: "Status") {
            row("State") {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.callout)
                }
            }
            if case .remoteNewer = settings.status {
                divider
                row("Update available") {
                    HStack(spacing: 8) {
                        Text("A newer version is in the remote.").font(.callout).foregroundStyle(.secondaryText)
                        Button("Pull now") { run("Pulled", onSuccess: promptRestartAfterPull) { try await SyncEngine.pull(masterPassword: $0) } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch settings.status {
        case .idle: return .green
        case .syncing: return .blue
        case .remoteNewer: return .orange
        case .error: return .red
        case .disabled: return .secondary
        }
    }

    private var statusText: String {
        switch settings.status {
        case .disabled: return settings.enabled ? "Not configured yet" : "Disabled"
        case .syncing: return "Syncing…"
        case .error(let e): return e
        case .remoteNewer: return "Remote is newer — pull to update"
        case .idle:
            if let d = settings.lastSyncDate {
                return "Up to date · v\(settings.lastSyncedVersion) · \(d.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Ready — nothing synced yet"
        }
    }

    // MARK: - Actions

    private var actionsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                switch message {
                case .success(let s):
                    Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                case .error(let e):
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hasUnsavedChanges {
                Label("Unsaved changes — press Save to apply.", systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button("Test Connection") {
                    runNoPassword("Connection OK") { try await buildDraftProvider().testConnection() }
                }
                if busy { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button("Pull") { run("Pulled", onSuccess: promptRestartAfterPull) { try await SyncEngine.pull(masterPassword: $0) } }
                Button("Sync ↑") { run("Synced") { _ = try await SyncEngine.push(masterPassword: $0, force: true) } }
                    .disabled(mustPullFirst)
                    .help(mustPullFirst
                          ? "The remote has newer data this device hasn't pulled yet. Press Pull first, then you can sync."
                          : "Force-upload this device's settings, overwriting the remote.")
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
            .controlSize(.large)

            Label("Auto-syncs on every change, and pulls on launch + hourly. Use these buttons for the first sync or to force one.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Operations

    private func setMasterPassword() {
        do {
            try SyncKeychain.storeMasterPassword(masterPassword)
            // Cache for the session so auto-sync doesn't re-prompt.
            SyncCoordinator.shared.cacheMasterPassword(masterPassword)
            masterPassword = ""; masterPasswordConfirm = ""
            message = .success("Master password set")
            bump()
            if settings.isConfigured { SyncCoordinator.shared.scheduleAutoPush() }
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Draft only — committed to the active config on Save.
            draftFolderBookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                       includingResourceValuesForKeys: nil, relativeTo: nil)
            draftFolderPath = url.path
            message = .success("Folder selected — press Save to apply")
        } catch {
            message = .error("Couldn't bookmark that folder: \(error.localizedDescription)")
        }
    }

    /// Build a provider from the DRAFT form values (not the applied config) so
    /// Test/Save validate what the user is about to commit.
    private func buildDraftProvider() throws -> SyncProvider {
        switch draftProvider {
        case .github:
            guard let comps = SyncSettings.parseGitHubURL(draftGithubURL) else {
                throw SyncProviderError(message: "Enter a valid GitHub repository URL.")
            }
            let token = patField.isEmpty ? SyncKeychain.retrievePAT() : patField
            guard let token, !token.isEmpty else {
                throw SyncProviderError(message: "Enter a personal access token.")
            }
            return GitHubSyncProvider(owner: comps.owner, repo: comps.repo, token: token)
        case .folder:
            guard let bm = draftFolderBookmark else {
                throw SyncProviderError(message: "Choose a folder first.")
            }
            return FolderSyncProvider(bookmark: bm,
                                      writeHistory: settings.historyEnabled,
                                      historyLimit: settings.historyKeepCount == 0 ? nil : settings.historyKeepCount)
        }
    }

    /// Save = commit the draft to the active config. We validate the draft
    /// destination first, and only commit on success — so the active sync is
    /// never disturbed by an invalid or merely-previewed config.
    private func save() {
        busy = true; message = nil
        Task {
            do {
                let provider = try buildDraftProvider()
                try await provider.testConnection()
                await MainActor.run {
                    if draftProvider == .github, !patField.isEmpty {
                        try? SyncKeychain.storePAT(patField)
                        patField = ""
                    }
                    settings.provider = draftProvider
                    settings.githubURL = draftGithubURL
                    settings.folderBookmark = draftFolderBookmark
                    settings.folderPath = draftFolderPath
                    message = .success("Saved")
                    bump()
                }
                // Learn the remote's version now so "Sync ↑" is disabled right
                // away if the remote already holds data we haven't pulled (a
                // fresh machine must Pull first).
                try? await SyncEngine.checkRemote()
                if settings.isConfigured { SyncCoordinator.shared.scheduleAutoPush() }
            } catch {
                await MainActor.run { message = .error(error.localizedDescription) }
            }
            await MainActor.run { busy = false }
        }
    }

    /// Run an op that needs the master password (fetched from Keychain via
    /// biometric prompt off the main thread).
    private func run(_ successLabel: String,
                     onSuccess: (@MainActor () -> Void)? = nil,
                     _ op: @escaping (String) async throws -> Void) {
        busy = true; message = nil; settings.isSyncing = true
        Task {
            do {
                let pw = try await Task.detached(priority: .userInitiated) {
                    try SyncKeychain.retrieveMasterPassword(prompt: "Unlock sync encryption")
                }.value
                SyncCoordinator.shared.cacheMasterPassword(pw)
                try await op(pw)
                await MainActor.run { message = .success(successLabel); onSuccess?() }
            } catch {
                await MainActor.run { message = .error(error.localizedDescription) }
            }
            await MainActor.run { busy = false; settings.isSyncing = false }
        }
    }

    /// After a manual pull, offer to relaunch. Most pulled settings apply live,
    /// but some prefs are only read at launch (font weight, notifications,
    /// hosts-UI, session restore), so a restart is recommended to fully reflect
    /// everything that changed.
    @MainActor
    private func promptRestartAfterPull() {
        SarvAlert.present(
            title: "Sync Complete",
            message: "Your settings were pulled from \(settings.provider.label).\n\nFor all changes to fully take effect, restarting SarvTerminal is recommended.",
            buttons: [
                SarvAlert.Button("Restart Now", isDefault: true),
                SarvAlert.Button("Later", isCancel: true),
            ]
        ) { result in
            if result.buttonIndex == 0 { AppRelaunch.now() }
        }
    }

    /// Run an op that doesn't need the master password (Test).
    private func runNoPassword(_ successLabel: String, _ op: @escaping () async throws -> Void) {
        busy = true; message = nil
        Task {
            do { try await op(); await MainActor.run { message = .success(successLabel) } }
            catch { await MainActor.run { message = .error(error.localizedDescription) } }
            await MainActor.run { busy = false }
        }
    }

    /// Force a view refresh after Keychain state changes (which SwiftUI can't observe).
    private func bump() { settings.objectWillChange.send() }

    // MARK: - Layout helpers

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        settingsRow(label, alignment: .top, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
