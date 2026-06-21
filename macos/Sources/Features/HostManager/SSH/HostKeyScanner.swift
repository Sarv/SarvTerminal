import Foundation

/// Pre-flight host-key verification, done BEFORE ssh runs (so it never has to
/// prompt — which would deadlock against the `SSH_ASKPASS_REQUIRE=force`
/// password helper). Uses the system `ssh-keygen` / `ssh-keyscan`.
enum HostKeyScanner {
    /// known_hosts host token: `host` for port 22, else `[host]:port`.
    static func token(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    struct ScanResult {
        let lines: String        // raw known_hosts lines to append (all key types)
        let keyType: String      // pretty type of the preferred key (e.g. "ED25519")
        let fingerprint: String  // "SHA256:…" of the preferred key
    }

    /// Is there already a known_hosts entry for this host? (`ssh-keygen -F`
    /// matches hashed entries too.)
    static func isKnown(_ token: String) async -> Bool {
        let r = await run("/usr/bin/ssh-keygen", ["-F", token])
        return r.status == 0 && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fetch the host's public keys via `ssh-keyscan`. nil if unreachable.
    static func scan(host: String, port: Int) async -> ScanResult? {
        let r = await run("/usr/bin/ssh-keyscan", ["-p", "\(port)", "-T", "6", host])
        let lines = r.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }

        // Show the strongest key's fingerprint (ed25519 > ecdsa > rsa > first).
        let preferred = lines.first { $0.contains("ed25519") }
            ?? lines.first { $0.contains("ecdsa") }
            ?? lines.first { $0.contains("rsa") }
            ?? lines[0]
        let toks = preferred.split(separator: " ").map(String.init)
        let keyType = toks.count > 1 ? prettyType(toks[1]) : ""
        let fingerprint = toks.count > 2 ? KnownHostsStore.fingerprint(base64Key: toks[2]) : "—"
        return ScanResult(lines: lines.joined(separator: "\n"), keyType: keyType, fingerprint: fingerprint)
    }

    /// Append scanned key lines to ~/.ssh/known_hosts.
    static func add(_ lines: String) {
        let url = knownHostsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += lines + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        KnownHostsStore.shared.reload()
    }

    /// Remove all entries for a host (handles hashed entries).
    static func remove(_ token: String) async {
        _ = await run("/usr/bin/ssh-keygen", ["-R", token])
        await MainActor.run { KnownHostsStore.shared.reload() }
    }

    // MARK: - Helpers

    private static var knownHostsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts")
    }

    private static func prettyType(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("ed25519") { return "ED25519" }
        if r.contains("ecdsa")   { return "ECDSA" }
        if r.contains("rsa")     { return "RSA" }
        if r.contains("dss") || r.contains("dsa") { return "DSA" }
        return raw.uppercased()
    }

    /// Run a process off the main thread and return (status, stdout).
    private static func run(_ launchPath: String, _ args: [String]) async -> (status: Int32, stdout: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "")); return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
