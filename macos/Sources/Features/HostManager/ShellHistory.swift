import SwiftUI
import AppKit

/// Reads the user's shell command history (zsh / bash / fish) for the Snippets
/// "Shell History" panel — most-recent-first and de-duplicated, so any past
/// command can be saved as a snippet in one click.
enum ShellHistory {
    /// Up to `limit` recent unique commands, newest first.
    static func recent(limit: Int = 400) -> [String] {
        guard let url = historyFile(),
              let data = try? Data(contentsOf: url) else { return [] }
        // History files can hold non-UTF8 bytes — decode leniently.
        return parse(String(decoding: data, as: UTF8.self), limit: limit)
    }

    /// The shell history file to read: `$HISTFILE` if set, else the usual
    /// per-shell defaults.
    private static func historyFile() -> URL? {
        let fm = FileManager.default
        if let hf = ProcessInfo.processInfo.environment["HISTFILE"], !hf.isEmpty {
            let path = (hf as NSString).expandingTildeInPath
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.zsh_history",
            "\(home)/.bash_history",
            "\(home)/.local/share/fish/fish_history",
        ]
        return candidates.first { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Normalize a raw history file into a clean, newest-first, de-duplicated list.
    private static func parse(_ raw: String, limit: Int) -> [String] {
        var commands: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            // zsh extended history: ": 1700000000:0;the command"
            if line.hasPrefix(":"), let semi = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semi)...])
            }
            // fish history is YAML-ish: "- cmd: the command" (+ "  when:" metadata)
            if line.hasPrefix("- cmd: ") {
                line = String(line.dropFirst("- cmd: ".count))
            } else if line.hasPrefix("  when:") || line.hasPrefix("- when:") {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { commands.append(trimmed) }
        }
        // Newest first, keeping the most-recent occurrence of each command.
        var seen = Set<String>()
        var result: [String] = []
        for cmd in commands.reversed() where seen.insert(cmd).inserted {
            result.append(cmd)
            if result.count >= limit { break }
        }
        return result
    }
}

/// A trailing side panel listing recent shell-history commands. Each row offers
/// a **Save** action that turns the command into a snippet.
struct ShellHistoryPanel: View {
    /// Called with a command the user chose to save as a snippet.
    let onSave: (String) -> Void
    let onClose: () -> Void

    @State private var items: [String] = []
    @State private var query = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text("Shell History").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText)
                TextField("Filter history", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.questionmark").font(.title2).foregroundStyle(.secondaryText)
                    Text("No shell history found").font(.callout).foregroundStyle(.secondaryText)
                    Text("Reads ~/.zsh_history, ~/.bash_history, or $HISTFILE.")
                        .font(.caption).foregroundStyle(.tertiaryText).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.self) { cmd in
                            ShellHistoryRow(command: cmd) { onSave(cmd) }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
        .onAppear { items = ShellHistory.recent() }
    }
}

private struct ShellHistoryRow: View {
    let command: String
    let onSave: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering {
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.secondary.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
