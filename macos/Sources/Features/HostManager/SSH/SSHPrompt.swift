import Foundation

/// A prompt ssh sends to its askpass helper, read from the prompt text. With
/// `SSH_ASKPASS_REQUIRE=force` every question goes through askpass: host-key
/// confirmations and passwords, for the target AND each jump host. Pure: no
/// I/O — `SSHPromptBroker` shows the dialogs and replies.
enum SSHPrompt: Equatable {
    /// "The authenticity of host 'X' can't be established… (yes/no/[fingerprint])?"
    /// `detail` is what to show the user (key type and fingerprint).
    case hostKey(host: String, detail: String)
    /// "user@host's password:" or keyboard-interactive "(user@host) Password:".
    case password(user: String, host: String)
    /// Anything else (key passphrase, one-time code…), shown as ssh wrote it.
    case other(String)

    static func parse(_ text: String) -> SSHPrompt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("continue connecting") {
            return .hostKey(host: quotedHost(in: trimmed), detail: hostKeyDetail(in: trimmed))
        }
        if let target = capture(#"^(.+)'s password:$"#, in: trimmed)
            ?? capture(#"^\((.+)\) [Pp]assword:$"#, in: trimmed) {
            let (user, host) = splitTarget(target)
            return .password(user: user, host: host)
        }
        return .other(trimmed)
    }

    /// "[localhost]:2222" from "…authenticity of host '[localhost]:2222 (1.2.3.4)'…".
    private static func quotedHost(in text: String) -> String {
        guard let quoted = capture(#"authenticity of host '([^']*)'"#, in: text) else { return "" }
        return quoted.components(separatedBy: " (").first ?? quoted
    }

    /// "ED25519 key fingerprint:\nSHA256:…", or the whole prompt if ssh worded it
    /// differently (e.g. a key that differs from the one for the IP address).
    private static func hostKeyDetail(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let line = lines.first(where: { $0.contains("key fingerprint is") }),
              let range = line.range(of: "key fingerprint is") else { return text }
        let type = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let print = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return "\(type) key fingerprint:\n\(print)"
    }

    /// "a@b@host" → ("a@b", "host"): a host never contains "@", a user might.
    private static func splitTarget(_ target: String) -> (user: String, host: String) {
        guard let at = target.lastIndex(of: "@") else { return ("", target) }
        return (String(target[..<at]), String(target[target.index(after: at)...]))
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// A password ssh may ask for, for the target host or a jump host.
struct SSHCredential: Equatable {
    /// "" matches any user (the host was saved without one).
    let user: String
    let host: String
    let password: String

    func matches(user promptUser: String, host promptHost: String) -> Bool {
        host.caseInsensitiveCompare(promptHost) == .orderedSame
            && (user.isEmpty || user == promptUser)
    }

    /// The saved password for a password prompt, if one matches.
    static func answer(for prompt: SSHPrompt, from credentials: [SSHCredential]) -> String? {
        guard case .password(let user, let host) = prompt else { return nil }
        return credentials.first { $0.matches(user: user, host: host) }?.password
    }
}

/// ProxyJump (`-J`) hops and the saved passwords that go with them.
enum SSHJump {
    struct Hop: Equatable {
        let user: String
        let host: String
        let port: Int
    }

    /// "a@bastion:2200,b@[fe80::1]:22" → hops, in order. Same syntax as ssh(1) `-J`.
    static func hops(_ spec: String) -> [Hop] {
        spec.split(separator: ",").compactMap { hop(String($0)) }
    }

    private static func hop(_ raw: String) -> Hop? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("ssh://") { text.removeFirst("ssh://".count) }
        var user = ""
        if let at = text.lastIndex(of: "@") {
            user = String(text[..<at])
            text = String(text[text.index(after: at)...])
        }
        var host = text, port = 22
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let value = Int(rest.dropFirst()) { port = value }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            port = Int(text[text.index(after: colon)...]) ?? 22
        }
        return host.isEmpty ? nil : Hop(user: user, host: host, port: port)
    }

    /// Saved passwords for `host` and for every jump hop that matches a saved
    /// host (same hostname and port, and same user when the hop names one).
    static func credentials(for host: SavedHost, savedHosts: [SavedHost]) -> [SSHCredential] {
        var credentials: [SSHCredential] = []
        if !host.password.isEmpty {
            credentials.append(SSHCredential(user: host.username, host: host.hostname, password: host.password))
        }
        for hop in hops(host.proxyJump) {
            if let saved = savedHosts.first(where: { isSaved($0, for: hop) }) {
                credentials.append(SSHCredential(user: hop.user.isEmpty ? saved.username : hop.user,
                                                 host: hop.host, password: saved.password))
            }
        }
        return credentials
    }

    private static func isSaved(_ saved: SavedHost, for hop: Hop) -> Bool {
        let sameHost = saved.hostname.caseInsensitiveCompare(hop.host) == .orderedSame
        let sameUser = hop.user.isEmpty || saved.username == hop.user
        return !saved.password.isEmpty && sameHost && saved.port == hop.port && sameUser
    }
}

/// Arguments every background (no-TTY) ssh run shares: port, jump host,
/// timeout and host-key policy. Host-key questions are answered by
/// `SSHPromptBroker`, so the host's own policy (including "ask") is used as is.
enum SSHBackgroundArgs {
    static func connection(for host: SavedHost) -> [String] {
        var args = ["-p", String(host.port)]
        if !host.proxyJump.isEmpty { args += ["-J", host.proxyJump] }
        let timeout = host.connectTimeoutSeconds > 0 ? host.connectTimeoutSeconds : 10
        args += ["-o", "ConnectTimeout=\(timeout)"]
        args += ["-o", "StrictHostKeyChecking=\(host.strictHostKeyChecking.rawValue)"]
        return args
    }

    /// The host's own key, for hosts that log in with one.
    static func identity(for host: SavedHost) -> [String] {
        guard host.authMethod == .publicKey, !host.identityFile.isEmpty else { return [] }
        return ["-i", (host.identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
    }

    /// The most useful stderr line: the last one that isn't a progress or
    /// known-hosts notice ssh prints on the way out.
    static func failureReason(stderr: String, status: Int32) -> String {
        let noise = ["Warning: Permanently added", "Authenticated to", "Transferred:",
                     "Bytes per second", "Connection closed by UNKNOWN"]
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains { line.hasPrefix($0) } }
        return lines.last ?? "ssh exited with status \(status)."
    }
}
