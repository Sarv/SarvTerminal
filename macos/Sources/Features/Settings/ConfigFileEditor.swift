import Foundation

/// Line-based editor for `~/.config/ghostty/config`.
///
/// Design choices:
/// - **In-place edit**, not full rewrite. We respect the user's existing
///   comments, ordering, includes, and any keys we don't manage.
/// - For each managed key we replace the **first uncommented occurrence**.
///   If the key is absent, we append it inside a clearly-marked GUI section
///   at the end of the file.
/// - Atomic write via temp file + rename.
final class ConfigFileEditor {

    enum Error: Swift.Error, LocalizedError {
        case readFailed(underlying: Swift.Error)
        case writeFailed(underlying: Swift.Error)
        case unknownConfigDirectory

        var errorDescription: String? {
            switch self {
            case .readFailed(let e): return "Failed to read config file: \(e.localizedDescription)"
            case .writeFailed(let e): return "Failed to write config file: \(e.localizedDescription)"
            case .unknownConfigDirectory: return "Could not determine config directory."
            }
        }
    }

    /// Marker comment for the section the GUI appends to. Lets us re-find
    /// and tidy up our own additions later.
    static let guiSectionMarker = "# --- SarvTerminal GUI settings ---"

    let path: URL
    private var lines: [String]

    init() throws {
        self.path = try Self.configFileURL()

        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let content = try String(contentsOf: path, encoding: .utf8)
                self.lines = content.components(separatedBy: "\n")
                // Trim trailing empty line if the file ended with "\n"
                if let last = self.lines.last, last.isEmpty {
                    self.lines.removeLast()
                }
            } catch {
                throw Error.readFailed(underlying: error)
            }
        } else {
            // Ensure config dir exists.
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            self.lines = []
        }
    }

    /// Set `key = value`. Replaces the first uncommented matching line, or
    /// appends inside the GUI section if not present.
    func set(_ key: String, _ value: String) {
        let serialized = "\(key) = \(value)"
        if let idx = firstUncommentedIndex(forKey: key) {
            lines[idx] = serialized
        } else {
            appendInGUISection(serialized)
        }
    }

    /// Remove all uncommented lines that set this key.
    func remove(_ key: String) {
        lines.removeAll { line in
            guard !isCommentedOrBlank(line) else { return false }
            return matches(line: line, key: key)
        }
    }

    /// Append a `keybind = <value>` line in the GUI section. Used by the
    /// keybind editor where multiple lines of the same key are allowed.
    func appendKeybind(_ value: String) {
        appendInGUISection("keybind = \(value)")
    }

    /// Remove the keybind line that exactly matches the given raw source
    /// line. Used by the keybind editor for delete/edit.
    func removeRawLine(_ rawLine: String) {
        lines.removeAll { $0 == rawLine }
    }

    /// Remove ALL uncommented lines that assign to this key. Useful for
    /// "Reset to defaults" on a repeatable key like `keybind`.
    func removeAll(key: String) {
        lines.removeAll { line in
            guard !isCommentedOrBlank(line) else { return false }
            return matches(line: line, key: key)
        }
    }

    /// Persist the current in-memory line list back to disk atomically.
    func commit() throws {
        var content = lines.joined(separator: "\n")
        // Always end with newline (POSIX convention).
        if !content.hasSuffix("\n") { content.append("\n") }

        do {
            try content.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw Error.writeFailed(underlying: error)
        }
    }

    // MARK: - Helpers

    private func firstUncommentedIndex(forKey key: String) -> Int? {
        lines.firstIndex { line in
            guard !isCommentedOrBlank(line) else { return false }
            return matches(line: line, key: key)
        }
    }

    /// True if the line is empty or starts with `#` (after trimming whitespace).
    private func isCommentedOrBlank(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// True if the line is a `key = value` or `key=value` assignment for the
    /// given key. Tolerates whitespace around the `=`.
    private func matches(line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eqIdx = trimmed.firstIndex(of: "=") else { return false }
        let lhs = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
        return lhs == key
    }

    /// Append `line` inside our GUI section, creating the marker block at
    /// EOF if needed.
    private func appendInGUISection(_ line: String) {
        if let markerIdx = lines.firstIndex(of: Self.guiSectionMarker) {
            // Insert right after the marker (and any subsequent GUI lines
            // that already exist) to keep this section together. Simplest:
            // find the next empty line / non-assignment, insert before it.
            var insertIdx = markerIdx + 1
            while insertIdx < lines.count {
                let next = lines[insertIdx]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    break
                }
                insertIdx += 1
            }
            lines.insert(line, at: insertIdx)
        } else {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            lines.append(Self.guiSectionMarker)
            lines.append(line)
        }
    }

    // MARK: - Path resolution

    private static func configFileURL() throws -> URL {
        // Single source of truth — debug builds get an isolated config file so
        // dev experiments never touch the release app's config.
        return AppPaths.ghosttyConfigFile
    }
}
