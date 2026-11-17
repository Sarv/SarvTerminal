import Foundation

/// Reads and writes an agent's JSON config for `AgentHookFormat`. Never
/// writes a file it couldn't parse, and backs up a shared file first.
enum AgentConfigFile {
    enum Failure: LocalizedError {
        case unreadable(URL, Error)
        case notAnObject(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url, let error):
                return "\(url.path) couldn't be read as JSON, so it was left unchanged. \(error.localizedDescription)"
            case .notAnObject(let url):
                return "\(url.path) isn't a JSON object, so it was left unchanged."
            }
        }
    }

    /// The backup written next to a shared config before each change.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("sarvterminal-backup")
    }

    /// The decoded config, or empty when the file doesn't exist yet.
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.notAnObject(url)
            }
            return object
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(url, error)
        }
    }

    /// Applies `change` to the file: backs up the current file when asked,
    /// then writes the result atomically.
    static func update(at url: URL, backup: Bool = true, _ change: ([String: Any]) -> [String: Any]) throws {
        let next = change(try read(url))
        let data = try JSONSerialization.data(
            withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup && manager.fileExists(atPath: url.path) {
            let backupURL = backupURL(for: url)
            try? manager.removeItem(at: backupURL)
            try manager.copyItem(at: url, to: backupURL)
        }
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// Deletes a file SarvTerminal wrote itself. A missing file is fine.
    static func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
