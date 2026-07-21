import SwiftUI
import AppKit

/// Reads the user's shell command history (zsh / bash / fish) for the Snippets
/// "Shell History" panel — most-recent-first and de-duplicated, so any past
/// command can be saved as a snippet in one click.
/// One history command plus, when the shell records it, WHEN it was run.
struct ShellHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let command: String
    /// nil when the shell's history format carries no timestamp (e.g. bash
    /// without `HISTTIMEFORMAT`, or zsh without `extended_history`).
    let date: Date?
}

enum ShellHistory {
    /// Up to `limit` recent unique commands, newest first (text only).
    static func recent(limit: Int = 400) -> [String] {
        recentEntries(limit: limit).map(\.command)
    }

    /// Up to `limit` recent unique commands, newest first, each with its run
    /// time when the shell records one (zsh `extended_history`, bash
    /// `HISTTIMEFORMAT`, fish). The newest occurrence (and its date) wins.
    static func recentEntries(limit: Int = 400) -> [ShellHistoryEntry] {
        guard let url = historyFile(),
              let data = try? Data(contentsOf: url) else { return [] }
        // History files can hold non-UTF8 bytes — decode leniently.
        return parseEntries(String(decoding: data, as: UTF8.self), limit: limit)
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

    /// Normalize a raw history file (zsh / bash / fish) into newest-first,
    /// de-duplicated entries, parsing timestamps where the format carries them.
    private static func parseEntries(_ raw: String, limit: Int) -> [ShellHistoryEntry] {
        var parsed: [(cmd: String, date: Date?)] = []
        var pendingBashDate: Date?     // a bash "#<epoch>" line applies to the next command
        var fishCmd: String?           // fish "- cmd:" awaiting its "when:"
        var fishDate: Date?

        func flushFish() {
            if let c = fishCmd { parsed.append((c, fishDate)); fishCmd = nil; fishDate = nil }
        }
        func epoch(_ s: Substring) -> Date? {
            Double(s.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) }
        }

        // A command with embedded newlines is written by zsh/bash as a trailing
        // backslash on each physical line, continuing on the next. Rejoin those
        // into one logical command (real newlines) — otherwise every
        // continuation line becomes a separate, timestamp-less "Earlier"
        // fragment, which scatters the day-grouped timeline and duplicates
        // section titles.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline is escaped only when preceded by an ODD number of
        // backslashes (an even count is literal escaped backslashes).
        func endsWithOddBackslash(_ s: String) -> Bool {
            var count = 0
            var idx = s.endIndex
            while idx > s.startIndex {
                idx = s.index(before: idx)
                if s[idx] == "\\" { count += 1 } else { break }
            }
            return count % 2 == 1
        }
        // Swallow continuation lines, turning each escaping backslash + newline
        // back into a real newline. Advances `i` past every line it consumes.
        func joinContinuations(_ first: String, _ i: inout Int) -> String {
            var cmd = first
            while endsWithOddBackslash(cmd), i + 1 < lines.count {
                cmd.removeLast()               // drop the escaping backslash
                i += 1
                cmd += "\n" + String(lines[i])
            }
            return cmd
        }

        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let line = String(lines[i])

            // fish: "- cmd: <command>" then "  when: <epoch>" (+ "  paths:" metadata).
            if line.hasPrefix("- cmd: ") {
                flushFish()
                fishCmd = String(line.dropFirst("- cmd: ".count))
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                continue
            }
            if line.hasPrefix("  when:") { fishDate = epoch(line[line.index(after: line.firstIndex(of: ":")!)...]); continue }
            if line.hasPrefix("  paths:") || line.hasPrefix("    - ") { continue }
            if fishCmd != nil { flushFish() }

            // bash with HISTTIMEFORMAT: a bare "#<epoch>" precedes its command.
            if line.hasPrefix("#"), line.count > 1,
               let e = Double(line.dropFirst()), e > 100_000_000 {
                pendingBashDate = Date(timeIntervalSince1970: e)
                continue
            }

            // zsh extended_history: ": <epoch>:<elapsed>;<command>"
            if line.hasPrefix(":") {
                let rest = line.dropFirst().drop(while: { $0 == " " })
                if let semi = rest.firstIndex(of: ";") {
                    let date = rest[..<semi].split(separator: ":").first.flatMap(epoch)
                    let cmd = joinContinuations(String(rest[rest.index(after: semi)...]), &i)
                        .trimmingCharacters(in: .whitespaces)
                    if !cmd.isEmpty { parsed.append((cmd, date)) }
                    continue
                }
            }

            // Plain command (bash w/o timestamps, or zsh non-extended).
            let cmd = joinContinuations(line, &i).trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty {
                parsed.append((cmd, pendingBashDate))
                pendingBashDate = nil
            }
        }
        flushFish()

        // Newest first, keeping the most-recent occurrence (and its date).
        var seen = Set<String>()
        var result: [ShellHistoryEntry] = []
        for e in parsed.reversed() where seen.insert(e.cmd).inserted {
            result.append(ShellHistoryEntry(command: e.cmd, date: e.date))
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
