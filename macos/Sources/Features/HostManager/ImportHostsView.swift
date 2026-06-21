import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Termius-style import flow:
///   1. pick a format,
///   2. (CSV) see the format + choose a file,
///   3. review/deselect the parsed hosts,
///   4. import → result.
struct ImportHostsView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Screen { case formats, csvIntro, preview, done }
    @State private var screen: Screen = .formats

    @State private var candidates: [ParsedHost] = []
    @State private var selected: Set<UUID> = []
    @State private var filter = ""
    @State private var title = "Add hosts to your vault"
    @State private var note: String?       // inline error / hint
    @State private var result: HostImportResult?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch screen {
                case .formats: formatsScreen
                case .csvIntro: csvIntroScreen
                case .preview: previewScreen
                case .done: doneScreen
                }
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.square.stack")
                .font(.system(size: 34)).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22).padding(.bottom, 16)
    }

    // MARK: - 1. Formats

    private var formatsScreen: some View {
        VStack(spacing: 16) {
            Text("Transfer your saved connections, groups, and tags. Select a source to start.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            HStack(alignment: .top, spacing: 14) {
                formatCard("~/.ssh/config", "terminal", enabled: true) { startSSH() }
                formatCard("CSV", "tablecells", enabled: true) { title = "Import from CSV"; note = nil; screen = .csvIntro }
                formatCard("PuTTY", "pc", enabled: true) { startPuTTY() }
                formatCard("MobaXterm", "macwindow", enabled: true) { startMobaXterm() }
                formatCard("SecureCRT", "lock.laptopcomputer", enabled: true) { startSecureCRT() }
            }
            if let note { noteLabel(note) }
            Spacer()
        }
        .padding(24)
    }

    private func formatCard(_ label: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 26))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
                Text(label).font(.callout).lineLimit(1)
                if !enabled {
                    Text("Soon").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.22)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100).contentShape(Rectangle()).opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(enabled ? "Import from \(label)" : "\(label) import is coming soon")
    }

    // MARK: - 2. CSV intro (format + choose file)

    private var csvIntroScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your CSV must use this header row. Only `hostname` is required.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(HostImporter.csvHeader)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 6) {
                bullet("`group` accepts a path like `Workspace/Dev` — groups are created automatically.")
                bullet("`tags` are separated by `;` (e.g. `prod;web`).")
                bullet("`auth` is one of password / publicKey / agent / ask.")
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Choose CSV file…") { chooseCSV() }.controlSize(.large)
                Button("Save template…") { saveTemplate() }
            }
            .padding(.top, 4)

            if let note { noteLabel(note) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•"); Text(.init(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 3. Preview (review + select)

    private var filtered: [ParsedHost] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.label.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    private var previewScreen: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)

            // Group header with select-all.
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text("Hosts").font(.headline)
                Spacer()
                Text("\(selected.count) of \(candidates.count)").font(.caption).foregroundStyle(.secondary)
                Button { toggleAll() } label: {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? .blue : .secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { host in
                        Button { toggle(host.id) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.label).foregroundStyle(.primary)
                                    Text(host.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selected.contains(host.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(host.id) ? .blue : .secondary)
                            }
                            .padding(.horizontal, 24).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 24)
                    }
                }
            }
        }
    }

    private var allSelected: Bool { !candidates.isEmpty && selected.count == candidates.count }
    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func toggleAll() { selected = allSelected ? [] : Set(candidates.map(\.id)) }

    // MARK: - 4. Done

    private var doneScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(result?.summary ?? "Done").font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if screen == .formats {
                Button("Cancel") { dismiss() }
            } else if screen == .done {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { backToFormats() }
            }
            if screen == .preview {
                Spacer()
                Button("Import \(selected.count) selected") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    private func noteLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func backToFormats() {
        screen = .formats; title = "Add hosts to your vault"; note = nil
        candidates = []; selected = []; filter = ""
    }

    private func startSSH() {
        let hosts = HostImporter.parseSSHConfig()
        if hosts.isEmpty { note = "No hosts found in ~/.ssh/config."; return }
        showPreview(hosts, title: "Import from ~/.ssh/config")
    }

    private func startPuTTY() {
        guard let content = readPickedFile(allowDirectory: false) else { return }
        let (hosts, error) = HostImporter.parsePuTTY(content)
        if let error { note = error; return }
        showPreview(hosts, title: "Review \(hosts.count) PuTTY session\(hosts.count == 1 ? "" : "s")")
    }

    private func startMobaXterm() {
        guard let content = readPickedFile(allowDirectory: false) else { return }
        let (hosts, error) = HostImporter.parseMobaXterm(content)
        if let error { note = error; return }
        showPreview(hosts, title: "Review \(hosts.count) MobaXterm session\(hosts.count == 1 ? "" : "s")")
    }

    private func startSecureCRT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // pick the Sessions folder or a single .ini
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose your SecureCRT 'Sessions' folder (or a single .ini)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (hosts, error) = HostImporter.parseSecureCRT(at: url)
        if let error { note = error; return }
        showPreview(hosts, title: "Review \(hosts.count) SecureCRT session\(hosts.count == 1 ? "" : "s")")
    }

    /// Open a file panel and return the file's text contents (nil if cancelled
    /// or unreadable — the latter sets `note`).
    private func readPickedFile(allowDirectory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowDirectory
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            note = "Couldn't read that file."
            return nil
        }
        return content
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            note = "Couldn't read that file."; return
        }
        let (hosts, error) = HostImporter.parseCSV(content)
        if let error { note = error; return }
        showPreview(hosts, title: "Review \(hosts.count) host\(hosts.count == 1 ? "" : "s")")
    }

    private func showPreview(_ hosts: [ParsedHost], title: String) {
        candidates = hosts
        selected = Set(hosts.map(\.id))   // all selected by default
        filter = ""; note = nil
        self.title = title
        screen = .preview
    }

    private func commit() {
        let chosen = candidates.filter { selected.contains($0.id) }
        result = HostImporter.commit(chosen)
        title = "Import complete"
        screen = .done
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "sarvterminal-hosts-template.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? HostImporter.csvTemplate.write(to: url, atomically: true, encoding: .utf8)
    }
}
