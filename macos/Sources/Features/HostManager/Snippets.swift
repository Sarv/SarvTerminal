import Foundation
import Combine

/// A saved command/script the user can run into a terminal in one click.
struct Snippet: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var command: String
    var createdAt: Date
    var updatedAt: Date

    static func blank() -> Snippet {
        let now = Date()
        return Snippet(id: UUID(), name: "", command: "", createdAt: now, updatedAt: now)
    }

    /// Custom decoder so older/partial JSON still loads with safe defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
    }

    init(id: UUID, name: String, command: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.command = command
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled snippet" : firstLine
    }

    /// True when there's nothing worth saving.
    var isEmpty: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Owns the persisted snippet library. Storage:
/// `~/.config/sarvterminal/snippets.json`. Mirrors `SavedHostsStore` so it
/// participates in sync (ingest/replaceAll + `loadFailed`).
final class SnippetsStore: ObservableObject {
    static let shared = SnippetsStore()

    @Published private(set) var snippets: [Snippet] = []
    /// True when the file exists but couldn't be read — the empty array is then
    /// NOT authoritative (sync must not push it).
    private(set) var loadFailed = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "SnippetsStore.io", qos: .utility)

    private init() {
        let dir = AppPaths.configDir
        fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    // MARK: - CRUD

    func upsert(_ snippet: Snippet) {
        var updated = snippet
        updated.updatedAt = Date()
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = updated
        } else {
            snippets.append(updated)
        }
        sortInPlace()
        persist()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    // MARK: - Sync helpers

    /// Merge synced snippets by id, newest `updatedAt` wins; never delete local-only.
    func ingest(_ incoming: [Snippet]) {
        var changed = false
        for s in incoming {
            if let idx = snippets.firstIndex(where: { $0.id == s.id }) {
                if s.updatedAt >= snippets[idx].updatedAt { snippets[idx] = s; changed = true }
            } else {
                snippets.append(s); changed = true
            }
        }
        if changed { sortInPlace(); persist() }
    }

    /// Mirror the synced set (deletes propagate).
    func replaceAll(_ incoming: [Snippet]) {
        snippets = incoming
        sortInPlace()
        persist()
    }

    // MARK: - IO

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loadFailed = false; return }
        guard let data = try? Data(contentsOf: fileURL) else { loadFailed = true; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Snippet].self, from: data) {
            snippets = decoded
            sortInPlace()
            loadFailed = false
        } else {
            loadFailed = true
        }
    }

    private func persist() {
        let snapshot = snippets
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func sortInPlace() {
        snippets.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
