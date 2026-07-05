import SwiftUI
import AppKit

/// Full SSH host editor — lives **inside** the Hosts section (never a sheet
/// or popup-over-popup). Layout is Termius-inspired: rounded grouped cards
/// containing pill-style rows.
struct HostEditorView: View {
    @Binding var draft: SavedHost
    let isNew: Bool
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onConnect: (() -> Void)?
    /// Called whenever a field with data commits (blur of text inputs, any
    /// toggle/picker change) so the owner can persist the draft live.
    var onAutosave: (() -> Void)? = nil

    @ObservedObject private var store = SavedHostsStore.shared
    @ObservedObject private var snippetsStore = SnippetsStore.shared

    // Inline expansion / always-shown states for the more advanced rows.
    @State private var showLocalForwards = false
    @State private var showRemoteForwards = false
    @State private var showInitialCommand = false
    @State private var showNote = false
    @State private var showAdvanced = false
    /// The user has focused-and-left the password field (or tried to save) —
    /// only then is an empty password worth flagging.
    @State private var passwordTouched = false
    /// Transient "Saved" footer indicator, flashed on every autosave.
    @State private var showSaved = false
    @State private var savedIndicatorHide: DispatchWorkItem? = nil

    // Local mirrors for fields that need text⇆list conversion.
    @State private var localFwdField = ""
    @State private var remoteFwdField = ""

    // Focus tracking for the free-text editors, so leaving them autosaves.
    @FocusState private var noteFocused: Bool
    @FocusState private var startupFocused: Bool
    @FocusState private var localFwdFocused: Bool
    @FocusState private var remoteFwdFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    addressCard
                    generalCard
                    credentialsCard
                    startupCard
                    appearanceCard
                    advancedCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { syncLocalMirrors() }
        // ONE blanket watcher for every discrete control (toggles, pickers,
        // tags, …): the signature hashes the whole draft with the type-in
        // fields blanked out, so ANY future non-text field autosaves without
        // being registered here. Text fields save on blur instead (autosaveIf).
        .onChange(of: draft.discreteAutosaveSignature) { _ in fireAutosave() }
        .onChange(of: draft.platform) { newValue in
            // Re-selecting "Auto (detect)" clears the cached detection so the
            // next connect re-probes (e.g. after a server was reinstalled).
            if newValue == HostPlatform.auto.rawValue { draft.detectedPlatform = "" }
        }
    }

    /// Blur handler for text inputs: autosave only when the field carries data.
    private func autosaveIf(_ fieldHasData: Bool) {
        if fieldHasData { fireAutosave() }
    }

    /// Run the owner's autosave and flash the "Saved" footer indicator.
    private func fireAutosave() {
        guard let onAutosave else { return }
        onAutosave()
        withAnimation(.easeIn(duration: 0.1)) { showSaved = true }
        savedIndicatorHide?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.4)) { showSaved = false }
        }
        savedIndicatorHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Hosts")
                }
                // Pad + explicit hit shape so the whole "< Hosts" area (not
                // just the glyphs) is clickable.
                .padding(.vertical, 4)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to hosts")

            Spacer()
            Text(isNew ? "New host" : "Edit host")
                .font(.headline)
            Spacer()

            if let onDelete {
                Button(action: onDelete) {
                    if isNew {
                        // New host: the draft may already be autosaved — this
                        // throws it away entirely instead of keeping it.
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.caption)
                            Text("Discard")
                        }
                        .contentShape(Rectangle())
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.plain)
                .help(isNew ? "Discard this draft — nothing is kept" : "Delete host")
                .foregroundStyle(.red)
            } else {
                // keep header symmetric
                Image(systemName: "trash").opacity(0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Address

    private var addressCard: some View {
        EditorCard("Address") {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: 50, height: 50)
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
                EditorTextRow(icon: "network",
                              placeholder: "IP or Hostname",
                              text: $draft.hostname,
                              autoFocus: true,
                              onEditingEnded: { autosaveIf(!draft.hostname.isEmpty) })
                    .help("Server IP address or DNS hostname")
            }
        }
    }

    // MARK: - General

    private var generalCard: some View {
        EditorCard("General") {
            EditorTextRow(icon: "tag", placeholder: "Label", text: $draft.label,
                          onEditingEnded: { autosaveIf(!draft.label.isEmpty) })
                .help("Display name shown in host lists (empty = hostname)")
            ParentGroupPicker(groupID: $draft.groupID, placeholder: "Parent Group")
                .help("Group this host lives in")
            TagsField(tags: $draft.tags, allKnownTags: knownTags)
                .help("Tags for search and filtering")
            EditorExpandRow(icon: "text.alignleft",
                            title: "Description",
                            summary: draft.note.isEmpty ? "" : oneLineSummary(draft.note),
                            isExpanded: $showNote) {
                TextEditor(text: $draft.note)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                    )
                    .focused($noteFocused)
                    .onChange(of: noteFocused) { focused in
                        if !focused { autosaveIf(!draft.note.isEmpty) }
                    }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsCard: some View {
        EditorCard("Credentials") {
            HStack(spacing: 10) {
                Text("SSH on")
                    .foregroundStyle(.secondary)
                EditorPortField(value: $draft.port,
                                onEditingEnded: { autosaveIf(draft.port != 22) })
                    .frame(width: 110)
                    .help("SSH port — 22 unless the server uses a custom one")
                Text("port")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 2)

            EditorTextRow(icon: "person",
                          placeholder: "Username",
                          text: $draft.username,
                          onEditingEnded: { autosaveIf(!draft.username.isEmpty) })
                .help("User to sign in as (empty = your macOS username)")

            EditorPickerRow(
                icon: "key",
                title: "Auth method",
                selection: $draft.authMethod,
                options: SavedHost.AuthMethod.allCases.map { ($0, $0.display) }
            )
            .help("How to authenticate: saved password, key file, ssh-agent, or ask every time")

            // Auth-input area — always present; renders the right control
            // for the currently selected method.
            authInputForCurrentMethod

            EditorBoolRow(icon: "arrow.triangle.2.circlepath",
                          title: "Agent forwarding (-A)",
                          isOn: $draft.forwardAgent)
                .help("Let the remote host use your local ssh-agent for onward connections")
        }
    }

    /// Renders the auth input below the method picker — always visible,
    /// content swaps based on the selected method.
    @ViewBuilder
    private var authInputForCurrentMethod: some View {
        switch draft.authMethod {
        case .password:
            EditorSecureRow(icon: "lock",
                            placeholder: "Password",
                            text: $draft.password,
                            onEditingEnded: {
                                passwordTouched = true
                                autosaveIf(!draft.password.isEmpty)
                            })
                .help("Password used to sign in — stored encrypted on this Mac")
            // Only nag once the user has visited the field and left it empty —
            // never on first open of a fresh editor.
            if passwordTouched, draft.password.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text("A password is required for Password auth. To be prompted at connect time instead, choose “Ask”.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.leading, 4)
            }
        case .publicKey:
            HStack(spacing: 6) {
                EditorTextRow(icon: "doc.text",
                              placeholder: "~/.ssh/id_ed25519",
                              text: $draft.identityFile,
                              monospaced: true,
                              onEditingEnded: { autosaveIf(!draft.identityFile.isEmpty) })
                    .help("Path to the private key file used to sign in")
                Button("Browse…") { pickIdentityFile() }
                    .controlSize(.small)
                    .help("Choose a key file from ~/.ssh")
            }
        case .agent:
            authInfoRow(icon: "key.horizontal",
                        text: "Uses your running ssh-agent. No password or key path needed.")
        case .ask:
            authInfoRow(icon: "questionmark.circle",
                        text: "SSH will prompt for credentials when you connect.")
        }
    }

    private func authInfoRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Startup command

    private var startupCard: some View {
        EditorCard("Startup") {
            EditorExpandRow(icon: "terminal.fill",
                            title: "Startup command",
                            summary: draft.initialCommand.isEmpty ? "" : oneLineSummary(draft.initialCommand),
                            isExpanded: $showInitialCommand) {
                TextEditor(text: $draft.initialCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 180)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                    )
                    .focused($startupFocused)
                    .onChange(of: startupFocused) { focused in
                        if !focused { autosaveIf(!draft.initialCommand.isEmpty) }
                    }
                HStack {
                    Text("Runs on the remote shell once the connection is established.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if !snippetsStore.snippets.isEmpty {
                        Menu {
                            ForEach(snippetsStore.snippets) { snippet in
                                Button(snippet.displayName) { insertSnippet(snippet) }
                            }
                        } label: {
                            Label("Insert snippet", systemImage: "curlybraces")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Append one of your saved snippets to the startup command")
                    }
                }
                .padding(.leading, 4)
            }
            .help("Command to run on the remote shell right after connecting")
        }
    }

    // MARK: - Advanced (connection options + port forwarding)

    private var advancedCard: some View {
        EditorCard {
            EditorExpandRow(icon: "slider.horizontal.3",
                            title: "Advanced",
                            summary: showAdvanced ? "" : "Connection options, port forwarding",
                            isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    EditorSubheading(text: "Connection options")
                    EditorPickerRow(
                        icon: "checkmark.shield",
                        title: "Strict host key checking",
                        selection: $draft.strictHostKeyChecking,
                        options: SavedHost.HostKeyChecking.allCases.map { ($0, $0.display) }
                    )
                    .help("What to do when the server's host key is unknown or has changed")
                    EditorIntRow(icon: "clock",
                                 placeholder: "Connect timeout in seconds",
                                 value: $draft.connectTimeoutSeconds,
                                 onEditingEnded: { autosaveIf(draft.connectTimeoutSeconds != 0) })
                        .help("Give up connecting after this many seconds — empty uses the system default")
                    EditorIntRow(icon: "heart.text.square",
                                 placeholder: "Keep-alive interval in seconds",
                                 value: $draft.serverAliveIntervalSeconds,
                                 onEditingEnded: { autosaveIf(draft.serverAliveIntervalSeconds != 0) })
                        .help("Ping the server every N seconds so idle sessions don't drop — empty turns it off")
                    EditorTextRow(icon: "arrow.triangle.branch",
                                  placeholder: "Proxy jump host, e.g. user@bastion",
                                  text: $draft.proxyJump,
                                  onEditingEnded: { autosaveIf(!draft.proxyJump.isEmpty) })
                        .help("Reach this host through an intermediate jump host (-J)")
                    EditorBoolRow(icon: "arrow.down.right.and.arrow.up.left",
                                  title: "Compression (-C)",
                                  isOn: $draft.useCompression)
                        .help("Compress traffic — helps on slow links, wastes CPU on fast ones")
                    EditorBoolRow(icon: "terminal",
                                  title: "Force TTY (-t)",
                                  isOn: $draft.requestTTY)
                        .help("Force a terminal allocation, e.g. for interactive commands run at startup")

                    EditorSubheading(text: "Port forwarding")
                    EditorExpandRow(icon: "arrow.right.square",
                                    title: "Local forwards",
                                    summary: countSummary(draft.localForwards),
                                    isExpanded: $showLocalForwards) {
                        TextEditor(text: $localFwdField)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 120)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                            )
                            .onChange(of: localFwdField) { _ in
                                draft.localForwards = splitLines(localFwdField)
                            }
                            .focused($localFwdFocused)
                            .onChange(of: localFwdFocused) { focused in
                                if !focused { autosaveIf(!draft.localForwards.isEmpty) }
                            }
                        Text("One per line, e.g. 8080:localhost:80")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                    .help("Expose a remote port on your Mac (-L)")
                    EditorExpandRow(icon: "arrow.left.square",
                                    title: "Remote forwards",
                                    summary: countSummary(draft.remoteForwards),
                                    isExpanded: $showRemoteForwards) {
                        TextEditor(text: $remoteFwdField)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 120)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                            )
                            .onChange(of: remoteFwdField) { _ in
                                draft.remoteForwards = splitLines(remoteFwdField)
                            }
                            .focused($remoteFwdFocused)
                            .onChange(of: remoteFwdFocused) { focused in
                                if !focused { autosaveIf(!draft.remoteForwards.isEmpty) }
                            }
                        Text("One per line, e.g. 9000:localhost:9000")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                    .help("Expose a local port on the remote host (-R)")
                    EditorIntRow(icon: "network",
                                 placeholder: "SOCKS proxy port, e.g. 1080",
                                 value: $draft.dynamicForwardPort,
                                 onEditingEnded: { autosaveIf(draft.dynamicForwardPort != 0) })
                        .help("Start a dynamic SOCKS proxy on this local port (-D) — empty turns it off")
                }
            }
            .help("Less-used options: host key policy, timeouts, proxy jump, port forwarding")
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        EditorCard("Appearance") {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Operating system")
                Spacer()
                Picker("", selection: $draft.platform) {
                    ForEach(HostPlatform.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .help("Sets the host's icon. Auto detects the OS on the first successful key/agent connect.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            HStack(spacing: 10) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Theme")
                Spacer()
                ThemePicker(themeName: $draft.themeName)
                    .frame(maxWidth: 320)
                    .help("Terminal theme used for this host's tabs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            Text("Saved per host — this host's tabs use this theme; other tabs keep the global theme.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let onConnect {
                Button {
                    guard requireValidDraft() else { return }
                    onConnect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Save & Connect")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(draft.canSave ? Color.accentColor : Color.accentColor.opacity(0.4))
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!draft.canConnect)
            }
            // Autosave feedback — flashes on every blur/toggle save so the
            // user knows their edits are already persisted.
            if showSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            Spacer()
            // No explicit Save — every field autosaves on blur/change, so the
            // only actions left are Close and Save & Connect.
            Button("Close", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    /// Gate for Save / Save & Connect: a save attempt with a missing required
    /// password reveals the inline error instead of silently doing nothing.
    private func requireValidDraft() -> Bool {
        guard draft.canSave else {
            passwordTouched = true
            return false
        }
        return true
    }

    private func syncLocalMirrors() {
        localFwdField = draft.localForwards.joined(separator: "\n")
        remoteFwdField = draft.remoteForwards.joined(separator: "\n")
        if !draft.note.isEmpty             { showNote = true }
        if !draft.initialCommand.isEmpty   { showInitialCommand = true }
        if !draft.localForwards.isEmpty    { showLocalForwards = true }
        if !draft.remoteForwards.isEmpty   { showRemoteForwards = true }
        // Open Advanced when any of its values differ from the defaults, so
        // nothing configured is ever hidden behind the collapsed row.
        if draft.strictHostKeyChecking != .ask
            || draft.connectTimeoutSeconds != 0
            || draft.serverAliveIntervalSeconds != 0
            || !draft.proxyJump.isEmpty
            || draft.useCompression
            || draft.requestTTY
            || !draft.localForwards.isEmpty
            || !draft.remoteForwards.isEmpty
            || draft.dynamicForwardPort != 0 {
            showAdvanced = true
        }
    }

    /// Appends a saved snippet's command to the startup command.
    private func insertSnippet(_ snippet: Snippet) {
        if draft.initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.initialCommand = snippet.command
        } else {
            draft.initialCommand += "\n" + snippet.command
        }
        showInitialCommand = true
        autosaveIf(true)
    }

    /// All tags currently used across saved hosts — deduped + alphabetized.
    private var knownTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for h in store.hosts {
            for t in h.tags where !seen.contains(t) {
                seen.insert(t); ordered.append(t)
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func countSummary(_ list: [String]) -> String {
        list.isEmpty ? "" : "\(list.count) entr\(list.count == 1 ? "y" : "ies")"
    }

    private func oneLineSummary(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    private func splitLines(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func pickIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
            autosaveIf(true)
        }
    }
}

private extension SavedHost {
    /// Change signature for every DISCRETE control in the editor (toggles,
    /// pickers, tags, …): the whole host hashed with the type-in fields
    /// blanked out. `onChange(of: discreteAutosaveSignature)` is the single
    /// blanket autosave hook — a future toggle/picker is covered automatically
    /// with no registration. Only a NEW type-in field needs excluding here;
    /// forgetting that fails loud (saves per keystroke), never silent.
    var discreteAutosaveSignature: Int {
        var copy = self
        // Type-in fields — these autosave on BLUR, not per keystroke.
        copy.hostname = ""
        copy.label = ""
        copy.username = ""
        copy.password = ""
        copy.note = ""
        copy.identityFile = ""
        copy.proxyJump = ""
        copy.initialCommand = ""
        copy.localForwards = []
        copy.remoteForwards = []
        copy.port = 0
        copy.connectTimeoutSeconds = 0
        copy.serverAliveIntervalSeconds = 0
        copy.dynamicForwardPort = 0
        // Programmatic/metadata fields — not user controls.
        copy.detectedPlatform = ""
        copy.createdAt = .distantPast
        copy.updatedAt = .distantPast
        return copy.hashValue
    }
}
