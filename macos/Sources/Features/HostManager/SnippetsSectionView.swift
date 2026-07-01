import SwiftUI
import AppKit

/// Vaults → Snippets: a saved command library. Run a snippet into the focused
/// terminal in one click (or copy it). Uses the shared `VaultsToolbar`.
struct SnippetsSectionView: View {
    @ObservedObject private var store = SnippetsStore.shared
    @ObservedObject private var tabs = VaultsTabsModel.shared
    @State private var search = ""
    @State private var draft: Snippet?
    @State private var isNew = false
    @State private var toast: String?
    @State private var showHistory = false

    private var filtered: [Snippet] {
        SearchMatcher.filter(store.snippets, query: search) { [$0.displayName, $0.command] }
    }

    var body: some View {
        VStack(spacing: 0) {
            VaultsToolbar(
                primary: .init(title: "New snippet", icon: "plus") { startNew() },
                actions: [.init(title: "Shell History", icon: "clock",
                                help: "Save a past command as a snippet") {
                    withAnimation(.easeInOut(duration: 0.18)) { showHistory.toggle() }
                }])
            Divider()

            if store.snippets.isEmpty {
                VaultsEmptyState(
                    icon: "curlybraces",
                    title: "Create snippet",
                    subtitle: "Save your most-used commands as snippets to run them in one click.")
            } else {
                searchBar
                Divider()
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if showHistory {
                ShellHistoryPanel(
                    onSave: { saveFromHistory($0) },
                    onClose: { withAnimation(.easeInOut(duration: 0.18)) { showHistory = false } })
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .sheet(item: $draft) { snippet in
            SnippetEditorView(
                snippet: snippet,
                isNew: isNew,
                onSave: { store.upsert($0); draft = nil },
                onDelete: isNew ? nil : {
                    if DeleteConfirmation.confirm(
                        snippet.displayName,
                        detail: "This permanently removes the snippet.") {
                        store.delete(snippet); draft = nil
                    }
                },
                onCancel: { draft = nil })
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search snippets", text: $search).textFieldStyle(.plain)
            Spacer()
            Text("\(filtered.count) of \(store.snippets.count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { snippet in
                    SnippetRow(
                        snippet: snippet,
                        terminals: tabs.terminals,
                        onSend: { id, execute in send(snippet, toTabID: id, execute: execute) },
                        onCopy: { copy(snippet) },
                        onEdit: { edit(snippet) },
                        onDelete: {
                            if DeleteConfirmation.confirm(
                                snippet.displayName,
                                detail: "This permanently removes the snippet.") {
                                store.delete(snippet)
                            }
                        })
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

    private func startNew() { draft = .blank(); isNew = true }
    private func edit(_ s: Snippet) { draft = s; isNew = false }

    /// Turn a shell-history command into a saved snippet (name defaults to the
    /// command's first line). Keeps the history panel open so several can be added.
    private func saveFromHistory(_ command: String) {
        var snippet = Snippet.blank()
        snippet.command = command
        store.upsert(snippet)
        showToast("Saved to snippets")
    }

    private func send(_ s: Snippet, toTabID id: UUID, execute: Bool) {
        if tabs.sendSnippet(s.command, toTabID: id, execute: execute) {
            showToast(execute ? "Executed in terminal" : "Pasted to terminal")
        }
    }

    private func copy(_ s: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.command, forType: .string)
        showToast("Copied")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let terminals: [VaultsTabsModel.TerminalTab]
    let onSend: (UUID, Bool) -> Void   // (tab id, execute)
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.purple.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.displayName).font(.callout).lineLimit(1)
                Text(snippet.command.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if hovering {
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy command")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete snippet")
            }
            runMenu
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Copy command", action: onCopy)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// Play button → pick a terminal (nested submenus keep it compact even with
    /// many terminals open) and whether to execute or just paste.
    private var runMenu: some View {
        Menu {
            if terminals.isEmpty {
                Text("No open terminals")
            } else {
                Menu("Execute in") {
                    ForEach(terminals) { tab in
                        Button(tab.displayName) { onSend(tab.id, true) }
                    }
                }
                Menu("Paste to") {
                    ForEach(terminals) { tab in
                        Button(tab.displayName) { onSend(tab.id, false) }
                    }
                }
            }
        } label: {
            Image(systemName: "play.circle.fill").font(.system(size: 16))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Run snippet")
    }
}

/// Create / edit a snippet.
private struct SnippetEditorView: View {
    @State var snippet: Snippet
    let isNew: Bool
    let onSave: (Snippet) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Snippet" : "Edit Snippet").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Optional — defaults to the first line", text: $snippet.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $snippet.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12)))
            }

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(snippet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(snippet.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
