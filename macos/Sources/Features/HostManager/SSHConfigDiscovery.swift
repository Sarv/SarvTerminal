import Foundation
import Darwin

/// One discovered SSH host that can be searched / connected to.
struct DiscoveredHost: Identifiable, Hashable {
    let id: UUID
    let label: String          // e.g. "web-1"  (the Host token in ssh_config)
    let hostname: String?      // resolved HostName, or nil if same as label
    let user: String?
    let port: Int?
    /// IdentityFile from the ssh_config block (nil = none) — carried into import.
    var identityFile: String? = nil
    /// ProxyJump / bastion from the ssh_config block (nil = none).
    var proxyJump: String? = nil
    let source: Source

    enum Source: Hashable {
        case sshConfig         // ~/.ssh/config
        case userHosts         // future: our own JSON store
    }

    /// Best display subtitle: e.g. "deploy@10.0.1.10:2222" or just "web-1.example.com"
    var subtitle: String {
        var parts: [String] = []
        if let user, !user.isEmpty {
            parts.append("\(user)@\(hostname ?? label)")
        } else if let hostname, hostname != label {
            parts.append(hostname)
        }
        if let port, port != 22 {
            parts.append("port \(port)")
        }
        return parts.joined(separator: " · ")
    }

    /// Command line we'd spawn to connect (used by the launcher).
    var sshCommand: String {
        // We use the label so ssh picks up everything from ~/.ssh/config.
        // For hosts not in ssh_config (future user hosts) we fall back to
        // explicit user@host:port.
        switch source {
        case .sshConfig:
            return "ssh \(label)"
        case .userHosts:
            var args = "ssh"
            if let user { args += " \(user)@\(hostname ?? label)" }
            else        { args += " \(hostname ?? label)" }
            if let port, port != 22 { args += " -p \(port)" }
            return args
        }
    }
}

/// Reads `~/.ssh/config` and returns one `DiscoveredHost` per concrete
/// `Host` entry. Wildcard hosts (e.g. `Host *.prod.example.com`) are
/// skipped — they're patterns, not addressable hosts.
enum SSHConfigDiscovery {
    static func loadAll() -> [DiscoveredHost] {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        let url = base.appendingPathComponent("config")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        // Follow `Include` directives (common: `Include config.d/*`) so split
        // configs import fully.
        var seen: Set<String> = [url.path]
        let expanded = expandIncludes(content, baseDir: base.path, depth: 0, seen: &seen)
        return parse(expanded)
    }

    /// Public for testing.
    static func parse(_ content: String) -> [DiscoveredHost] {
        var hosts: [DiscoveredHost] = []
        var currentLabel: String?
        var currentHostName: String?
        var currentUser: String?
        var currentPort: Int?
        var currentIdentity: String?
        var currentProxyJump: String?

        func flush() {
            guard let label = currentLabel,
                  // Reject wildcards — they're patterns, not connectable hosts.
                  !label.contains("*"),
                  !label.contains("?")
            else {
                return
            }
            hosts.append(DiscoveredHost(
                id: UUID(),
                label: label,
                hostname: currentHostName,
                user: currentUser,
                port: currentPort,
                identityFile: currentIdentity,
                proxyJump: currentProxyJump,
                source: .sshConfig
            ))
        }

        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // ssh_config syntax: `Keyword Value`  (separated by whitespace)
            // Some files use `Keyword=Value`. Handle both.
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))

            switch key {
            case "host":
                // A new Host block — flush previous.
                flush()
                // Reset state for the new entry.
                // Some Host lines have multiple patterns (e.g. `Host a b *.c`); we
                // take only the first concrete name.
                let firstToken = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? value
                currentLabel = firstToken
                currentHostName = nil
                currentUser = nil
                currentPort = nil
                currentIdentity = nil
                currentProxyJump = nil
            case "hostname":     currentHostName = value
            case "user":         currentUser = value
            case "port":         currentPort = Int(value)
            case "identityfile": currentIdentity = value
            case "proxyjump":    currentProxyJump = value
            default:
                continue
            }
        }
        flush() // last block
        // Sort case-insensitively for stable display.
        return hosts.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Inline `Include` directives into one string (recursively, glob-expanded,
    /// cycle-guarded). Relative includes resolve against `baseDir` (`~/.ssh`).
    private static func expandIncludes(_ content: String, baseDir: String,
                                       depth: Int, seen: inout Set<String>) -> String {
        guard depth < 16 else { return content }
        var out = ""
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard lower.hasPrefix("include ") || lower.hasPrefix("include=") else {
                out += raw + "\n"
                continue
            }
            let spec = String(line.dropFirst("include".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " =\t"))
            for token in spec.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                let pattern: String
                if token.hasPrefix("/") || token.hasPrefix("~") { pattern = token }
                else { pattern = (baseDir as NSString).appendingPathComponent(token) }
                for path in globPaths(pattern).sorted() where !seen.contains(path) {
                    seen.insert(path)
                    guard let sub = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    out += expandIncludes(sub, baseDir: (path as NSString).deletingLastPathComponent,
                                          depth: depth + 1, seen: &seen) + "\n"
                }
            }
        }
        return out
    }

    /// Expand a shell-style glob (with `~` and `{a,b}`) to matching file paths.
    private static func globPaths(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, GLOB_TILDE | GLOB_BRACE, nil, &g) == 0 else { return [] }
        var result: [String] = []
        if let pathv = g.gl_pathv {
            for i in 0..<Int(g.gl_pathc) where pathv[i] != nil {
                result.append(String(cString: pathv[i]!))
            }
        }
        return result
    }
}
