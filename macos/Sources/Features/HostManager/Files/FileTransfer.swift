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

    /// Resolve the final destination path and clear any existing target. Returns
    /// nil when the resolution means "do nothing".
    static func prepareDestination(item: FileItem, dest: FileBackend, destDir: String,
                                   resolution: ConflictResolution) async throws -> String? {
        if resolution == .skip || resolution == .stop { return nil }
        let name = finalName(for: item, resolution: resolution)
        let destPath = dest.join(destDir, name)
        if resolution == .replace || resolution == .merge {
            if try await dest.exists(destPath) {
                try? await dest.delete(FileItem(name: name, path: destPath, isDirectory: item.isDirectory,
                                                isSymlink: false, size: 0, modified: nil, permissions: nil))
            }
        }
        return destPath
    }

    static func copy(item: FileItem,
                     from source: FileBackend,
                     to dest: FileBackend,
                     destDir: String,
                     resolution: ConflictResolution) async throws {
        guard let destPath = try await prepareDestination(item: item, dest: dest, destDir: destDir, resolution: resolution)
        else { return }

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

        // Server ⇄ server → relay through this machine (download then upload).
        // (SFTPView normally routes these via `serverToServer` for the direct/
        // relay choice; this is the safe default if `copy` is called directly.)
        case let (s as RemoteFileBackend, d as RemoteFileBackend):
            try await relayViaLocal(from: s, srcPath: item.path, to: d, dstPath: destPath, isDir: item.isDirectory)

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

    // MARK: Server ⇄ server (direct or relayed)

    /// Copy between two remote hosts. `direct == true` runs scp ON the source
    /// host (agent-forwarded) so bytes go src→dst without touching this Mac;
    /// otherwise it relays via `scp -3` (through this Mac).
    static func serverToServer(item: FileItem, from src: RemoteFileBackend, to dst: RemoteFileBackend,
                               destDir: String, resolution: ConflictResolution, direct: Bool) async throws -> String? {
        guard let destPath = try await prepareDestination(item: item, dest: dst, destDir: destDir, resolution: resolution)
        else { return nil }
        if direct {
            try await directServerToServer(from: src, srcPath: item.path, to: dst, dstPath: destPath, isDir: item.isDirectory)
        } else {
            try await relayViaLocal(from: src, srcPath: item.path, to: dst, dstPath: destPath, isDir: item.isDirectory)
        }
        return destPath
    }

    /// Direct src→dst: run `scp` ON the source host so the file flows A→B and
    /// never passes through this machine. Key-based destinations authenticate
    /// via our forwarded SSH agent (`ssh -A`); password destinations get the
    /// saved password through a one-shot askpass written on A (then deleted).
    private static func directServerToServer(from src: RemoteFileBackend, srcPath: String,
                                             to dst: RemoteFileBackend, dstPath: String, isDir: Bool) async throws {
        let r = isDir ? "-r " : ""
        let scpTo = "\(dst.remoteTarget):\(dstPath)"
        var args = src.transferOptions
        args += ["-p", "\(src.transferPort)", src.remoteTarget]

        if dst.usesKeyAuth || dst.hostPassword.isEmpty {
            // Forward our agent so A can authenticate to B with the key.
            args.insert("-A", at: 0)
            args.append("scp -p -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
                        + "-P \(dst.transferPort) \(r)\(shquote(srcPath)) \(shquote(scpTo))")
        } else {
            // Feed B's password to scp-on-A via a temporary SSH_ASKPASS helper.
            let b64 = Data(dst.hostPassword.utf8).base64EncodedString()
            args.append("""
            AP=$(mktemp) || exit 1
            chmod 700 "$AP"
            cat > "$AP" <<'SARVEOS'
            #!/bin/sh
            printf '%s' "$SARV_BPW" | base64 -d
            SARVEOS
            SARV_BPW='\(b64)' SSH_ASKPASS="$AP" SSH_ASKPASS_REQUIRE=force \
            scp -p -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=1 \
            -P \(dst.transferPort) \(r)\(shquote(srcPath)) \(shquote(scpTo)) </dev/null
            rc=$?
            rm -f "$AP"
            exit $rc
            """)
        }
        let res = try await RemoteFileBackend.runProcess("/usr/bin/ssh", args, env: src.transferEnv)
        guard res.status == 0 else {
            throw FileOpError(message: res.stderr.isEmpty ? "Direct server-to-server transfer failed." : res.stderr)
        }
    }

    /// Single-quote for the source host's shell.
    private static func shquote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Relay through this Mac (download then upload)

    /// Relay src→dst by downloading to a local temp with the SOURCE's
    /// credentials, then uploading to the destination with the DESTINATION's
    /// credentials. Unlike `scp -3` (one credential for both hosts), this works
    /// when the two servers have different passwords/keys.
    private static func relayViaLocal(from src: RemoteFileBackend, srcPath: String,
                                      to dst: RemoteFileBackend, dstPath: String, isDir: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent((srcPath as NSString).lastPathComponent).path

        try await sftp(localPath: local, isDir: isDir, remote: src, remotePath: srcPath, upload: false) // download
        try await sftp(localPath: local, isDir: isDir, remote: dst, remotePath: dstPath, upload: true)  // upload
    }

    /// Quote a path for an sftp batch-file command (double quotes; escape `"` `\`).
    private static func batchQuote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
