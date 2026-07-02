import Foundation
import CryptoKit

/// One parsed entry from `~/.ssh/known_hosts`.
struct KnownHostEntry: Identifiable {
    let id = UUID()
    let raw: String            // original line, used to match on delete
    let hostDisplay: String    // e.g. "[127.0.0.1]:2222" or "(hashed host)"
    let keyType: String        // ssh-ed25519, ssh-rsa, ecdsa-sha2-nistp256, …
    let fingerprint: String    // "SHA256:…"
    let isHashed: Bool
}

/// Reads / edits `~/.ssh/known_hosts`. The app isn't sandboxed, so it touches
/// the file directly. Deleting an entry rewrites the file (useful when a host
/// key changed and ssh refuses to connect).
final class KnownHostsStore: ObservableObject {
    static let shared = KnownHostsStore()

    @Published private(set) var entries: [KnownHostEntry] = []

    private var fileURL: URL {
        AppPaths.sshDir.appendingPathComponent("known_hosts")
    }

    private init() { reload() }

    func reload() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            entries = []
            return
        }
        entries = Self.parse(content)
    }

    /// Remove an entry by exact line match and rewrite the file.
    func delete(_ entry: KnownHostEntry) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0 != entry.raw }
        try? kept.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }

    /// Merge unique entries from another known_hosts-format file. Returns how
    /// many new lines were appended.
    @discardableResult
    func importFrom(_ url: URL) -> Int {
        guard let incoming = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var seen = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var added: [String] = []
        for raw in incoming.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            added.append(line)
        }
        guard !added.isEmpty else { return 0 }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = existing
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += added.joined(separator: "\n") + "\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
        return added.count
    }

    // MARK: - Parsing

    static func parse(_ content: String) -> [KnownHostEntry] {
        var out: [KnownHostEntry] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            var tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.first?.hasPrefix("@") == true { tokens.removeFirst() }  // @cert-authority / @revoked
            guard tokens.count >= 3 else { continue }

            let hostField = tokens[0]
            let isHashed = hostField.hasPrefix("|1|")
            out.append(KnownHostEntry(
                raw: line,
                hostDisplay: isHashed ? "(hashed host)" : hostField.replacingOccurrences(of: ",", with: ", "),
                keyType: tokens[1],
                fingerprint: fingerprint(base64Key: tokens[2]),
                isHashed: isHashed))
        }
        return out
    }

    /// OpenSSH-style SHA256 fingerprint of a base64 key blob.
    static func fingerprint(base64Key: String) -> String {
        guard let data = Data(base64Encoded: base64Key) else { return "—" }
        let digest = SHA256.hash(data: data)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
}
