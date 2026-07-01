import Foundation

/// The single search/filter used across every filterable list — host search
/// palette, hosts dashboard, saved sessions, snippets, port forwards, SFTP.
///
/// Normalization lives in ONE place so a forgotten `.lowercased()` can't make
/// one list case-sensitive while another isn't. The query is split on
/// whitespace and EVERY token must appear (case-insensitively) in at least one
/// field, so multi-word queries like "loc 2222" match "Local SSH 2222".
enum SearchMatcher {
    /// True when `query` matches the given fields. An empty/whitespace query
    /// matches everything (no filtering).
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return true }
        let haystacks = fields.map { $0.lowercased() }
        return tokens.allSatisfy { token in
            haystacks.contains { $0.contains(token) }
        }
    }

    /// Convenience for the common `items.filter { … }` shape.
    static func filter<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matches(trimmed, in: fields($0)) }
    }
}
