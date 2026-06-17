import SwiftUI
import AppKit

/// Full SSH host editor — lives **inside** the Hosts section (never a sheet
/// or popup-over-popup). Layout is Termius-inspired: rounded grouped cards
/// containing pill-style rows.
struct HostEditorView: View {
    @Binding var draft: SavedHost
    let isNew: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onConnect: (() -> Void)?

    @ObservedObject private var store = SavedHostsStore.shared

    // Inline expansion / always-shown states for the more advanced rows.
    @State private var showLocalForwards = false
    @State private var showRemoteForwards = false
    @State private var showInitialCommand = false
    @State private var showNote = false

    // Local mirrors for fields that need text⇆list conversion.
    @State private var localFwdField = ""
    @State private var remoteFwdField = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    addressCard
                    generalCard
                    credentialsCard
                    optionsCard
                    forwardingCard
                    appearanceCard
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Hosts")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
            Text(isNew ? "New host" : "Edit host")
                .font(.headline)
            Spacer()

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete host")
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
                              text: $draft.hostname)
            }
        }
    }

    // MARK: - General

    private var generalCard: some View {
        EditorCard("General") {
            EditorTextRow(icon: "tag", placeholder: "Label", text: $draft.label)
            ParentGroupPicker(groupID: $draft.groupID, placeholder: "Parent Group")
            TagsField(tags: $draft.tags, allKnownTags: knownTags)
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
            }
        }
    }

    // MARK: - Credentials

    private var credentialsCard: some View {
        EditorCard("Credentials") {
            HStack(spacing: 10) {
                Text("SSH on")
                    .foregroundStyle(.secondary)
                EditorPortField(value: $draft.port)
                    .frame(width: 110)
                Text("port")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 2)

            EditorTextRow(icon: "person",
                          placeholder: "Username",
                          text: $draft.username)

            EditorPickerRow(
                icon: "key",
                title: "Auth method",
                selection: $draft.authMethod,
                options: SavedHost.AuthMethod.allCases.map { ($0, $0.display) }
            )

            // Auth-input area — always present; renders the right control
            // for the currently selected method.
            authInputForCurrentMethod

            EditorBoolRow(icon: "arrow.triangle.2.circlepath",
                          title: "Agent forwarding (-A)",
                          isOn: $draft.forwardAgent)
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
                            text: $draft.password)
            if draft.password.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                    Text("A password is required for Password auth. To be prompted at connect time instead, choose “Ask”.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.leading, 4)
            }
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Text("Stored in plaintext at ~/.config/sarvterminal/hosts.json. SSH keys are recommended.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
        case .publicKey:
            HStack(spacing: 6) {
                EditorTextRow(icon: "doc.text",
                              placeholder: "~/.ssh/id_ed25519",
                              text: $draft.identityFile,
                              monospaced: true)
                Button("Browse…") { pickIdentityFile() }
                    .controlSize(.small)
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

    // MARK: - Options

    private var optionsCard: some View {
        EditorCard("Connection options") {
            EditorPickerRow(
                icon: "checkmark.shield",
                title: "Strict host key checking",
                selection: $draft.strictHostKeyChecking,
                options: SavedHost.HostKeyChecking.allCases.map { ($0, $0.display) }
            )
            EditorIntRow(icon: "clock",
                         placeholder: "Connect timeout (s)  0 = default",
                         value: $draft.connectTimeoutSeconds)
            EditorIntRow(icon: "heart.text.square",
                         placeholder: "Keep-alive interval (s)  0 = off",
                         value: $draft.serverAliveIntervalSeconds)
            EditorTextRow(icon: "arrow.triangle.branch",
                          placeholder: "Proxy jump  e.g. user@bastion",
                          text: $draft.proxyJump)
            EditorBoolRow(icon: "arrow.down.right.and.arrow.up.left",
                          title: "Compression (-C)",
                          isOn: $draft.useCompression)
            EditorBoolRow(icon: "terminal",
                          title: "Force TTY (-t)",
                          isOn: $draft.requestTTY)
        }
    }

    // MARK: - Forwarding

    private var forwardingCard: some View {
        EditorCard("Port forwarding") {
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
                Text("One per line, e.g. 8080:localhost:80")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
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
                Text("One per line, e.g. 9000:localhost:9000")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            EditorIntRow(icon: "network",
                         placeholder: "Dynamic SOCKS port  0 = off",
                         value: $draft.dynamicForwardPort)

            EditorExpandRow(icon: "terminal.fill",
                            title: "Startup command",
                            summary: draft.initialCommand.isEmpty ? "" : "Set",
                            isExpanded: $showInitialCommand) {
                TextEditor(text: $draft.initialCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 180)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                    )
                Text("Runs on the remote shell once the connection is established.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        EditorCard("Appearance") {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Theme")
                Spacer()
                ThemePicker(themeName: $draft.themeName)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            Text("Saved per host. Per-tab theme override is coming in a follow-up — currently the new tab inherits the global theme.")
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
                    onConnect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Connect")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(draft.canSave ? Color.accentColor : Color.accentColor.opacity(0.4))
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!draft.canSave)
            }
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Save", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func syncLocalMirrors() {
        localFwdField = draft.localForwards.joined(separator: "\n")
        remoteFwdField = draft.remoteForwards.joined(separator: "\n")
        if !draft.note.isEmpty             { showNote = true }
        if !draft.initialCommand.isEmpty   { showInitialCommand = true }
        if !draft.localForwards.isEmpty    { showLocalForwards = true }
        if !draft.remoteForwards.isEmpty   { showRemoteForwards = true }
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
        }
    }
}
