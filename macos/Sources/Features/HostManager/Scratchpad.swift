import SwiftUI

/// Persisted scratchpad text — a place to comfortably stage/edit multi-line
/// commands or scripts (full mouse + cursor) before firing them into the active
/// terminal. Encrypted at rest since it may hold secrets. One shared buffer.
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()

    @Published var text: String = "" { didSet { schedulePersist() } }
    @Published var language: String = "bash" { didSet { schedulePersist() } }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ScratchpadStore.io", qos: .utility)
    private var pending: DispatchWorkItem?
    private var loaded = false

    private struct Payload: Codable { var text: String; var language: String }

    private init() {
        fileURL = AppPaths.configDir.appendingPathComponent("scratchpad.json")
        load()
        loaded = true
    }

    private func load() {
        switch EncryptedStore.read(Payload.self, from: fileURL, decoder: JSONDecoder()) {
        case .loaded(let p), .migrated(let p):
            text = p.text
            language = p.language.isEmpty ? "bash" : p.language
        case .none, .failed:
            break
        }
    }

    private func schedulePersist() {
        guard loaded else { return }   // don't write back what we just loaded
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persist() {
        let snapshot = Payload(text: text, language: language)
        let url = fileURL
        queue.async {
            try? EncryptedStore.write(snapshot, to: url, encoder: JSONEncoder())
        }
    }
}

/// Collapsible side panel next to the terminal: a comfortable editor (mouse +
/// cursor, syntax highlighting) that sends its contents to the active pane.
/// Bridges "text editor" and "shell": paste a big script here, edit it, hit
/// ⌘↵ to run it in the focused terminal.
struct ScratchpadPanel: View {
    @ObservedObject private var store = ScratchpadStore.shared
    @ObservedObject private var tabs = VaultsTabsModel.shared
    @StateObject private var find = FileFindSession()
    let onClose: () -> Void

    private var hasTerminal: Bool { tabs.activeTerminal != nil }
    private var canSend: Bool { hasTerminal && !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            CodeEditorView(text: $store.text, isEditable: true, wordWrap: true,
                           language: store.language, indentWidth: 4,
                           findSession: find, editorIdentifier: "scratchpad-editor", onEdit: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            Divider()
            footer
        }
        .frame(width: 360)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").foregroundStyle(.tint)
            Text("Scratchpad").fontWeight(.semibold)
            Spacer()
            Menu {
                ForEach(CodeLang.common) { lang in
                    Button {
                        store.language = lang.id
                    } label: {
                        if store.language == lang.id { Label(lang.label, systemImage: "checkmark") }
                        else { Text(lang.label) }
                    }
                }
            } label: {
                Text(CodeLang.label(for: store.language)).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().hoverTip("Syntax highlighting")

            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).hoverTip("Close scratchpad")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { _ = tabs.pasteToTargetTerminal(store.text) } label: {
                    Label("Send", systemImage: "text.insert")
                }
                .controlSize(.small).disabled(!canSend)
                .hoverTip("Paste into the active terminal (no Enter)")

                Button { _ = tabs.runInTargetTerminal(store.text) } label: {
                    Label("Run", systemImage: "return")
                }
                .controlSize(.small).buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .hoverTip("Send to the active terminal and run (⌘↵)")

                Spacer()

                Menu {
                    Button { saveAsSnippet() } label: { Label("Save as snippet", systemImage: "bookmark") }
                        .disabled(store.text.isEmpty)
                    Divider()
                    Button(role: .destructive) { store.text = "" } label: { Label("Clear", systemImage: "trash") }
                        .disabled(store.text.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverTip("More")
            }

            if !hasTerminal {
                Text("Open a terminal tab to send commands.")
                    .font(.caption2).foregroundStyle(.secondaryText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func saveAsSnippet() {
        let firstLine = store.text
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        var snippet = Snippet.blank()
        snippet.name = firstLine.isEmpty ? "Scratch snippet" : String(firstLine.prefix(60))
        snippet.command = store.text
        SnippetsStore.shared.upsert(snippet)
    }
}
