import Foundation
import Combine

/// Persisted set of "pinned" shell-history commands. Pinned commands are shown
/// at the top of the command sidebar's History tab and are exempt from the
/// recent-history cap (so they're never rolled off automatically). Stored
/// encrypted at rest, like the other local stores.
final class PinnedHistoryStore: ObservableObject {
    static let shared = PinnedHistoryStore()

    /// Newest-pinned first.
    @Published private(set) var pinned: [String] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "PinnedHistoryStore.io", qos: .utility)

    private init() {
        fileURL = AppPaths.configDir.appendingPathComponent("pinned-history.json")
        load()
    }

    func isPinned(_ command: String) -> Bool { pinned.contains(command) }

    func toggle(_ command: String) {
        if let idx = pinned.firstIndex(of: command) {
            pinned.remove(at: idx)
        } else {
            pinned.insert(command, at: 0)
        }
        persist()
    }

    private func load() {
        switch EncryptedStore.read([String].self, from: fileURL, decoder: JSONDecoder()) {
        case .loaded(let v), .migrated(let v): pinned = v
        case .none, .failed: pinned = []
        }
    }

    private func persist() {
        let snapshot = pinned
        let url = fileURL
        queue.async {
            try? EncryptedStore.write(snapshot, to: url, encoder: JSONEncoder())
        }
    }
}
