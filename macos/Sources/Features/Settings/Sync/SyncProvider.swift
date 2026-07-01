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

    /// Write ALL files in a SINGLE commit via the Git Data API (blobs → one
    /// tree → one commit → move the branch ref), instead of the contents API
    /// which creates one commit per file. Retries the whole sequence if the
    /// branch moved under us (another machine synced concurrently).
    func writeFiles(_ files: [String: Data]) async throws {
        try await commitAll(files, attempt: 0)
    }

    private func commitAll(_ files: [String: Data], attempt: Int) async throws {
        // 1. Default branch.
        let (rc0, repoJSON) = try await gh("", method: "GET")
        guard rc0 == 200, let branch = repoJSON?["default_branch"] as? String else {
            throw SyncProviderError(message: "Couldn't read repository info (\(rc0)).")
        }

        // 2. Current HEAD of the branch (404 ⇒ empty repo / no branch yet).
        let (rcRef, refJSON) = try await gh("/git/ref/heads/\(branch)", method: "GET")
        var parentCommit: String?
        var baseTree: String?
        if rcRef == 200 {
            parentCommit = (refJSON?["object"] as? [String: Any])?["sha"] as? String
            if let parentCommit {
                let (rcC, commitJSON) = try await gh("/git/commits/\(parentCommit)", method: "GET")
                if rcC == 200 { baseTree = (commitJSON?["tree"] as? [String: Any])?["sha"] as? String }
            }
        } else if rcRef != 404 {
            throw SyncProviderError(message: "Couldn't read branch \(branch) (\(rcRef)).")
        }

        // 3. One blob per file (base64 — works for the .enc binaries and the
        //    plaintext manifest alike).
        var entries: [[String: Any]] = []
        for (name, bytes) in files {
            let blobBody = try JSONSerialization.data(withJSONObject: [
                "content": bytes.base64EncodedString(), "encoding": "base64",
            ])
            let (rcB, blobJSON) = try await gh("/git/blobs", method: "POST", body: blobBody)
            guard (200...201).contains(rcB), let sha = blobJSON?["sha"] as? String else {
                throw SyncProviderError(message: "Failed to upload \(name) (\(rcB)).")
            }
            entries.append(["path": name, "mode": "100644", "type": "blob", "sha": sha])
        }

        // 4. A single tree containing every file.
        var treeBody: [String: Any] = ["tree": entries]
        if let baseTree { treeBody["base_tree"] = baseTree }
        let (rcT, treeJSON) = try await gh("/git/trees", method: "POST",
                                           body: try JSONSerialization.data(withJSONObject: treeBody))
        guard (200...201).contains(rcT), let treeSHA = treeJSON?["sha"] as? String else {
            throw SyncProviderError(message: "Failed to create tree (\(rcT)).")
        }

        // 5. One commit.
        var commitBody: [String: Any] = ["message": "Sync SarvTerminal settings", "tree": treeSHA]
        if let parentCommit { commitBody["parents"] = [parentCommit] }
        let (rcCm, commitJSON) = try await gh("/git/commits", method: "POST",
                                              body: try JSONSerialization.data(withJSONObject: commitBody))
        guard (200...201).contains(rcCm), let newCommit = commitJSON?["sha"] as? String else {
            throw SyncProviderError(message: "Failed to create commit (\(rcCm)).")
        }

        // 6. Move (or create) the branch ref to the new commit.
        let rcU: Int
        if rcRef == 200 {
            let (code, _) = try await gh("/git/refs/heads/\(branch)", method: "PATCH",
                                         body: try JSONSerialization.data(withJSONObject: ["sha": newCommit, "force": false]))
            rcU = code
        } else {
            let (code, _) = try await gh("/git/refs", method: "POST",
                                         body: try JSONSerialization.data(withJSONObject: ["ref": "refs/heads/\(branch)", "sha": newCommit]))
            rcU = code
        }
        if (200...201).contains(rcU) { return }

        // Ref moved under us (concurrent sync) → re-fetch and retry the sequence.
        if (rcU == 409 || rcU == 422), attempt < 3 {
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2...5) * 1_000_000_000))
            try await commitAll(files, attempt: attempt + 1)
            return
        }
        throw SyncProviderError(message: "Failed to update \(branch) (\(rcU)).",
                                isConflict: rcU == 409 || rcU == 422)
    }

    /// Small JSON helper: returns (statusCode, parsed-object?).
    private func gh(_ path: String, method: String, body: Data? = nil) async throws -> (Int, [String: Any]?) {
        guard let url = URL(string: apiBase + path) else {
            throw SyncProviderError(message: "Invalid path \(path).")
        }
        let (data, response) = try await URLSession.shared.data(for: request(url, method: method, body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (code, json)
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

    /// All payloads live inside a dedicated `SarvTerminal/` subfolder of the
    /// folder the user chose — so pointing sync at a shared/busy location
    /// (Desktop, Documents, a Drive root) never scatters our files among the
    /// user's own. Created on demand; legacy root-level files are migrated in.
    static let storageFolderName = "SarvTerminal"

    /// Resolve the bookmark to the user-selected directory URL, starting
    /// security-scoped access. Caller must `stopAccessingSecurityScopedResource()`
    /// on the returned URL when done. (The `SarvTerminal/` subfolder we actually
    /// read/write lives within this URL's security scope.)
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

    /// The `SarvTerminal/` subfolder of `base` where every payload lives. Created
    /// if missing; legacy root-level files (written by older builds) are migrated
    /// into it the first time it's created.
    private func storageDir(in base: URL) throws -> URL {
        let dir = base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SyncProviderError(message: "Couldn't create the SarvTerminal folder in the sync location.")
        }
        migrateLegacyLayout(base: base, storage: dir)
        return dir
    }

    /// One-time move of payloads written by older builds at the folder root into
    /// the new `SarvTerminal/` subfolder, so an already-configured sync keeps
    /// working seamlessly. Runs only when the subfolder has no manifest yet but
    /// the root does.
    private func migrateLegacyLayout(base: URL, storage: URL) {
        let fm = FileManager.default
        let manifestInStorage = storage.appendingPathComponent(SyncManifest.manifestFile)
        let manifestAtRoot = base.appendingPathComponent(SyncManifest.manifestFile)
        guard !fm.fileExists(atPath: manifestInStorage.path),
              fm.fileExists(atPath: manifestAtRoot.path) else { return }
        for name in [SyncManifest.manifestFile, SyncManifest.settingsFile, SyncManifest.hostsFile, "README.md"] {
            let src = base.appendingPathComponent(name)
            let dst = storage.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.moveItem(at: src, to: dst)
        }
        let srcHistory = base.appendingPathComponent("history", isDirectory: true)
        let dstHistory = storage.appendingPathComponent("history", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: srcHistory.path, isDirectory: &isDir), isDir.boolValue,
           !fm.fileExists(atPath: dstHistory.path) {
            try? fm.moveItem(at: srcHistory, to: dstHistory)
        }
    }

    func testConnection() async throws {
        let base = try resolve()
        defer { base.stopAccessingSecurityScopedResource() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncProviderError(message: "The sync folder no longer exists.")
        }
        // Creating the SarvTerminal subfolder + a probe inside it confirms we can
        // both create the folder and write to it.
        let dir = try storageDir(in: base)
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
        let base = try resolve()
        defer { base.stopAccessingSecurityScopedResource() }
        let file = try storageDir(in: base).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func writeFiles(_ files: [String: Data]) async throws {
        let base = try resolve()
        defer { base.stopAccessingSecurityScopedResource() }
        let dir = try storageDir(in: base)
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
