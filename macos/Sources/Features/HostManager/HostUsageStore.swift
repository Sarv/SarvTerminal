import Foundation

/// When a host was last connected and how often. Hosts never connected have
/// no entry (null), and get one on their first successful connect.
struct HostUsage: Codable, Equatable {
    var lastUsedAt: Date
    var useCount: Int
}

/// Pure usage bookkeeping and the "Recently used" ordering.
enum HostRecency {
    static func recording(_ id: UUID, at date: Date, in usage: [UUID: HostUsage]) -> [UUID: HostUsage] {
        var next = usage
        let count = (usage[id]?.useCount ?? 0) + 1
        next[id] = HostUsage(lastUsedAt: date, useCount: count)
        return next
    }

    /// Used hosts first, most recent first; never-used hosts after, A–Z.
    static func sorted(_ hosts: [SavedHost], usage: [UUID: HostUsage]) -> [SavedHost] {
        hosts.sorted { lhs, rhs in
            precedes(lastUse: (usage[lhs.id]?.lastUsedAt, usage[rhs.id]?.lastUsedAt),
                     names: (lhs.displayLabel, rhs.displayLabel))
        }
    }

    /// The latest use of any host in `hostIDs`, or nil when none was used.
    static func latestUse(of hostIDs: [UUID], usage: [UUID: HostUsage]) -> Date? {
        hostIDs.compactMap { usage[$0]?.lastUsedAt }.max()
    }

    /// Shared ordering for hosts and groups: by last use, then by name.
    static func precedes(lastUse: (Date?, Date?), names: (String, String)) -> Bool {
        switch lastUse {
        case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
        case (.some, .none): return true
        case (.none, .some): return false
        default: return names.0.localizedCaseInsensitiveCompare(names.1) == .orderedAscending
        }
    }
}

/// Local-only store of `HostUsage`, encrypted at rest like the host list.
///
/// Deliberately kept out of the host records and out of sync: connecting to
/// a host is not an edit, and must never create a backup version.
final class HostUsageStore: ObservableObject {
    static let shared = HostUsageStore()

    @Published private(set) var usage: [UUID: HostUsage] = [:]

    private let fileURL: URL
    private let queue = DispatchQueue(label: "HostUsageStore.io", qos: .utility)

    private init() {
        fileURL = AppPaths.configDir.appendingPathComponent("host-usage.json")
        load()
    }

    func recordUse(of hostID: UUID, at date: Date) {
        usage = HostRecency.recording(hostID, at: date, in: usage)
        persist()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch EncryptedStore.read([UUID: HostUsage].self, from: fileURL, decoder: decoder) {
        case .loaded(let decoded), .migrated(let decoded): usage = decoded
        case .none, .failed: usage = [:]
        }
    }

    private func persist() {
        let snapshot = usage
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? EncryptedStore.write(snapshot, to: url, encoder: encoder)
        }
    }
}
