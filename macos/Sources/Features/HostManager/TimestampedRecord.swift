import Foundation

/// A synced record (host, group, snippet, saved session, port forward) whose
/// timestamps are bookkeeping, not content.
protocol TimestampedRecord: Identifiable, Equatable {
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
}

extension TimestampedRecord {
    /// Equal in everything but `createdAt` / `updatedAt`.
    func contentEquals(_ other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.createdAt = .distantPast; rhs.createdAt = .distantPast
        lhs.updatedAt = .distantPast; rhs.updatedAt = .distantPast
        return lhs == rhs
    }
}

enum RecordUpsert {
    /// Insert or replace `record` in `list`, stamping `updatedAt = now`.
    ///
    /// Returns nil when an identical record (timestamps aside) is already
    /// stored: re-saving unchanged content must not bump `updatedAt`, because
    /// that changes the sync fingerprint and writes a new backup version.
    static func apply<Record: TimestampedRecord>(_ record: Record, to list: [Record], now: Date) -> [Record]? {
        var stamped = record
        stamped.updatedAt = now
        guard let index = list.firstIndex(where: { $0.id == record.id }) else { return list + [stamped] }
        guard !list[index].contentEquals(record) else { return nil }
        var updated = list
        updated[index] = stamped
        return updated
    }
}
