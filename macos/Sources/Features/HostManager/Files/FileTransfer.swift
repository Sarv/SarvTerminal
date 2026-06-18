import Foundation

/// How to resolve a name collision when copying into a directory.
enum ConflictResolution {
    case stop      // abort
    case skip      // leave the existing file, don't copy
    case replace   // overwrite
    case duplicate // copy under "name (copy)"
    case merge     // directories: copy contents over the existing folder
}

/// Copies a `FileItem` from one backend into another backend's directory,
/// over local FS and/or `scp`. Single-item for now (the context-menu action).
enum FileTransfer {

    /// Returns the final name to use given a resolution (handles "duplicate").
    static func finalName(for item: FileItem, resolution: ConflictResolution) -> String {
        guard resolution == .duplicate else { return item.name }
        let ext = (item.name as NSString).pathExtension
        let base = (item.name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(item.name) (copy)" : "\(base) (copy).\(ext)"
    }

    static func copy(item: FileItem,
                     from source: FileBackend,
                     to dest: FileBackend,
                     destDir: String,
                     resolution: ConflictResolution) async throws {
        if resolution == .skip || resolution == .stop { return }

        let name = finalName(for: item, resolution: resolution)
        let destPath = dest.join(destDir, name)

        // For replace/merge we clear the existing target first (merge of dirs is
        // approximated as replace-then-copy for v1).
        if resolution == .replace || resolution == .merge {
            if try await dest.exists(destPath) {
                try? await dest.delete(FileItem(name: name, path: destPath, isDirectory: item.isDirectory,
                                                isSymlink: false, size: 0, modified: nil, permissions: nil))
            }
        }

        switch (source, dest) {
        case let (s as LocalFileBackend, d as LocalFileBackend):
            _ = s; _ = d
            try FileManager.default.copyItem(atPath: item.path, toPath: destPath)

        // Local ⇄ remote → SFTP (put / get).
        case let (_ as LocalFileBackend, d as RemoteFileBackend):
            try await sftp(localPath: item.path, isDir: item.isDirectory,
                           remote: d, remotePath: destPath, upload: true)
        case let (s as RemoteFileBackend, _ as LocalFileBackend):
            try await sftp(localPath: destPath, isDir: item.isDirectory,
                           remote: s, remotePath: item.path, upload: false)

        // Server ⇄ server → SCP (scp -3, relayed through this machine).
        case let (s as RemoteFileBackend, d as RemoteFileBackend):
            try await scp3(from: s, srcPath: item.path, to: d, dstPath: destPath, isDir: item.isDirectory)

        default:
            throw FileOpError(message: "Unsupported transfer.")
        }
    }

    // MARK: SFTP (local ⇄ remote)

    private static func sftp(localPath: String, isDir: Bool,
                             remote: RemoteFileBackend, remotePath: String, upload: Bool) async throws {
        let r = isDir ? "-r " : ""
        let line = upload
            ? "put \(r)\(batchQuote(localPath)) \(batchQuote(remotePath))"
            : "get \(r)\(batchQuote(remotePath)) \(batchQuote(localPath))"

        let batch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-sftp-\(UUID().uuidString).batch")
        try (line + "\n").write(to: batch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: batch) }

        var args = remote.transferOptions
        args += ["-o", "Port=\(remote.transferPort)", "-b", batch.path, remote.remoteTarget]
        let res = try await RemoteFileBackend.runProcess("/usr/bin/sftp", args, env: remote.transferEnv)
        guard res.status == 0 else {
            throw FileOpError(message: res.stderr.isEmpty ? "Transfer failed." : res.stderr)
        }
    }

    // MARK: SCP -3 (server ⇄ server)

    private static func scp3(from src: RemoteFileBackend, srcPath: String,
                             to dst: RemoteFileBackend, dstPath: String, isDir: Bool) async throws {
        var args = ["-3"]
        args += src.transferOptions
        if isDir { args.append("-r") }
        // scp:// URIs carry a per-host port, which a bare `-P` can't do for two hosts.
        let srcURL = "scp://\(src.remoteTarget):\(src.transferPort)\(srcPath)"
        let dstURL = "scp://\(dst.remoteTarget):\(dst.transferPort)\(dstPath)"
        args += [srcURL, dstURL]
        // scp -3 relays through this machine; it can offer one askpass password,
        // so this works cleanly when both hosts share credentials.
        let res = try await RemoteFileBackend.runProcess("/usr/bin/scp", args, env: src.transferEnv)
        guard res.status == 0 else {
            throw FileOpError(message: res.stderr.isEmpty ? "Server-to-server copy failed." : res.stderr)
        }
    }

    /// Quote a path for an sftp batch-file command (double quotes; escape `"` `\`).
    private static func batchQuote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
