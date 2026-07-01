import SwiftUI
import AppKit

/// Vaults → Saved Sessions: named snapshots of a tab's split layout. Reopen one
/// to recreate the exact arrangement — local panes respawn at their directory,
/// SSH panes reconnect. Sessions are created from a tab's right-click menu
/// ("Save Session…"); this view lists them and connects / renames / deletes.
struct SavedSessionsSectionView: View {
    @ObservedObject private var store = SavedSessionsStore.shared
    @State private var search = ""
    @State private var renaming: SavedSession?
    @State private var renameText = ""

    private var filtered: [SavedSession] {
        SearchMatcher.filter(store.sessions, query: search) { [$0.name] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.sessions.isEmpty {
                VaultsEmptyState(
                    icon: "rectangle.split.2x2",
                    title: "No saved sessions",
                    subtitle: "Right-click a terminal tab and choose “Save Session…” to capture its split layout. Reopen it any time — local panes return to their directory and SSH panes reconnect.")
            } else {
                searchBar
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Rename Session",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Session name", text: $renameText)
            Button("Rename") {
                if let session = renaming { store.rename(session, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Saved Sessions").font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sessions", text: $search).textFieldStyle(.plain)
            Spacer()
            Text("\(filtered.count) of \(store.sessions.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { session in
                    SavedSessionRow(
                        session: session,
                        onConnect: { VaultsTabsModel.shared.openSavedSession(session) },
                        onRename: { renameText = session.name; renaming = session },
                        onColor: { store.setColor(session, colorID: $0) },
                        onDelete: {
                            if DeleteConfirmation.confirm(
                                session.name,
                                detail: "This removes the saved session. Your open tabs aren't affected.") {
                                store.delete(session)
                            }
                        })
                    Divider().padding(.leading, 52)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SavedSessionRow: View {
    let session: SavedSession
    let onConnect: () -> Void
    let onRename: () -> Void
    let onColor: (String?) -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var showColor = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var savedText: String {
        "Saved " + Self.relativeFormatter.localizedString(for: session.createdAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.sshCount > 0 ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
                .foregroundStyle(session.colorTint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(session.colorTint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.callout).lineLimit(1)
                Text("\(session.summary) · \(savedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if hovering {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete session")
            }
            Button(action: onConnect) {
                Image(systemName: "play.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("Open session")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onConnect() }
        .contextMenu {
            Button("Connect", action: onConnect)
            Button("Rename…", action: onRename)
            Button("Session Color…") { showColor = true }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .popover(isPresented: $showColor, arrowEdge: .trailing) {
            TabColorPicker(
                selected: VaultsTabsModel.tabColorOptions.first { $0.id == session.colorID }?.color
            ) { color in
                onColor(VaultsTabsModel.tabColorOptions.first { $0.color == color }?.id)
                showColor = false
            }
        }
    }
}

private extension SavedSession {
    /// Tint used for the row icon — the tab's saved color, or a neutral accent.
    var colorTint: Color {
        guard let colorID,
              let option = VaultsTabsModel.tabColorOptions.first(where: { $0.id == colorID })
        else { return .accentColor }
        return option.color
    }
}
