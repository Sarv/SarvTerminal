import SwiftUI
import AppKit

/// Vaults → Keychain: manage the SSH keys in `~/.ssh`. Generate new keys, copy
/// the public half to paste into a server's `authorized_keys` (or GitHub), and
/// delete keys you no longer need. Uses the shared `VaultsToolbar`.
struct KeychainSectionView: View {
    @ObservedObject private var manager = SSHKeyManager.shared
    @State private var search = ""
    @State private var showGenerator = false
    @State private var pendingDelete: SSHKey?
    @State private var toast: String?

    private var filtered: [SSHKey] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return manager.keys }
        return manager.keys.filter {
            $0.name.lowercased().contains(q)
                || $0.comment.lowercased().contains(q)
                || $0.type.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VaultsToolbar(
                primary: .init(title: "Generate key", icon: "plus") { showGenerator = true },
                trailing: [.init(icon: "arrow.clockwise", help: "Refresh") { reload() }])
            Divider()

            if manager.keys.isEmpty {
                if manager.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VaultsEmptyState(
                        icon: "key",
                        title: "No SSH keys",
                        subtitle: "Generate an SSH key to authenticate to your servers without a password. Keys live in ~/.ssh.")
                }
            } else {
                searchBar
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { toastView }
        .task { if manager.keys.isEmpty { await manager.refresh() } }
        .sheet(isPresented: $showGenerator) {
            KeyGeneratorView(manager: manager) { showToast("Key generated") }
        }
        // Shared centered-logo confirm — one delete semantic everywhere.
        .onChange(of: pendingDelete?.name) { _ in
            guard let key = pendingDelete else { return }
            DeleteConfirmation.confirm(
                key.name,
                detail: "This permanently removes the private and public key files from ~/.ssh. This can't be undone.") { confirmed in
                if confirmed { manager.delete(key); showToast("Deleted") }
            }
            pendingDelete = nil
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText)
            TextField("Search keys", text: $search).textFieldStyle(.plain)
            Spacer()
            Text("\(filtered.count) of \(manager.keys.count)").font(.caption).foregroundStyle(.secondaryText)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { key in
                    KeyRow(
                        key: key,
                        onCopyPublic: { copyPublic(key) },
                        onCopyPath: { copyPath(key) },
                        onReveal: { reveal(key) },
                        onDelete: { pendingDelete = key })
                    Divider().padding(.leading, 52)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.bottom, 20)
                .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func reload() { Task { await manager.refresh() } }

    private func copyPublic(_ key: SSHKey) {
        guard let text = manager.publicKeyText(key) else { showToast("No public key file"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Public key copied")
    }

    private func copyPath(_ key: SSHKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.privatePath, forType: .string)
        showToast("Path copied")
    }

    private func reveal(_ key: SSHKey) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.privatePath)])
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

// MARK: - Row

private struct KeyRow: View {
    let key: SSHKey
    let onCopyPublic: () -> Void
    let onCopyPath: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name).font(.callout).lineLimit(1)
                    badge("\(key.type) · \(key.bits)")
                    if !key.hasPublicKey { badge("no .pub", tint: .red) }
                }
                Text(key.comment.isEmpty ? key.fingerprint : "\(key.comment) · \(key.fingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hovering {
                Button(action: onReveal) { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Delete key")
            }
            Button(action: onCopyPublic) {
                Image(systemName: "doc.on.doc").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Copy public key")
            .disabled(!key.hasPublicKey)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy public key", action: onCopyPublic).disabled(!key.hasPublicKey)
            Button("Copy private key path", action: onCopyPath)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func badge(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}

// MARK: - Generator sheet

private struct KeyGeneratorView: View {
    @ObservedObject var manager: SSHKeyManager
    let onGenerated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = "id_ed25519"
    @State private var type: SSHKeyType = .ed25519
    @State private var comment = NSUserName() + "@" + (Host.current().localizedName ?? "mac")
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false

    private var passphraseMismatch: Bool { !passphrase.isEmpty && passphrase != confirm }
    private var canGenerate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !passphraseMismatch && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate SSH Key").font(.title3.weight(.semibold))

            field("Name", help: "Saved to ~/.ssh/\(name.isEmpty ? "name" : name)") {
                TextField("id_ed25519", text: $name).textFieldStyle(.roundedBorder)
            }

            field("Type") {
                Picker("", selection: $type) {
                    ForEach(SSHKeyType.allCases) { Text($0.display).tag($0) }
                }
                .labelsHidden()
                .onChange(of: type) { newValue in
                    // Keep the default name in step with the type when untouched.
                    if name == "id_ed25519" || name == "id_ecdsa" || name == "id_rsa" {
                        name = "id_\(newValue.rawValue)"
                    }
                }
            }

            field("Comment", help: "Helps you recognize the key later (e.g. on GitHub).") {
                TextField("user@machine", text: $comment).textFieldStyle(.roundedBorder)
            }

            field("Passphrase (optional)", help: "Encrypts the private key on disk. Leave blank for none.") {
                VStack(spacing: 6) {
                    SecureField("Passphrase", text: $passphrase).textFieldStyle(.roundedBorder)
                    SecureField("Confirm passphrase", text: $confirm).textFieldStyle(.roundedBorder)
                }
            }
            if passphraseMismatch {
                Label("Passphrases don't match.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = manager.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Generating…" : "Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field<Content: View>(_ label: String, help: String? = nil,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondaryText)
            content()
            if let help { Text(help).font(.caption2).foregroundStyle(.tertiaryText) }
        }
    }

    private func generate() {
        working = true
        Task {
            let ok = await manager.generate(name: name, type: type, passphrase: passphrase, comment: comment)
            working = false
            if ok { onGenerated(); dismiss() }
        }
    }
}
