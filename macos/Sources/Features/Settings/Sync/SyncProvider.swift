import Foundation

/// A storage backend for the encrypted sync payloads. Providers deal only in
/// opaque bytes — encryption and payload assembly happen in `SyncEngine`.
protocol SyncProvider {
    /// Validate credentials / reachability. Throws a user-facing error on failure.
    func testConnection() async throws
    /// Raw bytes of the plaintext manifest, or nil if the remote is empty.
    func readManifest() async throws -> Data?
    /// Raw bytes of a payload file, or nil if absent.
    func readFile(_ name: String) async throws -> Data?
    /// Write a batch of files. Implementations must write `manifest.json` LAST
    /// so a partial failure never advertises a version whose payloads are missing.
    func writeFiles(_ files: [String: Data]) async throws
}

struct SyncProviderError: LocalizedError {
    let message: String
    /// True for transient sync conflicts (e.g. another sync in flight). These
    /// are handled internally and should NOT be surfaced to the user.
    var isConflict: Bool = false
    var errorDescription: String? { message }
}

// MARK: - GitHub (PAT, private-repo only)

/// Stores payloads as files in a **private** GitHub repo via the REST contents
/// API. No OAuth — a fine-grained or classic PAT with `contents:write` is used.
struct GitHubSyncProvider: SyncProvider {
    let owner: String
    let repo: String
    let token: String

    private var apiBase: String { "https://api.github.com/repos/\(owner)/\(repo)" }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.httpBody = body
        return r
    }

    func testConnection() async throws {
        guard let url = URL(string: apiBase) else {
            throw SyncProviderError(message: "Invalid repository.")
        }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse else {
            throw SyncProviderError(message: "No response from GitHub.")
        }
        switch http.statusCode {
        case 200: break
        case 401: throw SyncProviderError(message: "Invalid token (401). Check your PAT.")
        case 403: throw SyncProviderError(message: "Access forbidden (403). The token may lack repo access.")
        case 404: throw SyncProviderError(message: "Repository not found, or the token can't see it.")
        default:  throw SyncProviderError(message: "GitHub returned \(http.statusCode).")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Enforce private-repo-only.
        if let isPrivate = json?["private"] as? Bool, isPrivate == false {
            throw SyncProviderError(message: "This repository is public. Use a private repository — your settings must never be stored publicly.")
        }
        // Require push permission so a later Sync↑ won't fail.
        if let perms = json?["permissions"] as? [String: Any],
           let push = perms["push"] as? Bool, push == false {
            throw SyncProviderError(message: "The token has read-only access. A token with write (contents) permission is required.")
        }
    }

    func readManifest() async throws -> Data? {
        try await readFile(SyncManifest.manifestFile)
    }

    func readFile(_ name: String) async throws -> Data? {
        guard let url = URL(string: "\(apiBase)/contents/\(name)") else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse else {
            throw SyncProviderError(message: "No response from GitHub.")
        }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw SyncProviderError(message: "GitHub returned \(http.statusCode) reading \(name).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["content"] as? String else {
            throw SyncProviderError(message: "Malformed response reading \(name).")
        }
        // GitHub wraps base64 at 60 cols.
        let clean = b64.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: clean) else {
            throw SyncProviderError(message: "Could not decode \(name).")
        }
        return decoded
    }

    /// Fetch the blob SHA for an existing file (nil if it doesn't exist) — the
    /// contents API needs it to update in place.
    private func currentSHA(_ name: String) async throws -> String? {
        guard let url = URL(string: "\(apiBase)/contents/\(name)") else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["sha"] as? String
    }

    func writeFiles(_ files: [String: Data]) async throws {
        // manifest.json last.
        let ordered = files.sorted { a, _ in a.key != SyncManifest.manifestFile }
        for (name, bytes) in ordered {
            try await put(name, bytes)
        }
    }

    /// PUT a file, fetching its current blob SHA first. A 409 means the SHA went
    /// stale between the GET and the PUT (e.g. overlapping pushes) — re-fetch and
    /// retry a couple of times before surfacing the error.
    private func put(_ name: String, _ bytes: Data, attempt: Int = 0) async throws {
        let sha = try await currentSHA(name)
        var payload: [String: Any] = [
            "message": "sarv sync: \(name)",
            "content": bytes.base64EncodedString(),
        ]
        if let sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let url = URL(string: "\(apiBase)/contents/\(name)") else {
            throw SyncProviderError(message: "Invalid path \(name).")
        }
        let (_, response) = try await URLSession.shared.data(for: request(url, method: "PUT", body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if (200...201).contains(code) { return }
        // 409 Conflict / 422 (stale or missing sha) → something else is mid-sync.
        // Wait a randomized 2–5s (jitter, to avoid two machines lock-stepping)
        // then refetch the sha and retry.
        if (code == 409 || code == 422), attempt < 3 {
            let waitSeconds = Double.random(in: 2...5)
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            try await put(name, bytes, attempt: attempt + 1)
            return
        }
        // A conflict that survived all retries is still transient — flag it so
        // the coordinator stays silent and lets the next sync resolve it.
        let conflict = (code == 409 || code == 422)
        throw SyncProviderError(message: "Failed to upload \(name) (\(code)).", isConflict: conflict)
    }
}

// MARK: - Cloud Folder (no auth)

/// Stores payloads as files inside a user-chosen directory, accessed through a
/// security-scoped bookmark. The user points this at any folder their OS keeps
/// synced (iCloud Drive, Dropbox, Google Drive, …), so we never touch those
/// services' APIs.
struct FolderSyncProvider: SyncProvider {
    let bookmark: Data
    /// Whether to write version snapshots under `history/` at all.
    var writeHistory: Bool = true
    /// Max version snapshots to keep under `history/`. `nil` = keep all.
    var historyLimit: Int? = 20

    /// Resolve the bookmark to a directory URL, starting security-scoped access.
    /// Caller must `stopAccessingSecurityScopedResource()` when done.
    private func resolve() throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            throw SyncProviderError(message: "The folder reference is stale — please re-select the sync folder.")
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncProviderError(message: "Couldn't access the sync folder. Re-select it to grant permission.")
        }
        return url
    }

    func testConnection() async throws {
        let dir = try resolve()
        defer { dir.stopAccessingSecurityScopedResource() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncProviderError(message: "The sync folder no longer exists.")
        }
        // Write + remove a probe to confirm writability.
        let probe = dir.appendingPathComponent(".sarv-sync-probe")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw SyncProviderError(message: "The sync folder isn't writable.")
        }
    }

    func readManifest() async throws -> Data? {
        try await readFile(SyncManifest.manifestFile)
    }

    func readFile(_ name: String) async throws -> Data? {
        let dir = try resolve()
        defer { dir.stopAccessingSecurityScopedResource() }
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func writeFiles(_ files: [String: Data]) async throws {
        let dir = try resolve()
        defer { dir.stopAccessingSecurityScopedResource() }
        let ordered = files.sorted { a, _ in a.key != SyncManifest.manifestFile }
        for (name, bytes) in ordered {
            try bytes.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        // Point-in-time history: unlike GitHub (which keeps git commits), a plain
        // folder overwrites in place. So snapshot each push into history/v<N>/ so
        // a previous version is always recoverable.
        if writeHistory { writeHistorySnapshot(in: dir, files: files) }
    }

    private func writeHistorySnapshot(in dir: URL, files: [String: Data]) {
        guard let manifestData = files[SyncManifest.manifestFile],
              let manifest = try? JSONDecoder.sync.decode(SyncManifest.self, from: manifestData) else { return }

        let historyRoot = dir.appendingPathComponent("history", isDirectory: true)
        let versionDir = historyRoot.appendingPathComponent("v\(manifest.version)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)) != nil
        else { return }

        // Snapshot the manifest + encrypted payloads (skip the human README).
        for (name, bytes) in files where name != "README.md" {
            try? bytes.write(to: versionDir.appendingPathComponent(name), options: .atomic)
        }
        pruneHistory(historyRoot)
    }

    /// Keep only the newest `historyLimit` version folders. When `historyLimit`
    /// is nil, keep everything (user opted out of pruning).
    private func pruneHistory(_ root: URL) {
        guard let keep = historyLimit, keep > 0 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let versionDirs = entries.filter { $0.lastPathComponent.hasPrefix("v") }
        let sorted = versionDirs.sorted {
            (Int($0.lastPathComponent.dropFirst()) ?? 0) > (Int($1.lastPathComponent.dropFirst()) ?? 0)
        }
        for old in sorted.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}
