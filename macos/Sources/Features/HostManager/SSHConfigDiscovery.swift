import Foundation

/// One discovered SSH host that can be searched / connected to.
struct DiscoveredHost: Identifiable, Hashable {
    let id: UUID
    let label: String          // e.g. "web-1"  (the Host token in ssh_config)
    let hostname: String?      // resolved HostName, or nil if same as label
    let user: String?
    let port: Int?
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
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(content)
    }

    /// Public for testing.
    static func parse(_ content: String) -> [DiscoveredHost] {
        var hosts: [DiscoveredHost] = []
        var currentLabel: String?
        var currentHostName: String?
        var currentUser: String?
        var currentPort: Int?

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
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

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
            case "hostname":
                currentHostName = value
            case "user":
                currentUser = value
            case "port":
                currentPort = Int(value)
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
}
