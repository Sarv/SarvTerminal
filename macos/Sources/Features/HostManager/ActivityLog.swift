import SwiftUI
import Combine

/// Kind of activity, used for the icon, tint, and filtering in the Logs view.
enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case connection
    case sync
    case transfer
    case error
    case info

    var id: String { rawValue }

    var label: String {
        switch self {
        case .connection: return "Connections"
        case .sync:       return "Sync"
        case .transfer:   return "Transfers"
        case .error:      return "Errors"
        case .info:       return "Info"
        }
    }

    var icon: String {
        switch self {
        case .connection: return "bolt.horizontal.circle"
        case .sync:       return "arrow.triangle.2.circlepath"
        case .transfer:   return "arrow.up.arrow.down"
        case .error:      return "exclamationmark.triangle"
        case .info:       return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .connection: return .blue
        case .sync:       return .green
        case .transfer:   return .purple
        case .error:      return .red
        case .info:       return .secondary
        }
    }
}

/// A single activity entry.
struct ActivityEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var date: Date
    var category: ActivityCategory
    var title: String
    var detail: String?
    /// false renders the row's icon in red regardless of category (e.g. a
    /// failed connection still lives under "Connections" but reads as a failure).
    var success: Bool
}

/// App-wide, persisted activity log shown in Vaults → Logs. Distinct from the
/// ephemeral per-connection log panel: this is a durable history of
/// connections, syncs, transfers, and errors across the whole app.
///
/// Storage: `~/.config/sarvterminal/activity.json` (a capped ring of the most
/// recent `maxEntries`, newest first).
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published private(set) var entries: [ActivityEntry] = []

    private let maxEntries = 1000
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ActivityLog.io", qos: .utility)

    private init() {
        let dir = AppPaths.configDir
        fileURL = dir.appendingPathComponent("activity.json")
        load()
    }

    // MARK: - Logging

    /// Record an event. Safe to call from any thread; hops to main to mutate
    /// the published array.
    func log(_ category: ActivityCategory, _ title: String, detail: String? = nil, success: Bool = true) {
        let entry = ActivityEntry(id: UUID(), date: Date(), category: category,
                                  title: title, detail: detail, success: success)
        let apply = {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            self.persist()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    // MARK: - IO

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ActivityEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
