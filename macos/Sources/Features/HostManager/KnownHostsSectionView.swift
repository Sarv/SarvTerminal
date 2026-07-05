import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Vaults → Known Hosts: browse, search, import into, and prune
/// `~/.ssh/known_hosts`. Uses the shared `VaultsToolbar`.
struct KnownHostsSectionView: View {
    @ObservedObject private var store = KnownHostsStore.shared
    @State private var search = ""
    @State private var pendingDelete: KnownHostEntry?

    private var filtered: [KnownHostEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.hostDisplay.lowercased().contains(q)
                || $0.keyType.lowercased().contains(q)
                || $0.fingerprint.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VaultsToolbar(
                actions: [
                    .init(title: "Import", icon: "square.and.arrow.down", help: "Merge entries from another known_hosts file") { importFile() },
                    .init(title: "Refresh", icon: "arrow.clockwise", help: "Reload from disk") { store.reload() },
                ])
            Divider()

            if store.entries.isEmpty {
                VaultsEmptyState(
                    icon: "checkmark.shield",
                    title: "No known hosts",
                    subtitle: "SSH host keys you trust are saved in ~/.ssh/known_hosts and will appear here.")
            } else {
                searchBar
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.reload() }
        // Centered-logo SarvAlert — same delete semantics as everywhere else.
        .onChange(of: pendingDelete) { entry in
            guard let entry else { return }
            SarvAlert.present(
                title: "Remove this host key?",
                message: "Removes \(entry.hostDisplay) from ~/.ssh/known_hosts. SSH will re-verify it on the next connection.",
                buttons: [
                    .init("Remove", isDefault: true, isDestructive: true),
                    .init("Cancel", isCancel: true),
                ]) { result in
                if result.buttonIndex == 0 { store.delete(entry) }
            }
            pendingDelete = nil
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts, key type, or fingerprint", text: $search).textFieldStyle(.plain)
            Spacer()
            Text("\(filtered.count) of \(store.entries.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                    KnownHostRow(entry: entry) { pendingDelete = entry }
                    Divider().padding(.leading, 52)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a known_hosts file to merge."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.importFrom(url)
    }
}

private struct KnownHostRow: View {
    let entry: KnownHostEntry
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.hostDisplay)
                    .font(.callout)
                    .foregroundStyle(entry.isHashed ? .secondary : .primary)
                Text("\(entry.keyType)  ·  \(entry.fingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Remove from known_hosts")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy fingerprint") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.fingerprint, forType: .string)
            }
            Button("Remove from known_hosts", role: .destructive, action: onDelete)
        }
    }
}
