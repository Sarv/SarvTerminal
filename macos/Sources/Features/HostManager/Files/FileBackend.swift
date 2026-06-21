import Foundation

/// Errors surfaced to the UI from a file operation.
struct FileOpError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Abstracts file operations over a local FS or a remote host (via the ssh/sftp
/// CLIs). Paths are POSIX ("/"-separated) for both.
protocol FileBackend {
    var location: FileLocation { get }
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [FileItem]
    func makeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func delete(_ item: FileItem) async throws
    func setPermissions(_ path: String, octal: String) async throws
    func exists(_ path: String) async throws -> Bool
    /// A local file URL whose contents mirror `item` (the file itself for a
    /// local backend; a downloaded temp copy for a remote one) — used by the
    /// file viewer.
    func localCopy(of item: FileItem) async throws -> URL
    /// Write `text` back to `item` (in place locally; upload for remote).
    func save(_ text: String, to item: FileItem) async throws
    /// Current size of a file in bytes (nil if missing) — polled to drive
    /// transfer progress against the known source size.
    func fileSize(_ path: String) async -> Int64?
}

extension FileBackend {
    /// Join a directory and a child name with a single "/".
    func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}

// MARK: - Local

final class LocalFileBackend: FileBackend {
    let location: FileLocation = .local
    private let fm = FileManager.default

    func homeDirectory() async throws -> String { NSHomeDirectory() }

    func list(_ path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        // All stat-level keys (incl. .fileSecurityKey for POSIX mode). We avoid
        // `attributesOfItem`, which OPENS each item — that's what made listing the
        // home folder trip the Desktop/Documents/Downloads privacy prompts.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .fileSecurityKey]
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                  options: [.skipsSubdirectoryDescendants])
        return contents.map { item in
            let vals = try? item.resourceValues(forKeys: Set(keys))
            var perms: String? = nil
            if let sec = vals?.fileSecurity {
                var mode: mode_t = 0
                if CFFileSecurityGetMode(sec as CFFileSecurity, &mode) {
                    perms = Self.symbolic(from: UInt16(mode & 0o777))
                }
            }
            return FileItem(
                name: item.lastPathComponent,
                path: item.path,
                isDirectory: vals?.isDirectory ?? false,
                isSymlink: vals?.isSymbolicLink ?? false,
                size: Int64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate,
                permissions: perms
            )
        }.sorted(by: Self.sort)
    }

    func makeDirectory(_ path: String) async throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func rename(_ path: String, to newPath: String) async throws {
        try fm.moveItem(atPath: path, toPath: newPath)
    }

    func delete(_ item: FileItem) async throws {
        try fm.removeItem(atPath: item.path)
    }

    func setPermissions(_ path: String, octal: String) async throws {
        guard let mode = UInt16(octal, radix: 8) else { throw FileOpError(message: "Invalid permissions: \(octal)") }
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    func exists(_ path: String) async throws -> Bool {
        fm.fileExists(atPath: path)
    }

    func localCopy(of item: FileItem) async throws -> URL {
        URL(fileURLWithPath: item.path)
    }

    func save(_ text: String, to item: FileItem) async throws {
        try text.write(toFile: item.path, atomically: true, encoding: .utf8)
    }

    func fileSize(_ path: String) async -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }

    static func sort(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// "rwxr-xr-x" from a POSIX mode.
    static func symbolic(from mode: UInt16) -> String {
        let bits = ["r", "w", "x"]
        var s = ""
        for shift in [6, 3, 0] {
            let v = (Int(mode) >> shift) & 0x7
            for (i, ch) in bits.enumerated() { s += (v & (4 >> i)) != 0 ? ch : "-" }
        }
        return s
    }
}

// MARK: - Remote (ssh / scp)

final class RemoteFileBackend: FileBackend {
    let location: FileLocation
    private let host: SavedHost
    /// askpass env so ssh/scp can authenticate non-interactively. Built once.
    private let askpassEnv: [String: String]

    init(host: SavedHost) {
        self.host = host
        self.location = .host(host)
        self.askpassEnv = host.password.isEmpty ? [:] : SSHAskpass.env(forPassword: host.password)
    }

    private var target: String {
        host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"
    }

    /// Common ssh/scp options derived from the host.
    private func sshOptions() -> [String] {
        var args: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if host.connectTimeoutSeconds > 0 { args += ["-o", "ConnectTimeout=\(host.connectTimeoutSeconds)"] }
        if !host.identityFile.isEmpty {
            args += ["-i", (host.identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        return args
    }

    func homeDirectory() async throws -> String {
        let out = try await run(ssh: ["pwd"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "/" : out
    }

    func list(_ path: String) async throws -> [FileItem] {
        // Plain `ls -la` (no --time-style): portable across GNU coreutils AND
        // BusyBox (Alpine), where long-form options aren't supported.
        let res = try await run(ssh: ["ls", "-la", sftpQuote(path)])
        guard res.status == 0 else { throw FileOpError(message: res.stderr.isEmpty ? "Failed to list directory." : res.stderr) }
        return Self.parseLS(res.stdout, dir: path).sorted(by: LocalFileBackend.sort)
    }

    func makeDirectory(_ path: String) async throws { try await runChecked(ssh: ["mkdir", sftpQuote(path)]) }

    func rename(_ path: String, to newPath: String) async throws {
        try await runChecked(ssh: ["mv", sftpQuote(path), sftpQuote(newPath)])
    }

    func delete(_ item: FileItem) async throws {
        let cmd = item.isDirectory ? "rm -rf" : "rm -f"
        try await runChecked(ssh: cmd.split(separator: " ").map(String.init) + [sftpQuote(item.path)])
    }

    func setPermissions(_ path: String, octal: String) async throws {
        try await runChecked(ssh: ["chmod", octal, sftpQuote(path)])
    }

    func exists(_ path: String) async throws -> Bool {
        let res = try await run(ssh: ["test", "-e", sftpQuote(path), "&&", "echo", "Y", "||", "echo", "N"])
        return res.stdout.contains("Y")
    }

    var remoteTarget: String { target }
    var transferOptions: [String] { sshOptions() }
    var transferEnv: [String: String] { askpassEnv }
    var transferPort: Int { host.port }

    func localCopy(of item: FileItem) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.name)
        let batch = dir.appendingPathComponent("get.sftp")
        try "get \"\(item.path)\" \"\(dest.path)\"\n".write(to: batch, atomically: true, encoding: .utf8)
        var args = sshOptions()
        args += ["-o", "Port=\(host.port)", "-b", batch.path, target]
        let res = try await Self.runProcess("/usr/bin/sftp", args, env: askpassEnv)
        try? FileManager.default.removeItem(at: batch)
        guard res.status == 0 else {
            throw FileOpError(message: res.stderr.isEmpty ? "Couldn't open file." : res.stderr)
        }
        return dest
    }

    func save(_ text: String, to item: FileItem) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appendingPathComponent(item.name)
        try text.write(to: local, atomically: true, encoding: .utf8)
        let batch = dir.appendingPathComponent("put.sftp")
        try "put \"\(local.path)\" \"\(item.path)\"\n".write(to: batch, atomically: true, encoding: .utf8)
        var args = sshOptions()
        args += ["-o", "Port=\(host.port)", "-b", batch.path, target]
        let res = try await Self.runProcess("/usr/bin/sftp", args, env: askpassEnv)
        guard res.status == 0 else {
            throw FileOpError(message: res.stderr.isEmpty ? "Couldn't save file." : res.stderr)
        }
    }

    func fileSize(_ path: String) async -> Int64? {
        // `wc -c` is portable (GNU + BusyBox); prints just the byte count.
        guard let r = try? await run(ssh: ["wc", "-c", "<", sftpQuote(path)]), r.status == 0 else { return nil }
        let digits = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(digits)
    }

    /// True when this host authenticates with a key/agent (so direct
    /// server-to-server via agent forwarding is possible).
    var usesKeyAuth: Bool { host.authMethod == .publicKey || host.authMethod == .agent }
    /// The saved password (empty if none) — used to feed a direct A→B transfer
    /// where B is a password host (via a one-shot askpass on A).
    var hostPassword: String { host.password }

    // MARK: ssh runner

    @discardableResult
    private func runChecked(ssh cmd: [String]) async throws -> ProcessResult {
        let r = try await run(ssh: cmd)
        guard r.status == 0 else { throw FileOpError(message: r.stderr.isEmpty ? "Operation failed." : r.stderr) }
        return r
    }

    private func run(ssh remoteArgs: [String]) async throws -> ProcessResult {
        var args = sshOptions()
        if host.port != 22 { args += ["-p", "\(host.port)"] }
        args.append(target)
        args.append(remoteArgs.joined(separator: " "))
        return try await Self.runProcess("/usr/bin/ssh", args, env: askpassEnv)
    }

    // MARK: Parsing

    /// Parse plain `ls -la` output (GNU + BusyBox) into FileItems.
    /// Columns: perms links owner group size MON DAY TIME|YEAR name…
    static func parseLS(_ output: String, dir: String) -> [FileItem] {
        var items: [FileItem] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("total ") { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9, cols[0].count >= 10 else { continue }
            let permsField = cols[0]
            let typeChar = permsField.first!
            let isDir = typeChar == "d"
            let isLink = typeChar == "l"
            let size = Int64(cols[4]) ?? 0
            // name is everything from the 9th field on (keeps spaces).
            var name = cols[8...].joined(separator: " ")
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            name = name.trimmingCharacters(in: .whitespaces)
            if name == "." || name == ".." || name.isEmpty { continue }
            let perms = String(permsField.dropFirst().prefix(9))
            let date = Self.parseDate(month: cols[5], day: cols[6], last: cols[7])
            items.append(FileItem(
                name: name,
                path: dir == "/" ? "/" + name : dir + "/" + name,
                isDirectory: isDir,
                isSymlink: isLink,
                size: size,
                modified: date,
                permissions: perms
            ))
        }
        return items
    }

    /// "Jun 18 14:05" (current year) or "Jun 18 2024" → Date, best-effort.
    private static func parseDate(month: String, day: String, last: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if last.contains(":") {
            f.dateFormat = "yyyy MMM d HH:mm"
            let year = Calendar.current.component(.year, from: Date())
            return f.date(from: "\(year) \(month) \(day) \(last)")
        }
        f.dateFormat = "MMM d yyyy"
        return f.date(from: "\(month) \(day) \(last)")
    }

    // MARK: Process

    struct ProcessResult { let status: Int32; let stdout: String; let stderr: String }

    /// Thread-safe holder so a cancelled Task can terminate the running process.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private var cancelled = false
        func attach(_ p: Process) {
            lock.lock(); defer { lock.unlock() }
            proc = p
            if cancelled { p.terminate() }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            proc?.terminate()
        }
    }

    static func runProcess(_ launchPath: String, _ args: [String], env: [String: String]) async throws -> ProcessResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: launchPath)
                    proc.arguments = args
                    var environment = ProcessInfo.processInfo.environment
                    env.forEach { environment[$0.key] = $0.value }
                    proc.environment = environment
                    let outPipe = Pipe(), errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe
                    proc.standardInput = FileHandle.nullDevice
                    box.attach(proc)   // lets a cancel terminate it
                    do { try proc.run() } catch { cont.resume(throwing: error); return }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: ProcessResult(
                        status: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Single-quote a string for safe embedding in a remote shell command.
func sftpQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
